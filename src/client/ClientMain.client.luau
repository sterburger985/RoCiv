--!strict
-- ClientMain (LocalScript, StarterPlayerScripts.RoCiv)
-- Wires the client map systems together:
--   server payload -> ClientMapState -> MapRenderer (+ fog styling)
--   TerritoryDelta  -> ClientMapState -> MapRenderer.refresh / panel refresh
--   input           -> CameraController / SelectionController -> info panel

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("RoCiv"):WaitForChild("Shared")
local MapQuery = require(Shared:WaitForChild("MapQuery"))
local MapConfig = require(Shared:WaitForChild("MapConfig"))
local remotes = ReplicatedStorage.RoCiv:WaitForChild("Remotes")

local here = script.Parent
local ClientMapState = require(here:WaitForChild("ClientMapState"))
local MapRenderer = require(here:WaitForChild("MapRenderer"))
local CameraController = require(here:WaitForChild("CameraController"))
local SelectionController = require(here:WaitForChild("SelectionController"))
local TerritoryInfoPanel = require(here:WaitForChild("TerritoryInfoPanel"))
local DevMapPanel = require(here:WaitForChild("DevMapPanel"))
local DebugOverlay = require(here:WaitForChild("DebugOverlay"))

local player = Players.LocalPlayer

-- Local presentation settings so the map reads clearly from strategy height.
local function applyMapLighting()
	local Lighting = game:GetService("Lighting")
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if atmosphere then
		atmosphere.Density = MapConfig.MAP_ATMOSPHERE_DENSITY
	end
	if MapConfig.DISABLE_POST_EFFECTS then
		for _, effect in Lighting:GetChildren() do
			if effect:IsA("DepthOfFieldEffect") or effect:IsA("BloomEffect") or effect:IsA("SunRaysEffect") then
				effect.Enabled = false
			end
		end
	end
	Lighting.ClockTime = MapConfig.LIGHTING_CLOCK_TIME
	Lighting.Brightness = MapConfig.LIGHTING_BRIGHTNESS
	Lighting.ExposureCompensation = MapConfig.LIGHTING_EXPOSURE
	Lighting.EnvironmentSpecularScale = MapConfig.LIGHTING_ENV_SPECULAR
	local cc = Lighting:FindFirstChild("RoCivMapColor")
	if not cc then
		cc = Instance.new("ColorCorrectionEffect")
		cc.Name = "RoCivMapColor"
		cc.Parent = Lighting
	end
	(cc :: ColorCorrectionEffect).Saturation = MapConfig.LIGHTING_SATURATION
end
applyMapLighting()

local state = ClientMapState.new()
local renderer = MapRenderer.new()
local camera = CameraController.new()
local selection = SelectionController.new(renderer)
local overlay = DebugOverlay.new()
local panel = TerritoryInfoPanel.new(function()
	selection:clear()
end)
selection:onChanged(function(record)
	panel:show(record)
end)

local devPanel = nil
local devRemote = remotes:FindFirstChild("DevRegenerate") :: RemoteEvent?
local devCommand = remotes:FindFirstChild("DevCommand") :: RemoteFunction?
local lastDevInfo = nil
local lastRenderOk = false

local function updateDevPanel()
	if devPanel then
		devPanel:update(lastDevInfo, renderer.lastStats, lastRenderOk, state:counts())
	end
end

if RunService:IsStudio() and devRemote and devCommand then
	devPanel = DevMapPanel.new({
		regenerate = function(seed, count)
			devRemote:FireServer(seed, count)
		end,
		command = function(cmd)
			local ok, res = pcall(function()
				return devCommand:InvokeServer(cmd)
			end)
			return if ok and type(res) == "table" then res else { ok = false }
		end,
		selectedId = function()
			return selection.selectedId
		end,
		toggleOverlay = function()
			return overlay:toggle(state, renderer)
		end,
	})
end

-- Visibility / ownership deltas: restyle only what changed, in one frame.
state:onChanged(function(ids)
	renderer:refresh(state, ids)
	selection:refresh(ids)
	-- Re-check that every visual still matches the data after the change.
	local ok, problems = renderer:validate(state)
	lastRenderOk = ok
	for _, p in problems do
		warn("[ClientMain] Render problem after update: " .. p)
	end
	updateDevPanel()
	player:SetAttribute("MapStateSeq", state.seq)
end)

local loading = false
local pendingReload = false

local function loadMap()
	if loading then
		pendingReload = true
		return
	end
	loading = true
	repeat
		pendingReload = false
		local payload = (remotes:WaitForChild("GetMap") :: RemoteFunction):InvokeServer()
		if payload and payload.version ~= state.version then
			selection:clear()
			overlay:clear()
			state:load(payload)
			local stats = renderer:render(state)
			local query = MapQuery.new(state.list, state.width, state.height)
			selection:setMap(state, query)
			camera:setBounds(state.width, state.height)
			overlay:build(state, renderer)
			local ok, problems = renderer:validate(state)
			lastRenderOk = ok
			lastDevInfo = payload.devInfo
			local c = state:counts()
			print(
				string.format(
					"[ClientMain] Rendered map v%d: %d territories (%dx%d) via %s in %.1f ms, %d instances. Fog: %d visible / %d explored / %d unexplored. Render check: %s",
					payload.version,
					stats.territoryCount,
					state.width,
					state.height,
					stats.backend,
					stats.renderMs,
					stats.instanceCount,
					c.Visible,
					c.Explored,
					c.Unexplored,
					if ok then "PASS" else "FAIL"
				)
			)
			for _, p in problems do
				warn("[ClientMain] Render problem: " .. p)
			end
			player:SetAttribute("MapVersionLoaded", state.version)
			player:SetAttribute("MapStateSeq", state.seq)
			updateDevPanel()
		end
	until not pendingReload
	loading = false
end

(remotes:WaitForChild("TerritoryDelta") :: RemoteEvent).OnClientEvent:Connect(function(delta)
	state:applyDelta(delta)
end);

(remotes:WaitForChild("MapUpdated") :: RemoteEvent).OnClientEvent:Connect(function()
	loadMap()
end)

loadMap()
