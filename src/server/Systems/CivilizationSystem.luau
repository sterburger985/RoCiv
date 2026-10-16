--!strict
-- CivilizationSystem (server)
-- Minimal civilization identities for Phase 2. Keeps three concepts apart:
--   Roblox Player  --controls-->  Civilization  --owns-->  Territories
-- Territory ownership itself lives in TerritorySystem (the single place
-- ownership can change); this module only describes civilizations and who
-- controls them.

export type ControllerType = "Player" | "AI" | "None"

export type Civilization = {
	civilizationId: number,
	displayName: string,
	color: Color3,
	controllerType: ControllerType,
	playerUserId: number?, -- Roblox UserId when controllerType == "Player"
	capitalCityId: number?, -- unset until cities exist (Phase 6)
	status: "Active" | "Defeated",
	isTest: boolean, -- development test identity, not the final roster
}

local CivilizationSystem = {}

local civs: { [number]: Civilization } = {}
local order: { number } = {}
local playerToCiv: { [Player]: number } = {}
local listeners: { () -> () } = {}

local function changed()
	for _, fn in listeners do
		task.spawn(fn)
	end
end

function CivilizationSystem.onChanged(fn: () -> ())
	table.insert(listeners, fn)
end

function CivilizationSystem.create(id: number, displayName: string, color: Color3, isTest: boolean?): Civilization
	assert(type(id) == "number" and id >= 1 and id % 1 == 0, "civilizationId must be a positive integer")
	assert(civs[id] == nil, "civilizationId already exists")
	local civ: Civilization = {
		civilizationId = id,
		displayName = displayName,
		color = color,
		controllerType = "None",
		playerUserId = nil,
		capitalCityId = nil,
		status = "Active",
		isTest = isTest == true,
	}
	civs[id] = civ
	table.insert(order, id)
	table.sort(order)
	changed()
	return civ
end

function CivilizationSystem.get(id: number?): Civilization?
	return if id then civs[id] else nil
end

function CivilizationSystem.exists(id: any): boolean
	return type(id) == "number" and civs[id] ~= nil
end

function CivilizationSystem.ids(): { number }
	return table.clone(order)
end

function CivilizationSystem.clear()
	table.clear(civs)
	table.clear(order)
	table.clear(playerToCiv)
	changed()
end

-- Player <-> civilization control ---------------------------------------------

function CivilizationSystem.assignPlayer(player: Player, civId: number): boolean
	local civ = civs[civId]
	if not civ then
		return false
	end
	-- One controller per civilization, one civilization per player.
	for p, id in playerToCiv do
		if id == civId and p ~= player then
			return false
		end
	end
	local previous = playerToCiv[player]
	if previous and civs[previous] then
		civs[previous].controllerType = "None"
		civs[previous].playerUserId = nil
	end
	playerToCiv[player] = civId
	civ.controllerType = "Player"
	civ.playerUserId = player.UserId
	changed()
	return true
end

function CivilizationSystem.releasePlayer(player: Player)
	local id = playerToCiv[player]
	if id and civs[id] then
		civs[id].controllerType = "None"
		civs[id].playerUserId = nil
	end
	playerToCiv[player] = nil
	changed()
end

function CivilizationSystem.civilizationOf(player: Player): number?
	return playerToCiv[player]
end

-- Public description sent to clients (names and colours are not secret).
function CivilizationSystem.publicList(): { { [string]: any } }
	local list = {}
	for _, id in order do
		local c = civs[id]
		table.insert(list, {
			civilizationId = c.civilizationId,
			displayName = c.displayName,
			color = c.color,
			controllerType = c.controllerType,
			status = c.status,
			isTest = c.isTest,
		})
	end
	return list
end

-- Development test identities (not the final roster): one per start
-- position of the current match size.
local TEST_COLORS = {
	Color3.fromRGB(60, 120, 235),
	Color3.fromRGB(220, 60, 60),
	Color3.fromRGB(60, 190, 90),
	Color3.fromRGB(235, 180, 40),
	Color3.fromRGB(160, 80, 210),
	Color3.fromRGB(40, 190, 200),
	Color3.fromRGB(240, 120, 40),
	Color3.fromRGB(230, 110, 180),
}
function CivilizationSystem.createTestCivilizations(count: number?)
	CivilizationSystem.clear()
	local n = math.clamp(count or 3, 1, #TEST_COLORS)
	for i = 1, n do
		CivilizationSystem.create(i, string.format("Civilization %s (test)", string.char(64 + i)), TEST_COLORS[i], true)
	end
end

return CivilizationSystem
