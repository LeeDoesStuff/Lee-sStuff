# Lee's scripts

Scripts for Roblox games. Paste a loadstring into your executor; every box has a copy button in its top-right corner.

## Loader

[CruelHub's loader](https://github.com/LeeDoesStuff/LuaLoader) asks for a key, then runs the right script for whatever game you're in (Fix It Up loads the main farm, not the hopper).
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/LuaLoader/main/loader.lua"))()
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

### [Pixel Conquest](pixel-conquest/)
A full-match bot for the OpenFront-style territory game, one tab per system:
- **Expand:** smart spawn far from everyone, auto expand that holds troops in the fastest-growth band, boats to open islands, and retaking land that was nuked out of your territory.
- **Combat:** attacks the weakest neighbour (by land or by boat across water), a sea siege that charges up and lands 3-boat salvos on island rivals, counterattacks sized to cancel incoming attacks 1:1 (and invade when you can afford it), revenge only when you're stronger, and a last stand (nuke, defense post, reinforce, ally request) when you can't hold.
- **Build:** cities (upgraded in place), ports, defense posts on attacked borders, artillery, airfields and railguns, with a gold reserve.
- **Weapons:** auto nukes on the biggest enemy's city cluster, revenge nukes on whoever nukes you, an anti-nuke manager that covers your best cities before nukes fly, airstrikes and railgun on cooldown.
- **Diplomacy and lobby:** auto accept and renew alliances (breaking them is blocked), auto queue, leave and requeue, the free reward, and buying passes with Money.

It uses the game's own ATTACK SIZE slider and blocks the game's Robux prompts.

💕 Built with love (and a very supportive AI girlfriend).
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/pixel-conquest/pc_main.lua"))()
```

### [Fix It Up!](fix-it-up/)
A flip farm with one menu tab for each part of the game:
- **Junkyard:** tier and spawn-% ESP on every junk car, a clickable list with one-click Buy, rare-spawn alerts, and a lookup for any car's rarity, engines, cost and profit.
- **Auto:** a buy → repair → sell loop that buys by tier or by spawn %, with a price cap, a minimum profit and a money reserve. It can clean and paint after each repair and tracks real profit (buy price and parts taken off). A Home spot of your choosing is where you're sent back after anything that teleports you.
- **Garage:** repair at the quietest of 4 shops, plus sell, refuel, clean and paint from anywhere, with a sell-timer tag over the picked car. Favorites are locked and never sold, and rare buys can lock themselves by tier or by spawn %.
- **Parts:** the parts shop and tools, engine and gearbox swaps, and car-to-car part moves, tires included.
- **Drive:** shows the distance you owe for the cars you've sold, plus a highway farm that pays it off (or runs with no limit) and pauses for auto flips.
- **Players, Gold, Teleport:** player ESP with titles over their cars, a garage viewer, a gold price readout with buy contracts, and teleports to every shop, garage and player.
- **Server hop:** hops until the other players have sold few cars, with a hard block for big sellers. Anti-mod leaves (or hops) the moment anyone ranked above Member in the game's group joins, and a live list shows where every staff member is.

Settings save automatically, and only cars the script bought are ever sold.
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LeeDoesStuff/Lee-sStuff/main/fix-it-up/fiu_main.lua"))()
```
*After a server hop it reloads from your executor's workspace folder, so to keep it across hops save it there as `fiu_main.lua` and start it with `loadstring(readfile("fiu_main.lua"))()`.*

### [Fix It Up! server hopper](fix-it-up/) · parked
Hops public servers until every other player has fewer than N Cars Sold. This is the standalone version of the main script's Server hop tab; the main script closes it if both are running.
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
