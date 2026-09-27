<title>Infinite Yield Guide</title>

# Infinite Yield — field guide for recon and farms

Infinite Yield (IY) **6.4.2**, [EdgeIY/infiniteyield](https://github.com/EdgeIY/infiniteyield), MIT license, **434 commands**. Checked 2026-09-26 against the live source and against a running copy in Build A Battle Bot. This is a working reference: what each command is good for when **reverse-engineering a game or running a farm**, how to **drive IY from our own scripts**, **where earlier projects should have used it**, and **the trade-offs of leaning on it**.

---

## 0. Your setup

| Piece | Where | What it does |
|---|---|---|
| Loader | `Potassium\autoexec\iy.lua` | `loadstring(game:HttpGet(".../EdgeIY/infiniteyield/master/source"))()`: **latest master on every join** |
| Settings | `Potassium\workspace\IY_FE.iy` (JSON) | prefix `;` · binds **X → `togglexray`**, **Z → `noclip`** (toggle) · event binds **OnExecute → `antiafk`, `autorj`** · `keepiy` on · `PluginsTable` · waypoints · aliases |
| Repo copy | `Lee-sStuff/inf yeild.lua` | ⚠️ a **MoonSec-obfuscated repack**, not the official source. It can't be audited; don't run it. Your autoexec uses the official one. |

`IY_LOADED` is set in `getgenv()` once IY runs; a second load exits early unless `_G.IY_DEBUG`.

---

## 1. Using IY

**Entry points:** the command bar (press the prefix `;`), chat (`;fly`), keybinds (Settings → Keybinds), event binds, and plugins.

**Command-string syntax** (parsed by IY's `execCmd`):

| Syntax | Meaning | Example |
|---|---|---|
| `a\b` | run several commands; `\\` is a literal backslash | `noclip\fly 60` |
| `N^cmd` | repeat N times | `5^jump` |
| `N^d^cmd` | repeat N times, `d` seconds apart | `10^0.5^thru 5` |
| `inf^d^cmd` | loop forever (default 1 s) until **`breakloops`** | `inf^30^notifyping` |
| `!cmd` | rerun `cmd` with its last arguments | `!goto` |
| `lastcmd` | rerun the previous command line | |

Commands run in `task.spawn`: **fire-and-forget, with no return value to your code**.

**Player selectors** (any `[player]` argument, comma-separated): `me` · `all` · `others` · `random` · `nearest` · `farthest` · `team` · `nonteam` · `allies` · `enemies` · `friends` · `nonfriends` · `guests` · `bacons` · `alive` · `dead` · `cursor` · `npcs` · `#N` (N random) · `%teamname` · `rad<N>` (within N studs) · `age<N>` (account age in days) · `group<id>` · partial names.

**Persistence:**
- **Waypoints** are saved per game.
- **Aliases** (`addalias fly f`).
- **Keybinds** (tap/hold, toggle pairs).
- **Event binds:** run a command on `OnSpawn / OnDied / OnDamage / OnKilled / OnJoin / OnLeave / OnChatted / OnExecute`.
- **Plugins** are `<name>.iy` files in the workspace.
- `keepiy` re-executes IY after a teleport.

**Plugin file format** (IY `loadfile`s it):

```lua
return {
    PluginName = "My Tools",
    PluginDescription = "what it adds",
    Commands = {
        mycmd = {
            ListName = "mycmd [arg]",
            Description = "what it does",
            Aliases = { "mc" },
            Function = function(args, speaker) --[[ runs in the plugin's own environment ]] end,
        },
    },
}
```

Load with `;addplugin <name>` (saved to `PluginsTable`, so it auto-loads next session) and remove with `;removeplugin <name>`.

---

## 2. Driving IY from our own scripts (verified live)

**IY's functions aren't reachable from other scripts.** Its "global" `execCmd`, `notify`, `getRoot` and `getPlayer` live in IY's own script environment. From a separate Potassium script they read as `nil`, both as plain globals and in `getgenv()` / `_G`.

A plugin can't get at them either. A bridge plugin that tried to export `execCmd` loaded, but saw `nil`: plugin chunks get their own environment too. So plugins can **add** IY commands, but they can't **call** IY internals.

**What works is IY's own command bar.** Its `FocusLost(enterPressed)` handler calls `execCmd`, so setting the text and firing that handler runs any command through IY's own code. This was verified by adding and then removing a plugin through it (the change showed up in `IY_FE.iy`):

```lua
-- Run any Infinite Yield command from another script via IY's command-bar handler.
local function iy(cmd)
    local root = gethui and gethui() or game:GetService("CoreGui")   -- Potassium: gethui() = CoreGui.RobloxGui
    local bar = root:FindFirstChild("Cmdbar", true)                   -- live build: Frame "Cmdbar" > TextBox "Input"
    local input = bar and (bar:IsA("TextBox") and bar or bar:FindFirstChildWhichIsA("TextBox"))
    if not (input and getconnections) then return false end           -- IY not loaded / hidden
    input.Text = cmd                                                  -- no prefix needed
    for _, c in ipairs(getconnections(input.FocusLost)) do c:Fire(true) end
    return true
end

iy("antiafk\\noprompts\\staffwatch")      -- chain with "\\" inside Lua strings
iy("inf^60^clearerror")
```

Live structure differs from the source. The published source makes `Cmdbar` a bare TextBox, but the running build wraps it in a `Cmdbar` Frame with an `Input` TextBox. The helper handles both. Expect this to drift; see the trade-offs.

**Vendoring (MIT):** when you need IY *logic* inside a loop (e.g. its server-hop list handling), copy the specific function into our script with the MIT notice. You get no runtime dependency and no command-bar coupling.

---

## 3. Command catalog, rated for recon/farm utility

★★★ use routinely · ★★ situational · ★ niche · ⚠️ replicates, is visible to others, or is risky · (C) client-only (does not replicate)

### 3.1 Recon and inspection ★★★

| Command | Use |
|---|---|
| `explorer` / `dex` · `moondex` / `mdex` | Browse the live instance tree: services, attributes, values, scripts. The fastest way to get oriented in a new game. |
| `remotespy` / `rspy` (Cobalt) | Intercepts **incoming and outgoing** remote traffic with arguments. Answers "what does this button send?" in seconds. |
| `simplespy` / `sspy` (SimpleSpy V3) | Client → server calls only, and it generates call code you can replay. |
| `savegame` / `saveplace` | `saveinstance` of the whole place, to grep offline in Studio. A full-map alternative to per-script decompile dumps. |
| `partname` / `partpath` | Click a part to get its full path and name. |
| `notifyposition` / `copyposition [plr]` | Exact coordinates (e.g. a sell spot or a sign). |
| `partesp [name]` · `esp` · `chams` · `locate` | Highlight parts or players by name (e.g. `partesp Material_Bolt`). |
| `xray` / `togglexray` · `invisibleparts` (C) | See through walls; show hidden trigger volumes. |
| `hitboxes` | Show rendered bounding boxes (hit, capture and trigger zones). |
| `freecam` · `viewpart` · `spectate [plr]` | Watch a zone or player without moving your character. |
| `console` · `serverinfo` · `jobid` · `notifyjobid` · `creatorid` · `copyplaceid` · `copygameid` | Server and game identifiers. |
| `audiologger` | Log sound ids. |
| `chatlogs` · `joinlogs` · `logs` · `logswebhook [url]` | Record chat and joins (the webhook sends them out; mind privacy). |

### 3.2 Session, server and AFK safety ★★★

| Command | Use |
|---|---|
| `antiafk` / `antiidle` | Stop the 20-minute idle kick (**already in your OnExecute binds**). |
| `autorejoin` / `autorj` | Rejoin after a kick or disconnect (**already bound**). Farm scripts must re-execute themselves after the rejoin. |
| `rejoin` / `rj` · `serverhop` / `shop` · `gameteleport [placeId]` | Server movement. `serverhop` is random. |
| `keepiy` | Re-run IY after a teleport. |
| `staffwatch` · `rolewatch [group] [role]` · `rolewatchleave` | Notify, or leave, when staff or a group role joins. **The top safety net for AFK farming.** |
| `noprompts` / `showprompts` | Block purchase and premium prompts (no accidental Robux popups while a farm clicks things). |
| `clearerror` · `antigameplaypaused` | Clear the kick blur and the "gameplay paused" box during long sessions. |
| `clientantikick` / `antikick` (C) · `antiteleport` (C) · `allowrejoin` · `cancelteleport` | Block **localscript** kicks and teleports. Server kicks still land. |
| `datalimit [kbps]` · `replicationlag [n]` | Network shaping (can desync you; testing only). |
| `findfriendgroups` | Who on the server is friends with whom (spot alt or staff clusters). |

### 3.3 Performance for long sessions ★★

`antilag` / `boostfps` / `lowgraphics` · `norender` / `render` (turns 3D rendering off entirely, a big CPU saving for multi-client AFK) · `volume [0-10]` · `hideguis` / `showguis` · `hideiy` / `showiy` · `use2022materials` · `togglefullscreen` · `screenshot` · `record`

### 3.4 Movement ★★

| Command | Use / note |
|---|---|
| `noclip` / `clip` | Walk through walls (your **Z** bind). The client moves freely, but server position checks still apply. |
| `fly [speed]` · `cframefly` / `cfly` · `vehiclefly` / `vfly` · `flyspeed` · `qefly` | Flight. `cfly` bypasses some anti-cheats; works on mobile. |
| `tpwalk [n]` | Teleport-steps in your move direction. It's *stepped* movement, the kind that survived Needle in a Haystack's force-drop check. |
| `speed` / `ws` · `loopspeed` · `spoofspeed` · `jumppower` · `loopjp` · `spoofjp` · `hipheight` · `gravity` (C) · `maxslopeangle` | Humanoid tuning. Spoof variants fake the value that client checks read. |
| `infjump` · `flyjump` · `autojump` · `edgejump` · `float` / `platform` · `swim` · `wallwalk` · `walltp` · `antivoid` | Traversal helpers. |
| `vehiclenoclip` · `vehicleclip` | Vehicle collisions. |

### 3.5 Teleport and navigation ★★★

| Command | Use / note |
|---|---|
| `tpposition` / `tppos X Y Z` · `tweentpposition` / `ttppos` · `offset` · `tweenoffset` · `thru [n]` | Coordinate moves. **Tween** variants move gradually, which can matter for anti-teleport and carried-item force-drops. |
| `goto` · `tweengoto` · `vehiclegoto` · `loopgoto [plr] [dist] [delay]` · `pulsetp [plr] [secs]` | Move to players. |
| `gotopart` · `tweengotopart` · `gotopartclass` · `gotomodel` · `tweengotomodel` · `gotopartdelay` | **Visit every part or model with a name**, e.g. `gotopart Material_Bolt` sweeps scrap-like pickups. |
| `walktoposition` · `walkto` / `follow` · `pathfindwalkto` · `pathfindwalktowaypoint` | Legit-looking walking. |
| `setwaypoint` / `swp` · `waypointpos` / `wpp` · `waypoint` / `wp` · `tweenwaypoint` / `twp` · `walktowaypoint` / `wtwp` · `showwp` / `hidewp` · `deletewaypoint` · `clearwaypoints` · `cleargamewaypoints` | **Named spots saved per game**: sell spots, sign pads, farm corners. |
| `clickteleport` (keybind) · `mouseteleport` / `mousetp` · `teleporttool` / `tptool` · `gotocamera` / `tgotocam` | Manual positioning. |
| `spawnpoint` · `nospawnpoint` · `flashback` / `diedtp` · `fakeout` | Respawn control. |

### 3.6 World interaction ★★★ (blunt, so read the notes)

| Command | Use / note |
|---|---|
| `fireproximityprompts` / `firepp [name]` · `noproximitypromptlimits` / `nopplimits` · `instantproximityprompts` / `instantpp` | Trigger prompts. ⚠️ With no name it fires **every** prompt (purchases, garage entries…). `nopplimits` only changes the client limit, **not the server range check**. |
| `fireclickdetectors` / `firecd [name]` · `noclickdetectorlimits` | Same idea for ClickDetectors. |
| `firetouchinterests` / `touchinterests [name]` | Fire TouchInterests (touch pads, tycoon buttons, collectors). |
| `bringpart` · `bringpartclass` (C) · `tpunanchored` / `tpua` ⚠️ · `freezeua` · `thawua` | Move parts. Client-side unless you own the network. |
| `delete` · `deleteclass` (C) · `deleteinvisparts` (C) · `clickdelete` · `lockworkspace` · `removeterrain` · `clearnilinstances` · `destroyheight` | Clear blockers locally (e.g. invisible walls in your way). |
| `btools` (C) · `f3x` (C) | Local building tools, handy for measuring. |

### 3.7 Character and state ★

`reset` · `respawn` · `refresh` / `re` · `god` ⚠️ · `invisible` / `visible` · `toolinvisible` · `sit` · `lay` · `sitwalk` · `nosit` · `jump` · `platformstand` / `stun` · `norotate` · `enablestate` / `disablestate [StateType]` · `team` (C) · `breakvelocity` · `deletevelocity` / `removeforces` · `weaken` / `strengthen` · `spin` · `anchor` / `unanchor` · `freezeanims` · `nilchar` · `noroot` / `replaceroot` · `trip` · `promptr6` / `promptr15` · appearance: `noarms` · `nolegs` · `nolimbs` · `naked` (C) · `noface` · `blockhead` · `blockhats` · `blocktool` · `creeper` · `drophats` · `nohats` · `hatspin` · `clearhats` · `chardelete` · `chardeleteclass` · `clearcharappearance` · `split`

### 3.8 Tools ★★

`tools` (copy tools from ReplicatedStorage/Lighting) · `grabtools` (auto-grab dropped tools) · `equiptools` · `unequiptools` · `usetools [n] [delay]` (activate everything) · `reach` · `boxreach` · `grippos` · `droptools` · `droppabletools` · `copytools` (C) · `dupetools` · `notools` · `deleteselectedtool` · `removespecifictool` · `handlekill` ⚠️

### 3.9 Input automation ★★

`autoclick [click] [release]` · `autokeypress [key] [down] [up]` · `hovername` · `mousesensitivity`. These are the **VirtualInput-style last resort** for games that only react to real input, after remotes, prompts and touches have failed.

### 3.10 Players, camera, chat ★

- **Camera:** `spectate` · `freecam` family · `firstp` / `thirdp` · `noclipcam` · `maxzoom` / `minzoom` · `camdistance` · `fov` · `fixcam` · `enableshiftlock` · `lookat`
- **Player info:** `inspect` · `age` · `joindate` · `userid` · `copyname` · `appearanceid` · `follow` · `orbit` · `stareat` · `friend` / `unfriend`
- **Chat and voice:** `chat` ⚠️ · `spam` ⚠️ · `whisper` ⚠️ · `pmspam` ⚠️ · `bubblechat` · `chatwindow` · `darkchat` · `listento` · `muteallvcs` · `mutevc` · `phonebook`
- **Lighting (C):** `fullbright` · `loopfullbright` · `ambient` · `day` / `night` · `nofog` · `brightness` · `globalshadows` · `light` · `restorelighting`

### 3.11 Trolling (no farm value; ⚠️ visible or reportable)

`fling` · `walkfling` · `flyfling` · `invisfling` · `antifling` (defensive, ★★ in PvP zones) · `loopoof` · `bang` · `jerk` · `carpet` · `headsit` · `scare` · `clientbring` / `loopbring` · `freeze` / `thaw` (C) · `hitbox` / `headsize` ⚠️ · `muteboombox`

### 3.12 Meta

`addalias` · `removealias` · `clraliases` · `addplugin` · `removeplugin` · `reloadplugin` · `addallplugins` · `breakloops` · `lastcmd` · `removecmd` · `guiscale` · `notify [text]` · `notifyping` · `enable` / `disable [coregui item]` · `alignmentkeys` · `ctrllock` · `exit` · `discord`

---

## 4. Retrospective: where I should have used IY

| Situation (project) | What I built | IY would have given | Verdict |
|---|---|---|---|
| Getting oriented in a new game (every project) | 7 hand-written tree-dump scripts written to files | `dex` for interactive browsing plus `savegame` for a full offline copy | **Should have started with `dex`.** File dumps still earn their keep for grep-able text, but orientation would have taken minutes. |
| Learning remote argument shapes (Battle Bot) | A custom `__namecall` spy and an `OnClientEvent` logger to file | `rspy` (Cobalt: in + out) and `sspy` (replayable call code) | **Should have used `rspy` for the first look.** My file logger was still right for **long, unattended** capture and for tagging GAME vs ME, which Cobalt's UI doesn't give me. |
| Finding exact spots (Needle sell spot, Battle Bot scrapper mouth and pads) | Coordinate probe scripts | `copypos`, `partname`, and `swp`/`wp` waypoints saved per game | **Should have used them.** They're faster, and waypoints persist per game. |
| Seeing where pickups hide (scrap on ledges) | Printing positions | `partesp Material_Bolt`, `xray` | **Should have used them** for recon. |
| Anti-AFK in `bbb_farm.lua` | A `VirtualUser` `Idled` handler | `antiafk`, already in your OnExecute binds | **Duplicate.** Keeping ours keeps the farm self-contained, but it could defer to IY. |
| Surviving kicks and rejoins | Nothing; the farm dies on rejoin | `autorj` is already on, but IY can't re-run *our* script | **Gap.** The farm needs its own autoexec or `queue_on_teleport`. |
| Server hopping (`fiu_hop.lua`) | A custom hopper filtering by players' stats, with 429 handling | `serverhop` is random | **Custom was justified.** IY's hop-list code could have been vendored (MIT) for the teleport part. |
| Teleport sweeps (scrap, sign pads) | Direct `HRP.CFrame` sets in loops | `gotopart`, `tpposition` | **Ours was right.** Loops need synchronous moves and completion checks, and `execCmd` is fire-and-forget. |
| Firing prompts (fabricator, station pads) | `fireproximityprompt`, then `PlotSignRemote` | `firepp`, `nopplimits`, `instantpp` | **IY would not have helped.** The server range check and the camera-facing gate beat client limits, and bare `firepp` fires *every* prompt, including purchases. |
| AFK safety for the farm | Nothing | `staffwatch` or `rolewatchleave`, `noprompts`, `clearerror`, `antilag` / `norender` | **Was a gap; fixed.** `bbb_farm.lua` → Settings → "Infinite Yield" now has an *AFK safety bundle* toggle (`staffwatch\noprompts\clearerror`) and *Stop 3D rendering* (`norender`/`render`), both through the §2 driver. |
| Measuring anti-teleport tolerance (Needle) | Hand-tuned stepped mover | `tpwalk`, `tweentpposition` with `tweenspeed` | **Would have sped up testing** of safe step sizes and speeds. |

**The pattern:** IY is excellent for **recon and safety**, and worse than bespoke code for **core farm loops**. Those need determinism, return values and game-specific server rules.

---

## 5. Trade-offs of using IY's code

| Trade-off | Detail | Mitigation |
|---|---|---|
| **Environment isolation** | Other scripts can't call IY functions; even plugins can't reach its internals. | Use the command-bar driver (§2) for commands, or vendor functions (MIT). |
| **UI-internal coupling** | The driver depends on IY's GUI shape, and the live build already differs from the published source (Frame + `Input` vs a bare TextBox). | Find it by `FindFirstChild("Cmdbar", true)` plus the first TextBox. Fail soft (`return false`) and log it. |
| **No completion or return** | `execCmd` spawns and forgets. You can't await a `goto` or read a result. | Use IY for fire-and-forget toggles; keep loops that need confirmation in our own code. |
| **Global loop state** | `breakloops` stops **every** IY command loop, yours and the player's. | Avoid `inf^` loops in farms, or own the loop yourself. |
| **Persistent toggles collide with farms** | `noclip`, `fly`, `tpwalk`, `walkfling` change physics under our teleports, and your **Z**/**X** binds can toggle them mid-run. | Turn movement toggles off before a farm starts: `iy("clip\\unfly")`. |
| **Always-latest remote code** | Autoexec pulls `master` every join (last pushed 2026-09-25), so a bad commit or repo compromise runs with executor rights. A hung `HttpGet` also stalled our executor queue once. | Pin a reviewed copy in the workspace (as we did for Obsidian) and `readfile` it. |
| **Unauditable repacks** | The repo's `inf yeild.lua` is MoonSec-obfuscated. | Only run the official source. |
| **Detection surface** | IY's GUI sits in `RobloxGui` (gethui). Cobalt/SimpleSpy hook `__namecall` globally. Commands like `fling`, `tpua`, chat spam and `bang` **replicate** and get reported. | Use recon tools in private servers or briefly; never run replicated/trolling commands on a farm account. |
| **Client-only illusions** | `(C)` commands (`btools`, `delete`, `team`, spoofed speed) don't replicate; `nopplimits` doesn't beat server ranges. | Treat them as local views. Verify every effect server-side (money, attributes, sync payloads). |
| **Blunt instruments** | `firepp`, `firecd` and `touchinterests` without a name hit everything. | Always pass a name, or use the game's own remote. |
| **Weight** | About 488 KB, a full GUI, many connections, on every client. | On multi-client AFK boxes, `hideiy` and `norender`, or skip IY there. |
| **License** | MIT. | Keep the notice when vendoring code. |

**Rule of thumb:**
- Use IY for **recon** (`dex`, `rspy`, `savegame`, `partname`, `copypos`, `partesp`, waypoints), **session safety** (`staffwatch`, `noprompts`, `clearerror`, `antiafk`, `autorj`, `antilag`/`norender`) and **manual one-offs**.
- Write **the farm loop itself** in our own code, because it needs completion signals and game-specific rules.

---

## 6. Recipes

| Goal | IY command line |
|---|---|
| First look at a new game | `dex` then `rspy`, then play one full loop by hand |
| Full offline copy | `savegame` |
| Pin down a spot | stand there, then `swp sellspot` · later `wp sellspot` / `twp sellspot` |
| Find hidden pickups or triggers | `partesp Material_Bolt\xray\invisibleparts` |
| AFK safety bundle (bind to OnExecute) | `antiafk\autorj\noprompts\clearerror\staffwatch` |
| Long multi-client session | `antilag\norender\hideiy` |
| Loop a check every 30 s | `inf^30^notifyping` (stop: `breakloops`) |
| Before a farm takes over movement | `clip\unfly\untpwalk` |
| From our script | `iy("antiafk\\noprompts\\staffwatch")` (see §2) |
