# PS99 Hatch Wars Scripts

Auto boss fighter + event egg auto-hatcher for the "Hatch Wars" event in Pet Simulator 99 (placeId 8737899170).

## How to run (one line)

```lua
loadstring(game:HttpGet('https://raw.githubusercontent.com/gametil/kaila-mastan-jontro-pati/refs/heads/main/main.lua'))()
```

Edit the top of `main.lua` before running:

- `TARGET = "boss"` or `"hatch"` (do not run both at once - they move your character to different spots)
- `SELECTED_BOSS = 0..4` (boss script only): which boss(es) to fight - forces the UI's boss toggles on load
  - `0` = leave the saved toggle selection as-is (default: every boss on, cycle picks highest unlocked / best fightable)
  - `1..4` = only that boss's toggle on (strict target)
  - `1` = Ember IBZ (Ember Cliffs)
  - `2` = Spore Lulu (Spore Forest)
  - `3` = Ghoul Aussie (Green Graveyard)
  - `4` = Warlock Ahmad (Witching Hour)

## hatchwar_auto_boss.luau

- **Cycle**: reads the target boss's own requirements (coins + recommended luck), fights only while your luck is at/above that recommendation, and when you drop below it farms Lucky Orbs - then returns to the SAME target boss. Wins/losses, luck and orb progress print on a status line.
- **In-game UI (Maclib window)**: press `RightControl` to show/hide. One toggle per boss (1 Ember IBZ / 2 Spore Lulu / 3 Ghoul Aussie / 4 Warlock Ahmad): enable exactly one for a strict target, several to rotate between them, none to pause the fights - plus a Lock-target toggle and everything live: auto fight, auto farm, auto taps, boss teleport, tap rate and luck gate sliders, and a live status panel (state, selected bosses, target, luck vs requirement, orbs, coins, wins, taps). Settings auto-save; if Maclib fails to load, the automation keeps running headless.
- **Farming walks, never teleports**: the character runs to the nearest Lucky Orb with normal `Humanoid:MoveTo` walking (auto-jump if stuck); the game's proximity pickup collects them, so the server only ever sees regular movement. The single exception is one short teleport next to the boss right before a fight (server refuses starts from far away) - set `TeleportToBoss = false` to disable it and walk there instead.
- **Tapping**: pops every fight circle at 12 taps/s (server cap 15/s) for the whole fight; the combo progress bar shows like a normal player's.
- **Key CONFIG**:
  - TapsPerSecond: 12
  - MinWinChance: 0.5 (fallback auto-pick only accepts zones with at least this chance)
  - TargetBoss / PreferredZone: 0 (0 = auto; 1-4 = force that boss; set by the loader's SELECTED_BOSS)
  - LockTarget: true (keep the same target boss unless it becomes unavailable)
  - MinLuckFactor: 1.0 (fight while luck >= factor x the boss's recommended luck)
  - AutoGrindCycle: true (fight -> luck low -> farm orbs -> fight again)
  - AutoFight: true (start fights automatically; false = pause after the current one)
  - TapsEnabled: true (tap fight circles automatically)
  - TeleportToBoss: true (short tp next to the boss before starting)
  - AutoJoin: true (enter the Hatch Wars instance when outside)
  - StatusSeconds: 10 / GrindLogSeconds: 6 (print intervals)
  - FightDelay: 3, StartCooldown: 5, ComboBar: true

## hatchwar_auto_hatch.luau

- **What it does**: auto-hatches the four Hatch Wars event eggs (Ember, Spore, Graveyard, Witching) by teleporting next to them (server needs ~15 studs) and keeping the game's Auto Hatch chain running - enable one egg, several to rotate between them, or none to stop.
- **In-game UI (Maclib window)**: press `RightControl` to show/hide. One toggle per event egg (Ember / Spore / Graveyard / Witching): enable exactly one for a strict egg, several to rotate between them (each stays until its arm quota or it goes missing, then the next enabled egg is picked), none to stop. Toggles for auto join and egg teleport, sliders for retry delays, and a live status panel (enabled eggs, active egg, hatching, hatched count, coins, arms, last error). A permission-locked egg no longer kills the script - single-egg mode blocks and shows it in the status, cycle mode skips it. Settings auto-save; if Maclib fails to load, hatching keeps running headless.
- **CONFIG**: Egg (a name = that egg only / "" or "all" = every event egg on / "none" = stop, all seeded from the UI toggles), AutoArmsPerEgg (rotates after N arms in cycle mode), AutoJoin, TeleportToEgg, TeleportStuds, TeleportWait, RestartDelay, NoCoinsDelay, StatusSeconds.

**Note**: the Witching Egg may reply "You don't have permission to hatch this!" until you progress the event - single-egg mode stops and tells you, cycle mode skips it and moves to the next enabled event egg instead of spamming retries.

## Important

Do NOT run both scripts at the same time - they use the same character for different spots (bosses vs eggs). Pick one.

## Disclaimer

Educational/use at your own risk; scripts only interact through the game's own client APIs and remotes. No warranties given.
