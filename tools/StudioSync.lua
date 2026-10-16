-- StudioSync (development helper, run from the Studio command bar in EDIT mode)
-- Pulls every script from a specific GitHub commit of sterburger985/RoCiv and
-- writes it into the open place, creating missing scripts. HttpEnabled is
-- switched on only for the download and restored afterwards.
-- Usage: set REF to a commit SHA (preferred, avoids CDN caching) or "main".

local REF = "main"
local REPO = "https://raw.githubusercontent.com/sterburger985/RoCiv/"

local FILES = {
	"src/client/CameraController.luau",
	"src/client/ClientMain.client.luau",
	"src/client/ClientMapState.luau",
	"src/client/DebugOverlay.luau",
	"src/client/DevMapPanel.luau",
	"src/client/MapRenderer.luau",
	"src/client/MovementClient.luau",
	"src/client/SelectionController.luau",
	"src/client/TerrainPainter.luau",
	"src/client/TerritoryInfoPanel.luau",
	"src/client/TerritoryStyle.luau",
	"src/server/Map/MapGenerator.luau",
	"src/server/Map/MapValidator.luau",
	"src/server/Map/MovementGraph.luau",
	"src/server/Map/Pathfinding.luau",
	"src/server/MapService.server.luau",
	"src/server/Systems/CivilizationSystem.luau",
	"src/server/Systems/TerritorySystem.luau",
	"src/server/Systems/VisibilitySystem.luau",
	"src/shared/Geometry.luau",
	"src/shared/MapConfig.luau",
	"src/shared/MapQuery.luau",
	"src/shared/TerrainTypes.luau",
}

local HS = game:GetService("HttpService")

local function folder(parent, name)
	local f = parent:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
	end
	return f
end

-- Repo path -> (parent instance, script name, class)
local function target(path)
	local file = string.match(path, "([^/]+)%.luau$")
	local class = "ModuleScript"
	if string.find(file, "%.server$") then
		class = "Script"
		file = string.gsub(file, "%.server$", "")
	elseif string.find(file, "%.client$") then
		class = "LocalScript"
		file = string.gsub(file, "%.client$", "")
	end
	local parent
	if string.find(path, "^src/shared/") then
		parent = folder(folder(game.ReplicatedStorage, "RoCiv"), "Shared")
	elseif string.find(path, "^src/server/Map/") then
		parent = folder(folder(game.ServerScriptService, "RoCiv"), "Map")
	elseif string.find(path, "^src/server/Systems/") then
		parent = folder(folder(game.ServerScriptService, "RoCiv"), "Systems")
	elseif string.find(path, "^src/server/") then
		parent = folder(game.ServerScriptService, "RoCiv")
	elseif string.find(path, "^src/client/") then
		parent = folder(game.StarterPlayer.StarterPlayerScripts, "RoCiv")
	end
	return parent, file, class
end

local was = HS.HttpEnabled
HS.HttpEnabled = true
local report = {}
local ok, err = pcall(function()
	local sources = {}
	for _, path in FILES do
		sources[path] = HS:GetAsync(REPO .. REF .. "/" .. path, true)
	end
	-- Only write once every download succeeded (no half-synced place).
	for _, path in FILES do
		local parent, name, class = target(path)
		local s = parent:FindFirstChild(name)
		if s and s.ClassName ~= class then
			s:Destroy()
			s = nil
		end
		if not s then
			s = Instance.new(class)
			s.Name = name
			s.Parent = parent
		end
		s.Source = sources[path]
		table.insert(report, string.format("%s (%d bytes)", s:GetFullName(), #sources[path]))
	end
end)
HS.HttpEnabled = was
if not ok then
	error("StudioSync failed, nothing written: " .. tostring(err))
end
print("[StudioSync] " .. REF .. "\n" .. table.concat(report, "\n"))
return table.concat(report, "\n")
