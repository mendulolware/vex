-- Check for table that is shared between executions.
if not shared then
	return warn("No shared, no script.")
end

-- Detach previous execution.
if shared.RageBot then
	shared.RageBot.detach()
end

local RageBot = { detached = false, connections = {}, targetPart = nil, targetPos = nil }

-- Constants.
local LINORIA_URL = "https://raw.githubusercontent.com/violin-suzutsuki/LinoriaLib/main/Library.lua"
local DATA2CODE_URL = "https://raw.githubusercontent.com/Awakenchan/GcViewerV2/refs/heads/main/Utility/Data2Code%40Amity.lua"

-- Services.
local playersService = game:GetService("Players")
local runService = game:GetService("RunService")
local userInputService = game:GetService("UserInputService")

-- State.
local localPlayer = playersService.LocalPlayer
local mouse = localPlayer:GetMouse()
local currentCamera = workspace.CurrentCamera
local lastShot = 0
local data2Code = nil
local oldNamecall = nil
local oldIndex = nil

-- Anti-aim state.
local antiAimAngle = 0
local antiAimFlip = false
local antiAimWasActive = false
local savedVelocity = nil

-- Config driven by the menu.
local config = {
	silentAim = true,
	mouseSpoof = true,
	remoteRewrite = false,
	logRemotes = false,
	autoFire = true,
	teamCheck = true,
	wallCheck = false,
	showFov = true,
	targetMode = "Cursor",
	aimPart = "Head",
	fovRadius = 1000,
	fireDelay = 0.08,
	hitChance = 100,
	prediction = 0.05,
	antiAim = false,
	antiAimMode = "Spin",
	spinSpeed = 720,
	jitterAngle = 60,
	desync = false,
	desyncPower = 500,
}

---Fetch and run a remote script through the custom request function.
---@param url string
local function loadRemote(url)
	local response = request({ Url = url, Method = "GET" })
	return loadstring(response.Body)()
end

---@module Linoria.Library
local Library = loadRemote(LINORIA_URL)
RageBot.library = Library

local fovCircle = Drawing.new("Circle")
fovCircle.Thickness = 1
fovCircle.NumSides = 64
fovCircle.Color = Color3.new(1, 0.2, 0.2)
fovCircle.Transparency = 1

local wallParams = RaycastParams.new()
wallParams.FilterType = Enum.RaycastFilterType.Exclude

---Whether the player is a valid enemy.
---@param player Player
---@return boolean
local function isEnemy(player)
	if player == localPlayer then
		return false
	end

	if config.teamCheck and player.Team and localPlayer.Team and player.Team == localPlayer.Team then
		return false
	end

	return true
end

---Whether there is a clear line from the camera to the part.
---@param part BasePart
---@return boolean
local function isVisible(part)
	wallParams.FilterDescendantsInstances = { localPlayer.Character, currentCamera }

	local origin = currentCamera.CFrame.Position
	local result = workspace:Raycast(origin, part.Position - origin, wallParams)
	return result == nil or result.Instance:IsDescendantOf(part.Parent)
end

---Return the best enemy aim part by the selected targeting mode.
---@return BasePart?
local function getTarget()
	local best, bestScore = nil, math.huge
	local mousePos = userInputService:GetMouseLocation()
	local cameraPos = currentCamera.CFrame.Position
	local distanceMode = config.targetMode == "Distance"

	for _, player in ipairs(playersService:GetPlayers()) do
		if not isEnemy(player) then
			continue
		end

		local character = player.Character
		if not character or character:FindFirstChildOfClass("ForceField") then
			continue
		end

		local part = character:FindFirstChild(config.aimPart)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not (part and humanoid and humanoid.Health > 0) then
			continue
		end

		local score
		if distanceMode then
			score = (part.Position - cameraPos).Magnitude
		else
			local screenPos, onScreen = currentCamera:WorldToViewportPoint(part.Position)
			if not onScreen then
				continue
			end

			score = (Vector2.new(screenPos.X, screenPos.Y) - mousePos).Magnitude
			if score > config.fovRadius then
				continue
			end
		end

		if score >= bestScore then
			continue
		end

		if config.wallCheck and not isVisible(part) then
			continue
		end

		best, bestScore = part, score
	end

	return best
end

---Whether this call should be redirected to the target.
---@return boolean
local function shouldRedirect()
	return config.silentAim and RageBot.targetPos ~= nil and math.random(1, 100) <= config.hitChance
end

---Aim a direction vector at the target while keeping its length.
---@param origin Vector3
---@param direction Vector3
---@return Vector3
local function redirectDirection(origin, direction)
	return (RageBot.targetPos - origin).Unit * direction.Magnitude
end

---Serialize and print remote arguments with Data2Code.
---@param remote Instance
---@param args table
local function logRemote(remote, args)
	if not data2Code then
		local ok, class = pcall(loadRemote, DATA2CODE_URL)
		if not ok then
			return warn("Data2Code failed to load.")
		end
		data2Code = class
	end

	print(remote:GetFullName(), data2Code.Convert(args, true))
end

---@param self Instance
local function handleRaycast(self, ...)
	if self ~= workspace or not shouldRedirect() then
		return oldNamecall(self, ...)
	end

	local origin, direction, params = ...
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
		return oldNamecall(self, ...)
	end

	return oldNamecall(self, origin, redirectDirection(origin, direction), params)
end

---@param self Instance
local function handleFindPartOnRay(self, ...)
	if self ~= workspace or not shouldRedirect() then
		return oldNamecall(self, ...)
	end

	local ray = ...
	if typeof(ray) ~= "Ray" then
		return oldNamecall(self, ...)
	end

	local newRay = Ray.new(ray.Origin, redirectDirection(ray.Origin, ray.Direction))
	return oldNamecall(self, newRay, select(2, ...))
end

---@param self Instance
local function handleCameraRay(self, ...)
	if self ~= currentCamera or not shouldRedirect() then
		return oldNamecall(self, ...)
	end

	local ray = oldNamecall(self, ...)
	return Ray.new(ray.Origin, redirectDirection(ray.Origin, ray.Direction))
end

---@param self Instance
local function handleFireServer(self, ...)
	if config.logRemotes then
		task.spawn(logRemote, self, table.pack(...))
	end

	if not config.remoteRewrite or not shouldRedirect() then
		return oldNamecall(self, ...)
	end

	-- Unit-length Vector3 arguments are treated as aim directions.
	local args = table.pack(...)
	local origin = currentCamera.CFrame.Position
	for index = 1, args.n do
		local value = args[index]
		if typeof(value) == "Vector3" and math.abs(value.Magnitude - 1) < 0.01 then
			args[index] = (RageBot.targetPos - origin).Unit
		end
	end

	return oldNamecall(self, table.unpack(args, 1, args.n))
end

local namecallHandlers = {
	Raycast = handleRaycast,
	FindPartOnRay = handleFindPartOnRay,
	FindPartOnRayWithIgnoreList = handleFindPartOnRay,
	FindPartOnRayWithWhitelist = handleFindPartOnRay,
	ScreenPointToRay = handleCameraRay,
	ViewportPointToRay = handleCameraRay,
	FireServer = handleFireServer,
}

oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
	if RageBot.detached or checkcaller() then
		return oldNamecall(self, ...)
	end

	local handler = namecallHandlers[getnamecallmethod()]
	if not handler then
		return oldNamecall(self, ...)
	end

	return handler(self, ...)
end))

oldIndex = hookmetamethod(game, "__index", newcclosure(function(self, key)
	if (key == "Hit" or key == "Target") and self == mouse then
		if config.mouseSpoof and RageBot.targetPos and not RageBot.detached and not checkcaller() then
			if key == "Hit" then
				return CFrame.new(RageBot.targetPos)
			end

			return RageBot.targetPart
		end
	end

	return oldIndex(self, key)
end))

---Get the local character's root and humanoid.
---@return BasePart?, Humanoid?
local function getLocalRoot()
	local character = localPlayer.Character
	if not character then
		return
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if root and humanoid and humanoid.Health > 0 then
		return root, humanoid
	end
end

---Undo velocity desync before the next render step.
local function restoreVelocity()
	local root = getLocalRoot()
	if savedVelocity and root then
		root.AssemblyLinearVelocity = savedVelocity
	end

	savedVelocity = nil
end

---Rotate the character each physics step.
---@param deltaTime number
local function onHeartbeat(deltaTime)
	local root, humanoid = getLocalRoot()
	if not config.antiAim or not root then
		if antiAimWasActive and humanoid then
			humanoid.AutoRotate = true
		end

		antiAimWasActive = false
		return
	end

	antiAimWasActive = true
	humanoid.AutoRotate = false

	if config.antiAimMode == "Spin" then
		antiAimAngle += math.rad(config.spinSpeed) * deltaTime
	elseif config.antiAimMode == "Jitter" then
		-- Face away from the camera and flip every frame.
		local _, cameraYaw = currentCamera.CFrame:ToOrientation()
		antiAimFlip = not antiAimFlip
		antiAimAngle = cameraYaw + math.pi + (antiAimFlip and 1 or -1) * math.rad(config.jitterAngle)
	else
		antiAimAngle = math.rad(math.random(0, 360))
	end

	root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, antiAimAngle, 0)

	if config.desync then
		local angle = math.random() * math.pi * 2
		savedVelocity = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(math.cos(angle), 0, math.sin(angle)) * config.desyncPower
	end
end

---Per-frame update: pick target, draw FOV, auto-fire.
local function onRender()
	restoreVelocity()
	currentCamera = workspace.CurrentCamera

	fovCircle.Visible = config.showFov and config.targetMode == "Cursor"
	fovCircle.Radius = config.fovRadius
	fovCircle.Position = userInputService:GetMouseLocation()

	local part = getTarget()
	RageBot.targetPart = part
	RageBot.targetPos = part and (part.Position + part.AssemblyLinearVelocity * config.prediction) or nil

	if not (config.autoFire and part and isrbxactive()) then
		return
	end

	local now = os.clock()
	if now - lastShot < config.fireDelay then
		return
	end

	lastShot = now
	mouse1click()
end

---Build the menu.
local function buildMenu()
	local window = Library:CreateWindow({ Title = "Vex", Center = true, AutoShow = true })
	local tab = window:AddTab("Main")

	local rageBox = tab:AddLeftGroupbox("Ragebot")
	rageBox:AddToggle("silentAim", { Text = "Silent aim (ray hooks)", Default = config.silentAim })
	rageBox:AddToggle("mouseSpoof", { Text = "Mouse.Hit spoof", Default = config.mouseSpoof })
	rageBox:AddToggle("remoteRewrite", { Text = "Remote rewrite (experimental)", Default = config.remoteRewrite })
	rageBox:AddToggle("autoFire", { Text = "Auto fire", Default = config.autoFire })
	rageBox:AddSlider("fireDelay", { Text = "Fire delay", Default = config.fireDelay, Min = 0.01, Max = 0.5, Rounding = 2 })
	rageBox:AddSlider("hitChance", { Text = "Hit chance", Default = config.hitChance, Min = 1, Max = 100, Rounding = 0 })
	rageBox:AddSlider("prediction", { Text = "Prediction (s)", Default = config.prediction, Min = 0, Max = 0.3, Rounding = 3 })

	local antiAimBox = tab:AddLeftGroupbox("Anti-aim")
	antiAimBox:AddToggle("antiAim", { Text = "Anti-aim", Default = config.antiAim })
	antiAimBox:AddDropdown("antiAimMode", { Text = "Mode", Values = { "Spin", "Jitter", "Random" }, Default = 1 })
	antiAimBox:AddSlider("spinSpeed", { Text = "Spin speed (deg/s)", Default = config.spinSpeed, Min = 60, Max = 2000, Rounding = 0 })
	antiAimBox:AddSlider("jitterAngle", { Text = "Jitter angle", Default = config.jitterAngle, Min = 10, Max = 180, Rounding = 0 })
	antiAimBox:AddToggle("desync", { Text = "Velocity desync (risky)", Default = config.desync })
	antiAimBox:AddSlider("desyncPower", { Text = "Desync power", Default = config.desyncPower, Min = 50, Max = 5000, Rounding = 0 })

	local targetBox = tab:AddRightGroupbox("Targeting")
	targetBox:AddDropdown("targetMode", { Text = "Mode", Values = { "Cursor", "Distance" }, Default = 1 })
	targetBox:AddDropdown("aimPart", { Text = "Aim part", Values = { "Head", "HumanoidRootPart", "UpperTorso" }, Default = 1 })
	targetBox:AddToggle("teamCheck", { Text = "Team check", Default = config.teamCheck })
	targetBox:AddToggle("wallCheck", { Text = "Wall check", Default = config.wallCheck })
	targetBox:AddToggle("showFov", { Text = "Show FOV", Default = config.showFov })
	targetBox:AddSlider("fovRadius", { Text = "FOV radius", Default = config.fovRadius, Min = 50, Max = 2000, Rounding = 0 })

	local debugBox = tab:AddRightGroupbox("Debug")
	debugBox:AddToggle("logRemotes", { Text = "Log FireServer args", Default = config.logRemotes })
	debugBox:AddButton("Unload", function()
		RageBot.detach()
	end)
	debugBox:AddLabel("Menu key"):AddKeyPicker("menuKey", { Default = "RightShift", NoUI = true, Text = "Menu key" })
	Library.ToggleKeybind = Options.menuKey

	-- Mirror every control into the config table.
	for key in pairs(config) do
		local control = Toggles[key] or Options[key]
		if control then
			config[key] = control.Value
			control:OnChanged(function()
				config[key] = control.Value
			end)
		end
	end
end

---Disconnect everything and clean up.
function RageBot.detach()
	if RageBot.detached then
		return
	end
	RageBot.detached = true
	RageBot.targetPart = nil
	RageBot.targetPos = nil

	restoreVelocity()
	local _, humanoid = getLocalRoot()
	if humanoid then
		humanoid.AutoRotate = true
	end

	for _, connection in ipairs(RageBot.connections) do
		connection:Disconnect()
	end

	-- Hooks stay installed but pass through once detached.
	fovCircle:Destroy()
	Library:Unload()
	shared.RageBot = nil
end

---This is called when initialization errors.
---@param error string
local function onInitializeError(error)
	warn("Failed to initialize.")
	warn(error)
	warn(debug.traceback())
	RageBot.detach()
end

local function initializeScript()
	buildMenu()
	Library:OnUnload(RageBot.detach)
	table.insert(RageBot.connections, runService.RenderStepped:Connect(onRender))
	table.insert(RageBot.connections, runService.Heartbeat:Connect(onHeartbeat))
	shared.RageBot = RageBot
end

xpcall(initializeScript, onInitializeError)
