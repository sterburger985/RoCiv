--!strict
-- TerritoryInfoPanel (client)
-- Strategy-game territory panel, created once and updated in place. Shows
-- only what this player knows: unexplored territories show "Unknown".
-- Sections: Territory · Ownership · Geography · Development. Built from a
-- list layout so later phases can add sections without re-positioning.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("RoCiv"):WaitForChild("Shared")
local TerrainTypes = require(Shared:WaitForChild("TerrainTypes"))
local MapConfig = require(Shared:WaitForChild("MapConfig"))
local TerritoryStyle = require(script.Parent:WaitForChild("TerritoryStyle"))

local GUI_NAME = "TerritoryInfo"

local BG = Color3.fromRGB(20, 22, 28)
local TEXT = Color3.fromRGB(238, 234, 224)
local MUTED = Color3.fromRGB(150, 146, 136)
local GOLD = MapConfig.SELECTION_OUTLINE_COLOR

local TerritoryInfoPanel = {}
TerritoryInfoPanel.__index = TerritoryInfoPanel

export type TerritoryInfoPanel = typeof(setmetatable(
	{} :: {
		gui: ScreenGui,
		frame: Frame,
		title: TextLabel,
		subtitle: TextLabel,
		swatch: Frame,
		values: { [string]: TextLabel },
		ownerChip: Frame,
		neighborList: TextLabel,
		closeButton: TextButton,
	},
	TerritoryInfoPanel
))

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

local function corner(parent: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = parent
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
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.AnchorPoint = Vector2.new(0, 1)
	frame.Position = UDim2.new(0, 14, 1, -14)
	frame.Size = UDim2.fromOffset(268, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundColor3 = BG
	frame.BackgroundTransparency = 0.06
	frame.Visible = false
	frame.Parent = gui
	corner(frame, 8)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(78, 72, 58)
	stroke.Parent = frame
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.PaddingTop = UDim.new(0, 12)
	pad.PaddingBottom = UDim.new(0, 12)
	pad.Parent = frame
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 3)
	list.Parent = frame

	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	-- Header: colour swatch, title, subtitle, close button.
	local header = Instance.new("Frame")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 40)
	header.LayoutOrder = nextOrder()
	header.Parent = frame
	local swatch = Instance.new("Frame")
	swatch.Name = "Swatch"
	swatch.Position = UDim2.fromOffset(0, 4)
	swatch.Size = UDim2.fromOffset(14, 14)
	swatch.BorderSizePixel = 0
	swatch.Parent = header
	corner(swatch, 3)
	local title = label(header, "Territory", TEXT, 18, Enum.Font.GothamBold)
	title.Name = "Title"
	title.Position = UDim2.fromOffset(22, 0)
	title.Size = UDim2.new(1, -54, 0, 22)
	title.TextTruncate = Enum.TextTruncate.AtEnd
	local subtitle = label(header, "", MUTED, 12, Enum.Font.Gotham)
	subtitle.Name = "Subtitle"
	subtitle.Position = UDim2.fromOffset(22, 22)
	subtitle.Size = UDim2.new(1, -54, 0, 16)
	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, 4, 0, -4)
	close.Size = UDim2.fromOffset(28, 28)
	close.BackgroundTransparency = 1
	close.Text = "×"
	close.TextColor3 = MUTED
	close.TextSize = 22
	close.Font = Enum.Font.GothamBold
	close.Parent = header
	close.Activated:Connect(onClose)

	local values: { [string]: TextLabel } = {}
	local function section(name: string)
		local s = label(frame, string.upper(name), GOLD, 11, Enum.Font.GothamBold)
		s.Size = UDim2.new(1, 0, 0, 20)
		s.TextYAlignment = Enum.TextYAlignment.Bottom
		s.LayoutOrder = nextOrder()
		local rule = Instance.new("Frame")
		rule.BackgroundColor3 = GOLD
		rule.BackgroundTransparency = 0.75
		rule.BorderSizePixel = 0
		rule.Size = UDim2.new(1, 0, 0, 1)
		rule.LayoutOrder = nextOrder()
		rule.Parent = frame
	end
	local function row(key: string, text: string): Frame
		local r = Instance.new("Frame")
		r.Name = "Row_" .. key
		r.BackgroundTransparency = 1
		r.Size = UDim2.new(1, 0, 0, 20)
		r.LayoutOrder = nextOrder()
		r.Parent = frame
		local k = label(r, text, MUTED, 13, Enum.Font.Gotham)
		k.Size = UDim2.new(0.45, 0, 1, 0)
		local v = label(r, "-", TEXT, 14, Enum.Font.GothamMedium)
		v.Name = "Value_" .. key
		v.TextXAlignment = Enum.TextXAlignment.Right
		v.Position = UDim2.new(0.45, 0, 0, 0)
		v.Size = UDim2.new(0.55, 0, 1, 0)
		v.TextTruncate = Enum.TextTruncate.AtEnd
		values[key] = v
		return r
	end

	section("Territory")
	row("terrain", "Terrain")
	row("elevation", "Elevation")
	row("fertility", "Fertility")
	row("visibility", "Visibility")

	section("Ownership")
	local ownerRow = row("owner", "Owner")
	local ownerChip = Instance.new("Frame")
	ownerChip.Name = "OwnerChip"
	ownerChip.AnchorPoint = Vector2.new(0, 0.5)
	ownerChip.Position = UDim2.new(0.45, -2, 0.5, 0)
	ownerChip.Size = UDim2.fromOffset(10, 10)
	ownerChip.BorderSizePixel = 0
	ownerChip.Visible = false
	ownerChip.Parent = ownerRow
	corner(ownerChip, 5)

	section("Geography")
	row("kind", "Type")
	row("neighbors", "Neighbours")
	local neighborList = label(frame, "", MUTED, 12, Enum.Font.Code)
	neighborList.Name = "NeighborList"
	neighborList.Size = UDim2.new(1, 0, 0, 0)
	neighborList.AutomaticSize = Enum.AutomaticSize.Y
	neighborList.TextWrapped = true
	neighborList.LayoutOrder = nextOrder()

	section("Development")
	row("city", "City")
	row("resources", "Resources")
	row("movement", "Move cost")

	local hint = label(frame, "Right-click or × to deselect · F frames the map", MUTED, 11, Enum.Font.Gotham)
	hint.Size = UDim2.new(1, 0, 0, 22)
	hint.TextYAlignment = Enum.TextYAlignment.Bottom
	hint.LayoutOrder = nextOrder()

	gui.Parent = playerGui

	return setmetatable({
		gui = gui,
		frame = frame,
		title = title,
		subtitle = subtitle,
		swatch = swatch,
		values = values,
		ownerChip = ownerChip,
		neighborList = neighborList,
		closeButton = close,
	}, TerritoryInfoPanel)
end

local function pct(v: number?): string
	if type(v) ~= "number" then
		return "Unknown"
	end
	return string.format("%d%%", math.floor(v * 100 + 0.5))
end

-- `yourCivilizationId` marks the player's own civilization in the panel.
function TerritoryInfoPanel.show(self: TerritoryInfoPanel, t: any?, yourCivilizationId: number?)
	if not t then
		self.frame.Visible = false
		return
	end
	local known = TerritoryStyle.isKnown(t)
	local def = if known then TerrainTypes.get(t.terrainType) else nil
	local unknown = "Unknown"

	self.title.Text = if def then def.displayName .. " Region" else "Unexplored Region"
	self.subtitle.Text = string.format("Territory #%s", tostring(t.id))
	self.swatch.BackgroundColor3 = TerritoryStyle.fillColor(t)

	self.values.terrain.Text = if def then def.displayName else unknown
	self.values.elevation.Text = if known then pct(t.elevation) else unknown
	self.values.fertility.Text = if known then pct(t.fertility) else unknown
	self.values.visibility.Text = tostring(t.state)

	local ownerColor = if known then TerritoryStyle.ownerColor(t.ownerId) else nil
	if not known then
		self.values.owner.Text = unknown
	else
		local name = TerritoryStyle.ownerName(t.ownerId)
		if t.ownerId and t.ownerId == yourCivilizationId then
			name ..= " (you)"
		end
		if t.state == "Explored" and t.ownerId then
			name ..= " · last seen"
		end
		self.values.owner.Text = name
	end
	self.ownerChip.Visible = ownerColor ~= nil
	if ownerColor then
		self.ownerChip.BackgroundColor3 = ownerColor
	end

	self.values.kind.Text = if def then (if def.isWater then "Water" else "Land") else unknown
	local neighbors = if type(t.neighbors) == "table" then t.neighbors else {}
	self.values.neighbors.Text = tostring(#neighbors)
	local ids = {}
	for _, nb in neighbors do
		table.insert(ids, tostring(nb))
	end
	self.neighborList.Text = if #ids > 0 then "Adjacent: " .. table.concat(ids, ", ") else "Adjacent: none"

	self.values.city.Text = if not known then unknown elseif t.cityId then ("City #" .. tostring(t.cityId)) else "None"
	if not known then
		self.values.resources.Text = unknown
	elseif type(t.resources) == "table" and #t.resources > 0 then
		self.values.resources.Text = tostring(#t.resources) .. " deposits"
	else
		self.values.resources.Text = "None yet"
	end
	if def then
		self.values.movement.Text = if def.isWater
			then string.format("%d (naval)", def.moveCost)
			else string.format("%d (land)", def.moveCost)
	else
		self.values.movement.Text = unknown
	end
	self.frame.Visible = true
end

return TerritoryInfoPanel
