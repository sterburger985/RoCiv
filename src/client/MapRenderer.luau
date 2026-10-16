--!strict
-- MapRenderer (client)
-- Turns map payload data into visuals. Owns every Instance it creates and
-- can tear them all down for regeneration.
--
-- Backends:
--   EditableMesh  one MeshPart per territory, built at runtime from the
--                 polygon (top face + side walls). Preferred.
--   Wedge         fallback: each polygon triangle drawn with two WedgeParts.
-- Borders are not separate objects: territories are drawn inset by
-- BORDER_INSET and a dark base plate shows through the gaps.
--
-- Fog of war is drawn by recolouring these same territory visuals (see
-- TerritoryStyle), so fog always matches territory ids and boundaries.
-- Around the map: a dark frame marks the playable edge and a large
-- decorative sea backdrop fills the rest of the view (no grey void).
--
-- Rendering never decides gameplay. Each visual only carries a TerritoryId
-- attribute; selection resolves clicks against data via MapQuery.

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("RoCiv"):WaitForChild("Shared")
local Geometry = require(Shared:WaitForChild("Geometry"))
local MapConfig = require(Shared:WaitForChild("MapConfig"))
local TerrainTypes = require(Shared:WaitForChild("TerrainTypes"))
local TerritoryStyle = require(script.Parent:WaitForChild("TerritoryStyle"))

local MAP_FOLDER_NAME = "StrategicMap"

type Visual = {
	root: Instance,
	parts: { BasePart },
	mesh: EditableMesh?,
	color: Color3,
	ownerOutline: Instance?,
	height: number, -- current surface height offset
	decor: Model?,
	decorKey: string?,
}

local MapRenderer = {}
MapRenderer.__index = MapRenderer

export type MapRenderer = typeof(setmetatable(
	{} :: {
		folder: Folder?,
		visuals: { [number]: Visual },
		polygons: { [number]: { Vector2 } },
		emphasis: { [number]: number },
		state: any,
		lastStats: { [string]: any }?,
		width: number,
		height: number,
		backend: string,
		wedgeTemplate: WedgePart,
	},
	MapRenderer
))

function MapRenderer.new(): MapRenderer
	local wedge = Instance.new("WedgePart")
	wedge.Anchored = true
	wedge.CanCollide = false
	wedge.CanQuery = false
	wedge.CanTouch = false
	wedge.CastShadow = false
	wedge.Material = MapConfig.TERRITORY_MATERIAL
	wedge.TopSurface = Enum.SurfaceType.Smooth
	wedge.BottomSurface = Enum.SurfaceType.Smooth
	return setmetatable({
		folder = nil,
		visuals = {},
		polygons = {},
		emphasis = {},
		state = nil,
		lastStats = nil,
		width = 0,
		height = 0,
		backend = "none",
		wedgeTemplate = wedge,
	}, MapRenderer)
end

-- Coordinate conversion: map (x, y) <-> world (X, Z), map centred on origin.
function MapRenderer.mapToWorld(self: MapRenderer, p: Vector2, y: number?): Vector3
	return Vector3.new(p.X - self.width * 0.5, y or MapConfig.MAP_ORIGIN_Y, p.Y - self.height * 0.5)
end

function MapRenderer.worldToMap(self: MapRenderer, v: Vector3): Vector2
	return Vector2.new(v.X + self.width * 0.5, v.Z + self.height * 0.5)
end

-- Cleanup ------------------------------------------------------------------

function MapRenderer.clear(self: MapRenderer)
	for _, v in self.visuals do
		if v.mesh then
			v.mesh:Destroy()
		end
	end
	table.clear(self.visuals)
	table.clear(self.polygons)
	table.clear(self.emphasis)
	if self.folder then
		self.folder:Destroy()
		self.folder = nil
	end
	-- Defensive: remove any stray map folder (e.g. from a previous script run).
	for _, child in workspace:GetChildren() do
		if child.Name == MAP_FOLDER_NAME then
			child:Destroy()
		end
	end
end

-- Backends -------------------------------------------------------------------

local function addFace(em: EditableMesh, pts: { Vector3 }, reverse: boolean)
	-- Fan-triangulate a convex planar loop. Separate vertices per face so
	-- auto-computed normals stay flat.
	local vids = table.create(#pts)
	for i, p in pts do
		vids[i] = em:AddVertex(p)
	end
	for i = 2, #pts - 1 do
		if reverse then
			em:AddTriangle(vids[1], vids[i + 1], vids[i])
		else
			em:AddTriangle(vids[1], vids[i], vids[i + 1])
		end
	end
end

local function addFaceBothSides(em: EditableMesh, pts: { Vector3 })
	-- Winding convention is not relied upon: emitting both windings with
	-- separate vertices guarantees the visible side is always drawn.
	addFace(em, pts, false)
	addFace(em, pts, true)
end

function MapRenderer._buildMeshVisual(self: MapRenderer, poly: { Vector2 }, color: Color3): Visual
	local thickness = MapConfig.TERRITORY_THICKNESS
	local lo, hi = Geometry.bounds(poly)
	local c = (lo + hi) * 0.5
	local half = thickness * 0.5
	local em = AssetService:CreateEditableMesh()

	local top = table.create(#poly)
	for i, p in poly do
		top[i] = Vector3.new(p.X - c.X, half, p.Y - c.Y)
	end
	addFaceBothSides(em, top)
	local n = #poly
	for i = 1, n do
		local a = poly[i] - c
		local b = poly[i % n + 1] - c
		addFaceBothSides(em, {
			Vector3.new(a.X, half, a.Y),
			Vector3.new(b.X, half, b.Y),
			Vector3.new(b.X, -half, b.Y),
			Vector3.new(a.X, -half, a.Y),
		})
	end

	local part = AssetService:CreateMeshPartAsync(Content.fromObject(em), {
		CollisionFidelity = Enum.CollisionFidelity.Box,
	})
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = MapConfig.TERRITORY_MATERIAL
	part.Color = color
	part.Position = self:mapToWorld(c, MapConfig.MAP_ORIGIN_Y - half)
	return { root = part, parts = { part }, mesh = em, color = color, ownerOutline = nil, height = 0, decor = nil, decorKey = nil }
end

-- Classic two-wedge triangle.
function MapRenderer._drawTriangle(self: MapRenderer, a: Vector3, b: Vector3, c: Vector3, parent: Instance, color: Color3, out: { BasePart })
	local thickness = MapConfig.TERRITORY_THICKNESS
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	if bc.Magnitude < 1e-4 or ab:Cross(ac).Magnitude < 1e-6 then
		return
	end
	local right = ac:Cross(ab).Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local h = math.abs(ab:Dot(up))
	-- Keep the wedge's thickness axis pointing up/down so the slab sits on
	-- the map plane regardless of triangle winding.
	local offset = Vector3.new(0, -thickness * 0.5, 0)

	local w1 = self.wedgeTemplate:Clone()
	w1.Size = Vector3.new(thickness, h, math.abs(ab:Dot(back)))
	w1.CFrame = CFrame.fromMatrix((a + b) * 0.5 + offset, right, up, back)
	w1.Color = color
	w1.Parent = parent
	table.insert(out, w1)

	local w2 = self.wedgeTemplate:Clone()
	w2.Size = Vector3.new(thickness, h, math.abs(ac:Dot(back)))
	w2.CFrame = CFrame.fromMatrix((a + c) * 0.5 + offset, -right, up, -back)
	w2.Color = color
	w2.Parent = parent
	table.insert(out, w2)
end

function MapRenderer._buildWedgeVisual(self: MapRenderer, poly: { Vector2 }, color: Color3): Visual
	local model = Instance.new("Model")
	local parts: { BasePart } = {}
	local y = MapConfig.MAP_ORIGIN_Y
	local p1 = self:mapToWorld(poly[1], y)
	for i = 2, #poly - 1 do
		self:_drawTriangle(p1, self:mapToWorld(poly[i], y), self:mapToWorld(poly[i + 1], y), model, color, parts)
	end
	return { root = model, parts = parts, mesh = nil, color = color, ownerOutline = nil, height = 0, decor = nil, decorKey = nil }
end

-- Public -------------------------------------------------------------------

local function editableMeshAvailable(): boolean
	local ok, em = pcall(function()
		return AssetService:CreateEditableMesh()
	end)
	if ok and em then
		em:Destroy()
		return true
	end
	return false
end

local function plainPart(name: string, color: Color3, size: Vector3, position: Vector3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = MapConfig.TERRITORY_MATERIAL
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Color = color
	p.Size = size
	p.Position = position
	return p
end

-- Parts are limited to 2048 studs per axis, so large flat decorations use a
-- capped part plus a SpecialMesh scale to reach their visual size.
local function scaledPart(name: string, color: Color3, size: Vector3, position: Vector3): Part
	local partSize = Vector3.new(math.min(size.X, 2048), math.min(size.Y, 2048), math.min(size.Z, 2048))
	local p = plainPart(name, color, partSize, position)
	if partSize ~= size then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Brick
		mesh.Scale = Vector3.new(size.X / partSize.X, size.Y / partSize.Y, size.Z / partSize.Z)
		mesh.Parent = p
	end
	return p
end

-- Decorative surroundings: border base, playable-edge frame, sea backdrop.
function MapRenderer._buildSurroundings(self: MapRenderer, folder: Instance)
	local y = MapConfig.MAP_ORIGIN_Y
	local t = MapConfig.TERRITORY_THICKNESS
	local W, H = self.width, self.height
	local surround = Instance.new("Folder")
	surround.Name = "Surroundings"
	surround.Parent = folder

	-- Seen through the gaps between territories: forms every border line.
	scaledPart("BorderBase", MapConfig.BORDER_COLOR, Vector3.new(W + 2, 1, H + 2), Vector3.new(0, y - t * 0.5 - 0.5, 0)).Parent =
		surround

	-- Dark rim just outside the playable rectangle.
	local f = MapConfig.MAP_FRAME_WIDTH
	scaledPart("MapFrame", MapConfig.MAP_FRAME_COLOR, Vector3.new(W + 2 * f, 1, H + 2 * f), Vector3.new(0, y - t * 0.5 - 0.7, 0)).Parent =
		surround

	-- Open sea filling the rest of the view.
	local size = MapConfig.BACKDROP_SIZE
	scaledPart("SeaBackdrop", MapConfig.BACKDROP_COLOR, Vector3.new(size, 1, size), Vector3.new(0, y - t - 2, 0)).Parent = surround
end

-- Thin flat parts along a polygon's edges, just above the surface.
function MapRenderer.buildOutline(self: MapRenderer, polygon: { Vector2 }, width: number, color: Color3, lift: number): Model
	local model = Instance.new("Model")
	model.Name = "Outline"
	-- Sit inside the territory fill: inset past the border gap plus half the line.
	local poly = Geometry.insetConvex(polygon, MapConfig.BORDER_INSET + width * 0.5)
	local y = MapConfig.MAP_ORIGIN_Y + lift
	local n = #poly
	for i = 1, n do
		local a = self:mapToWorld(poly[i], y)
		local b = self:mapToWorld(poly[i % n + 1], y)
		local len = (b - a).Magnitude
		if len > 0.05 then
			local seg = plainPart("Edge", color, Vector3.new(width, 0.2, len + width), (a + b) * 0.5)
			seg.CFrame = CFrame.lookAt((a + b) * 0.5, b)
			seg.Material = Enum.Material.SmoothPlastic
			seg.Parent = model
		end
	end
	return model
end

-- Tile design -----------------------------------------------------------------

local SNOW = Color3.fromRGB(244, 246, 250)

local function decoPart(shape: string, color: Color3, size: Vector3, cf: CFrame, tag: string): BasePart
	local p: BasePart
	if shape == "Wedge" then
		p = Instance.new("WedgePart")
	else
		local part = Instance.new("Part")
		if shape == "Ball" then
			part.Shape = Enum.PartType.Ball
		elseif shape == "Cylinder" then
			part.Shape = Enum.PartType.Cylinder
		end
		p = part
	end
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Color = color
	p.Size = size
	p.CFrame = cf
	p:SetAttribute("DecoTint", tag)
	return p
end

-- Triangular ridge (two wedges back to back), base centred at `base`.
local function ridge(model: Model, base: CFrame, length: number, height: number, width: number, color: Color3, tag: string)
	local c = base * CFrame.new(0, height * 0.5, 0)
	decoPart("Wedge", color, Vector3.new(length, height, width * 0.5), c * CFrame.new(0, 0, -width * 0.25), tag).Parent =
		model
	decoPart("Wedge", color, Vector3.new(length, height, width * 0.5), c * CFrame.new(0, 0, width * 0.25) * CFrame.Angles(0, math.pi, 0), tag).Parent =
		model
end

-- Small deterministic terrain props. Only built for territories the player
-- knows, so decorations can never reveal hidden terrain.
function MapRenderer._buildDecorations(self: MapRenderer, record: any, height: number, color: Color3): Model?
	local def = TerrainTypes.get(record.terrainType)
	local kind = def and def.decoration
	if not kind then
		return nil
	end
	local poly = Geometry.insetConvex(self.polygons[record.id], 7)
	local area = Geometry.signedArea(poly)
	if area < 80 then
		return nil
	end
	local caps = { Trees = 7, Peaks = 3, Snow = 4, Dunes = 3 }
	local n = math.clamp(math.floor(area * MapConfig.DECORATION_DENSITY + 0.5), 1, caps[kind] or 3)
	local rng = Random.new(record.id * 7919 + #kind)
	local lo, hi = Geometry.bounds(poly)
	local top = MapConfig.MAP_ORIGIN_Y + height
	local model = Instance.new("Model")
	model.Name = "Decor_" .. record.id
	local placed, guard = 0, 0
	while placed < n and guard < n * 40 do
		guard += 1
		local p = Vector2.new(rng:NextNumber(lo.X, hi.X), rng:NextNumber(lo.Y, hi.Y))
		if Geometry.pointInConvex(poly, p, 0) then
			placed += 1
			local w = self:mapToWorld(p, top)
			local yaw = rng:NextNumber(0, math.pi * 2)
			if kind == "Trees" then
				local d = rng:NextNumber(7, 10)
				decoPart("Ball", color, Vector3.new(d, d, d), CFrame.new(w + Vector3.new(0, d * 0.3, 0)), "Base").Parent = model
				local d2 = d * rng:NextNumber(0.55, 0.75)
				local off = Vector3.new(math.cos(yaw), 0, math.sin(yaw)) * d * 0.55
				decoPart("Ball", color, Vector3.new(d2, d2, d2), CFrame.new(w + off + Vector3.new(0, d2 * 0.3, 0)), "Base").Parent =
					model
			elseif kind == "Peaks" then
				local L, H, W = rng:NextNumber(12, 18), rng:NextNumber(8, 12), rng:NextNumber(12, 17)
				local base = CFrame.new(w) * CFrame.Angles(0, yaw, 0)
				ridge(model, base, L, H, W, color, "Base")
				local k = 0.36
				ridge(model, base * CFrame.new(0, H * (1 - k), 0), L * k * 1.4, H * k, W * k, SNOW, "Snow")
			elseif kind == "Snow" then
				local d = rng:NextNumber(6, 10)
				decoPart("Cylinder", color, Vector3.new(0.3, d, d), CFrame.new(w + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.pi * 0.5), "Base").Parent =
					model
			elseif kind == "Dunes" then
				ridge(model, CFrame.new(w) * CFrame.Angles(0, yaw, 0), rng:NextNumber(12, 18), rng:NextNumber(1.2, 2), rng:NextNumber(6, 9), color, "Base")
			end
		end
	end
	return model
end

local function moveVisual(v: Visual, dy: number)
	if dy == 0 then
		return
	end
	local root = v.root
	if root:IsA("Model") then
		root:PivotTo(root:GetPivot() + Vector3.new(0, dy, 0))
	elseif root:IsA("BasePart") then
		root.Position += Vector3.new(0, dy, 0)
	end
end

-- World Y of a territory's top surface (outlines sit just above it).
function MapRenderer.surfaceY(self: MapRenderer, id: number): number
	local v = self.visuals[id]
	return MapConfig.MAP_ORIGIN_Y + (if v then v.height else 0)
end

function MapRenderer._applyStyle(self: MapRenderer, record: any)
	local v = self.visuals[record.id]
	if not v then
		return
	end
	local color = TerritoryStyle.fillColor(record, self.emphasis[record.id])
	if v.color ~= color then
		v.color = color
		for _, p in v.parts do
			p.Color = color
		end
	end
	-- Height (known terrain only; unexplored stays flat).
	local h = TerritoryStyle.surfaceHeight(record)
	if v.height ~= h then
		moveVisual(v, h - v.height)
		v.height = h
		if v.decor then
			v.decor:Destroy()
			v.decor = nil
			v.decorKey = nil
		end
	end

	-- Decorations.
	local decoColor = if MapConfig.TILE_DECORATIONS then TerritoryStyle.decorationColor(record) else nil
	local key = if decoColor then record.terrainType else nil
	if key ~= v.decorKey then
		if v.decor then
			v.decor:Destroy()
			v.decor = nil
		end
		v.decorKey = key
		if key and decoColor and self.folder then
			v.decor = self:_buildDecorations(record, h, decoColor)
			if v.decor then
				v.decor.Parent = self.folder:FindFirstChild("Decorations")
			end
		end
	end
	if v.decor and decoColor then
		local snow = if record.state == "Explored" then SNOW:Lerp(MapConfig.FOG_EXPLORED_GREY, MapConfig.FOG_EXPLORED_BLEND) else SNOW
		for _, p in v.decor:GetChildren() do
			if p:IsA("BasePart") then
				p.Color = if p:GetAttribute("DecoTint") == "Snow" then snow else decoColor
			end
		end
	end

	local borderColor = TerritoryStyle.ownerBorderColor(record)
	if v.ownerOutline then
		v.ownerOutline:Destroy()
		v.ownerOutline = nil
	end
	if borderColor and self.folder then
		local outline = self:buildOutline(self.polygons[record.id], MapConfig.OWNER_OUTLINE_WIDTH, borderColor, h + 0.06)
		outline.Name = "OwnerBorder_" .. record.id
		outline.Parent = self.folder:FindFirstChild("OwnerBorders")
		v.ownerOutline = outline
	end
	-- Attributes mirror the client's knowledge for debugging/tests only.
	v.root:SetAttribute("SurfaceHeight", v.height)
	v.root:SetAttribute("Visibility", record.state)
	v.root:SetAttribute("KnownTerrain", record.terrainType)
	v.root:SetAttribute("KnownOwner", record.ownerId)
end

-- Builds every territory visual from the client map state. Returns stats.
function MapRenderer.render(self: MapRenderer, state: any): { [string]: any }
	local t0 = os.clock()
	self:clear()
	self.state = state
	self.width = state.width
	self.height = state.height

	local backend = MapConfig.RENDER_BACKEND
	if backend == "Auto" then
		backend = if editableMeshAvailable() then "EditableMesh" else "Wedge"
	end

	local folder = Instance.new("Folder")
	folder.Name = MAP_FOLDER_NAME
	self.folder = folder
	self:_buildSurroundings(folder)
	local territoriesFolder = Instance.new("Folder")
	territoriesFolder.Name = "Territories"
	territoriesFolder.Parent = folder
	local ownerFolder = Instance.new("Folder")
	ownerFolder.Name = "OwnerBorders"
	ownerFolder.Parent = folder
	local decoFolder = Instance.new("Folder")
	decoFolder.Name = "Decorations"
	decoFolder.Parent = folder
	folder.Parent = workspace

	local failures = 0
	local meshMeshes = 0
	local meshBudgetExhausted = false
	for i, t in state.list do
		local color = TerritoryStyle.fillColor(t)
		self.polygons[t.id] = t.polygon
		local poly = Geometry.insetConvex(t.polygon, MapConfig.BORDER_INSET)
		local visual: Visual
		if backend == "EditableMesh" and not meshBudgetExhausted then
			local ok, result = pcall(function()
				return self:_buildMeshVisual(poly, color)
			end)
			if ok then
				visual = result
				meshMeshes += 1
			else
				-- Usually the client EditableMesh memory budget. Stop trying (each
				-- failed attempt logs an engine error) and use wedges from here on.
				failures += 1
				meshBudgetExhausted = true
				warn(
					string.format(
						"[MapRenderer] EditableMesh unavailable after %d meshes (%s); using wedges for the rest",
						meshMeshes,
						tostring(result)
					)
				)
				visual = self:_buildWedgeVisual(poly, color)
			end
		else
			visual = self:_buildWedgeVisual(poly, color)
		end
		visual.root.Name = "Territory_" .. t.id
		visual.root:SetAttribute("TerritoryId", t.id)
		visual.root.Parent = territoriesFolder
		self.visuals[t.id] = visual
		self:_applyStyle(t)
		if i % MapConfig.RENDER_BATCH_SIZE == 0 then
			task.wait()
		end
	end

	local instanceCount = #folder:GetDescendants()
	local stats = {
		backend = backend,
		renderMs = (os.clock() - t0) * 1000,
		instanceCount = instanceCount,
		meshFallbacks = failures,
		editableMeshes = meshMeshes,
		territoryCount = #state.list,
	}
	self.lastStats = stats
	folder:SetAttribute("Backend", backend)
	folder:SetAttribute("RenderMs", stats.renderMs)
	folder:SetAttribute("InstanceCount", instanceCount)
	folder:SetAttribute("MapVersion", state.version)
	return stats
end

-- Re-styles only the given territories (visibility or ownership changed).
-- All changes are applied in the same frame, so nothing flickers.
function MapRenderer.refresh(self: MapRenderer, state: any, ids: { number })
	for _, id in ids do
		local r = state:get(id)
		if r then
			self:_applyStyle(r)
		end
	end
end

-- Lightens one territory (hover / selection feedback). nil removes it.
function MapRenderer.setEmphasis(self: MapRenderer, id: number, amount: number?)
	if self.emphasis[id] == amount then
		return
	end
	self.emphasis[id] = amount
	local r = self.state and self.state:get(id)
	if r then
		self:_applyStyle(r)
	end
end

-- Re-styles every territory (e.g. civilization colours changed).
function MapRenderer.refreshAll(self: MapRenderer, state: any)
	for _, r in state.list do
		self:_applyStyle(r)
	end
end

function MapRenderer.getVisualRoot(self: MapRenderer, id: number): Instance?
	local v = self.visuals[id]
	return if v then v.root else nil
end

function MapRenderer.getPolygon(self: MapRenderer, id: number): { Vector2 }?
	return self.polygons[id]
end

-- Rendering validation: every territory represented once, visuals match the
-- current data (including fog state), no stray or duplicate map objects.
function MapRenderer.validate(self: MapRenderer, state: any): (boolean, { string })
	local problems: { string } = {}
	for _, t in state.list do
		local v = self.visuals[t.id]
		if not v then
			table.insert(problems, "No visual for territory " .. t.id)
			continue
		end
		if v.root:GetAttribute("TerritoryId") ~= t.id then
			table.insert(problems, "Visual attribute mismatch for territory " .. t.id)
		end
		if v.root:GetAttribute("Visibility") ~= t.state then
			table.insert(problems, "Visual visibility mismatch for territory " .. t.id)
		end
		if #v.parts == 0 then
			table.insert(problems, "Visual has no parts for territory " .. t.id)
		elseif v.parts[1].Color ~= TerritoryStyle.fillColor(t, self.emphasis[t.id]) then
			table.insert(problems, "Visual colour does not match state for territory " .. t.id)
		end
		if not TerritoryStyle.isKnown(t) and (v.decor ~= nil or v.height ~= 0) then
			table.insert(problems, "Fog leak: unexplored territory has terrain height/decorations " .. t.id)
		end
		if v.height ~= TerritoryStyle.surfaceHeight(t) then
			table.insert(problems, "Surface height mismatch for territory " .. t.id)
		end
		local wantBorder = TerritoryStyle.ownerBorderColor(t) ~= nil
		if wantBorder ~= (v.ownerOutline ~= nil) then
			table.insert(problems, "Owner border mismatch for territory " .. t.id)
		end
		if not v.root:IsDescendantOf(workspace) then
			table.insert(problems, "Visual not in workspace for territory " .. t.id)
		end
	end
	local mapFolders = 0
	for _, child in workspace:GetChildren() do
		if child.Name == MAP_FOLDER_NAME then
			mapFolders += 1
		end
	end
	if mapFolders ~= 1 then
		table.insert(problems, string.format("Expected 1 map folder in workspace, found %d", mapFolders))
	end
	if self.folder then
		local territoriesFolder = self.folder:FindFirstChild("Territories")
		local roots = if territoriesFolder then #territoriesFolder:GetChildren() else 0
		if roots ~= #state.list then
			table.insert(problems, string.format("Expected %d territory visuals, found %d", #state.list, roots))
		end
		local borders = self.folder:FindFirstChild("OwnerBorders")
		local expectedBorders = 0
		for _, t in state.list do
			if TerritoryStyle.ownerBorderColor(t) then
				expectedBorders += 1
			end
		end
		if borders and #borders:GetChildren() ~= expectedBorders then
			table.insert(problems, string.format("Expected %d owner borders, found %d", expectedBorders, #borders:GetChildren()))
		end
	end
	local ok = #problems == 0
	if self.folder then
		self.folder:SetAttribute("RenderValidationOk", ok)
		self.folder:SetAttribute("RenderProblems", #problems)
	end
	return ok, problems
end

return MapRenderer
