--!strict
-- SelectionController (client)
-- Left-click a territory to select it. Deselect by left-clicking outside the
-- map, right-clicking without dragging (right-drag pans the camera), or the
-- panel's close button. Escape is not used: Roblox reserves it for its menu.
--
-- The click is projected onto the map plane, converted to map coordinates
-- and resolved with MapQuery against the territory *data*. The rendered
-- instance is only used to draw the highlight.

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("RoCiv"):WaitForChild("Shared")
local MapConfig = require(Shared:WaitForChild("MapConfig"))

local SelectionController = {}
SelectionController.__index = SelectionController

export type SelectionController = typeof(setmetatable(
	{} :: {
		renderer: any,
		query: any,
		byId: { [number]: any },
		selectedId: number?,
		highlight: Highlight,
		listeners: { (record: any?) -> () },
		connections: { RBXScriptConnection },
		pressPos: Vector2?,
		rightPressPos: Vector2?,
	},
	SelectionController
))

function SelectionController.new(renderer: any): SelectionController
	-- One persistent Highlight, re-targeted on every selection (never duplicated).
	local fxFolder = workspace:FindFirstChild("RoCivClientFX")
	if not fxFolder then
		fxFolder = Instance.new("Folder")
		fxFolder.Name = "RoCivClientFX"
		fxFolder.Parent = workspace
	end
	local existing = fxFolder:FindFirstChild("SelectionHighlight")
	if existing then
		existing:Destroy()
	end
	local highlight = Instance.new("Highlight")
	highlight.Name = "SelectionHighlight"
	highlight.FillColor = MapConfig.SELECTION_FILL_COLOR
	highlight.FillTransparency = MapConfig.SELECTION_FILL_TRANSPARENCY
	highlight.OutlineColor = MapConfig.SELECTION_OUTLINE_COLOR
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Enabled = false
	highlight.Parent = fxFolder

	local self = setmetatable({
		renderer = renderer,
		query = nil,
		byId = {},
		selectedId = nil,
		highlight = highlight,
		listeners = {},
		connections = {},
		pressPos = nil,
		rightPressPos = nil,
	}, SelectionController)
	self:_bind()
	return self
end

function SelectionController.setMap(self: SelectionController, payload: any, query: any)
	self:clear()
	self.query = query
	self.byId = {}
	for _, t in payload.territories do
		self.byId[t.id] = t
	end
end

function SelectionController.onChanged(self: SelectionController, fn: (record: any?) -> ())
	table.insert(self.listeners, fn)
end

function SelectionController._notify(self: SelectionController)
	local record = if self.selectedId then self.byId[self.selectedId] else nil
	-- Expose for debugging / automated tests.
	Players.LocalPlayer:SetAttribute("SelectedTerritoryId", self.selectedId or 0)
	for _, fn in self.listeners do
		task.spawn(fn, record)
	end
end

function SelectionController.select(self: SelectionController, id: number?)
	if id ~= nil and self.byId[id] == nil then
		id = nil
	end
	if id == self.selectedId then
		return
	end
	self.selectedId = id
	if id then
		local root = self.renderer:getVisualRoot(id)
		self.highlight.Adornee = root
		self.highlight.Enabled = root ~= nil
	else
		self.highlight.Adornee = nil
		self.highlight.Enabled = false
	end
	self:_notify()
end

function SelectionController.clear(self: SelectionController)
	self.selectedId = nil
	self.highlight.Adornee = nil
	self.highlight.Enabled = false
	self:_notify()
end

-- Screen position -> territory id (or nil).
function SelectionController.pick(self: SelectionController, screenPos: Vector2): number?
	local cam = workspace.CurrentCamera
	if not cam or not self.query then
		return nil
	end
	local ray = cam:ViewportPointToRay(screenPos.X, screenPos.Y)
	if math.abs(ray.Direction.Y) < 1e-6 then
		return nil
	end
	local t = (MapConfig.MAP_ORIGIN_Y - ray.Origin.Y) / ray.Direction.Y
	if t < 0 then
		return nil
	end
	local world = ray.Origin + ray.Direction * t
	return self.query:territoryAt(self.renderer:worldToMap(world))
end

function SelectionController._bind(self: SelectionController)
	table.insert(
		self.connections,
		UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed then
				return
			end
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				self.pressPos = UserInputService:GetMouseLocation()
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				self.rightPressPos = UserInputService:GetMouseLocation()
			end
		end)
	)
	table.insert(
		self.connections,
		UserInputService.InputEnded:Connect(function(input, gameProcessed)
			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				local rp = self.rightPressPos
				self.rightPressPos = nil
				if rp and not gameProcessed and (UserInputService:GetMouseLocation() - rp).Magnitude <= 6 then
					self:clear()
				end
				return
			end
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
				return
			end
			local press = self.pressPos
			self.pressPos = nil
			if gameProcessed or not press then
				return
			end
			local pos = UserInputService:GetMouseLocation()
			-- Ignore drags; only treat short clicks as selection.
			if (pos - press).Magnitude > 6 then
				return
			end
			self:select(self:pick(pos))
		end)
	)
end

return SelectionController
