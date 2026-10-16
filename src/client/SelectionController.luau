--!strict
-- SelectionController (client)
-- Left-click a territory to select it. Deselect by left-clicking outside the
-- map, right-clicking without dragging (right-drag pans the camera), or the
-- panel's close button. Escape is not used: Roblox reserves it for its menu.
-- Hovering shows a thin outline; the selection gets a thick gold outline.
--
-- The cursor is projected onto the map plane, converted to map coordinates
-- and resolved with MapQuery against the territory *data*. Rendered parts
-- are never used to decide which territory was picked. Unexplored
-- territories can be selected but reveal nothing (the client has no data).

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("RoCiv"):WaitForChild("Shared")
local MapConfig = require(Shared:WaitForChild("MapConfig"))

local FX_FOLDER_NAME = "RoCivClientFX"

local SelectionController = {}
SelectionController.__index = SelectionController

export type SelectionController = typeof(setmetatable(
	{} :: {
		renderer: any,
		state: any,
		query: any,
		selectedId: number?,
		hoverId: number?,
		fx: Folder,
		selectionOutline: Instance?,
		hoverOutline: Instance?,
		listeners: { (record: any?) -> () },
		connections: { RBXScriptConnection },
		pressPos: Vector2?,
		rightPressPos: Vector2?,
	},
	SelectionController
))

function SelectionController.new(renderer: any): SelectionController
	-- One persistent FX folder; outlines inside it are replaced, never stacked.
	local old = workspace:FindFirstChild(FX_FOLDER_NAME)
	if old then
		old:Destroy()
	end
	local fx = Instance.new("Folder")
	fx.Name = FX_FOLDER_NAME
	fx.Parent = workspace

	local self = setmetatable({
		renderer = renderer,
		state = nil,
		query = nil,
		selectedId = nil,
		hoverId = nil,
		fx = fx,
		selectionOutline = nil,
		hoverOutline = nil,
		listeners = {},
		connections = {},
		pressPos = nil,
		rightPressPos = nil,
	}, SelectionController)
	self:_bind()
	return self
end

function SelectionController.setMap(self: SelectionController, state: any, query: any)
	self.state = state
	self.query = query
	self:_setHover(nil)
	self:clear()
end

function SelectionController.onChanged(self: SelectionController, fn: (record: any?) -> ())
	table.insert(self.listeners, fn)
end

function SelectionController._notify(self: SelectionController)
	local record = if self.selectedId and self.state then self.state:get(self.selectedId) else nil
	-- Exposed for debugging / automated tests.
	Players.LocalPlayer:SetAttribute("SelectedTerritoryId", self.selectedId or 0)
	for _, fn in self.listeners do
		task.spawn(fn, record)
	end
end

-- Re-sends the current record (e.g. after its visibility or owner changed).
function SelectionController.refresh(self: SelectionController, changedIds: { number }?)
	if not self.selectedId then
		return
	end
	if changedIds and not table.find(changedIds, self.selectedId) then
		return
	end
	self:_notify()
end

function SelectionController._outline(self: SelectionController, id: number, width: number, color: Color3, lift: number): Instance?
	local poly = self.renderer:getPolygon(id)
	if not poly then
		return nil
	end
	local outline = self.renderer:buildOutline(poly, width, color, lift)
	outline.Parent = self.fx
	return outline
end

-- Fill lightening: selection is stronger than hover; readable at any zoom
-- (the outlines alone are only ~1 pixel wide when fully zoomed out).
local SELECT_EMPHASIS = 0.3
local HOVER_EMPHASIS = 0.12

function SelectionController._emphasis(self: SelectionController, id: number?)
	if not id then
		return
	end
	local amount = nil
	if id == self.selectedId then
		amount = SELECT_EMPHASIS
	elseif id == self.hoverId then
		amount = HOVER_EMPHASIS
	end
	self.renderer:setEmphasis(id, amount)
end

function SelectionController.select(self: SelectionController, id: number?)
	if id ~= nil and (not self.state or self.state:get(id) == nil) then
		id = nil
	end
	if id == self.selectedId then
		return
	end
	local previous = self.selectedId
	self.selectedId = id
	self:_emphasis(previous)
	self:_emphasis(id)
	if self.selectionOutline then
		self.selectionOutline:Destroy()
		self.selectionOutline = nil
	end
	if id then
		self.selectionOutline =
			self:_outline(id, MapConfig.SELECTION_OUTLINE_WIDTH, MapConfig.SELECTION_OUTLINE_COLOR, 0.14)
		if self.selectionOutline then
			self.selectionOutline.Name = "SelectionOutline"
		end
	end
	self:_notify()
end

function SelectionController.clear(self: SelectionController)
	local previous = self.selectedId
	self.selectedId = nil
	self:_emphasis(previous)
	if self.selectionOutline then
		self.selectionOutline:Destroy()
		self.selectionOutline = nil
	end
	self:_notify()
end

function SelectionController._setHover(self: SelectionController, id: number?)
	if id == self.hoverId then
		return
	end
	local previous = self.hoverId
	self.hoverId = id
	self:_emphasis(previous)
	self:_emphasis(id)
	if self.hoverOutline then
		self.hoverOutline:Destroy()
		self.hoverOutline = nil
	end
	if id then
		self.hoverOutline = self:_outline(id, MapConfig.HOVER_OUTLINE_WIDTH, MapConfig.HOVER_OUTLINE_COLOR, 0.1)
		if self.hoverOutline then
			self.hoverOutline.Name = "HoverOutline"
		end
	end
	Players.LocalPlayer:SetAttribute("HoverTerritoryId", id or 0)
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
	local lastMouse = Vector2.new(-1, -1)
	local lastCamCF = CFrame.identity
	table.insert(
		self.connections,
		RunService.RenderStepped:Connect(function()
			-- Hover: only re-pick when the mouse or camera actually moved.
			local m = UserInputService:GetMouseLocation()
			local cam = workspace.CurrentCamera
			local camCF = if cam then cam.CFrame else CFrame.identity
			if m ~= lastMouse or camCF ~= lastCamCF then
				lastMouse = m
				lastCamCF = camCF
				self:_setHover(self:pick(m))
			end
		end)
	)
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
