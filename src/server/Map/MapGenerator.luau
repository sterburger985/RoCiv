--!strict
-- MapGenerator
-- Deterministic procedural generator for RoCiv's strategic territories.
--
-- Pipeline:
--   1. Scatter N seed points with Random.new(seed).
--   2. Lloyd relaxation (Voronoi -> move each point to its cell centroid).
--   3. Final Voronoi cells via half-plane clipping of the map rectangle.
--      Every clipped edge is tagged with the site that produced it, which
--      gives exact shared-edge adjacency for free.
--   4. Elevation / moisture from seeded multi-octave noise.
--   5. Terrain rules (sea level by quantile, edge ocean, lake fill, coast,
--      mountains, tundra, desert / plains / grassland / forest).
--
-- The generator is pure: it touches no Instances and returns plain data.
-- It lives on the server so clients cannot regenerate hidden map data
-- (important once resources and fog of war exist).
-- The same seed + settings always produce the same logical map.

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
	resources: { any }, -- placeholder (resource phase)
	ownerId: number?, -- nil = unowned
	cityId: number?, -- nil = no city
	movementMetadata: {
		moveCost: number,
		passableByLand: boolean,
		isWater: boolean,
	},
}

export type MapData = {
	seed: number,
	territoryCount: number,
	width: number,
	height: number,
	seaLevel: number,
	mountainLevel: number,
	territories: { [number]: Territory },
	territoryIds: { number },
	stats: { [string]: any },
}

export type GenerateOptions = {
	seed: number?,
	territoryCount: number?,
	width: number?,
	height: number?,
}

local MapGenerator = {}

-- Voronoi ----------------------------------------------------------------

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

	for i = 1, n do
		local s = sites[i]
		-- Other sites sorted by distance so we can stop early.
		local order = table.create(n - 1)
		local dist2 = table.create(n)
		for j = 1, n do
			if j ~= i then
				local d = sites[j] - s
				dist2[j] = d.X * d.X + d.Y * d.Y
				table.insert(order, j)
			end
		end
		table.sort(order, function(a, b)
			local da, db = dist2[a], dist2[b]
			if da == db then
				return a < b
			end
			return da < db
		end)

		local poly = table.clone(corners)
		local tags = { 0, 0, 0, 0 }
		local maxR2 = 0
		for _, p in poly do
			local d = p - s
			maxR2 = math.max(maxR2, d.X * d.X + d.Y * d.Y)
		end

		for _, j in order do
			-- A site farther than 2 * (furthest vertex) cannot cut the cell.
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
		polys[i] = poly
		tagsList[i] = tags
	end
	return polys, tagsList
end

-- Noise --------------------------------------------------------------------

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

-- Generation ---------------------------------------------------------------

function MapGenerator.generate(options: GenerateOptions?): MapData
	local opts = options or {}
	local t0 = os.clock()
	local seed = math.floor(opts.seed or MapConfig.DEFAULT_SEED)
	local count = math.clamp(
		math.floor(opts.territoryCount or MapConfig.DEFAULT_TERRITORY_COUNT),
		MapConfig.MIN_TERRITORY_COUNT,
		MapConfig.MAX_TERRITORY_COUNT
	)
	local width = opts.width or MapConfig.MAP_WIDTH
	local height = opts.height or MapConfig.MAP_HEIGHT

	local rng = Random.new(seed)

	-- 1. Seed points (kept slightly away from the edges).
	local margin = 0.01
	local sites: { Vector2 } = table.create(count)
	for i = 1, count do
		sites[i] = Vector2.new(
			rng:NextNumber(width * margin, width * (1 - margin)),
			rng:NextNumber(height * margin, height * (1 - margin))
		)
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

	-- Territory ids are explicit, stable values stored on the record. They are
	-- assigned 1..N from the seeded site order; nothing else (instance names,
	-- colours, positions) is used as identity.
	local territories: { [number]: Territory } = {}
	local ids: { number } = table.create(count)
	for i = 1, count do
		local poly = polys[i]
		local id = i
		ids[i] = id
		territories[id] = {
			id = id,
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
			resources = {},
			ownerId = nil,
			cityId = nil,
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
	-- Enforce symmetry: only keep a link if both sides agree. (Shared edges
	-- are the same segment, so this only matters at the length threshold.)
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

	-- 4. Elevation & moisture.
	local ex, ey = rng:NextNumber(-10000, 10000), rng:NextNumber(-10000, 10000)
	local mx, my = rng:NextNumber(-10000, 10000), rng:NextNumber(-10000, 10000)
	local ez, mz = rng:NextNumber(0, 100), rng:NextNumber(0, 100)
	local tundraJitter = {}
	local rawElev: { [number]: number } = {}
	local minE, maxE = math.huge, -math.huge
	for _, id in ids do
		local t = territories[id]
		local nx = t.centroid.X / width
		local ny = t.centroid.Y / height
		local aspect = width / height
		local e = fbm(
			nx * MapConfig.ELEVATION_FREQUENCY * aspect + ex,
			ny * MapConfig.ELEVATION_FREQUENCY + ey,
			ez,
			MapConfig.ELEVATION_OCTAVES
		)
		local dx = math.abs(nx - 0.5) * 2
		local dy = math.abs(ny - 0.5) * 2
		local d = math.max(dx, dy) * 0.7 + math.sqrt(dx * dx + dy * dy) * 0.3
		e -= smoothstep(MapConfig.EDGE_FALLOFF_START, 1.0, d) * MapConfig.EDGE_FALLOFF_STRENGTH
		rawElev[id] = e
		minE = math.min(minE, e)
		maxE = math.max(maxE, e)

		local m = fbm(
			nx * MapConfig.MOISTURE_FREQUENCY * aspect + mx,
			ny * MapConfig.MOISTURE_FREQUENCY + my,
			mz,
			MapConfig.MOISTURE_OCTAVES
		)
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
	local seaLevel = quantile(elevList, 1 - MapConfig.LAND_FRACTION)
	for _, id in ids do
		local t = territories[id]
		if MapConfig.FORCE_EDGE_OCEAN and touchesEdge[id] and t.elevation >= seaLevel then
			-- Keep elevation consistent with the water rule.
			t.elevation = math.max(0, seaLevel - 0.001)
		end
		t.isWater = t.elevation < seaLevel
	end

	-- Lake fill: water bodies not connected to the outer ocean become land.
	-- (Lakes are a later terrain type; Phase 1 has no inland water.)
	local reached: { [number]: boolean } = {}
	local queue = {}
	for _, id in ids do
		local t = territories[id]
		if t.isWater and touchesEdge[id] then
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
	local lakesFilled = 0
	for _, id in ids do
		local t = territories[id]
		if t.isWater and not reached[id] then
			t.isWater = false
			t.elevation = seaLevel
			lakesFilled += 1
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
		if t.isWater then
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
		local def = TerrainTypes.ById[terrain]
		t.fertility = clamp01(def.baseFertility + (t.moisture - 0.5) * 0.3 + rng:NextNumber(-0.05, 0.05))
		t.movementMetadata = {
			moveCost = def.moveCost,
			passableByLand = def.passableByLand,
			isWater = def.isWater,
		}
	end

	local t1 = os.clock()
	local terrainCounts = {}
	for _, id in ids do
		local tt = territories[id].terrainType
		terrainCounts[tt] = (terrainCounts[tt] or 0) + 1
	end

	return {
		seed = seed,
		territoryCount = count,
		width = width,
		height = height,
		seaLevel = seaLevel,
		mountainLevel = mountainLevel,
		territories = territories,
		territoryIds = ids,
		stats = {
			voronoiMs = (tVoronoi - t0) * 1000,
			totalMs = (t1 - t0) * 1000,
			lakesFilled = lakesFilled,
			terrainCounts = terrainCounts,
		},
	}
end

-- Deterministic fingerprint of the logical map (FNV-1a over a canonical
-- string). Used to prove same seed => same map.
function MapGenerator.fingerprint(map: MapData): string
	local parts = { tostring(map.seed), tostring(map.territoryCount) }
	for _, id in map.territoryIds do
		local t = map.territories[id]
		local coords = {}
		for _, p in t.polygon do
			table.insert(coords, string.format("%.3f,%.3f", p.X, p.Y))
		end
		table.insert(
			parts,
			string.format(
				"%d|%s|%.5f|%.5f|%s|%s",
				id,
				t.terrainType,
				t.elevation,
				t.fertility,
				table.concat(coords, ";"),
				table.concat(t.neighbors, ",")
			)
		)
	end
	local s = table.concat(parts, "\n")
	local h = 2166136261
	for i = 1, #s do
		h = bit32.bxor(h, string.byte(s, i))
		-- 32-bit FNV prime multiply split to stay within double precision
		h = (bit32.band(h * 403, 0xFFFFFFFF) + bit32.lshift(bit32.band(h, 0xFFFF), 24)) % 4294967296
	end
	return string.format("%08x", h)
end

-- Plain-table copy safe to send over a RemoteFunction (no internal fields).
function MapGenerator.toClientPayload(map: MapData, includeSeed: boolean): { [string]: any }
	local list = table.create(#map.territoryIds)
	for _, id in map.territoryIds do
		local t = map.territories[id]
		table.insert(list, {
			id = t.id,
			polygon = t.polygon,
			centroid = t.centroid,
			neighbors = t.neighbors,
			terrainType = t.terrainType,
			elevation = t.elevation,
			fertility = t.fertility,
			ownerId = t.ownerId,
			cityId = t.cityId,
		})
	end
	return {
		seed = if includeSeed then map.seed else nil,
		territoryCount = map.territoryCount,
		width = map.width,
		height = map.height,
		territories = list,
	}
end

return MapGenerator
