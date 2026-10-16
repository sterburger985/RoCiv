--!strict
-- MapGenerator
-- Deterministic procedural generator for RoCiv's strategic territories.
--
-- Pipeline:
--   1. Scatter N seed points with Random.new(seed).
--   2. Lloyd relaxation (Voronoi -> move each point to its cell centroid).
--   3. Final Voronoi cells via half-plane clipping of the map rectangle
--      (grid-accelerated). Every clipped edge is tagged with the site that
--      produced it, which gives exact shared-edge adjacency for free.
--   4. Geography: an elevation field built from shaped continents (domain-
--      warped ellipses) plus peninsulas, bays, archipelagos and ridged
--      mountain chains; moisture and latitude noise.
--   5. Terrain rules: sea level by quantile, edge ocean, lakes (small inland
--      water bodies), coast, mountains, tundra, desert / plains / grassland
--      / forest.
--   6. Rivers (downhill across territories to the sea or a lake) and start
--      positions for the match size's civilizations.
--   7. The continent count is checked; if the map misses its target, it is
--      regenerated with a deterministically derived seed (attempts recorded).
--
-- The generator is pure: it touches no Instances and returns plain data.
-- It lives on the server so clients cannot regenerate hidden map data.
-- The same seed + match size always produce the same logical map.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("RoCiv"):WaitForChild("Shared")
local Geometry = require(Shared:WaitForChild("Geometry"))
local MapConfig = require(Shared:WaitForChild("MapConfig"))
local TerrainTypes = require(Shared:WaitForChild("TerrainTypes"))

export type Territory = {
	id: number,
	site: Vector2,
	centroid: Vector2,
	polygon: { Vector2 },
	edgeNeighbors: { number }, -- per polygon edge: neighbour id or 0 (map boundary)
	area: number,
	neighbors: { number },
	terrainType: string,
	isWater: boolean,
	elevation: number, -- 0..1
	fertility: number, -- 0..1
	moisture: number, -- 0..1
	latitude: number, -- 0 (equator) .. 1 (pole)
	landmassId: number, -- 0 for water
	riverPath: { Vector2 }?, -- river polyline inside this territory (if any)
	riverId: number?,
	resources: { any }, -- placeholder (resource phase)
	ownerId: number?, -- civilizationId, nil = unowned (change only via TerritorySystem)
	cityId: number?, -- nil = no city
	developmentData: { [string]: any }, -- placeholder for future improvements
	movementMetadata: {
		moveCost: number,
		passableByLand: boolean,
		isWater: boolean,
	},
}

export type River = { id: number, territoryIds: { number }, mouth: number }

export type MapData = {
	seed: number,
	baseSeed: number,
	attempt: number,
	matchSize: string,
	civilizations: number,
	territoryCount: number,
	width: number,
	height: number,
	seaLevel: number,
	mountainLevel: number,
	territories: { [number]: Territory },
	territoryIds: { number },
	landmasses: { { id: number, size: number, isContinent: boolean } },
	continentCount: number,
	rivers: { River },
	startPositions: { number }, -- territory ids, one per civilization (server only)
	stats: { [string]: any },
}

export type GenerateOptions = {
	seed: number?,
	matchSize: string?,
	territoryCount: number?, -- overrides the match size's count (dev/testing)
	width: number?,
	height: number?,
}

local MapGenerator = {}

-- Voronoi ----------------------------------------------------------------

-- Grid-accelerated Voronoi: each cell is clipped only by nearby sites. The
-- search radius grows until it provably covers every site that could cut
-- the cell (any cutting site lies within 2 * the cell's max vertex radius).
local function computeCells(sites: { Vector2 }, width: number, height: number)
	local n = #sites
	local polys = table.create(n)
	local tagsList = table.create(n)
	local corners = {
		Vector2.new(0, 0),
		Vector2.new(width, 0),
		Vector2.new(width, height),
		Vector2.new(0, height),
	}
	local cell = math.sqrt(width * height / math.max(n, 1))
	local cols = math.max(1, math.ceil(width / cell))
	local rows = math.max(1, math.ceil(height / cell))
	local grid: { [number]: { number } } = {}
	for i, s in sites do
		local cx = math.clamp(math.floor(s.X / cell), 0, cols - 1)
		local cy = math.clamp(math.floor(s.Y / cell), 0, rows - 1)
		local key = cy * cols + cx
		grid[key] = grid[key] or {}
		table.insert(grid[key], i)
	end

	for i = 1, n do
		local s = sites[i]
		local scx = math.clamp(math.floor(s.X / cell), 0, cols - 1)
		local scy = math.clamp(math.floor(s.Y / cell), 0, rows - 1)
		local r = 2
		local poly, tags
		while true do
			local order = {}
			local dist2 = {}
			for gy = math.max(0, scy - r), math.min(rows - 1, scy + r) do
				for gx = math.max(0, scx - r), math.min(cols - 1, scx + r) do
					local bucket = grid[gy * cols + gx]
					if bucket then
						for _, j in bucket do
							if j ~= i then
								local d = sites[j] - s
								dist2[j] = d.X * d.X + d.Y * d.Y
								table.insert(order, j)
							end
						end
					end
				end
			end
			table.sort(order, function(a, b)
				local da, db = dist2[a], dist2[b]
				if da == db then
					return a < b
				end
				return da < db
			end)
			poly = table.clone(corners)
			tags = { 0, 0, 0, 0 }
			local maxR2 = 0
			for _, p in poly do
				local d = p - s
				maxR2 = math.max(maxR2, d.X * d.X + d.Y * d.Y)
			end
			for _, j in order do
				if dist2[j] * 0.25 > maxR2 then
					break
				end
				local o = sites[j]
				poly, tags = Geometry.clipHalfPlane(poly, tags, (s + o) * 0.5, o - s, j)
				maxR2 = 0
				for _, p in poly do
					local d = p - s
					maxR2 = math.max(maxR2, d.X * d.X + d.Y * d.Y)
				end
			end
			local searchedAll = scx - r <= 0 and scy - r <= 0 and scx + r >= cols - 1 and scy + r >= rows - 1
			-- Squares clipped by the map edge still cover the whole edge side.
			local coverX0 = if scx - r <= 0 then math.huge else s.X - (scx - r) * cell
			local coverX1 = if scx + r >= cols - 1 then math.huge else (scx + r + 1) * cell - s.X
			local coverY0 = if scy - r <= 0 then math.huge else s.Y - (scy - r) * cell
			local coverY1 = if scy + r >= rows - 1 then math.huge else (scy + r + 1) * cell - s.Y
			local covered = math.min(coverX0, coverX1, coverY0, coverY1)
			if searchedAll or 2 * math.sqrt(maxR2) <= covered then
				break
			end
			r += 2
		end
		polys[i] = poly
		tagsList[i] = tags
	end
	return polys, tagsList
end

-- Noise and helpers ------------------------------------------------------------

local function fbm(x: number, y: number, z: number, octaves: number): number
	local total, amp, freq, norm = 0, 1, 1, 0
	for _ = 1, octaves do
		total += math.noise(x * freq, y * freq, z) * amp
		norm += amp
		amp *= 0.5
		freq *= 2
	end
	return total / norm -- roughly -0.5..0.5
end

-- Ridged noise: 1 along "ridges", 0 elsewhere (mountain chains).
local function ridged(x: number, y: number, z: number): number
	local n = 1 - math.abs(math.noise(x, y, z) * 2)
	n = math.clamp(n, 0, 1)
	return n * n
end

local function clamp01(v: number): number
	return math.clamp(v, 0, 1)
end

local function smoothstep(e0: number, e1: number, x: number): number
	local t = clamp01((x - e0) / (e1 - e0))
	return t * t * (3 - 2 * t)
end

local function quantile(values: { number }, q: number): number
	if #values == 0 then
		return 0
	end
	local sorted = table.clone(values)
	table.sort(sorted)
	local idx = math.clamp(math.floor(q * (#sorted - 1) + 0.5) + 1, 1, #sorted)
	return sorted[idx]
end

local function segDist(p: Vector2, a: Vector2, b: Vector2): number
	local ab = b - a
	local len2 = ab:Dot(ab)
	if len2 < 1e-9 then
		return (p - a).Magnitude
	end
	local t = math.clamp((p - a):Dot(ab) / len2, 0, 1)
	return (p - (a + ab * t)).Magnitude
end

function MapGenerator.matchSizeDef(name: string?): any
	local key = name or MapConfig.DEFAULT_MATCH_SIZE
	return MapConfig.MATCH_SIZES[key] or MapConfig.MATCH_SIZES[MapConfig.DEFAULT_MATCH_SIZE]
end

-- Geography field ----------------------------------------------------------------
-- All shapes work in normalised coordinates: u in [0, aspect], v in [0, 1].

type Shape = { kind: string, a: Vector2, b: Vector2?, rx: number, ry: number, rot: number, strength: number, owner: number }

local function buildShapes(rng: Random, def: any, aspect: number)
	local shapes: { Shape } = {}
	local bays: { Shape } = {}
	local k = rng:NextInteger(def.continents[1], def.continents[2])
	-- Continent centres: spread out with rejection sampling.
	local centres: { Vector2 } = {}
	local minSep = 0.9 / math.sqrt(k) -- in v units
	local guard = 0
	while #centres < k and guard < 4000 do
		guard += 1
		local c = Vector2.new(rng:NextNumber(0.2, aspect - 0.2), rng:NextNumber(0.22, 0.78))
		local ok = true
		for _, o in centres do
			if (c - o).Magnitude < minSep then
				ok = false
				break
			end
		end
		if ok then
			table.insert(centres, c)
		end
		if guard % 500 == 0 then
			minSep *= 0.9 -- relax if the map is crowded
		end
	end
	local landArea = aspect * def.landFraction
	for ci, c in centres do
		-- Each continent gets a similar share of the land; vary it a little.
		local share = landArea / #centres * rng:NextNumber(0.8, 1.25)
		local elong = rng:NextNumber(1.1, 1.9)
		local ry = math.sqrt(share / (math.pi * elong)) * 1.15
		local rx = ry * elong
		local rot = rng:NextNumber(0, math.pi)
		table.insert(shapes, { kind = "Continent", a = c, rx = rx, ry = ry, rot = rot, strength = 1, owner = ci })

		-- Peninsulas: capsules reaching out from the coast.
		for _ = 1, rng:NextInteger(def.peninsulas[1], def.peninsulas[2]) do
			local ang = rng:NextNumber(0, math.pi * 2)
			local dir = Vector2.new(math.cos(ang), math.sin(ang))
			local edge = c + Vector2.new(dir.X * rx * math.cos(rot) - dir.Y * ry * math.sin(rot), dir.X * rx * math.sin(rot) + dir.Y * ry * math.cos(rot)) * 0.75
			local outward = (edge - c).Unit
			local len = ry * rng:NextNumber(0.7, 1.2)
			local bend = Vector2.new(-outward.Y, outward.X) * rng:NextNumber(-0.3, 0.3)
			local tip = edge + (outward + bend).Unit * len
			table.insert(shapes, { kind = "Peninsula", a = edge, b = tip, rx = ry * rng:NextNumber(0.18, 0.28), ry = 0, rot = 0, strength = 0.85, owner = ci })
		end
		-- Bays: notches cut into the coast.
		for _ = 1, rng:NextInteger(def.bays[1], def.bays[2]) do
			local ang = rng:NextNumber(0, math.pi * 2)
			local dir = Vector2.new(math.cos(ang), math.sin(ang))
			local edge = c + Vector2.new(dir.X * rx * math.cos(rot) - dir.Y * ry * math.sin(rot), dir.X * rx * math.sin(rot) + dir.Y * ry * math.cos(rot)) * 0.92
			table.insert(bays, { kind = "Bay", a = edge, rx = ry * rng:NextNumber(0.25, 0.4), ry = 0, rot = 0, strength = 1.1, owner = 0 })
		end
	end
	-- Archipelagos: clusters of small islands away from the continents.
	local islands: { Shape } = {}
	for cluster = 1, def.islandClusters do
		local centre: Vector2? = nil
		for _ = 1, 200 do
			local c = Vector2.new(rng:NextNumber(0.1, aspect - 0.1), rng:NextNumber(0.12, 0.88))
			local far = true
			for _, sh in shapes do
				if sh.kind == "Continent" and (c - sh.a).Magnitude < math.max(sh.rx, sh.ry) * 1.25 then
					far = false
					break
				end
			end
			if far then
				centre = c
				break
			end
		end
		if centre then
			for _ = 1, rng:NextInteger(4, 7) do
				local p = centre + Vector2.new(rng:NextNumber(-0.11, 0.11), rng:NextNumber(-0.09, 0.09))
				table.insert(islands, { kind = "Island", a = p, rx = rng:NextNumber(0.022, 0.04), ry = 0, rot = 0, strength = 0.75, owner = 100 + cluster })
			end
		end
	end
	return shapes, bays, islands, #centres
end

local function sampleElevation(p: Vector2, shapes: { Shape }, bays: { Shape }, islands: { Shape }, noiseOff: Vector3, aspect: number): (number, number)
	-- Domain warp gives coasts an organic outline.
	local wx = fbm(p.X * 3.1 + noiseOff.X, p.Y * 3.1 + noiseOff.Y, noiseOff.Z, 3) * 0.12
	local wy = fbm(p.X * 3.1 + noiseOff.Y, p.Y * 3.1 + noiseOff.X, noiseOff.Z + 11, 3) * 0.12
	local q = p + Vector2.new(wx, wy)
	local e = -0.6
	local owner = 0
	for _, sh in shapes do
		local v
		if sh.kind == "Continent" then
			local d = q - sh.a
			local cs, sn = math.cos(-sh.rot), math.sin(-sh.rot)
			local lx = d.X * cs - d.Y * sn
			local ly = d.X * sn + d.Y * cs
			local r = math.sqrt((lx / sh.rx) ^ 2 + (ly / sh.ry) ^ 2)
			v = (1 - r) * sh.strength
		else -- Peninsula capsule
			v = (1 - segDist(q, sh.a, sh.b :: Vector2) / sh.rx) * sh.strength * 0.7
		end
		if v > e then
			e = v
			owner = sh.owner
		end
	end
	for _, sh in islands do
		local v = (1 - (q - sh.a).Magnitude / sh.rx) * sh.strength
		if v > e then
			e = v
			owner = sh.owner
		end
	end
	for _, sh in bays do
		local d = (q - sh.a).Magnitude / sh.rx
		if d < 1 then
			e -= (1 - d) * (1 - d) * sh.strength
		end
	end
	-- Detail noise and mountain chains (ridges only on land).
	e += fbm(p.X * 5 + noiseOff.Z, p.Y * 5 + noiseOff.X, noiseOff.Y, 4) * 0.35
	if e > 0 then
		e += ridged(p.X * 3.2 + noiseOff.Y, p.Y * 3.2 + noiseOff.Z, noiseOff.X) * 0.45 * math.clamp(e * 3, 0, 1)
	end
	-- Ocean ring at the map edge.
	local dx = math.min(p.X, aspect - p.X) / aspect
	local dy = math.min(p.Y, 1 - p.Y)
	local edge = math.min(dx * 2.2, dy)
	e -= (1 - smoothstep(0.0, 0.12, edge)) * 1.2
	return e, owner
end

-- Landmasses ----------------------------------------------------------------------

local function labelLandmasses(territories: { [number]: Territory }, ids: { number })
	local masses = {}
	for _, id in ids do
		territories[id].landmassId = 0
	end
	local nextId = 0
	for _, id in ids do
		local t = territories[id]
		if not t.isWater and t.landmassId == 0 then
			nextId += 1
			t.landmassId = nextId
			local q, h = { id }, 1
			while h <= #q do
				local cur = q[h]
				h += 1
				for _, nb in territories[cur].neighbors do
					local o = territories[nb]
					if not o.isWater and o.landmassId == 0 then
						o.landmassId = nextId
						table.insert(q, nb)
					end
				end
			end
			table.insert(masses, { id = nextId, size = #q, isContinent = false })
		end
	end
	local land = 0
	for _, m in masses do
		land += m.size
	end
	local continents = 0
	for _, m in masses do
		m.isContinent = m.size >= MapConfig.CONTINENT_MIN_TERRITORIES and m.size >= land * MapConfig.CONTINENT_MIN_LAND_SHARE
		if m.isContinent then
			continents += 1
		end
	end
	table.sort(masses, function(a, b)
		return a.size > b.size
	end)
	return masses, continents
end

-- Hop distances over land from a set of sources.
local function landDistances(territories: { [number]: Territory }, sources: { number }): { [number]: number }
	local dist: { [number]: number } = {}
	local q = {}
	for _, s in sources do
		dist[s] = 0
		table.insert(q, s)
	end
	local h = 1
	while h <= #q do
		local cur = q[h]
		h += 1
		for _, nb in territories[cur].neighbors do
			if dist[nb] == nil and not territories[nb].isWater then
				dist[nb] = dist[cur] + 1
				table.insert(q, nb)
			end
		end
	end
	return dist
end

-- Generation ---------------------------------------------------------------

local function generateOnce(seed: number, def: any, count: number, width: number, height: number)
	local t0 = os.clock()
	local rng = Random.new(seed)
	local aspect = width / height

	-- 1. Seed points (kept slightly away from the edges).
	local margin = 0.01
	local sites: { Vector2 } = table.create(count)
	for i = 1, count do
		sites[i] = Vector2.new(rng:NextNumber(width * margin, width * (1 - margin)), rng:NextNumber(height * margin, height * (1 - margin)))
	end

	-- 2. Lloyd relaxation.
	for _ = 1, MapConfig.LLOYD_ITERATIONS do
		local polys = computeCells(sites, width, height)
		for i = 1, count do
			sites[i] = Geometry.centroid(polys[i])
		end
	end

	-- 3. Final cells.
	local polys, tagsList = computeCells(sites, width, height)
	local tVoronoi = os.clock()

	-- Territory ids are explicit, stable values stored on the record.
	local territories: { [number]: Territory } = {}
	local ids: { number } = table.create(count)
	for i = 1, count do
		local poly = polys[i]
		ids[i] = i
		territories[i] = {
			id = i,
			site = sites[i],
			centroid = Geometry.centroid(poly),
			polygon = poly,
			edgeNeighbors = tagsList[i],
			area = Geometry.signedArea(poly),
			neighbors = {},
			terrainType = "Ocean",
			isWater = true,
			elevation = 0,
			fertility = 0,
			moisture = 0,
			latitude = 0,
			landmassId = 0,
			riverPath = nil,
			riverId = nil,
			resources = {},
			ownerId = nil,
			cityId = nil,
			developmentData = {},
			movementMetadata = { moveCost = 1, passableByLand = false, isWater = true },
		}
	end

	-- Adjacency from tagged shared edges.
	local minEdge = MapConfig.MIN_SHARED_EDGE_LENGTH
	local touchesEdge: { [number]: boolean } = {}
	for _, id in ids do
		local t = territories[id]
		local poly = t.polygon
		local n = #poly
		local seen: { [number]: boolean } = {}
		for e = 1, n do
			local other = t.edgeNeighbors[e]
			if other == 0 then
				touchesEdge[id] = true
			elseif not seen[other] then
				local len = (poly[e % n + 1] - poly[e]).Magnitude
				if len >= minEdge then
					seen[other] = true
					table.insert(t.neighbors, other)
				end
			end
		end
		table.sort(t.neighbors)
	end
	for _, id in ids do
		local t = territories[id]
		local kept = {}
		for _, nb in t.neighbors do
			if table.find(territories[nb].neighbors, id) then
				table.insert(kept, nb)
			end
		end
		t.neighbors = kept
	end

	-- 4. Geography field.
	local shapes, bays, islands, continentTarget = buildShapes(rng, def, aspect)
	local noiseOff = Vector3.new(rng:NextNumber(-500, 500), rng:NextNumber(-500, 500), rng:NextNumber(0, 100))
	local mx, my, mz = rng:NextNumber(-10000, 10000), rng:NextNumber(-10000, 10000), rng:NextNumber(0, 100)
	local tundraJitter = {}
	local rawElev: { [number]: number } = {}
	local shapeOwner: { [number]: number } = {}
	local minE, maxE = math.huge, -math.huge
	for _, id in ids do
		local t = territories[id]
		local p = Vector2.new(t.centroid.X / height, t.centroid.Y / height) -- u in [0, aspect]
		local e, owner = sampleElevation(p, shapes, bays, islands, noiseOff, aspect)
		rawElev[id] = e
		shapeOwner[id] = owner
		minE = math.min(minE, e)
		maxE = math.max(maxE, e)
		local nx, ny = t.centroid.X / width, t.centroid.Y / height
		local m = fbm(nx * MapConfig.MOISTURE_FREQUENCY * aspect + mx, ny * MapConfig.MOISTURE_FREQUENCY + my, mz, MapConfig.MOISTURE_OCTAVES)
		t.moisture = clamp01(0.5 + m * 1.6)
		t.latitude = math.abs(ny - 0.5) * 2
		tundraJitter[id] = rng:NextNumber(-1, 1) * MapConfig.TUNDRA_LATITUDE_JITTER
	end
	local range = math.max(maxE - minE, 1e-6)
	local elevList = {}
	for _, id in ids do
		local v = (rawElev[id] - minE) / range
		territories[id].elevation = v
		table.insert(elevList, v)
	end

	-- 5. Terrain.
	local seaLevel = quantile(elevList, 1 - def.landFraction)
	for _, id in ids do
		local t = territories[id]
		if touchesEdge[id] and t.elevation >= seaLevel then
			t.elevation = math.max(0, seaLevel - 0.001)
		end
		t.isWater = t.elevation < seaLevel
	end
	-- Keep continents apart: where land of two different shapes (continents
	-- or archipelagos) touches, the lower side becomes sea. This guarantees
	-- the match size's continent count instead of noise merging them.
	local straits = 0
	for _, id in ids do
		local t = territories[id]
		if not t.isWater then
			for _, nb in t.neighbors do
				local o = territories[nb]
				if not o.isWater and shapeOwner[nb] ~= shapeOwner[id] then
					local low = if o.elevation < t.elevation or (o.elevation == t.elevation and nb < id) then o else t
					low.isWater = true
					low.elevation = math.max(0, seaLevel - 0.001)
					straits += 1
					if low == t then
						break
					end
				end
			end
		end
	end

	-- Water bodies not connected to the outer ocean: small ones become
	-- Lakes, large ones are filled to land.
	local reached: { [number]: boolean } = {}
	local queue = {}
	for _, id in ids do
		if territories[id].isWater and touchesEdge[id] then
			reached[id] = true
			table.insert(queue, id)
		end
	end
	local head = 1
	while head <= #queue do
		local id = queue[head]
		head += 1
		for _, nb in territories[id].neighbors do
			if not reached[nb] and territories[nb].isWater then
				reached[nb] = true
				table.insert(queue, nb)
			end
		end
	end
	local isLake: { [number]: boolean } = {}
	local lakesFilled = 0
	local seenInland: { [number]: boolean } = {}
	for _, id in ids do
		if territories[id].isWater and not reached[id] and not seenInland[id] then
			local body, q2, h2 = {}, { id }, 1
			seenInland[id] = true
			while h2 <= #q2 do
				local cur = q2[h2]
				h2 += 1
				table.insert(body, cur)
				for _, nb in territories[cur].neighbors do
					if territories[nb].isWater and not reached[nb] and not seenInland[nb] then
						seenInland[nb] = true
						table.insert(q2, nb)
					end
				end
			end
			if #body <= MapConfig.LAKE_MAX_TERRITORIES then
				for _, b in body do
					isLake[b] = true
				end
			else
				for _, b in body do
					territories[b].isWater = false
					territories[b].elevation = seaLevel
					lakesFilled += 1
				end
			end
		end
	end
	-- Extra lakes in damp lowland basins (local minima away from the coast).
	local lakeCandidates = {}
	for _, id in ids do
		local t = territories[id]
		if not t.isWater and t.moisture > 0.55 and t.latitude < 0.7 then
			local lowest, inland = true, true
			for _, nb in t.neighbors do
				local o = territories[nb]
				if o.isWater then
					inland = false
				elseif o.elevation < t.elevation then
					lowest = false
				end
			end
			if lowest and inland then
				table.insert(lakeCandidates, id)
			end
		end
	end
	local lakesAdded = 0
	for _, id in lakeCandidates do
		if lakesAdded >= def.lakes then
			break
		end
		-- Don't place lakes next to other lakes (keeps them distinct).
		local nearLake = false
		for _, nb in territories[id].neighbors do
			if isLake[nb] then
				nearLake = true
			end
		end
		if not nearLake then
			territories[id].isWater = true
			isLake[id] = true
			lakesAdded += 1
		end
	end

	-- Mountain level = top MOUNTAIN_FRACTION of land elevations.
	local landElev = {}
	for _, id in ids do
		if not territories[id].isWater then
			table.insert(landElev, territories[id].elevation)
		end
	end
	local mountainLevel = if #landElev > 0 then quantile(landElev, 1 - MapConfig.MOUNTAIN_FRACTION) else 2

	for _, id in ids do
		local t = territories[id]
		local nearWater, nearLand = false, false
		for _, nb in t.neighbors do
			if territories[nb].isWater then
				nearWater = true
			else
				nearLand = true
			end
		end
		local terrain: string
		if isLake[id] then
			terrain = "Lake"
		elseif t.isWater then
			terrain = if nearLand then "Coast" else "Ocean"
		else
			local moisture = clamp01(t.moisture + (if nearWater then MapConfig.MOISTURE_WATER_BONUS else 0))
			t.moisture = moisture
			if t.elevation >= mountainLevel then
				terrain = "Mountains"
			elseif t.latitude >= MapConfig.TUNDRA_LATITUDE + tundraJitter[id] then
				terrain = "Tundra"
			elseif moisture < MapConfig.DESERT_MOISTURE and t.latitude < MapConfig.DESERT_MAX_LATITUDE then
				terrain = "Desert"
			elseif moisture > MapConfig.FOREST_MOISTURE then
				terrain = "Forest"
			elseif moisture > MapConfig.GRASSLAND_MOISTURE then
				terrain = "Grassland"
			else
				terrain = "Plains"
			end
		end
		t.terrainType = terrain
	end

	local masses, continents = labelLandmasses(territories, ids)

	-- 6a. Rivers: downhill from high damp land to water.
	local rivers: { River } = {}
	local hasRiver: { [number]: boolean } = {}
	local sources = {}
	local highLand = if #landElev > 0 then quantile(landElev, 0.55) else 2
	for _, id in ids do
		local t = territories[id]
		if not t.isWater and t.elevation >= highLand and t.moisture > 0.35 and t.terrainType ~= "Desert" then
			table.insert(sources, id)
		end
	end
	-- Deterministic shuffle.
	for i = #sources, 2, -1 do
		local j = rng:NextInteger(1, i)
		sources[i], sources[j] = sources[j], sources[i]
	end
	for _, src in sources do
		if #rivers >= def.rivers then
			break
		end
		if not hasRiver[src] then
			local path = { src }
			local cur = src
			local mouth = nil
			local guard = 0
			while guard < 60 do
				guard += 1
				local t = territories[cur]
				local best, bestE = nil, t.elevation
				local water = nil
				for _, nb in t.neighbors do
					local o = territories[nb]
					if o.isWater then
						if not water or o.elevation < territories[water].elevation then
							water = nb
						end
					elseif o.elevation < bestE and not hasRiver[nb] and not table.find(path, nb) then
						best, bestE = nb, o.elevation
					end
				end
				if water then
					mouth = water
					break
				elseif best then
					table.insert(path, best)
					cur = best
				else
					break
				end
			end
			-- A river must reach water and cross enough land; mountains may
			-- only be the source.
			local valid = mouth ~= nil and #path >= MapConfig.RIVER_MIN_LENGTH
			for i = 2, #path do
				if territories[path[i]].terrainType == "Mountains" then
					valid = false
				end
			end
			if valid then
				local rid = #rivers + 1
				table.insert(rivers, { id = rid, territoryIds = path, mouth = mouth :: number })
				for _, tid in path do
					hasRiver[tid] = true
				end
			end
		end
	end
	-- River geometry: centroid -> shared-edge midpoint -> next centroid,
	-- with a little meander. Each territory stores only its own piece.
	local function sharedEdgeMid(a: number, b: number): Vector2
		local t = territories[a]
		local n = #t.polygon
		for e = 1, n do
			if t.edgeNeighbors[e] == b then
				local p, q = t.polygon[e], t.polygon[e % n + 1]
				return p:Lerp(q, rng:NextNumber(0.35, 0.65))
			end
		end
		return (t.centroid + territories[b].centroid) * 0.5
	end
	local function meander(a: Vector2, b: Vector2): Vector2
		local mid = (a + b) * 0.5
		local d = b - a
		local perp = Vector2.new(-d.Y, d.X).Unit
		return mid + perp * d.Magnitude * rng:NextNumber(-0.18, 0.18)
	end
	for _, river in rivers do
		local path = river.territoryIds
		local mids = {}
		for i = 1, #path do
			local nextId = path[i + 1] or river.mouth
			mids[i] = sharedEdgeMid(path[i], nextId)
		end
		for i, tid in path do
			local t = territories[tid]
			local c = t.centroid:Lerp(Geometry.centroid(t.polygon), 0.5)
			local pts = {}
			if i > 1 then
				table.insert(pts, mids[i - 1])
				table.insert(pts, meander(mids[i - 1], c))
			end
			table.insert(pts, c)
			table.insert(pts, meander(c, mids[i]))
			table.insert(pts, mids[i])
			t.riverPath = pts
			t.riverId = river.id
		end
	end

	-- Fertility and movement metadata.
	for _, id in ids do
		local t = territories[id]
		local def2 = TerrainTypes.ById[t.terrainType]
		local fert = def2.baseFertility + (t.moisture - 0.5) * 0.3 + rng:NextNumber(-0.05, 0.05)
		if hasRiver[id] then
			fert += MapConfig.RIVER_FERTILITY_BONUS
		end
		t.fertility = clamp01(fert)
		t.movementMetadata = { moveCost = def2.moveCost, passableByLand = def2.passableByLand, isWater = def2.isWater }
	end

	-- 6b. Start positions on continents, spread apart.
	local function startScore(id: number): number
		local t = territories[id]
		if t.isWater or t.terrainType == "Mountains" or t.terrainType == "Tundra" or t.terrainType == "Desert" then
			return -1
		end
		local d = landDistances(territories, { id })
		local near = 0
		for _, hops in d do
			if hops <= 2 then
				near += 1
			end
		end
		return near + t.fertility * 4 + (if hasRiver[id] then 2 else 0)
	end
	local continentIds = {}
	for _, m in masses do
		if m.isContinent then
			table.insert(continentIds, m.id)
		end
	end
	if #continentIds == 0 and #masses > 0 then
		table.insert(continentIds, masses[1].id)
	end
	local candidatesBy: { [number]: { number } } = {}
	for _, id in ids do
		local lm = territories[id].landmassId
		if lm > 0 and table.find(continentIds, lm) and startScore(id) >= 6 then
			candidatesBy[lm] = candidatesBy[lm] or {}
			table.insert(candidatesBy[lm], id)
		end
	end
	local starts: { number } = {}
	local civs = def.civilizations
	for i = 1, civs do
		-- Round-robin over continents (largest first) so starts span them.
		local lm = continentIds[(i - 1) % #continentIds + 1]
		local pool = candidatesBy[lm] or {}
		if #pool == 0 then
			-- Fall back to any continent candidate.
			for _, l in continentIds do
				if candidatesBy[l] and #candidatesBy[l] > 0 then
					pool = candidatesBy[l]
					break
				end
			end
		end
		local best, bestScore = nil, -math.huge
		local distFromStarts = if #starts > 0 then landDistances(territories, starts) else {}
		for _, id in pool do
			if not table.find(starts, id) then
				local hops = distFromStarts[id] or 99 -- other landmass = far
				if hops >= MapConfig.START_MIN_SPACING then
					local score = math.min(hops, 12) * 3 + startScore(id)
					if score > bestScore then
						best, bestScore = id, score
					end
				end
			end
		end
		if best then
			table.insert(starts, best)
		end
	end

	local t1 = os.clock()
	local terrainCounts = {}
	for _, id in ids do
		local tt = territories[id].terrainType
		terrainCounts[tt] = (terrainCounts[tt] or 0) + 1
	end
	return {
		territories = territories,
		ids = ids,
		seaLevel = seaLevel,
		mountainLevel = mountainLevel,
		masses = masses,
		continents = continents,
		continentTarget = continentTarget,
		rivers = rivers,
		starts = starts,
		stats = {
			voronoiMs = (tVoronoi - t0) * 1000,
			totalMs = (t1 - t0) * 1000,
			lakesFilled = lakesFilled,
			lakes = lakesAdded,
			straits = straits,
			terrainCounts = terrainCounts,
		},
	}
end

function MapGenerator.generate(options: GenerateOptions?): MapData
	local opts = options or {}
	local t0 = os.clock()
	local baseSeed = math.floor(opts.seed or MapConfig.DEFAULT_SEED)
	local sizeName = if opts.matchSize and MapConfig.MATCH_SIZES[opts.matchSize] then opts.matchSize else MapConfig.DEFAULT_MATCH_SIZE
	local def = MapGenerator.matchSizeDef(sizeName)
	local count = math.clamp(math.floor(opts.territoryCount or def.territories), MapConfig.MIN_TERRITORY_COUNT, MapConfig.MAX_TERRITORY_COUNT)
	local autoW, autoH = MapConfig.mapSizeFor(count)
	local width = opts.width or autoW
	local height = opts.height or autoH

	local result, attempt, seed
	for a = 1, MapConfig.GENERATION_ATTEMPTS do
		attempt = a
		-- Attempt 1 uses the seed itself; retries derive new seeds from it.
		seed = if a == 1 then baseSeed else (baseSeed * 7919 + a * 104729) % 2147483647
		result = generateOnce(seed, def, count, width, height)
		if result.continents >= def.continents[1] and #result.starts >= def.civilizations then
			break
		end
	end

	return {
		seed = seed,
		baseSeed = baseSeed,
		attempt = attempt,
		matchSize = sizeName,
		civilizations = def.civilizations,
		territoryCount = count,
		width = width,
		height = height,
		seaLevel = result.seaLevel,
		mountainLevel = result.mountainLevel,
		territories = result.territories,
		territoryIds = result.ids,
		landmasses = result.masses,
		continentCount = result.continents,
		rivers = result.rivers,
		startPositions = result.starts,
		stats = {
			voronoiMs = result.stats.voronoiMs,
			totalMs = (os.clock() - t0) * 1000,
			attempts = attempt,
			lakesFilled = result.stats.lakesFilled,
			lakes = result.stats.lakes,
			terrainCounts = result.stats.terrainCounts,
		},
	}
end

-- Deterministic fingerprint of the logical map (FNV-1a over a canonical
-- string). Used to prove same seed => same map.
function MapGenerator.fingerprint(map: MapData): string
	local parts = { tostring(map.seed), tostring(map.territoryCount), map.matchSize }
	for _, id in map.territoryIds do
		local t = map.territories[id]
		local coords = {}
		for _, p in t.polygon do
			table.insert(coords, string.format("%.3f,%.3f", p.X, p.Y))
		end
		table.insert(
			parts,
			string.format(
				"%d|%s|%.5f|%.5f|%s|%s|%s",
				id,
				t.terrainType,
				t.elevation,
				t.fertility,
				table.concat(coords, ";"),
				table.concat(t.neighbors, ","),
				tostring(t.riverId)
			)
		)
	end
	table.insert(parts, table.concat(map.startPositions, ","))
	local s = table.concat(parts, "\n")
	local h = 2166136261
	for i = 1, #s do
		h = bit32.bxor(h, string.byte(s, i))
		-- 32-bit FNV prime multiply split to stay within double precision
		h = (bit32.band(h * 403, 0xFFFFFFFF) + bit32.lshift(bit32.band(h, 0xFFFF), 24)) % 4294967296
	end
	return string.format("%08x", h)
end

return MapGenerator
