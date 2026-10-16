--!strict
-- TerrainTypes
-- Definitions for every terrain type used by the strategic map.
-- Gameplay systems should read terrain properties from here rather than
-- hard-coding values. `color` is the swatch shown in UI; the map itself is
-- drawn as voxel terrain by the client TerrainPainter.

export type TerrainDef = {
	id: string,
	displayName: string,
	color: Color3,
	isWater: boolean,
	baseFertility: number, -- 0..1
	moveCost: number, -- cost to enter a region of this terrain (Phase 3)
	passableByLand: boolean,
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
	},
	{
		-- Lake = inland fresh water (not connected to the ocean).
		id = "Lake",
		displayName = "Lake",
		color = Color3.fromRGB(64, 132, 170),
		isWater = true,
		baseFertility = 0.4,
		moveCost = 1,
		passableByLand = false,
	},
	{
		id = "Grassland",
		displayName = "Grassland",
		color = Color3.fromRGB(104, 166, 70),
		isWater = false,
		baseFertility = 0.75,
		moveCost = 1,
		passableByLand = true,
	},
	{
		id = "Plains",
		displayName = "Plains",
		color = Color3.fromRGB(194, 172, 86),
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
		color = Color3.fromRGB(218, 186, 112),
		isWater = false,
		baseFertility = 0.12,
		moveCost = 1,
		passableByLand = true,
	},
	{
		id = "Tundra",
		displayName = "Tundra",
		color = Color3.fromRGB(154, 168, 172),
		isWater = false,
		baseFertility = 0.2,
		moveCost = 1,
		passableByLand = true,
	},
	{
		id = "Mountains",
		displayName = "Mountains",
		color = Color3.fromRGB(122, 106, 94),
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
