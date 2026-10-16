--!strict
-- MovementGraph (server)
-- Phase 3 navigation layer. Every strategic territory is subdivided into a
-- few smaller MOVEMENT REGIONS (a seeded Voronoi inside the territory
-- polygon). Armies will move region to region; regions are never owned or
-- conquered - each one simply belongs to exactly one territory
-- (`territoryId`), so strategic ownership and navigation stay separate.
--
-- Adjacency:
--   * inside a territory: regions sharing a clipped edge
--   * across territories: regions whose border segments overlap on the
--     shared territory edge (only between territories that are neighbours)
--
-- Region movement data (terrain, cost, passability, road) is derived from
-- the parent territory's terrain. Roads are a placeholder for later phases.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("RoCiv"):WaitForChild("Shared")
local Geometry = require(Shared:WaitForChild("Geometry"))
local MapConfig = require(Shared:WaitForChild("MapConfig"))
local TerrainTypes = require(Shared:WaitForChild("TerrainTypes"))

export type Region = {
	id: number,
	territoryId: number,
	polygon: { Vector2 },
	centroid: Vector2,
	area: number,
	neighbors: { number },
	terrainType: string,
	isWater: boolean,
	moveCost: number,
	passableByLand: boolean,
	passableByNaval: boolean,
	hasRoad: boolean, -- placeholder (roads arrive in a later phase)
}

export type Graph = {
	regions: { [number]: Region },
	regionIds: { number },
	byTerritory: { [number]: { number } },
	maxStep: number, -- longest centroid-to-centroid hop (pathfinding heuristic)
	stats: { [string]: any },
}

local MovementGraph = {}

local BOUNDARY_TAG = 1000000 -- tags >= this mark territory boundary edges

-- Clip a territory polygon into Voronoi cells around `sites`.
local function cellsInside(poly: { Vector2 }, polyTags: { number }, sites: { Vector2 })
	local cells, cellTags = {}, {}
	for i, s in sites do
		local cell = table.clone(poly)
		local tags = table.clone(polyTags)
		for j, o in sites do
			if j ~= i then
				cell, tags = Geometry.clipHalfPlane(cell, tags, (s + o) * 0.5, o - s, j)
			end
		end
		cells[i] = cell
		cellTags[i] = tags
	end
	return cells, cellTags
end

local function samplePoints(poly: { Vector2 }, k: number, rng: Random): { Vector2 }
	local lo, hi = Geometry.bounds(poly)
	local pts = {}
	local guard = 0
	while #pts < k and guard < k * 200 do
		guard += 1
		local p = Vector2.new(rng:NextNumber(lo.X, hi.X), rng:NextNumber(lo.Y, hi.Y))
		if Geometry.pointInConvex(poly, p, 0) then
			table.insert(pts, p)
		end
	end
	if #pts == 0 then
		table.insert(pts, Geometry.centroid(poly))
	end
	return pts
end

function MovementGraph.build(map: any): Graph
	local t0 = os.clock()
	local regions: { [number]: Region } = {}
	local regionIds: { number } = {}
	local byTerritory: { [number]: { number } } = {}
	local minEdge = MapConfig.REGION_MIN_SHARED_EDGE
	-- boundary segments per territory pair: key "a:b" (a<b) -> list of {regionId, territoryId, p, q}
	local boundary: { [string]: { any } } = {}
	local nextId = 1

	for _, tid in map.territoryIds do
		local t = map.territories[tid]
		local def = TerrainTypes.ById[t.terrainType]
		local k = math.clamp(math.floor(t.area / MapConfig.REGION_TARGET_AREA + 0.5), 1, MapConfig.REGION_MAX_PER_TERRITORY)
		local rng = Random.new(map.seed * 31 + tid * 7919)

		-- Territory edges carry BOUNDARY_TAG + neighbour territory id (0 = map edge).
		local polyTags = {}
		for e, tag in t.edgeNeighbors do
			polyTags[e] = BOUNDARY_TAG + tag
		end

		local sites = samplePoints(t.polygon, k, rng)
		for _ = 1, MapConfig.REGION_LLOYD_ITERATIONS do
			local cells = cellsInside(t.polygon, polyTags, sites)
			for i, c in cells do
				if #c >= 3 then
					sites[i] = Geometry.centroid(c)
				end
			end
		end
		local cells, cellTags = cellsInside(t.polygon, polyTags, sites)

		local base = nextId
		local ids = {}
		-- Assign ids first so internal tags (site index) map to region ids.
		local siteToRegion: { [number]: number } = {}
		for i, c in cells do
			if #c >= 3 and Geometry.signedArea(c) > 1e-3 then
				siteToRegion[i] = nextId
				nextId += 1
			end
		end
		for i, c in cells do
			local rid = siteToRegion[i]
			if rid then
				local region: Region = {
					id = rid,
					territoryId = tid,
					polygon = c,
					centroid = Geometry.centroid(c),
					area = Geometry.signedArea(c),
					neighbors = {},
					terrainType = t.terrainType,
					isWater = def.isWater,
					moveCost = def.moveCost,
					passableByLand = def.passableByLand,
					passableByNaval = def.isWater,
					hasRoad = false,
				}
				regions[rid] = region
				table.insert(regionIds, rid)
				table.insert(ids, rid)
				local n = #c
				local seen: { [number]: boolean } = {}
				for e = 1, n do
					local tag = cellTags[i][e]
					local a, b = c[e], c[e % n + 1]
					local len = (b - a).Magnitude
					if tag >= BOUNDARY_TAG then
						local other = tag - BOUNDARY_TAG
						if other > 0 and len > 1e-3 then
							local key = if tid < other then tid .. ":" .. other else other .. ":" .. tid
							boundary[key] = boundary[key] or {}
							table.insert(boundary[key], { region = rid, territory = tid, p = a, q = b })
						end
					elseif len >= minEdge then
						local nb = siteToRegion[tag]
						if nb and not seen[nb] then
							seen[nb] = true
							table.insert(region.neighbors, nb)
						end
					end
				end
			end
		end
		byTerritory[tid] = ids
		local _ = base
	end

	-- Cross-territory links: overlap of boundary segments along the shared edge.
	for key, segs in boundary do
		local parts = string.split(key, ":")
		local ta, tb = tonumber(parts[1]) :: number, tonumber(parts[2]) :: number
		local tA = map.territories[ta]
		if table.find(tA.neighbors, tb) then
			for i = 1, #segs do
				local s1 = segs[i]
				for j = i + 1, #segs do
					local s2 = segs[j]
					if s1.territory ~= s2.territory then
						local dir = s1.q - s1.p
						local len = dir.Magnitude
						if len > 1e-6 then
							local u = dir / len
							local a0, a1 = 0, len
							local b0 = (s2.p - s1.p):Dot(u)
							local b1 = (s2.q - s1.p):Dot(u)
							if b0 > b1 then
								b0, b1 = b1, b0
							end
							local overlap = math.min(a1, b1) - math.max(a0, b0)
							-- Must also be collinear (same territory edge).
							local off = math.abs(Geometry.cross(u, s2.p - s1.p))
							if overlap >= minEdge and off < 0.05 then
								local r1, r2 = regions[s1.region], regions[s2.region]
								if not table.find(r1.neighbors, r2.id) then
									table.insert(r1.neighbors, r2.id)
									table.insert(r2.neighbors, r1.id)
								end
							end
						end
					end
				end
			end
		end
	end

	local maxStep = 0
	for _, rid in regionIds do
		local r = regions[rid]
		table.sort(r.neighbors)
		for _, nb in r.neighbors do
			maxStep = math.max(maxStep, (regions[nb].centroid - r.centroid).Magnitude)
		end
	end

	return {
		regions = regions,
		regionIds = regionIds,
		byTerritory = byTerritory,
		maxStep = maxStep,
		stats = { buildMs = (os.clock() - t0) * 1000, regionCount = #regionIds },
	}
end

-- Validation ---------------------------------------------------------------

function MovementGraph.validate(graph: Graph, map: any): (boolean, { string }, { [string]: any })
	local problems: { string } = {}
	local info: { [string]: any } = {}
	local function bad(msg: string)
		if #problems < 40 then
			table.insert(problems, msg)
		end
	end
	local regions = graph.regions

	-- Geometry and parent territory.
	for tid, ids in graph.byTerritory do
		local t = map.territories[tid]
		if #ids == 0 then
			bad("territory " .. tid .. " has no movement regions")
		end
		local sum = 0
		for _, rid in ids do
			local r = regions[rid]
			if r.territoryId ~= tid then
				bad("region " .. rid .. " has wrong territoryId")
			end
			if not Geometry.isConvexCCW(r.polygon) then
				bad("region " .. rid .. " polygon invalid")
			end
			if not Geometry.pointInConvex(t.polygon, r.centroid, 0.01) then
				bad("region " .. rid .. " centroid outside territory " .. tid)
			end
			sum += r.area
		end
		if t and math.abs(sum - t.area) / t.area > 1e-4 then
			bad(string.format("territory %d regions cover %.5f of its area", tid, sum / t.area))
		end
	end

	-- Neighbour lists.
	for _, rid in graph.regionIds do
		local r = regions[rid]
		local seen = {}
		for _, nb in r.neighbors do
			local o = regions[nb]
			if not o then
				bad("region " .. rid .. " lists missing region " .. nb)
			elseif nb == rid then
				bad("region " .. rid .. " lists itself")
			elseif seen[nb] then
				bad("region " .. rid .. " duplicate neighbour " .. nb)
			elseif not table.find(o.neighbors, rid) then
				bad("one-way link " .. rid .. " -> " .. nb)
			elseif o.territoryId ~= r.territoryId and not table.find(map.territories[r.territoryId].neighbors, o.territoryId) then
				bad(string.format("regions %d/%d link non-neighbouring territories", rid, nb))
			end
			seen[nb] = true
		end
		if #r.neighbors == 0 then
			bad("isolated region " .. rid)
		end
	end

	-- Each territory's regions are internally connected.
	for tid, ids in graph.byTerritory do
		if #ids > 0 then
			local inT = {}
			for _, rid in ids do
				inT[rid] = true
			end
			local visited = { [ids[1]] = true }
			local q, h = { ids[1] }, 1
			while h <= #q do
				local cur = q[h]
				h += 1
				for _, nb in regions[cur].neighbors do
					if inT[nb] and not visited[nb] then
						visited[nb] = true
						table.insert(q, nb)
					end
				end
			end
			if #q ~= #ids then
				bad(string.format("territory %d regions not internally connected (%d/%d)", tid, #q, #ids))
			end
		end
	end

	-- Every territory adjacency has at least one region-level crossing.
	local crossings: { [string]: boolean } = {}
	for _, rid in graph.regionIds do
		local r = regions[rid]
		for _, nb in r.neighbors do
			local o = regions[nb]
			if o.territoryId ~= r.territoryId then
				crossings[math.min(r.territoryId, o.territoryId) .. ":" .. math.max(r.territoryId, o.territoryId)] = true
			end
		end
	end
	local missingCrossings = 0
	for _, tid in map.territoryIds do
		for _, nb in map.territories[tid].neighbors do
			if tid < nb and not crossings[tid .. ":" .. nb] then
				missingCrossings += 1
				bad(string.format("territories %d and %d are neighbours but no regions connect", tid, nb))
			end
		end
	end

	-- Whole graph connected.
	if #graph.regionIds > 0 then
		local visited = { [graph.regionIds[1]] = true }
		local q, h = { graph.regionIds[1] }, 1
		while h <= #q do
			local cur = q[h]
			h += 1
			for _, nb in regions[cur].neighbors do
				if not visited[nb] then
					visited[nb] = true
					table.insert(q, nb)
				end
			end
		end
		if #q ~= #graph.regionIds then
			bad(string.format("movement graph disconnected (%d/%d reachable)", #q, #graph.regionIds))
		end
	end

	local degree = 0
	for _, rid in graph.regionIds do
		degree += #regions[rid].neighbors
	end
	info.regionCount = #graph.regionIds
	info.averageNeighbors = degree / math.max(#graph.regionIds, 1)
	info.missingCrossings = missingCrossings
	return #problems == 0, problems, info
end

return MovementGraph
