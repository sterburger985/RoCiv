--!strict
-- DebugOverlay (client, development aid)
-- Draws territory id labels and neighbour links (centroid to centroid) so
-- adjacency can be checked by eye. Only shows what the client already knows
-- (geometry and neighbour ids are sent for every territory). Rebuilt on map
-- change; never left behind.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("RoCiv"):WaitForChild("Shared")
local MapConfig = require(Shared:WaitForChild("MapConfig"))

local FOLDER_NAME = "RoCivDebugOverlay"

local DebugOverlay = {}
DebugOverlay.__index = DebugOverlay

export type DebugOverlay = typeof(setmetatable({} :: { enabled: boolean, folder: Folder? }, DebugOverlay))

function DebugOverlay.new(): DebugOverlay
	return setmetatable({ enabled = false, folder = nil }, DebugOverlay)
end

function DebugOverlay.clear(self: DebugOverlay)
	if self.folder then
		self.folder:Destroy()
		self.folder = nil
	end
	for _, c in workspace:GetChildren() do
		if c.Name == FOLDER_NAME then
			c:Destroy()
		end
	end
end

function DebugOverlay.build(self: DebugOverlay, state: any, renderer: any)
	self:clear()
	if not self.enabled then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	local y = MapConfig.MAP_ORIGIN_Y + 0.3
	for _, r in state.list do
		local anchor = Instance.new("Part")
		anchor.Name = "Id_" .. r.id
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.Transparency = 1
		anchor.Size = Vector3.new(1, 1, 1)
		anchor.Position = renderer:mapToWorld(r.centroid, y)
		local bb = Instance.new("BillboardGui")
		bb.Size = UDim2.fromOffset(40, 16)
		bb.AlwaysOnTop = true
		bb.LightInfluence = 0
		bb.MaxDistance = 6000
		local t = Instance.new("TextLabel")
		t.BackgroundTransparency = 1
		t.Size = UDim2.fromScale(1, 1)
		t.Text = tostring(r.id)
		t.TextColor3 = Color3.new(1, 1, 1)
		t.TextStrokeTransparency = 0.3
		t.TextSize = 12
		t.Font = Enum.Font.GothamBold
		t.Parent = bb
		bb.Parent = anchor
		anchor.Parent = folder

		for _, nb in r.neighbors do
			if nb > r.id then
				local o = state:get(nb)
				if o then
					local a = renderer:mapToWorld(r.centroid, y)
					local b = renderer:mapToWorld(o.centroid, y)
					local link = Instance.new("Part")
					link.Name = string.format("Link_%d_%d", r.id, nb)
					link.Anchored = true
					link.CanCollide = false
					link.CanQuery = false
					link.CanTouch = false
					link.Material = Enum.Material.Neon
					link.Color = Color3.fromRGB(255, 255, 255)
					link.Transparency = 0.35
					link.Size = Vector3.new(0.6, 0.2, (b - a).Magnitude)
					link.CFrame = CFrame.lookAt((a + b) * 0.5, b)
					link.Parent = folder
				end
			end
		end
	end
	folder.Parent = workspace
	self.folder = folder
end

function DebugOverlay.toggle(self: DebugOverlay, state: any, renderer: any): boolean
	self.enabled = not self.enabled
	self:build(state, renderer)
	return self.enabled
end

return DebugOverlay
