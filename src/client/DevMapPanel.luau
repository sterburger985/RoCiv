--!strict
-- DevMapPanel (client) — DEVELOPMENT ONLY
-- Studio-only tools: regenerate the map, test fog of war, test ownership
-- with the test civilizations, test movement regions / routes, toggle the
-- debug overlay. ClientMain only creates it when RunService:IsStudio() is
-- true and the server exposed the dev remotes (which it only does in
-- Studio). Every action is re-validated on the server. Ordinary players can
-- never reach these tools.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MapConfig = require(ReplicatedStorage:WaitForChild("RoCiv"):WaitForChild("Shared"):WaitForChild("MapConfig"))

local GUI_NAME = "DevMapPanel"

local DevMapPanel = {}
DevMapPanel.__index = DevMapPanel

export type Callbacks = {
	regenerate: (seed: number, matchSize: string) -> (),
	command: (cmd: { [string]: any }) -> { [string]: any },
	selectedId: () -> number?,
	toggleOverlay: () -> boolean,
	movement: {
		setOverlay: (on: boolean) -> (),
		setRouteTool: (on: boolean) -> (),
		setDomain: (domain: string) -> (),
		setRange: (on: boolean, budget: number) -> (),
		buildRoad: () -> number,
	},
}

export type DevMapPanel = typeof(setmetatable(
	{} :: {
		gui: ScreenGui,
		body: Frame,
		seedBox: TextBox,
		sizeBtn: TextButton,
		matchSize: string,
		rangeBox: TextBox,
		budgetBox: TextBox,
		mapStatus: TextLabel,
		civStatus: TextLabel,
		moveStatus: TextLabel,
		actionStatus: TextLabel,
		civRow: Frame,
		cb: Callbacks,
	},
	DevMapPanel
))

local BG = Color3.fromRGB(40, 16, 16)
local TEXT = Color3.fromRGB(240, 230, 220)
local MUTED = Color3.fromRGB(190, 160, 150)
local BTN = Color3.fromRGB(110, 46, 40)
local BTN_HOT = Color3.fromRGB(170, 60, 50)

local function corner(parent: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = parent
end

local function row(parent: Instance, name: string, order: number, h: number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundTransparency = 1
	f.Size = UDim2.new(1, 0, 0, h)
	f.LayoutOrder = order
	f.Parent = parent
	return f
end

local function heading(parent: Instance, order: number, text: string)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, 16)
	l.LayoutOrder = order
	l.Text = text
	l.TextColor3 = Color3.fromRGB(255, 140, 120)
	l.TextSize = 11
	l.Font = Enum.Font.GothamBold
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
end

local function box(parent: Instance, name: string, placeholder: string, x: UDim, w: UDim): TextBox
	local b = Instance.new("TextBox")
	b.Name = name
	b.Position = UDim2.new(x, UDim.new(0, 0))
	b.Size = UDim2.new(w, UDim.new(1, 0))
	b.BackgroundColor3 = Color3.fromRGB(20, 8, 8)
	b.BorderSizePixel = 0
	b.ClearTextOnFocus = false
	b.PlaceholderText = placeholder
	b.PlaceholderColor3 = Color3.fromRGB(120, 90, 85)
	b.Text = ""
	b.TextColor3 = TEXT
	b.TextSize = 13
	b.Font = Enum.Font.Code
	b.Parent = parent
	corner(b, 4)
	return b
end

local function button(parent: Instance, name: string, text: string, x: UDim, w: UDim, hot: boolean?): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Position = UDim2.new(x, UDim.new(0, 0))
	b.Size = UDim2.new(w, UDim.new(1, 0))
	b.BackgroundColor3 = if hot then BTN_HOT else BTN
	b.BorderSizePixel = 0
	b.Text = text
	b.TextColor3 = TEXT
	b.TextSize = 12
	b.Font = Enum.Font.GothamBold
	b.AutoButtonColor = true
	b.Parent = parent
	corner(b, 4)
	return b
end

local function caption(parent: Instance, text: string, x: UDim, w: UDim): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Position = UDim2.new(x, UDim.new(0, 0))
	l.Size = UDim2.new(w, UDim.new(1, 0))
	l.Text = text
	l.TextColor3 = MUTED
	l.TextSize = 12
	l.Font = Enum.Font.Gotham
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

local function statusLabel(parent: Instance, order: number, name: string): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, 0)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.LayoutOrder = order
	l.Text = ""
	l.TextColor3 = MUTED
	l.TextSize = 11
	l.Font = Enum.Font.Code
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.TextWrapped = true
	l.Parent = parent
	return l
end

local function toggle(btn: TextButton, label: string, initial: boolean, onChange: (boolean) -> ())
	local on = initial
	local function paint()
		btn.Text = label .. ": " .. (if on then "ON" else "OFF")
		btn.BackgroundColor3 = if on then BTN_HOT else BTN
	end
	paint()
	btn.Activated:Connect(function()
		on = not on
		paint()
		onChange(on)
	end)
end

function DevMapPanel.new(cb: Callbacks): DevMapPanel
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false

	-- Top-left (the chat window lives top-right).
	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.Position = UDim2.new(0, 12, 0, 52)
	frame.Size = UDim2.fromOffset(276, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundColor3 = BG
	frame.BackgroundTransparency = 0.08
	frame.Parent = gui
	corner(frame, 8)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(200, 70, 60)
	stroke.Parent = frame
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.Parent = frame
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 4)
	list.Parent = frame

	local header = row(frame, "Header", 1, 22)
	local title = caption(header, "DEV ONLY · Map Tools (Studio)", UDim.new(0, 0), UDim.new(1, -30))
	title.TextColor3 = Color3.fromRGB(255, 140, 120)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 14
	local collapse = button(header, "CollapseButton", "–", UDim.new(1, -26), UDim.new(0, 26))

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Size = UDim2.new(1, 0, 0, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.LayoutOrder = 2
	body.Parent = frame
	local blist = Instance.new("UIListLayout")
	blist.SortOrder = Enum.SortOrder.LayoutOrder
	blist.Padding = UDim.new(0, 4)
	blist.Parent = body

	-- Map
	heading(body, 1, "MAP")
	local r1 = row(body, "MapRow", 2, 24)
	caption(r1, "Seed", UDim.new(0, 0), UDim.new(0, 36))
	local seedBox = box(r1, "SeedBox", "12345", UDim.new(0, 36), UDim.new(0.5, -40))
	local sizeBtn = button(r1, "MatchSizeButton", "Size: Quick", UDim.new(0.5, 4), UDim.new(0.5, -4))
	local r2 = row(body, "MapButtons", 3, 24)
	local regen = button(r2, "RegenerateButton", "Regenerate", UDim.new(0, 0), UDim.new(0.5, -3), true)
	local random = button(r2, "RandomSeedButton", "Random seed", UDim.new(0.5, 3), UDim.new(0.5, -3))
	local mapStatus = statusLabel(body, 4, "Status")

	-- Fog of war
	heading(body, 10, "FOG OF WAR")
	local r3 = row(body, "FogRow", 11, 24)
	local reveal = button(r3, "RevealAllButton", "", UDim.new(0, 0), UDim.new(0.5, -3))
	local clear = button(r3, "ClearVisionButton", "Remove all vision", UDim.new(0.5, 3), UDim.new(0.5, -3))
	local r4 = row(body, "VisionRow", 12, 24)
	caption(r4, "Range", UDim.new(0, 0), UDim.new(0, 40))
	local rangeBox = box(r4, "RangeBox", "2", UDim.new(0, 40), UDim.new(0, 34))
	local addVision = button(r4, "AddVisionButton", "Add vision at selected", UDim.new(0, 80), UDim.new(1, -80), true)

	-- Ownership (test civilizations)
	heading(body, 20, "OWNERSHIP · selected territory")
	local civRow = row(body, "CivRow", 21, 24)
	local civStatus = statusLabel(body, 22, "CivStatus")

	-- Movement (Phase 3)
	heading(body, 30, "MOVEMENT REGIONS")
	local r6 = row(body, "MoveRow1", 31, 24)
	local regionsBtn = button(r6, "RegionsButton", "", UDim.new(0, 0), UDim.new(0.5, -3))
	local routeBtn = button(r6, "RouteToolButton", "", UDim.new(0.5, 3), UDim.new(0.5, -3))
	local r7 = row(body, "MoveRow2", 32, 24)
	local domainBtn = button(r7, "DomainButton", "Domain: Land", UDim.new(0, 0), UDim.new(0.38, -3))
	local rangeBtn = button(r7, "RangeButton", "", UDim.new(0.38, 3), UDim.new(0.37, -3))
	caption(r7, "MP", UDim.new(0.75, 4), UDim.new(0, 20))
	local budgetBox = box(r7, "BudgetBox", "6", UDim.new(0.75, 24), UDim.new(0.25, -24))
	budgetBox.Text = "6"
	local r7b = row(body, "MoveRow3", 33, 24)
	local roadBtn = button(r7b, "RoadButton", "Road along route (test)", UDim.new(0, 0), UDim.new(1, 0))
	local moveStatus = statusLabel(body, 34, "MoveStatus")

	-- Debug
	heading(body, 40, "DEBUG")
	local r8 = row(body, "DebugRow", 41, 24)
	local overlay = button(r8, "OverlayButton", "", UDim.new(0, 0), UDim.new(1, 0))
	local actionStatus = statusLabel(body, 50, "ActionStatus")

	gui.Parent = playerGui

	local self = setmetatable({
		gui = gui,
		body = body,
		seedBox = seedBox,
		sizeBtn = sizeBtn,
		matchSize = MapConfig.DEFAULT_MATCH_SIZE,
		rangeBox = rangeBox,
		budgetBox = budgetBox,
		mapStatus = mapStatus,
		civStatus = civStatus,
		moveStatus = moveStatus,
		actionStatus = actionStatus,
		civRow = civRow,
		cb = cb,
	}, DevMapPanel)

	local function say(text: string)
		actionStatus.Text = text
	end

	local function submit()
		local seed = tonumber(seedBox.Text)
		if not seed then
			say("Enter a numeric seed.")
			return
		end
		mapStatus.Text = string.format("Regenerating %s map, seed %d…", self.matchSize, seed)
		cb.regenerate(math.floor(seed), self.matchSize)
	end
	regen.Activated:Connect(submit)
	local function showSize()
		local def = MapConfig.MATCH_SIZES[self.matchSize]
		sizeBtn.Text = string.format("%s · %d civs", self.matchSize, def.civilizations)
	end
	showSize()
	sizeBtn.Activated:Connect(function()
		local order = MapConfig.MATCH_SIZE_ORDER
		local i = table.find(order, self.matchSize) or 0
		self.matchSize = order[i % #order + 1]
		showSize()
		say(string.format("Match size %s selected — press Regenerate.", self.matchSize))
	end)
	random.Activated:Connect(function()
		seedBox.Text = tostring(math.random(1, 2 ^ 30))
		submit()
	end)
	collapse.Activated:Connect(function()
		body.Visible = not body.Visible
		collapse.Text = if body.Visible then "–" else "+"
	end)

	toggle(reveal, "Reveal all", false, function(on)
		local res = cb.command({ cmd = "RevealAll", value = on })
		say(string.format("Reveal all %s (%d territories changed)", if on then "on" else "off", res.changed or 0))
	end)
	clear.Activated:Connect(function()
		local res = cb.command({ cmd = "ClearVision" })
		say(string.format("All vision removed (%d changed). Explored areas stay explored.", res.changed or 0))
	end)
	addVision.Activated:Connect(function()
		local id = cb.selectedId()
		local range = tonumber(rangeBox.Text) or 2
		if not id then
			say("Select a territory first.")
			return
		end
		local res = cb.command({ cmd = "AddVision", territoryId = id, range = math.floor(range) })
		say(string.format("Vision source #%s at %d, range %d (%d changed)", tostring(res.sourceId), id, range, res.changed or 0))
	end)

	toggle(regionsBtn, "Regions", false, cb.movement.setOverlay)
	toggle(routeBtn, "Route tool", false, cb.movement.setRouteTool)
	local domain = "Land"
	domainBtn.Activated:Connect(function()
		domain = if domain == "Land" then "Naval" else "Land"
		domainBtn.Text = "Domain: " .. domain
		cb.movement.setDomain(domain)
	end)
	toggle(rangeBtn, "Range", false, function(on)
		cb.movement.setRange(on, tonumber(budgetBox.Text) or 6)
	end)
	budgetBox.FocusLost:Connect(function()
		local b = tonumber(budgetBox.Text)
		if b then
			cb.movement.setRange(rangeBtn.Text:find("ON") ~= nil, b)
		end
	end)

	roadBtn.Activated:Connect(function()
		local n = cb.movement.buildRoad()
		say(string.format("Road placed on %d land regions of the route", n))
	end)

	toggle(overlay, "Overlay (ids + links)", false, function()
		cb.toggleOverlay()
	end)

	return self
end

-- Rebuilds the civilization buttons from the server's civilization list.
function DevMapPanel.setCivilizations(self: DevMapPanel, civs: { any })
	for _, c in self.civRow:GetChildren() do
		c:Destroy()
	end
	local n = #civs + 1
	local w = 1 / n
	for i, civ in civs do
		local short = string.match(civ.displayName, "Civilization (%w+)") or tostring(civ.civilizationId)
		local b = button(self.civRow, "Civ" .. civ.civilizationId .. "Button", short, UDim.new(w * (i - 1), 2), UDim.new(w, -4))
		b.BackgroundColor3 = civ.color:Lerp(Color3.new(0, 0, 0), 0.25)
		b.Activated:Connect(function()
			local id = self.cb.selectedId()
			if not id then
				self.actionStatus.Text = "Select a territory first."
				return
			end
			local res = self.cb.command({ cmd = "AssignOwner", territoryId = id, civilizationId = civ.civilizationId })
			self.actionStatus.Text = if res.ok
				then string.format("Territory %d -> %s", id, civ.displayName)
				else "Owner unchanged (" .. tostring(res.message) .. ")"
			self:refreshCivStatus()
		end)
	end
	local none = button(self.civRow, "UnownedButton", "None", UDim.new(w * (n - 1), 2), UDim.new(w, -4))
	none.Activated:Connect(function()
		local id = self.cb.selectedId()
		if not id then
			self.actionStatus.Text = "Select a territory first."
			return
		end
		local res = self.cb.command({ cmd = "ClearOwner", territoryId = id })
		self.actionStatus.Text = if res.ok then string.format("Territory %d is now unowned", id) else "Owner unchanged (" .. tostring(res.message) .. ")"
		self:refreshCivStatus()
	end)
	self:refreshCivStatus()
end

-- Shows each civilization's territory list straight from the server index.
function DevMapPanel.refreshCivStatus(self: DevMapPanel)
	task.spawn(function()
		local res = self.cb.command({ cmd = "CivStatus" })
		if not res.ok then
			return
		end
		local lines = {}
		for _, c in res.civilizations do
			local ids = {}
			for i, id in c.territories do
				if i > 8 then
					table.insert(ids, "…")
					break
				end
				table.insert(ids, tostring(id))
			end
			table.insert(
				lines,
				string.format("%s [%s]: %d (%s)", c.displayName, c.controllerType, #c.territories, table.concat(ids, ","))
			)
		end
		table.insert(lines, "Ownership index valid: " .. tostring(res.ownershipValid))
		self.civStatus.Text = table.concat(lines, "\n")
	end)
end

function DevMapPanel.setMovementStatus(self: DevMapPanel, text: string)
	self.moveStatus.Text = text
end

function DevMapPanel.update(self: DevMapPanel, devInfo: any, renderStats: any, renderOk: boolean, counts: { [string]: number }?)
	if devInfo then
		self.seedBox.Text = tostring(devInfo.seed)
		if devInfo.matchSize and MapConfig.MATCH_SIZES[devInfo.matchSize] then
			self.matchSize = devInfo.matchSize
			local def = MapConfig.MATCH_SIZES[devInfo.matchSize]
			self.sizeBtn.Text = string.format("%s · %d civs", devInfo.matchSize, def.civilizations)
		end
	end
	local lines = {}
	if devInfo then
		table.insert(lines, string.format("World %d x %d · %d territories · %s regions", devInfo.width, devInfo.height, devInfo.territoryCount, tostring(devInfo.regionCount)))
		table.insert(lines, string.format("%s · %d continents · %d rivers · %d starts · attempt %d", tostring(devInfo.matchSize), devInfo.continents or 0, devInfo.rivers or 0, devInfo.starts or 0, devInfo.attempt or 1))
		table.insert(
			lines,
			string.format(
				"Map %s · movement %s · gen %.0f ms",
				if devInfo.validationOk then "PASS" else "FAIL",
				if devInfo.movementOk then "PASS" else "FAIL",
				devInfo.generationMs
			)
		)
	end
	if renderStats then
		table.insert(lines, string.format("Render %.0f ms · %d instances · check %s", renderStats.renderMs, renderStats.instanceCount, if renderOk then "PASS" else "FAIL"))
	end
	if counts then
		table.insert(lines, string.format("Fog: %d visible · %d explored · %d unexplored", counts.Visible, counts.Explored, counts.Unexplored))
	end
	self.mapStatus.Text = table.concat(lines, "\n")
	self.mapStatus.TextColor3 = if (devInfo == nil or (devInfo.validationOk and devInfo.movementOk)) and renderOk
		then Color3.fromRGB(170, 220, 160)
		else Color3.fromRGB(255, 140, 120)
end

return DevMapPanel
