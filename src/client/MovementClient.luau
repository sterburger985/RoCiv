--!strict
-- MovementClient (client, Phase 3)
-- Client side of the movement-region layer:
--   * downloads region geometry/topology (no terrain - that comes from the
--     player's own territory knowledge)
--   * optional overlay of movement-region borders inside known territories
--   * route tool: click a start region and a goal region; the SERVER plans the
--     route with this player's knowledge and the client draws it
--   * range preview: regions reachable from the start within a budget
-- Everything drawn here is presentation; routes and costs come from the server.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("RoCiv"):WaitForChild("Shared")
local MapConfig = require(Shared:WaitForChild("MapConfig"))
local MapQuery = require(Shared:WaitForChild("MapQuery"))

local FOLDER_NAME = "RoCivMovement"

local MovementClient = {}
MovementClient.__index = MovementClient

export type MovementClient = typeof(setmetatable(
	{} :: {
		renderer: any,
		state: any,
		remotes: Folder,
		version: number,
		regions: { [number]: any },
		list: { any },
		query: any,
		folder: Folder,
		overlayOn: boolean,
		routeToolOn: boolean,
		showRange: boolean,
		domain: string,
		budget: number,
		startId: number?,
		goalId: number?,
		lastRoute: any,
		statusListeners: { (text: string) -> () },
	},
	MovementClient
))

local function linePart(a: Vector3, b: Vector3, width: number, color: Color3, transparency: number, neon: boolean): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = if neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
	p.Color = color
	p.Transparency = transparency
	p.Size = Vector3.new(width, 0.2, (b - a).Magnitude + width * 0.5)
	p.CFrame = CFrame.lookAt((a + b) * 0.5, b)
	return p
end

local function dot(pos: Vector3, diameter: number, color: Color3): Part
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Cylinder
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = Vector3.new(0.3, diameter, diameter)
	p.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.pi * 0.5)
	return p
end

function MovementClient.new(renderer: any, state: any, remotes: Folder): MovementClient
	local old = workspace:FindFirstChild(FOLDER_NAME)
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = workspace
	return setmetatable({
		renderer = renderer,
		state = state,
		remotes = remotes,
		version = 0,
		regions = {},
		list = {},
		query = nil,
		folder = folder,
		overlayOn = false,
		routeToolOn = false,
		showRange = false,
		domain = "Land",
		budget = 6,
		startId = nil,
		goalId = nil,
		lastRoute = nil,
		statusListeners = {},
	}, MovementClient)
end

function MovementClient.onStatus(self: MovementClient, fn: (text: string) -> ())
	table.insert(self.statusListeners, fn)
end

function MovementClient._status(self: MovementClient, text: string)
	for _, fn in self.statusListeners do
		fn(text)
	end
end

function MovementClient._sub(self: MovementClient, name: string): Folder
	local f = self.folder:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = self.folder
	end
	return f :: Folder
end

function MovementClient._clearSub(self: MovementClient, name: string)
	local f = self.folder:FindFirstChild(name)
	if f then
		f:Destroy()
	end
end

-- Called after every map (re)load.
function MovementClient.load(self: MovementClient)
	self:resetRoute()
	self:_clearSub("RegionBorders")
	self:_clearSub("Roads") -- a new map starts without roads
	local payload = (self.remotes:WaitForChild("GetMovementGraph") :: RemoteFunction):InvokeServer()
	self.version = payload.version
	self.list = payload.regions
	table.clear(self.regions)
	for _, r in payload.regions do
		self.regions[r.id] = r
	end
	self.query = MapQuery.new(payload.regions, self.state.width, self.state.height)
	Players.LocalPlayer:SetAttribute("MovementRegions", #payload.regions)
	if self.overlayOn then
		self:drawRegionBorders()
	end
end

function MovementClient.regionAtScreen(self: MovementClient, world: Vector3?): number?
	if not world or not self.query then
		return nil
	end
	return self.query:territoryAt(self.renderer:worldToMap(world))
end

function MovementClient._centroidWorld(self: MovementClient, rid: number, lift: number): Vector3
	local r = self.regions[rid]
	return self.renderer:mapToWorld(r.centroid, self.renderer:surfaceY(r.territoryId) + lift)
end

-- Region borders inside known territories (territory borders are already
-- drawn by the map). Unexplored territories are skipped to keep fog clean.
function MovementClient.drawRegionBorders(self: MovementClient)
	self:_clearSub("RegionBorders")
	local folder = self:_sub("RegionBorders")
	local count = 0
	for _, r in self.list do
		local rec = self.state:get(r.territoryId)
		if rec and rec.state ~= "Unexplored" then
			for _, nbId in r.neighbors do
				local o = self.regions[nbId]
				if o and nbId > r.id and o.territoryId == r.territoryId then
					-- Find the shared edge (endpoints match in reverse order).
					local n, m = #r.polygon, #o.polygon
					for i = 1, n do
						local a, b = r.polygon[i], r.polygon[i % n + 1]
						for k = 1, m do
							local c, d = o.polygon[k], o.polygon[k % m + 1]
							if (a - d).Magnitude < 0.05 and (b - c).Magnitude < 0.05 then
								local y = self.renderer:surfaceY(r.territoryId) + 0.08
								-- Light lines read clearly on every terrain colour.
								local part = linePart(self.renderer:mapToWorld(a, y), self.renderer:mapToWorld(b, y), 1.1, Color3.fromRGB(245, 240, 225), 0.35, false)
								part.Parent = folder
								count += 1
							end
						end
					end
				end
			end
		end
	end
	Players.LocalPlayer:SetAttribute("RegionBorderParts", count)
end

function MovementClient.setOverlay(self: MovementClient, on: boolean)
	self.overlayOn = on
	if on then
		self:drawRegionBorders()
	else
		self:_clearSub("RegionBorders")
	end
end

-- Fog changed: keep the overlay in step with what is known.
function MovementClient.onVisibilityChanged(self: MovementClient)
	if self.overlayOn then
		self:drawRegionBorders()
	end
end

function MovementClient.resetRoute(self: MovementClient)
	self.startId = nil
	self.goalId = nil
	self.lastRoute = nil
	self:_clearSub("Route")
	self:_clearSub("Range")
	local p = Players.LocalPlayer
	p:SetAttribute("RouteStart", 0)
	p:SetAttribute("RouteGoal", 0)
	p:SetAttribute("RouteCost", -1)
end

function MovementClient.setRouteTool(self: MovementClient, on: boolean)
	self.routeToolOn = on
	if not on then
		self:resetRoute()
	end
	self:_status(if on then "Route tool: click a start region, then a goal." else "Route tool off.")
end

function MovementClient.setDomain(self: MovementClient, domain: string)
	self.domain = domain
	if self.startId then
		self:_refreshPreviews()
	end
end

function MovementClient.setRange(self: MovementClient, on: boolean, budget: number?)
	self.showRange = on
	if budget then
		self.budget = budget
	end
	if self.startId then
		self:_refreshPreviews()
	else
		self:_clearSub("Range")
	end
end

function MovementClient._drawMarker(self: MovementClient, rid: number, color: Color3, name: string)
	local folder = self:_sub("Route")
	local m = dot(self:_centroidWorld(rid, 0.3), 16, color)
	m.Name = name
	m.Parent = folder
end

function MovementClient._requestRange(self: MovementClient)
	self:_clearSub("Range")
	if not self.showRange or not self.startId then
		return
	end
	local res = (self.remotes:WaitForChild("RequestRange") :: RemoteFunction):InvokeServer(self.startId, self.budget, self.domain)
	if not res or not res.ok or res.version ~= self.state.version then
		return
	end
	local folder = self:_sub("Range")
	for _, entry in res.regions do
		if self.regions[entry.id] then
			local frac = if res.budget > 0 then entry.cost / res.budget else 0
			local color = Color3.fromRGB(90, 230, 140):Lerp(Color3.fromRGB(255, 170, 60), math.clamp(frac, 0, 1))
			local d = dot(self:_centroidWorld(entry.id, 0.25), 9, color)
			d.Parent = folder
		end
	end
	Players.LocalPlayer:SetAttribute("RangeCount", #res.regions)
end

function MovementClient._requestRoute(self: MovementClient)
	local p = Players.LocalPlayer
	if not self.startId or not self.goalId then
		return
	end
	local res = (self.remotes:WaitForChild("RequestRoute") :: RemoteFunction):InvokeServer(self.startId, self.goalId, self.domain)
	self.lastRoute = res
	-- Keep the start/goal markers, redraw the line.
	local folder = self:_sub("Route")
	for _, c in folder:GetChildren() do
		if c.Name == "Step" or c.Name == "StepCasing" or c.Name == "CostLabel" then
			c:Destroy()
		end
	end
	if not res or not res.ok then
		p:SetAttribute("RouteCost", -1)
		self:_status("No route: " .. tostring(res and res.reason))
		return
	end
	if res.version ~= self.state.version then
		return
	end
	for i = 2, #res.path do
		local a = self:_centroidWorld(res.path[i - 1], 0.45)
		local b = self:_centroidWorld(res.path[i], 0.45)
		-- Dark casing under a bright core keeps the route readable on light tiles.
		local casing = linePart(a - Vector3.new(0, 0.05, 0), b - Vector3.new(0, 0.05, 0), 6.5, Color3.fromRGB(28, 24, 18), 0.1, false)
		casing.Name = "StepCasing"
		casing.Parent = folder
		local seg = linePart(a, b, 3.4, Color3.fromRGB(255, 205, 70), 0, true)
		seg.Name = "Step"
		seg.Parent = folder
	end
	-- Cost label above the goal.
	local anchor = Instance.new("Part")
	anchor.Name = "CostLabel"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.Position = self:_centroidWorld(self.goalId, 2)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(150, 26)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 6, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
	t.BackgroundTransparency = 0.15
	t.TextColor3 = Color3.fromRGB(255, 220, 90)
	t.Font = Enum.Font.GothamBold
	t.TextSize = 13
	t.Text = string.format("%s · cost %g · %d steps", self.domain, res.cost, #res.path - 1)
	t.Parent = bb
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = t
	bb.Parent = anchor
	anchor.Parent = folder
	p:SetAttribute("RouteCost", res.cost)
	p:SetAttribute("RouteSteps", #res.path - 1)
	self:_status(string.format("Route %d -> %d: cost %g, %d steps (%d nodes searched)", self.startId, self.goalId, res.cost, #res.path - 1, res.expanded))
end

function MovementClient._refreshPreviews(self: MovementClient)
	self:_requestRange()
	if self.goalId then
		self:_requestRoute()
	end
end

-- Left-click handler while the route tool is on. Returns true if consumed.
function MovementClient.handleClick(self: MovementClient, world: Vector3?): boolean
	if not self.routeToolOn then
		return false
	end
	local rid = self:regionAtScreen(world)
	if not rid then
		return true
	end
	local p = Players.LocalPlayer
	if not self.startId or self.goalId then
		self:resetRoute()
		self.startId = rid
		p:SetAttribute("RouteStart", rid)
		self:_drawMarker(rid, Color3.fromRGB(90, 230, 140), "Start")
		self:_requestRange()
		self:_status(string.format("Start region %d (territory %d). Click a goal region.", rid, self.regions[rid].territoryId))
	else
		self.goalId = rid
		p:SetAttribute("RouteGoal", rid)
		self:_drawMarker(rid, Color3.fromRGB(255, 120, 90), "Goal")
		self:_requestRoute()
	end
	return true
end

-- Programmatic entry (dev panel / tests): plan a route between two regions.
function MovementClient.planRoute(self: MovementClient, startId: number, goalId: number)
	self:resetRoute()
	self.startId = startId
	self:_drawMarker(startId, Color3.fromRGB(90, 230, 140), "Start")
	self.goalId = goalId
	self:_drawMarker(goalId, Color3.fromRGB(255, 120, 90), "Goal")
	self:_requestRange()
	self:_requestRoute()
end

-- Development: mark the land regions of the current route as road (server
-- validates) and draw the road. Re-plans so the new cost is shown.
function MovementClient.buildRoadAlongRoute(self: MovementClient, devCommand: (any) -> any): number
	local route = self.lastRoute
	if not route or not route.ok then
		self:_status("Plan a route first.")
		return 0
	end
	local res = devCommand({ cmd = "SetRoads", regionIds = route.path, value = true })
	if not res or not res.ok then
		self:_status("Road command rejected.")
		return 0
	end
	local folder = self:_sub("Roads")
	for i = 2, #route.path do
		local a, b = route.path[i - 1], route.path[i]
		local ra, rb = self.regions[a], self.regions[b]
		if ra and rb then
			local seg = linePart(self:_centroidWorld(a, 0.3), self:_centroidWorld(b, 0.3), 2.2, Color3.fromRGB(122, 92, 60), 0, false)
			seg.Name = "Road"
			seg.Parent = folder
		end
	end
	self:_requestRoute()
	return res.changed or 0
end

function MovementClient.clearAll(self: MovementClient)
	self:resetRoute()
	self:_clearSub("RegionBorders")
end

return MovementClient
