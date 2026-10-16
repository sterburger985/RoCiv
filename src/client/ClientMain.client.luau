--!strict
-- ClientMain (LocalScript, StarterPlayerScripts.RoCiv)
-- Wires the client map systems together: fetch map -> render -> selection.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("RoCiv"):WaitForChild("Shared")
local MapQuery = require(Shared:WaitForChild("MapQuery"))
local remotes = ReplicatedStorage.RoCiv:WaitForChild("Remotes")

local here = script.Parent
local MapRenderer = require(here:WaitForChild("MapRenderer"))
local CameraController = require(here:WaitForChild("CameraController"))
local SelectionController = require(here:WaitForChild("SelectionController"))
local TerritoryInfoPanel = require(here:WaitForChild("TerritoryInfoPanel"))
local DevMapPanel = require(here:WaitForChild("DevMapPanel"))

local MapConfig = require(Shared:WaitForChild("MapConfig"))

local player = Players.LocalPlayer

-- Local presentation tweaks so the map reads clearly from strategy height.
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
end
applyMapLighting()

local renderer = MapRenderer.new()
local camera = CameraController.new()
local selection = SelectionController.new(renderer)
local panel = TerritoryInfoPanel.new(function()
	selection:clear()
end)
selection:onChanged(function(record)
	panel:show(record)
end)

local devPanel = nil
local devRemote = remotes:FindFirstChild("DevRegenerate") :: RemoteEvent?
if RunService:IsStudio() and devRemote then
	devPanel = DevMapPanel.new(function(seed, count)
		devRemote:FireServer(seed, count)
	end)
end

local loading = false
local pendingReload = false
local loadedVersion = 0

local function loadMap()
	if loading then
		pendingReload = true
		return
	end
	loading = true
	repeat
		pendingReload = false
		local payload = (remotes:WaitForChild("GetMap") :: RemoteFunction):InvokeServer()
		if payload and payload.version ~= loadedVersion then
			selection:clear()
			local stats = renderer:render(payload)
			local query = MapQuery.new(payload.territories, payload.width, payload.height)
			selection:setMap(payload, query)
			camera:setBounds(payload.width, payload.height)
			local ok, problems = renderer:validate(payload)
			loadedVersion = payload.version
			print(
				string.format(
					"[ClientMain] Rendered map v%d: %d territories via %s in %.1f ms, %d instances. Render check: %s",
					payload.version,
					stats.territoryCount,
					stats.backend,
					stats.renderMs,
					stats.instanceCount,
					if ok then "PASS" else "FAIL"
				)
			)
			for _, p in problems do
				warn("[ClientMain] Render problem: " .. p)
			end
			player:SetAttribute("MapVersionLoaded", loadedVersion)
			if devPanel then
				devPanel:update(payload.devInfo, stats, ok)
			end
		end
	until not pendingReload
	loading = false
end

(remotes:WaitForChild("MapUpdated") :: RemoteEvent).OnClientEvent:Connect(function()
	loadMap()
end)

loadMap()
