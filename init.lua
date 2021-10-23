-- based on iamtryingtofindname's Gerstner wave implementation
-- This module is freely distributed on this topic : https://devforum.roblox.com/t/realistic-oceans-using-mesh-deformation/1159345 as of writing (OCTOBER 23 2021)
-- I've done major changes to make it fit my needs
-- 22/09/2021

local Wave = {}

Wave.__index = Wave

-- Caching instancing methods

local newCFrame = CFrame.new
local newVec3 = Vector3.new
local newVec2 = Vector2.new
local datenow = DateTime.now

local IdentityCFrame = CFrame.new()

local EmptyVector2 = Vector2.new()
local EmptyVector3 = Vector3.new()

local math_noise = math.noise
local random = math.random
local setseed = math.randomseed

-- Cache math methods

local SQRT = math.sqrt
local COS, SIN = math.cos, math.sin

-- Constants

local TAU = 2 * math.pi

--

local Stepped = game:GetService("RunService").RenderStepped
local Player = game:GetService("Players").LocalPlayer

local default = {
	WaveLength = 85,
	Gravity = 1.5,
	Direction = Vector2.new(1, 0), -- must be a Vector2
	PushPoint = nil,
	WaveInstances = {},
	Steepness = 1,
	Amplitude = 1.00,
	TimeModifier = 4,
	MaxDistance = 1500,
	RestoreToDefaultCFrame = "false",
}

-- Declare local functions

local function Gerstner(pos: Vector3, waveLength: number, dir: Vector2, steepness: number, gravity: number, t: number)
	local k = TAU / waveLength
	local a = steepness / k
	local d = dir.Unit
	local c = SQRT(gravity / k)
	local f = k * d:Dot(newVec2(pos.X, pos.Z)) - c * t
	local cosF = COS(f)

	-- Displacement Vectors

	local dX = (d.X * (a * cosF))
	local dY = a * SIN(f)
	local dZ = ( d.Y * (a * cosF))
	return newVec3(dX, dY, dZ)
end

local function CreateSettings(s, o)
	o = o or {}
	s = s or default

	local new = {
		WaveLength = s.WaveLength 		or o.WaveLength    or default.WaveLength,
		Gravity = s.Gravity 			or o.Gravity 	   or default.Gravity,
		Direction = s.Direction 		or o.Direction     or default.Direction,
		PushPoint = s.PushPoint 		or o.PushPoint     or default.PushPoint,
		WaveInstances = s.WaveInstances or o.WaveInstances or default.WaveInstances,
		Steepness = s.Steepness 		or o.Steepness     or default.Steepness,
		Amplitude = s.Amplitude			or o.Amplitude	   or default.Amplitude,
		TimeModifier = s.TimeModifier 	or o.TimeModifier  or default.TimeModifier,
		MaxDistance = s.MaxDistance 	or o.MaxDistance   or default.MaxDistance,
		
		RestoreToDefaultCFrame = s.RestoreToDefaultCFrame or o.RestoreToDefaultCFrame or default.RestoreToDefaultCFrame
	}

	-- Make sure each wave instance has non-null parameters
	for index, object in pairs(s.WaveInstances) do
		-- object.Direction = object.Direction or default.Direction
		-- ^ method :Update() already handles that case
		object.Steepness = object.Steepness or default.Steepness
		object.WaveLength = object.WaveLength or default.WaveLength
		object.Gravity = object.Gravity or default.Gravity
	end

	return new
end

local function t(s)
	return (datenow().UnixTimestampMillis / 1000) * s.TimeModifier
end

local function GetDirection(_settings, worldPos)
	local Direction = _settings.Direction
	local PushPoint = _settings.PushPoint

	if PushPoint then
		local partPos = nil

		if PushPoint:IsA("Attachment") then
			partPos = PushPoint.WorldPosition
		elseif PushPoint:IsA("BasePart") then
			partPos = PushPoint.Position
		else
			warn("Invalid class for FollowPart, must be BasePart or Attachment")
			return
		end

		Direction = (partPos - worldPos).Unit
		Direction = newVec2(Direction.X, Direction.Z)
	end

	return Direction
end

-- Module

function Wave.new(meshes, waveSettings, camera, sphereRadius, bones)
	-- Get bones on our own
	if not bones then
		bones = {}
		for meshIndex, mesh in pairs(meshes) do
			bones[meshIndex] = {}
			if meshIndex == 1 then
				for _a, v in pairs(mesh:GetDescendants()) do
					if v:IsA("Bone") then
						table.insert(bones[meshIndex], v)
					end
				end
			else
				for _, v in pairs(bones[1]) do
					local bone = mesh:FindFirstChild(v.Name)
					
					if bone and bone:IsA("Bone") then
						table.insert(bones[meshIndex], bone)
					end
				end
			end
		end
	end
	
	-- Be aware that the same bone transform will given no matter whether or not it's the same mesh as the others meshes in the array
	local self = setmetatable({
		_instance = meshes[1],
		_activeCamera = camera or workspace.CurrentCamera,
		_sphereRadius = sphereRadius, -- if no value is specified, it will assume that we're working on a 2d plane
		_bones = bones,
		_lastBoneTransform = table.create(#bones, IdentityCFrame),
		_time = 0,
		_connections = {},
		_noise = {},
		_settings = CreateSettings(waveSettings),
		_unloaded = false,
	}, Wave)

	return self
end

function Wave:Update(baseOffset)
	for a, v in pairs(self._bones[1]) do
		local worldPos = v.WorldPosition
		local Settings = self._settings
		local Direction = Settings.Direction
		
		-- wrote this piece of code to prevent the bone from updating if it's out of sight, 
		-- but it ended up making operations more expensive lmao
		if (self._sphereRadius) then
			local camCFrame = self._activeCamera.CFrame
			local distanceBetweenEyeAndSphereCenter = (camCFrame.Position - baseOffset).Magnitude
			local distanceBetweenEyeAndPoint = (camCFrame.Position - worldPos).Magnitude

			local pointVisible = distanceBetweenEyeAndPoint < SQRT(distanceBetweenEyeAndSphereCenter ^ 2 + self._sphereRadius ^ 2)
			if not pointVisible then v.Transform = IdentityCFrame; end
		end
		
		-- generate a perlin noise value if the direction vector is not specified
		local function check(i, d)
			if d == EmptyVector2 or d == nil then
				-- Use Perlin Noise
				local vindex = a * #Settings.WaveInstances + i

				local Noise = self._noise[vindex]
				local NoiseX = Noise and self._noise[vindex].X
				local NoiseZ = Noise and self._noise[vindex].Z
				local NoiseModifier = 1 -- If you want more of a consistent direction, change this number to something bigger

				if not Noise then
					self._noise[vindex] = {}
					-- Uses perlin noise to generate smooth transitions between random directions in the waves
					NoiseX = math_noise(worldPos.X / NoiseModifier, worldPos.Z / NoiseModifier, 1)
					NoiseZ = math_noise(worldPos.X / NoiseModifier, worldPos.Z / NoiseModifier, 0)

					self._noise[vindex].X = NoiseX
					self._noise[vindex].Z = NoiseZ
				end

				return newVec2(NoiseX, NoiseZ)
			else
				return GetDirection(Settings, worldPos)
			end
		end

		Direction = check(0, Direction)

		-- Sums up the gerstner waves
		local sum = EmptyVector3

		for index = 1, #Settings.WaveInstances + 1 do
			local currSettings = index == 1 and Settings or Settings.WaveInstances[index - 1]
			local dir = currSettings.Direction or check(index - 1, currSettings.Direction)
			sum += Gerstner(worldPos, currSettings.WaveLength, dir, currSettings.Steepness, currSettings.Gravity, self._time)
		end
		
		for boneIndex, bone in pairs(self._bones) do
			bone[a].Transform = newCFrame(sum * Settings.Amplitude)
		end
	end
end

function Wave:Refresh()
	for boneIndex, bone in pairs(self._bones) do
		for _i, v in pairs(bone) do
			if boneIndex == 1 then
				self._lastBoneTransform[_i] = v.Transform
			end
			
			v.Transform = self._settings.RestoreToDefaultCFrame == "true" and IdentityCFrame or self._lastBoneTransform[_i]
		end
	end
end

function Wave:UpdateSettings(waveSettings)
	self._settings = CreateSettings(waveSettings, self._settings)
end

function Wave:ConnectRenderStepped(baseOffset)
	local Connection = Stepped:Connect(function(dt)
		if not game:IsLoaded() then return end
		local Settings = self._settings
		
		-- local currentTimestamp = t(Settings)
		
		if not self._activeCamera or (self._activeCamera.CFrame.p - self._instance.Position).Magnitude < Settings.MaxDistance then
			self._unloaded = false
			self._time += dt * Settings.TimeModifier -- simulation time elapsed
			self:Update(baseOffset or EmptyVector3)
		else
			if not self._unloaded then
				self:Refresh()
			end
			self._unloaded = true
		end
	end)

	table.insert(self._connections, Connection)

	return Connection
end

function Wave:Destroy()
	self._instance = nil

	for _, v in pairs(self._connections) do
		pcall(function()
			v:Disconnect()
		end)
	end

	self = nil
end

-- Aliases

Wave.wave = Wave.new

return Wave
