--!strict
-- MapService (Script, ServerScriptService.RoCiv)
-- Network layer for the strategic map.
--   * Generates + validates the map and hands it to TerritorySystem.
--   * Builds a per-player view filtered by VisibilitySystem: geometry for
--     every territory, but terrain/owner data only for what that player has
--     discovered. Clients never receive data they have not seen.
--   * Sends small per-player deltas when visibility or ownership changes.
--   * Studio-only dev remotes: regenerate, vision tools, ownership tools.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("RoCiv"):WaitForChild("Shared")
local MapConfig = require(Shared:WaitForChild("MapConfig"))
local MapGenerator = require(script.Parent:WaitForChild("Map"):WaitForChild("MapGenerator"))
local MapValidator = require(script.Parent:WaitForChild("Map"):WaitForChild("MapValidator"))
local TerritorySystem = require(script.Parent:WaitForChild("Systems"):WaitForChild("TerritorySystem"))
local VisibilitySystem = require(script.Parent:WaitForChild("Systems"):WaitForChild("VisibilitySystem"))

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

local territoryDelta = Instance.new("RemoteEvent")
territoryDelta.Name = "TerritoryDelta"
territoryDelta.Parent = remotes

local devRegenerate: RemoteEvent? = nil
local devCommand: RemoteFunction? = nil
if DEV_TOOLS then
	local r = Instance.new("RemoteEvent")
	r.Name = "DevRegenerate"
	r.Parent = remotes
	devRegenerate = r
	local c = Instance.new("RemoteFunction")
	c.Name = "DevCommand"
	c.Parent = remotes
	devCommand = c
end
remotes.Parent = rocivFolder

-- Per-player view -------------------------------------------------------------

local function territoryView(player: Player, id: number): { [string]: any }
	local t = TerritorySystem.get(id)
	assert(t, "unknown territory")
	local state = VisibilitySystem.getState(player, id)
	local view: { [string]: any } = { id = id, state = state }
	if state ~= "Unexplored" then
		-- Static terrain facts are known once explored.
		view.terrainType = t.terrainType
		view.elevation = t.elevation
		view.fertility = t.fertility
		view.resources = t.resources
		-- Owner: live when visible, last-seen when only explored.
		view.ownerId = if state == "Visible" then t.ownerId else VisibilitySystem.knownOwner(player, id)
	end
	return view
end

local function sendDelta(player: Player, ids: { number })
	if #ids == 0 or not player.Parent then
		return
	end
	local updates = table.create(#ids)
	for _, id in ids do
		table.insert(updates, territoryView(player, id))
	end
	territoryDelta:FireClient(player, {
		version = TerritorySystem.getVersion(),
		seq = VisibilitySystem.getSeq(player),
		updates = updates,
	})
end

local function buildPayload(player: Player): { [string]: any }
	local map = TerritorySystem.getMap()
	assert(map, "no map")
	local list = table.create(#map.territoryIds)
	for _, id in map.territoryIds do
		local t = map.territories[id]
		local view = territoryView(player, id)
		-- Geometry is sent for every territory so fog can be drawn exactly on
		-- territory boundaries. Shapes reveal no terrain or ownership.
		view.polygon = t.polygon
		view.centroid = t.centroid
		view.neighbors = t.neighbors
		table.insert(list, view)
	end
	return {
		version = TerritorySystem.getVersion(),
		seq = VisibilitySystem.getSeq(player),
		territoryCount = map.territoryCount,
		width = map.width,
		height = map.height,
		territories = list,
		fogEnabled = MapConfig.FOG_OF_WAR_ENABLED,
	}
end

-- Map lifecycle --------------------------------------------------------------

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
			"[MapService] Generated map seed=%d territories=%d size=%dx%d in %.1f ms (voronoi %.1f ms) fingerprint=%s",
			map.seed,
			map.territoryCount,
			map.width,
			map.height,
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

	TerritorySystem.setMap(map)
	VisibilitySystem.resetAll()
	lastDevInfo = if DEV_TOOLS
		then {
			seed = map.seed,
			territoryCount = map.territoryCount,
			width = map.width,
			height = map.height,
			generationMs = genMs,
			validationMs = report.durationMs,
			validationOk = report.ok,
			errorCount = #report.errors,
			warningCount = #report.warnings,
			fingerprint = fp,
		}
		else nil
	generating = false
	mapUpdated:FireAllClients(TerritorySystem.getVersion())
end

getMap.OnServerInvoke = function(player: Player)
	while generating or not TerritorySystem.getMap() do
		task.wait(0.1)
	end
	VisibilitySystem.addPlayer(player)
	local payload = buildPayload(player)
	payload.devInfo = lastDevInfo
	if DEV_TOOLS then
		payload.seed = (TerritorySystem.getMap() :: any).seed
	end
	return payload
end

local function onPlayerAdded(player: Player)
	VisibilitySystem.addPlayer(player)
	if TerritorySystem.getMap() and #VisibilitySystem.listSources(player) == 0 then
		VisibilitySystem.giveStartVision(player)
	end
end
Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in Players:GetPlayers() do
	onPlayerAdded(p)
end
Players.PlayerRemoving:Connect(function(player)
	VisibilitySystem.removePlayer(player)
end)

-- Ownership changes reach only the players who can currently see them.
TerritorySystem.onOwnerChanged(function(territoryId, _old, newOwner)
	for _, player in VisibilitySystem.noteOwnerChange(territoryId, newOwner) do
		sendDelta(player, { territoryId })
	end
end)

-- Development remotes (Studio only) ------------------------------------------

local function isInt(v: any): boolean
	return type(v) == "number" and v == v and v % 1 == 0 and math.abs(v) < 2 ^ 31
end

if devRegenerate then
	devRegenerate.OnServerEvent:Connect(function(player: Player, seed: any, count: any)
		-- Defence in depth: never honour this outside Studio.
		if not RunService:IsStudio() or generating then
			return
		end
		if not isInt(seed) or type(count) ~= "number" or count ~= count then
			return
		end
		count = math.clamp(math.floor(count), MapConfig.MIN_TERRITORY_COUNT, MapConfig.MAX_TERRITORY_COUNT)
		print(string.format("[MapService] Dev regenerate requested by %s: seed=%d count=%d", player.Name, seed, count))
		buildMap(seed, count)
	end)
end

if devCommand then
	devCommand.OnServerInvoke = function(player: Player, cmd: any): any
		if not RunService:IsStudio() or type(cmd) ~= "table" or type(cmd.cmd) ~= "string" then
			return { ok = false, message = "rejected" }
		end
		local name = cmd.cmd
		if name == "AddVision" then
			if not isInt(cmd.territoryId) or not isInt(cmd.range) then
				return { ok = false, message = "bad args" }
			end
			local sourceId, changed = VisibilitySystem.addSource(player, cmd.territoryId, cmd.range, "Dev source")
			sendDelta(player, changed)
			return { ok = sourceId ~= nil, sourceId = sourceId, changed = #changed }
		elseif name == "MoveVision" then
			if not isInt(cmd.sourceId) or not isInt(cmd.territoryId) then
				return { ok = false, message = "bad args" }
			end
			local changed = VisibilitySystem.moveSource(player, cmd.sourceId, cmd.territoryId)
			sendDelta(player, changed)
			return { ok = true, changed = #changed }
		elseif name == "RemoveVision" then
			if not isInt(cmd.sourceId) then
				return { ok = false, message = "bad args" }
			end
			local changed = VisibilitySystem.removeSource(player, cmd.sourceId)
			sendDelta(player, changed)
			return { ok = true, changed = #changed }
		elseif name == "ClearVision" then
			local changed = VisibilitySystem.clearSources(player)
			sendDelta(player, changed)
			return { ok = true, changed = #changed }
		elseif name == "RevealAll" then
			local changed = VisibilitySystem.setRevealAll(player, cmd.value == true)
			sendDelta(player, changed)
			return { ok = true, changed = #changed }
		elseif name == "SetOwner" then
			if not isInt(cmd.territoryId) or (cmd.ownerId ~= nil and not isInt(cmd.ownerId)) then
				return { ok = false, message = "bad args" }
			end
			local ok = TerritorySystem.setOwner(cmd.territoryId, cmd.ownerId)
			return { ok = ok }
		elseif name == "Status" then
			return {
				ok = true,
				sources = VisibilitySystem.listSources(player),
				summary = VisibilitySystem.summary(player),
				revealAll = VisibilitySystem.isRevealAll(player),
				seq = VisibilitySystem.getSeq(player),
				version = TerritorySystem.getVersion(),
			}
		end
		return { ok = false, message = "unknown command" }
	end
end

buildMap(MapConfig.DEFAULT_SEED, MapConfig.DEFAULT_TERRITORY_COUNT)
