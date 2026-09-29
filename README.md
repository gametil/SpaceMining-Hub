# Space Mining Hub (PS99)

Space Mining Event automation for Pet Simulator 99 — WindUI hub with mining, merchant, and the 7 **data-verified** explosives.

## Quick start

```lua
loadstring(game:HttpGet('https://raw.githubusercontent.com/<owner>/SpaceMining-Hub/refs/heads/main/main.lua'))()
```

> Replace `<owner>` with the GitHub account this repo is pushed under.

## What it does

- **Events tab** — join Space Mining Event, auto mining (Nearest / HighestValue / Priority), ore blacklist, wide-area range, live status
- **Extras tab** — auto teleport to best zone, auto hatch, auto claim pickaxe, auto buy next zone, auto buy from the Space Mine Merchant (respect-gated slots)
- **Explosives tab** — per-explosive `Auto` toggle + `Cooldown` repeat-timer (activate → wait → repeat)

## Verified explosives (3 proofs)

`__DIRECTORY.Consumables` `InventoryTags={"Space Mining"}` + the game's own `ActionMenu.Consumable` whitelist + `Tiers[1].Desc`:

| Item | Merchant? | Effect |
|---|---|---|
| Big Bang | ✅ | mine-wide countdown → massive crater |
| Rover Charge | ✅ | leaps & slams 3× at your feet |
| Void Charge | ❌ drop | sucks rock in, then blows |
| Drill Array | ✅ | 5 shafts in an X (strip mining) |
| Core Charge | ✅ | bores 20 layers straight down |
| Breach Charge | ✅ | small blast, cracks rock above/below |
| Stardust Charge | ❌ drop | turns surrounding rock into solid ore |

Activation = the game's own `ConsumableCmds.Consume(ownedItem, 1)` → `Consumables_Consume` with the real owned UID.

## Notes

- `main.lua` is the standalone (loadstring) build — includes a `STATE` shim so it runs outside Real's live-reload.
- Cooldown is a repeat timer; no per-item cooldown exists in game data.
- For authorized debugging of games you own/develop only.

## Credits

UI: [WindUI](https://github.com/Footagesus/WindUI) · Remote names verified against decompiled game sources.
