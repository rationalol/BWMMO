# BW asset extraction

This folder contains the local, personal-use asset pipeline for extracting
battle sprites from a Pokémon Black/White ROM.

## Why it is separate

The extracted PNGs are copyrighted game assets. They are **not** part of the
repository: output goes to `client/assets/bw/`, which is gitignored. Use this
only with a ROM you own, and do not redistribute the extracted files or ship
them in a public build.

## Usage

```bash
pip install ndspy pillow
python tools/rom/extract_bw_assets.py \
  --rom "Pokemon - White Version (USA, Europe) (NDSi Enhanced).nds"
```

Options:

- `--content server/content/game.json`: species id → national dex mapping
- `--out client/assets/bw`: output directory
- `--only snivy,tepig`: extract only selected species
- `--clean`: remove old Pokémon PNGs first

The script writes `pokemon/<id>_front.png`, `pokemon/<id>_back.png`, and a
`manifest.json`. The client checks for these files at runtime and falls back to
the programmatic placeholder art if they are absent, so the project still runs
without a ROM.

## What was figured out

- Gen 5 battle sprites live in `a/0/0/4`; each national dex entry occupies 20
  files, starting at `dex * 20`.
- The static front/back sprite is file 0/9: an LZ11-compressed 4bpp NCGR with a
  16-color NCLR at file 18.
- The static 96x96 image is assembled from four tile quadrants
  (64x64, 32x64, 64x32, 32x32). The quadrant layout is the shared cell layout
  documented by the Gen 5 ROM-hacking community.
- Pokémon art in the animated sheet (file 2) is a separate NCER/NANR pipeline;
  this tool intentionally extracts the static battle art first.

Next extraction targets: battle UI, music, and the remaining Unova maps. Those formats
need separate converters.

## Move animations and battle particles

`extract_battle_effects.py` exports the original per-move animation scripts and the
particles they spawn:

```bash
python tools/rom/extract_battle_effects.py --rom "Pokemon - White Version (USA, Europe) (NDSi Enhanced).nds"
```

- `a/0/6/6` has 601 entries; entries 1–559 are the move animation scripts (entry 0 is a
  dummy). Each file starts with a sequence count, then one 56-byte header per sequence
  whose first word is the command-stream offset. A command is a 16-bit opcode followed
  by a fixed number of 32-bit arguments; `End` is `0x4D`. A handful of call-only
  sequences end at EOF instead of `End`.
- `a/0/0/6` has 733 battle-effect files. Each starts with ` APS` (particle/effect
  header) and contains one or more ` TPS` blocks. A TPS block starts with a 0x20-byte
  header: `u32[2]` is the mask size, `u32[4]` the palette size and `u32[5]` the block
  size. The payload is an 8-bit coverage mask followed by a BGR555 palette (the
  transparent/terminator entry is usually 0).
- Effect IDs referenced by `LoadSPA`/`PlaySPAAnimation`/`PlaySPAProjectile` point into
  `a/0/0/6`; particle IDs select an emitter, not always a unique texture. The extractor
  keeps every TPS texture in order and the client cycles the atlas when emitters share
  textures.

Output goes to `client/assets/bw/battle_effects/`: a compact `manifest.json` with the
serialised visual commands for all 559 moves, plus one `effect_<id>.png` atlas per
referenced effect. `--check` validates the scripts without writing. The client replays
the original command timing in 2D (`battle_effects.gd`); extracted assets remain local
and gitignored.


## Nuvema Town 3D map and field actors

`extract_nuvema.py` reconstructs the starting town and its characters for the online
Godot client:

```bash
python tools/rom/extract_nuvema.py   --rom "Pokemon - White Version (USA, Europe) (NDSi Enhanced).nds"
```

It reads the overworld map matrix (`a/0/0/9`), resolves the Nuvema Town cell
(24,23) and zone 389, extracts the terrain chunk from `a/0/0/8`, reads the prop
placements from the chunk and the house/lab/sign/plant models from `a/2/2/9`,
then converts the map and props with Apicula. Terrain and prop textures come
from `a/0/1/4` and `a/1/7/6`. Field actors come from `a/1/6/0`
(`fmdl_hero`, `fmdl_heroine`, `fmdl_boy4`, `fmdl_girl2`); each is a 32×32
billboard card with embedded animation frames.

Output:

- `client/assets/bw/nuvema/map/` — `map24_23.glb` + terrain PNGs
- `client/assets/bw/nuvema/props/` — house, lab, sign, plant GLBs + PNGs
- `client/assets/bw/nuvema/placements.json` — matrix cell, prop resource IDs,
  coordinates and rotations
- `client/assets/bw/nuvema/actors/{hero,heroine,boy4,girl2}/frames/` — the
  original 32×32 overworld pixel-sprite frames
- `client/assets/bw/nuvema/actors/<actor>/actor.json` — four-direction
  idle/walk animation map; hero and heroine also expose the running frames as
  `run_*`, used by the Shift-run control
- `client/assets/bw/nuvema/player.png` — fallback trainer portrait

The online client uses these assets for Nuvema Town, the default spawn: start the
server and run the Godot project, and other players/NPCs appear as the original actor
sprites. `run-nuvema.cmd` (or `NuvemaTown.tscn`) still opens the standalone offline
preview for asset checks.

## Route 1 cells

Route 1 is zone 317, made of overworld cells `(24,22)` (south) and `(24,21)` (north).
Extract each as its own client asset folder:

```bash
python tools/rom/extract_bw_map.py --rom "Pokemon - White Version (USA, Europe) (NDSi Enhanced).nds" --cell 24,22 --out client/assets/bw/route1_south
python tools/rom/extract_bw_map.py --rom "Pokemon - White Version (USA, Europe) (NDSi Enhanced).nds" --cell 24,21 --out client/assets/bw/route1_north
```

The current game uses the full Unova outdoor world, not just these three cells. Build it
with:

```bash
python tools/rom/extract_nuvema.py          # shared field actors
python tools/rom/extract_unova_outdoor.py   # 109 outdoor cells -> ~51 MB
python tools/rom/build_unova_world.py       # 928x864 collision/encounter world
python tools/rom/extract_unova_indoor.py    # 387 scenes -> ~175 MB
python tools/rom/build_unova_indoor_worlds.py
python tools/rom/extract_zone_entities.py   # NPCs/warps/triggers from a/1/2/5
python tools/rom/build_unova_maps.py        # 374 indoor maps + 129 outdoor doors
python tools/rom/extract_seasonal_props.py  # r01_a/b seasonal blossom models 295-302
python tools/rom/fix_alpha_textures.py --root client/assets/bw  # bleed transparent RGB
```

Building doors are separate props authored at the building origin. The outdoor
extractor also exports `door_pc.glb` beside each Pokémon Center (`p0_pc_01`),
and the client attaches it at the entrance.

ROM textures use magenta as their transparency key. Bilinear filtering blends
those hidden texels into tree and window edges as purple fringes, so the final
step copies the nearest opaque color into every alpha=0 texel (alpha is left
unchanged). The foliage shader also samples texel centers instead of tile
borders, which removes the thin seams where tree-wall UVs wrap.

The outdoor layout lives in `server/content/maps/unova_full.json` and is sent in
`map_state` as a 109-chunk `visual` manifest. The client streams a 5×5 cell window of
local assets by `asset` id.

Both outdoor and indoor collision come from the map chunk permission grid in `a/0/0/8`,
not material sampling. Each WB/GC chunk stores a 32×32 grid of 8-byte entries; behavior 1
with flag 1, behavior 0xFF and directional walls are solid, while flag 0x0004 marks wild
grass. NG/RD chunks have no local terrain grid and fall back to material sampling.

The outdoor builder decodes the game's own terrain heights from those same 8-byte
entries. Each entry is a `MapHeightTile`: shape (2 bits), slope index (14 bits),
plane-offset index (16 bits) and the 32-bit tile type, whose low word is the tile class
and whose high word holds the collision, grass and water flags. The two indexes address
global tables in the field overlay (329 normalized fx16 normals, then the fx32 plane
offsets 0x7B8 bytes later); `extract_nuvema.py` finds them by the two flat normals that
start the normal table. A shape-0 tile is one plane; a shape-2 tile is two planes
(`MapHeightSplit`) cut along a diagonal. The height at a point is
`-(offset + nx*x + nz*z) / ny`, with x/z relative to the chunk centre, and the builder
samples it at each tile centre. The result is stored as a base64 int16 grid
(`heightScale = 16`) on each visual chunk. NG/RD chunks without this terrain section
fall back to GLB sampling. Indoors the GLB sampling is kept: those map models are
authored around their own floor offsets, so their visual mesh is the reliable reference
for the client's chunk origin. Movement is height-aware at runtime: the server rejects
climbing more than 24 world units (1.5 tiles) but allows dropping up to 128 units (8
tiles), and the client mirrors that rule.

`build_unova_maps.py` parses zone entities (`a/1/2/5`): 20-byte interactables, 36-byte
NPCs, 20-byte warps and 22-byte triggers. Warp coordinates are in 1/16-tile units. Each
indoor scene becomes `unova_in_<zone>`; warp tiles become `P` portals and the destination
is the target warp's own tile. 13 scenes with no walkable permission tile, plus doors
whose target cannot be resolved, are skipped.

The original game does not recolor the spring blossom tree for autumn. It swaps the
prop model: bundle 0 contains `r01_a/b` in `spring/summer/autumn/winter` variants at
IDs 295–302. `extract_seasonal_props.py` extracts all eight GLBs and writes
`unova_outdoor/seasonal_props.json`; the client maps the placement's spring prop to the
current season's path. Autumn therefore uses the real `r01_*_autumn` model and textures.
Only the small `kisetu_hana`/`hana` flower materials use the client-side hue shader as a
supplement.

Apicula must be installed at `.tools/apicula/apicula.exe` or passed via
`--apicula`. Extracted assets stay local and gitignored.

## Wild encounter tables

`extract_encounters.py` reads the zone header's encounter index (field 11) and resolves
the land table from `a/1/2/6`. It applies the standard Gen 5 land slot rates
`20/20/10/10/10/10/5/5/4/4/1/1`:

```bash
python tools/rom/extract_encounters.py --cell 24,22
python tools/rom/extract_encounters.py --zone 317 --json
```

Route 1 is zone 317 → encounter table 77. Its regular grass slots are Patrat and
Lillipup at levels 2–4, alternating through the 12 slots (50% each after weights).
Nuvema (zone 389) and Accumula (zone 397) have no encounter table (`0xFFFF`).
The server stores this as an `encounterZones` rectangle in `unova_full.json`; the full
world builder emits one zone for every cell with a ROM encounter table.

## Full Gen 5 species, moves and learnsets

The full content pipeline reads every national dex entry, not just the starter roster:

```bash
python tools/rom/extract_all_species.py   # 649 species -> rom/species_all.json
python tools/rom/extract_moves.py         # 559 moves -> rom/moves.json
cd server && npm run build-content        # -> server/content/game.json
```

Sources:

- `a/0/1/6`: personal data indexed by national dex; base stats, types and catch rate.
- `a/0/1/8`: level-up learnsets `(move id, level)`.
- `a/0/2/1`: 560 move records of 36 bytes; type, category, power, accuracy, PP and priority.
- `a/0/0/2[203]`: English move names, section index == move id.
- `a/0/0/2[70]`: English species names, section index == national dex.

`build-game-content.ts` uses Showdown's Gen 5 dex only to map dex numbers and move
names to stable Showdown ids. ROM values remain authoritative for stats, types, move
numbers and learnsets. The generated `game.json` has 649 species and 559 moves; each
learnset is filtered to moves that exist in Showdown and deduplicated by move. Alternate
forms, egg moves and TM/tutor moves are not imported yet.

`extract_species.py` is the older subset tool: it only walks the species already in
`game.json` and writes `server/content/rom/species.json`. Keep it for quick experiments;
use the three commands above for a full rebuild.

## NPC dialogue and conditional branches

`extract_dialogues.py` decodes the Gen 5 field-script format and story text:

```bash
python tools/rom/extract_zone_entities.py   # NPC script ids
python tools/rom/extract_dialogues.py       # -> server/content/rom/npc_dialogues.json
python tools/rom/build_unova_maps.py        # embeds the lines into indoor maps
```

What it reads:

- `a/0/5/7`: one script file per zone. The file starts with a table of signed
  offsets relative to each entry's own position, terminated by `0xFD13`. The rest is
  a 16-bit command stream (`a/0/5/7.778` is Nuvema Town).
- `a/0/1/2`: zone headers. Field 4 is the zone script file, field 6 is the story text
  file (`a/0/0/3`).
- `a/0/0/3`: encrypted string tables. Each section is XOR-decrypted backwards with a
  rotating key seeded from its last unit; `0xF000` control codes carry pages, player
  names and formatting.
- `a/1/2/5`: NPC script ids. An NPC's `script` is a 1-based entry in its zone's
  script file offset table.

The extractor runs a small VM for the control-flow commands that matter for dialogue
(lock/face, messages, jumps, calls, stack compares, flags and work values). NPCs whose
scripts use an unsupported command fall back to a static message scan so their text is
not dropped. The default branch assumes all story flags are zero; variants are generated
for referenced flags. `npc_dialogues.json` stores the lines, `usedFlags`, `setFlags` and
conditional variants. The server persists `storyFlags` per character and applies
`setFlags` after a dialogue, so the next interaction can select another branch.

Opcode parameter widths live in `bw_script_ops.json`. They are factual metadata derived
from public Gen 5 scripting documentation and the BW/B2W2 decompilation; no tool source
is included. The extractor is intentionally local and reads the user's own ROM.

## Map texture libraries (BTX0 / TEX0)

`a/0/1/4` holds one BTX0 texture library per map (282 of them). Each carries the terrain
textures plus a `_pl` palette entry per texture. The same archive layout shows up inside
map chunks (`a/0/0/8`) and in the seasonal texture set `a/0/7/0`.

Layout confirmed against `a/0/1/4[106]` and `a/0/7/0[2]`:

- `BTX0` header: `0x08` file size, `0x0C` = `0x10` (header size), `0x0E` section count,
  `0x10` offset of the first section (usually `0x14`). A BTX0 can be embedded at a
  non-zero offset inside a model file, so search for the magic instead of assuming 0.
- `TEX0` at that offset: `0x04` section size, `0x14` **texture data offset** (relative to
  `TEX0`), `0x34` **texture info table offset** (relative to `TEX0`).
- Names come first: 16-byte records of a 4-byte header plus a 12-byte NUL-padded name,
  one record per texture, then one record per `_pl` palette, then the 8-byte-per-entry
  info table, then the texture data at the offset from `0x14`.
- Texture data is 4bpp, linear, low nibble is the left pixel, no 8×8 tile swizzle.
  Walking the data region as consecutive 32×32 blocks reproduces the small terrain
  textures exactly — `a/0/1/4[106]` decodes to trees, bushes, grass and rock, and
  `a/0/7/0[2]` decodes to four variants each of `kisetu01` and `mori01ca`.
- Still unresolved: the width/height/format fields inside the 8-byte info entries, and
  the palette encoding of the `_pl` entries. Until those are pinned down, textures are
  rendered as index maps rather than colour.

`a/0/7/0` is the seasonal texture set: six BTX0 files (`sea_simi`, `taki_shibu`,
`kisetu01` + `mori01ca`, `sea_simi`, `fire`, `denki`), each texture stored four times
with `.1`–`.4` suffixes. `kisetu01.1`–`.4` are four seasonal versions of the same
32×32 flower/leaf rosette. `docs/research/route1_leaves.md` has the season and
Route 1 leaf-effect write-up.
