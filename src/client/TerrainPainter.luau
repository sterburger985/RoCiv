--!strict
-- TerrainPainter (client)
-- Draws KNOWN territories as Roblox voxel terrain (Humankind-style relief:
-- rolling grassland, golden plains, forest canopy, dunes, tundra with snow,
-- real mountain ranges, beaches, shallow coasts, deep ocean, lakes and
-- rivers). Unexplored territories are never painted - they stay as the
-- parchment plateau drawn by MapRenderer - so the terrain itself can never
-- leak hidden map data. Everything here is presentation only.
--
--   Visible   full-colour materials, real water.
--   Explored  Civilization VI-style sepia: the same relief in parchment
--             tones (a separate set of materials), water drawn as flat sepia.
--
-- Terrain is written per territory: a column grid (4 studs, the voxel size)
-- records which territory owns each column, and painting a territory only
-- rewrites its own columns. Heights blend toward known neighbours near
-- shared borders so the land is continuous; unknown neighbours are treated
-- as "same as me" (no information used). When a territory becomes known its
-- known neighbours are repainted so their shared borders match.
--
-- Work is queued and processed within a per-frame time budget, so large
-- reveals build progressively without freezing the client.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("RoCiv"):WaitForChild("Shared")
local MapConfig = require(Shared:WaitForChild("MapConfig"))
local Geometry = require(Shared:WaitForChild("Geometry"))

local RES = 4
local M = Enum.Material

local TerrainPainter = {}
TerrainPainter.__index = TerrainPainter

export type Mode = string -- "Visible" | "Explored"

type EdgeInfo = { a: Vector2, b: Vector2, neighbor: number }

export type TerrainPainter = typeof(setmetatable(
	{} :: {
		terrain: Terrain,
		state: any,
		width: number,
		height: number,
		x0: number, -- world X of column 0's left side
		z0: number,
		cols: number,
		rows: number,
		owner: buffer, -- u16 per column: territory id (0 = outside map)
		surface: buffer, -- f32 per column: world Y of the visible top
		edges: { [number]: { EdgeInfo } },
		bounds: { [number]: { number } }, -- i0, i1, j0, j1 (column ranges)
		painted: { [number]: Mode },
		paintedTop: { [number]: number },
		queue: { [number]: Mode | false }, -- false = clear back to unpainted
		order: { number },
		listeners: { (ids: { number }) -> () },
		conn: RBXScriptConnection?,
		stats: { [string]: number },
	},
	TerrainPainter
))

-- Materials ---------------------------------------------------------------------
-- Two disjoint material sets: full colour (Visible) and sepia (Explored).
-- Material colours are global, so each terrain look needs its own material.

local VISIBLE = {
	Grass = M.Grass,
	Forest = M.LeafyGrass,
	Plains = M.Ground,
	Sand = M.Sand,
	SeaFloor = M.Sandstone,
	Rock = M.Rock,
	Snow = M.Snow,
	Tundra = M.Mud,
	Border = M.Pavement,
}
local SEPIA = {
	Low = M.Limestone,
	Forest = M.Concrete,
	High = M.Basalt,
	Snow = M.Ice,
	Water = M.Salt,
	Border = M.Asphalt,
}

local MATERIAL_COLORS: { [Enum.Material]: Color3 } = {
	[M.Grass] = Color3.fromRGB(104, 148, 56),
	[M.LeafyGrass] = Color3.fromRGB(46, 92, 38),
	[M.Ground] = Color3.fromRGB(186, 164, 84),
	[M.Sand] = Color3.fromRGB(226, 204, 148),
	[M.Sandstone] = Color3.fromRGB(196, 176, 128),
	[M.Rock] = Color3.fromRGB(122, 112, 102),
	[M.Snow] = Color3.fromRGB(240, 244, 248),
	[M.Mud] = Color3.fromRGB(132, 136, 108),
	[M.Pavement] = Color3.fromRGB(236, 226, 192),
	-- Sepia (Civilization VI "explored" look)
	[M.Limestone] = Color3.fromRGB(196, 170, 124),
	[M.Concrete] = Color3.fromRGB(156, 130, 92),
	[M.Basalt] = Color3.fromRGB(136, 112, 82),
	[M.Ice] = Color3.fromRGB(226, 212, 178),
	[M.Salt] = Color3.fromRGB(170, 162, 132),
	[M.Asphalt] = Color3.fromRGB(96, 76, 52),
}

-- Terrain heights (studs above sea level) ---------------------------------------

local BASE = { Ocean = -18, Coast = -6, Lake = -6, Grassland = 3, Plains = 2.5, Desert = 2.5, Forest = 3.5, Tundra = 3, Mountains = 18 }
local RISE = { Ocean = 0, Coast = 0, Lake = 0, Grassland = 7, Plains = 4, Desert = 5, Forest = 6, Tundra = 6, Mountains = 14 }

local function targetHeight(r: any): number
	local tt = r.terrainType
	local e = math.clamp(((r.elevation or 0.5) - 0.42) / 0.58, 0, 1)
	return (BASE[tt] or 3) + (RISE[tt] or 0) * e
end

local function isWaterType(tt: string?): boolean
	return tt == "Ocean" or tt == "Coast" or tt == "Lake"
end

local function smoothstep(e0: number, e1: number, x: number): number
	local t = math.clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
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

local noise = math.noise
local function ridge(x: number, z: number, s: number, seed: number): number
	local n = 1 - math.abs(noise(x / s, z / s, seed))
	return n * n
end

-- Construction ---------------------------------------------------------------------

function TerrainPainter.new(): TerrainPainter
	local self = setmetatable({
		terrain = workspace.Terrain,
		state = nil,
		width = 0,
		height = 0,
		x0 = 0,
		z0 = 0,
		cols = 0,
		rows = 0,
		owner = buffer.create(0),
		surface = buffer.create(0),
		edges = {},
		bounds = {},
		painted = {},
		paintedTop = {},
		queue = {},
		order = {},
		listeners = {},
		conn = nil,
		stats = { painted = 0, voxels = 0, ms = 0 },
	}, TerrainPainter)
	return self
end

function TerrainPainter.onPainted(self: TerrainPainter, fn: (ids: { number }) -> ())
	table.insert(self.listeners, fn)
end

local function applyLook(terrain: Terrain)
	for mat, color in MATERIAL_COLORS do
		terrain:SetMaterialColor(mat, color)
	end
	terrain.WaterColor = MapConfig.TERRAIN_WATER_COLOR
	terrain.WaterTransparency = MapConfig.TERRAIN_WATER_TRANSPARENCY
	terrain.WaterReflectance = MapConfig.TERRAIN_WATER_REFLECTANCE
	terrain.WaterWaveSize = MapConfig.TERRAIN_WATER_WAVE_SIZE
	terrain.WaterWaveSpeed = MapConfig.TERRAIN_WATER_WAVE_SPEED
	-- Grass blades are invisible from strategy height; not scriptable everywhere.
	pcall(function()
		(terrain :: any).Decoration = false
	end)
end

-- Column index helpers (map coordinates; world = map - size/2).
function TerrainPainter._colCentre(self: TerrainPainter, i: number, j: number): Vector2
	return Vector2.new(self.x0 + RES * i + RES * 0.5 + self.width * 0.5, self.z0 + RES * j + RES * 0.5 + self.height * 0.5)
end

function TerrainPainter._colOf(self: TerrainPainter, p: Vector2): (number, number)
	return math.floor((p.X - self.width * 0.5 - self.x0) / RES), math.floor((p.Y - self.height * 0.5 - self.z0) / RES)
end

function TerrainPainter.ownerAt(self: TerrainPainter, p: Vector2): number
	local i, j = self:_colOf(p)
	if i < 0 or j < 0 or i >= self.cols or j >= self.rows then
		return 0
	end
	return buffer.readu16(self.owner, (j * self.cols + i) * 2)
end

-- World Y of the drawn surface at a map point (parchment height if unknown).
function TerrainPainter.heightAt(self: TerrainPainter, p: Vector2): number
	local i, j = self:_colOf(p)
	if i < 0 or j < 0 or i >= self.cols or j >= self.rows then
		return MapConfig.MAP_ORIGIN_Y
	end
	return buffer.readf32(self.surface, (j * self.cols + i) * 4)
end

-- Prepares the column grid for a new map and clears all terrain.
function TerrainPainter.setup(self: TerrainPainter, state: any, query: any)
	local t0 = os.clock()
	self:clearAll()
	self.state = state
	self.width, self.height = state.width, state.height
	self.x0 = math.floor(-self.width * 0.5 / RES) * RES
	self.z0 = math.floor(-self.height * 0.5 / RES) * RES
	self.cols = math.ceil((self.width * 0.5 - self.x0) / RES)
	self.rows = math.ceil((self.height * 0.5 - self.z0) / RES)
	local n = self.cols * self.rows
	self.owner = buffer.create(n * 2)
	self.surface = buffer.create(n * 4)
	local parch = MapConfig.MAP_ORIGIN_Y + MapConfig.PARCHMENT_HEIGHT
	for k = 0, n - 1 do
		buffer.writef32(self.surface, k * 4, parch)
	end
	applyLook(self.terrain)

	-- Rasterise every territory polygon into the column grid (half-open
	-- spans so shared edges assign each column once).
	for _, r in state.list do
		local poly = r.polygon
		local lo, hi = Geometry.bounds(poly)
		local _, j0 = self:_colOf(lo)
		local _, j1 = self:_colOf(hi)
		j0 = math.max(j0, 0)
		j1 = math.min(j1, self.rows - 1)
		local bi0, bi1 = math.huge, -math.huge
		local nPoly = #poly
		for j = j0, j1 do
			local mz = self:_colCentre(0, j).Y
			local xa, xb = math.huge, -math.huge
			for e = 1, nPoly do
				local a, b = poly[e], poly[e % nPoly + 1]
				if (a.Y <= mz and b.Y > mz) or (b.Y <= mz and a.Y > mz) then
					local x = a.X + (mz - a.Y) / (b.Y - a.Y) * (b.X - a.X)
					xa = math.min(xa, x)
					xb = math.max(xb, x)
				end
			end
			if xa < xb then
				local ia = math.max(0, math.ceil((xa - self.width * 0.5 - self.x0) / RES - 0.5))
				local ib = math.min(self.cols - 1, math.ceil((xb - self.width * 0.5 - self.x0) / RES - 0.5) - 1)
				for i = ia, ib do
					local k = (j * self.cols + i) * 2
					if buffer.readu16(self.owner, k) == 0 then
						buffer.writeu16(self.owner, k, r.id)
					end
				end
				bi0 = math.min(bi0, ia)
				bi1 = math.max(bi1, ib)
			end
		end
		self.bounds[r.id] = { math.max(0, bi0 - 1), math.min(self.cols - 1, bi1 + 1), math.max(0, j0 - 1), math.min(self.rows - 1, j1 + 1) }
	end
	-- Columns on exact edges / float gaps: resolve with the map query.
	local gaps = 0
	for j = 0, self.rows - 1 do
		for i = 0, self.cols - 1 do
			local k = (j * self.cols + i) * 2
			if buffer.readu16(self.owner, k) == 0 then
				local c = self:_colCentre(i, j)
				if c.X > 0 and c.Y > 0 and c.X < self.width and c.Y < self.height then
					local id = query:territoryAt(c)
					if id then
						buffer.writeu16(self.owner, k, id)
						local b = self.bounds[id]
						b[1], b[2], b[3], b[4] = math.min(b[1], i), math.max(b[2], i), math.min(b[3], j), math.max(b[4], j)
						gaps += 1
					end
				end
			end
		end
	end

	-- Edge -> neighbour id, found by sampling just outside each edge.
	for _, r in state.list do
		local poly = r.polygon
		local nPoly = #poly
		local list: { EdgeInfo } = {}
		for e = 1, nPoly do
			local a, b = poly[e], poly[e % nPoly + 1]
			local d = b - a
			if d.Magnitude > 0.5 then
				local normal = Vector2.new(d.Y, -d.X).Unit
				local mid = (a + b) * 0.5
				local nb = 0
				for _, step in { 3, 6, 9 } do
					local o = self:ownerAt(mid + normal * step)
					if o ~= 0 and o ~= r.id then
						nb = o
						break
					end
				end
				table.insert(list, { a = a, b = b, neighbor = nb })
			end
		end
		self.edges[r.id] = list
	end
	self.stats.setupMs = (os.clock() - t0) * 1000
	self.stats.gapColumns = gaps
	self.stats.columns = n

	if not self.conn then
		self.conn = RunService.Heartbeat:Connect(function()
			self:_step()
		end)
	end
end

function TerrainPainter.clearAll(self: TerrainPainter)
	self.terrain:Clear()
	table.clear(self.painted)
	table.clear(self.paintedTop)
	table.clear(self.queue)
	table.clear(self.order)
	table.clear(self.edges)
	table.clear(self.bounds)
end

function TerrainPainter.destroy(self: TerrainPainter)
	if self.conn then
		self.conn:Disconnect()
		self.conn = nil
	end
	self:clearAll()
end

-- Queueing ---------------------------------------------------------------------------

-- mode nil = remove the territory's terrain (back to parchment).
-- force = repaint even if already painted in this mode (neighbour changed).
function TerrainPainter.request(self: TerrainPainter, id: number, mode: Mode?, force: boolean?)
	local want: Mode | false = mode or false
	local current: Mode | false = self.painted[id] or false
	if self.queue[id] == nil and current == want and not (force and want ~= false) then
		return
	end
	if self.queue[id] == nil then
		table.insert(self.order, id)
	end
	self.queue[id] = want
end

function TerrainPainter.isPainted(self: TerrainPainter, id: number): Mode?
	return self.painted[id]
end

-- What the territory will look like once the queue drains.
function TerrainPainter.pendingMode(self: TerrainPainter, id: number): Mode?
	local q = self.queue[id]
	if q ~= nil then
		return if q == false then nil else q
	end
	return self.painted[id]
end

function TerrainPainter.queueLength(self: TerrainPainter): number
	return #self.order
end

function TerrainPainter._step(self: TerrainPainter)
	if #self.order == 0 then
		return
	end
	local t0 = os.clock()
	local budget = MapConfig.TERRAIN_FRAME_BUDGET_MS / 1000
	local done = {}
	while #self.order > 0 and os.clock() - t0 < budget do
		local id = table.remove(self.order, 1) :: number
		local want = self.queue[id]
		self.queue[id] = nil
		if want ~= nil then
			local ok, err = pcall(function()
				self:_paint(id, if want == false then nil else want)
			end)
			if not ok then
				warn("[TerrainPainter] Failed to paint territory " .. id .. ": " .. tostring(err))
			end
			table.insert(done, id)
		end
	end
	self.stats.ms += (os.clock() - t0) * 1000
	if #done > 0 then
		for _, fn in self.listeners do
			fn(done)
		end
	end
end

-- Paints everything queued right now (tests / tools).
function TerrainPainter.flush(self: TerrainPainter)
	while #self.order > 0 do
		self:_step()
	end
end

-- Painting ------------------------------------------------------------------------------

function TerrainPainter._paint(self: TerrainPainter, id: number, mode: Mode?)
	local rec = self.state:get(id)
	local b = self.bounds[id]
	if not rec or not b then
		return
	end
	local Y0 = MapConfig.MAP_ORIGIN_Y
	local yBot = Y0 - MapConfig.TERRAIN_DEPTH
	local cols = self.cols
	local i0, i1, j0, j1 = b[1], b[2], b[3], b[4]
	local nx, nz = i1 - i0 + 1, j1 - j0 + 1

	-- 1. Per-column surface (solid top, water top, material).
	local solidTop: { [number]: number } = {}
	local waterTop: { [number]: number } = {}
	local matOf: { [number]: Enum.Material } = {}
	local maxTop = Y0 + 4
	local parch = Y0 + MapConfig.PARCHMENT_HEIGHT

	if mode then
		local tt = rec.terrainType
		local water = isWaterType(tt)
		local hOwn = targetHeight(rec)
		local edgeList = self.edges[id] or {}
		-- Per-edge blend target: halfway to a KNOWN neighbour, else own height.
		local mids = table.create(#edgeList)
		for e, info in edgeList do
			local nrec = if info.neighbor ~= 0 then self.state:get(info.neighbor) else nil
			if nrec and nrec.terrainType and nrec.state ~= "Unexplored" then
				mids[e] = (hOwn + targetHeight(nrec)) * 0.5
			elseif info.neighbor == 0 then
				mids[e] = (hOwn + BASE.Ocean) * 0.5 -- map edge is open sea
			else
				mids[e] = hOwn
			end
		end
		local blend = MapConfig.TERRAIN_BLEND_DISTANCE
		local river = rec.riverPath
		local sepia = mode == "Explored"

		for j = j0, j1 do
			for i = i0, i1 do
				local k = j * cols + i
				if buffer.readu16(self.owner, k * 2) == id then
					local c = self:_colCentre(i, j)
					local wx, wz = c.X, c.Y
					-- Border blend weights.
					local sumK, sumH = 0, 0
					for e, info in edgeList do
						local d = segDist(c, info.a, info.b)
						if d < blend then
							local kk = 1 - smoothstep(0, blend, d)
							sumK += kk
							sumH += kk * mids[e]
						end
					end
					local h
					if sumK > 1 then
						h = sumH / sumK
						sumK = 1
					else
						h = hOwn * (1 - sumK) + sumH
					end
					local f = 1 - sumK -- interior factor: 0 at borders
					local mat: Enum.Material
					local wTop: number? = nil

					if water then
						h += noise(wx / 60, wz / 60, 3) * 2 * f
						if tt == "Ocean" then
							h -= 6 * f
						end
						h = math.min(h, -0.5)
						if sepia then
							mat = SEPIA.Water
							h = 0
						else
							mat = VISIBLE.SeaFloor
							wTop = Y0
						end
					else
						-- Relief by terrain type.
						local snow = false
						local canopy = 0
						if tt == "Grassland" then
							h += (noise(wx / 90, wz / 90, 1) * 3.5 + noise(wx / 28, wz / 28, 2)) * f
						elseif tt == "Plains" then
							h += (noise(wx / 120, wz / 120, 4) * 2.5 + noise(wx / 35, wz / 35, 5) * 0.6) * f
						elseif tt == "Forest" then
							h += noise(wx / 100, wz / 100, 6) * 3 * f
							local cn = noise(wx / 13, wz / 13, 7) + noise(wx / 40, wz / 40, 8) * 0.5
							if cn > -0.25 then
								canopy = (2.2 + (cn + 0.25) * 5) * math.min(1, f * 1.6)
							end
						elseif tt == "Desert" then
							local dune = ridge(wx + noise(wz / 80, 0, 9) * 30, wz, 38, 10)
							h += (dune * 5 + noise(wx / 150, wz / 150, 11) * 2) * f
						elseif tt == "Tundra" then
							h += noise(wx / 80, wz / 80, 12) * 3 * f
							snow = noise(wx / 36, wz / 36, 13) > 0.18
						elseif tt == "Mountains" then
							local peaks = ridge(wx, wz, 95, 14) ^ 1.5 * 52 + ridge(wx, wz, 38, 15) * 14
							h += (peaks + noise(wx / 25, wz / 25, 16) * 3) * f
						end
						-- Beaches: land never dips below the sea next to water.
						local beach = false
						if h < 2 then
							h = math.max(h, 0.8)
							beach = true
						end
						local top = Y0 + h
						if sepia then
							if tt == "Mountains" and top > Y0 + 14 then
								mat = if top > Y0 + 40 then SEPIA.Snow else SEPIA.High
							elseif canopy > 0 then
								mat = SEPIA.Forest
							else
								mat = SEPIA.Low
							end
						else
							if beach and tt ~= "Mountains" then
								mat = VISIBLE.Sand
							elseif tt == "Mountains" then
								mat = if top > Y0 + 40 then VISIBLE.Snow elseif top > Y0 + 12 then VISIBLE.Rock else VISIBLE.Grass
							elseif tt == "Forest" then
								mat = if canopy > 0 then VISIBLE.Forest else VISIBLE.Grass
							elseif tt == "Plains" then
								mat = VISIBLE.Plains
							elseif tt == "Desert" then
								mat = VISIBLE.Sand
							elseif tt == "Tundra" then
								mat = if snow then VISIBLE.Snow else VISIBLE.Tundra
							else
								mat = VISIBLE.Grass
							end
						end
						h += canopy

						-- River channel.
						if river and #river >= 2 then
							local d = math.huge
							for s = 1, #river - 1 do
								d = math.min(d, segDist(c, river[s], river[s + 1]))
							end
							local rw = MapConfig.RIVER_HALF_WIDTH
							if d < rw then
								local bank = h - canopy
								if sepia then
									h = math.max(bank - 0.6, 0.4)
									mat = SEPIA.Water
								else
									wTop = Y0 + math.max(bank - 0.7, 0.3)
									h = math.max(bank - 2.4 - 1.4 * (1 - d / rw), -1.5)
									mat = VISIBLE.SeaFloor
								end
							end
						end

						-- Neutral territory border line (drawn by the lower id only,
						-- and only between two known land territories).
						local isBorder = false
						for _, step in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
							local ni, nj = i + step[1], j + step[2]
							if ni >= 0 and nj >= 0 and ni < cols and nj < self.rows then
								local o = buffer.readu16(self.owner, (nj * cols + ni) * 2)
								if o ~= id and o > id then
									local orec = self.state:get(o)
									if orec and orec.terrainType and orec.state ~= "Unexplored" and not isWaterType(orec.terrainType) then
										isBorder = true
										break
									end
								end
							end
						end
						if isBorder and mat ~= SEPIA.Water and wTop == nil then
							mat = if sepia then SEPIA.Border else VISIBLE.Border
						end
					end
					solidTop[k] = Y0 + h
					if wTop then
						waterTop[k] = wTop
					end
					matOf[k] = mat
					maxTop = math.max(maxTop, Y0 + h, wTop or -math.huge)
				end
			end
		end
	end

	-- 2. Read the box, rewrite only this territory's columns, write back.
	local top = math.max(maxTop + RES, self.paintedTop[id] or -math.huge)
	top = math.ceil((top - Y0) / RES) * RES + Y0
	local region = Region3.new(
		Vector3.new(self.x0 + RES * i0, yBot, self.z0 + RES * j0),
		Vector3.new(self.x0 + RES * (i1 + 1), top, self.z0 + RES * (j1 + 1))
	):ExpandToGrid(RES)
	local mats, occs = self.terrain:ReadVoxels(region, RES)
	local size = mats.Size
	local ny = size.Y
	local voxels = 0
	for xi = 1, size.X do
		local i = i0 + xi - 1
		local mx, ox = mats[xi], occs[xi]
		for zi = 1, size.Z do
			local j = j0 + zi - 1
			local k = j * cols + i
			if i <= i1 and j <= j1 and buffer.readu16(self.owner, k * 2) == id then
				local sT = solidTop[k]
				local wT = waterTop[k]
				local mat = matOf[k]
				for yi = 1, ny do
					local yb = yBot + (yi - 1) * RES
					local m, o = M.Air, 0
					if sT then
						local sf = math.clamp((sT - yb) / RES, 0, 1)
						local wf = if wT then math.clamp((wT - yb) / RES, 0, 1) else 0
						if sf >= 0.5 or (sf > 0 and wf <= sf) then
							m, o = mat :: Enum.Material, if wf > sf then 1 else sf
						elseif wf > 0 then
							m, o = M.Water, wf
						end
					end
					mx[yi][zi] = m
					ox[yi][zi] = o
					voxels += 1
				end
				buffer.writef32(self.surface, k * 4, if sT then math.max(sT, wT or -math.huge) else parch)
			end
		end
	end
	self.terrain:WriteVoxels(region, RES, mats, occs)
	self.paintedTop[id] = top
	self.painted[id] = mode
	self.stats.painted += 1
	self.stats.voxels += voxels
end

-- Validation helper: columns of an unpainted territory must hold no terrain.
function TerrainPainter.columnsClear(self: TerrainPainter, id: number): boolean
	local b = self.bounds[id]
	if not b then
		return true
	end
	local Y0 = MapConfig.MAP_ORIGIN_Y
	local region = Region3.new(
		Vector3.new(self.x0 + RES * b[1], Y0 - MapConfig.TERRAIN_DEPTH, self.z0 + RES * b[3]),
		Vector3.new(self.x0 + RES * (b[2] + 1), Y0 + 160, self.z0 + RES * (b[4] + 1))
	):ExpandToGrid(RES)
	local mats = self.terrain:ReadVoxels(region, RES)
	local size = mats.Size
	for xi = 1, size.X do
		for zi = 1, size.Z do
			local i, j = b[1] + xi - 1, b[3] + zi - 1
			if buffer.readu16(self.owner, (j * self.cols + i) * 2) == id then
				for yi = 1, size.Y do
					if mats[xi][yi][zi] ~= M.Air then
						return false
					end
				end
			end
		end
	end
	return true
end

return TerrainPainter
