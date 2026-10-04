-- Hatch Wars Event Egg Auto-Hatcher (Pet Simulator 99 - "Hatch Wars" event)
-- Pick ONE of the four event eggs in CONFIG.Egg, or leave Egg = "" to cycle
-- automatically through every event egg. Teleports next to the egg and keeps the
-- game's own Auto Hatch chain running. Event eggs only - not the real-world eggs.
--
-- Server rules learned from testing:
--   * Event eggs are CustomEggs: hatched through CustomEggs_Hatch(uid, amount).
--     The normal egg path (Eggs_RequestPurchase) rejects them with "No egg number!".
--   * Every purchase re-checks distance: you must stand within ~15 studs of the egg
--     or the server replies "You're too far away!" and stops the chain.
--   * "You don't have permission to hatch this!" means the egg is locked for this
--     account (e.g. Witching Egg until you progress further) - we stop and report
--     instead of spamming retries.
--
-- Note: do not run together with hatchwar_auto_boss.luau - both teleport the
-- character to different spots on the same strip (bosses vs eggs).
-- Compatible with common executors (Synapse, Wave, Real, etc.).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Library = ReplicatedStorage:WaitForChild("Library")
local LocalPlayer = Players.LocalPlayer

-- alive flag: respects Real's live-reload STATE when present, otherwise a getgenv token
-- so re-issuing the script stops the previous run instead of stacking loops
local G = getgenv and getgenv() or nil
if G then
	G.AutoHatchToken = (G.AutoHatchToken or 0) + 1
end
local MY_TOKEN = G and G.AutoHatchToken
local function isAlive()
	if type(STATE) == "table" and type(STATE.alive) == "function" then
		return STATE.alive()
	end
	if G then
		return G.AutoHatchToken == MY_TOKEN
	end
	return true
end

local CONFIG = {
	Egg = "Ember Egg",       -- "Ember Egg" | "Spore Egg" | "Graveyard Egg" | "Witching Egg" | "" or "all" = cycle every event egg | "none" = stop
	AutoArmsPerEgg = 25,     -- auto mode: arms on one egg before rotating to the next event egg
	AutoJoin = true,         -- teleport into the Hatch Wars instance when outside
	TeleportToEgg = true,    -- tp next to the egg (server requires ~15 studs)
	TeleportStuds = 13,      -- skip the tp if already within this range
	TeleportWait = 0.6,      -- seconds to settle after teleporting before the first attempt
	RestartDelay = 2,        -- retry pause after a generic failure
	NoCoinsDelay = 10,       -- wait this long when broke
	StatusSeconds = 10,      -- progress print interval
}

local HatchingCmds = require(Library.Client.HatchingCmds)
local Hatching = require(Library.Types.Hatching)
local CustomEggsCmds = require(Library.Client.CustomEggsCmds)
local Directory = require(Library.Directory)
local EggCmds = require(Library.Client.EggCmds)
local CalcEggPricePlayer = require(Library.Balancing.CalcEggPricePlayer)
local CurrencyCmds = require(Library.Client.CurrencyCmds)
local Save = require(Library.Client.Save)
local InstancingCmds = require(Library.Client.InstancingCmds)
local HatchWar = require(Library.Types.HatchWar)

local stats = { arms = 0, batch = 0 }
local startHatched = nil
local lastErr = ""
local hatchBlocked = false -- permission-locked egg; cleared when the egg selection changes
local stopHandled = false  -- stop mode: game auto hatch already disabled once
local AUTO_EGGS = { "Ember Egg", "Spore Egg", "Graveyard Egg", "Witching Egg" }
local autoMode = (CONFIG.Egg == "" or CONFIG.Egg == "all") -- Egg = "" -> cycle every event egg
local autoIdx = 1
local autoArms = 0
local autoBlocked = {}

local function log(msg)
	print("[AutoHatch] " .. msg)
end

local function inEvent()
	return require(Library.Client.HatchWarCmds).Instance() ~= nil
end

local function short(n)
	n = tonumber(n) or 0
	if n >= 1e9 then
		return ("%.1fb"):format(n / 1e9)
	elseif n >= 1e6 then
		return ("%.1fm"):format(n / 1e6)
	elseif n >= 1e3 then
		return ("%.1fk"):format(n / 1e3)
	end
	return tostring(math.floor(n))
end

local function charHRP()
	local char = LocalPlayer.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function eggUid()
	local ok, uid = pcall(function()
		return CustomEggsCmds.GetById(CONFIG.Egg)
	end)
	return ok and uid or nil
end

-- egg world position: read the CustomEggs object registry (GetById only returns the uid),
-- fall back to matching the model name against the uid
local function eggPosition(uid)
	local ok, a, b = pcall(debug.getupvalue, CustomEggsCmds.GetById, 1)
	local reg = nil
	if ok then
		if typeof(a) == "table" then
			reg = a
		elseif typeof(b) == "table" then
			reg = b
		end
	end
	if reg and uid and typeof(reg[uid]) == "table" then
		local pos = reg[uid]._position
		if typeof(pos) == "Vector3" then
			return pos
		end
	end
	local things = workspace:FindFirstChild("__THINGS")
	local folder = things and things:FindFirstChild("CustomEggs")
	local model = folder and uid and folder:FindFirstChild(uid)
	if model then
		return model:GetPivot().Position
	end
	return nil
end

local function goToEgg(pos)
	local hrp = charHRP()
	if not hrp then return false, "no character" end
	local flat = Vector3.new(hrp.Position.X - pos.X, 0, hrp.Position.Z - pos.Z)
	if flat.Magnitude <= CONFIG.TeleportStuds then
		return true, "already close (" .. math.floor(flat.Magnitude) .. " studs)"
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { LocalPlayer.Character }
	local from = Vector3.new(pos.X, pos.Y + 8, pos.Z + 10)
	local hit = workspace:Raycast(from, Vector3.new(0, -80, 0), params)
	local land = hit and (hit.Position + Vector3.new(0, 3, 0)) or Vector3.new(pos.X, pos.Y - 2, pos.Z + 10)
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.CFrame = CFrame.lookAt(land, Vector3.new(pos.X, land.Y, pos.Z))
	return true, "tp " .. math.floor(flat.Magnitude) .. " studs"
end

local function eggPrice(dir)
	local ok, price = pcall(function()
		return CalcEggPricePlayer(dir)
	end)
	if ok and type(price) == "number" and price > 0 then
		return price
	end
	return tonumber(dir.overrideCost) or 200
end

local function eggMaxHatch(dir)
	local ok, n = pcall(function()
		return EggCmds.GetMaxHatch(dir)
	end)
	if not ok or type(n) ~= "number" then
		ok, n = pcall(function()
			return EggCmds.GetMaxHatch()
		end)
	end
	return (ok and type(n) == "number" and n > 0) and n or 1
end

local function hatchOnce(uid)
	local dir = Directory.Eggs[CONFIG.Egg]
	if not dir then return false, "egg missing from Directory.Eggs" end
	pcall(function()
		HatchingCmds.Enable(Hatching.Options.AUTO)
	end)
	local coins = CurrencyCmds.Get(dir.currency or HatchWar.COIN) or 0
	local price = eggPrice(dir)
	local amount = math.floor(math.min(eggMaxHatch(dir), coins / price))
	if amount < 1 then
		return false, "You need more coins to buy this egg!"
	end
	stats.batch = amount
	HatchingCmds.SetupCustomEgg(uid, dir, amount)
	local ok, msg = HatchingCmds.AttemptHatch()
	if ok then
		return true
	end
	return false, tostring(msg or "unknown error")
end

-- stop mode (Egg = "none"), auto mode (Egg = "") and unknown eggs are handled live
-- in the arm loop below, so the UI can switch modes at runtime instead of exiting.

-- arm loop: keep the game's Auto Hatch chain pointed at the chosen egg
task.spawn(function()
	local nextArmAt = 0
	local missingSince = nil
	local unknownLogged = nil
	while isAlive() do
		task.wait(0.5)
		if not inEvent() then
			if CONFIG.AutoJoin then
				log("joining Hatch Wars...")
				pcall(function()
					InstancingCmds.Enter(HatchWar.INSTANCE_ID, nil, true, "Auto hatcher joining!")
				end)
				task.wait(6)
			end
			continue
		end
		if not autoMode and (CONFIG.Egg == "" or CONFIG.Egg == "none" or CONFIG.Egg == "stop") then
			if not stopHandled then
				stopHandled = true
				pcall(function()
					HatchingCmds.StopHatching()
				end)
				pcall(function()
					HatchingCmds.ForceDisable(Hatching.Options.AUTO)
				end)
				log("stopped: auto hatch disabled - pick an egg (or All event eggs) in the UI to resume")
			end
			continue
		end
		if autoMode then
			-- pick the next event egg that is not permission-blocked
			local found = nil
			for i = 1, #AUTO_EGGS do
				local idx = ((autoIdx - 1 + (i - 1)) % #AUTO_EGGS) + 1
				local cand = AUTO_EGGS[idx]
				if not autoBlocked[cand] then
					found, autoIdx = cand, idx
					break
				end
			end
			if not found then
				if not stopHandled then
					stopHandled = true
					log("all four event eggs are locked for this account - waiting for event progress")
				end
				task.wait(5)
				continue
			end
			stopHandled = false
			if CONFIG.Egg ~= found then
				log(CONFIG.Egg == "" and ("auto: starting with " .. found) or ("auto: switching to " .. found))
				pcall(function()
					HatchingCmds.StopHatching()
				end)
				CONFIG.Egg = found
				autoArms = 0
				missingSince = nil
				lastErr = ""
			end
		elseif stopHandled then
			stopHandled = false
			log("resumed: egg = " .. CONFIG.Egg)
		end
		if Directory.Eggs[CONFIG.Egg] == nil then
			if autoMode then
				autoBlocked[CONFIG.Egg] = true
				log("auto: " .. CONFIG.Egg .. " missing from Directory.Eggs - skipping")
				task.wait(1)
				continue
			end
			if unknownLogged ~= CONFIG.Egg then
				unknownLogged = CONFIG.Egg
				log(("unknown egg '%s' - use: Ember Egg, Spore Egg, Graveyard Egg, Witching Egg"):format(tostring(CONFIG.Egg)))
			end
			task.wait(2)
			continue
		end
		unknownLogged = nil
		if hatchBlocked then
			task.wait(1)
			continue
		end
		local uid = eggUid()
		if not uid then
			if not missingSince then
				missingSince = os.clock()
				log(("egg '%s' not spawned yet - waiting"):format(CONFIG.Egg))
			elseif autoMode and os.clock() - missingSince > 15 then
				log("auto: " .. CONFIG.Egg .. " not spawned - trying the next event egg")
				autoIdx = (autoIdx % #AUTO_EGGS) + 1
				missingSince = nil
			elseif os.clock() - missingSince > 30 then
				missingSince = nil
				log(("egg '%s' still missing - is it unlocked in this zone?"):format(CONFIG.Egg))
			end
			task.wait(2)
			continue
		end
		missingSince = nil
		if CONFIG.TeleportToEgg then
			local pos = eggPosition(uid)
			if pos then
				local ok, why = goToEgg(pos)
				if not ok then
					log("tp failed (" .. tostring(why) .. ")")
				elseif not why:find("already") then
					log("tp -> " .. CONFIG.Egg .. " (" .. why .. ")")
					task.wait(CONFIG.TeleportWait)
				end
			end
		end
		if HatchingCmds.IsHatching() then
			continue
		end
		if os.clock() < nextArmAt then
			continue
		end
		local ok, err = hatchOnce(uid)
		if ok then
			stats.arms += 1
			log(("hatch chain started: %s x%d (arm #%d)"):format(CONFIG.Egg, stats.batch, stats.arms))
			if autoMode then
				autoArms += 1
				if autoArms >= CONFIG.AutoArmsPerEgg then
					autoArms = 0
					autoIdx = (autoIdx % #AUTO_EGGS) + 1
					log("auto: rotating to the next event egg")
				end
			end
			task.wait(1.2)
		else
			if err ~= lastErr then
				lastErr = err
				log("attempt failed: " .. err)
			end
			if err:find("permission") then
				if autoMode then
					autoBlocked[CONFIG.Egg] = true
					log(("auto: '%s' is locked for this account - skipping it for now"):format(CONFIG.Egg))
				else
					log(("BLOCKED: '%s' is locked for this account - beat more bosses / progress the event, or switch eggs in the UI"):format(CONFIG.Egg))
					hatchBlocked = true
				end
			elseif err:find("too far") then
				nextArmAt = os.clock() + 1
			elseif err:find("too quickly") then
				nextArmAt = os.clock() + 3
			elseif err:find("coins") or err:find("afford") then
				nextArmAt = os.clock() + CONFIG.NoCoinsDelay
			else
				nextArmAt = os.clock() + CONFIG.RestartDelay
			end
		end
	end
end)

-- status loop
task.spawn(function()
	while isAlive() do
		task.wait(CONFIG.StatusSeconds)
		local sv = Save.Get()
		if startHatched == nil and sv then
			startHatched = sv.EggsHatched or 0
		end
		local hatched = (sv and sv.EggsHatched) or 0
		local coins = CurrencyCmds.Get(HatchWar.COIN) or 0
		log(("egg=%s hatching=%s hatched=+%d total=%s coins=%s arms=%d"):format(
			CONFIG.Egg, tostring(HatchingCmds.IsHatching()), hatched - (startHatched or hatched),
			short(hatched), short(coins), stats.arms))
	end
end)

do
	local dir = nil
	if not autoMode then
		dir = Directory.Eggs[CONFIG.Egg]
	end
	if autoMode then
		log(("loaded: auto mode - cycling event eggs (%s), tp=%s"):format(
			table.concat(AUTO_EGGS, ", "), tostring(CONFIG.TeleportToEgg)))
	elseif dir then
		log(("loaded: egg=%s tp=%s maxHatch=%d price=%d"):format(
			CONFIG.Egg, tostring(CONFIG.TeleportToEgg), eggMaxHatch(dir), eggPrice(dir)))
	else
		log(("loaded: egg=%s (stopped/unknown - pick one in the UI) tp=%s"):format(
			tostring(CONFIG.Egg), tostring(CONFIG.TeleportToEgg)))
	end
end

-- === Maclib UI: pick the event egg and control the hatcher live ===
-- All callbacks mutate the live CONFIG of THIS run, so changes apply on the next tick.
-- The window is purely a controller: if Maclib fails to load, hatching keeps running.
task.spawn(function()
	local ok, err = pcall(function()
		local MacLib = loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
		if not MacLib then
			error("Maclib loadstring returned nil")
		end

		local EGG_LIST = { "All event eggs (auto)", "Ember Egg", "Spore Egg", "Graveyard Egg", "Witching Egg", "Stop" }
		local function eggIndex()
			if autoMode then
				return 1
			end
			for i, e in ipairs(EGG_LIST) do
				if e == CONFIG.Egg then
					return i
				end
			end
			return #EGG_LIST
		end

		-- close a window left over from a previous run of this script
		if G and G.AutoHatchWindow then
			pcall(function()
				G.AutoHatchWindow:Unload()
			end)
		end

		local Window = MacLib:Window({
			Title = "Hatch Wars Auto",
			Subtitle = "Egg Hatcher",
			Size = UDim2.fromOffset(740, 560),
			DragStyle = 1,
			DisabledWindowControls = {},
			ShowUserInfo = true,
			Keybind = Enum.KeyCode.RightControl,
			AcrylicBlur = false, -- off: acrylic blur can be detected
		})
		if G then
			G.AutoHatchWindow = Window
		end

		local TabGroup = Window:TabGroup()
		local MainTab = TabGroup:Tab({ Name = "Hatch" })
		local SettingsTab = TabGroup:Tab({ Name = "Settings" })
		local Left = MainTab:Section({ Side = "Left" })
		local Right = MainTab:Section({ Side = "Right" })

		local function setEgg(Value)
			if Value == "All event eggs (auto)" then
				if autoMode then
					return
				end
				autoMode = true
				autoBlocked = {}
				autoIdx = 1
				autoArms = 0
				CONFIG.Egg = ""
				hatchBlocked = false
				lastErr = ""
				pcall(function()
					HatchingCmds.StopHatching()
				end)
				log("UI: auto mode - cycling every event egg")
				pcall(function()
					Window:Notify({ Title = "Hatch Wars Auto", Description = "Auto: all event eggs", Lifetime = 3 })
				end)
				return
			end
			local egg = (Value == "Stop") and "none" or Value
			local wasAuto = autoMode
			if not wasAuto and egg == CONFIG.Egg then
				return
			end
			autoMode = false
			CONFIG.Egg = egg
			hatchBlocked = false
			lastErr = ""
			if egg == "none" then
				log("UI: hatching stopped (game auto hatch disables on the next tick)")
				pcall(function()
					Window:Notify({ Title = "Hatch Wars Auto", Description = "Hatching stopped", Lifetime = 3 })
				end)
			else
				pcall(function()
					HatchingCmds.StopHatching() -- drop the previous egg's chain
				end)
				log("UI: egg = " .. egg)
				pcall(function()
					Window:Notify({ Title = "Hatch Wars Auto", Description = "Egg: " .. egg, Lifetime = 3 })
				end)
			end
		end

		Left:Header({ Text = "Event Egg" })
		Left:Dropdown({
			Name = "Which egg to hatch",
			Multi = false,
			Required = true,
			Options = EGG_LIST,
			Default = eggIndex(),
			Callback = function(Value)
				setEgg(tostring(Value))
			end,
		}, "EggSelect")

		Left:Divider()
		Left:Header({ Text = "Live Status" })
		local statusPara = Left:Paragraph({
			Header = "Status",
			Body = "starting...",
		})

		Right:Header({ Text = "Automation" })
		Right:Toggle({
			Name = "Auto join event",
			Default = CONFIG.AutoJoin,
			Callback = function(Value)
				CONFIG.AutoJoin = Value
				log("UI: auto join " .. (Value and "ON" or "OFF"))
			end,
		}, "AutoJoin")
		Right:Toggle({
			Name = "Teleport to egg",
			Default = CONFIG.TeleportToEgg,
			Callback = function(Value)
				CONFIG.TeleportToEgg = Value
				log("UI: egg teleport " .. (Value and "ON" or "OFF"))
			end,
		}, "TeleportToEgg")
		Right:Slider({
			Name = "Retry delay on error (s)",
			Default = CONFIG.RestartDelay,
			Minimum = 1,
			Maximum = 10,
			DisplayMethod = "Value",
			Precision = 0,
			Callback = function(Value)
				CONFIG.RestartDelay = math.floor(Value)
			end,
		}, "RestartDelay")
		Right:Slider({
			Name = "Wait when broke (s)",
			Default = CONFIG.NoCoinsDelay,
			Minimum = 5,
			Maximum = 30,
			DisplayMethod = "Value",
			Precision = 0,
			Callback = function(Value)
				CONFIG.NoCoinsDelay = math.floor(Value)
			end,
		}, "NoCoinsDelay")

		local function statusBody()
			local sv = Save.Get()
			local hatched = (sv and sv.EggsHatched) or 0
			local coins = CurrencyCmds.Get(HatchWar.COIN) or 0
			local egg
			if autoMode then
				local locked = 0
				for _ in pairs(autoBlocked) do
					locked += 1
				end
				egg = "All event eggs (auto)"
				if CONFIG.Egg ~= "" then
					egg ..= " -> " .. CONFIG.Egg
				end
				if locked > 0 then
					egg ..= (" (%d locked)"):format(locked)
				end
			elseif CONFIG.Egg == "" or CONFIG.Egg == "none" or CONFIG.Egg == "stop" then
				egg = "STOPPED"
			else
				egg = CONFIG.Egg
			end
			local body = ("Egg: %s\nHatching: %s\nHatched: +%d (total %s)\nCoins: %s\nArms: %d\nLast error: %s"):format(
				egg, tostring(HatchingCmds.IsHatching()), hatched - (startHatched or hatched),
				short(hatched), short(coins), stats.arms,
				lastErr ~= "" and lastErr or "-")
			if hatchBlocked then
				body ..= "\nBLOCKED: this egg is locked - switch eggs in the dropdown"
			end
			return body
		end

		MacLib:SetFolder("HatchWarsAuto")
		SettingsTab:InsertConfigSection("Left")
		MainTab:Select()
		pcall(function()
			MacLib:LoadAutoLoadConfig()
		end)

		task.spawn(function()
			while task.wait(1) do
				if not isAlive() then
					break
				end
				local bodyOk, body = pcall(statusBody)
				if bodyOk and statusPara then
					pcall(function()
						statusPara:UpdateBody(body)
					end)
				end
			end
		end)

		Window.onUnloaded(function()
			statusPara = nil
			log("UI closed - hatching keeps running; re-execute the script to reopen the window")
		end)

		log("UI loaded - RightControl shows/hides the window (egg selector + live status)")
	end)
	if not ok then
		log("UI failed to load (hatching keeps running): " .. tostring(err))
	end
end)
