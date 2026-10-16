--!strict
-- DevMapPanel (client) — DEVELOPMENT ONLY
-- Studio-only tools: regenerate the map, test fog of war (vision sources,
-- reveal all), test ownership, toggle the debug overlay. ClientMain only
-- creates it when RunService:IsStudio() is true and the server exposed the
-- dev remotes (which it only does in Studio). Every action is re-validated
-- on the server.

local Players = game:GetService("Players")

local GUI_NAME = "DevMapPanel"

local DevMapPanel = {}
DevMapPanel.__index = DevMapPanel

export type Callbacks = {
	regenerate: (seed: number, count: number) -> (),
	command: (cmd: { [string]: any }) -> { [string]: any },
	selectedId: () -> number?,
	toggleOverlay: () -> boolean,
}

export type DevMapPanel = typeof(setmetatable(
	{} :: {
		gui: ScreenGui,
		body: Frame,
		seedBox: TextBox,
		countBox: TextBox,
		rangeBox: TextBox,
		ownerBox: TextBox,
		mapStatus: TextLabel,
		actionStatus: TextLabel,
		revealButton: TextButton,
		overlayButton: TextButton,
		collapseButton: TextButton,
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

local function row(parent: Instance, order: number, h: number): Frame
	local f = Instance.new("Frame")
	f.BackgroundTransparency = 1
	f.Size = UDim2.new(1, 0, 0, h)
	f.LayoutOrder = order
	f.Parent = parent
	return f
end

local function heading(parent: Instance, order: number, text: string)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, 18)
	l.LayoutOrder = order
	l.Text = text
	l.TextColor3 = Color3.fromRGB(255, 140, 120)
	l.TextSize = 12
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

function DevMapPanel.new(cb: Callbacks): DevMapPanel
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.AnchorPoint = Vector2.new(1, 0)
	frame.Position = UDim2.new(1, -12, 0, 12)
	frame.Size = UDim2.fromOffset(280, 0)
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
	list.Padding = UDim.new(0, 5)
	list.Parent = frame

	-- Header with collapse toggle
	local header = row(frame, 1, 22)
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
	blist.Padding = UDim.new(0, 5)
	blist.Parent = body

	-- Map
	heading(body, 1, "MAP")
	local r1 = row(body, 2, 24)
	caption(r1, "Seed", UDim.new(0, 0), UDim.new(0, 40))
	local seedBox = box(r1, "SeedBox", "12345", UDim.new(0, 40), UDim.new(0.5, -44))
	caption(r1, "Count", UDim.new(0.5, 4), UDim.new(0, 40))
	local countBox = box(r1, "TerritoriesBox", "260", UDim.new(0.5, 44), UDim.new(0.5, -44))
	local r2 = row(body, 3, 26)
	local regen = button(r2, "RegenerateButton", "Regenerate", UDim.new(0, 0), UDim.new(0.5, -3), true)
	local random = button(r2, "RandomSeedButton", "Random seed", UDim.new(0.5, 3), UDim.new(0.5, -3))
	local mapStatus = statusLabel(body, 4, "Status")

	-- Fog of war
	heading(body, 10, "FOG OF WAR")
	local r3 = row(body, 11, 26)
	local reveal = button(r3, "RevealAllButton", "Reveal all: OFF", UDim.new(0, 0), UDim.new(0.5, -3))
	local clear = button(r3, "ClearVisionButton", "Remove all vision", UDim.new(0.5, 3), UDim.new(0.5, -3))
	local r4 = row(body, 12, 26)
	caption(r4, "Range", UDim.new(0, 0), UDim.new(0, 40))
	local rangeBox = box(r4, "RangeBox", "2", UDim.new(0, 40), UDim.new(0, 36))
	local addVision = button(r4, "AddVisionButton", "Add vision at selected", UDim.new(0, 82), UDim.new(1, -82), true)

	-- Ownership
	heading(body, 20, "OWNERSHIP (placeholder civs 1-8)")
	local r5 = row(body, 21, 26)
	caption(r5, "Owner", UDim.new(0, 0), UDim.new(0, 40))
	local ownerBox = box(r5, "OwnerBox", "1", UDim.new(0, 40), UDim.new(0, 36))
	local setOwner = button(r5, "SetOwnerButton", "Set owner", UDim.new(0, 82), UDim.new(0.5, -44), true)
	local clearOwner = button(r5, "ClearOwnerButton", "Unowned", UDim.new(0.5, 42), UDim.new(0.5, -42))

	-- Debug
	heading(body, 30, "DEBUG")
	local r6 = row(body, 31, 26)
	local overlay = button(r6, "OverlayButton", "Overlay (ids + links): OFF", UDim.new(0, 0), UDim.new(1, 0))
	local actionStatus = statusLabel(body, 40, "ActionStatus")

	gui.Parent = playerGui

	local self = setmetatable({
		gui = gui,
		body = body,
		seedBox = seedBox,
		countBox = countBox,
		rangeBox = rangeBox,
		ownerBox = ownerBox,
		mapStatus = mapStatus,
		actionStatus = actionStatus,
		revealButton = reveal,
		overlayButton = overlay,
		collapseButton = collapse,
	}, DevMapPanel)

	local function say(text: string)
		actionStatus.Text = text
	end

	local function submit()
		local seed = tonumber(seedBox.Text)
		local count = tonumber(countBox.Text)
		if not seed or not count then
			say("Enter a numeric seed and territory count.")
			return
		end
		mapStatus.Text = string.format("Regenerating seed %d with %d territories…", seed, count)
		cb.regenerate(math.floor(seed), math.floor(count))
	end
	regen.Activated:Connect(submit)
	random.Activated:Connect(function()
		seedBox.Text = tostring(math.random(1, 2 ^ 30))
		submit()
	end)

	collapse.Activated:Connect(function()
		body.Visible = not body.Visible
		collapse.Text = if body.Visible then "–" else "+"
	end)

	local revealOn = false
	reveal.Activated:Connect(function()
		revealOn = not revealOn
		local res = cb.command({ cmd = "RevealAll", value = revealOn })
		reveal.Text = "Reveal all: " .. (if revealOn then "ON" else "OFF")
		say(string.format("Reveal all %s (%d territories changed)", if revealOn then "on" else "off", res.changed or 0))
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
	setOwner.Activated:Connect(function()
		local id = cb.selectedId()
		local owner = tonumber(ownerBox.Text)
		if not id or not owner then
			say("Select a territory and enter an owner number.")
			return
		end
		local res = cb.command({ cmd = "SetOwner", territoryId = id, ownerId = math.floor(owner) })
		say(if res.ok then string.format("Territory %d owner -> %d", id, owner) else "Owner unchanged")
	end)
	clearOwner.Activated:Connect(function()
		local id = cb.selectedId()
		if not id then
			say("Select a territory first.")
			return
		end
		local res = cb.command({ cmd = "SetOwner", territoryId = id, ownerId = nil })
		say(if res.ok then string.format("Territory %d is now unowned", id) else "Owner unchanged")
	end)
	overlay.Activated:Connect(function()
		local on = cb.toggleOverlay()
		overlay.Text = "Overlay (ids + links): " .. (if on then "ON" else "OFF")
	end)

	return self
end

function DevMapPanel.setOverlayLabel(self: DevMapPanel, on: boolean)
	self.overlayButton.Text = "Overlay (ids + links): " .. (if on then "ON" else "OFF")
end

function DevMapPanel.update(self: DevMapPanel, devInfo: any, renderStats: any, renderOk: boolean, counts: { [string]: number }?)
	if devInfo then
		self.seedBox.Text = tostring(devInfo.seed)
		self.countBox.Text = tostring(devInfo.territoryCount)
	end
	local lines = {}
	if devInfo then
		table.insert(lines, string.format("World %d x %d studs, %d territories", devInfo.width, devInfo.height, devInfo.territoryCount))
		table.insert(lines, string.format("Generate %.0f ms · Validate %.0f ms", devInfo.generationMs, devInfo.validationMs))
		table.insert(
			lines,
			string.format(
				"Validation: %s (%d err, %d warn) · %s",
				if devInfo.validationOk then "PASS" else "FAIL",
				devInfo.errorCount,
				devInfo.warningCount,
				devInfo.fingerprint
			)
		)
	end
	if renderStats then
		table.insert(
			lines,
			string.format("Render %.0f ms via %s · %d instances", renderStats.renderMs, renderStats.backend, renderStats.instanceCount)
		)
	end
	table.insert(lines, "Render check: " .. (if renderOk then "PASS" else "FAIL"))
	if counts then
		table.insert(lines, string.format("Fog: %d visible · %d explored · %d unexplored", counts.Visible, counts.Explored, counts.Unexplored))
	end
	self.mapStatus.Text = table.concat(lines, "\n")
	self.mapStatus.TextColor3 = if (devInfo == nil or devInfo.validationOk) and renderOk
		then Color3.fromRGB(170, 220, 160)
		else Color3.fromRGB(255, 140, 120)
end

return DevMapPanel
