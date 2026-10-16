--!strict
-- ClientMapState (client)
-- The client's copy of what the server has told this player about the map.
-- It is not authoritative: it only mirrors the server's per-player view.
--
-- Each record: id, polygon, centroid, neighbors, state
-- ("Visible" | "Explored" | "Unexplored"), and - only when explored -
-- terrainType, elevation, fertility, resources, ownerId.
--
-- Deltas carry the map version and a per-player sequence number; stale or
-- out-of-order deltas are ignored, and deltas that arrive while a new map is
-- loading are buffered and applied afterwards.

local ClientMapState = {}
ClientMapState.__index = ClientMapState

export type ClientMapState = typeof(setmetatable(
	{} :: {
		version: number,
		seq: number,
		width: number,
		height: number,
		records: { [number]: any },
		list: { any },
		pending: { any },
		listeners: { (ids: { number }) -> () },
		civilizations: { any },
		yourCivilizationId: number?,
		civListeners: { () -> () },
	},
	ClientMapState
))

local STATIC_FIELDS = { "terrainType", "elevation", "fertility", "resources", "cityId" }

function ClientMapState.new(): ClientMapState
	return setmetatable({
		version = 0,
		seq = 0,
		width = 0,
		height = 0,
		records = {},
		list = {},
		pending = {},
		listeners = {},
		civilizations = {},
		yourCivilizationId = nil,
		civListeners = {},
	}, ClientMapState)
end

function ClientMapState.onChanged(self: ClientMapState, fn: (ids: { number }) -> ())
	table.insert(self.listeners, fn)
end

function ClientMapState.onCivilizationsChanged(self: ClientMapState, fn: () -> ())
	table.insert(self.civListeners, fn)
end

-- Public civilization list (id, name, colour) + which one this player controls.
function ClientMapState.setCivilizations(self: ClientMapState, list: { any }?, yourId: number?)
	self.civilizations = list or {}
	self.yourCivilizationId = yourId
	for _, fn in self.civListeners do
		fn()
	end
end

-- Replaces everything with a fresh payload (new map or reconnect).
function ClientMapState.load(self: ClientMapState, payload: any)
	self.version = payload.version
	self.seq = payload.seq
	self.width = payload.width
	self.height = payload.height
	table.clear(self.records)
	self.list = payload.territories
	for _, r in payload.territories do
		self.records[r.id] = r
	end
	self.civilizations = payload.civilizations or {}
	self.yourCivilizationId = payload.yourCivilizationId
	-- Apply buffered deltas that belong to this map and are newer.
	local buffered = self.pending
	self.pending = {}
	table.sort(buffered, function(a, b)
		return a.seq < b.seq
	end)
	for _, d in buffered do
		self:applyDelta(d)
	end
end

-- Returns the ids that changed (empty if the delta was ignored).
function ClientMapState.applyDelta(self: ClientMapState, delta: any): { number }
	if delta.version ~= self.version then
		if delta.version > self.version then
			-- A newer map is on its way; keep this until it has loaded.
			table.insert(self.pending, delta)
		end
		return {}
	end
	if delta.seq <= self.seq then
		return {} -- already reflected in what we have
	end
	self.seq = delta.seq
	local changed = {}
	for _, u in delta.updates do
		local r = self.records[u.id]
		if r then
			r.state = u.state
			if u.state == "Unexplored" then
				for _, f in STATIC_FIELDS do
					r[f] = nil
				end
				r.ownerId = nil
			else
				for _, f in STATIC_FIELDS do
					r[f] = u[f]
				end
				r.ownerId = u.ownerId
			end
			table.insert(changed, u.id)
		end
	end
	if #changed > 0 then
		for _, fn in self.listeners do
			fn(changed)
		end
	end
	return changed
end

function ClientMapState.get(self: ClientMapState, id: number): any?
	return self.records[id]
end

function ClientMapState.counts(self: ClientMapState): { [string]: number }
	local c = { Visible = 0, Explored = 0, Unexplored = 0 }
	for _, r in self.list do
		c[r.state] = (c[r.state] or 0) + 1
	end
	return c
end

return ClientMapState
