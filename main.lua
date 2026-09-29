--!nonstrict
-- Space Mining Hub (PS99) - standalone loadstring build
-- Usage:
--   loadstring(game:HttpGet('https://raw.githubusercontent.com/gametil/SpaceMining-Hub/refs/heads/main/main.lua'))()
--
-- STATE shim: under Real's live-reload, STATE (alive/onCleanup) is injected and this is
-- skipped. Standalone (HttpGet loadstring) we provide a minimal fallback so cleanup
-- registration and loops still work.

if STATE == nil then
	local cleanups = {}
	STATE = {
		alive = function()
			return true
		end,
		onCleanup = function(fn)
			table.insert(cleanups, fn)
		end,
	}
end

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer

-- Runtime-safe require: guards against missing modules AND silences static
-- "Unknown require" false positives (analyzer can't see runtime WaitChild paths).
local function safeRequire(path: string): any
	local node: any = game
	for seg in string.gmatch(path, "[^%.]+") do
		if seg == "game" then
			continue
		end
		node = node:WaitForChild(seg, 10)
		if not node then
			error("[SpaceMiningHub] module not found: " .. path)
		end
	end
	return (require(node))
end

local Network = safeRequire("game.ReplicatedStorage.Library.Client.Network")
local InstancingCmds = safeRequire("game.ReplicatedStorage.Library.Client.InstancingCmds")
local BlockWorldClient = safeRequire("game.ReplicatedStorage.Library.Client.ToolCmds.BlockWorldClient")
local Save = safeRequire("game.ReplicatedStorage.Library.Client.Save")
local ConsumableItem = safeRequire("game.ReplicatedStorage.Library.Items.ConsumableItem")

local INSTANCE_ID = "SpaceMiningEvent"

----------------------------------------------------------------
-- CONFIG (UI binds here)
----------------------------------------------------------------
local CFG = {
	MiningMethod = "Nearest",      -- Nearest | HighestValue | Priority
	PriorityOrder = {"Ruby Ore", "Quartz Ore", "Topaz Ore", "Sapphire Ore", "Emerald Ore", "Amethyst Ore", "Onyx Ore", "Rainbow Ore"},
	Range = 300,
	Blacklist = {},                -- set of ore DisplayName
	AutoMine = false,
	AutoTeleport = false,
	AutoHatch = false,
	AutoClaimPickaxe = false,
	AutoBuyZone = false,
	AutoBuyBombs = false,
	AntiAFK = false,
	TickRate = 0.5,
}

local notifyOn = true -- Notifications toggle

----------------------------------------------------------------
-- EVENT ENTRY / STATUS
----------------------------------------------------------------
local SM = {}

function SM.IsInEvent(): boolean
	local ok, res = pcall(function()
		return InstancingCmds.GetInstanceID() == INSTANCE_ID
	end)
	return ok and res == true
end

function SM.JoinEvent(): (boolean, string)
	if SM.IsInEvent() then
		return true, "Already in Space Mining Event"
	end
	local ok, err = pcall(function()
		InstancingCmds.Enter(INSTANCE_ID, nil, true, "Joining Space Mining Event")
	end)
	if ok then
		pcall(function()
			Network.Fire("Instances: Mark Entered", INSTANCE_ID)
		end)
		return true, "Joining Space Mining Event"
	end
	return false, tostring(err)
end

----------------------------------------------------------------
-- ORE SCANNER (ore = Part child "B" + DisplayName ends "Ore"; chests excluded)
----------------------------------------------------------------
export type OreEntry = { part: BasePart, name: string, tier: number, dist: number, pos: Vector3 }

local function isChest(id: string): boolean
	return string.find(id, "Chest", 1, true) ~= nil
end

function SM.ScanOres(): {OreEntry}
	local out: {OreEntry} = {}
	local w = BlockWorldClient.GetLocal()
	if not w or w.Destroyed or not w.Blocks then
		return out
	end
	local char = lp.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return out
	end
	local hp = (hrp :: BasePart).Position
	local model = w.Model
	for _, b in pairs(w.Blocks) do
		if not b.TempBroken then
			local d = b.Dir
			local id = d and tostring(d._id or "") or ""
			local name = d and tostring(d.DisplayName) or "?"
			if string.sub(name, -4) == "Ore" and not isChest(id) and not CFG.Blacklist[name] then
				local part = b.Part
				if typeof(part) ~= "Instance" then
					part = model and model:FindFirstChild(tostring(part))
				end
				if typeof(part) == "Instance" and part:IsA("BasePart") then
					local p = part :: BasePart
					if p:FindFirstChild("B") ~= nil then
						local pos = p.Position
						local dist = (pos - hp).Magnitude
						if dist <= CFG.Range then
							table.insert(out, { part = p, name = name, tier = tonumber(d and d.Tier) or 0, dist = dist, pos = pos })
						end
					end
				end
			end
		end
	end
	return out
end

----------------------------------------------------------------
-- TARGET SELECTION: Nearest / HighestValue / Priority
----------------------------------------------------------------
local function priorityRank(name: string): number
	for i, n in ipairs(CFG.PriorityOrder) do
		if n == name then
			return i
		end
	end
	return math.huge
end

function SM.SelectTarget(ores: {OreEntry}): OreEntry?
	if #ores == 0 then
		return nil
	end
	local method = CFG.MiningMethod
	table.sort(ores, function(a, b)
		if method == "Nearest" then
			return a.dist < b.dist
		elseif method == "Priority" then
			local ra, rb = priorityRank(a.name), priorityRank(b.name)
			if ra ~= rb then
				return ra < rb
			end
		end
		return (a.tier * 1000 - a.dist) > (b.tier * 1000 - b.dist)
	end)
	return ores[1]
end

----------------------------------------------------------------
-- ACTION CONTROLLER: PV_Latch -> HW_Flush -> SimulateBreak
----------------------------------------------------------------
local function posString(pos: Vector3): string
	return string.format("%d, %d, %d", math.floor(pos.X + 0.5), math.floor(pos.Y + 0.5), math.floor(pos.Z + 0.5))
end

function SM.MineOnce(target: OreEntry)
	Network.Fire("PV_Latch", posString(target.pos))
	Network.Fire("HW_Flush", target.part)
	pcall(function()
		local brk = (target.part :: any).SimulateBreak
		if brk then
			(target.part :: any):SimulateBreak()
		end
	end)
end

----------------------------------------------------------------
-- AUTO MINE LOOP
----------------------------------------------------------------
local mineThread: thread? = nil

function SM.SetAutoMine(enabled: boolean)
	CFG.AutoMine = enabled
	if enabled and not mineThread then
		mineThread = task.spawn(function()
			while STATE.alive() and CFG.AutoMine do
				if SM.IsInEvent() then
					local ok, err = pcall(function()
						local target = SM.SelectTarget(SM.ScanOres())
						if target then
							SM.MineOnce(target)
						end
					end)
					if not ok then
						warn("[SpaceMining] " .. tostring(err))
					end
				end
				task.wait(CFG.TickRate)
			end
			mineThread = nil
		end)
	elseif not enabled and mineThread then
		task.cancel(mineThread :: thread)
		mineThread = nil
	end
end

----------------------------------------------------------------
-- AUTO BUY NEXT ZONE (event zones)
----------------------------------------------------------------
function SM.BuyZone(zoneNumber: number): (boolean, string)
	local ok, res = pcall(function()
		return Network.Invoke("InstanceZones_RequestPurchase", INSTANCE_ID, zoneNumber)
	end)
	return ok and res == true, tostring(res)
end

local function autoBuyZoneLoop()
	while STATE.alive() and CFG.AutoBuyZone do
		if SM.IsInEvent() then
			pcall(function()
				local zones = Save.Get().InstanceZones
				local bought = zones and zones[INSTANCE_ID] or {}
				local nextZone = (bought.Max or 0) + 1
				SM.BuyZone(nextZone)
			end)
		end
		task.wait(2)
	end
end

----------------------------------------------------------------
-- PICKAXE CLAIM (Dark Matter Pickaxe via QB_Tender)
----------------------------------------------------------------
function SM.ClaimPickaxe(pickaxeId: any): (boolean, string)
	local ok, res = pcall(function()
		return Network.Invoke("QB_Tender", pickaxeId)
	end)
	return ok and res == true, tostring(res)
end

----------------------------------------------------------------
-- EGGS (Auto Hatch)
----------------------------------------------------------------
function SM.HatchEgg(eggId: string, count: number?): (boolean, string)
	local ok, res = pcall(function()
		return Network.Invoke("Eggs_RequestPurchase", eggId, count or 1)
	end)
	return ok and res == true, tostring(res)
end

----------------------------------------------------------------
-- MERCHANT (Space Mine Merchant slots: bombs for SpaceCoins)
----------------------------------------------------------------
function SM.BuyMerchantSlot(slot: number): (boolean, string)
	local ok, res, err = pcall(function()
		return Network.Invoke("Merchant_RequestPurchase", "SpaceMineMerchant", slot, true)
	end)
	if ok and res == true then
		return true, "Bought slot " .. slot
	end
	return false, tostring(err or res or "buy failed")
end

function SM.AutoBuyLoop()
	-- Real logic mirrored from the game's "Auto Space Merchant" (docId 67 L335-357):
	-- refresh stock via ZR_Cycle, then respect-gate slots and buy with Merchant_RequestPurchase.
	task.spawn(function()
		local Merchants = safeRequire("game.ReplicatedStorage.__DIRECTORY.Merchants.SpaceMineMerchant")
		local MerchantUtil = safeRequire("game.ReplicatedStorage.Library.Client.MerchantUtil")
		local Save = safeRequire("game.ReplicatedStorage.Library.Client.Save")
		while STATE.alive() and CFG.AutoBuyBombs do
			if SM.IsInEvent() then
				pcall(function()
					Network.Invoke("ZR_Cycle") -- refresh merchant stock
				end)
				local respect = 1
				pcall(function()
					local save = Save.Get()
					local exp = save and save.MerchantExperience and save.MerchantExperience.SpaceMineMerchant or 0
					respect = MerchantUtil.RespectLevelFromExperience(exp)
				end)
				local slotLevels = Merchants.SlotRespectLevels or {}
				for slot = 1, #slotLevels do
					if not (STATE.alive() and CFG.AutoBuyBombs) then
						break
					end
					if respect >= slotLevels[slot] then
						local ok, err = SM.BuyMerchantSlot(slot)
						if not ok and string.find(err, "enough") then
							Network.Fire("CF_Reset")
							CFG.AutoBuyBombs = false
							warn("[SpaceMining] Out of Space Coins - auto-buy disabled")
							break
						end
						task.wait(0.5)
					end
				end
			end
			task.wait(1)
		end
	end)
end

----------------------------------------------------------------
-- BOMB MANAGER — Space Mining EXPLOSIVES (all data-verified)
--
-- VERIFIED set (ONLY these 7 are real Space Mining explosives), proven 3 ways:
--   1) __DIRECTORY.Consumables entries with InventoryTags = {"Space Mining"}
--   2) the game's own ActionMenu.Consumable whitelist (u76)
--   3) each item's Tiers[1].Desc (what it actually does)
-- Nothing invented. The 3 "Booster" consumables are NOT explosives (excluded).
--
-- Activation (verified live): ConsumableCmds.Consume(ownedItem, 1)
--   -> fires "Consumables_Consume" with the real owned UID. Requirement() passes for all 7.
--
-- No per-item cooldown exists in game data. `cooldown` below is a user repeat-timer
-- (activate -> wait -> activate), NOT a game value.
--
-- "MM_*" strings are FFlag PRICE keys (e.g. MM_Bomb=150000 SpaceCoins, MM_NuclearTNT=50
-- Helium-3), NOT item/merchant codes — they must never be passed to a remote.
----------------------------------------------------------------
local InventoryCmds = safeRequire("game.ReplicatedStorage.Library.Client.InventoryCmds")
local ConsumableCmds = safeRequire("game.ReplicatedStorage.Library.Client.ConsumableCmds")

local BombManager = {}

-- Map: key -> verified record. fromMerchant = obtainable from the Space Mine Merchant drop tables.
BombManager.Bombs = {
	BigBang        = { name = "Big Bang",        fromMerchant = true,  desc = "mine-wide countdown -> massive crater" },
	RoverCharge    = { name = "Rover Charge",    fromMerchant = true,  desc = "leaps & slams down 3x at your feet" },
	VoidCharge     = { name = "Void Charge",     fromMerchant = false, desc = "sucks rock in, then blows" },
	DrillArray     = { name = "Drill Array",     fromMerchant = true,  desc = "5 shafts in an X (strip mining)" },
	CoreCharge     = { name = "Core Charge",     fromMerchant = true,  desc = "bores 20 layers straight down" },
	BreachCharge   = { name = "Breach Charge",   fromMerchant = true,  desc = "small blast, cracks rock above & below" },
	StardustCharge = { name = "Stardust Charge", fromMerchant = false, desc = "turns surrounding rock into solid ore" },
}

-- Deterministic UI order (matches the reference screenshot sequence).
BombManager.Order = {
	"BigBang", "RoverCharge", "VoidCharge", "DrillArray",
	"CoreCharge", "BreachCharge", "StardustCharge",
}

BombManager.State = {}
for key, def in BombManager.Bombs do
	BombManager.State[key] = { enabled = false, cooldown = 20, lastFired = 0, lastError = nil, loop = nil, name = def.name }
end

-- Real owned-item lookup: items live in InventoryCmds.Container()._store._byUID,
-- matched by GetId() == item name. (Name-template items have no UID — GetUID asserts.)
local InventoryCmds = safeRequire("game.ReplicatedStorage.Library.Client.InventoryCmds")
local ConsumableCmds = safeRequire("game.ReplicatedStorage.Library.Client.ConsumableCmds")

local function getOwnedItem(itemName: string): any?
	local ok, found = pcall(function()
		local store = InventoryCmds.Container()._store
		for _uid, entry in pairs(store._byUID) do
			local idOk, id = pcall(function()
				return entry:GetId()
			end)
			if idOk and id == itemName then
				return entry
			end
		end
		return nil
	end)
	return ok and found or nil
end

function BombManager.Fire(key: string): (boolean, string)
	local def = BombManager.Bombs[key]
	if not def then
		return false, "Unknown bomb: " .. tostring(key)
	end
	local item = getOwnedItem(def.name)
	if not item then
		BombManager.State[key].lastError = "not in inventory"
		return false, "No " .. def.name .. " in inventory"
	end
	-- Game's own activation path: clones to amount 1, checks requirements,
	-- fires "Consumables_Consume" with the real owned UID.
	local ok, res, err = pcall(function()
		return ConsumableCmds.Consume(item, 1)
	end)
	if ok and res == true then
		BombManager.State[key].lastFired = os.clock()
		BombManager.State[key].lastError = nil
		return true, def.name .. " fired"
	end
	BombManager.State[key].lastError = tostring(err or res or "consume rejected")
	return false, tostring(err or res or "consume rejected")
end

-- Loop: activate -> wait cooldown -> repeat (exactly the requested bomb cycle)
function BombManager.SetEnabled(key: string, enabled: boolean, cooldown: number?)
	local st = BombManager.State[key]
	if not st then
		return
	end
	st.enabled = enabled
	if cooldown then
		st.cooldown = math.max(1, cooldown)
	end
	if enabled and not st.loop then
		st.loop = task.spawn(function()
			while STATE.alive() and st.enabled do
				pcall(BombManager.Fire, key)
				local waited = 0
				while STATE.alive() and st.enabled and waited < st.cooldown do
					task.wait(0.5)
					waited += 0.5
				end
			end
			st.loop = nil
		end)
	elseif not enabled and st.loop then
		task.cancel(st.loop :: thread)
		st.loop = nil
	end
end

----------------------------------------------------------------
-- WINDUI (verified against WindUI 1.6.x official example)
----------------------------------------------------------------
local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

local Window = WindUI:CreateWindow({
	Title = "Pet Simulator 99  |  Space Mining Event",
	Folder = "SpaceMiningHub",
	Icon = "pickaxe",
	Theme = "Dark",
	Author = "Script made by Zodex",
	Size = UDim2.fromOffset(580, 460),
	OpenButton = {
		Title = "Space Mining Hub",
		CornerRadius = UDim.new(1, 0),
		Enabled = true, -- the reopen "square" after minimize/close
	},
})

-- Right Control reopens the UI (requirement: "press right Control -> opens UI")
Window:SetToggleKey(Enum.KeyCode.RightControl)

----------------------------------------------------------------
-- INFO (top tab) — script credit, server, Discord
-- ENCODING RULE (global): NEVER use \U{...} / \u{...} escapes in Luau strings.
-- Luau does not parse them (it only knows \n 	 \\ \" \ddd) and they render on
-- screen as literal "U{...}" garbage. Write real UTF-8 characters directly.
----------------------------------------------------------------
local INFO = {
	Author = "Script made by Zodex",
	ServerName = "AETOS",
	DiscordInvite = "discord.gg/YazKRj4hWa",
	DiscordUrl = "https://discord.gg/YazKRj4hWa",
}

local InfoTab = Window:Tab({ Title = "Info", Icon = "info" })

-- Card 1: script information
InfoTab:Paragraph({
	Title = "Space Mining Event Hub",
	Desc = "Pet Simulator 99 - Space Mining Event Hub.\nMining, merchant, and explosive systems.",
})

-- Card 2: script author
InfoTab:Paragraph({
	Title = "Script made by Zodex",
	Desc = "Script author and developer.",
})

-- Card 3: server
InfoTab:Paragraph({
	Title = "Server",
	Desc = INFO.ServerName,
})

-- Card 4: Discord server
InfoTab:Paragraph({
	Title = "Discord Server",
	Desc = INFO.DiscordInvite,
})
InfoTab:Button({
	Title = "Open Discord Server",
	Icon = "message-circle",
	IconAlign = "Left",
	Justify = "Center",
	Callback = function()
		pcall(setclipboard, INFO.DiscordUrl)
		WindUI:Notify({
			Title = "Discord Server",
			Content = INFO.DiscordInvite .. " (copied to clipboard)",
			Duration = 4,
			Icon = "message-circle",
		})
	end,
})

-- Card 5: reopen UI
InfoTab:Paragraph({
	Title = "Reopen UI",
	Desc = "Hotkey: Right Control\nPress Right Control or click the reopen button to show the UI again.",
})

----------------------------------------------------------------
-- TOPBAR SQUARES: yellow = minimize (reopenable), red = full close
----------------------------------------------------------------
local hubMinimize = function()
	Window:Close() -- minimizes; the OpenButton square + Right Control reopen it
end

local hubClose = function()
	-- full teardown: stop every loop, then destroy the window
	CFG.AutoMine = false
	CFG.AutoBuyBombs = false
	CFG.AntiAFK = false
	CFG.AutoHatch = false
	CFG.AutoClaimPickaxe = false
	CFG.AutoBuyZone = false
	pcall(function()
		for key in BombManager.State do
			BombManager.SetEnabled(key, false)
		end
	end)
	pcall(function()
		if mineThread then
			task.cancel(mineThread :: thread)
			mineThread = nil
		end
	end)
	Window:Destroy()
end

Window:CreateTopbarButton("Minimize", "minus", hubMinimize, 998, nil, Color3.fromHex("#f5c451"))
Window:CreateTopbarButton("Close", "x", hubClose, 999, nil, Color3.fromHex("#ff4830"))

-- Tab: EVENTS
local EventsTab = Window:Tab({ Title = "Events", Icon = "sparkles" })

EventsTab:Paragraph({
	Title = "Space Mining Event",
	Desc = "Status: checking...",
})

local statusPara = EventsTab:Paragraph({
	Title = "Current Status",
	Desc = "Idle",
})

EventsTab:Button({
	Title = "Join Space Mining Event",
	Icon = "log-in",
	Callback = function()
		local ok, msg = SM.JoinEvent()
		WindUI:Notify({ Title = "Space Mining", Content = msg, Duration = 3, Icon = "pickaxe" })
	end,
})

EventsTab:Toggle({
	Title = "Auto Mining",
	Value = false,
	Callback = function(v)
		SM.SetAutoMine(v)
	end,
})

EventsTab:Dropdown({
	Title = "Select Mining Method",
	Values = { "Nearest", "HighestValue", "Priority" },
	Value = "Nearest",
	Callback = function(v)
		CFG.MiningMethod = v
	end,
})

EventsTab:Dropdown({
	Title = "Special Ore Priority",
	Desc = "Highest To Lowest",
	Values = CFG.PriorityOrder,
	Multi = true,
	AllowNone = true,
	Callback = function(selected)
		-- rebuild priority order from multi-selection order
		if type(selected) == "table" then
			CFG.PriorityOrder = {}
			for _, name in ipairs(selected) do
				table.insert(CFG.PriorityOrder, name)
			end
		end
	end,
})

EventsTab:Slider({
	Title = "Wide Area Range",
	Value = { Min = 50, Max = 1000, Default = CFG.Range },
	Step = 10,
	Callback = function(v)
		CFG.Range = v
	end,
})

EventsTab:Dropdown({
	Title = "Blacklist Ores",
	Values = { "Amethyst Ore", "Emerald Ore", "Onyx Ore", "Quartz Ore", "Rainbow Ore", "Ruby Ore", "Sapphire Ore", "Topaz Ore" },
	Multi = true,
	AllowNone = true,
	Callback = function(selected)
		CFG.Blacklist = {}
		if type(selected) == "table" then
			for _, name in ipairs(selected) do
				CFG.Blacklist[name] = true
			end
		end
	end,
})

EventsTab:Toggle({
	Title = "Notifications",
	Value = true,
	Callback = function(v)
		notifyOn = v
	end,
})

-- Additional features section
local ExtraTab = Window:Tab({ Title = "Extras", Icon = "rocket" })

ExtraTab:Toggle({
	Title = "Auto Teleport to Best Zone",
	Value = false,
	Callback = function(v)
		CFG.AutoTeleport = v
	end,
})

ExtraTab:Toggle({
	Title = "Auto Hatch Best Egg",
	Value = false,
	Callback = function(v)
		CFG.AutoHatch = v
		if v then
			task.spawn(function()
				while STATE.alive() and CFG.AutoHatch do
					if SM.IsInEvent() then
						pcall(SM.HatchEgg, "Combine Egg", 1)
					end
					task.wait(3)
				end
			end)
		end
	end,
})

ExtraTab:Toggle({
	Title = "Auto Claim Pickaxe",
	Value = false,
	Callback = function(v)
		CFG.AutoClaimPickaxe = v
		if v then
			task.spawn(function()
				while STATE.alive() and CFG.AutoClaimPickaxe do
					pcall(SM.ClaimPickaxe, "Dark Matter Pickaxe")
					task.wait(5)
				end
			end)
		end
	end,
})

ExtraTab:Toggle({
	Title = "Auto Buy Next Zone",
	Value = false,
	Callback = function(v)
		CFG.AutoBuyZone = v
		if v then
			task.spawn(autoBuyZoneLoop)
		end
	end,
})

ExtraTab:Toggle({
	Title = "Anti-AFK",
	Desc = "Jumps every 5 min (VirtualInputManager Space key)",
	Value = false,
	Callback = function(v)
		CFG.AntiAFK = v
		if v then
			task.spawn(function()
				local VIM = game:GetService("VirtualInputManager")
				while STATE.alive() and CFG.AntiAFK do
					pcall(function()
						VIM:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
						task.wait(0.2)
						VIM:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
					end)
					task.wait(300)
				end
			end)
		end
	end,
})

ExtraTab:Toggle({
	Title = "Auto Buy Bombs (Merchant)",
	Value = false,
	Callback = function(v)
		CFG.AutoBuyBombs = v
		if v then
			SM.AutoBuyLoop()
		end
	end,
})

----------------------------------------------------------------
-- EXPLOSIVES TAB — every verified explosive: Auto toggle + repeat-timer slider
-- Order follows BombManager.Order (matches the reference screenshot sequence).
----------------------------------------------------------------
local BombsTab = Window:Tab({ Title = "Explosives", Icon = "bomb" })

BombsTab:Section({ Title = "💣 Explosives" })
BombsTab:Paragraph({
	Title = "Repeat-timer, not a power setting",
	Desc = "ON -> activate -> wait cooldown -> activate -> repeat. All 7 names verified against __DIRECTORY.Consumables (InventoryTags = Space Mining).",
})

for _, key in BombManager.Order do
	local def = BombManager.Bombs[key]
	BombsTab:Toggle({
		Title = "Auto " .. def.name,
		Desc = def.desc,
		Value = false,
		Callback = function(v)
			BombManager.SetEnabled(key, v)
		end,
	})
	BombsTab:Slider({
		Title = def.name .. " Cooldown",
		Value = { Min = 1, Max = 120, Default = 20 },
		Step = 1,
		Callback = function(v)
			BombManager.State[key].cooldown = v
		end,
	})
end

----------------------------------------------------------------
-- STATUS REFRESH LOOP
----------------------------------------------------------------
task.spawn(function()
	while STATE.alive() do
		if statusPara and statusPara.SetDesc then
			local inEvent = SM.IsInEvent()
			local ores = inEvent and SM.ScanOres() or {}
			local desc = string.format(
				"In Event: %s  |  Ores in range: %d  |  Method: %s  |  Range: %d",
				tostring(inEvent), #ores, CFG.MiningMethod, CFG.Range
			)
			pcall(function()
				statusPara:SetDesc(desc)
			end)
		end
		task.wait(1)
	end
end)

----------------------------------------------------------------
-- CLEANUP
----------------------------------------------------------------
STATE.onCleanup(function()
	CFG.AutoMine = false
	CFG.AutoBuyBombs = false
	CFG.AntiAFK = false
	CFG.AutoHatch = false
	CFG.AutoClaimPickaxe = false
	CFG.AutoBuyZone = false
	if mineThread then
		task.cancel(mineThread :: thread)
		mineThread = nil
	end
	for _, st in pairs(BombManager.State) do
		st.enabled = false
		if st.loop then
			pcall(task.cancel, st.loop)
			st.loop = nil
		end
	end
	pcall(function()
		Window:Destroy()
	end)
end)

print("[SpaceMiningHub] loaded — label 'space-mining'")
return { SM = SM, BombManager = BombManager, CFG = CFG }
