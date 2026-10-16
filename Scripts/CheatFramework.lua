--// Shared Framework
--// Load this file as a module from your raw GitHub URL.
--// The main script receives a Framework table from this chunk.

local Environment = getgenv()

--// Internal state

local ScriptSession = { Active = true }
local ScriptConnections = {}
local PickupAttempts = {}
local EggInstances = {}
local WorldEggNames = {}

local Library = nil
local StatsUtil = nil
local LocalDataModule = nil
local OriginalGetPickupRange = nil

--// Cleanup utilities

local function CancelThread(thread)
	if thread == nil then
		return
	end

	pcall(task.cancel, thread)
end

local function ClearLoopManager(manager)
	if type(manager) ~= "table" then
		return
	end

	manager.Started = false

	if type(manager.Definitions) == "table" then
		table.clear(manager.Definitions)
	end

	if type(manager.NextRun) == "table" then
		table.clear(manager.NextRun)
	end

	if type(manager.Busy) == "table" then
		table.clear(manager.Busy)
	end

	if type(manager.CallbackTasks) == "table" then
		for _, callbackThread in manager.CallbackTasks do
			CancelThread(callbackThread)
		end
		table.clear(manager.CallbackTasks)
	end

	CancelThread(manager.Task)
	manager.Task = nil
end

local function StopPreviousSession()
	local previousStop = Environment.StopCurrentScript

	if type(previousStop) == "function" then
		pcall(previousStop)
	elseif type(Environment.StopEggRefresh) == "function" then
		pcall(Environment.StopEggRefresh)
	end

	if Environment.EggRefreshTask then
		CancelThread(Environment.EggRefreshTask)
		Environment.EggRefreshTask = nil
	end

	if type(Environment.LoopFlags) == "table" then
		for flagName in Environment.LoopFlags do
			Environment.LoopFlags[flagName] = false
		end
	end

	ClearLoopManager(Environment.LoopManager)

	if type(Environment.RestorePickupRadius) == "function" then
		pcall(Environment.RestorePickupRadius)
	end

	Environment.StopEggRefresh = nil
	Environment.EggRefreshSession = nil
	Environment.SafeWait = nil
	Environment.RestorePickupRadius = nil
	Environment.PickupRadiusEnabled = false
	Environment.CharacterLock = nil
	Environment.InMinigame = nil
end

StopPreviousSession()
