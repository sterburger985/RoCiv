--!strict
-- DevMapPanel (client) — DEVELOPMENT ONLY
-- Studio-only panel to regenerate the map with a chosen seed / territory
-- count. ClientMain only creates it when RunService:IsStudio() is true and
-- the server exposed the DevRegenerate remote (which it only does in Studio).

local Players = game:GetService("Players")

local GUI_NAME = "DevMapPanel"

local DevMapPanel = {}
DevMapPanel.__index = DevMapPanel

export type DevMapPanel = typeof(setmetatable(
	{} :: {
		gui: ScreenGui,
		seedBox: TextBox,
		countBox: TextBox,
		status: TextLabel,
		regenButton: TextButton,
		randomButton: TextButton,
	},
	DevMapPanel
))

local BG = Color3.fromRGB(40, 16, 16)
local TEXT = Color3.fromRGB(240, 230, 220)
local MUTED = Color3.fromRGB(190, 160, 150)

local function textBox(parent: Instance, name: string, placeholder: string, y: number): TextBox
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Position = UDim2.fromOffset(12, y)
	lbl.Size = UDim2.fromOffset(80, 26)
	lbl.Text = name
	lbl.TextColor3 = MUTED
	lbl.TextSize = 14
	lbl.Font = Enum.Font.Gotham
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Parent = parent

	local box = Instance.new("TextBox")
	box.Name = name .. "Box"
	box.Position = UDim2.fromOffset(92, y)
	box.Size = UDim2.new(1, -104, 0, 26)
	box.BackgroundColor3 = Color3.fromRGB(20, 8, 8)
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.PlaceholderText = placeholder
	box.Text = ""
	box.TextColor3 = TEXT
	box.TextSize = 14
	box.Font = Enum.Font.Code
	box.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 4)
	c.Parent = box
	return box
end

local function button(parent: Instance, name: string, text: string, pos: UDim2, size: UDim2, color: Color3): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Position = pos
	b.Size = size
	b.BackgroundColor3 = color
	b.BorderSizePixel = 0
	b.Text = text
	b.TextColor3 = TEXT
	b.TextSize = 14
	b.Font = Enum.Font.GothamBold
	b.AutoButtonColor = true
	b.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 4)
	c.Parent = b
	return b
end

function DevMapPanel.new(onRegenerate: (seed: number, count: number) -> ()): DevMapPanel
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
	frame.Position = UDim2.new(1, -16, 0, 16)
	frame.Size = UDim2.fromOffset(300, 252)
	frame.BackgroundColor3 = BG
	frame.BackgroundTransparency = 0.1
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(200, 70, 60)
	stroke.Parent = frame

	local header = Instance.new("TextLabel")
	header.BackgroundTransparency = 1
	header.Position = UDim2.fromOffset(12, 8)
	header.Size = UDim2.new(1, -24, 0, 22)
	header.Text = "DEV ONLY · Map Tools (Studio)"
	header.TextColor3 = Color3.fromRGB(255, 140, 120)
	header.TextSize = 15
	header.Font = Enum.Font.GothamBold
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Parent = frame

	local seedBox = textBox(frame, "Seed", "e.g. 12345", 38)
	local countBox = textBox(frame, "Territories", "e.g. 150", 70)

	local regen = button(
		frame,
		"RegenerateButton",
		"Regenerate",
		UDim2.fromOffset(12, 104),
		UDim2.new(0.5, -16, 0, 30),
		Color3.fromRGB(170, 60, 50)
	)
	local random = button(
		frame,
		"RandomSeedButton",
		"Random seed",
		UDim2.new(0.5, 4, 0, 104),
		UDim2.new(0.5, -16, 0, 30),
		Color3.fromRGB(90, 50, 46)
	)

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.BackgroundTransparency = 1
	status.Position = UDim2.fromOffset(12, 142)
	status.Size = UDim2.new(1, -24, 1, -150)
	status.Text = "Waiting for map…"
	status.TextColor3 = MUTED
	status.TextSize = 12
	status.Font = Enum.Font.Code
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.TextYAlignment = Enum.TextYAlignment.Top
	status.TextWrapped = true
	status.Parent = frame

	gui.Parent = playerGui

	local self = setmetatable({
		gui = gui,
		seedBox = seedBox,
		countBox = countBox,
		status = status,
		regenButton = regen,
		randomButton = random,
	}, DevMapPanel)

	local function submit()
		local seed = tonumber(seedBox.Text)
		local count = tonumber(countBox.Text)
		if not seed or not count then
			status.Text = "Enter a numeric seed and territory count."
			return
		end
		status.Text = string.format("Regenerating seed %d with %d territories…", seed, count)
		onRegenerate(seed, count)
	end
	regen.Activated:Connect(submit)
	random.Activated:Connect(function()
		seedBox.Text = tostring(math.random(1, 2 ^ 30))
		submit()
	end)

	return self
end

function DevMapPanel.update(self: DevMapPanel, devInfo: any, renderStats: any, renderOk: boolean)
	if devInfo then
		self.seedBox.Text = tostring(devInfo.seed)
		self.countBox.Text = tostring(devInfo.territoryCount)
	end
	local lines = {}
	if devInfo then
		table.insert(lines, string.format("Generate: %.0f ms   Validate: %.0f ms", devInfo.generationMs, devInfo.validationMs))
		table.insert(
			lines,
			string.format(
				"Validation: %s (%d err, %d warn)",
				if devInfo.validationOk then "PASS" else "FAIL",
				devInfo.errorCount,
				devInfo.warningCount
			)
		)
		table.insert(lines, "Fingerprint: " .. devInfo.fingerprint)
	end
	if renderStats then
		table.insert(lines, string.format("Render: %.0f ms via %s", renderStats.renderMs, renderStats.backend))
		table.insert(lines, string.format("Map instances: %d", renderStats.instanceCount))
	end
	table.insert(lines, "Render check: " .. (if renderOk then "PASS" else "FAIL"))
	self.status.Text = table.concat(lines, "\n")
	self.status.TextColor3 = if (devInfo == nil or devInfo.validationOk) and renderOk
		then Color3.fromRGB(170, 220, 160)
		else Color3.fromRGB(255, 140, 120)
end

return DevMapPanel
