--!strict
-- MapConfig
-- Central configuration for RoCiv map generation and rendering (Phase 1).
-- Every tunable number for the strategic map lives here so balance changes
-- never require touching generator or renderer code.

local MapConfig = {}

-- Generation ---------------------------------------------------------------

MapConfig.DEFAULT_SEED = 12345
MapConfig.DEFAULT_TERRITORY_COUNT = 150
MapConfig.MIN_TERRITORY_COUNT = 20
MapConfig.MAX_TERRITORY_COUNT = 600

-- Map area in studs. Logical 2D coordinates (x, y) map to world (X, Z).
MapConfig.MAP_WIDTH = 1600
MapConfig.MAP_HEIGHT = 1000

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
MapConfig.BORDER_COLOR = Color3.fromRGB(28, 30, 36)

-- "Wedge"        two WedgeParts per polygon triangle. Default: works everywhere.
-- "EditableMesh" one runtime MeshPart per territory. Tested in Phase 1: the
--                client EditableMesh memory budget allowed only ~8 meshes, and
--                published games must opt in to "Allow Mesh / Image APIs".
--                Kept as an experimental option; remaining territories fall
--                back to wedges once the budget is exhausted.
-- "Auto"         same as EditableMesh with fallback.
MapConfig.RENDER_BACKEND = "Wedge"
MapConfig.TERRITORY_MATERIAL = Enum.Material.Plastic
-- Yield every N territories while rendering so the client never freezes.
MapConfig.RENDER_BATCH_SIZE = 25

-- Selection highlight
MapConfig.SELECTION_OUTLINE_COLOR = Color3.fromRGB(255, 220, 90)
MapConfig.SELECTION_FILL_COLOR = Color3.fromRGB(255, 255, 255)
MapConfig.SELECTION_FILL_TRANSPARENCY = 0.7

-- Client lighting overrides for a clear top-down strategy view (presentation
-- only; applied locally by ClientMain). Atmosphere haze and depth of field
-- wash the map out at strategic camera heights.
MapConfig.MAP_ATMOSPHERE_DENSITY = 0
MapConfig.DISABLE_POST_EFFECTS = true -- DepthOfField, Bloom, SunRays

-- Camera -------------------------------------------------------------------

MapConfig.CAMERA_MIN_HEIGHT = 80
MapConfig.CAMERA_MAX_HEIGHT = 1300
MapConfig.CAMERA_START_HEIGHT = 900
MapConfig.CAMERA_PITCH_DEGREES = 62 -- 90 would be straight down
MapConfig.CAMERA_PAN_SPEED = 1.1 -- multiplied by current height, studs/sec
MapConfig.CAMERA_ZOOM_STEP = 0.12 -- fraction of height per wheel notch

-- Development tools ----------------------------------------------------------

-- The regenerate panel / remote only work inside Roblox Studio. This flag
-- lets you turn them off in Studio too. They can never run in a live server
-- because MapService also checks RunService:IsStudio().
MapConfig.DEV_TOOLS_ENABLED = true

return MapConfig
