--!strict
-- TerritoryInfoPanel (client)
-- Reusable panel showing the selected territory's data. Created once; it
-- only updates text on selection changes (no UI is recreated).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("RoCiv"):WaitForChild("Shared")
local TerrainTypes = require(Shared:WaitForChild("TerrainTypes"))

local GUI_NAME = "TerritoryInfo"

local TerritoryInfoPanel = {}
TerritoryInfoPanel.__index = TerritoryInfoPanel

export type TerritoryInfoPanel = typeof(setmetatable(
	{} :: {
		gui: ScreenGui,
		frame: Frame,
		title: TextLabel,
		swatch: Frame,
		values: { [string]: TextLabel },
		closeButton: TextButton,
	},
	TerritoryInfoPanel
))

local FIELDS = {
	{ key = "id", label = "Territory ID" },
	{ key = "terrain", label = "Terrain" },
	{ key = "elevation", label = "Elevation" },
	{ key = "fertility", label = "Fertility" },
	{ key = "neighbors", label = "Neighbours" },
	{ key = "owner", label = "Owner" },
}

local BG = Color3.fromRGB(22, 24, 30)
local TEXT = Color3.fromRGB(236, 232, 222)
local MUTED = Color3.fromRGB(150, 148, 140)
local ACCENT = Color3.fromRGB(255, 220, 90)

local function label(parent: Instance, text: string, color: Color3, size: number, font: Enum.Font): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextColor3 = color
	l.TextSize = size
	l.Font = font
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

function TerritoryInfoPanel.new(onClose: () -> ()): TerritoryInfoPanel
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.AnchorPoint = Vector2.new(0, 1)
	frame.Position = UDim2.new(0, 16, 1, -16)
	frame.Size = UDim2.fromOffset(260, 236)
	frame.BackgroundColor3 = BG
	frame.BackgroundTransparency = 0.08
	frame.Visible = false
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(70, 66, 56)
	stroke.Thickness = 1
	stroke.Parent = frame

	local swatch = Instance.new("Frame")
	swatch.Name = "Swatch"
	swatch.Position = UDim2.fromOffset(16, 18)
	swatch.Size = UDim2.fromOffset(14, 14)
	swatch.BorderSizePixel = 0
	swatch.Parent = frame
	local sc = Instance.new("UICorner")
	sc.CornerRadius = UDim.new(0, 3)
	sc.Parent = swatch

	local title = label(frame, "Territory", TEXT, 20, Enum.Font.GothamBold)
	title.Name = "Title"
	title.Position = UDim2.fromOffset(38, 12)
	title.Size = UDim2.new(1, -80, 0, 26)

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -10, 0, 10)
	close.Size = UDim2.fromOffset(28, 28)
	close.BackgroundTransparency = 1
	close.Text = "×"
	close.TextColor3 = MUTED
	close.TextSize = 24
	close.Font = Enum.Font.GothamBold
	close.Parent = frame
	close.Activated:Connect(onClose)

	local rule = Instance.new("Frame")
	rule.Position = UDim2.fromOffset(16, 46)
	rule.Size = UDim2.new(1, -32, 0, 1)
	rule.BackgroundColor3 = ACCENT
	rule.BackgroundTransparency = 0.6
	rule.BorderSizePixel = 0
	rule.Parent = frame

	local values: { [string]: TextLabel } = {}
	for i, f in FIELDS do
		local y = 56 + (i - 1) * 26
		local k = label(frame, f.label, MUTED, 14, Enum.Font.Gotham)
		k.Position = UDim2.fromOffset(16, y)
		k.Size = UDim2.new(0.5, -16, 0, 22)
		local v = label(frame, "-", TEXT, 15, Enum.Font.GothamMedium)
		v.Name = "Value_" .. f.key
		v.TextXAlignment = Enum.TextXAlignment.Right
		v.Position = UDim2.new(0.5, 0, 0, y)
		v.Size = UDim2.new(0.5, -16, 0, 22)
		values[f.key] = v
	end

	local hint = label(frame, "Esc or × to deselect", MUTED, 12, Enum.Font.Gotham)
	hint.Position = UDim2.new(0, 16, 1, -24)
	hint.Size = UDim2.new(1, -32, 0, 16)

	gui.Parent = playerGui

	return setmetatable({
		gui = gui,
		frame = frame,
		title = title,
		swatch = swatch,
		values = values,
		closeButton = close,
	}, TerritoryInfoPanel)
end

local function pct(v: number): string
	return string.format("%d%%", math.floor(v * 100 + 0.5))
end

function TerritoryInfoPanel.show(self: TerritoryInfoPanel, t: any?)
	if not t then
		self.frame.Visible = false
		return
	end
	local def = TerrainTypes.get(t.terrainType)
	self.title.Text = (if def then def.displayName else t.terrainType) .. " Region"
	self.swatch.BackgroundColor3 = if def then def.color else Color3.new(1, 0, 1)
	self.values.id.Text = tostring(t.id)
	self.values.terrain.Text = if def then def.displayName else t.terrainType
	self.values.elevation.Text = pct(t.elevation)
	self.values.fertility.Text = pct(t.fertility)
	self.values.neighbors.Text = tostring(#t.neighbors)
	self.values.owner.Text = if t.ownerId then ("Civilization " .. tostring(t.ownerId)) else "Unowned"
	self.frame.Visible = true
end

return TerritoryInfoPanel
