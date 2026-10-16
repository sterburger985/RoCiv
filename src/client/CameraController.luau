--!strict
-- CameraController (client)
-- Strategy camera: fixed pitch, looks "north" (-Z).
--   WASD / arrow keys  pan
--   Mouse wheel        zoom
--   Right-drag         pan (grab the map)
-- Camera movement is presentation only and never affects simulation.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("RoCiv"):WaitForChild("Shared")
local MapConfig = require(Shared:WaitForChild("MapConfig"))

local CameraController = {}
CameraController.__index = CameraController

export type CameraController = typeof(setmetatable(
	{} :: {
		focus: Vector3,
		height: number,
		halfWidth: number,
		halfHeight: number,
		dragging: boolean,
		connections: { RBXScriptConnection },
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

function CameraController.new(): CameraController
	local self = setmetatable({
		focus = Vector3.new(0, MapConfig.MAP_ORIGIN_Y, 0),
		height = MapConfig.CAMERA_START_HEIGHT,
		halfWidth = MapConfig.MAP_WIDTH * 0.5,
		halfHeight = MapConfig.MAP_HEIGHT * 0.5,
		dragging = false,
		connections = {},
	}, CameraController)
	self:_bind()
	return self
end

function CameraController.setBounds(self: CameraController, width: number, height: number)
	self.halfWidth = width * 0.5
	self.halfHeight = height * 0.5
	self:_clamp()
end

function CameraController.focusOn(self: CameraController, worldPos: Vector3)
	self.focus = Vector3.new(worldPos.X, MapConfig.MAP_ORIGIN_Y, worldPos.Z)
	self:_clamp()
end

function CameraController._clamp(self: CameraController)
	self.focus = Vector3.new(
		math.clamp(self.focus.X, -self.halfWidth, self.halfWidth),
		MapConfig.MAP_ORIGIN_Y,
		math.clamp(self.focus.Z, -self.halfHeight, self.halfHeight)
	)
	self.height = math.clamp(self.height, MapConfig.CAMERA_MIN_HEIGHT, MapConfig.CAMERA_MAX_HEIGHT)
end

function CameraController._apply(self: CameraController)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	if cam.CameraType ~= Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Scriptable
	end
	local pitch = math.rad(MapConfig.CAMERA_PITCH_DEGREES)
	local back = self.height / math.tan(pitch)
	local pos = self.focus + Vector3.new(0, self.height, back)
	cam.CFrame = CFrame.lookAt(pos, self.focus)
end

-- Project the mouse onto the map plane (used by right-drag panning).
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

function CameraController._bind(self: CameraController)
	local dragAnchor: Vector3? = nil

	table.insert(
		self.connections,
		UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed then
				return
			end
			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				dragAnchor = mouseOnPlane()
				self.dragging = dragAnchor ~= nil
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
				self.height *= if input.Position.Z > 0 then (1 - step) else (1 + step)
				self:_clamp()
			end
		end)
	)
	table.insert(
		self.connections,
		RunService.RenderStepped:Connect(function(dt)
			if not UserInputService:GetFocusedTextBox() then
				local move = Vector3.zero
				for key, dir in PAN_KEYS do
					if UserInputService:IsKeyDown(key) then
						move += dir
					end
				end
				if move.Magnitude > 0 then
					self.focus += move.Unit * self.height * MapConfig.CAMERA_PAN_SPEED * dt
					self:_clamp()
				end
			end
			self:_apply()
			if self.dragging and dragAnchor then
				local now = mouseOnPlane()
				if now then
					self.focus += dragAnchor - now
					self:_clamp()
					self:_apply()
				end
			end
		end)
	)
end

function CameraController.destroy(self: CameraController)
	for _, c in self.connections do
		c:Disconnect()
	end
	table.clear(self.connections)
end

return CameraController
