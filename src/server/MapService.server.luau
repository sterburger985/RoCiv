--!strict
-- MapService (Script, ServerScriptService.RoCiv)
-- Server-authoritative owner of the strategic map.
--   * Generates + validates the map at startup.
--   * Holds the authoritative MapData (clients only ever get a copy).
--   * Serves the map to clients through Remotes.GetMap.
--   * Studio-only: accepts DevRegenerate requests from the dev panel.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("RoCiv"):WaitForChild("Shared")
local MapConfig = require(Shared:WaitForChild("MapConfig"))
local MapGenerator = require(script.Parent:WaitForChild("Map"):WaitForChild("MapGenerator"))
local MapValidator = require(script.Parent:WaitForChild("Map"):WaitForChild("MapValidator"))

-- Strategy view has no avatar.
Players.CharacterAutoLoads = false

local DEV_TOOLS = MapConfig.DEV_TOOLS_ENABLED and RunService:IsStudio()

-- Remotes (created fresh each server start so there are never duplicates).
local rocivFolder = ReplicatedStorage:WaitForChild("RoCiv")
local existing = rocivFolder:FindFirstChild("Remotes")
if existing then
	existing:Destroy()
end
local remotes = Instance.new("Folder")
remotes.Name = "Remotes"

local getMap = Instance.new("RemoteFunction")
getMap.Name = "GetMap"
getMap.Parent = remotes

local mapUpdated = Instance.new("RemoteEvent")
mapUpdated.Name = "MapUpdated"
mapUpdated.Parent = remotes

local devRegenerate: RemoteEvent? = nil
if DEV_TOOLS then
	local r = Instance.new("RemoteEvent")
	r.Name = "DevRegenerate"
	r.Parent = remotes
	devRegenerate = r
end
remotes.Parent = rocivFolder

-- State ----------------------------------------------------------------------

local currentMap: MapGenerator.MapData? = nil
local currentPayload: { [string]: any }? = nil
local mapVersion = 0
local generating = false
local lastDevInfo: { [string]: any }? = nil

local function buildMap(seed: number, count: number)
	generating = true
	local t0 = os.clock()
	local map = MapGenerator.generate({ seed = seed, territoryCount = count })
	local genMs = (os.clock() - t0) * 1000
	local report = MapValidator.validate(map)
	local text = MapValidator.format(report)
	local fp = MapGenerator.fingerprint(map)

	print(
		string.format(
			"[MapService] Generated map seed=%d territories=%d in %.1f ms (voronoi %.1f ms) fingerprint=%s",
			map.seed,
			map.territoryCount,
			genMs,
			map.stats.voronoiMs,
			fp
		)
	)
	if report.ok then
		print(text)
	else
		-- Serious problems are surfaced loudly, never ignored.
		warn(text)
	end

	currentMap = map
	mapVersion += 1
	currentPayload = MapGenerator.toClientPayload(map, DEV_TOOLS)
	currentPayload.version = mapVersion
	lastDevInfo = if DEV_TOOLS
		then {
			seed = map.seed,
			territoryCount = map.territoryCount,
			generationMs = genMs,
			validationMs = report.durationMs,
			validationOk = report.ok,
			errorCount = #report.errors,
			warningCount = #report.warnings,
			fingerprint = fp,
			reportText = text,
		}
		else nil
	if currentPayload then
		currentPayload.devInfo = lastDevInfo
	end
	generating = false
	mapUpdated:FireAllClients(mapVersion)
end

getMap.OnServerInvoke = function(_player: Player)
	while generating or not currentPayload do
		task.wait(0.1)
	end
	return currentPayload
end

if devRegenerate then
	devRegenerate.OnServerEvent:Connect(function(player: Player, seed: any, count: any)
		-- Defence in depth: never honour this outside Studio.
		if not RunService:IsStudio() or generating then
			return
		end
		if type(seed) ~= "number" or type(count) ~= "number" then
			return
		end
		if seed ~= seed or count ~= count then
			return
		end
		seed = math.clamp(math.floor(seed), -2 ^ 31, 2 ^ 31 - 1)
		count = math.clamp(math.floor(count), MapConfig.MIN_TERRITORY_COUNT, MapConfig.MAX_TERRITORY_COUNT)
		print(string.format("[MapService] Dev regenerate requested by %s: seed=%d count=%d", player.Name, seed, count))
		buildMap(seed, count)
	end)
end

-- Note: later phases (TerritorySystem etc.) should move `currentMap` into a
-- server ModuleScript so other systems can read it directly.
local _ = currentMap

buildMap(MapConfig.DEFAULT_SEED, MapConfig.DEFAULT_TERRITORY_COUNT)
