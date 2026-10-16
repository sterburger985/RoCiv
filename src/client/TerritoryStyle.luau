--!strict
-- TerritoryStyle (client)
-- Decides how a territory looks from the client's map state. Pure
-- presentation: colours are derived from data and never read back as data.
--   Visible     terrain colour (+ owner tint)
--   Explored    terrain colour faded toward grey (last known state)
--   Unexplored  dark fog colour, close to the border colour so the shapes of
--               undiscovered territories are barely visible

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("RoCiv"):WaitForChild("Shared")
local MapConfig = require(Shared:WaitForChild("MapConfig"))
local TerrainTypes = require(Shared:WaitForChild("TerrainTypes"))

local TerritoryStyle = {}

-- Part colours are stored with 8 bits per channel; quantising here keeps the
-- computed style equal to what a part reports back (used by render checks).
local function quantise(c: Color3): Color3
	return Color3.fromRGB(math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

function TerritoryStyle.ownerColor(ownerId: number?): Color3?
	if not ownerId then
		return nil
	end
	local palette = MapConfig.OWNER_COLORS
	return palette[(ownerId - 1) % #palette + 1]
end

function TerritoryStyle.ownerName(ownerId: number?): string
	if not ownerId then
		return "Unowned"
	end
	return "Civilization " .. tostring(ownerId)
end

-- `emphasis` (0..1) lightens the fill for hover / selection feedback.
function TerritoryStyle.fillColor(record: any, emphasis: number?): Color3
	if record.state == "Unexplored" or not record.terrainType then
		local fog = MapConfig.FOG_UNEXPLORED_COLOR
		return if emphasis then quantise(fog:Lerp(Color3.new(1, 1, 1), emphasis * 0.5)) else fog
	end
	local def = TerrainTypes.get(record.terrainType)
	local color = if def then def.color else Color3.new(1, 0, 1)
	local owner = TerritoryStyle.ownerColor(record.ownerId)
	if owner then
		color = color:Lerp(owner, MapConfig.OWNER_FILL_TINT)
	end
	if record.state == "Explored" then
		color = color:Lerp(MapConfig.FOG_EXPLORED_GREY, MapConfig.FOG_EXPLORED_BLEND)
	end
	if emphasis then
		color = color:Lerp(Color3.new(1, 1, 1), emphasis)
	end
	return quantise(color)
end

-- Owner border colour, or nil when no border should be drawn.
function TerritoryStyle.ownerBorderColor(record: any): Color3?
	if record.state == "Unexplored" then
		return nil
	end
	local owner = TerritoryStyle.ownerColor(record.ownerId)
	if owner and record.state == "Explored" then
		owner = owner:Lerp(MapConfig.FOG_EXPLORED_GREY, MapConfig.FOG_EXPLORED_BLEND)
	end
	return if owner then quantise(owner) else nil
end

return TerritoryStyle
