--!strict
-- MapValidator
-- Checks a generated MapData for identity, geometry, adjacency, terrain and
-- data-level selection problems. Returns a structured report; nothing is
-- silently ignored. Rendering checks live in the client MapRenderer
-- (it is the only place the rendered instances exist).

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("RoCiv"):WaitForChild("Shared")
local Geometry = require(Shared:WaitForChild("Geometry"))
local MapConfig = require(Shared:WaitForChild("MapConfig"))
local MapQuery = require(Shared:WaitForChild("MapQuery"))
local TerrainTypes = require(Shared:WaitForChild("TerrainTypes"))

export type Issue = { check: string, message: string, ids: { number }? }
export type Report = {
	ok: boolean,
	errors: { Issue },
	warnings: { Issue },
	info: { [string]: any },
	checksRun: { string },
	durationMs: number,
}

local MapValidator = {}

-- Position tolerance in studs. Vector2 stores 32-bit floats, so a vertex
-- shared by two cells (computed independently by each) can differ by ~1e-3
-- at the far side of a 4000-stud map. 0.01 studs is far below anything
-- visible or gameplay-relevant.
local POS_TOL = 0.01

-- Unknown terrain is reported separately; treat it as land here.
local function isWaterRecord(t: any): boolean
	local def = TerrainTypes.ById[t.terrainType]
	return def ~= nil and def.isWater
end

function MapValidator.validate(map: any): Report
	local t0 = os.clock()
	local errors: { Issue } = {}
	local warnings: { Issue } = {}
	local info: { [string]: any } = {}
	local checksRun: { string } = {}

	local function err(check: string, message: string, ids: { number }?)
		table.insert(errors, { check = check, message = message, ids = ids })
	end
	local function warn(check: string, message: string, ids: { number }?)
		table.insert(warnings, { check = check, message = message, ids = ids })
	end

	local territories = map.territories
	local ids: { number } = map.territoryIds
	local W, H = map.width, map.height

	-- Identity -----------------------------------------------------------------
	table.insert(checksRun, "identity")
	local seenIds: { [number]: boolean } = {}
	local dupIds = {}
	for _, id in ids do
		if seenIds[id] then
			table.insert(dupIds, id)
		end
		seenIds[id] = true
	end
	if #dupIds > 0 then
		err("identity", "Duplicate territory ids", dupIds)
	end
	if #ids ~= map.territoryCount then
		err("identity", string.format("Expected %d territories, found %d", map.territoryCount, #ids))
	end
	local keyCount = 0
	for key, t in territories do
		keyCount += 1
		if t.id ~= key then
			err("identity", string.format("Territory stored under key %s has id %s", tostring(key), tostring(t.id)))
		end
	end
	if keyCount ~= #ids then
		err("identity", string.format("Territory table has %d entries but id list has %d", keyCount, #ids))
	end

	local required = {
		id = "number",
		polygon = "table",
		neighbors = "table",
		terrainType = "string",
		elevation = "number",
		fertility = "number",
		resources = "table",
		movementMetadata = "table",
	}
	local missing = {}
	for _, id in ids do
		local t = territories[id]
		if not t then
			table.insert(missing, id)
			continue
		end
		for field, ty in required do
			if type(t[field]) ~= ty then
				err("identity", string.format("Territory %d field '%s' should be %s", id, field, ty), { id })
			end
		end
		if t.ownerId ~= nil and type(t.ownerId) ~= "number" then
			err("identity", "ownerId must be nil or a number", { id })
		end
		if t.cityId ~= nil and type(t.cityId) ~= "number" then
			err("identity", "cityId must be nil or a number", { id })
		end
	end
	if #missing > 0 then
		err("identity", "Ids listed without territory records", missing)
	end

	-- Geometry -----------------------------------------------------------------
	table.insert(checksRun, "geometry")
	local totalArea = 0
	local badPoly, outOfBounds, centroidOutside = {}, {}, {}
	for _, id in ids do
		local t = territories[id]
		if not t then
			continue
		end
		local poly = t.polygon
		if #poly < 3 or not Geometry.isConvexCCW(poly) then
			table.insert(badPoly, id)
		end
		for _, p in poly do
			if p.X < -POS_TOL or p.Y < -POS_TOL or p.X > W + POS_TOL or p.Y > H + POS_TOL then
				table.insert(outOfBounds, id)
				break
			end
		end
		local area = Geometry.signedArea(poly)
		totalArea += area
		if not Geometry.pointInConvex(poly, Geometry.centroid(poly), 1e-4) then
			table.insert(centroidOutside, id)
		end
	end
	if #badPoly > 0 then
		err("geometry", "Polygons that are degenerate, non-convex or wrongly oriented", badPoly)
	end
	if #outOfBounds > 0 then
		err("geometry", "Polygons extending outside the map bounds", outOfBounds)
	end
	if #centroidOutside > 0 then
		err("geometry", "Centroid outside its own polygon", centroidOutside)
	end
	local mapArea = W * H
	local areaError = math.abs(totalArea - mapArea) / mapArea
	info.areaCoverage = totalArea / mapArea
	if areaError > 1e-6 then
		err("geometry", string.format("Territory areas sum to %.6f of the map (gaps or overlaps)", totalArea / mapArea))
	end

	-- Shared edges: every tagged edge must exist (reversed) on the other side.
	local edgeMismatch = {}
	for _, id in ids do
		local t = territories[id]
		if not t or not t.edgeNeighbors then
			continue
		end
		local poly = t.polygon
		local n = #poly
		for e = 1, n do
			local other = t.edgeNeighbors[e]
			if other ~= 0 then
				local a, b = poly[e], poly[e % n + 1]
				local o = territories[other]
				local found = false
				if o then
					local on = #o.polygon
					for k = 1, on do
						local c, d = o.polygon[k], o.polygon[k % on + 1]
						if (c - b).Magnitude < POS_TOL and (d - a).Magnitude < POS_TOL then
							found = true
							break
						end
					end
				end
				if not found and (b - a).Magnitude >= POS_TOL then
					table.insert(edgeMismatch, id)
					break
				end
			end
		end
	end
	if #edgeMismatch > 0 then
		err("geometry", "Border edges not matched by the neighbouring polygon", edgeMismatch)
	end

	-- Adjacency ----------------------------------------------------------------
	table.insert(checksRun, "adjacency")
	local badRef, selfRef, dupRef, asym, isolated = {}, {}, {}, {}, {}
	for _, id in ids do
		local t = territories[id]
		if not t then
			continue
		end
		local seen: { [number]: boolean } = {}
		for _, nb in t.neighbors do
			if territories[nb] == nil then
				table.insert(badRef, id)
			elseif nb == id then
				table.insert(selfRef, id)
			elseif seen[nb] then
				table.insert(dupRef, id)
			elseif not table.find(territories[nb].neighbors, id) then
				table.insert(asym, id)
			end
			seen[nb] = true
		end
		if #t.neighbors == 0 then
			table.insert(isolated, id)
		end
	end
	if #badRef > 0 then
		err("adjacency", "Neighbour ids that do not exist", badRef)
	end
	if #selfRef > 0 then
		err("adjacency", "Territories listing themselves as neighbours", selfRef)
	end
	if #dupRef > 0 then
		err("adjacency", "Duplicate neighbour ids", dupRef)
	end
	if #asym > 0 then
		err("adjacency", "One-way neighbour links (not symmetric)", asym)
	end
	if #isolated > 0 then
		err("adjacency", "Isolated territories with no neighbours", isolated)
	end

	-- Independent geometric cross-check: brute-force shared-segment search
	-- that ignores the generator's edge tags.
	local minEdge = MapConfig.MIN_SHARED_EDGE_LENGTH
	local bboxes = {}
	for _, id in ids do
		local t = territories[id]
		if t then
			local lo, hi = Geometry.bounds(t.polygon)
			bboxes[id] = { lo, hi }
		end
	end
	local missingLinks, falseLinks = {}, {}
	-- Sweep over x so only polygons whose bounding boxes overlap are compared.
	local sweep = {}
	for _, id in ids do
		if territories[id] then
			table.insert(sweep, id)
		end
	end
	table.sort(sweep, function(x, y)
		return bboxes[x][1].X < bboxes[y][1].X
	end)
	for ai = 1, #sweep do
		local a = territories[sweep[ai]]
		local abox = bboxes[a.id]
		for bi = ai + 1, #sweep do
			local b = territories[sweep[bi]]
			local bbox = bboxes[b.id]
			if bbox[1].X > abox[2].X + POS_TOL then
				break
			end
			local overlap = abox[1].Y <= bbox[2].Y + POS_TOL and bbox[1].Y <= abox[2].Y + POS_TOL
			local shared = 0
			if overlap then
				local na, nb = #a.polygon, #b.polygon
				for i = 1, na do
					local p, q = a.polygon[i], a.polygon[i % na + 1]
					for k = 1, nb do
						local r, s = b.polygon[k], b.polygon[k % nb + 1]
						if (p - s).Magnitude < POS_TOL and (q - r).Magnitude < POS_TOL then
							shared += (q - p).Magnitude
						end
					end
				end
			end
			local geomAdjacent = shared >= minEdge
			local listed = table.find(a.neighbors, b.id) ~= nil
			if geomAdjacent and not listed then
				table.insert(missingLinks, a.id)
				table.insert(missingLinks, b.id)
			elseif listed and not geomAdjacent then
				table.insert(falseLinks, a.id)
				table.insert(falseLinks, b.id)
			end
		end
	end
	-- Listed links between polygons whose boxes never overlap are missed by
	-- the sweep; catch them directly.
	for _, id in sweep do
		local abox = bboxes[id]
		for _, nb in territories[id].neighbors do
			local bbox = bboxes[nb]
			if bbox and (bbox[1].X > abox[2].X + POS_TOL or abox[1].X > bbox[2].X + POS_TOL or bbox[1].Y > abox[2].Y + POS_TOL or abox[1].Y > bbox[2].Y + POS_TOL) then
				table.insert(falseLinks, id)
				table.insert(falseLinks, nb)
			end
		end
	end
	if #missingLinks > 0 then
		err("adjacency", "Shared borders missing from neighbour lists (pairs)", missingLinks)
	end
	if #falseLinks > 0 then
		err("adjacency", "Neighbour links without a shared border (pairs)", falseLinks)
	end

	-- Whole-map connectivity.
	if #ids > 0 then
		local visited: { [number]: boolean } = { [ids[1]] = true }
		local queue = { ids[1] }
		local head = 1
		while head <= #queue do
			local id = queue[head]
			head += 1
			for _, nb in territories[id].neighbors do
				if territories[nb] and not visited[nb] then
					visited[nb] = true
					table.insert(queue, nb)
				end
			end
		end
		if #queue ~= #ids then
			local unreached = {}
			for _, id in ids do
				if not visited[id] then
					table.insert(unreached, id)
				end
			end
			err("adjacency", "Map graph is disconnected; unreachable territories", unreached)
		end
	end
	local degreeSum = 0
	for _, id in ids do
		if territories[id] then
			degreeSum += #territories[id].neighbors
		end
	end
	info.averageNeighbors = degreeSum / math.max(#ids, 1)

	-- Terrain ------------------------------------------------------------------
	table.insert(checksRun, "terrain")
	local badTerrain, badElev, badFert, waterRule, coastRule, mountainRule = {}, {}, {}, {}, {}, {}
	for _, id in ids do
		local t = territories[id]
		if not t then
			continue
		end
		local def = TerrainTypes.get(t.terrainType)
		if not def then
			table.insert(badTerrain, id)
			continue
		end
		if t.elevation < 0 or t.elevation > 1 or t.elevation ~= t.elevation then
			table.insert(badElev, id)
		end
		if t.fertility < 0 or t.fertility > 1 or t.fertility ~= t.fertility then
			table.insert(badFert, id)
		end
		-- Ocean/Coast are exactly the territories below sea level; lakes are
		-- inland water and may sit above it (basins).
		local water = t.elevation < map.seaLevel
		local isLake = t.terrainType == "Lake"
		if t.isWater ~= def.isWater or (not isLake and water ~= def.isWater) then
			table.insert(waterRule, id)
		end
		local nearLand = false
		for _, nb in t.neighbors do
			local o = territories[nb]
			if o and not isWaterRecord(o) then
				nearLand = true
			end
		end
		if (t.terrainType == "Coast") ~= (def.isWater and not isLake and nearLand) then
			table.insert(coastRule, id)
		end
		if (t.terrainType == "Mountains") ~= (not def.isWater and t.elevation >= map.mountainLevel) then
			table.insert(mountainRule, id)
		end
	end
	if #badTerrain > 0 then
		err("terrain", "Unknown terrain types", badTerrain)
	end
	if #badElev > 0 then
		err("terrain", "Elevation outside 0..1", badElev)
	end
	if #badFert > 0 then
		err("terrain", "Fertility outside 0..1", badFert)
	end
	if #waterRule > 0 then
		err("terrain", "Water/land does not match elevation vs sea level", waterRule)
	end
	if #coastRule > 0 then
		err("terrain", "Coast must be sea touching land; Ocean must not touch land", coastRule)
	end
	-- Lakes must not connect to the open sea.
	local lakeOnSea = {}
	for _, id in ids do
		local t = territories[id]
		if t and t.terrainType == "Lake" then
			for _, nb in t.neighbors do
				local o = territories[nb]
				if o and (o.terrainType == "Ocean" or o.terrainType == "Coast") then
					table.insert(lakeOnSea, id)
					break
				end
			end
		end
	end
	if #lakeOnSea > 0 then
		err("terrain", "Lakes touching the sea", lakeOnSea)
	end
	if #mountainRule > 0 then
		err("terrain", "Mountains must be exactly the land at/above mountain level", mountainRule)
	end

	-- Land masses (informational) and single-territory islands (warning).
	local landVisited: { [number]: boolean } = {}
	local masses = {}
	for _, id in ids do
		local t = territories[id]
		if t and not isWaterRecord(t) and not landVisited[id] then
			local size = 0
			local queue = { id }
			landVisited[id] = true
			local head = 1
			while head <= #queue do
				local cur = queue[head]
				head += 1
				size += 1
				for _, nb in territories[cur].neighbors do
					local o = territories[nb]
					if o and not landVisited[nb] and not isWaterRecord(o) then
						landVisited[nb] = true
						table.insert(queue, nb)
					end
				end
			end
			table.insert(masses, { root = id, size = size })
		end
	end
	table.sort(masses, function(a, b)
		return a.size > b.size
	end)
	local massSizes, singles = {}, {}
	for _, m in masses do
		table.insert(massSizes, m.size)
		if m.size == 1 then
			table.insert(singles, m.root)
		end
	end
	info.landMasses = massSizes
	if #singles > 0 then
		warn("terrain", "Single-territory islands (valid, but isolated by water)", singles)
	end

	local counts = {}
	for _, id in ids do
		local t = territories[id]
		if t then
			counts[t.terrainType] = (counts[t.terrainType] or 0) + 1
		end
	end
	info.terrainCounts = counts
	for _, def in TerrainTypes.List do
		if not counts[def.id] and #ids >= 100 then
			warn("terrain", "Terrain type never generated: " .. def.id)
		end
	end

	-- Geography: landmasses, continents, rivers, start positions ---------------
	if map.landmasses then
		table.insert(checksRun, "geography")
		-- Landmass labels must match the flood fill above.
		local badLabel = {}
		for _, id in ids do
			local t = territories[id]
			if t then
				local water = isWaterRecord(t)
				if water and t.landmassId ~= 0 then
					table.insert(badLabel, id)
				elseif not water then
					for _, nb in t.neighbors do
						local o = territories[nb]
						if o and not isWaterRecord(o) and o.landmassId ~= t.landmassId then
							table.insert(badLabel, id)
							break
						end
					end
					if t.landmassId == 0 then
						table.insert(badLabel, id)
					end
				end
			end
		end
		if #badLabel > 0 then
			err("geography", "Landmass labels inconsistent with land connectivity", badLabel)
		end
		if #map.landmasses ~= #masses then
			err("geography", string.format("Generator reports %d landmasses, flood fill finds %d", #map.landmasses, #masses))
		end
		local def = MapConfig.MATCH_SIZES[map.matchSize]
		info.continents = map.continentCount
		if def and map.continentCount < def.continents[1] then
			err("geography", string.format("%s map needs at least %d continents, has %d", map.matchSize, def.continents[1], map.continentCount))
		end

		-- Rivers: chains of neighbouring land territories ending at water.
		local badRiver = {}
		local riverCount = 0
		for _, river in map.rivers or {} do
			riverCount += 1
			local path = river.territoryIds
			local ok = #path >= MapConfig.RIVER_MIN_LENGTH
			for i, tid in path do
				local t = territories[tid]
				if not t or isWaterRecord(t) or t.riverId ~= river.id or not t.riverPath or #t.riverPath < 2 then
					ok = false
				elseif i > 1 and not table.find(t.neighbors, path[i - 1]) then
					ok = false
				end
			end
			local last = territories[path[#path]]
			local mouth = territories[river.mouth]
			if not last or not mouth or not isWaterRecord(mouth) or not table.find(last.neighbors, river.mouth) then
				ok = false
			end
			if not ok then
				table.insert(badRiver, river.id)
			end
		end
		info.rivers = riverCount
		if #badRiver > 0 then
			err("geography", "Rivers broken (not a land chain ending at water) [river ids]", badRiver)
		end
		local strayRiver = {}
		for _, id in ids do
			local t = territories[id]
			if t and t.riverId ~= nil then
				local r = map.rivers and map.rivers[t.riverId]
				if not r or not table.find(r.territoryIds, id) then
					table.insert(strayRiver, id)
				end
			end
		end
		if #strayRiver > 0 then
			err("geography", "Territories tagged with a river that does not include them", strayRiver)
		end

		-- Start positions.
		local starts = map.startPositions or {}
		info.starts = #starts
		if def and #starts ~= map.civilizations then
			err("geography", string.format("Expected %d start positions, found %d", map.civilizations, #starts))
		end
		local badStart = {}
		for i, sid in starts do
			local t = territories[sid]
			if not t or isWaterRecord(t) or t.terrainType == "Mountains" or table.find(starts, sid) ~= i then
				table.insert(badStart, sid)
			else
				local lm = nil
				for _, m in map.landmasses do
					if m.id == t.landmassId then
						lm = m
					end
				end
				if not lm or not lm.isContinent then
					table.insert(badStart, sid)
				end
			end
		end
		if #badStart > 0 then
			err("geography", "Start positions on water/mountains, duplicated, or off-continent", badStart)
		end
		-- Spacing: land hops between starts on the same landmass.
		local tooClose = {}
		for i, a in starts do
			if territories[a] then
				local dist: { [number]: number } = { [a] = 0 }
				local q, h = { a }, 1
				while h <= #q do
					local cur = q[h]
					h += 1
					if dist[cur] < MapConfig.START_MIN_SPACING then
						for _, nb in territories[cur].neighbors do
							local o = territories[nb]
							if o and dist[nb] == nil and not isWaterRecord(o) then
								dist[nb] = dist[cur] + 1
								table.insert(q, nb)
							end
						end
					end
				end
				for j = i + 1, #starts do
					local d = dist[starts[j]]
					if d and d < MapConfig.START_MIN_SPACING then
						table.insert(tooClose, a)
						table.insert(tooClose, starts[j])
					end
				end
			end
		end
		if #tooClose > 0 then
			err("geography", "Start positions closer than START_MIN_SPACING (pairs)", tooClose)
		end
	end

	-- Data-level selection -----------------------------------------------------
	table.insert(checksRun, "selection")
	local query = MapQuery.new(
		(function()
			local list = {}
			for _, id in ids do
				if territories[id] then
					table.insert(list, territories[id])
				end
			end
			return list
		end)(),
		W,
		H
	)
	local wrongPick = {}
	for _, id in ids do
		local t = territories[id]
		if t and query:territoryAt(Geometry.centroid(t.polygon)) ~= id then
			table.insert(wrongPick, id)
		end
	end
	if #wrongPick > 0 then
		err("selection", "Point lookup at centroid returned the wrong territory", wrongPick)
	end

	return {
		ok = #errors == 0,
		errors = errors,
		warnings = warnings,
		info = info,
		checksRun = checksRun,
		durationMs = (os.clock() - t0) * 1000,
	}
end

local function idList(ids: { number }?): string
	if not ids or #ids == 0 then
		return ""
	end
	local shown = {}
	for i = 1, math.min(#ids, 20) do
		shown[i] = tostring(ids[i])
	end
	local s = " [ids: " .. table.concat(shown, ", ")
	if #ids > 20 then
		s ..= string.format(", ... +%d more", #ids - 20)
	end
	return s .. "]"
end

function MapValidator.format(report: Report): string
	local lines = {}
	table.insert(
		lines,
		string.format(
			"[MapValidator] %s - %d error(s), %d warning(s), checks: %s (%.1f ms)",
			if report.ok then "PASS" else "FAIL",
			#report.errors,
			#report.warnings,
			table.concat(report.checksRun, ", "),
			report.durationMs
		)
	)
	for _, e in report.errors do
		table.insert(lines, string.format("  ERROR [%s] %s%s", e.check, e.message, idList(e.ids)))
	end
	for _, w in report.warnings do
		table.insert(lines, string.format("  WARN  [%s] %s%s", w.check, w.message, idList(w.ids)))
	end
	local info = report.info
	if info.terrainCounts then
		local parts = {}
		for _, def in TerrainTypes.List do
			table.insert(parts, string.format("%s=%d", def.id, info.terrainCounts[def.id] or 0))
		end
		table.insert(lines, "  Terrain: " .. table.concat(parts, " "))
	end
	if info.averageNeighbors then
		table.insert(lines, string.format("  Avg neighbours: %.2f  Area coverage: %.6f", info.averageNeighbors, info.areaCoverage or 0))
	end
	if info.landMasses then
		local sizes = {}
		for i, s in info.landMasses do
			sizes[i] = tostring(s)
		end
		table.insert(lines, "  Land masses (territories): " .. table.concat(sizes, ", "))
	end
	if info.continents then
		table.insert(lines, string.format("  Continents: %d  Rivers: %d  Starts: %d", info.continents, info.rivers or 0, info.starts or 0))
	end
	return table.concat(lines, "\n")
end

return MapValidator
