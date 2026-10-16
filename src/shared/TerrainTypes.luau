--!strict
-- TerrainTypes
-- Definitions for every terrain type used by the strategic map.
-- Gameplay systems should read terrain properties from here rather than
-- hard-coding values. Movement values are placeholders for Phase 3.

export type TerrainDef = {
	id: string,
	displayName: string,
	color: Color3,
	isWater: boolean,
	baseFertility: number, -- 0..1
	moveCost: number, -- placeholder for Phase 3 movement
	passableByLand: boolean,
}

local TerrainTypes = {}

local defs: { TerrainDef } = {
	{
		id = "Ocean",
		displayName = "Ocean",
		color = Color3.fromRGB(38, 82, 140),
		isWater = true,
		baseFertility = 0.15,
		moveCost = 1,
		passableByLand = false,
	},
	{
		-- Coast = shallow water next to land (Civilization convention).
		id = "Coast",
		displayName = "Coast",
		color = Color3.fromRGB(78, 140, 196),
		isWater = true,
		baseFertility = 0.35,
		moveCost = 1,
		passableByLand = false,
	},
	{
		id = "Grassland",
		displayName = "Grassland",
		color = Color3.fromRGB(110, 170, 80),
		isWater = false,
		baseFertility = 0.75,
		moveCost = 1,
		passableByLand = true,
	},
	{
		id = "Plains",
		displayName = "Plains",
		color = Color3.fromRGB(184, 176, 96),
		isWater = false,
		baseFertility = 0.6,
		moveCost = 1,
		passableByLand = true,
	},
	{
		id = "Forest",
		displayName = "Forest",
		color = Color3.fromRGB(46, 110, 62),
		isWater = false,
		baseFertility = 0.45,
		moveCost = 2,
		passableByLand = true,
	},
	{
		id = "Desert",
		displayName = "Desert",
		color = Color3.fromRGB(224, 196, 130),
		isWater = false,
		baseFertility = 0.12,
		moveCost = 1,
		passableByLand = true,
	},
	{
		id = "Tundra",
		displayName = "Tundra",
		color = Color3.fromRGB(176, 188, 186),
		isWater = false,
		baseFertility = 0.2,
		moveCost = 1,
		passableByLand = true,
	},
	{
		id = "Mountains",
		displayName = "Mountains",
		color = Color3.fromRGB(112, 100, 92),
		isWater = false,
		baseFertility = 0.05,
		moveCost = 3,
		passableByLand = true,
	},
}

TerrainTypes.List = defs
TerrainTypes.ById = {} :: { [string]: TerrainDef }
for _, def in defs do
	TerrainTypes.ById[def.id] = def
end

function TerrainTypes.get(id: string): TerrainDef?
	return TerrainTypes.ById[id]
end

function TerrainTypes.isValid(id: any): boolean
	return type(id) == "string" and TerrainTypes.ById[id] ~= nil
end

return TerrainTypes
