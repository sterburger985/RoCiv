--!strict
-- TerritorySystem (server)
-- Owns the authoritative strategic map (MapData) for the current match and
-- is the ONLY place territory ownership may change. Other systems (future
-- expansion, conquest, diplomacy) must call this API instead of writing
-- `territory.ownerId` themselves.
--
-- Ownership is stored on the territory record (`ownerId` = civilizationId or
-- nil) plus an index civilizationId -> set of territory ids, which is kept in
-- sync by this module and checked by validateOwnership().

local MapGenerator = require(script.Parent.Parent:WaitForChild("Map"):WaitForChild("MapGenerator"))
local CivilizationSystem = require(script.Parent:WaitForChild("CivilizationSystem"))

type MapData = MapGenerator.MapData
type Territory = MapGenerator.Territory

export type OwnerChangedListener = (territoryId: number, oldOwner: number?, newOwner: number?) -> ()

local TerritorySystem = {}

local currentMap: MapData? = nil
local mapVersion = 0
local ownerListeners: { OwnerChangedListener } = {}
local ownedBy: { [number]: { [number]: boolean } } = {}

-- Map lifecycle --------------------------------------------------------------

function TerritorySystem.setMap(map: MapData): number
	currentMap = map
	mapVersion += 1
	table.clear(ownedBy)
	for _, id in map.territoryIds do
		local owner = map.territories[id].ownerId
		if owner then
			ownedBy[owner] = ownedBy[owner] or {}
			ownedBy[owner][id] = true
		end
	end
	return mapVersion
end

function TerritorySystem.getMap(): MapData?
	return currentMap
end

function TerritorySystem.getVersion(): number
	return mapVersion
end

function TerritorySystem.get(id: number): Territory?
	if not currentMap then
		return nil
	end
	return currentMap.territories[id]
end

function TerritorySystem.ids(): { number }
	return if currentMap then currentMap.territoryIds else {}
end

function TerritorySystem.neighborsOf(id: number): { number }
	local t = TerritorySystem.get(id)
	return if t then t.neighbors else {}
end

-- Ownership queries -----------------------------------------------------------

function TerritorySystem.getOwner(id: number): number?
	local t = TerritorySystem.get(id)
	return if t then t.ownerId else nil
end

function TerritorySystem.isUnowned(id: number): boolean
	local t = TerritorySystem.get(id)
	return t ~= nil and t.ownerId == nil
end

function TerritorySystem.isOwnedBy(id: number, civId: number): boolean
	local t = TerritorySystem.get(id)
	return t ~= nil and t.ownerId == civId
end

-- Sorted list of the territories a civilization owns.
function TerritorySystem.getTerritoriesOf(civId: number): { number }
	local list = {}
	for id in ownedBy[civId] or {} do
		table.insert(list, id)
	end
	table.sort(list)
	return list
end

function TerritorySystem.countOf(civId: number): number
	local n = 0
	for _ in ownedBy[civId] or {} do
		n += 1
	end
	return n
end

-- Ownership changes (the only write path) ---------------------------------

local function setOwnerInternal(id: number, ownerId: number?): (boolean, string?)
	local t = TerritorySystem.get(id)
	if not t then
		return false, "unknown territory"
	end
	if ownerId ~= nil and not CivilizationSystem.exists(ownerId) then
		return false, "unknown civilization"
	end
	local old = t.ownerId
	if old == ownerId then
		return false, "unchanged"
	end
	if old and ownedBy[old] then
		ownedBy[old][id] = nil
	end
	if ownerId then
		ownedBy[ownerId] = ownedBy[ownerId] or {}
		ownedBy[ownerId][id] = true
	end
	t.ownerId = ownerId
	for _, fn in ownerListeners do
		task.spawn(fn, id, old, ownerId)
	end
	return true, nil
end

-- Assigns a territory to a civilization (replacing any previous owner).
function TerritorySystem.assignOwner(id: number, civId: number): (boolean, string?)
	return setOwnerInternal(id, civId)
end

-- Makes a territory unowned.
function TerritorySystem.clearOwner(id: number): (boolean, string?)
	return setOwnerInternal(id, nil)
end

function TerritorySystem.onOwnerChanged(fn: OwnerChangedListener)
	table.insert(ownerListeners, fn)
end

-- Foundations for future territorial expansion (no claiming rules yet) ------

-- True if `id` borders any territory owned by `civId`.
function TerritorySystem.isAdjacentToCivilization(id: number, civId: number): boolean
	for _, nb in TerritorySystem.neighborsOf(id) do
		if TerritorySystem.isOwnedBy(nb, civId) then
			return true
		end
	end
	return false
end

-- Unowned territories bordering a civilization (candidate expansion targets).
-- `landOnly` skips water territories.
function TerritorySystem.getFrontier(civId: number, landOnly: boolean?): { number }
	local seen: { [number]: boolean } = {}
	local list = {}
	for id in ownedBy[civId] or {} do
		for _, nb in TerritorySystem.neighborsOf(id) do
			local t = TerritorySystem.get(nb)
			if t and not seen[nb] and t.ownerId == nil and (not landOnly or not t.isWater) then
				seen[nb] = true
				table.insert(list, nb)
			end
		end
	end
	table.sort(list)
	return list
end

-- Consistency checks -----------------------------------------------------------

function TerritorySystem.validateOwnership(): (boolean, { string })
	local problems = {}
	if not currentMap then
		return true, problems
	end
	local indexCount: { [number]: number } = {}
	for civId, set in ownedBy do
		for id in set do
			local t = currentMap.territories[id]
			if not t then
				table.insert(problems, string.format("index lists missing territory %d under civ %d", id, civId))
			elseif t.ownerId ~= civId then
				table.insert(problems, string.format("index says civ %d owns %d but data says %s", civId, id, tostring(t.ownerId)))
			end
			indexCount[id] = (indexCount[id] or 0) + 1
			if indexCount[id] > 1 then
				table.insert(problems, string.format("territory %d appears under more than one civilization", id))
			end
		end
	end
	for _, id in currentMap.territoryIds do
		local owner = currentMap.territories[id].ownerId
		if owner ~= nil then
			if not CivilizationSystem.exists(owner) then
				table.insert(problems, string.format("territory %d owned by unknown civilization %s", id, tostring(owner)))
			end
			if not (ownedBy[owner] and ownedBy[owner][id]) then
				table.insert(problems, string.format("territory %d owner %d missing from index", id, owner))
			end
		end
	end
	return #problems == 0, problems
end

-- Placeholder start location (until real start-position selection exists).
function TerritorySystem.landNearestCentre(): number?
	if not currentMap then
		return nil
	end
	local centre = Vector2.new(currentMap.width * 0.5, currentMap.height * 0.5)
	local best, bestDist = nil, math.huge
	for _, id in currentMap.territoryIds do
		local t = currentMap.territories[id]
		if not t.isWater then
			local d = (t.centroid - centre).Magnitude
			if d < bestDist then
				best, bestDist = id, d
			end
		end
	end
	return best
end

return TerritorySystem
