-- Hatch Wars Auto Boss Fighter (Pet Simulator 99 - "Hatch Wars" event)
-- Auto-starts boss fights and instantly taps every fight circle ("Tap to hatch faster!" bars).
-- Teleports to the boss first: the server refuses fight starts unless you stand within ~12 studs
-- (it replies with "Walk up to the boss first!").
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
	MinWinChance = 0.5,          -- only auto-fight zones with at least this win chance
	PreferredZone = 0,           -- 0 = auto pick; 1-4 = force that zone when available and affordable
	TargetBoss = 0,              -- 0 = auto; 1-4 = force that zone's boss (alias for PreferredZone)
	FightDelay = 3,              -- seconds to wait after a fight ends before starting the next
	StartCooldown = 5,           -- seconds before retrying a refused fight start
	AutoJoin = true,             -- teleport into the Hatch Wars instance when outside
	LowChanceFallback = true,    -- if no zone meets MinWinChance, grind the best affordable one (loss pity applies)
	RespectGameAutoBattle = true,-- if the game's own AutoBattle is on, let it start fights (we still tap)
	GameAutoGraceSeconds = 20,   -- but start one ourselves if the game auto starts nothing for this long
	ComboBar = true,             -- show the fight combo progress bar
	StatusSeconds = 10,          -- progress print interval
	TeleportToBoss = true,       -- tp next to the picked boss before starting (server refuses from far away)
	TeleportStuds = 12,          -- skip the tp if already within this range of the boss
	TeleportWait = 1.0,          -- seconds to settle after teleporting before starting the fight
}

local HatchWarCmds = require(Library.Client.HatchWarCmds)
local Boss = require(Library.Client.HatchWarCmds.Boss)
local Circles = require(Library.Client.HatchWarCmds.Boss.Circles)
local Input = require(Library.Client.HatchWarCmds.Boss.Input)
local Spray = require(Library.Client.HatchWarCmds.Boss.Spray)
local CurrencyCmds = require(Library.Client.CurrencyCmds)
local HatchWar = require(Library.Types.HatchWar)
local Save = require(Library.Client.Save)
local InstancingCmds = require(Library.Client.InstancingCmds)

local stats = { taps = 0, starts = 0, zone = 0 }
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
	-- TargetBoss: force a specific zone boss like Egg targets a specific egg
	if CONFIG.TargetBoss >= 1 then
		local z = CONFIG.TargetBoss
		if zoneAvailable(z) and coins >= (Boss.Recommended(z) or 0) then
			return z
		end
	end
	if CONFIG.PreferredZone >= 1 then
		local z = CONFIG.PreferredZone
		if zoneAvailable(z) and coins >= (Boss.Recommended(z) or 0) then
			return z
		end
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

local function charHRP()
	local char = LocalPlayer.Character
	return char and char:FindFirstChild("HumanoidRootPart")
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
task.spawn(function()
	while isAlive() do
		task.wait(0.05)
		if Boss.IsFighting() and Circles.Count() > 0 then
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

-- fight loop: join, pick a zone, tp to boss, start fights, repeat
task.spawn(function()
	local notFightingSince = os.clock()
	local nextStartAt = 0
	local lastGameAutoAt = os.clock()
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
			continue
		end
		comboShown = false
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
		local z = pickZone()
		if not z then
			log("no affordable zone at " .. math.floor(CONFIG.MinWinChance * 100) .. "%+ chance - waiting for buffs")
			nextStartAt = os.clock() + 6
			continue
		end
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
			log(("fight started: zone %d %s (%d%% chance)"):format(z, HatchWar.ZONES[z].Boss, math.floor((Boss.WinChance(z) or 0) * 100)))
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
		local z = stats.zone
		local chance = z > 0 and math.floor((Boss.WinChance(z) or 0) * 100) or 0
		log(("fighting=%s zone=%d chance=%d%% coins=%s wins=%s taps=%d starts=%d"):format(
			tostring(Boss.IsFighting()), z, chance, short(CurrencyCmds.Get(HatchWar.COIN) or 0),
			table.concat(bossWins(), ","), stats.taps, stats.starts))
	end
end)

log(("loaded: taps=%d/s minChance=%d%% autoJoin=%s tp=%s"):format(
	CONFIG.TapsPerSecond, math.floor(CONFIG.MinWinChance * 100),
	tostring(CONFIG.AutoJoin), tostring(CONFIG.TeleportToBoss)))
