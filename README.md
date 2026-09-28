# Lee's scripts

Scripts for Roblox games. Paste a loadstring into your executor; every box has a copy button in its top-right corner.

## Loader

Runs the right script for whatever game you're in (Fix It Up loads the main farm, not the hopper).
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/loader.lua"))()
```

## My scripts

Each title links to the game's folder, which holds the notes and spec behind the script. The menus use the Obsidian UI: **RightCtrl** shows and hides them.

### [Build A Battle Bot](build-a-battle-bot/)
Auto farm: Depths runs, Pit events, crates and parts, plot upgrades (including the ×10 bulk button), skills, rebirths, scrap and the Alien Raid crate catcher.
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/build-a-battle-bot/bbb_farm.lua"))()
```

### [Warfare](warfare/)
Drone HUD: drop and impact predictor, blast rings, enemy aim cones with a WATCHED warning, a body guard and enemy drone alerts.
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/warfare/warfare_hud.lua"))()
```

### [Hit The Thrift](hit-the-thrift/)
Rarity ESP on every rack, shelf and display, a Finds list, auto Matcha, laundry pods and washer bubbles, plus MRKET packing and delivery (those two aren't tested live yet).
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/hit-the-thrift/thrift_esp.lua"))()
```

### [Command An Army](command-an-army/) · v1, untested
Daily rewards, quests, codes, banner summons, ascension and evolution, equip best, the match flow (map vote, team pick, respawns) and army orders.
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/command-an-army/caa_farm.lua"))()
```

### [Fix It Up!](fix-it-up/) · parked
Junkyard car tiers with ESP, auto buy → repair → sell, garage tools, the shop and teleports. Favorited cars are never sold.
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/fix-it-up/fiu_main.lua"))()
```
*After a server hop it reloads from your executor's workspace folder, so to keep it across hops save it there as `fiu_main.lua` and start it with `loadstring(readfile("fiu_main.lua"))()`.*

### [Fix It Up! server hopper](fix-it-up/) · parked
Hops public servers until every other player has fewer than N Cars Sold.
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/fix-it-up/fiu_hop.lua"))()
```
*It reloads itself from the workspace folder after each hop: save it as `fiu_hop.lua` and start it with `loadstring(readfile("fiu_hop.lua"))()`.*

### [Sneaker Resell Simulator](sneaker-resell-simulator/) · parked
Sneaker Panel v2: works out which sell channel pays (cashier at 0.55× or the NPC bar minigame at up to 1.10×) before it buys, then handles buying, selling, slots, trades, the market and boxes.
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/sneaker-resell-simulator/panel_v2.lua"))()
```
*Re-arming after a server hop needs a workspace copy saved as `panel_v2.lua`.*

### [Needle in a Haystack](needle-in-a-haystack/) · parked
Recreates the Sell On Drop gamepass: carries each load to the vent's pay spot.
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/needle-in-a-haystack/needle_selldrop.lua"))()
```

### [Mog or Die](mog-or-die/) · parked
Collection, plot and crate helpers.
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/mog-or-die/mog_auto.lua"))()
```

## Other people's scripts

Not mine: obfuscated (MoonSec) scripts from 2022, kept as they were. They may no longer work.

### Infinite Yield (repack)
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/inf%20yeild.lua"))()
```
The official, current Infinite Yield:
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/EdgeIY/infiniteyield/master/source"))()
```

### A One Piece Game
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/a%20one%20piece%20game.lua"))()
```

### Baki (LazyHub)
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/baki%20lazyhub.lua"))()
```

### Prison Life
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/prison%20life%20script.lua"))()
```

### YBA (Kolgie)
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/yba%20kolgie.lua"))()
```

### YBA (Xenon)
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/yba%20xenon.lua"))()
```

### shitpoststatus
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/shitpoststatus.lua"))()
```

## Notes

Cross-game notes: the [recon checklist](notes/game-recon-checklist.md), the [Infinite Yield guide](notes/infinite-yield.md) and the [Potassium bridge quirks](notes/potassium-bridge-quirks.md).
