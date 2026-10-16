--!strict
-- ClientMain (LocalScript, StarterPlayerScripts.RoCiv)
-- Wires the client systems together:
--   server payload -> ClientMapState -> MapRenderer (+ fog styling)
--   TerritoryDelta  -> ClientMapState -> MapRenderer.refresh / panel refresh
--   civilizations   -> TerritoryStyle (owner names/colours) -> restyle
--   input           -> CameraController / SelectionController -> info panel
--   movement graph  -> MovementClient (region overlay, route/range previews)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

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
local TerritoryStyle = require(here:WaitForChild("TerritoryStyle"))
local DevMapPanel = require(here:WaitForChild("DevMapPanel"))
local DebugOverlay = require(here:WaitForChild("DebugOverlay"))
local MovementClient = require(here:WaitForChild("MovementClient"))

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
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = MapConfig.LIGHTING_SHADOW_SOFTNESS
	Lighting.Ambient = MapConfig.LIGHTING_AMBIENT
	Lighting.OutdoorAmbient = MapConfig.LIGHTING_OUTDOOR_AMBIENT
	Lighting.EnvironmentDiffuseScale = MapConfig.LIGHTING_ENV_DIFFUSE
	Lighting.GeographicLatitude = MapConfig.LIGHTING_LATITUDE
	local cc = Lighting:FindFirstChild("RoCivMapColor")
	if not cc then
		cc = Instance.new("ColorCorrectionEffect")
		cc.Name = "RoCivMapColor"
		cc.Parent = Lighting
	end
	(cc :: ColorCorrectionEffect).Saturation = MapConfig.LIGHTING_SATURATION;
	(cc :: ColorCorrectionEffect).Contrast = MapConfig.LIGHTING_CONTRAST;
	(cc :: ColorCorrectionEffect).TintColor = MapConfig.LIGHTING_TINT
end
applyMapLighting()

-- Small chat window pinned to the top-right corner so the map stays clear.
local function applyChatLayout()
	local window = TextChatService:FindFirstChildOfClass("ChatWindowConfiguration")
	if window then
		window.HorizontalAlignment = Enum.HorizontalAlignment.Right
		window.VerticalAlignment = Enum.VerticalAlignment.Top
		window.WidthScale = MapConfig.CHAT_WIDTH_SCALE
		window.HeightScale = MapConfig.CHAT_HEIGHT_SCALE
		window.TextSize = MapConfig.CHAT_TEXT_SIZE
		window.BackgroundTransparency = 0.35
	end
	local bar = TextChatService:FindFirstChildOfClass("ChatInputBarConfiguration")
	if bar then
		bar.TextSize = MapConfig.CHAT_TEXT_SIZE
	end
end
pcall(applyChatLayout)

local state = ClientMapState.new()
local renderer = MapRenderer.new()
local camera = CameraController.new()
local selection = SelectionController.new(renderer)
local overlay = DebugOverlay.new()
local movement = MovementClient.new(renderer, state, remotes)
local panel = TerritoryInfoPanel.new(function()
	selection:clear()
end)
selection:onChanged(function(record)
	panel:show(record, state.yourCivilizationId)
end)
-- While the route tool is on, left clicks plan routes instead of selecting.
selection.clickInterceptor = function(screenPos)
	return movement:handleClick(SelectionController.planePoint(screenPos))
end

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
		regenerate = function(seed, matchSize)
			devRemote:FireServer(seed, matchSize)
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
		movement = {
			setOverlay = function(on)
				movement:setOverlay(on)
			end,
			setRouteTool = function(on)
				movement:setRouteTool(on)
			end,
			setDomain = function(domain)
				movement:setDomain(domain)
			end,
			setRange = function(on, budget)
				movement:setRange(on, budget)
			end,
			buildRoad = function()
				return movement:buildRoadAlongRoute(function(cmd)
					local ok, res = pcall(function()
						return devCommand:InvokeServer(cmd)
					end)
					return if ok then res else nil
				end)
			end,
		},
	})
	movement:onStatus(function(text)
		devPanel:setMovementStatus(text)
	end)
end

local function revalidate(label: string)
	local ok, problems = renderer:validate(state)
	lastRenderOk = ok
	for _, p in problems do
		warn("[ClientMain] Render problem " .. label .. ": " .. p)
	end
end

-- Visibility / ownership deltas: restyle only what changed, in one frame.
state:onChanged(function(ids)
	renderer:refresh(state, ids)
	selection:refresh(ids)
	movement:onVisibilityChanged()
	revalidate("after update")
	updateDevPanel()
	if devPanel then
		devPanel:refreshCivStatus()
	end
	player:SetAttribute("MapStateSeq", state.seq)
end)

-- Terrain painting finished for some territories: outlines follow it.
renderer:onSurfaceChanged(function(ids)
	selection:surfaceChanged(ids)
end)

-- Civilization list changes (names/colours/controllers): restyle everything.
state:onCivilizationsChanged(function()
	TerritoryStyle.setCivilizations(state.civilizations)
	if renderer.state then
		renderer:refreshAll(state)
		selection:refresh(nil)
		revalidate("after civilization update")
	end
	if devPanel then
		devPanel:setCivilizations(state.civilizations)
	end
	player:SetAttribute("YourCivilizationId", state.yourCivilizationId or 0)
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
			TerritoryStyle.setCivilizations(state.civilizations)
			local stats = renderer:render(state)
			local query = MapQuery.new(state.list, state.width, state.height)
			selection:setMap(state, query)
			camera:setBounds(state.width, state.height)
			overlay:build(state, renderer)
			movement:load()
			revalidate("after load")
			lastDevInfo = payload.devInfo
			local c = state:counts()
			print(
				string.format(
					"[ClientMain] Rendered map v%d: %d territories (%dx%d), %d movement regions, via %s in %.1f ms, %d instances. Fog: %d visible / %d explored / %d unexplored. Render check: %s",
					payload.version,
					stats.territoryCount,
					state.width,
					state.height,
					#movement.list,
					stats.backend,
					stats.renderMs,
					stats.instanceCount,
					c.Visible,
					c.Explored,
					c.Unexplored,
					if lastRenderOk then "PASS" else "FAIL"
				)
			)
			player:SetAttribute("MapVersionLoaded", state.version)
			player:SetAttribute("MapStateSeq", state.seq)
			player:SetAttribute("YourCivilizationId", state.yourCivilizationId or 0)
			if devPanel then
				devPanel:setCivilizations(state.civilizations)
			end
			updateDevPanel()
		end
	until not pendingReload
	loading = false
end

(remotes:WaitForChild("TerritoryDelta") :: RemoteEvent).OnClientEvent:Connect(function(delta)
	state:applyDelta(delta)
end);

(remotes:WaitForChild("CivilizationsUpdated") :: RemoteEvent).OnClientEvent:Connect(function(list, yourId)
	state:setCivilizations(list, yourId)
end);

(remotes:WaitForChild("MapUpdated") :: RemoteEvent).OnClientEvent:Connect(function()
	loadMap()
end)

loadMap()
