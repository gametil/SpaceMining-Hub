# PS99 Hatch Wars Scripts

One-line description: auto boss fighter + event egg auto-hatcher for the "Hatch Wars" event in Pet Simulator 99 (placeId 8737899170).

## How to run
Paste either file into any Lua executor that supports Luau (Synapse, Wave, Real, etc.) while in the game, then execute. Re-executing a script stops its previous run (safe to restart).

## hatchwar_auto_boss.luau
- **What it does**: Auto-starts boss fights and instantly taps every fight circle ("Tap to hatch faster!" bars). Teleports to the boss first (server requires ~12 studs).
- **CONFIG options**:
  - TapsPerSecond: 12 (server counts up to 15/s)
  - MinWinChance: 0.5 (only auto-fight zones with at least this win chance)
  - PreferredZone: 0 (0 = auto pick; 1-4 = force that zone when available and affordable)
  - TargetBoss: 0 (0 = auto; 1-4 = force that zone's boss — aliases PreferredZone; useful for targeting a specific boss slot directly)
  - FightDelay: 3 (seconds to wait after a fight ends)
  - StartCooldown: 5 (seconds before retrying a refused fight start)
  - AutoJoin: true (teleport into Hatch Wars instance when outside)
  - LowChanceFallback: true (grind best affordable zone if no zone meets MinWinChance)
  - RespectGameAutoBattle: true (let game's AutoBattle start fights)
  - GameAutoGraceSeconds: 20 (start one ourselves if game auto starts nothing for 20s)
  - ComboBar: true (show fight combo progress bar)
  - StatusSeconds: 10 (progress print interval)
  - TeleportToBoss: true (tp next to picked boss before starting)
  - TeleportStuds: 12 (skip tp if already within this range)
  - TeleportWait: 1.0 (seconds to settle after teleporting)

## hatchwar_auto_hatch.luau
- **What it does**: Auto-hatches one of the four Hatch Wars event eggs (Ember, Spore, Graveyard, Witching) by teleporting next to it and keeping the game's Auto Hatch chain running.
- **CONFIG table**:
  - Egg: "Ember Egg" (egg name or "" to stop)
  - AutoJoin: true (teleport into Hatch Wars instance when outside)
  - TeleportToEgg: true (tp next to the egg)
  - TeleportStuds: 13 (skip tp if already within 13 studs)
  - TeleportWait: 0.6 (seconds to settle after teleporting)
  - RestartDelay: 2 (retry pause after failure)
  - NoCoinsDelay: 10 (wait this long when broke)
  - StatusSeconds: 10 (progress print interval)

**Note**: Witching Egg may reply "You don't have permission to hatch this!" until you progress the event — the script stops and tells you instead of spamming retries.

## Important
Do NOT run both scripts at the same time — they teleport your character to different spots on the same strip (bosses vs eggs) and will fight over position. Pick one.

## Disclaimer
Educational/use at your own risk; scripts only interact through the game's own client APIs and remotes. No warranties given.