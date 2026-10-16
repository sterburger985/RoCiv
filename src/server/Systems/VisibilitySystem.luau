--!strict
-- VisibilitySystem (server)
-- Authoritative fog of war. Stores, per player, which territories are
-- Visible (seen right now), Explored (seen before) or Unexplored (never
-- seen). Visibility is derived from vision sources; it is recalculated only
-- when a source or the map changes, never per frame.
--
-- Vision range is measured in territories (neighbour hops), so water and
-- land are treated identically: every territory has a state.
--
-- This module holds data only. The network layer (MapService) decides what
-- each client may receive, and the client only draws what it is told.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("RoCiv"):WaitForChild("Shared")
local MapConfig = require(Shared:WaitForChild("MapConfig"))
local TerritorySystem = require(script.Parent:WaitForChild("TerritorySystem"))

export type VisibilityState = "Unexplored" | "Explored" | "Visible"

type Source = { territoryId: number, range: number, label: string }
type PlayerState = {
	visible: { [number]: boolean },
	explored: { [number]: boolean },
	sources: { [number]: Source },
	nextSourceId: number,
	revealAll: boolean,
	-- Last owner this player actually saw for each territory (shown while
	-- the territory is only Explored).
	knownOwner: { [number]: number },
	seq: number,
}

local VisibilitySystem = {}

local states: { [Player]: PlayerState } = {}

local function newState(): PlayerState
	return {
		visible = {},
		explored = {},
		sources = {},
		nextSourceId = 1,
		revealAll = false,
		knownOwner = {},
		seq = 0,
	}
end

local function stateOf(ps: PlayerState, id: number): VisibilityState
	if ps.visible[id] then
		return "Visible"
	elseif ps.explored[id] then
		return "Explored"
	end
	return "Unexplored"
end

-- Breadth-first search over the neighbour graph up to `range` hops. Each
-- source gets its own visited set: sharing one with other sources would
-- stop this flood wherever another source already reached (bug found in
-- testing: a wide source inside a narrow one revealed nothing extra).
local function floodFrom(startId: number, range: number, into: { [number]: boolean })
	local start = TerritorySystem.get(startId)
	if not start then
		return
	end
	local seen: { [number]: boolean } = { [startId] = true }
	into[startId] = true
	local frontier = { startId }
	for _ = 1, range do
		local nextFrontier = {}
		for _, id in frontier do
			local t = TerritorySystem.get(id)
			if t then
				for _, nb in t.neighbors do
					if not seen[nb] then
						seen[nb] = true
						into[nb] = true
						table.insert(nextFrontier, nb)
					end
				end
			end
		end
		frontier = nextFrontier
		if #frontier == 0 then
			break
		end
	end
end

-- Recomputes one player's visibility. Returns the ids whose state changed.
local function recompute(ps: PlayerState): { number }
	local newVisible: { [number]: boolean } = {}
	if ps.revealAll or not MapConfig.FOG_OF_WAR_ENABLED then
		for _, id in TerritorySystem.ids() do
			newVisible[id] = true
		end
	else
		for _, src in ps.sources do
			floodFrom(src.territoryId, src.range, newVisible)
		end
	end

	local changed: { number } = {}
	for _, id in TerritorySystem.ids() do
		local before = stateOf(ps, id)
		local nowVisible = newVisible[id] == true
		if nowVisible then
			ps.explored[id] = true
			-- Remember what the player saw while it was visible.
			local t = TerritorySystem.get(id)
			if t then
				ps.knownOwner[id] = t.ownerId :: any
			end
		end
		ps.visible[id] = if nowVisible then true else nil
		if stateOf(ps, id) ~= before then
			table.insert(changed, id)
		end
	end
	if #changed > 0 then
		ps.seq += 1
	end
	return changed
end

-- Public API ---------------------------------------------------------------

function VisibilitySystem.addPlayer(player: Player)
	if not states[player] then
		states[player] = newState()
	end
end

function VisibilitySystem.removePlayer(player: Player)
	states[player] = nil
end

function VisibilitySystem.players(): { Player }
	local list = {}
	for p in states do
		table.insert(list, p)
	end
	return list
end

-- Clears all visibility (used when a new map is generated) and gives every
-- player the placeholder start vision.
function VisibilitySystem.resetAll()
	for player, ps in states do
		local seq = ps.seq
		local fresh = newState()
		fresh.seq = seq + 1
		fresh.revealAll = ps.revealAll
		states[player] = fresh
		VisibilitySystem.giveStartVision(player)
	end
end

-- MapService supplies the start territory for a player (their
-- civilization's generated start position); fallback = land nearest centre.
local startResolver: ((Player) -> number?)? = nil
function VisibilitySystem.setStartResolver(fn: (Player) -> number?)
	startResolver = fn
end

function VisibilitySystem.giveStartVision(player: Player): { number }
	local ps = states[player]
	local start = if startResolver then startResolver(player) else nil
	if not start or not TerritorySystem.get(start) then
		start = TerritorySystem.landNearestCentre()
	end
	if not ps or not start then
		return {}
	end
	local id = ps.nextSourceId
	ps.nextSourceId += 1
	ps.sources[id] = { territoryId = start, range = MapConfig.START_VISION_RANGE, label = "Start" }
	return recompute(ps)
end

function VisibilitySystem.addSource(player: Player, territoryId: number, range: number, label: string?): (number?, { number })
	local ps = states[player]
	if not ps or not TerritorySystem.get(territoryId) then
		return nil, {}
	end
	local id = ps.nextSourceId
	ps.nextSourceId += 1
	ps.sources[id] = { territoryId = territoryId, range = math.clamp(math.floor(range), 0, 20), label = label or "Source" }
	return id, recompute(ps)
end

function VisibilitySystem.moveSource(player: Player, sourceId: number, territoryId: number): { number }
	local ps = states[player]
	if not ps or not ps.sources[sourceId] or not TerritorySystem.get(territoryId) then
		return {}
	end
	ps.sources[sourceId].territoryId = territoryId
	return recompute(ps)
end

function VisibilitySystem.removeSource(player: Player, sourceId: number): { number }
	local ps = states[player]
	if not ps or not ps.sources[sourceId] then
		return {}
	end
	ps.sources[sourceId] = nil
	return recompute(ps)
end

function VisibilitySystem.clearSources(player: Player): { number }
	local ps = states[player]
	if not ps then
		return {}
	end
	table.clear(ps.sources)
	return recompute(ps)
end

function VisibilitySystem.listSources(player: Player): { { id: number, territoryId: number, range: number, label: string } }
	local ps = states[player]
	local list = {}
	if ps then
		for id, s in ps.sources do
			table.insert(list, { id = id, territoryId = s.territoryId, range = s.range, label = s.label })
		end
		table.sort(list, function(a, b)
			return a.id < b.id
		end)
	end
	return list
end

function VisibilitySystem.setRevealAll(player: Player, value: boolean): { number }
	local ps = states[player]
	if not ps then
		return {}
	end
	ps.revealAll = value
	return recompute(ps)
end

function VisibilitySystem.isRevealAll(player: Player): boolean
	local ps = states[player]
	return ps ~= nil and ps.revealAll
end

function VisibilitySystem.getState(player: Player, territoryId: number): VisibilityState
	local ps = states[player]
	if not ps then
		return "Unexplored"
	end
	return stateOf(ps, territoryId)
end

function VisibilitySystem.knownOwner(player: Player, territoryId: number): number?
	local ps = states[player]
	return if ps then ps.knownOwner[territoryId] else nil
end

-- Called when a territory's owner changes: players who can see it learn the
-- new owner. Returns the players that should receive an update.
function VisibilitySystem.noteOwnerChange(territoryId: number, newOwner: number?): { Player }
	local who = {}
	for player, ps in states do
		if ps.visible[territoryId] then
			ps.knownOwner[territoryId] = newOwner :: any
			ps.seq += 1
			table.insert(who, player)
		end
	end
	return who
end

function VisibilitySystem.getSeq(player: Player): number
	local ps = states[player]
	return if ps then ps.seq else 0
end

-- Counts per state (diagnostics / tests).
function VisibilitySystem.summary(player: Player): { [string]: number }
	local counts = { Visible = 0, Explored = 0, Unexplored = 0 }
	for _, id in TerritorySystem.ids() do
		local s = VisibilitySystem.getState(player, id)
		counts[s] += 1
	end
	return counts
end

return VisibilitySystem
