--!strict
-- MapConfig
-- Central configuration for RoCiv's strategic map: generation, terrain,
-- rendering, fog of war, camera and development tools. Every tunable lives
-- here so balance and presentation changes never require touching the
-- generator, renderer or camera code.

local MapConfig = {}

-- Generation ---------------------------------------------------------------

MapConfig.DEFAULT_SEED = 12345
MapConfig.DEFAULT_TERRITORY_COUNT = 260
MapConfig.MIN_TERRITORY_COUNT = 20
MapConfig.MAX_TERRITORY_COUNT = 600

-- World size. The map grows with the territory count so territories keep a
-- consistent size: area = count * TERRITORY_AREA, shaped by MAP_ASPECT
-- (width / height). Logical 2D coordinates (x, y) map to world (X, Z).
-- Set FIXED_MAP_WIDTH / FIXED_MAP_HEIGHT to numbers to force a size instead.
MapConfig.TERRITORY_AREA = 16000 -- studs^2 per territory (~125 studs across)
MapConfig.MAP_ASPECT = 1.6
MapConfig.FIXED_MAP_WIDTH = nil :: number?
MapConfig.FIXED_MAP_HEIGHT = nil :: number?

function MapConfig.mapSizeFor(territoryCount: number): (number, number)
	if MapConfig.FIXED_MAP_WIDTH and MapConfig.FIXED_MAP_HEIGHT then
		return MapConfig.FIXED_MAP_WIDTH, MapConfig.FIXED_MAP_HEIGHT
	end
	local area = territoryCount * MapConfig.TERRITORY_AREA
	local height = math.sqrt(area / MapConfig.MAP_ASPECT)
	local width = height * MapConfig.MAP_ASPECT
	-- Round to whole studs so sizes are readable in logs.
	return math.floor(width + 0.5), math.floor(height + 0.5)
end

-- Lloyd relaxation passes. More passes = more evenly sized, rounder cells.
MapConfig.LLOYD_ITERATIONS = 2

-- Two territories are neighbours only if their shared border is at least
-- this long (studs). Filters out "corner touches" that look like a point.
MapConfig.MIN_SHARED_EDGE_LENGTH = 4

-- Terrain ------------------------------------------------------------------

-- Target share of territories that are land (before lake filling).
MapConfig.LAND_FRACTION = 0.55
-- Share of LAND territories that become mountains (highest elevations).
MapConfig.MOUNTAIN_FRACTION = 0.08
-- Territories touching the map edge are forced to water so the world is
-- ringed by ocean.
MapConfig.FORCE_EDGE_OCEAN = true

-- Elevation noise
MapConfig.ELEVATION_FREQUENCY = 2.2
MapConfig.ELEVATION_OCTAVES = 4
-- Pushes elevation down toward the map edges (0 = off).
MapConfig.EDGE_FALLOFF_START = 0.55 -- normalized distance from centre
MapConfig.EDGE_FALLOFF_STRENGTH = 0.9

-- Moisture noise (drives desert / plains / grassland / forest)
MapConfig.MOISTURE_FREQUENCY = 2.8
MapConfig.MOISTURE_OCTAVES = 3
MapConfig.MOISTURE_WATER_BONUS = 0.12 -- added to land next to water

-- Latitude 0 = equator (vertical centre), 1 = pole (top/bottom edge).
MapConfig.TUNDRA_LATITUDE = 0.62
MapConfig.TUNDRA_LATITUDE_JITTER = 0.06
MapConfig.DESERT_MAX_LATITUDE = 0.55

MapConfig.DESERT_MOISTURE = 0.30 -- below => desert
MapConfig.GRASSLAND_MOISTURE = 0.50 -- above => grassland
MapConfig.FOREST_MOISTURE = 0.66 -- above => forest

-- Rendering ----------------------------------------------------------------

MapConfig.MAP_ORIGIN_Y = 0 -- world Y of the top surface of the map
MapConfig.TERRITORY_THICKNESS = 2
-- Each territory is drawn inset by this many studs; the dark base plate
-- shows through the gap and forms the border lines (2 * inset wide).
MapConfig.BORDER_INSET = 1.25
MapConfig.BORDER_COLOR = Color3.fromRGB(24, 26, 32)

-- Decorative world around the playable map (never gameplay data, never
-- selectable). The frame marks the playable edge; the backdrop is open sea
-- that fills the rest of the view so there is no grey void.
MapConfig.MAP_FRAME_WIDTH = 10
MapConfig.MAP_FRAME_COLOR = Color3.fromRGB(14, 18, 26)
MapConfig.BACKDROP_COLOR = Color3.fromRGB(22, 52, 92)
MapConfig.BACKDROP_SIZE = 60000 -- studs, visual size (one scaled part)

-- "Wedge"        two WedgeParts per polygon triangle. Default: works everywhere.
-- "EditableMesh" one runtime MeshPart per territory. Tested in Phase 1: the
--                client EditableMesh memory budget allowed only ~8 meshes, and
--                published games must opt in to "Allow Mesh / Image APIs".
--                Kept as an experimental option; remaining territories fall
--                back to wedges once the budget is exhausted.
-- "Auto"         same as EditableMesh with fallback.
MapConfig.RENDER_BACKEND = "Wedge"
MapConfig.TERRITORY_MATERIAL = Enum.Material.Plastic -- SmoothPlastic showed sun glare in testing
-- Yield every N territories while rendering so the client never freezes.
MapConfig.RENDER_BATCH_SIZE = 25

-- Selection / hover outlines (drawn from the territory polygon)
MapConfig.SELECTION_OUTLINE_COLOR = Color3.fromRGB(255, 214, 80)
MapConfig.SELECTION_OUTLINE_WIDTH = 3
MapConfig.HOVER_OUTLINE_COLOR = Color3.fromRGB(245, 245, 235)
MapConfig.HOVER_OUTLINE_WIDTH = 1.2
MapConfig.OWNER_OUTLINE_WIDTH = 1.6
-- How strongly an owner's colour tints a territory's fill (0..1).
MapConfig.OWNER_FILL_TINT = 0.28

-- Placeholder owner palette (Phase 2 ownership testing). Real civilizations
-- arrive in Phase 6; until then owners are numbers 1..N.
MapConfig.OWNER_COLORS = {
	Color3.fromRGB(220, 60, 60),
	Color3.fromRGB(60, 120, 230),
	Color3.fromRGB(240, 170, 40),
	Color3.fromRGB(160, 80, 210),
	Color3.fromRGB(40, 190, 170),
	Color3.fromRGB(235, 110, 180),
	Color3.fromRGB(130, 200, 60),
	Color3.fromRGB(240, 240, 240),
}

-- Client lighting overrides for a clear top-down strategy view (presentation
-- only; applied locally by ClientMain). Atmosphere haze, depth of field and
-- bloom wash the map out at strategic camera heights.
MapConfig.MAP_ATMOSPHERE_DENSITY = 0
MapConfig.DISABLE_POST_EFFECTS = true -- DepthOfField, Bloom, SunRays
MapConfig.LIGHTING_CLOCK_TIME = 12 -- sun overhead = even lighting
MapConfig.LIGHTING_BRIGHTNESS = 1.6
MapConfig.LIGHTING_EXPOSURE = 0
MapConfig.LIGHTING_ENV_SPECULAR = 0
MapConfig.LIGHTING_SATURATION = 0.12 -- ColorCorrection saturation boost

-- Tile design (presentation only) --------------------------------------------

-- Each known territory's colour is shaded slightly (deterministic per id) so
-- neighbouring territories of the same terrain stay distinguishable.
MapConfig.TILE_SHADE_VARIATION = 0.05
-- Small terrain decorations (trees, peaks, snow, dunes) on known territories.
MapConfig.TILE_DECORATIONS = true
MapConfig.DECORATION_DENSITY = 1 / 1700 -- decorations per stud^2 of territory
-- Upper limit per territory for each decoration kind (keeps part counts low).
MapConfig.DECORATION_CAPS = { Trees = 12, Peaks = 5, Snow = 5, Dunes = 5, Fields = 4, Meadow = 5, Waves = 3 }

-- Selected territory: its direct neighbours get a temporary outline.
MapConfig.NEIGHBOR_OUTLINE_COLOR = Color3.fromRGB(120, 220, 255)
MapConfig.NEIGHBOR_OUTLINE_WIDTH = 2.2

-- Roblox chat window: small, top-right (map stays the focus).
MapConfig.CHAT_WIDTH_SCALE = 0.65
MapConfig.CHAT_HEIGHT_SCALE = 0.5
MapConfig.CHAT_TEXT_SIZE = 13

-- Movement regions (Phase 3) ---------------------------------------------------

-- Each territory is split into ~area / REGION_TARGET_AREA movement regions.
MapConfig.REGION_TARGET_AREA = 3600
MapConfig.REGION_MAX_PER_TERRITORY = 8
MapConfig.REGION_LLOYD_ITERATIONS = 2
MapConfig.REGION_MIN_SHARED_EDGE = 2 -- studs; shorter contacts are not passages
-- Pathfinding
MapConfig.UNKNOWN_REGION_COST = 1 -- unexplored regions: assumed passable at this cost
MapConfig.ROAD_COST_MULTIPLIER = 0.5 -- placeholder until roads exist
MapConfig.ROUTE_REQUESTS_PER_SECOND = 10 -- per player, server-enforced
MapConfig.MAX_RANGE_BUDGET = 30

-- Fog of war -----------------------------------------------------------------

MapConfig.FOG_OF_WAR_ENABLED = true
-- Placeholder vision until cities and units exist (Phase 6+): every player
-- starts with one vision source on the land territory nearest the map
-- centre. Range is in territories (neighbour hops).
MapConfig.START_VISION_RANGE = 3
-- Fog presentation (client only; never authoritative)
MapConfig.FOG_UNEXPLORED_COLOR = Color3.fromRGB(34, 36, 44) -- close to the border colour so unexplored borders fade
MapConfig.FOG_EXPLORED_GREY = Color3.fromRGB(70, 72, 80)
MapConfig.FOG_EXPLORED_BLEND = 0.55 -- 0 = full colour, 1 = grey

-- Camera -------------------------------------------------------------------

MapConfig.CAMERA_PITCH_DEGREES = 66 -- 90 would be straight down
MapConfig.CAMERA_FIELD_OF_VIEW = 50 -- vertical, degrees
MapConfig.CAMERA_MIN_HEIGHT = 60
-- Margins kept free around the fitted map (fraction of the viewport) so
-- edge UI does not cover it.
MapConfig.CAMERA_FIT_MARGIN_X = 0.02
MapConfig.CAMERA_FIT_MARGIN_Y = 0.04
-- How far beyond "whole map fits" the player may zoom out.
MapConfig.CAMERA_MAX_ZOOM_OUT = 1.2
MapConfig.CAMERA_PAN_SPEED = 1.1 -- multiplied by current height, studs/sec
MapConfig.CAMERA_ZOOM_STEP = 0.12 -- fraction of height per wheel notch
MapConfig.CAMERA_ZOOM_SMOOTHING = 14 -- higher = snappier

-- Development tools ----------------------------------------------------------

-- The dev panel and dev remotes only work inside Roblox Studio. This flag
-- lets you turn them off in Studio too. They can never run in a live server
-- because the server also checks RunService:IsStudio().
MapConfig.DEV_TOOLS_ENABLED = true

return MapConfig
