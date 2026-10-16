--!strict
-- Geometry
-- 2D polygon helpers used by the map generator, validator, renderer and
-- selection. Polygons are arrays of Vector2 in counter-clockwise order
-- (standard math orientation, x right / y up). All territory polygons are
-- convex because they are Voronoi cells clipped to a rectangle.

local Geometry = {}

local EPS = 1e-7

export type Polygon = { Vector2 }

local function cross(a: Vector2, b: Vector2): number
	return a.X * b.Y - a.Y * b.X
end
Geometry.cross = cross

-- Signed area (positive for counter-clockwise polygons).
function Geometry.signedArea(poly: Polygon): number
	local sum = 0
	local n = #poly
	for i = 1, n do
		local a = poly[i]
		local b = poly[i % n + 1]
		sum += a.X * b.Y - b.X * a.Y
	end
	return sum * 0.5
end

function Geometry.centroid(poly: Polygon): Vector2
	local n = #poly
	local a2 = 0
	local cx, cy = 0, 0
	for i = 1, n do
		local a = poly[i]
		local b = poly[i % n + 1]
		local c = a.X * b.Y - b.X * a.Y
		a2 += c
		cx += (a.X + b.X) * c
		cy += (a.Y + b.Y) * c
	end
	if math.abs(a2) < EPS then
		-- Degenerate: average of vertices
		local s = Vector2.zero
		for _, p in poly do
			s += p
		end
		return s / math.max(n, 1)
	end
	return Vector2.new(cx / (3 * a2), cy / (3 * a2))
end

function Geometry.bounds(poly: Polygon): (Vector2, Vector2)
	local minX, minY = math.huge, math.huge
	local maxX, maxY = -math.huge, -math.huge
	for _, p in poly do
		if p.X < minX then
			minX = p.X
		end
		if p.Y < minY then
			minY = p.Y
		end
		if p.X > maxX then
			maxX = p.X
		end
		if p.Y > maxY then
			maxY = p.Y
		end
	end
	return Vector2.new(minX, minY), Vector2.new(maxX, maxY)
end

-- Point in convex CCW polygon (inclusive of the border within `tolerance`).
function Geometry.pointInConvex(poly: Polygon, p: Vector2, tolerance: number?): boolean
	local tol = tolerance or 1e-6
	local n = #poly
	for i = 1, n do
		local a = poly[i]
		local b = poly[i % n + 1]
		local e = b - a
		local len = e.Magnitude
		if len > EPS then
			-- signed distance of p to the left of edge a->b
			if cross(e, p - a) / len < -tol then
				return false
			end
		end
	end
	return true
end

function Geometry.isConvexCCW(poly: Polygon): boolean
	local n = #poly
	if n < 3 then
		return false
	end
	for i = 1, n do
		local a = poly[i]
		local b = poly[i % n + 1]
		local c = poly[(i + 1) % n + 1]
		if cross(b - a, c - b) < -1e-6 then
			return false
		end
	end
	return Geometry.signedArea(poly) > 0
end

-- Clip a convex polygon against the half plane (p - m) . n <= 0.
-- `tags[i]` labels edge poly[i] -> poly[i+1]; the new edge created along
-- the clip line receives `newTag`. Returns the clipped polygon and tags.
function Geometry.clipHalfPlane(
	poly: Polygon,
	tags: { number },
	m: Vector2,
	n: Vector2,
	newTag: number
): (Polygon, { number })
	local outV: Polygon = {}
	local outT: { number } = {}
	local count = #poly
	for i = 1, count do
		local a = poly[i]
		local b = poly[i % count + 1]
		local tag = tags[i]
		local da = (a - m):Dot(n)
		local db = (b - m):Dot(n)
		local aIn = da <= 0
		local bIn = db <= 0
		if aIn then
			table.insert(outV, a)
			table.insert(outT, tag)
			if not bIn then
				local t = da / (da - db)
				table.insert(outV, a + (b - a) * t)
				table.insert(outT, newTag)
			end
		elseif bIn then
			local t = da / (da - db)
			table.insert(outV, a + (b - a) * t)
			table.insert(outT, tag)
		end
	end
	return Geometry.removeDuplicateVertices(outV, outT)
end

-- Removes consecutive (near) duplicate vertices which produce zero-length
-- edges. Keeps edge tags consistent.
function Geometry.removeDuplicateVertices(poly: Polygon, tags: { number }): (Polygon, { number })
	local changed = true
	while changed and #poly > 0 do
		changed = false
		local n = #poly
		for i = 1, n do
			local a = poly[i]
			local b = poly[i % n + 1]
			if (b - a).Magnitude < 1e-6 then
				-- Edge i is zero length: drop vertex i and its tag. The previous
				-- edge now ends at poly[i+1] which is at the same location.
				table.remove(poly, i)
				table.remove(tags, i)
				changed = true
				break
			end
		end
	end
	return poly, tags
end

-- Intersection of two infinite lines p1 + t*d1 and p2 + s*d2.
local function lineIntersect(p1: Vector2, d1: Vector2, p2: Vector2, d2: Vector2): Vector2?
	local denom = cross(d1, d2)
	if math.abs(denom) < 1e-9 then
		return nil
	end
	local t = cross(p2 - p1, d2) / denom
	return p1 + d1 * t
end

-- Shrinks a convex CCW polygon so that every edge moves inward by `inset`.
-- Edges that would collapse are removed. Falls back to scaling toward the
-- centroid for tiny polygons. Always returns a convex CCW polygon.
function Geometry.insetConvex(poly: Polygon, inset: number): Polygon
	if inset <= 0 then
		return table.clone(poly)
	end
	-- Represent the polygon as a list of directed lines.
	local linesP: { Vector2 } = {}
	local linesD: { Vector2 } = {}
	local n = #poly
	for i = 1, n do
		local a = poly[i]
		local b = poly[i % n + 1]
		local d = b - a
		if d.Magnitude > EPS then
			local u = d.Unit
			local inward = Vector2.new(-u.Y, u.X) -- left normal for CCW
			table.insert(linesP, a + inward * inset)
			table.insert(linesD, u)
		end
	end

	for _ = 1, n do
		local m = #linesP
		if m < 3 then
			break
		end
		local verts: Polygon = {}
		local ok = true
		for j = 1, m do
			local prev = (j - 2) % m + 1
			local v = lineIntersect(linesP[prev], linesD[prev], linesP[j], linesD[j])
			if not v then
				ok = false
				break
			end
			verts[j] = v
		end
		if ok then
			-- Find an edge whose direction reversed (it collapsed).
			local reversed = nil
			for j = 1, m do
				local e = verts[j % m + 1] - verts[j]
				if e:Dot(linesD[j]) < 0 then
					reversed = j
					break
				end
			end
			if not reversed then
				if Geometry.signedArea(verts) > EPS then
					return verts
				end
				break
			end
			table.remove(linesP, reversed)
			table.remove(linesD, reversed)
		else
			break
		end
	end

	-- Fallback: uniform scale toward the centroid.
	local c = Geometry.centroid(poly)
	local minR = math.huge
	for i = 1, n do
		local a = poly[i]
		local b = poly[i % n + 1]
		local e = b - a
		if e.Magnitude > EPS then
			local dist = math.abs(cross(e.Unit, c - a))
			minR = math.min(minR, dist)
		end
	end
	local k = if minR > inset * 2 then (minR - inset) / minR else 0.5
	local out: Polygon = {}
	for i, p in poly do
		out[i] = c + (p - c) * k
	end
	return out
end

return Geometry
