-- Hatch Wars Auto Boss Fighter (Pet Simulator 99 - "Hatch Wars" event)
-- Smart target-boss cycle: resolve ONE target boss, read ITS recommended luck/coin
-- requirements, fight while luck >= that recommendation, drop to farming the middle
-- Lucky Orb strip when it falls below, return to the same boss when recovered.
-- Teleports to the boss first: the server refuses fight starts unless you stand within ~12 studs.
-- Compatible with common executors (Synapse, Wave, Real, etc.).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Library = ReplicatedStorage:WaitForChild("Library")
local LocalPlayer = Players.LocalPlayer

-- alive flag: respects Real's live-reload STATE when present, otherwise a getgenv token
-- so re-issuing the script stops the previous run instead of stacking loops
local G = getgenv and getgenv() or nil
if G then
	G.AutoBossToken = (G.AutoBossToken or 0) + 1
end
local MY_TOKEN = G and G.AutoBossToken
local function isAlive()
	if type(STATE) == "table" and type(STATE.alive) == "function" then
		return STATE.alive()
	end
	if G then
		return G.AutoBossToken == MY_TOKEN
	end
	return true
end

local CONFIG = {
	TapsPerSecond = 12,          -- server counts up to 15/s toward fight pace
	MinWinChance = 0.5,          -- fallback auto-pick only accepts zones with at least this win chance
	PreferredZone = 0,           -- 0 = auto; 1-4 = force that zone as the target when available
	TargetBoss = 0,              -- 0 = auto; 1-4 = force that zone's boss (alias for PreferredZone)
	FightDelay = 3,              -- seconds to wait after a fight ends before starting the next
	StartCooldown = 5,           -- seconds before retrying a refused fight start
	AutoJoin = true,             -- teleport into the Hatch Wars instance when outside
	LowChanceFallback = true,    -- if no zone meets MinWinChance, fight the best affordable one (loss pity applies)
	RespectGameAutoBattle = true,-- if the game's own AutoBattle is on, let it start fights (we still tap)
	GameAutoGraceSeconds = 20,   -- but start one ourselves if the game auto starts nothing for this long
	ComboBar = true,             -- show the fight combo progress bar
	StatusSeconds = 10,          -- progress print interval
	TeleportToBoss = true,       -- tp next to the picked boss before starting (server refuses from far away)
	TeleportStuds = 12,          -- skip the tp if already within this range of the boss
	TeleportWait = 1.0,          -- seconds to settle after teleporting before starting the fight
	LockTarget = true,           -- keep the same target boss unless it becomes unavailable
	MinLuckFactor = 1.0,         -- fight while luck >= factor * the TARGET boss's recommended luck
	AutoGrindCycle = true,       -- full cycle: fight -> luck low -> farm middle orbs -> fight again
	AutoFight = true,            -- start new fights automatically (off = pause after the current one)
	TapsEnabled = true,          -- tap fight circles automatically during fights
	BailTapsOnLowLuck = false,   -- false: keep tapping for the whole fight; luck can dip below rec mid-fight (hatching uses orbs), farming still runs right after the fight ends
	GrindMonitorSeconds = 2,     -- sample Luck/meter cadence during a fight
	GrindLogSeconds = 6,         -- progress print interval while farming
}

-- loader override: main.lua sets getgenv().HatchWarConfig before loading this
-- file (e.g. { TargetBoss = 3 } to always fight a specific boss); unknown keys ignored
do
	local over = getgenv().HatchWarConfig
	if type(over) == "table" then
		for k, v in pairs(over) do
			if CONFIG[k] ~= nil then
				CONFIG[k] = v
			end
		end
	end
end

local HatchWarCmds = require(Library.Client.HatchWarCmds)
local Boss = require(Library.Client.HatchWarCmds.Boss)
local Circles = require(Library.Client.HatchWarCmds.Boss.Circles)
local Input = require(Library.Client.HatchWarCmds.Boss.Input)
local Spray = require(Library.Client.HatchWarCmds.Boss.Spray)
local CurrencyCmds = require(Library.Client.CurrencyCmds)
local HatchWar = require(Library.Types.HatchWar)
local Save = require(Library.Client.Save)
local InstancingCmds = require(Library.Client.InstancingCmds)
local OrbsCmd = require(Library.Client.HatchWarCmds.Orbs)
local HatchWarLuck = require(Library.Util.HatchWarLuck)

local stats = { taps = 0, starts = 0, zone = 0 }
local CYCLE = { state = "IDLE", lastLuck = 0, lastCoins = 0, lastOrbs = 0 }
local TARGET = nil
local TARGET_UNREACHABLE = false
local TAPS_PAUSED = false
local LOCK_WAIT_LOGGED = false
local luckNow
local comboShown = false

local function log(msg)
	print("[AutoBoss] " .. msg)
end

local function inEvent()
	return HatchWarCmds.Instance() ~= nil
end

local function instanceVars()
	local sv = Save.Get()
	local iv = sv and sv.InstanceVars
	return type(iv) == "table" and iv[HatchWar.INSTANCE_ID] or nil
end

local function bossWins()
	local iv = instanceVars()
	local bw = iv and iv[HatchWar.SAVE.BossWins]
	return type(bw) == "table" and bw or {}
end

local function gameAutoBattleOn()
	local iv = instanceVars()
	local ab = iv and iv[HatchWar.SAVE.AutoBattle]
	return type(ab) == "table" and ab.On == true
end

local function zoneAvailable(z)
	if z <= 1 then
		return true
	end
	return (tonumber(bossWins()[z - 1]) or 0) > 0
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

local function pickZone()
	local coins = CurrencyCmds.Get(HatchWar.COIN) or 0
	if CONFIG.TargetBoss >= 1 then
		local z = CONFIG.TargetBoss
		if zoneAvailable(z) and coins >= (Boss.Recommended(z) or 0) then
			return z
		end
		return nil -- strict: a selected boss is never swapped for another one
	end
	if CONFIG.PreferredZone >= 1 then
		local z = CONFIG.PreferredZone
		if zoneAvailable(z) and coins >= (Boss.Recommended(z) or 0) then
			return z
		end
		return nil -- strict: a selected boss is never swapped for another one
	end
	local fallback, fallbackChance = nil, -1
	for z = #HatchWar.ZONES, 1, -1 do
		if zoneAvailable(z) then
			local recCoins = Boss.Recommended(z)
			if coins >= recCoins then
				local chance = Boss.WinChance(z) or 0
				if chance >= CONFIG.MinWinChance then
					return z
				end
				if chance > fallbackChance then
					fallback, fallbackChance = z, chance
				end
			end
		end
	end
	return CONFIG.LowChanceFallback and fallback or nil
end

-- === target boss: resolve once, keep it unless unavailable or config selects another ===
local function resolveTarget()
	if CONFIG.TargetBoss >= 1 then
		if zoneAvailable(CONFIG.TargetBoss) then
			return CONFIG.TargetBoss, "config TargetBoss"
		end
		return CONFIG.TargetBoss, "config TargetBoss (locked - waiting)"
	end
	if CONFIG.PreferredZone >= 1 then
		if zoneAvailable(CONFIG.PreferredZone) then
			return CONFIG.PreferredZone, "config PreferredZone"
		end
		return CONFIG.PreferredZone, "config PreferredZone (locked - waiting)"
	end
	for z = #HatchWar.ZONES, 1, -1 do
		if zoneAvailable(z) then
			return z, "highest unlocked"
		end
	end
	return 1, "fallback"
end

local function targetReqs(t)
	local coins, recLuck = Boss.Recommended(t)
	return (tonumber(coins) or 0), (tonumber(recLuck) or 0)
end

local function targetZone()
	if not CONFIG.LockTarget then
		return pickZone() or (select(1, resolveTarget()))
	end
	local strict = CONFIG.TargetBoss >= 1 or CONFIG.PreferredZone >= 1
	if TARGET then
		if zoneAvailable(TARGET) or strict then
			return TARGET
		end
		log(("target zone %d unavailable - re-evaluating"):format(TARGET))
		TARGET = nil
		TARGET_UNREACHABLE = false
	end
	local z, src = resolveTarget()
	TARGET = z
	TARGET_UNREACHABLE = false
	local needCoins, needLuck = targetReqs(z)
	log(("target: zone %d %s [%s] requires %s coins / %s luck (you have %s luck)"):format(
		z, HatchWar.ZONES[z].Boss, src, short(needCoins), short(needLuck), short(luckNow(z))))
	return z
end

local function charHRP()
	local char = LocalPlayer.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- === live resource readers (Luck, orb meter, coins) ===
local GRIND = {
	MinCoins = 0,       -- hard minimum coins; 0 = use the target boss's own entry cost
	MinOrbs = 400,      -- carried Lucky Orbs below this = the meter ran out -> farm
}

local function carriedOrbs()
	local ok, v = pcall(CurrencyCmds.Get, HatchWar.ORB)
	return (ok and tonumber(v)) or 0
end

local function orbCap()
	local ok, _, cap = pcall(function()
		return OrbsCmd.Bank()
	end)
	if ok and tonumber(cap) and cap > 0 then
		return cap
	end
	local attr = tonumber(LocalPlayer:GetAttribute(HatchWar.TAG_ATTRIBUTES.OrbBank))
	if attr and attr > 0 then
		return attr
	end
	return 8100
end

function luckNow(zone)
	zone = (type(zone) == "number" and zone >= 1) and zone or 1
	local ok, v = pcall(function()
		return Boss.PlayerLuck(zone)
	end)
	if ok and type(v) == "number" then
		return v
	end
	local attr = tonumber(LocalPlayer:GetAttribute(HatchWar.LUCK_ATTRIBUTE))
	if attr then
		return attr
	end
	local ok2, r = pcall(function()
		return HatchWarLuck.Compute(LocalPlayer, {}).Luck
	end)
	return (ok2 and type(r) == "number" and r) or 0
end

local function minCoinsFor(t)
	if GRIND.MinCoins > 0 then
		return GRIND.MinCoins
	end
	local coins = targetReqs(t)
	return coins
end

-- true when the TARGET boss's requirements are not met -> farm
-- returns low, human reason, reason key ("luck" | "orbs" | "coins")
local function resourceLow()
	local t = targetZone()
	local needCoins, needLuck = targetReqs(t)
	local luck = luckNow(t)
	if luck >= needLuck * CONFIG.MinLuckFactor then
		TARGET_UNREACHABLE = false
	end
	if not TARGET_UNREACHABLE and luck < needLuck * CONFIG.MinLuckFactor then
		return true, ("target %d: luck %d < %d"):format(t, math.floor(luck), math.floor(needLuck * CONFIG.MinLuckFactor)), "luck"
	end
	local orbs = carriedOrbs()
	if orbs < GRIND.MinOrbs then
		return true, ("target %d: orbs %d < %d"):format(t, orbs, GRIND.MinOrbs), "orbs"
	end
	local coins = CurrencyCmds.Get(HatchWar.COIN) or 0
	local floorCoins = minCoinsFor(t)
	if coins < floorCoins then
		return true, ("target %d: coins %s < %s"):format(t, short(coins), short(floorCoins)), "coins"
	end
	return false, nil, nil
end

local function nearestOrb()
	local folder = workspace:FindFirstChild("__DEBRIS")
	folder = folder and folder:FindFirstChild("HatchWarOrbs")
	if not folder then
		return nil, nil
	end
	local hrp = charHRP()
	if not hrp then
		return nil, nil
	end
	local best, bestD = nil, math.huge
	for _, p in ipairs(folder:GetChildren()) do
		local pp = p:IsA("BasePart") and p.Position or (p:IsA("Model") and p:GetPivot().Position or nil)
		if pp then
			local d = (pp - hrp.Position).Magnitude
			if d < bestD then
				best, bestD = pp, d
			end
		end
	end
	return best, bestD
end

local PATROL = nil
local patrolIndex = 1
local function patrolPoints()
	if PATROL then
		return PATROL
	end
	PATROL = {}
	local inst = HatchWarCmds.Instance()
	local model = inst and inst.model
	local INTERACT = model and model:FindFirstChild("INTERACT")
	local oa = INTERACT and INTERACT:FindFirstChild("OrbAreas")
	local sum = Vector3.zero
	if oa then
		for _, c in ipairs(oa:GetChildren()) do
			local p = c:IsA("BasePart") and c.Position or (c:IsA("Model") and c:GetPivot().Position or nil)
			if p then
				PATROL[#PATROL + 1] = p
				sum += p
			end
		end
	end
	if #PATROL > 0 then
		PATROL[#PATROL + 1] = sum / #PATROL
	else
		PATROL[1] = Vector3.new(6480, 17, 21998)
	end
	return PATROL
end

local lastGrindLogAt = 0
local moveTarget, moveLastAt = nil, 0
local walkPos, walkProgressAt = nil, 0
local patrolAt = 0
local function grindStep()
	local hrp = charHRP()
	if not hrp then
		return false, "no character"
	end
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return false, "no humanoid"
	end
	local now = os.clock()

	-- walk to the nearest Lucky Orb (or patrol the middle strip when none exist);
	-- no CFrame/velocity writes - the game's proximity pickup collects on arrival,
	-- so the server only ever sees normal walking speed
	local pos, dist = nearestOrb()
	local target
	if pos then
		target = pos
	else
		local pts = patrolPoints()
		local p = pts[patrolIndex]
		local flat = hrp.Position - p
		if Vector3.new(flat.X, 0, flat.Z).Magnitude <= 6 or now - patrolAt > 8 then
			patrolIndex = (patrolIndex % #pts) + 1
			patrolAt = now
			p = pts[patrolIndex]
		end
		target = p
	end

	if not moveTarget or (target - moveTarget).Magnitude > 2 or now - moveLastAt >= 2 then
		moveTarget, moveLastAt = target, now
		pcall(function()
			hum:MoveTo(target)
		end)
	end

	if not walkPos or (hrp.Position - walkPos).Magnitude > 1 then
		walkPos = hrp.Position
		walkProgressAt = now
	elseif now - walkProgressAt > 3 then
		walkProgressAt = now
		moveLastAt = 0
		pcall(function()
			hum.Jump = true
		end)
	end
	return true, pos and ("walk to orb " .. math.floor(dist) .. " studs") or "walk patrol middle"
end

local function grindProgressLog(why)
	local now = os.clock()
	if now - lastGrindLogAt >= CONFIG.GrindLogSeconds then
		lastGrindLogAt = now
		local t = targetZone()
		local _, rec = targetReqs(t)
		log(("farming: orbs=%d/%d luck=%s/%s coins=%s (%s)"):format(
			carriedOrbs(), orbCap(), short(luckNow(t)), short(rec),
			short(CurrencyCmds.Get(HatchWar.COIN) or 0), why or "low"))
	end
end

local function bossPosition(z)
	local inst = HatchWarCmds.Instance()
	local model = inst and inst.model
	model = model and model:FindFirstChild("Bosses", true)
	model = model and model:FindFirstChild("Boss" .. z)
	if not model then return nil end
	return model:GetPivot().Position
end

local function goToBoss(z)
	local bp = bossPosition(z)
	if not bp then return false, "no boss model" end
	local hrp = charHRP()
	if not hrp then return false, "no character" end
	local flat = Vector3.new(hrp.Position.X - bp.X, 0, hrp.Position.Z - bp.Z)
	if flat.Magnitude <= CONFIG.TeleportStuds then
		return true, "already close (" .. math.floor(flat.Magnitude) .. " studs)"
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { LocalPlayer.Character }
	local from = Vector3.new(bp.X, bp.Y + 8, bp.Z - 8)
	local hit = workspace:Raycast(from, Vector3.new(0, -80, 0), params)
	local pos = hit and (hit.Position + Vector3.new(0, 3, 0)) or Vector3.new(bp.X, bp.Y + 3, bp.Z - 8)
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.CFrame = CFrame.lookAt(pos, Vector3.new(bp.X, pos.Y, bp.Z))
	return true, "tp " .. math.floor(flat.Magnitude) .. " studs"
end

local function startFight(z)
	local inst = HatchWarCmds.Instance()
	if not inst then return false, "no instance" end
	local ok, r1, r2 = pcall(function()
		return inst:InvokeCustom(HatchWar.NET_PREFIX.Boss .. "Start", z)
	end)
	if not ok then return false, tostring(r1) end
	if r1 == true then return true, nil end
	return false, tostring(r2 or r1)
end

-- mirrors the game's own circleHit: count the tap, fire HW_Boss_Tap, push spray FX
local function tapCircle()
	stats.taps += 1
	pcall(function()
		Input.Count()
	end)
	if CONFIG.ComboBar and not comboShown then
		comboShown = true
		pcall(function()
			local gui = LocalPlayer.PlayerGui:FindFirstChild("_INSTANCES")
			gui = gui and gui:FindFirstChild("HatchWarBoss")
			gui = gui and gui:FindFirstChild("Controls")
			gui = gui and gui:FindFirstChild("ProgressBar")
			if gui then
				gui.Visible = true
			end
		end)
	end
	local inst = HatchWarCmds.Instance()
	if inst then
		pcall(function()
			inst:FireCustom(HatchWar.NET_PREFIX.Boss .. "Tap", "circle")
		end)
	end
	pcall(function()
		Spray.Push()
	end)
end

-- tap loop: pop one live circle per tick, paced just under the server's click cap
-- pauses instantly when the mid-fight monitor flags luck below the target's recommendation
task.spawn(function()
	while isAlive() do
		task.wait(0.05)
		if Boss.IsFighting() and CONFIG.TapsEnabled and not TAPS_PAUSED and Circles.Count() > 0 then
			local ok = pcall(function()
				return Circles.TapOldest(tapCircle)
			end)
			if not ok then
				task.wait(0.5)
			else
				local jitter = 0.85 + 0.3 * math.random()
				task.wait((1 / CONFIG.TapsPerSecond) * jitter)
			end
		end
	end
end)

-- cycle loop: resolve target -> monitor its requirements -> farm when low -> fight when met
task.spawn(function()
	local notFightingSince = os.clock()
	local nextStartAt = 0
	local lastGameAutoAt = os.clock()
	local lastMonitorAt = 0
	local wasGrinding = false
	local bailLogged = false
	while isAlive() do
		task.wait(0.4)
		if not inEvent() then
			if CONFIG.AutoJoin then
				log("joining Hatch Wars...")
				pcall(function()
					InstancingCmds.Enter(HatchWar.INSTANCE_ID, nil, true, "Auto boss fighter joining!")
				end)
				task.wait(6)
			end
			continue
		end
		if Boss.IsFighting() then
			notFightingSince = os.clock()
			lastGameAutoAt = os.clock()
			wasGrinding = false
			CYCLE.state = "FIGHTING"
			if CONFIG.AutoGrindCycle and os.clock() - lastMonitorAt >= CONFIG.GrindMonitorSeconds then
				lastMonitorAt = os.clock()
				local low, why, reason = resourceLow()
				if low then
					if CONFIG.BailTapsOnLowLuck and reason == "luck" then
						TAPS_PAUSED = true
						if not bailLogged then
							bailLogged = true
							log(("mid-fight monitor: %s -> stopped tapping, farm after this fight"):format(why))
						end
					elseif not bailLogged then
						bailLogged = true
						log(("mid-fight monitor: %s -> farm after this fight"):format(why))
					end
				elseif TAPS_PAUSED then
					TAPS_PAUSED = false
					log("mid-fight monitor: requirements met again - resuming taps")
				end
			end
			continue
		end
		comboShown = false
		TAPS_PAUSED = false
		bailLogged = false

		if CONFIG.AutoGrindCycle then
			local low, why = resourceLow()
			if low then
				if not wasGrinding then
					wasGrinding = true
					CYCLE.state = "FARMING"
					log(("farm: %s -> collecting Lucky Orbs in the middle area"):format(why))
				end
				local t = targetZone()
				if not TARGET_UNREACHABLE and carriedOrbs() >= orbCap() - 1 then
					local _, rec = targetReqs(t)
					if luckNow(t) < rec * CONFIG.MinLuckFactor then
						TARGET_UNREACHABLE = true
						log(("target %d luck unreachable at orb cap - %s"):format(t,
							(CONFIG.TargetBoss >= 1 or CONFIG.PreferredZone >= 1)
								and "staying on this boss with the luck gate lifted"
								or "falling back to best fightable zone"))
					end
				end
				grindStep()
				grindProgressLog(why)
				nextStartAt = os.clock() + 0.5
				continue
			elseif wasGrinding then
				wasGrinding = false
				CYCLE.state = "REPLENISHING"
				local t = targetZone()
				local _, rec = targetReqs(t)
				log(("restored: target %d luck %s >= %s, orbs=%d, coins=%s -> returning to boss"):format(
					t, short(luckNow(t)), short(rec), carriedOrbs(),
					short(CurrencyCmds.Get(HatchWar.COIN) or 0)))
			end
		end

		if not CONFIG.AutoFight then
			CYCLE.state = "PAUSED"
			nextStartAt = os.clock() + 0.5
			continue
		end
		local idle = os.clock() - notFightingSince
		if idle < CONFIG.FightDelay or os.clock() < nextStartAt then
			continue
		end
		local letGameStart = CONFIG.RespectGameAutoBattle
			and gameAutoBattleOn()
			and (os.clock() - lastGameAutoAt) < CONFIG.GameAutoGraceSeconds
		if letGameStart then
			continue
		end
		local z
		if CONFIG.LockTarget then
			z = targetZone()
			if TARGET_UNREACHABLE then
				z = pickZone() or z
			end
		else
			z = pickZone() or targetZone()
		end
		if not z then
			log("no affordable zone at " .. math.floor(CONFIG.MinWinChance * 100) .. "%+ chance - waiting for buffs")
			nextStartAt = os.clock() + 6
			continue
		end
		if not zoneAvailable(z) then
			if not LOCK_WAIT_LOGGED then
				LOCK_WAIT_LOGGED = true
				log(("waiting: selected boss zone %d is locked - standing by until it unlocks"):format(z))
			end
			nextStartAt = os.clock() + 5
			continue
		end
		LOCK_WAIT_LOGGED = false
		local started, errText
		if CONFIG.TeleportToBoss then
			local tpOk, tpWhy = goToBoss(z)
			if not tpOk then
				log("tp failed (" .. tostring(tpWhy) .. ") zone " .. z)
				nextStartAt = os.clock() + CONFIG.StartCooldown
				continue
			end
			if tpWhy ~= "near" and not tpWhy:find("already") then
				log("tp -> zone " .. z .. " boss (" .. tpWhy .. ")")
			end
			task.wait(CONFIG.TeleportWait)
		end
		started, errText = startFight(z)
		if started then
			stats.starts += 1
			stats.zone = z
			CYCLE.state = "FIGHTING"
			local _, rec = targetReqs(z)
			log(("fight started: target zone %d %s (%d%% chance, luck %s >= %s)"):format(
				z, HatchWar.ZONES[z].Boss, math.floor((Boss.WinChance(z) or 0) * 100),
				short(luckNow(z)), short(rec)))
		else
			log(("start refused zone %d: %s"):format(z, tostring(errText)))
			nextStartAt = os.clock() + CONFIG.StartCooldown
		end
	end
end)

-- status loop
task.spawn(function()
	while isAlive() do
		task.wait(CONFIG.StatusSeconds)
		local t = TARGET or 0
		local z = stats.zone
		local chance = z > 0 and math.floor((Boss.WinChance(z) or 0) * 100) or 0
		local luck = luckNow(t >= 1 and t or 1)
		local coins = CurrencyCmds.Get(HatchWar.COIN) or 0
		local orbs = carriedOrbs()
		local rec = t >= 1 and select(2, targetReqs(t)) or 0
		CYCLE.lastLuck = luck
		CYCLE.lastCoins = coins
		CYCLE.lastOrbs = orbs
		if Boss.IsFighting() then
			CYCLE.state = "FIGHTING"
		end
		log(("cycle=%s target=%d fighting=%s zone=%d chance=%d%% coins=%s luck=%s/%s orbs=%d/%d wins=%s taps=%d starts=%d"):format(
			CYCLE.state, t, tostring(Boss.IsFighting()), z, chance, short(coins),
			short(luck), short(rec), orbs, orbCap(), table.concat(bossWins(), ","), stats.taps, stats.starts))
	end
end)

log(("loaded: taps=%d/s minChance=%d%% autoJoin=%s tp=%s lockTarget=%s autoGrind=%s luckGate=x%.2f rec"):format(
	CONFIG.TapsPerSecond, math.floor(CONFIG.MinWinChance * 100),
	tostring(CONFIG.AutoJoin), tostring(CONFIG.TeleportToBoss), tostring(CONFIG.LockTarget),
	tostring(CONFIG.AutoGrindCycle), CONFIG.MinLuckFactor))

-- === Maclib UI: pick the target boss and control every automation live ===
-- All callbacks mutate the live CONFIG of THIS run, so changes apply mid-cycle.
-- The window is purely a controller: if Maclib fails to load, automation keeps running.
task.spawn(function()
	local ok, err = pcall(function()
		local MacLib = loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
		if not MacLib then
			error("Maclib loadstring returned nil")
		end

		local BOSS_LIST = {
			"Auto (highest unlocked)",
			"1 - Ember IBZ",
			"2 - Spore Lulu",
			"3 - Ghoul Aussie",
			"4 - Warlock Ahmad",
		}

		-- close a window left over from a previous run of this script
		if G and G.AutoBossWindow then
			pcall(function()
				G.AutoBossWindow:Unload()
			end)
		end

		local Window = MacLib:Window({
			Title = "Hatch Wars Auto",
			Subtitle = "Boss Fighter",
			Size = UDim2.fromOffset(740, 560),
			DragStyle = 1,
			DisabledWindowControls = {},
			ShowUserInfo = true,
			Keybind = Enum.KeyCode.RightControl,
			AcrylicBlur = false, -- off: acrylic blur can be detected
		})
		if G then
			G.AutoBossWindow = Window
		end

		local TabGroup = Window:TabGroup()
		local MainTab = TabGroup:Tab({ Name = "Boss" })
		local SettingsTab = TabGroup:Tab({ Name = "Settings" })
		local Left = MainTab:Section({ Side = "Left" })
		local Right = MainTab:Section({ Side = "Right" })

		local function setTargetBoss(n)
			CONFIG.TargetBoss = n
			CONFIG.PreferredZone = n
			TARGET = nil
			TARGET_UNREACHABLE = false
			LOCK_WAIT_LOGGED = false
			local desc
			if n >= 1 then
				desc = ("Target locked to boss %d (%s)"):format(n, HatchWar.ZONES[n].Boss)
			else
				desc = "Target set to auto (highest unlocked, best fightable)"
			end
			log("UI: " .. desc)
			pcall(function()
				Window:Notify({ Title = "Hatch Wars Auto", Description = desc, Lifetime = 3 })
			end)
		end

		Left:Header({ Text = "Target Boss" })
		local bossDropdown = Left:Dropdown({
			Name = "Fight which boss",
			Multi = false,
			Required = true,
			Options = BOSS_LIST,
			Default = math.clamp((CONFIG.TargetBoss or 0) + 1, 1, #BOSS_LIST),
			Callback = function(Value)
				local n = tonumber(tostring(Value):match("^(%d+)")) or 0
				setTargetBoss(n)
			end,
		}, "BossSelect")
		Left:Toggle({
			Name = "Lock target (never switch bosses)",
			Default = CONFIG.LockTarget,
			Callback = function(Value)
				CONFIG.LockTarget = Value
			end,
		}, "LockTarget")

		Left:Divider()
		Left:Header({ Text = "Live Status" })
		local statusPara = Left:Paragraph({
			Header = "Status",
			Body = "starting...",
		})

		Right:Header({ Text = "Automation" })
		Right:Toggle({
			Name = "Auto fight (start fights)",
			Default = CONFIG.AutoFight,
			Callback = function(Value)
				CONFIG.AutoFight = Value
				log("UI: auto fight " .. (Value and "ON" or "OFF"))
			end,
		}, "AutoFight")
		Right:Toggle({
			Name = "Auto farm (when luck is low)",
			Default = CONFIG.AutoGrindCycle,
			Callback = function(Value)
				CONFIG.AutoGrindCycle = Value
				log("UI: auto farm " .. (Value and "ON" or "OFF"))
			end,
		}, "AutoFarm")
		Right:Toggle({
			Name = "Auto tap fight circles",
			Default = CONFIG.TapsEnabled,
			Callback = function(Value)
				CONFIG.TapsEnabled = Value
				log("UI: auto taps " .. (Value and "ON" or "OFF"))
			end,
		}, "AutoTaps")
		Right:Toggle({
			Name = "Teleport to boss before fight",
			Default = CONFIG.TeleportToBoss,
			Callback = function(Value)
				CONFIG.TeleportToBoss = Value
				log("UI: boss teleport " .. (Value and "ON" or "OFF"))
			end,
		}, "TeleportBoss")
		Right:Slider({
			Name = "Taps per second",
			Default = CONFIG.TapsPerSecond,
			Minimum = 1,
			Maximum = 15,
			DisplayMethod = "Value",
			Precision = 0,
			Callback = function(Value)
				CONFIG.TapsPerSecond = math.floor(Value)
			end,
		}, "TapsPerSecond")
		Right:Slider({
			Name = "Luck gate (x recommendation)",
			Default = CONFIG.MinLuckFactor,
			Minimum = 0.5,
			Maximum = 1.5,
			DisplayMethod = "Value",
			Precision = 2,
			Callback = function(Value)
				CONFIG.MinLuckFactor = Value
			end,
		}, "MinLuckFactor")

		local function statusBody()
			local t = TARGET or 0
			local rec = 0
			local bossName = "- (auto)"
			if t >= 1 then
				local _, r = targetReqs(t)
				rec = r
				bossName = ("%s (zone %d)"):format(HatchWar.ZONES[t].Boss, t)
			end
			return ("State: %s\nBoss: %s\nLuck: %s / %s\nOrbs: %d / %d\nCoins: %s\nWins: %s\nTaps: %d | Fights started: %d"):format(
				tostring(CYCLE.state), bossName,
				short(luckNow(t >= 1 and t or 1)), short(rec),
				carriedOrbs(), orbCap(),
				short(CurrencyCmds.Get(HatchWar.COIN) or 0),
				table.concat(bossWins(), ","),
				stats.taps, stats.starts)
		end

		MacLib:SetFolder("HatchWarsAuto")
		SettingsTab:InsertConfigSection("Left")
		MainTab:Select()
		pcall(function()
			MacLib:LoadAutoLoadConfig()
		end)
		-- an explicit SELECTED_BOSS passed to the loadstring wins over the saved config
		if G and type(G.HatchWarConfig) == "table" then
			local n = tonumber(G.HatchWarConfig.TargetBoss)
			if n and n >= 1 and n ~= (CONFIG.TargetBoss or 0) then
				setTargetBoss(n)
				pcall(function()
					bossDropdown:UpdateSelection(math.clamp(n + 1, 1, #BOSS_LIST))
				end)
			end
		end

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
			log("UI closed - automation keeps running; re-execute the script to reopen the window")
		end)

		log("UI loaded - RightControl shows/hides the window (boss selector + live status)")
	end)
	if not ok then
		log("UI failed to load (automation keeps running): " .. tostring(err))
	end
end)
