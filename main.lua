-- PS99 Hatch Wars Scripts - loader / entry point
-- Stable URL: loadstring(game:HttpGet('https://raw.githubusercontent.com/gametil/SpaceMining-Hub/refs/heads/main/main.lua'))()
-- Pick which script to load below, then execute this file.

local TARGET = "hatch" -- "hatch" = event egg auto-hatcher | "boss" = auto boss fighter
                       -- (do not run both at once: they teleport the character to different spots)

local BASE = "https://raw.githubusercontent.com/gametil/SpaceMining-Hub/refs/heads/main/"
local FILES = {
	hatch = "hatchwar_auto_hatch.luau",
	boss = "hatchwar_auto_boss.luau",
}

local file = FILES[TARGET]
if not file then
	error("[Loader] TARGET must be \"hatch\" or \"boss\" (got " .. tostring(TARGET) .. ")")
end

print("[Loader] loading " .. file .. " ...")
loadstring(game:HttpGet(BASE .. file))()
