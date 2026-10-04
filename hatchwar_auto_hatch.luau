-- Hatch Wars Event Egg Auto-Hatcher (Pet Simulator 99 - "Hatch Wars" event)
-- Pick ONE of the four event eggs in CONFIG.Egg, teleports next to it and keeps the
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
	Egg = "Ember Egg",       -- "Ember Egg" | "Spore Egg" | "Graveyard Egg" | "Witching Egg" | "" = stop & disable auto hatch
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

-- stop mode: CONFIG.Egg = "" disables the game's auto hatch and exits
if CONFIG.Egg == "" or CONFIG.Egg == "none" then
	pcall(function()
		HatchingCmds.StopHatching()
	end)
	pcall(function()
		HatchingCmds.ForceDisable(Hatching.Options.AUTO)
	end)
	log("stopped: auto hatch disabled")
	return
end

if Directory.Eggs[CONFIG.Egg] == nil then
	log(("unknown egg '%s' - use: Ember Egg, Spore Egg, Graveyard Egg, Witching Egg"):format(tostring(CONFIG.Egg)))
	return
end

-- arm loop: keep the game's Auto Hatch chain pointed at the chosen egg
task.spawn(function()
	local nextArmAt = 0
	local stopped = false
	local missingSince = nil
	while isAlive() and not stopped do
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
		local uid = eggUid()
		if not uid then
			if not missingSince then
				missingSince = os.clock()
				log(("egg '%s' not spawned yet - waiting"):format(CONFIG.Egg))
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
			task.wait(1.2)
		else
			if err ~= lastErr then
				lastErr = err
				log("attempt failed: " .. err)
			end
			if err:find("permission") then
				log(("STOPPED: '%s' is locked for this account - beat more bosses / progress the event, then re-run"):format(CONFIG.Egg))
				stopped = true
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

log(("loaded: egg=%s tp=%s maxHatch=%d price=%d"):format(
	CONFIG.Egg, tostring(CONFIG.TeleportToEgg),
	eggMaxHatch(Directory.Eggs[CONFIG.Egg]), eggPrice(Directory.Eggs[CONFIG.Egg])))
