--!strict
-- MapQuery
-- Fast "which territory contains this point?" lookups using a uniform grid
-- over territory bounding boxes plus exact point-in-convex-polygon tests.
-- Works on any list of records that have `id` and `polygon` fields, so the
-- server (full data) and the client (payload) share it.
--
-- Selection uses this instead of trusting which Part a ray hit: the click
-- position is converted to map coordinates and resolved against the data.

local Geometry = require(script.Parent.Geometry)

type Record = { id: number, polygon: { Vector2 } }

local MapQuery = {}
MapQuery.__index = MapQuery

export type MapQuery = typeof(setmetatable(
	{} :: {
		cellSize: number,
		cols: number,
		rows: number,
		grid: { [number]: { Record } },
		width: number,
		height: number,
	},
	MapQuery
))

function MapQuery.new(records: { Record }, width: number, height: number): MapQuery
	local n = math.max(#records, 1)
	local cellSize = math.sqrt(width * height / n)
	local cols = math.max(1, math.ceil(width / cellSize))
	local rows = math.max(1, math.ceil(height / cellSize))
	local grid: { [number]: { Record } } = {}
	for _, r in records do
		local lo, hi = Geometry.bounds(r.polygon)
		local c0 = math.clamp(math.floor(lo.X / cellSize), 0, cols - 1)
		local c1 = math.clamp(math.floor(hi.X / cellSize), 0, cols - 1)
		local r0 = math.clamp(math.floor(lo.Y / cellSize), 0, rows - 1)
		local r1 = math.clamp(math.floor(hi.Y / cellSize), 0, rows - 1)
		for cy = r0, r1 do
			for cx = c0, c1 do
				local key = cy * cols + cx
				local bucket = grid[key]
				if not bucket then
					bucket = {}
					grid[key] = bucket
				end
				table.insert(bucket, r)
			end
		end
	end
	return setmetatable({
		cellSize = cellSize,
		cols = cols,
		rows = rows,
		grid = grid,
		width = width,
		height = height,
	}, MapQuery)
end

-- Returns the id of the territory containing `p` (map coordinates), or nil.
function MapQuery.territoryAt(self: MapQuery, p: Vector2): number?
	if p.X < 0 or p.Y < 0 or p.X > self.width or p.Y > self.height then
		return nil
	end
	local cx = math.clamp(math.floor(p.X / self.cellSize), 0, self.cols - 1)
	local cy = math.clamp(math.floor(p.Y / self.cellSize), 0, self.rows - 1)
	local bucket = self.grid[cy * self.cols + cx]
	if not bucket then
		return nil
	end
	for _, r in bucket do
		if Geometry.pointInConvex(r.polygon, p, 0.01) then
			return r.id
		end
	end
	return nil
end

return MapQuery
