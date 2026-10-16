--!strict
-- Pathfinding (server)
-- A* routes and Dijkstra movement ranges over the MovementGraph.
--
-- Movement domains:
--   "Land"   may enter land regions only (embarking comes in a later phase)
--   "Naval"  may enter water regions only
-- Cost of a step = cost of ENTERING the destination region:
--   terrain moveCost, halved on regions with a road, +RIVER_MOVE_COST on
--   river territories without a road (placeholder road data).
--
-- Fog of war: callers pass a `knowledge(regionId)` function. Regions the
-- player has not explored return nil and are treated as passable at
-- UNKNOWN_COST, so a route never reveals hidden terrain. Server-side callers
-- (AI, validation) can omit `knowledge` to use the true terrain.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("RoCiv"):WaitForChild("Shared")
local MapConfig = require(Shared:WaitForChild("MapConfig"))

export type Domain = "Land" | "Naval"
export type Knowledge = (regionId: number) -> { isWater: boolean, moveCost: number, hasRoad: boolean }?
export type Options = { domain: Domain?, knowledge: Knowledge?, maxExpansions: number? }
export type PathResult = {
	path: { number },
	cost: number,
	stepCosts: { number },
	expanded: number,
}

local Pathfinding = {}

-- Minimal binary heap keyed on `f`.
local function heapPush(heap: { any }, node: any)
	table.insert(heap, node)
	local i = #heap
	while i > 1 do
		local parent = i // 2
		if heap[parent].f <= heap[i].f then
			break
		end
		heap[parent], heap[i] = heap[i], heap[parent]
		i = parent
	end
end

local function heapPop(heap: { any }): any
	local top = heap[1]
	local last = table.remove(heap)
	if #heap > 0 then
		heap[1] = last
		local i = 1
		local n = #heap
		while true do
			local l, r = i * 2, i * 2 + 1
			local smallest = i
			if l <= n and heap[l].f < heap[smallest].f then
				smallest = l
			end
			if r <= n and heap[r].f < heap[smallest].f then
				smallest = r
			end
			if smallest == i then
				break
			end
			heap[i], heap[smallest] = heap[smallest], heap[i]
			i = smallest
		end
	end
	return top
end

-- Cost to enter `rid` for this domain, or nil if impassable.
function Pathfinding.enterCost(graph: any, rid: number, opts: Options?): number?
	local o = opts or {}
	local domain = o.domain or "Land"
	local region = graph.regions[rid]
	if not region then
		return nil
	end
	local info
	if o.knowledge then
		info = o.knowledge(rid)
		if info == nil then
			return MapConfig.UNKNOWN_REGION_COST
		end
	else
		info = region
	end
	if domain == "Land" and info.isWater then
		return nil
	elseif domain == "Naval" and not info.isWater then
		return nil
	end
	local cost = info.moveCost
	if info.hasRoad then
		cost *= MapConfig.ROAD_COST_MULTIPLIER
	elseif info.hasRiver then
		-- Fording a river is slow; a road (bridge) removes the penalty.
		cost += MapConfig.RIVER_MOVE_COST
	end
	return cost
end

-- Lowest possible cost of any single step (keeps the A* heuristic admissible).
local function minStepCost(): number
	return math.min(1, MapConfig.UNKNOWN_REGION_COST) * MapConfig.ROAD_COST_MULTIPLIER
end

function Pathfinding.findPath(graph: any, startId: number, goalId: number, opts: Options?): (PathResult?, string?)
	local o = opts or {}
	local regions = graph.regions
	if not regions[startId] or not regions[goalId] then
		return nil, "unknown region"
	end
	if startId == goalId then
		return { path = { startId }, cost = 0, stepCosts = {}, expanded = 0 }, nil
	end
	if Pathfinding.enterCost(graph, goalId, o) == nil then
		return nil, "destination impassable for " .. (o.domain or "Land")
	end
	local goal = regions[goalId].centroid
	local perStud = minStepCost() / math.max(graph.maxStep, 1)
	local function h(rid: number): number
		return (regions[rid].centroid - goal).Magnitude * perStud
	end

	local g: { [number]: number } = { [startId] = 0 }
	local cameFrom: { [number]: number } = {}
	local closed: { [number]: boolean } = {}
	local heap = {}
	heapPush(heap, { id = startId, f = h(startId) })
	local expanded = 0
	local limit = o.maxExpansions or 100000

	while #heap > 0 do
		local node = heapPop(heap)
		local cur = node.id
		if not closed[cur] then
			closed[cur] = true
			expanded += 1
			if cur == goalId then
				local path = { goalId }
				while path[1] ~= startId do
					table.insert(path, 1, cameFrom[path[1]])
				end
				local steps = {}
				for i = 2, #path do
					steps[i - 1] = Pathfinding.enterCost(graph, path[i], o) :: number
				end
				return { path = path, cost = g[goalId], stepCosts = steps, expanded = expanded }, nil
			end
			if expanded > limit then
				return nil, "search limit reached"
			end
			for _, nb in regions[cur].neighbors do
				if not closed[nb] then
					local c = Pathfinding.enterCost(graph, nb, o)
					if c then
						local ng = g[cur] + c
						if g[nb] == nil or ng < g[nb] then
							g[nb] = ng
							cameFrom[nb] = cur
							heapPush(heap, { id = nb, f = ng + h(nb) })
						end
					end
				end
			end
		end
	end
	return nil, "no route"
end

-- All regions reachable from `startId` within `budget` movement points.
-- Returns regionId -> cost.
function Pathfinding.reachable(graph: any, startId: number, budget: number, opts: Options?): { [number]: number }
	local o = opts or {}
	local regions = graph.regions
	local dist: { [number]: number } = {}
	if not regions[startId] then
		return dist
	end
	dist[startId] = 0
	local done: { [number]: boolean } = {}
	local heap = {}
	heapPush(heap, { id = startId, f = 0 })
	while #heap > 0 do
		local node = heapPop(heap)
		local cur = node.id
		if not done[cur] then
			done[cur] = true
			for _, nb in regions[cur].neighbors do
				local c = Pathfinding.enterCost(graph, nb, o)
				if c then
					local nd = dist[cur] + c
					if nd <= budget + 1e-9 and (dist[nb] == nil or nd < dist[nb]) then
						dist[nb] = nd
						heapPush(heap, { id = nb, f = nd })
					end
				end
			end
		end
	end
	return dist
end

-- Checks that a returned path is legal and its cost is correct.
function Pathfinding.validatePath(graph: any, result: PathResult, opts: Options?): (boolean, string?)
	local path = result.path
	local total = 0
	for i = 2, #path do
		local a, b = graph.regions[path[i - 1]], graph.regions[path[i]]
		if not a or not b then
			return false, "unknown region in path"
		end
		if not table.find(a.neighbors, b.id) then
			return false, string.format("step %d -> %d is not adjacent", a.id, b.id)
		end
		local c = Pathfinding.enterCost(graph, b.id, opts)
		if not c then
			return false, string.format("region %d impassable for this domain", b.id)
		end
		total += c
	end
	if math.abs(total - result.cost) > 1e-6 then
		return false, string.format("cost mismatch %.3f vs %.3f", total, result.cost)
	end
	return true, nil
end

return Pathfinding
