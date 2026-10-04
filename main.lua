-- PS99 Hatch Wars Scripts - loader / entry point
-- Stable URL: loadstring(game:HttpGet('https://raw.githubusercontent.com/gametil/kaila-mastan-jontro-pati/refs/heads/main/main.lua'))()
-- Pick which script to load below, then execute this file.

local TARGET = "hatch" -- "hatch" = event egg auto-hatcher | "boss" = auto boss fighter
                       -- (do not run both at once: they move the character to different spots)

-- Which boss(es) to fight (only used when TARGET = "boss"; forces the UI's boss toggles on load):
-- 0 = leave the saved toggle selection as-is (default: all bosses on, cycle picks the best)
-- 1-4 = only that boss's toggle on (strict target)
-- 1 = Ember IBZ     (Ember Cliffs)
-- 2 = Spore Lulu    (Spore Forest)
-- 3 = Ghoul Aussie  (Green Graveyard)
-- 4 = Warlock Ahmad (Witching Hour)
local SELECTED_BOSS = 0

local BASE = "https://raw.githubusercontent.com/gametil/kaila-mastan-jontro-pati/refs/heads/main/"
local FILES = {
	hatch = "hatchwar_auto_hatch.luau",
	boss = "hatchwar_auto_boss.luau",
}

local file = FILES[TARGET]
if not file then
	error("[Loader] TARGET must be \"hatch\" or \"boss\" (got " .. tostring(TARGET) .. ")")
end

-- hand the boss choice to the boss script before it loads (0 = auto)
getgenv().HatchWarConfig = { TargetBoss = SELECTED_BOSS, PreferredZone = SELECTED_BOSS }

print("[Loader] loading " .. file .. (TARGET == "boss" and (" (selected boss " .. SELECTED_BOSS .. ")") or "") .. " ...")
loadstring(game:HttpGet(BASE .. file))()
