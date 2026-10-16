--!strict
-- MapService (Script, ServerScriptService.RoCiv)
-- Network layer for the strategic map.
--   * Generates + validates the map, builds the movement graph (Phase 3),
--     and hands both to the server systems.
--   * Builds a per-player view filtered by VisibilitySystem: geometry for
--     every territory, but terrain/owner data only for what that player has
--     discovered. Clients never receive data they have not seen.
--   * Sends small per-player deltas when visibility or ownership changes.
--   * Route / range previews are computed on the server with the player's
--     own knowledge, so routes never reveal unexplored terrain.
--   * Studio-only dev remotes: regenerate, vision, ownership, diagnostics.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("RoCiv"):WaitForChild("Shared")
local MapConfig = require(Shared:WaitForChild("MapConfig"))
local MapFolder = script.Parent:WaitForChild("Map")
local Systems = script.Parent:WaitForChild("Systems")
local MapGenerator = require(MapFolder:WaitForChild("MapGenerator"))
local MapValidator = require(MapFolder:WaitForChild("MapValidator"))
local MovementGraph = require(MapFolder:WaitForChild("MovementGraph"))
local Pathfinding = require(MapFolder:WaitForChild("Pathfinding"))
local CivilizationSystem = require(Systems:WaitForChild("CivilizationSystem"))
local TerritorySystem = require(Systems:WaitForChild("TerritorySystem"))
local VisibilitySystem = require(Systems:WaitForChild("VisibilitySystem"))

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

local function remote(className: string, name: string): any
	local r = Instance.new(className)
	r.Name = name
	r.Parent = remotes
	return r
end

local getMap = remote("RemoteFunction", "GetMap") :: RemoteFunction
local mapUpdated = remote("RemoteEvent", "MapUpdated") :: RemoteEvent
local territoryDelta = remote("RemoteEvent", "TerritoryDelta") :: RemoteEvent
local civsUpdated = remote("RemoteEvent", "CivilizationsUpdated") :: RemoteEvent
local getMovementGraph = remote("RemoteFunction", "GetMovementGraph") :: RemoteFunction
local requestRoute = remote("RemoteFunction", "RequestRoute") :: RemoteFunction
local requestRange = remote("RemoteFunction", "RequestRange") :: RemoteFunction
local devRegenerate: RemoteEvent? = if DEV_TOOLS then remote("RemoteEvent", "DevRegenerate") else nil
local devCommand: RemoteFunction? = if DEV_TOOLS then remote("RemoteFunction", "DevCommand") else nil
remotes.Parent = rocivFolder

-- State ------------------------------------------------------------------------

local generating = false
local lastDevInfo: { [string]: any }? = nil
local movementGraph: MovementGraph.Graph? = nil

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
		view.cityId = t.cityId
		view.riverPath = t.riverPath -- river course inside this territory (nil = none)
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
		civilizations = CivilizationSystem.publicList(),
		yourCivilizationId = CivilizationSystem.civilizationOf(player),
	}
end

-- What this player knows about a movement region (nil = unexplored).
local function knowledgeFor(player: Player): Pathfinding.Knowledge
	return function(rid: number)
		local graph = movementGraph
		if not graph then
			return nil
		end
		local r = graph.regions[rid]
		if not r or VisibilitySystem.getState(player, r.territoryId) == "Unexplored" then
			return nil
		end
		return r
	end
end

-- Server-side route self-test: A* must match Dijkstra and every route must
-- be legal. Uses true terrain.
local function selfTestRoutes(graph: MovementGraph.Graph, seed: number): { [string]: any }
	local rng = Random.new(seed + 99)
	local tested, failures, noRoute = 0, 0, 0
	local t0 = os.clock()
	local ids = graph.regionIds
	for _ = 1, 40 do
		local a = ids[rng:NextInteger(1, #ids)]
		local b = ids[rng:NextInteger(1, #ids)]
		local domain: Pathfinding.Domain = if graph.regions[a].isWater then "Naval" else "Land"
		local opts = { domain = domain }
		local result = Pathfinding.findPath(graph, a, b, opts)
		local dist = Pathfinding.reachable(graph, a, math.huge, opts)
		tested += 1
		if result then
			local ok = Pathfinding.validatePath(graph, result, opts)
			if not ok or math.abs((dist[b] or -1) - result.cost) > 1e-6 then
				failures += 1
			end
		elseif dist[b] ~= nil and a ~= b then
			failures += 1 -- Dijkstra found a route A* missed
		else
			noRoute += 1
		end
	end
	return { tested = tested, failures = failures, noRoute = noRoute, ms = (os.clock() - t0) * 1000 }
end

-- Map lifecycle --------------------------------------------------------------

local function buildMap(seed: number, matchSize: string, count: number?)
	generating = true
	local t0 = os.clock()
	local map = MapGenerator.generate({ seed = seed, matchSize = matchSize, territoryCount = count })
	local genMs = (os.clock() - t0) * 1000
	local report = MapValidator.validate(map)
	local text = MapValidator.format(report)
	local fp = MapGenerator.fingerprint(map)

	print(
		string.format(
			"[MapService] Generated %s map seed=%d (base %d, attempt %d) territories=%d continents=%d rivers=%d starts=%d size=%dx%d in %.1f ms (voronoi %.1f ms) fingerprint=%s",
			map.matchSize,
			map.seed,
			map.baseSeed,
			map.attempt,
			map.territoryCount,
			map.continentCount,
			#map.rivers,
			#map.startPositions,
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

	local graph = MovementGraph.build(map)
	local graphOk, graphProblems, graphInfo = MovementGraph.validate(graph, map)
	local routeTest = selfTestRoutes(graph, map.seed)
	local graphText = string.format(
		"[MovementGraph] %s - %d regions (avg %.2f neighbours) built in %.1f ms; route self-test %d/%d ok (%d unreachable pairs) in %.1f ms",
		if graphOk and routeTest.failures == 0 then "PASS" else "FAIL",
		graphInfo.regionCount,
		graphInfo.averageNeighbors,
		graph.stats.buildMs,
		routeTest.tested - routeTest.failures,
		routeTest.tested,
		routeTest.noRoute,
		routeTest.ms
	)
	if graphOk and routeTest.failures == 0 then
		print(graphText)
	else
		warn(graphText)
		for _, p in graphProblems do
			warn("  " .. p)
		end
	end

	TerritorySystem.setMap(map)
	movementGraph = graph
	if DEV_TOOLS and #CivilizationSystem.ids() ~= map.civilizations then
		-- Development: one test civilization per start position; testers keep
		-- their slot order.
		local testers = {}
		for _, p in Players:GetPlayers() do
			table.insert(testers, p)
		end
		CivilizationSystem.createTestCivilizations(map.civilizations)
		for i, p in testers do
			if i <= map.civilizations then
				CivilizationSystem.assignPlayer(p, i)
			end
		end
	end
	VisibilitySystem.resetAll()
	lastDevInfo = if DEV_TOOLS
		then {
			seed = map.baseSeed,
			actualSeed = map.seed,
			attempt = map.attempt,
			matchSize = map.matchSize,
			continents = map.continentCount,
			rivers = #map.rivers,
			starts = #map.startPositions,
			territoryCount = map.territoryCount,
			width = map.width,
			height = map.height,
			generationMs = genMs,
			validationMs = report.durationMs,
			validationOk = report.ok,
			errorCount = #report.errors,
			warningCount = #report.warnings,
			fingerprint = fp,
			regionCount = graphInfo.regionCount,
			movementOk = graphOk and routeTest.failures == 0,
		}
		else nil
	generating = false
	mapUpdated:FireAllClients(TerritorySystem.getVersion())
end

local function waitForMap()
	while generating or not TerritorySystem.getMap() do
		task.wait(0.1)
	end
end

getMap.OnServerInvoke = function(player: Player)
	waitForMap()
	VisibilitySystem.addPlayer(player)
	local payload = buildPayload(player)
	payload.devInfo = lastDevInfo
	if DEV_TOOLS then
		payload.seed = (TerritorySystem.getMap() :: any).baseSeed
	end
	return payload
end

getMovementGraph.OnServerInvoke = function(_player: Player)
	waitForMap()
	local graph = movementGraph :: MovementGraph.Graph
	local list = table.create(#graph.regionIds)
	for _, rid in graph.regionIds do
		local r = graph.regions[rid]
		-- Geometry and topology only; terrain comes from the player's
		-- territory knowledge, so nothing hidden leaks here.
		table.insert(list, {
			id = r.id,
			territoryId = r.territoryId,
			polygon = r.polygon,
			centroid = r.centroid,
			neighbors = r.neighbors,
		})
	end
	return { version = TerritorySystem.getVersion(), regions = list }
end

-- Simple per-player rate limit for preview requests.
local lastRequests: { [Player]: { number } } = {}
local function allowRequest(player: Player): boolean
	local now = os.clock()
	local list = lastRequests[player] or {}
	local kept = {}
	for _, t in list do
		if now - t < 1 then
			table.insert(kept, t)
		end
	end
	if #kept >= MapConfig.ROUTE_REQUESTS_PER_SECOND then
		lastRequests[player] = kept
		return false
	end
	table.insert(kept, now)
	lastRequests[player] = kept
	return true
end

local function isInt(v: any): boolean
	return type(v) == "number" and v == v and v % 1 == 0 and math.abs(v) < 2 ^ 31
end

local function validDomain(d: any): Pathfinding.Domain?
	if d == "Land" or d == "Naval" then
		return d
	end
	return nil
end

requestRoute.OnServerInvoke = function(player: Player, startId: any, goalId: any, domain: any)
	if not allowRequest(player) then
		return { ok = false, reason = "rate limited" }
	end
	local graph = movementGraph
	local d = validDomain(domain)
	if not graph or generating or not isInt(startId) or not isInt(goalId) or not d then
		return { ok = false, reason = "bad request" }
	end
	local result, reason = Pathfinding.findPath(graph, startId, goalId, { domain = d, knowledge = knowledgeFor(player) })
	if not result then
		return { ok = false, reason = reason }
	end
	return {
		ok = true,
		version = TerritorySystem.getVersion(),
		path = result.path,
		cost = result.cost,
		stepCosts = result.stepCosts,
		expanded = result.expanded,
	}
end

requestRange.OnServerInvoke = function(player: Player, startId: any, budget: any, domain: any)
	if not allowRequest(player) then
		return { ok = false, reason = "rate limited" }
	end
	local graph = movementGraph
	local d = validDomain(domain)
	if not graph or generating or not isInt(startId) or type(budget) ~= "number" or budget ~= budget or not d then
		return { ok = false, reason = "bad request" }
	end
	budget = math.clamp(budget, 0, MapConfig.MAX_RANGE_BUDGET)
	local dist = Pathfinding.reachable(graph, startId, budget, { domain = d, knowledge = knowledgeFor(player) })
	local list = {}
	for rid, cost in dist do
		table.insert(list, { id = rid, cost = cost })
	end
	return { ok = true, version = TerritorySystem.getVersion(), budget = budget, regions = list }
end

-- Players ----------------------------------------------------------------------

local function broadcastCivs()
	for _, p in Players:GetPlayers() do
		civsUpdated:FireClient(p, CivilizationSystem.publicList(), CivilizationSystem.civilizationOf(p))
	end
end
CivilizationSystem.onChanged(broadcastCivs)

local function onPlayerAdded(player: Player)
	VisibilitySystem.addPlayer(player)
	if DEV_TOOLS then
		-- Development: give each tester the first free test civilization.
		for _, id in CivilizationSystem.ids() do
			if CivilizationSystem.assignPlayer(player, id) then
				break
			end
		end
	end
	-- After civ assignment so vision starts at that civ's start position.
	if TerritorySystem.getMap() and #VisibilitySystem.listSources(player) == 0 then
		VisibilitySystem.giveStartVision(player)
	end
end

-- Test civilizations exist only for development; production rosters arrive
-- with match setup in a later phase.
if DEV_TOOLS then
	CivilizationSystem.createTestCivilizations(MapConfig.MATCH_SIZES[MapConfig.DEFAULT_MATCH_SIZE].civilizations)
end

-- Each player's starting vision is centred on their civilization's
-- generated start position (players without one share start 1).
VisibilitySystem.setStartResolver(function(player: Player): number?
	local map = TerritorySystem.getMap() :: any
	if not map or not map.startPositions or #map.startPositions == 0 then
		return nil
	end
	local civId = CivilizationSystem.civilizationOf(player)
	return map.startPositions[civId or 1] or map.startPositions[1]
end)

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in Players:GetPlayers() do
	onPlayerAdded(p)
end
Players.PlayerRemoving:Connect(function(player)
	VisibilitySystem.removePlayer(player)
	CivilizationSystem.releasePlayer(player)
	lastRequests[player] = nil
end)

-- Ownership changes reach only the players who can currently see them.
TerritorySystem.onOwnerChanged(function(territoryId, _old, newOwner)
	for _, player in VisibilitySystem.noteOwnerChange(territoryId, newOwner) do
		sendDelta(player, { territoryId })
	end
end)

-- Development remotes (Studio only) ------------------------------------------

if devRegenerate then
	devRegenerate.OnServerEvent:Connect(function(player: Player, seed: any, matchSize: any, count: any)
		-- Defence in depth: never honour this outside Studio.
		if not RunService:IsStudio() or generating then
			return
		end
		if not isInt(seed) or type(matchSize) ~= "string" or MapConfig.MATCH_SIZES[matchSize] == nil then
			return
		end
		-- Optional territory override (testing); nil = the match size's count.
		if count ~= nil then
			if type(count) ~= "number" or count ~= count then
				return
			end
			count = math.clamp(math.floor(count), MapConfig.MIN_TERRITORY_COUNT, MapConfig.MAX_TERRITORY_COUNT)
		end
		print(string.format("[MapService] Dev regenerate requested by %s: seed=%d size=%s count=%s", player.Name, seed, matchSize, tostring(count)))
		buildMap(seed, matchSize, count)
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
		elseif name == "AssignOwner" then
			if not isInt(cmd.territoryId) or not isInt(cmd.civilizationId) then
				return { ok = false, message = "bad args" }
			end
			local ok, reason = TerritorySystem.assignOwner(cmd.territoryId, cmd.civilizationId)
			return { ok = ok, message = reason }
		elseif name == "ClearOwner" then
			if not isInt(cmd.territoryId) then
				return { ok = false, message = "bad args" }
			end
			local ok, reason = TerritorySystem.clearOwner(cmd.territoryId)
			return { ok = ok, message = reason }
		elseif name == "SetRoads" then
			-- Placeholder roads (real road building arrives with improvements).
			local graph = movementGraph
			if not graph or type(cmd.regionIds) ~= "table" or #cmd.regionIds > 500 then
				return { ok = false, message = "bad args" }
			end
			local value = cmd.value == true
			local n = 0
			for _, rid in cmd.regionIds do
				local r = if isInt(rid) then graph.regions[rid] else nil
				if r and not r.isWater then
					r.hasRoad = value
					n += 1
				end
			end
			return { ok = true, changed = n }
		elseif name == "CivStatus" then
			local civs = {}
			for _, id in CivilizationSystem.ids() do
				local c = CivilizationSystem.get(id) :: CivilizationSystem.Civilization
				table.insert(civs, {
					civilizationId = id,
					displayName = c.displayName,
					controllerType = c.controllerType,
					territories = TerritorySystem.getTerritoriesOf(id),
					frontier = #TerritorySystem.getFrontier(id, true),
				})
			end
			local ok, problems = TerritorySystem.validateOwnership()
			return { ok = true, civilizations = civs, ownershipValid = ok, problems = problems }
		elseif name == "Status" then
			return {
				ok = true,
				sources = VisibilitySystem.listSources(player),
				summary = VisibilitySystem.summary(player),
				revealAll = VisibilitySystem.isRevealAll(player),
				seq = VisibilitySystem.getSeq(player),
				version = TerritorySystem.getVersion(),
				yourCivilizationId = CivilizationSystem.civilizationOf(player),
			}
		end
		return { ok = false, message = "unknown command" }
	end
end

buildMap(MapConfig.DEFAULT_SEED, MapConfig.DEFAULT_MATCH_SIZE)
