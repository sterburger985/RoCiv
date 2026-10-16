--!strict
-- CameraController (client)
-- Strategy camera with a fixed pitch, looking "north" (-Z).
--   Start / F key     frame the whole map in the current viewport
--   WASD / arrows     pan
--   Mouse wheel       zoom toward the cursor (smoothed)
--   Right-drag        grab and pan the map
-- The framing is computed from the real viewport size, field of view and
-- pitch, so the whole map fits at any resolution or aspect ratio, and it is
-- recomputed when the window is resized. Zoom-out is capped a little beyond
-- "whole map visible" and the focus is clamped to the map, so the map can
-- never be lost. Camera movement is presentation only.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("RoCiv"):WaitForChild("Shared")
local MapConfig = require(Shared:WaitForChild("MapConfig"))

local RENDER_STEP_NAME = "RoCivStrategyCamera"

local CameraController = {}
CameraController.__index = CameraController

export type CameraController = typeof(setmetatable(
	{} :: {
		focus: Vector3,
		height: number,
		targetHeight: number,
		halfWidth: number,
		halfHeight: number,
		fitHeight: number,
		fitFocus: Vector3,
		maxHeight: number,
		userMoved: boolean,
		zoomAnchored: boolean,
		dragging: boolean,
		connections: { RBXScriptConnection },
		viewportConn: RBXScriptConnection?,
	},
	CameraController
))

local PAN_KEYS = {
	[Enum.KeyCode.W] = Vector3.new(0, 0, -1),
	[Enum.KeyCode.Up] = Vector3.new(0, 0, -1),
	[Enum.KeyCode.S] = Vector3.new(0, 0, 1),
	[Enum.KeyCode.Down] = Vector3.new(0, 0, 1),
	[Enum.KeyCode.A] = Vector3.new(-1, 0, 0),
	[Enum.KeyCode.Left] = Vector3.new(-1, 0, 0),
	[Enum.KeyCode.D] = Vector3.new(1, 0, 0),
	[Enum.KeyCode.Right] = Vector3.new(1, 0, 0),
}

-- Pure framing maths ---------------------------------------------------------

local function cameraCFrame(focus: Vector3, height: number): CFrame
	local pitch = math.rad(MapConfig.CAMERA_PITCH_DEGREES)
	local pos = focus + Vector3.new(0, height, height / math.tan(pitch))
	return CFrame.lookAt(pos, focus)
end

-- Normalised device coords (-1..1) of a world point for a given camera.
local function project(cf: CFrame, aspect: number, p: Vector3): (number, number)
	local v = cf:PointToObjectSpace(p)
	local depth = -v.Z
	if depth <= 1e-3 then
		return math.huge, math.huge
	end
	local ty = math.tan(math.rad(MapConfig.CAMERA_FIELD_OF_VIEW) * 0.5)
	return v.X / (depth * ty * aspect), v.Y / (depth * ty)
end

local function corners(halfW: number, halfH: number): { Vector3 }
	local y = MapConfig.MAP_ORIGIN_Y
	return {
		Vector3.new(-halfW, y, -halfH),
		Vector3.new(halfW, y, -halfH),
		Vector3.new(halfW, y, halfH),
		Vector3.new(-halfW, y, halfH),
	}
end

local function fits(focus: Vector3, height: number, aspect: number, pts: { Vector3 }): boolean
	local cf = cameraCFrame(focus, height)
	local limX = 1 - 2 * MapConfig.CAMERA_FIT_MARGIN_X
	local limY = 1 - 2 * MapConfig.CAMERA_FIT_MARGIN_Y
	for _, p in pts do
		local x, y = project(cf, aspect, p)
		if math.abs(x) > limX or math.abs(y) > limY then
			return false
		end
	end
	return true
end

-- Lowest camera height (and a vertically centred focus) at which the whole
-- map rectangle fits inside the viewport with the configured margins.
function CameraController.computeFit(halfW: number, halfH: number, viewport: Vector2): (number, Vector3)
	local aspect = viewport.X / math.max(viewport.Y, 1)
	local pts = corners(halfW, halfH)
	local focus = Vector3.new(0, MapConfig.MAP_ORIGIN_Y, 0)
	local height = 1000
	for _ = 1, 4 do
		-- Binary search the height for the current focus.
		local lo, hi = MapConfig.CAMERA_MIN_HEIGHT, 200000
		for _ = 1, 40 do
			local mid = (lo + hi) * 0.5
			if fits(focus, mid, aspect, pts) then
				hi = mid
			else
				lo = mid
			end
		end
		height = hi
		-- Re-centre vertically: the tilted view puts more empty space below
		-- the near edge than above the far edge, so shift the focus.
		local cf = cameraCFrame(focus, height)
		local _, yFar = project(cf, aspect, pts[1])
		local _, yNear = project(cf, aspect, pts[4])
		local imbalance = (yFar + yNear) * 0.5 -- >0: map sits high on screen
		focus += Vector3.new(0, 0, -imbalance * halfH * 0.5)
	end
	return height, focus
end

-- Instance -------------------------------------------------------------------

function CameraController.new(): CameraController
	local self = setmetatable({
		focus = Vector3.new(0, MapConfig.MAP_ORIGIN_Y, 0),
		height = 1000,
		targetHeight = 1000,
		halfWidth = 500,
		halfHeight = 300,
		fitHeight = 1000,
		fitFocus = Vector3.new(0, MapConfig.MAP_ORIGIN_Y, 0),
		maxHeight = 1200,
		userMoved = false,
		zoomAnchored = false,
		dragging = false,
		connections = {},
		viewportConn = nil,
	}, CameraController)
	self:_bind()
	return self
end

function CameraController._viewport(self: CameraController): Vector2
	local cam = workspace.CurrentCamera
	return if cam then cam.ViewportSize else Vector2.new(1280, 720)
end

function CameraController._recomputeFit(self: CameraController)
	local vp = self:_viewport()
	if vp.X < 10 or vp.Y < 10 then
		return
	end
	self.fitHeight, self.fitFocus = CameraController.computeFit(self.halfWidth, self.halfHeight, vp)
	self.maxHeight = self.fitHeight * MapConfig.CAMERA_MAX_ZOOM_OUT
end

-- Sets the map size and frames the whole map.
function CameraController.setBounds(self: CameraController, width: number, height: number)
	self.halfWidth = width * 0.5
	self.halfHeight = height * 0.5
	self:frameMap()
end

-- Shows the complete map, centred, at the best zoom for this viewport.
function CameraController.frameMap(self: CameraController)
	self:_recomputeFit()
	self.focus = self.fitFocus
	self.height = self.fitHeight
	self.targetHeight = self.fitHeight
	self.userMoved = false
	self.zoomAnchored = false
	self:_apply()
end

function CameraController.focusOn(self: CameraController, worldPos: Vector3)
	self.focus = Vector3.new(worldPos.X, MapConfig.MAP_ORIGIN_Y, worldPos.Z)
	self.userMoved = true
	self:_clamp()
end

function CameraController._clamp(self: CameraController)
	self.focus = Vector3.new(
		math.clamp(self.focus.X, -self.halfWidth, self.halfWidth),
		MapConfig.MAP_ORIGIN_Y,
		math.clamp(self.focus.Z, -self.halfHeight, self.halfHeight)
	)
	self.targetHeight = math.clamp(self.targetHeight, MapConfig.CAMERA_MIN_HEIGHT, self.maxHeight)
	self.height = math.clamp(self.height, MapConfig.CAMERA_MIN_HEIGHT, self.maxHeight)
end

function CameraController._apply(self: CameraController)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	if cam.CameraType ~= Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Scriptable
	end
	if cam.FieldOfView ~= MapConfig.CAMERA_FIELD_OF_VIEW then
		cam.FieldOfView = MapConfig.CAMERA_FIELD_OF_VIEW
	end
	cam.CFrame = cameraCFrame(self.focus, self.height)
	-- Focus drives level-of-detail and lighting priority: keep it on the map.
	cam.Focus = CFrame.new(self.focus)
end

-- Project the mouse onto the map plane.
local function mouseOnPlane(): Vector3?
	local cam = workspace.CurrentCamera
	if not cam then
		return nil
	end
	local m = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(m.X, m.Y)
	if math.abs(ray.Direction.Y) < 1e-6 then
		return nil
	end
	local t = (MapConfig.MAP_ORIGIN_Y - ray.Origin.Y) / ray.Direction.Y
	if t < 0 then
		return nil
	end
	return ray.Origin + ray.Direction * t
end

function CameraController._watchViewport(self: CameraController)
	if self.viewportConn then
		self.viewportConn:Disconnect()
	end
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	self.viewportConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		if self.userMoved then
			-- Keep the player's view, but update the zoom-out limit.
			self:_recomputeFit()
			self:_clamp()
		else
			self:frameMap()
		end
	end)
end

function CameraController._bind(self: CameraController)
	local dragAnchor: Vector3? = nil

	self:_watchViewport()
	table.insert(
		self.connections,
		workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
			self:_watchViewport()
			self:frameMap()
		end)
	)

	table.insert(
		self.connections,
		UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed then
				return
			end
			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				dragAnchor = mouseOnPlane()
				self.dragging = dragAnchor ~= nil
			elseif input.KeyCode == Enum.KeyCode.F then
				self:frameMap()
			end
		end)
	)
	table.insert(
		self.connections,
		UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				dragAnchor = nil
				self.dragging = false
			end
		end)
	)
	table.insert(
		self.connections,
		UserInputService.InputChanged:Connect(function(input, gameProcessed)
			if input.UserInputType == Enum.UserInputType.MouseWheel and not gameProcessed then
				local step = MapConfig.CAMERA_ZOOM_STEP
				self.targetHeight *= if input.Position.Z > 0 then (1 - step) else (1 + step)
				self.targetHeight = math.clamp(self.targetHeight, MapConfig.CAMERA_MIN_HEIGHT, self.maxHeight)
				self.zoomAnchored = true
				self.userMoved = true
			end
		end)
	)

	-- Bound just after Roblox's default camera scripts (RenderPriority.Camera)
	-- so nothing overwrites our CFrame later in the same frame.
	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
		if not UserInputService:GetFocusedTextBox() then
			local move = Vector3.zero
			for key, dir in PAN_KEYS do
				if UserInputService:IsKeyDown(key) then
					move += dir
				end
			end
			if move.Magnitude > 0 then
				self.focus += move.Unit * self.height * MapConfig.CAMERA_PAN_SPEED * dt
				self.userMoved = true
				self:_clamp()
			end
		end

		-- Smooth zoom that keeps the point under the cursor in place.
		if math.abs(self.targetHeight - self.height) > 0.01 then
			local before = if self.zoomAnchored then mouseOnPlane() else nil
			local alpha = 1 - math.exp(-MapConfig.CAMERA_ZOOM_SMOOTHING * dt)
			self.height += (self.targetHeight - self.height) * alpha
			self:_apply()
			if before then
				local after = mouseOnPlane()
				if after then
					self.focus += before - after
				end
			end
			self:_clamp()
		end

		self:_apply()
		if self.dragging and dragAnchor then
			local now = mouseOnPlane()
			if now then
				self.focus += dragAnchor - now
				self.userMoved = true
				self:_clamp()
				self:_apply()
			end
		end
	end)
end

function CameraController.destroy(self: CameraController)
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	if self.viewportConn then
		self.viewportConn:Disconnect()
	end
	for _, c in self.connections do
		c:Disconnect()
	end
	table.clear(self.connections)
end

return CameraController
