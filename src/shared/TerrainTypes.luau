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
	moveCost: number, -- cost to enter a region of this terrain (Phase 3)
	passableByLand: boolean,
	surfaceHeight: number, -- tile height offset in studs (presentation)
	decoration: string?, -- "Trees" | "Peaks" | "Snow" | "Dunes" | nil (presentation)
	decorationColor: Color3?,
}

local TerrainTypes = {}

local defs: { TerrainDef } = {
	{
		id = "Ocean",
		displayName = "Ocean",
		color = Color3.fromRGB(34, 78, 140),
		isWater = true,
		baseFertility = 0.15,
		moveCost = 1,
		passableByLand = false,
		surfaceHeight = -0.9,
	},
	{
		-- Coast = shallow water next to land (Civilization convention).
		id = "Coast",
		displayName = "Coast",
		color = Color3.fromRGB(70, 140, 200),
		isWater = true,
		baseFertility = 0.35,
		moveCost = 1,
		passableByLand = false,
		surfaceHeight = -0.6,
	},
	{
		id = "Grassland",
		displayName = "Grassland",
		color = Color3.fromRGB(104, 166, 70),
		isWater = false,
		baseFertility = 0.75,
		moveCost = 1,
		passableByLand = true,
		surfaceHeight = 0,
	},
	{
		id = "Plains",
		displayName = "Plains",
		color = Color3.fromRGB(194, 172, 86),
		isWater = false,
		baseFertility = 0.6,
		moveCost = 1,
		passableByLand = true,
		surfaceHeight = 0,
	},
	{
		id = "Forest",
		displayName = "Forest",
		color = Color3.fromRGB(46, 110, 62),
		isWater = false,
		baseFertility = 0.45,
		moveCost = 2,
		passableByLand = true,
		surfaceHeight = 0.15,
		decoration = "Trees",
		decorationColor = Color3.fromRGB(28, 82, 44),
	},
	{
		id = "Desert",
		displayName = "Desert",
		color = Color3.fromRGB(218, 186, 112),
		isWater = false,
		baseFertility = 0.12,
		moveCost = 1,
		passableByLand = true,
		surfaceHeight = 0.05,
		decoration = "Dunes",
		decorationColor = Color3.fromRGB(196, 160, 92),
	},
	{
		id = "Tundra",
		displayName = "Tundra",
		color = Color3.fromRGB(154, 168, 172),
		isWater = false,
		baseFertility = 0.2,
		moveCost = 1,
		passableByLand = true,
		surfaceHeight = 0.1,
		decoration = "Snow",
		decorationColor = Color3.fromRGB(236, 240, 244),
	},
	{
		id = "Mountains",
		displayName = "Mountains",
		color = Color3.fromRGB(122, 106, 94),
		isWater = false,
		baseFertility = 0.05,
		moveCost = 3,
		passableByLand = true,
		surfaceHeight = 1.4,
		decoration = "Peaks",
		decorationColor = Color3.fromRGB(96, 84, 76),
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
