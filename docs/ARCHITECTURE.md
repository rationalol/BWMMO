# Architecture Notes

## Goal of this slice

Build the smallest system that proves the important parts of a Pokémon-style MMO:

1. A persistent account and character.
2. A shared map where multiple players see each other move in real time.
3. Chat and NPC interaction.
4. A wild encounter whose outcome is decided by the server.
5. Reconnect without losing progress.
6. A client that can later be ported to Android.

The current content is a Nuvema Town and Route 1 slice assembled from the ROM, plus
three legacy 2D placeholder maps kept for battle/encounter regression tests. The
architecture is the deliverable.

## Why a custom engine instead of modifying the ROM

Looking inside the PokeMMO Android client shows:

- Java/Android shell with a ~9.6 MB `classes.dex`
- libGDX rendering and audio libraries
- `libagbplayj.so` (GBA music playback) and `libsseqj.so` (NDS SSEQ music)
- pre-rendered map images under `assets/data/maps/`

That is consistent with a custom game engine that reuses ROM-derived assets, not an NDS
emulator with network injection. Three routes were considered:

| Route | Verdict |
|---|---|
| Patch the NDS ROM to speak to a server | Not viable: tight RAM/CPU, WFC emulation, no server authority, poor tooling |
| Run an emulator and sync memory | Fine for co-op experiments, but cannot reliably support trading, PvP, anti-cheat, or per-player story state |
| Reimplement the game and use the ROM as a data/asset source | The only route that scales to an MMO; also the route this prototype starts |

This prototype ships no art of its own beyond programmatic placeholders. The intended
visual layer is built locally from the user's own ROM through `tools/rom`; extracted
assets are gitignored and never redistributed. A future content pipeline can also ingest
maps/text defined by the project, or assets the project is legally allowed to use.

## Runtime topology

```
┌──────────────────────────────┐
│ Godot 4 client               │
│  - NuvemaOnlineView (3D)     │
│  - WorldView (legacy 2D)     │
│  - HUD / chat / dialogue     │
│  - battle presentation       │
│  - WebSocket client          │
└───────────────┬──────────────┘
                │ JSON over WebSocket
┌───────────────▼──────────────┐
│ Node.js + TypeScript server  │
│  - auth / tokens / sessions  │
│  - map collision + portals   │
│  - encounter rolls           │
│  - battle engine             │
│  - chat + rate limits        │
└───────────────┬──────────────┘
                │ debounced atomic writes
┌───────────────▼──────────────┐
│ server/data/store.json       │
│  accounts, tokens, characters│
└──────────────────────────────┘
```

The server is the source of truth. The client only sends intents and renders snapshots.

## Server design

### Authentication and sessions

- `scrypt` password hashing with a per-account salt.
- Random 32-byte resume tokens, persisted with a 7-day expiry.
- One live session per account. A new login takes over the old socket (the old one is
  disconnected with “Signed in from another connection”).
- Character creation is separate from registration. A character name is globally unique.

### Content files

All game content is loaded from `server/content` at startup:

- `game.json`: balance config, moves, playable species stats/learnsets, catch rates,
  evolution graph, the starter list, the item catalog (`items`) and shop stock (`shops`)
- `rom/species_all.json`: all 649 national dex entries with ROM base stats, types,
  catch rates and full level-up learnsets
- `rom/moves.json`: all 559 Gen 5 moves with ROM type, category, power, accuracy, PP and
  priority, plus the English name
- `rom/species.json`: legacy subset written by `extract_species.py`; the full build uses
  `species_all.json`
- `rom/npc_dialogues.json`: decoded NPC lines, referenced/set story flags, and conditional
  dialogue variants keyed by zone and NPC entity id
- `maps/*.json`: ASCII maps, spawns, NPCs, portals, encounter zones, and the visual chunk manifest

`server/src/content/loader.ts` derives widths/heights, validates every reference, and
refuses to start on broken content. `npm run validate-content` runs the same checks
standalone. Adding a species, move, item, shop, map, NPC, or encounter table is a data
edit; the server and client do not need code changes. The client receives the starter
summaries and item catalog in `auth_ok` and the map/NPC payload in `map_state`.

### World model

Maps are ASCII grids in `server/content/maps/*.json`. Each character in a row is a tile:

- `.` ground, `,` plaza/path, `#` tree, `~` water, `H` house, `g` tall grass,
  `f` flowers, `=` bridge, `P` portal, `S` sign

The current content has one 928×864 outdoor map (`unova_full`) covering all 109 non-empty
overworld matrix cells, plus the legacy 2D Willow Town, Route 1, and Whispering Grove,
with all 649 Gen 5 species and Snivy/Tepig/Oshawott as starters. `game.json`'s `startingMap`
selects the spawn map; the loader refuses to start if it does not name an existing map.
The loader validates:

- tile bounds, rectangular rows, and known tile characters
- NPC and spawn occupancy
- portal source/target consistency and reachability (tests)
- species/move/encounter references
- learnset, stats, catch rates, evolution targets/moves, and starter ids

The map object is sent to the client on entering a map, including NPC positions and
a collision tile window. The client uses the same walkability rules for prediction, but
the server still rejects illegal moves. The full outdoor map is a 928×864 ASCII grid;
the client overlays it on 109 ROM cell scenes with global origin `(x, z) = (−248, −248)`
and `world = origin + tile * 16`; chunk roots sit at `cell * 512`, matching the GLB meshes
which span −256…256 around their cell centre. `map_state` carries a 65×65 tile window
(~4 KB) with a global origin (`tileX`, `tileY`) instead of the whole grid; when the player
moves within 16 tiles of the window edge the server sends `map_window` with a recentred
slice. The chunk visuals are still streamed as a 5×5 cell window around the player.
Indoor scenes use the same origin and the normal `map_state` path, with inline visual
chunks; their 32×32 grids fit in one window.

### Local ROM asset pipeline

The legacy 2D world can run on placeholder art; the ROM-derived worlds require locally
extracted assets. The intended visual direction is BW-derived:

- `tools/rom/extract_bw_assets.py` reads the user's own ROM with `ndspy`.
- It maps species ids to national dex numbers from `server/content/game.json`, opens
  `a/0/0/4` (pokegra), LZ11-decompresses the static NCGR, and assembles the 96×96
  front/back sprite using the shared four-quadrant cell layout.
- It also extracts 24 trainer portraits from `a/0/7/2` using the shared trainer NCER
  layout; the legacy 2D world uses these as portraits for players/NPCs.
- Nuvema Town and Route 1 use the original field actors instead: `a/1/6/0` contains
  `fmdl_hero`/`fmdl_heroine`/`fmdl_boy4`/`fmdl_girl2`, each a 32×32 billboard card with
  embedded animation frames. `extract_nuvema.py` writes those frames plus `actor.json`
  with four-direction idle/walk/run animations; Route 1 reuses the same actor root.
- `tools/rom/extract_bw_map.py` resolves any overworld matrix cell, extracts its terrain,
  props and textures, and writes a placements manifest for one map. Route 1 south and
  north are cells `(24,22)` and `(24,21)`.
- Output goes to `client/assets/bw/`, which is gitignored. No extracted assets are
  committed or bundled.
- The client checks for textures at runtime and falls back to its programmatic art if
  they are missing.

This is deliberately a local, personal-use pipeline: extracting and redistributing
ROM assets is a copyright risk. The game code never downloads assets and does not ship
any ROM content. Battle backgrounds/UI, music, and maps beyond Nuvema/Route 1 are not
part of this extraction phase yet.

### Full Unova 3D map pipeline

The full outdoor Unova world is assembled from the ROM matrix:

1. `a/0/0/9` file 0 is the 29×27 overworld matrix: 783 cells, 109 non-empty, each with a
   model id and zone id. The other files in the same NARC are the small indoor matrices.
2. Zone headers (`a/0/1/2`) name the area and matrix. Area records (`a/0/1/3`) provide the
   prop bundle and map texture set.
3. `tools/rom/extract_unova_outdoor.py` extracts every non-empty outdoor cell: terrain
   from `a/0/0/8`, props from `a/2/2/9`, textures from `a/0/1/4` and `a/1/7/6`, and
   converts them with Apicula. Output is ~51 MB under `client/assets/bw/unova_outdoor/`
   with per-cell `placements.json` files.
4. `tools/rom/extract_unova_indoor.py` resolves the 387 indoor zones through their small
   matrices and batches map models by texture set. Output is ~175 MB under
   `client/assets/bw/unova_indoor/` with one scene entry per zone (387 scenes, 5900
   room cells).
5. Every map chunk in `a/0/0/8` carries a permission grid (32×32 eight-byte tiles). The
   grid is the game's own collision data: behavior 1 + flag 1, behavior 0xFF, and
   directional walls are solid; flag 0x0004 marks tall grass and 0x0002 marks water.
   The same entry is a `MapHeightTile` (shape, slope index, plane-offset index, diagonal
   bit), so the outdoor builder decodes the original terrain planes instead of sampling
   the GLB. The global slope/offset tables live in the field overlay; a shape-2 tile is
   two planes cut by a diagonal. `tools/rom/build_unova_world.py` assembles the 109 grids
   into `server/content/worlds/unova_full.json` (928×864) plus 15 zone-header encounter
   zones.
6. `tools/rom/build_unova_indoor_worlds.py` assembles the same grids per indoor scene and
   writes `server/content/worlds/unova_indoor.json`. NG/RD chunks have no permission grid
   and fall back to terrain-material sampling; heights stay GLB-sampled because indoor
   models are authored around their own floor offsets. Only 13 scenes have no walkable
   tiles.
7. `tools/rom/extract_zone_entities.py` parses `a/1/2/5` (one file per zone): interactables,
   36-byte NPC entries, 20-byte warp entries, and 22-byte triggers. Warp coordinates are
   in 1/16-tile units; NPC x/z are tile coordinates.
8. `tools/rom/build_unova_maps.py` turns those entities into `unova_in_<zone>` maps:
   warp source tiles become `P` portals carrying the warp's `contactDirection` as
   `entryDir`, destinations use the target warp's own tile, room spawns are chosen from
   walkable door tiles, and NPCs are placed on nearby walkable tiles. When the doorway is
   solid, the trigger is snapped onto the whole walkable strip in front of it (one tile
   per doorway tile, so a 1×3 side door gets three trigger tiles) and marked
   `onWarpTile: false`, so the server makes the player press into the door. It also
   rewrites `unova_full.json` with the outdoor permission grid, visual chunks, and the
   outdoor door portals while preserving the existing outdoor NPCs.
9. The server owns the world layout. `unova_full` has a `visual` block with 109 chunks
   (asset id, cellX/cellY, offsets); `map_state` sends it to the client. The client loads
   local GLB/props by asset id, streams a 5×5 cell window around the player, and places
   actors with the server origin. Indoor maps send inline chunks (`mapFile` + `props`) so
   cells can share the extracted mapset/propset files without duplicating 175 MB of GLBs.
10. `client/scenes/NuvemaTown.tscn` plus `run-nuvema.cmd` keep a standalone offline
    preview; the online path uses the server's grid collision.

Outdoor spawn is `(784, 753)` (Nuvema cell 24,23, local 16,17). The Nuvema NPCs are at
`(781,752)` and `(787,752)`. Cell seams are ordinary walkable tiles; there is no
`map_state` transition when crossing them. The client loads the player's current chunk
synchronously, requests neighbours asynchronously, and keeps a radius of two cells
loaded (5×5). It unloads farther chunks. Collision tiles are independent of the visual
chunks: the server sends a 65×65 prediction window and refreshes it near the edge, so a
client can keep rendering 5×5 cells while only holding a smaller collision slice.

Outdoor and indoor collision both come from the ROM permission grids. The server treats
`P` portals as door tiles, but a door only fires when the move direction matches the
warp's `entryDir` (the ROM contact direction): front doors take W, east-wall doors A,
west-wall doors D, north doors S. A snapped trigger in front of a solid door covers the
whole doorway frontage (1×3 side doors expose three trigger tiles) and is ordinary
floor until the player presses into the door, reproducing the original two-step contact;
doorway tiles fire on the matching step. Portals without `entryDir` (legacy maps and
scripted warps) keep the old any-direction behaviour. A successful door use sends a new
`map_state` for `unova_in_<zone>` (or back to `unova_full`). The client shows a short
loading fade on these transitions, but outdoor cell seams remain seamless. 374 indoor maps
are generated (169 reachable from the overworld door graph); 13 NG/RD or cutscene scenes
with no walkable tiles are skipped, as are doors whose target scene or coordinates are
invalid.

### Wild encounters

Maps can define `encounterZones` rectangles. A zone contains an id, name, tile rectangle,
per-step rate, and weighted table. `unova_full` currently has 71 encounter zones derived
from the outdoor matrix cells; every species in the ROM table is now imported, so zones
keep their full 12-slot land tables. Zone areas without an encounter table (towns and
some special cells) never roll encounters even if they contain a `g` tile.

The Route 1 table comes from the ROM: zone 317 stores encounter index 77 in field 11 of
its zone header; `a/1/2/6[77]` has the 12 regular land slots. Applying the standard Gen 5
slot rates `20/20/10/10/10/10/5/5/4/4/1/1` gives Patrat 50% and Lillipup 50% at levels
2–4. `tools/rom/extract_encounters.py` resolves any zone table. The world builder maps
each zone's table to `encounterZones` and filters species not yet present in
`game.json`. The prototype uses a 10% encounter chance per accepted step into tall
grass; `ENCOUNTER_RATE` can override it for tests.

On an encounter the server picks a weighted entry, creates a wild creature from the
species/level data, and sends `battle_start`. The client never generates encounters or
rolls outcomes.

### Movement

- Client → server: `{type:"move", dir, seq}`.
- Input follows the original turn confirmation: the first press of a direction turns in
  place and sends `{type:"turn", dir}`, which the server broadcasts as `player_turned`;
  the next press (or a held key after 150 ms) sends the move. Turning never moves the
  character, and the client does not rotate mid-step.
- Server: checks battle state, 130 ms cooldown, bounds, tiles, NPCs.
- Accepted: update tile position, persist, send `move_ack`, then broadcast
  `player_moved` only to players within 64 tiles (Chebyshev) of the new position.
  Visibility is diffed in both directions after every move and map transition, so
  clients receive `player_joined`/`player_left` as characters enter or leave the AOI.
  The tile window is recentred with `map_window` when the player nears its edge.
- Rejected: send `move_ack` with the authoritative position and a reason.
- Client predicts the step immediately and reconciles only against the ack for its latest
  sequence number. Older acks are ignored. An ack for the tile the client already
  predicted must not cancel the walk animation mid-slide; the client keeps animating
  until it reaches the tile.
- ROM maps hold a 500 ms walk cadence (480 ms travel plus a short idle beat) or a
  250 ms run cadence with Shift. The extracted 4-frame cycle contains two footfalls
  (neutral / stride / neutral / stride), so one cycle spans two tiles: walk plays at
  4 fps (1 s per cycle) and run at 8 fps (0.5 s per cycle). The repeated neutral
  (aerial for run) frame lands between the two footfalls, so the stride rhythm is
  even and each tile gets exactly one footfall.
- A move carries an optional `run` flag. The server echoes it in `move_ack` and
  `player_moved`, so observers play the same run animation and interpolation speed.
- Portals update `mapId` and coordinates, persist, then send a fresh `map_state`; the old
  map receives `player_left` and the new map receives `player_joined`.

This is not a full prediction/reconciliation system (no input replay), but it removes
the worst latency feel for a tile-stepping game and keeps the server authoritative.

### Chat and NPCs

- Chat is global for the slice, rate-limited to one message per 800 ms and 200 chars.
- NPC interaction requires the NPC to be on the same map and within Manhattan distance 2.
- Nuvema Town ships Bianca and Cheren as plain `kind:"npc"` dialogue NPCs; the client
  renders their `sprite` id with the original field-actor animations.
- Nuvema also has a service corner south of the spawn: `nurse_joy` (`healer`),
  `mart_clerk` (`shop` with `shopId:"nuvema_mart"`) and `pc_terminal` (`pc`). The
  service NPCs send `party_state` / `shop_state` / `pc_state` after `dialogue` and are
  re-validated by proximity for every transaction, not just when the menu opened.
- Healer NPCs restore the whole party and PC box (HP, PP and status conditions) and
  send both `dialogue` and `party_state`. Willow Town and Whispering Grove have legacy
  healer NPCs too.

### NPC dialogue

Indoor NPC lines are decoded from the ROM rather than authored as placeholders:

1. `extract_zone_entities.py` records each NPC's 16-bit `script` id from `a/1/2/5`.
2. `extract_dialogues.py` reads the zone header's script file (`a/0/1/2` field 4) and
   story text file (field 6). A script file starts with relative offset entries
   terminated by `0xFD13`; the NPC script id is a 1-based entry in that table.
3. The script is a 16-bit command stream. The extractor runs a small VM for locking,
   messages (`0x3D`), jumps/calls, stack comparisons, flags (`0x10`/`0x23`–`0x25`) and
   work values. Unknown commands fall back to a static message scan.
4. `a/0/0/3` strings are XOR-encrypted with a rotating key; `0xF000` controls encode
   pages, line breaks and player-name substitutions. The extractor flattens blocks and
   renders sections into dialogue pages.
5. `build_unova_maps.py` embeds the resulting lines into each indoor map's NPC. A
   profile may include `dialogueVariants` (flag conditions + lines + `setFlags`) and
   `setFlags` for the default branch.

The server persists `character.storyFlags`. `selectDialogue` picks the first variant
whose flags all match (default zero) and returns its lines and flags to set; after an
interaction those flags are saved. That is how talking to Bianca in the lab once can
unlock her follow-up battle-request branch on the next interaction. The default run
assumes a new-game flag state; later story work can initialise the ROM flags properly.

### Battle

`server/src/game/battle.ts` is now an adapter around Pokémon Showdown's Gen 5 simulator
(`@pkmn/sim`, MIT). Our `BattleState` shape is unchanged, so the game server and client
protocol stay stable while the rules kernel becomes much more complete.

- `createBattle` builds a `gen5customgame` Showdown battle with the player party on
  `p1` and the wild creature on `p2` (AI chooses the first available move).
- Showdown's team preview is resolved automatically; the client never sees it.
- Player moves and switches are sent to Showdown. Run, catch and item use stay in our
  server: success ends the battle; a failed run/catch or a used medicine uses a hidden
  no-op `Splash` turn so Showdown still resolves the wild's free attack, faint and
  forced-switch flow.
- The battle carries its own copy of the bag (`inventory.items`), so choosing a Great
  Ball or a Potion is validated and deducted inside the battle and synced back to the
  character when the battle ends.
- Showdown owns turn order, accuracy, physical/special damage, type effectiveness, STAB,
  critical hits, abilities, items, status, stat stages and secondary effects.
- Our layer owns encounters, catch chance/ball consumption, run chance, medicine effects
  and revive bookkeeping, XP/level-ups, rewards, healing, persistence and the final
  `battle_end`.
- After each turn the adapter copies HP/status and the remaining PP of every move from
  Showdown into `CreatureState`, and updates the active party index. Saved PP is loaded
  back into Showdown before the first action; Gen 5's default PP Ups are cleared so the
  ROM's base PP is authoritative. Species base stats/types/catch rates come from the ROM;
  `SpA`/`SpD` are used by Showdown.
- The prototype uses a fixed Showdown seed for deterministic tests; later it can be
  randomized per battle.

Species base stats, types, catch rates and full level-up learnsets come from the ROM
(`tools/rom/extract_all_species.py` + `server/scripts/build-game-content.ts`).
`statsForLevel` uses a Gen 5-style formula without IVs/EVs/nature. `game.json` contains
all 649 base species and 559 moves; learnsets are filtered to moves that resolve in
Showdown Gen 5, and each species keeps every ROM level-up entry it can support. Alternate
forms, egg moves and TM/tutor moves are not imported yet. `baseXp` remains
prototype-scaled.

The client never decides damage, turn order, catch success, XP, or rewards. It only
displays the synchronized battle state. Move buttons show current/max PP and disable
zero-PP moves; stat stages and status icons are not drawn yet, although those effects are
active server-side. PvP can later use the same Showdown adapter with both sides
controlled by players.

### Growth, evolution, moves and the Pokédex

`server/src/game/creatures.ts` owns all per-creature progression and persists it inside
`CharacterState`:

- Each owned move is stored as a content `MoveDef` plus `currentPp`/`maxPp`. New and
  wild creatures start full; battle sync writes spent PP back; a nurse heals PP too.
  `normalizeCreatureProgress` migrates old saves, clamps PP to the ROM maximum and
  removes stale queued moves.
- `awardExperience` only looks at learnset entries for the level just reached (not every
  older entry). A move enters a free slot immediately. With four moves known it is kept
  in the creature's persisted `pendingMoves` array and the player receives one
  `move_learn_request` at a time. `learn_move` replaces a slot or declines; `forget_move`
  lets the party menu drop a known move while keeping at least one.
- `SpeciesDef.evolutions` is generated from Showdown's Gen 5 dex into 320 relationships.
  After a level-up, `levelEvolutionFor` evaluates level, known-move, held-item and stat
  conditions (plus gender for Burmy/Combee). `evolveCreature` changes species, types,
  stats, base XP and catch rate while preserving level, XP, moves, PP and queued learns.
  Item, trade, friendship and location evolutions are imported for the Pokédex display
  but do not have a trigger UI yet.
- `pokedex` stores sorted national-dex `seen` and `caught` arrays. Encounters mark seen;
  captures, the starter and evolution mark caught. Older saves are seeded from the party
  and box on first load. `pokedex_request` returns the seen/caught state plus a 649-entry
  catalog for the client's Dex menu.

### Items, shops and the PC

`game.json.items` is the single item catalog. It is sent to the client in `auth_ok` so
the bag, shop and battle menus all render names, descriptions, prices and icons from the
same data:

- `ball`: `ballBonus` multiplies the catch formula (Poké 1.0, Great 1.5, Ultra 2.0).
- `medicine`: `heal` restores a fixed amount, `cureStatus` clears a major status, and
  `revive` brings a fainted creature back at half HP. A medicine costs the turn in
  battle and can be used from the bag outside battle.
- `key`: reserved for future key items.

The character inventory is `{items: {itemId: count}}`, capped at 99 per stack. Older
saves that only had `{balls: n}` are migrated to a `poke_ball` stack at login.
`buildStartingInventory` seeds `startingBalls` plus `config.startingItems` (three
Potions by default). Selling returns half the buy price, rounded down.

`game.json.shops` maps shop ids to ordered stock lists; an NPC with `kind:"shop"` points
at one through `shopId`. Buy/sell validates the stock, money, stack cap and the clerk's
proximity on every request. Coins are earned from wins (`winReward`), so the loop is
win → earn → buy → catch/heal.

`character.box` is the PC storage, capped by `config.maxBox` (30). Depositing requires
keeping at least one party member; withdrawing requires a free party slot; swapping
works even when both sides are full. Boxed creatures keep their current HP and status,
so the PC is storage rather than a free heal. The nurse, not the PC, restores HP and
clears status.

The client uses four overlays: the HUD bag (pockets, item details, “use on” party
targets), `shop_ui.gd` (buy/sell tabs with quantities and prices), `pc_ui.gd` (party and
box columns with store/take/swap) and the battle bag (one button per owned ball type
plus a medicine list and target picker). None of these overlays compute outcomes; they
only send intents and render the server's next `shop_state`, `pc_state`, `party_state`
or `battle_turn`.

### Client rendering and animation

- Battle creatures load `client/assets/bw/pokemon_anim/manifest.json`. Each side is a
  horizontal sheet of idle frames plus per-frame durations, produced by
  `tools/fetch_battle_sprites.py` from Showdown's Gen 5 animated GIFs. `battle_creature.gd`
  advances a timer and draws the current frame with `draw_texture_rect_region`; the ROM
  static portrait remains the fallback when no animation sheet exists.
- Move effects use the game's own scripts and particles. `tools/rom/extract_battle_effects.py`
  reads the 559 scripts from `a/0/6/6` (timed command streams containing `LoadSPA`,
  `PlaySPAAnimation`, `PlaySPAProjectile`, camera/sprite commands and waits), extracts the
  TPS coverage masks and BGR555 palettes from `a/0/0/6`, and writes
  `client/assets/bw/battle_effects/manifest.json` plus one atlas per effect. The server
  translates each Showdown turn into `battle.events`; `battle_event_player.gd` walks the
  events, `battle_effects.gd` replays the ROM script in 2D, `battle_actor_fx.gd` owns the
  sprite/camera tweens, and HP/status feedback is applied at the matching damage event.
  The client locks the command menu until playback ends and defers the victory/defeat
  overlay behind the final move. Without extracted assets the player emits a
  type-coloured procedural burst so battles still run.
- Outdoor and indoor chunk meshes are post-processed on instantiation. Tree/flower/grass/
  petal materials (`ki*`, `hana*`, `kusa*`, `r01_*`) get a wind `ShaderMaterial` with
  linear-mipmap filtering, backface culling disabled and alpha scissor. Other opaque/masked
  materials get `map_lit.gdshader`, an unshaded shader that keeps the ROM's baked vertex
  shading and adds only a faint normal-based directional term. This matches BW's bright,
  soft DS look; real-time directional shadows were deliberately removed because they made
  trees and building sides much harsher than the original. Foliage and terrain textures
  use `filter_linear_mipmap` to soften the low-resolution 3D textures, while sprites and UI
  stay pixel-crisp. Shadow-card materials (`ki02c`, `ki02dx`, `*_kage`) are forced to
  unshaded alpha blending: they are ROM-baked soft ground shadows, and running them
  through the foliage alpha scissor turned them into opaque black blobs. Map/prop meshes
  disable shadow casting; only character blob shadows remain. Water uses the unshaded
  `water_flow` shader.
- Each visual chunk carries a base64 `heights` grid (32×32 signed 16-bit fixed-point
  values, `heightScale=16`). The builder samples the topmost upward-facing GLB triangle
  at every tile centre. The client decodes it into `chunk_heights`, places actors at
  `_height_at(grid)` and interpolates Y with the same `move_toward` as X/Z, so stairs and
  slopes are followed smoothly. After a chunk streams in, `_reheight_actors()` updates
  self, NPCs and peers. The server compares the height of the current and destination tiles on every
  move: climbing more than 24 world units (1.5 tiles) is rejected, while dropping up to
  128 units is allowed. The client mirrors this rule in prediction, so ledges can be
  jumped down but walls/cliffs cannot be climbed.
- Player and NPC actors get a soft blob-shadow quad at ground level. Outdoor camera is
  `(0,270,310)` with target `(0,22,-22)`. Indoors use a closer/higher preset
  `(0,220,165)` with target `(0,10,-20)` and an extra warm ambient boost. For indoor
  rooms with at most a 26×26 walkable bounding box, the camera focuses on the room centre
  blended 35% toward the player, so the room stays framed without hiding the doorway
  behind the chat panel. Indoor chunks also carry exterior building shell props
  (`buill_*`, `thouse_*`, `r4_build*`, `r5_build*`, plus the Pokémon Center's own
  `pc_01` shell, `c04_football*` test pitch and the town `searock*` rock); the client
  filters those when `indoor_view` is true, otherwise they cover the floor and NPCs.
  The rock filter only applies to rooms named "Pokémon Center" because cave interiors
  use `searock*` as legitimate scenery.
- NPC name labels scale with distance and fade out beyond eight tiles; the local player's
  overhead label is hidden. The global chat panel auto-collapses after 12 seconds of
  inactivity, leaving a single header bar; `+` or T expands it again.
- FXAA is enabled in `project.godot`. MSAA is deliberately off: in the GL Compatibility
  renderer, enabling 3D MSAA produced unstable exposure/shadow rendering during windowed
  tests. A higher-quality AA path would require evaluating Forward+/Mobile.
- The 3D environment uses a procedural sky. The ROM's blossom trees are seasonal props
  `r01_a/b_spring/summer/autumn/winter`
  (IDs 295–302). `extract_seasonal_props.py` extracts all eight and writes
  `seasonal_props.json`; the client resolves the `r01_*` prop path for the current
  season, so autumn uses the real autumn model/texture. The `seasonal_flower` shader is
  only a supplement for `kisetu_hana`/`hana` pixels: autumn shifts pink/white to yellow,
  winter desaturates, summer reddens; green leaves stay green. Fog is intentionally off: at the ~315-unit
  camera distance even a low density washed the whole scene white.
- The hero actor uses the extracted 2D billboard frames. The original engine walks with
  `ACMD_WALK_8F` (8 movement frames) and runs with `ACMD_RUN4F` (4 movement frames), with
  run speed exactly twice walk speed. The client keeps the four extracted walk/run frames
  (including the repeated base frame needed for a balanced gait) and drives travel with
  32/64 units per second. Because the four-frame cycle has two footfalls, it spans two
  tiles: walk plays at 4 fps (1 s per two-tile cycle) and run at 8 fps (0.5 s per cycle),
  so each tile gets exactly one footfall and the animation cycle and tile arrival
  coincide. A short 80 ms idle grace prevents a held run from flashing the idle pose
  between tiles; the original engine similarly uses `anim.step` phase alignment instead
  of restarting the cycle every step.
- Headless checks cover frame sheets, material overrides, particles and environment
  construction. Visual screenshots are taken with explicit foreground permission only.

### Reconnect

- Client stores `server_url` and `token` in `user://session.cfg`.
- On socket loss while in the world, it shows an overlay and retries `resume` with
  fixed 2 s retry backoff (up to 20 attempts).
- Server `resume` validates the token and re-enters the world at the saved position.
- After a successful resume, the client receives a full `map_state`, so no differential
  state repair is needed.
- On fatal session errors, the client clears the token and returns to the login screen.

### Persistence

The prototype uses one JSON file with debounced (500 ms) atomic writes
(`store.json.tmp` → rename) and a 10 s autosave. This keeps setup to `npm install`.

A production migration would keep the same `Store` interface and use PostgreSQL:

```sql
accounts(id uuid pk, username citext unique, salt text, hash text, created_at timestamptz)
tokens(token text pk, account_id uuid fk, expires_at timestamptz)
characters(account_id uuid pk fk, name citext unique, color text, map_id text,
           x int, y int, dir text, money int, wins int, updated_at timestamptz)
inventories(account_id uuid pk fk, items jsonb)
party_slots(character_id uuid, slot int, species text, level int, xp int, hp int,
            status text, moves jsonb, ...)
box_slots(character_id uuid, slot int, species text, level int, xp int, hp int,
          status text, moves jsonb, ...)
```

Redis would hold online presence, socket/session routing, chat channels, and rate limits.

## Scaling path

The current server is one process with in-memory sessions and a simple distance-based
interest filter. That is appropriate for tens of concurrent players on a small map. The
next steps are:

1. **Interest management**: tile windows and a 64-tile broadcast radius are in place,
   but each move still scans every session and each refresh resends a whole window.
   Replace the linear scan with a grid/quadtree, send tile deltas instead of full
   windows, and split broadcasts by ROM cell.
2. **Channels/shards**: one logical map has N instances; friends/parties can join the same
   channel. This is how PokeMMO-style population scaling works.
3. **Stateless gateways + game workers**: WebSocket gateways route to map/battle workers;
   Redis pub/sub carries events; Postgres stores durable state.
4. **Battle workers**: PvE can stay close to the map worker; PvP needs isolated, auditable
   rooms and deterministic replays.
5. **Anti-cheat**: server-side validation is already in place; add movement speed
   statistics, anomaly detection, trade/economy audit logs, and signed client builds.
6. **Content pipeline**: maps, creatures, moves, starters, and encounters are already
   data-driven; extend the schema to events, conditional dialogue, trainers, and items;
   add an editor/import tool. For story fidelity, consider a decompilation project as a
   reference for flags and event semantics (do not copy copyrighted assets).
7. **Shared-world story**: every player has their own story flags and NPC visibility;
   cutscenes may temporarily instance a map. The world stays shared while progression
   remains personal.

## Testing

Server:

- Server `node:test` suites for content validation, ROM species data and the evolution
  graph, map integrity, dialogue variant selection, battle resolution, catching with
  typed balls, battle medicine/revive, switching, XP/level-ups, level evolution, pending
  move learning/forgetting, PP persistence, Pokédex registration, item effects, shop
  pricing helpers, PC deposit/withdraw/swap, persistence, and tokens.
- A WebSocket smoke test that creates two accounts with different starters in the
  seamless world, verifies the starter Pokédex/catalog, the 65×65 `map_state` window and
  spawn/NPC data, moves and observes the broadcast, receives a recentred `map_window`
  near the window edge, chats, heals at Nurse Joy, refuses an illegal PC deposit, buys
  and sells a Potion at the Mart, talks to Cheren, enters the lab and reads decoded
  Juniper dialogue with the player name substituted, checks that the first Bianca
  interaction sets story flags and unlocks her follow-up branch, crosses the
  Nuvema/Route 1 seam without a map transition, triggers a tall-grass encounter and
  checks the seen flag, resolves at least one server battle turn with spent PP synced
  back, exits the battle, reconnects with a token to the saved world position, Pokédex
  and remaining PP, uses a Potion on the damaged starter, and chats again.
- Battle resolution, encounters, portals, and healing are also covered by the node:test
  suites. Existing saves from the old per-cell maps are migrated to global `unova_full`
  coordinates at startup.

Client:

- Headless Godot import/run catches parse and startup errors.
- Auto modes (`--auto`, `--auto-b`, `--auto-run`, `--auto-dialogue`, `--auto-create`,
  `--auto-reconnect`, `--capture-login`, `--touch`) run against Nuvema Town. The legacy
  `--auto-battle` / `--auto-grove` paths need `startingMap` set back to `town`.
- The Nuvema/Route 1 seamless world is built from locally extracted ROM assets. The
  headless asset check (`client/tests/check_rom_assets.gd`) loads every map GLB, prop,
  actor manifest, and exercises chunk streaming (initial two chunks, load the third,
  unload the far one) using the server-shaped `visual` manifest.
- `client/tests/check_battle_animation.gd` verifies the front/back animation sheets and
  frame advancement. `client/tests/check_visual_runtime.gd` builds the Route 1 chunk
  headlessly and checks material overrides, particle emission and environment setup.
  `check_shop_layout.gd` and `check_pc_layout.gd` exercise the buy/sell and storage
  overlays and their emitted requests; `check_hud_layout.gd` covers the bag pockets,
  medicine “use on” targets, Dex filters/pages/details and the four-move learn prompt;
  `check_battle_layout.gd` checks the battle move rows and their `current/max PP`
  labels. These do not open a window; final visual tuning still needs
  an explicit visible run.

## Known trade-offs

- JSON store, not a database (party, PC box and item stacks are part of the character save)
- Radius-based AOI only; no channels or sharding yet
- Global chat only
- All 649 base Gen 5 species and 559 moves are imported, but alternate forms, egg moves
  and TM/tutor moves are not; no held items, trainer/PvP battles or client battle status
  icons. PP is shown and persisted, but item/trade/friendship/location evolutions have
  data and Dex hints without a trigger UI
- The item economy is prototype-sized: one Nuvema Mart, eight items, no badges/shop
  gates, and the PC has no release/rename/move-between-boxes yet
- Base stats/types/catch rates/learnsets are ROM-derived and the evolution graph is
  imported from Showdown's Gen 5 dex; Showdown supports status moves and SpA/SpD, and
  `baseXp` reward values remain prototype-scaled
- The Showdown adapter uses a fixed seed and a hidden no-op `Splash` move for failed
  run/catch and medicine turns; both are prototype details, not final gameplay design
- Nuvema Town and Route 1 are part of the full seamless Unova outdoor map; the three
  legacy 2D maps remain as battle/encounter regression content
- Nuvema and Route 1 use the original field-actor sprite cards; other 2D maps still use
  scaled battle portraits
- Battle idle animation comes from Showdown's Gen 5 GIFs, not a direct NCER/NANR
  implementation; shiny, substitute and most alternate-form animations are not covered.
- Overworld characters are original 32×32 2D billboards, not 3D models. The 3D feel comes
  from terrain normals/vertex colors, blob shadows and the camera angle; there is no
  real-time shadow map, SSAO or global illumination.
- Outdoor streaming preloads a 5×5 cell window; collision tiles use a 65×65 window.
  The AOI is a per-move linear scan with a 64-tile radius, `map_window` resends the whole
  slice rather than a delta, and there are no channels/shards yet
- 169 of the 374 generated indoor maps are reachable from the overworld door graph; 13
  scenes have no walkable permission tiles and some story/elevator doors are skipped. 966
  NPC dialogue profiles (164 conditional variants) are decoded, but many indoor NPC
  entities still fall back to generic text because they use special/global script ids, have
  no story text, or hit unsupported high-numbered script commands. Trainer events,
  condition triggers and full story-flag initialisation are not wired yet
- Outdoor and indoor collision come from ROM permission grids, with a per-step height
  rule (climb <=1.5 tiles, drop <=8 tiles). Building/prop footprints and cell seams still
  need a visual pass; 13 overworld door warps had no walkable approach or target and are
  not connected
- Outdoor heights are decoded from the ROM's MapHeightTile planes (the same entry as the
  permission grid); indoor heights stay GLB-sampled because the room models carry their
  own floor offsets
- No client-side replay buffer; correction is “snap/glide to server tile”
- UI is English-only and uses programmatic placeholder art
- Android export configuration is intentionally not included
