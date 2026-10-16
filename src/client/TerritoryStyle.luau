--!strict
-- TerritoryStyle (client)
-- Decides how a territory looks from the client's map state. Pure
-- presentation: colours are derived from data and never read back as data.
-- Visual hierarchy (spec): terrain -> ownership border -> borders ->
-- temporary selection emphasis -> fog of war.
--   Visible     full-colour voxel terrain (TerrainPainter) + owner border
--   Explored    sepia terrain (Civilization VI style) + last-known owner
--   Unexplored  flat parchment slab; no terrain, height or features

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("RoCiv"):WaitForChild("Shared")
local MapConfig = require(Shared:WaitForChild("MapConfig"))
local TerrainTypes = require(Shared:WaitForChild("TerrainTypes"))

local TerritoryStyle = {}

-- Civilization registry (from the server; names/colours are public).
local civilizations: { [number]: any } = {}

function TerritoryStyle.setCivilizations(list: { any })
	table.clear(civilizations)
	for _, c in list do
		civilizations[c.civilizationId] = c
	end
end

function TerritoryStyle.getCivilization(id: number?): any?
	return if id then civilizations[id] else nil
end

-- Part colours are stored with 8 bits per channel; quantising here keeps the
-- computed style equal to what a part reports back (used by render checks).
local function quantise(c: Color3): Color3
	return Color3.fromRGB(math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

-- Deterministic small brightness offset per territory id (-1..1).
local function shadeOf(id: number): number
	local h = (id * 2654435761) % 4294967296
	return ((h % 1000) / 999) * 2 - 1
end

local function shaded(color: Color3, id: number): Color3
	local k = 1 + shadeOf(id) * MapConfig.TILE_SHADE_VARIATION
	return Color3.new(math.clamp(color.R * k, 0, 1), math.clamp(color.G * k, 0, 1), math.clamp(color.B * k, 0, 1))
end

function TerritoryStyle.ownerColor(ownerId: number?): Color3?
	if not ownerId then
		return nil
	end
	local civ = civilizations[ownerId]
	if civ then
		return civ.color
	end
	-- Unknown civilization id: fall back to the placeholder palette.
	local palette = MapConfig.OWNER_COLORS
	return palette[(ownerId - 1) % #palette + 1]
end

function TerritoryStyle.ownerName(ownerId: number?): string
	if not ownerId then
		return "Unowned"
	end
	local civ = civilizations[ownerId]
	return if civ then civ.displayName else ("Civilization " .. tostring(ownerId))
end

function TerritoryStyle.isKnown(record: any): boolean
	return record.state ~= "Unexplored" and record.terrainType ~= nil
end

local function fogFade(color: Color3, record: any): Color3
	if record.state == "Explored" then
		return color:Lerp(MapConfig.FOG_EXPLORED_SEPIA, MapConfig.FOG_EXPLORED_BLEND)
	end
	return color
end

-- `emphasis` (0..1) lightens the fill for hover / selection feedback.
function TerritoryStyle.fillColor(record: any, emphasis: number?): Color3
	if not TerritoryStyle.isKnown(record) then
		-- Parchment, very slightly varied per territory like aged paper.
		local fog = shaded(MapConfig.PARCHMENT_COLOR, record.id)
		if emphasis then
			fog = fog:Lerp(Color3.new(1, 1, 1), emphasis * 0.6)
		end
		return quantise(fog)
	end
	local def = TerrainTypes.get(record.terrainType)
	local color = shaded(if def then def.color else Color3.new(1, 0, 1), record.id)
	local owner = TerritoryStyle.ownerColor(record.ownerId)
	if owner then
		color = color:Lerp(owner, MapConfig.OWNER_FILL_TINT)
	end
	color = fogFade(color, record)
	if emphasis then
		color = color:Lerp(Color3.new(1, 1, 1), emphasis)
	end
	return quantise(color)
end

-- Owner border colour, or nil when no border should be drawn. Explored
-- (last-known) borders are drawn in a sepia-faded version of the colour.
function TerritoryStyle.ownerBorderColor(record: any): Color3?
	if record.state == "Unexplored" then
		return nil
	end
	local owner = TerritoryStyle.ownerColor(record.ownerId)
	if owner and record.state == "Explored" then
		owner = owner:Lerp(MapConfig.FOG_EXPLORED_SEPIA, MapConfig.FOG_EXPLORED_BLEND)
	end
	return if owner then quantise(owner) else nil
end

return TerritoryStyle
