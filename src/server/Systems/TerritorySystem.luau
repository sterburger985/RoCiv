--!strict
-- TerritorySystem (server)
-- Owns the authoritative strategic map (MapData) for the current match and
-- territory ownership. Other server systems read territories from here;
-- nothing on the client is ever trusted to change this data.

local MapGenerator = require(script.Parent.Parent:WaitForChild("Map"):WaitForChild("MapGenerator"))

type MapData = MapGenerator.MapData
type Territory = MapGenerator.Territory

export type OwnerChangedListener = (territoryId: number, oldOwner: number?, newOwner: number?) -> ()

local TerritorySystem = {}

local currentMap: MapData? = nil
local mapVersion = 0
local ownerListeners: { OwnerChangedListener } = {}

function TerritorySystem.setMap(map: MapData): number
	currentMap = map
	mapVersion += 1
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

-- Sets (or clears, with nil) a territory's owner. Returns true if it changed.
function TerritorySystem.setOwner(id: number, ownerId: number?): boolean
	local t = TerritorySystem.get(id)
	if not t then
		return false
	end
	if ownerId ~= nil and (type(ownerId) ~= "number" or ownerId < 1 or ownerId % 1 ~= 0) then
		return false
	end
	local old = t.ownerId
	if old == ownerId then
		return false
	end
	t.ownerId = ownerId
	for _, fn in ownerListeners do
		task.spawn(fn, id, old, ownerId)
	end
	return true
end

function TerritorySystem.onOwnerChanged(fn: OwnerChangedListener)
	table.insert(ownerListeners, fn)
end

-- Land territory closest to the map centre (placeholder start location
-- until real start-position selection exists).
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
