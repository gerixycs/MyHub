--!strict
--============================================================
-- Universal Roblox Luau Framework
--============================================================
-- Game-agnostic infrastructure only.
-- No game-specific services, modules, variable names, or gameplay.
--
-- Typical use in a main script:
--   local Framework = loadstring(game:HttpGet(FRAMEWORK_URL))()
--   local Environment = Framework.InitializeVariables({
--       IsEnabled = false,
--       SelectedTarget = "",
--       CurrentToken = Framework.NIL, -- initialized as nil
--       Attempts = 0,
--   })
--
-- This file expects an executor environment with getgenv(), or falls
-- back to _G. For Roblox Studio, use a ModuleScript and replace the
-- environment access with an explicitly passed state table.
--============================================================

local VERSION = "1.0.0"
local POLL_INTERVAL = 0.05
local MIN_LOOP_INTERVAL = 0.05

local ENVIRONMENT_KEY = "__UniversalFrameworkRuntime"
local MANAGED_VARIABLES_KEY = "__UniversalFrameworkManagedVariables"
local LEGACY_STOP_KEY = "StopCurrentScript"
local LEGACY_SAFE_WAIT_KEY = "SafeWait"
local LEGACY_LOOP_MANAGER_KEY = "LoopManager"
local LEGACY_LOOP_FLAGS_KEY = "LoopFlags"

local function GetEnvironment()
	if type(getgenv) == "function" then
		local success, environment = pcall(getgenv)
		if success and type(environment) == "table" then
			return environment
		end
	end
	return _G
end

local Environment = GetEnvironment()

-- Sentinel for variables that should exist in the schema but default to nil.
local NIL = {}

local function SafeCall(callback, ...)
	if type(callback) ~= "function" then
		return false, "callback must be a function"
	end
	return pcall(callback, ...)
end

local function CancelTask(thread)
	if thread ~= nil then
		pcall(task.cancel, thread)
	end
end

local function DeepCopy(value, seen)
	if type(value) ~= "table" then
		return value
	end

	seen = seen or {}
	if seen[value] then
		return seen[value]
	end

	local result = {}
	seen[value] = result

	for key, child in pairs(value) do
		result[DeepCopy(key, seen)] = DeepCopy(child, seen)
	end

	return setmetatable(result, getmetatable(value))
end

local function ClearManagedVariables(target, names)
	if type(names) ~= "table" then
		return
	end

	for _, variableName in ipairs(names) do
		if type(variableName) == "string" then
			target[variableName] = nil
		end
	end
	table.clear(names)
end

-- Stop the previously loaded copy first. This keeps reloads from leaving
-- old scheduler tasks, connections, or callbacks running beside the new copy.
local previousRuntime = Environment[ENVIRONMENT_KEY]
if type(previousRuntime) == "table" and type(previousRuntime.Stop) == "function" then
	SafeCall(previousRuntime.Stop, "reload")
elseif type(Environment[LEGACY_STOP_KEY]) == "function" then
	SafeCall(Environment[LEGACY_STOP_KEY])
end

-- Clear any variable names that the previous framework was managing.
-- The names are recorded by InitializeVariables(), not hard-coded here.
local previousManagedVariables = Environment[MANAGED_VARIABLES_KEY]
ClearManagedVariables(Environment, previousManagedVariables)
Environment[MANAGED_VARIABLES_KEY] = {}

-- Clear generic framework-owned aliases left by an older copy.
Environment[LEGACY_SAFE_WAIT_KEY] = nil
Environment[LEGACY_LOOP_MANAGER_KEY] = nil
Environment[LEGACY_LOOP_FLAGS_KEY] = nil
Environment[LEGACY_STOP_KEY] = nil

--============================================================
-- Runtime state
--============================================================

local Session = { Active = true }
local Connections = {}
local Tasks = {}
local CleanupCallbacks = {}
local Locks = {}
local ManagedVariableNames = Environment[MANAGED_VARIABLES_KEY]

local LoopFlags = {}
local LoopManager = {
	Definitions = {},
	NextRun = {},
	Busy = {},
	CallbackTasks = {},
	Started = false,
	Task = nil,
}

Environment[LEGACY_LOOP_FLAGS_KEY] = LoopFlags
Environment[LEGACY_LOOP_MANAGER_KEY] = LoopManager

--============================================================
-- Generic variable registration
--============================================================

local RESERVED_VARIABLE_NAMES = {
	[ENVIRONMENT_KEY] = true,
	[MANAGED_VARIABLES_KEY] = true,
	[LEGACY_STOP_KEY] = true,
	[LEGACY_SAFE_WAIT_KEY] = true,
	[LEGACY_LOOP_MANAGER_KEY] = true,
	[LEGACY_LOOP_FLAGS_KEY] = true,
}

local function InitializeVariables(defaults)
	assert(type(defaults) == "table", "InitializeVariables expects a table of variable defaults")

	-- Validate everything before mutating the current environment.
	local variableNames = {}
	for variableName, defaultValue in pairs(defaults) do
		assert(type(variableName) == "string" and variableName ~= "",
			"variable names must be non-empty strings")
		assert(not RESERVED_VARIABLE_NAMES[variableName],
			("'%s' is reserved by the framework"):format(variableName))
		assert(defaultValue ~= nil, (
			"nil cannot be used as a table value; use Framework.NIL for '%s'"):format(variableName))
		table.insert(variableNames, variableName)
	end
	table.sort(variableNames)

	-- Remove the last schema entirely, including names omitted from this schema.
	ClearManagedVariables(Environment, ManagedVariableNames)

	-- Initialize only the names declared by this particular main script.
	for _, variableName in ipairs(variableNames) do
		local defaultValue = defaults[variableName]
		if defaultValue == NIL then
			Environment[variableName] = nil
		else
			Environment[variableName] = DeepCopy(defaultValue)
		end
		table.insert(ManagedVariableNames, variableName)
	end

	Environment[MANAGED_VARIABLES_KEY] = ManagedVariableNames
	return Environment
end

local function GetManagedVariableNames()
	local copy = table.create(#ManagedVariableNames)
	for index, variableName in ipairs(ManagedVariableNames) do
		copy[index] = variableName
	end
	return copy
end

--============================================================
-- Connections, tasks, and cleanup callbacks
--============================================================

local function TrackConnection(connection)
	if connection ~= nil then
		table.insert(Connections, connection)
	end
	return connection
end

local function TrackTask(thread)
	if thread ~= nil then
		table.insert(Tasks, thread)
	end
	return thread
end

local function RegisterCleanup(callback)
	assert(type(callback) == "function", "cleanup callback must be a function")
	table.insert(CleanupCallbacks, callback)
	return callback
end

--============================================================
-- Safe wait
--============================================================

local function SafeWait(durationSeconds, flagName, checkIntervalSeconds)
	local duration = math.max(tonumber(durationSeconds) or 0, 0)
	local checkInterval = math.max(tonumber(checkIntervalSeconds) or 0.1, 0.03)
	local endTime = os.clock() + duration

	while Session.Active do
		if flagName ~= nil and LoopFlags[flagName] ~= true then
			return false
		end

		local remaining = endTime - os.clock()
		if remaining <= 0 then
			return true
		end

		task.wait(math.min(checkInterval, remaining))
	end

	return false
end

--============================================================
-- Generic named locks
--============================================================

local function AcquireLock(lockName)
	assert(type(lockName) == "string" and lockName ~= "", "lock name must be a non-empty string")

	if Locks[lockName] ~= nil then
		return nil
	end

	local token = {}
	Locks[lockName] = token
	return token
end

local function ReleaseLock(lockName, token)
	if type(lockName) ~= "string" or token == nil or Locks[lockName] ~= token then
		return false
	end

	Locks[lockName] = nil
	return true
end

--============================================================
-- Generic loop scheduler
--============================================================

local function RegisterLoop(loopName, intervalSeconds, callback)
	assert(type(loopName) == "string" and loopName ~= "", "loop name must be a non-empty string")
	assert(type(callback) == "function", "loop callback must be a function")

	local interval = math.max(tonumber(intervalSeconds) or 1, MIN_LOOP_INTERVAL)
	LoopManager.Definitions[loopName] = {
		Interval = interval,
		Callback = callback,
	}

	if LoopFlags[loopName] == nil then
		LoopFlags[loopName] = false
	end

	return LoopManager.Definitions[loopName]
end

local function SetLoopEnabled(loopName, enabled)
	if LoopManager.Definitions[loopName] == nil then
		return false, "unknown loop: " .. tostring(loopName)
	end

	LoopFlags[loopName] = enabled == true
	if not LoopFlags[loopName] then
		LoopManager.NextRun[loopName] = nil
	end
	return true
end

local function StartLoopManager()
	if not Session.Active or LoopManager.Started then
		return false
	end

	LoopManager.Started = true
	LoopManager.Task = task.spawn(function()
		while Session.Active and LoopManager.Started
			and Environment[LEGACY_LOOP_MANAGER_KEY] == LoopManager do

			local now = os.clock()
			for loopName, definition in pairs(LoopManager.Definitions) do
				if not Session.Active or not LoopManager.Started then
					break
				end

				if LoopFlags[loopName] == true then
					local nextRun = LoopManager.NextRun[loopName] or 0
					if not LoopManager.Busy[loopName] and now >= nextRun then
						local callbackName = loopName
						local callbackDefinition = definition
					LoopManager.Busy[callbackName] = true

						LoopManager.CallbackTasks[callbackName] = task.defer(function()
							local success, errorMessage = pcall(callbackDefinition.Callback)

							-- A stale callback must not alter state belonging to a later session.
							if not Session.Active or Environment[LEGACY_LOOP_MANAGER_KEY] ~= LoopManager then
								return
							end

							if LoopFlags[callbackName] then
								LoopManager.NextRun[callbackName] = os.clock() + callbackDefinition.Interval
							else
								LoopManager.NextRun[callbackName] = nil
							end

							LoopManager.Busy[callbackName] = nil
							LoopManager.CallbackTasks[callbackName] = nil

							if not success then
								warn(("[Framework loop: %s] %s"):format(callbackName, tostring(errorMessage)))
							end
						end)
					end
				else
					LoopManager.NextRun[loopName] = nil
				end
			end

			task.wait(POLL_INTERVAL)
		end
	end)

	return true
end

--============================================================
-- Shutdown / cleanup
--============================================================

local StopCurrentScript
local Runtime

local function ClearLoopManager(manager)
	if type(manager) ~= "table" then
		return
	end

	manager.Started = false

	if type(manager.CallbackTasks) == "table" then
		for _, thread in pairs(manager.CallbackTasks) do
			CancelTask(thread)
		end
		table.clear(manager.CallbackTasks)
	end

	CancelTask(manager.Task)
	manager.Task = nil

	if type(manager.Definitions) == "table" then table.clear(manager.Definitions) end
	if type(manager.NextRun) == "table" then table.clear(manager.NextRun) end
	if type(manager.Busy) == "table" then table.clear(manager.Busy) end
end

StopCurrentScript = function(reason)
	if not Session.Active then
		return false
	end

	Session.Active = false
	Session.StopReason = reason or "manual"

	for flagName in pairs(LoopFlags) do
		LoopFlags[flagName] = false
	end

	ClearLoopManager(LoopManager)

	for index = #Tasks, 1, -1 do
		CancelTask(Tasks[index])
		Tasks[index] = nil
	end

	for index = #Connections, 1, -1 do
		local connection = Connections[index]
		pcall(function()
			connection:Disconnect()
		end)
		Connections[index] = nil
	end

	-- Cleanups run before managed variables are deleted, so callbacks can still use them.
	for index = #CleanupCallbacks, 1, -1 do
		SafeCall(CleanupCallbacks[index], reason)
		CleanupCallbacks[index] = nil
	end

	table.clear(Locks)

	ClearManagedVariables(Environment, ManagedVariableNames)
	Environment[MANAGED_VARIABLES_KEY] = ManagedVariableNames

	if Environment[LEGACY_STOP_KEY] == StopCurrentScript then
		Environment[LEGACY_STOP_KEY] = nil
	end
	if Environment[LEGACY_SAFE_WAIT_KEY] == SafeWait then
		Environment[LEGACY_SAFE_WAIT_KEY] = nil
	end
	if Environment[LEGACY_LOOP_MANAGER_KEY] == LoopManager then
		Environment[LEGACY_LOOP_MANAGER_KEY] = nil
	end
	if Environment[LEGACY_LOOP_FLAGS_KEY] == LoopFlags then
		Environment[LEGACY_LOOP_FLAGS_KEY] = nil
	end
	if Environment[ENVIRONMENT_KEY] == Runtime then
		Environment[ENVIRONMENT_KEY] = nil
	end

	return true
end

--============================================================
-- Public framework API
--============================================================

local Framework = {
	Version = VERSION,
	NIL = NIL,
	Environment = Environment,
	Session = Session,
	Connections = Connections,
	Tasks = Tasks,
	CleanupCallbacks = CleanupCallbacks,
	LoopFlags = LoopFlags,
	LoopManager = LoopManager,

	-- State / variable declaration
	InitializeVariables = InitializeVariables,
	GetManagedVariableNames = GetManagedVariableNames,

	-- Lifecycle and resource management
	Stop = StopCurrentScript,
	StopCurrentScript = StopCurrentScript,
	TrackConnection = TrackConnection,
	TrackTask = TrackTask,
	RegisterCleanup = RegisterCleanup,

	-- Waiting and locks
	SafeWait = SafeWait,
	AcquireLock = AcquireLock,
	ReleaseLock = ReleaseLock,

	-- Scheduler
	RegisterLoop = RegisterLoop,
	SetLoopEnabled = SetLoopEnabled,
	StartLoopManager = StartLoopManager,
}

Runtime = {
	Stop = StopCurrentScript,
	Version = VERSION,
}

Environment[ENVIRONMENT_KEY] = Runtime
Environment[LEGACY_STOP_KEY] = StopCurrentScript
Environment[LEGACY_SAFE_WAIT_KEY] = SafeWait

return Framework
