# BWMMO Prototype Protocol (v3)

Transport: WebSocket text frames carrying one JSON object per frame.

- Default endpoint: `ws://<host>:2567` (any path; the server upgrades all paths)
- Max frame size: 8 KiB
- Server heartbeat: WebSocket ping every 30 s; dead sockets are terminated
- Client ping: `{"type":"ping","t":<client-ms>}` → `{"type":"pong","t":<echo>,"now":<server-ms>}`
- Message rate limit: 40 messages/second per socket
- All coordinates are zero-based tile coordinates. `dir` is one of `up|down|left|right`.
- The default starting map is `unova_full`, a 928×864 grid assembled from 109 ROM
  overworld cells. The client streams a 5×5 cell window of terrain chunks by cellX/cellY;
  walking across a cell seam does not send a new `map_state`. Indoor scenes are separate
  maps named `unova_in_<zone>` (374 generated, 169 reachable from current interior doors).
  ROM doorways are 1–3 tiles wide/tall and keep the warp's original `contactDirection` as
  `entryDir`, so each door opens with the same key as the DS game: `down`/S, `up`/W,
  `left`/A or `right`/D. A move in a different direction never warps. `onWarpTile` says
  whether the `P` is the doorway tile itself (`true`) or the walkable floor snapped in
  front of a solid door (`false`). Snapped doors are ordinary floor on the first press;
  the player walks onto the trigger, then presses into the door, matching the original
  two-step door contact. Portal tiles that are the doorway trigger on the matching step.
  Portals without `entryDir` (hand-authored maps, scripted warps) keep the old
  any-direction behaviour. The arrival tile is locked: portals stay inert until the
  player steps off it, and walking between `P` tiles of the same doorway does not
  retrigger. The client shows a short loading fade for these transitions.
- `map_state` carries only a 65×65 collision tile window around the player
  (`tileX`, `tileY`, `tileWidth`, `tileHeight`) instead of the full 928×864 grid
  (~4 KB instead of ~830 KB). When the player approaches the edge of that window the
  server sends a `map_window` with a recentred slice; the client keeps the same visual
  chunks and only replaces its collision prediction grid. Indoor and legacy maps
  smaller than the window send the full grid with `windowed: false`.
- The client renders tile `(x, y)` at `(originX + x*16, height, originZ + y*16)`.
  Outdoor, indoor, and legacy `P` maps all use `originX = -248` and `originZ = -248`;
  map chunks are placed at `cell * 512`, so a tile's mesh is centred on its 32×32 cell.
  Each visual chunk carries `heights`, a base64 little-endian int16 grid (one value per
  tile); the map visual carries `heightScale` (16) so the client converts a value to
  world units with `value / heightScale`. Missing chunks/tiles use height 0.
- Player presence and movement are interest-managed: `player_joined`, `player_left`,
  and `player_moved` are only sent for characters within 64 tiles (Chebyshev distance)
  on the same map. Chat remains global.
- Visual chunks normally reference a per-cell `placements.json`. Indoor chunks embed
  `mapFile` and `props[{x,y,z,rotation,file}]` directly; their asset paths are relative to
  `res://assets/bw/`, e.g. `unova_indoor/mapsets/tex_213/m_labo01_00_00.glb`.
- The server is authoritative. The client sends intents; the server validates and broadcasts results.

## Connection lifecycle

1. Server sends `hello`.
2. Client sends `register`, `login`, or `resume`.
3. Server responds with `auth_ok` containing a token and `character` (or `null`).
4. If `character` is `null`, client sends `create_character`.
5. Server sends `character_created`, then `map_state`.
6. If a character already exists, `map_state` follows `auth_ok` directly.

## Client → Server

### `register`
```json
{"type":"register","username":"ash_ketchum","password":"pikachu","locale":"zh_CN"}
```
Username: 3–20 `[A-Za-z0-9_]`. Password: 4–72 chars. `locale` is optional and
accepts `en`, `zh_CN`, `zh_TW`, `ja`, or `ko`; it is normalised from common
variants such as `zh-Hans`. The server stores it on the connection for future
content rendering.

### `login`
```json
{"type":"login","username":"ash_ketchum","password":"pikachu","locale":"zh_CN"}
```

### `resume`
```json
{"type":"resume","token":"<token from auth_ok>","locale":"zh_CN"}
```
Tokens are valid for 7 days and are persisted across server restarts.

### `logout`
```json
{"type":"logout"}
```
Explicit sign-out, sent by Settings → Log out. The server revokes every token
issued for the account, saves and removes the player from the world, and closes
the socket with code `4000`. The character and story progress are kept; a later
`login` with the same credentials continues where the player left off. This
message is only accepted after authentication.

### `set_locale`
```json
{"type":"set_locale","locale":"en"}
```
Updates the connection's preferred locale. This may be sent before or after
authentication; unknown or unsupported values are ignored. The client sends it
when the player changes the language in Settings or on the login screen.

### `create_character`
```json
{"type":"create_character","name":"Ash","color":"#e76f51","starter":"snivy","sprite":0}
```
Name: 2–16 `[A-Za-z0-9_]`, unique across the server. Color must be one of the
eight colors listed in `server/src/game/creatures.ts`. `starter` must be one of
the ids sent in `auth_ok.starters`; omitting it falls back to the first starter.
`sprite` is an optional appearance id: `0` Hilbert, `1` Hilda, `2` boy NPC,
`3` girl NPC. Unova maps it to the original field-actor frames; the legacy 2D world uses
`0`/`1` as trainer portraits. Unknown ids fall back to `0`.

### `move`
```json
{"type":"move","dir":"up","seq":12}
{"type":"move","dir":"right","seq":13,"run":true}
```
`run` is optional (default `false`). The server enforces a 130 ms cooldown, map bounds,
blocking tiles, NPC tiles, and “not in battle”. Response is `move_ack` with the same
`seq` and the requested `run` flag. The server broadcasts `player_moved` to other
players on the same map only for accepted moves, including `run` so observers can use
the faster interpolation and the original running frames. In ROM maps the server grid is
also the collision layer for the 3D terrain; the client predicts against the same tiles
and NPC positions.

### `turn`
```json
{"type":"turn","dir":"left"}
```
Turns a character in place without taking a step. The client sends this when the
first press of a direction differs from the character's current facing; the next
press (or a held key after the 150 ms turn delay) sends `move`. The server updates
the stored facing and broadcasts `player_turned` to nearby players. Turns are
ignored while the character is in battle. A `move` that is rejected as `blocked`
also broadcasts `player_turned` when its direction changed the stored facing.

### `chat`
```json
{"type":"chat","text":"hello world"}
```
1–200 characters after control characters are stripped. 800 ms cooldown. Chat is
global (all maps) and is echoed to the sender.

### `interact`
```json
{"type":"interact","npcId":"nurse_joy"}
```
The NPC must be on the player's map and within Manhattan distance 2. Response is
`dialogue`. NPC `kind` decides the follow-up service:

- `healer` (Nurse Joy, Mom): restores HP and clears status conditions for the party
  and PC box, then sends `party_state` and `notice`.
- `shop` (Mart Clerk): sends `shop_state` right after `dialogue`; buying and selling
  are only accepted while the player is within distance 2 of that shop's clerk.
- `pc` (PC terminal): sends `pc_state`; storage operations are only accepted while
  the player is within distance 2 of a `pc` NPC.
- `move_tutor`: sends `move_service` with the NPC's `moveList`; `teach_move` puts the
  chosen move into the normal learn/replace queue.
- `move_reminder`: sends `move_service` with each party member's relearnable level-up
  moves; `teach_move` remembers one of them.
- `trade`: sends `trade_service`; `trade_evolve` performs a simulated link trade.
- `ability`: sends `ability_service`; `set_ability` switches one party member's
  ability among the species's legal Gen 5 abilities and saves it immediately.
- `friendship`: maxes the friendship of every party member (a test service for now).
- `guide` / `npc`: dialogue only.

Bianca and Cheren are `kind:"npc"` in the Nuvema part of `unova`. Nuvema also has
`nurse_joy`, `mart_clerk` and `pc_terminal` south of the spawn point. The test growth
NPCs live in Professor Juniper's Lab (`server/content/story/growth_test.json`).

Furniture is examined with the same message and no `npcId`:

```json
{"type":"interact","objectX":12,"objectY":5}
```

The tile must hold one of the map's `interactables` and be within Manhattan distance 1
of the player (the client sends the tile it faces, or the tile it stands on). The reply
is `dialogue` with `kind:"object"`, `npcName` set to the object's label and `lines`
taken from the ROM object script when it decoded, else the label's generic line.

### `use_item`
```json
{"type":"use_item","itemId":"potion","partyIndex":0}
```
Uses medicine, a TM or an evolution stone outside battle. Potions fail at full HP,
Full Heal fails without a status, and Revive only works on a fainted creature. A
successful medicine or evolution stone consumes one item and replies with
`party_state` and `notice`; TMs are reusable (Gen 5 behavior), put the item's `moveId`
into the pending learn queue and reply with `move_learn_request`. An invalid target is
rejected with an `error` and does not consume the item. Items cannot be used while a
battle is active (`battle_action` handles that).

### `shop_buy` / `shop_sell`
```json
{"type":"shop_buy","shopId":"nuvema_mart","itemId":"poke_ball","qty":2}
{"type":"shop_sell","shopId":"nuvema_mart","itemId":"potion","qty":1}
```
`qty` is 1–99 and stacks cap at 99. Buying checks the shop catalog, the player's
money, the stack cap and the clerk's proximity; selling returns `floor(price / 2)`
coins per item and works for any owned item while at that clerk. Both reply with a
fresh `shop_state`, `party_state` and `notice`.

### `pc_deposit` / `pc_withdraw` / `pc_swap`
```json
{"type":"pc_deposit","partyIndex":2}
{"type":"pc_withdraw","boxIndex":0}
{"type":"pc_swap","partyIndex":0,"boxIndex":3}
```
Deposit moves a party member into the PC box (the party must keep at least one
creature); withdraw moves a boxed creature into the party (requires a free party
slot); swap exchanges a party member with a boxed one and works when both sides are
full. Stored creatures keep their HP and status. All operations require standing
within distance 2 of a `pc` NPC and reply with `pc_state`, `party_state` and
`notice`.

### `pc_release` / `rename_creature`
```json
{"type":"pc_release","boxIndex":0}
{"type":"rename_creature","source":"party","index":0,"name":"Ivy"}
```
`pc_release` deletes a boxed Pokémon permanently; the client confirms first. Party
members are never released through this message, so at least one partner remains.
`rename_creature` accepts a 1–12 character nickname (Unicode allowed, control
characters rejected) for a party or boxed creature. Both require standing within
distance 2 of a `pc` NPC and reply with `pc_state`, `party_state` and `notice`.

### `friend_request` / `friend_accept` / `friend_decline` / `friend_cancel` / `friend_remove`
```json
{"type":"friend_request","playerId":"<character-id>"}
{"type":"friend_accept","playerId":"<character-id>"}
{"type":"friend_decline","playerId":"<character-id>"}
{"type":"friend_cancel","playerId":"<character-id>"}
{"type":"friend_remove","playerId":"<character-id>"}
```
A friendship only exists after the recipient accepts. Pending requests are persisted and
survive restarts. `friend_cancel` is sent by the requester, `friend_decline` by the
recipient; `friend_remove` clears both characters' lists. Every action replies with a
fresh `social_state` and a `notice`; the other online side receives a notice and, where
relevant, an updated `social_state`.

### `social_state`
```json
{"type":"social_state"}
```
Requests a snapshot with `friends`, `incomingRequests`, `outgoingRequests`, `nearby`
and `maxFriends`. `nearby` rows carry Manhattan `distance`, `friend`, `requested` and
`incoming` flags. Friends also carry `online` and, while online, `location`.

### `direct_message`
```json
{"type":"direct_message","toId":"<character-id>","text":"Want to trade?"}
```
Only accepted when the recipient is a friend or currently visible to the sender. The
recipient receives `direct_message` with `fromId`/`fromName`; the sender receives an
echo with `toId`/`toName` and `outgoing:true`. Messages are live-only, not persisted.

### `duel_request` / `duel_accept` / `duel_decline` / `duel_cancel`
```json
{"type":"duel_request","playerId":"<friend-character-id>"}
{"type":"duel_accept","playerId":"<requester-character-id>"}
{"type":"duel_decline","playerId":"<requester-character-id>"}
{"type":"duel_cancel","playerId":"<target-character-id>"}
```
Friend-only invitations. Both trainers must be online, out of battle and have at least
one healthy Pokémon. A request expires after 30 seconds. Accepting clones both parties
into a server-authoritative Showdown duel and sends `battle_start` to both. Pending
invites are cancelled if either side enters a wild battle, starts another duel or
disconnects.

### `battle_action`
```json
{"type":"battle_action","battleId":"<uuid>","action":"move","moveIndex":1}
{"type":"battle_action","battleId":"<uuid>","action":"run"}
{"type":"battle_action","battleId":"<uuid>","action":"switch","partyIndex":1}
{"type":"battle_action","battleId":"<uuid>","action":"catch","itemId":"great_ball"}
{"type":"battle_action","battleId":"<uuid>","action":"item","itemId":"potion","partyIndex":0}
```
The battle must belong to the sender and be awaiting an action. While
`battle.mustSwitch` is true, only `switch` is accepted. `catch` throws one ball from
the battle inventory (default `poke_ball` for older clients); stronger balls use
their `ballBonus` and raise the catch chance. `item` uses a medicine on any party
member and consumes the turn, so the wild creature attacks immediately after the
heal. The server resolves the whole turn (player action/AI move, speed/priority
order, accuracy, damage, dual-type effectiveness, faints, catch chance) and returns
`battle_turn`, followed by `battle_end` when the battle is over. Invalid actions are
rejected without consuming the turn or the item. A move with 0 PP is rejected; the
client disables those buttons and shows `currentPp/maxPp` on each move.

In a duel (`battle.mode:"duel"`) only `move` and `switch` are accepted. `run`, `catch`
and `item` are rejected server-side, even if a modified client sends them. Both sides
choose once per turn; the first client to choose receives `battle_turn` with
`awaitingAction:false` until the opponent also chooses, then both receive the resolved
turn. If one side must replace a fainted creature, only that side has
`mustSwitch:true/awaitingAction:true`; the other side waits.

A story battle (`battle.mode:"trainer"`) also accepts `move`, `switch` and `item`, but
`run` and `catch` are rejected with `There's no running from a Trainer battle` and
`You can't catch another Trainer's Pokémon`. The opponent is AI-controlled: when its
active creature faints it sends out its next healthy team member on its own, so the
player is never asked to answer for the trainer side.

### `pokedex_request`
```json
{"type":"pokedex_request"}
```
Asks for the current seen/caught registry plus all 649 catalog entries. The reply is
`pokedex_state` with `entries` populated. The client caches the catalog for the Dex menu;
normal progression updates carry only `seen`/`caught`.

### `learn_move`
```json
{"type":"learn_move","source":"party","index":0,"moveId":"growth","replaceIndex":2}
{"type":"learn_move","source":"party","index":0,"moveId":"growth","replaceIndex":-1}
```
Resolves the `move_learn_request` the server sent for that creature. `source` is
`party` or `box`, and `index` is the slot in that list. `replaceIndex` selects the
known move to overwrite, or `-1` to decline. If the creature has fewer than four moves
the server fills the free slot and ignores the index value. The queued move is persisted
until resolved, so disconnecting does not lose it. A successful/rejected decision replies
with `party_state` and `notice`; the next queued move (if any) is sent afterwards.

### `forget_move`
```json
{"type":"forget_move","partyIndex":0,"moveIndex":2}
```
Forgets one party move outside battle (the last remaining move cannot be forgotten).
Replies with `party_state` and `notice`, and can free a slot before resolving a queued
level-up move.

### `teach_move`
```json
{"type":"teach_move","npcId":"test_move_tutor","partyIndex":0,"moveId":"workup"}
{"type":"teach_move","npcId":"test_move_reminder","partyIndex":0,"moveId":"tackle"}
```
Asks a `move_tutor` or `move_reminder` within distance 2 to teach one move. Tutor
moves must be in that NPC's `moveList`; reminder moves must be level-up moves the
creature could already know and does not currently know. The move is appended to the
creature's persisted pending queue and the normal `move_learn_request` is sent, so the
player chooses a move to replace or declines. The final choice goes through
`learn_move`.

### `trade_evolve`
```json
{"type":"trade_evolve","npcId":"test_link_trade","partyIndex":2}
```
Performs the simulated link trade for a creature with a `trade` evolution. A required
held item is checked and consumed. Replies with `party_state`, `pokedex_state` when
the evolution registers a new species, `notice`, `journal` and `evolution_event`.
Nothing is sent to another player because this is a test station, not real trading.

## Server → Client

Content display names (`starters[].name`, `items[].name`, `map_state.map.name`,
`map_state.map.npcs[].name`, creature `name`/`moves[].name`, shop item names,
Pokédex entry names and evolution names) are rendered in the connection's
current locale. IDs, types, status codes and asset paths remain canonical and
are never localized.

### `hello`
```json
{"type":"hello","version":3,"message":"BWMMO prototype server","locales":["en","zh_CN","zh_TW","ja","ko"]}
```
`locales` lists the locales the server accepts in auth/`set_locale` messages.

### `auth_ok`
```json
{
  "type":"auth_ok",
  "token":"...",
  "username":"ash_ketchum",
  "character": null,
  "starters":[
    {"id":"snivy","name":"Snivy","types":["Grass"],"level":5,"moves":["Tackle","Leer"]},
    {"id":"tepig","name":"Tepig","types":["Fire"],"level":5,"moves":["Tackle","Tail Whip"]},
    {"id":"oshawott","name":"Oshawott","types":["Water"],"level":5,"moves":["Tackle","Tail Whip"]}
  ],
  "items":[
    {"id":"poke_ball","name":"Poké Ball","category":"ball","price":200,"ballBonus":1.0,
     "description":"A device for catching wild Pokémon.","icon":"poke_ball"},
    {"id":"potion","name":"Potion","category":"medicine","price":300,"heal":20,
     "description":"Restores 20 HP to one Pokémon.","icon":"potion"}
  ],
  "maxParty":6,
  "maxBox":30
}
```
`character` is the full saved character when one exists. Starter `moves` contains the
level-up moves currently imported into content (including status moves such as Leer);
Showdown resolves their effects. `items` is the global item catalog (balls, medicine,
key items) used by the bag, shop and battle menus; `maxBox` is the PC box capacity.

### `character_created`
```json
{"type":"character_created","character":{ "...": "..." }}
```

### `map_state`
```json
{
  "type":"map_state",
  "map":{
    "id":"unova_full",
    "name":"Unova",
    "width":928,
    "height":864,
    "tiles":["#####################################...","... 65 rows of 65 tiles ..."],
    "tileX":752,
    "tileY":721,
    "tileWidth":65,
    "tileHeight":65,
    "windowed":true,
    "npcs":[
      {"id":"bianca","name":"Bianca","x":781,"y":752,"color":"#f4a261","kind":"npc","sprite":3},
      {"id":"cheren","name":"Cheren","x":787,"y":752,"color":"#457b9d","kind":"npc","sprite":2}
    ],
    "interactables":[
      {"id":"z391_o0","x":2,"y":2,"script":2,"label":"TV","dialogue":["It's a TV."]}
    ],
    "visual":{
      "originX":-248,"originZ":-248,"tile":16,"cellSize":32,"heightScale":16,
      "chunks":[
        {"asset":"unova_outdoor/cells/cell_24_21","cellX":24,"cellY":21,"offsetX":12288,"offsetZ":10752,"heights":"<32x32 int16 base64>"},
        {"asset":"unova_outdoor/cells/cell_24_22","cellX":24,"cellY":22,"offsetX":12288,"offsetZ":11264,"heights":"<32x32 int16 base64>"},
        {"asset":"unova_outdoor/cells/cell_24_23","cellX":24,"cellY":23,"offsetX":12288,"offsetZ":11776,"heights":"<32x32 int16 base64>"}
      ]
    }
  },
  "self":{
    "id":"<uuid>","name":"Ash","color":"#e76f51","sprite":0,"mapId":"unova_full",
    "x":784,"y":753,"dir":"down","money":500,"wins":0,
    "inventory":{"items":{"poke_ball":10,"potion":3}},
    "pokedex":{"seen":[495],"caught":[495]},
    "party":[{"species":"snivy","name":"Snivy","level":5,"types":["Grass"],
      "xp":0,"maxHp":19,"hp":19,"atk":9,"def":9,"speed":11,
      "baseXp":16,"catchRate":0.176,
      "moves":[{"id":"tackle","name":"Tackle","type":"Normal","power":50,"accuracy":100,"priority":0,
                "pp":35,"currentPp":35,"maxPp":35},
               {"id":"leer","name":"Leer","type":"Normal","power":0,"accuracy":100,"priority":0,
                "pp":30,"currentPp":30,"maxPp":30}]}]
  },
  "players":[{"id":"...","name":"Misty","color":"#2a9d8f","sprite":1,"mapId":"unova_full","x":784,"y":752,"dir":"down"}],
  "online":2,
  "maxParty":6,
  "maxBox":30,
  "location":"诺文镇",
  "worldMap":{
    "width":256,
    "height":168,
    "places":[
      {"name":"诺文镇","x":232,"y":158,"kind":"town"},
      {"name":"1号道路","x":232,"y":148,"kind":"route"},
      {"name":"七宝市","x":203,"y":118,"kind":"town"}
    ]
  },
  "pokedexTotal":649
}
```
`tiles` contains `tileHeight` rows of `tileWidth` characters; the example is abbreviated.
`(tileX, tileY)` is the global tile coordinate of `tiles[0][0]`, so a local row index
`ly` and column `lx` map to global `(tileX + lx, tileY + ly)`. `width`/`height` remain
the full map dimensions. Small maps that fit in one window send the complete grid and
set `windowed` to `false`. `visual` is optional: the server owns terrain chunk
ids/offsets, and the client loads those local assets for display only. Collision, spawn,
NPCs and encounters still come from the server grid.
`worldMap` is optional and omitted when the ROM town map has not been extracted. It is
the full Unova marker list (40 named areas), localized for the player's locale; `x`/`y`
are pixels in the 256×168 world-map image, and `kind` is `town`, `route` or `landmark`.
The client matches `location` against `places[].name` to highlight the current area, so
the list only changes when the player changes locale.
The new-character spawn in `unova_full` is `(784, 753)` facing `down` (Nuvema Town),
which is near the origin of the seamless 928×864 grid. `sprite` selects the actor
animation set (0 Hilbert, 1 Hilda, 2 boy NPC, 3 girl NPC).
Tile characters: `.` ground, `,` plaza/path, `#` tree/wall, `~` water, `H` house,
`g` tall grass, `f` flowers, `=` bridge, `P` portal, `S` sign. Outdoor cell seams in
`unova_full` are normal walkable tiles, not portals. Every walkable tile of a ROM door
footprint is a `P` tile, so a 1×3 side door or 3×1 building door exposes its whole
doorway. Each portal carries `entryDir` from the ROM warp's contact direction and
`onWarpTile`; the server only uses the door when the move direction matches `entryDir`,
and a snapped trigger (`onWarpTile: false`) waits for a press into the door instead of
firing on the step onto the trigger floor. Portals with no `entryDir` (legacy maps and
scripted warps) still fire on any step onto `P`. The server replies with a fresh
`map_state` (doors into `unova_in_<zone>` and back, plus legacy maps). Moving between
adjacent `P` tiles of one doorway does not retrigger, and the tile the player arrives on
is locked until they leave it, so wide doorways never bounce. A move that is blocked by a
wall while the player stands on a `P` tile and matches its `entryDir` also uses that door;
the client sends the move without predicting a step and the server answers with
`map_state` instead of `move_ack`. Otherwise the server sends `move_ack` for the step
first, then `map_state`; the client should treat the new map state as authoritative.

### `map_window`
```json
{"type":"map_window","mapId":"unova_full","x":745,"y":726,"width":65,"height":65,"tiles":["... 65 rows ..."]}
```
Sent after an accepted move when the player comes within 16 tiles of the current tile
window edge (`TILE_WINDOW_MARGIN`). It carries a recentred slice; `mapId` must match the
current map. The client replaces its tile grid and window origin. The initial window is
sent in `map_state`; this message is never sent for maps that fit entirely in one window.

### `player_joined` / `player_left` / `player_moved` / `player_turned`
Same-map presence events. They are scoped by interest: a character only receives events
for players within 64 tiles (Chebyshev distance) on the same map.
```json
{"type":"player_joined","player":{"id":"...","name":"Misty","color":"#2a9d8f","sprite":1,"mapId":"unova_full","x":784,"y":752,"dir":"down"}}
{"type":"player_left","playerId":"..."}
{"type":"player_moved","playerId":"...","mapId":"unova_full","x":785,"y":753,"dir":"right","run":false}
{"type":"player_moved","playerId":"...","mapId":"unova_full","x":786,"y":753,"dir":"right","run":true}
{"type":"player_turned","playerId":"...","mapId":"unova_full","x":786,"y":753,"dir":"up"}
```

### `move_ack`
```json
{"type":"move_ack","seq":12,"accepted":true,"x":785,"y":753,"dir":"right","run":false,"mapId":"unova_full","location":"诺文镇"}
{"type":"move_ack","seq":13,"accepted":true,"x":786,"y":753,"dir":"right","run":true,"mapId":"unova_full","location":"诺文镇"}
{"type":"move_ack","seq":14,"accepted":false,"reason":"blocked","x":786,"y":753,"dir":"right","run":false,"mapId":"unova_full"}
```
Reasons: `blocked`, `too_fast`, `in_battle`. On a rejected ack the client should
reconcile to the returned position. Accepted acks also carry `location`, the
localized town/route name for the new tile (the seamless overworld is subdivided
into 32x32-tile ROM matrix cells).

### `chat`
```json
{"type":"chat","playerId":"...","name":"Misty","text":"hi","mapId":"unova_full","mapName":"Unova"}
```

### `social_state`
```json
{
  "type":"social_state",
  "friends":[{"id":"...","name":"Misty","online":true,"mapId":"unova_full","location":"Route 1"}],
  "incomingRequests":[{"id":"...","name":"Bianca","online":true,"at":1234567890}],
  "outgoingRequests":[],
  "nearby":[{"id":"...","name":"Cheren","distance":4,"mapId":"unova_full","location":"Route 1",
             "friend":false,"requested":false,"incoming":false}],
  "maxFriends":50
}
```
Sent on world entry and after every friend/duel action; the client can also request a
fresh snapshot.

### `direct_message`
```json
{"type":"direct_message","fromId":"...","fromName":"Misty","text":"hi","at":1234567890}
{"type":"direct_message","toId":"...","toName":"Misty","text":"hi","at":1234567890,"outgoing":true}
```

### `duel_request` / `duel_request_sent` / `duel_request_cancelled` / `duel_request_expired` / `duel_declined`
```json
{"type":"duel_request","fromId":"...","fromName":"Misty","expiresAt":1234567890}
{"type":"duel_request_sent","toId":"...","toName":"Misty","expiresAt":1234567890}
{"type":"duel_request_cancelled","fromId":"...","name":"Misty"}
{"type":"duel_request_expired","toId":"...","name":"Misty"}
{"type":"duel_declined","playerId":"...","name":"Misty"}
```
The target's client opens an accept/decline prompt. Cancellation, expiry and decline
carry either `fromId` (target-side prompt) or `toId` (requester-side pending state) so
both clients can clear their UI.

### `dialogue`
```json
{"type":"dialogue","npcId":"bianca","npcName":"Bianca","kind":"npc","lines":["Hi! I'm Bianca.","..."]}
```
Indoor NPC lines come from the decoded ROM story text. The server substitutes
`{name}` with the character name before sending. Conditional story flags are
server-side; the client only receives the selected `lines`.

`kind` may also be `story` or `gate`:

- `story`: a page of an active scene. It carries `sceneId` and `step`; the client
  must echo them back with `story_advance` when the page is closed, and stays in
  its dialogue state until `story_end`.
- `gate`: the explanation for a locked passage. It has no `sceneId`; walking away
  or closing the box is enough. The server rate-limits repeats to one every 2.5 s.

### Story scenes

```json
{"type":"story_begin","sceneId":"prologue_bedroom_intro"}
{"type":"dialogue","kind":"story","sceneId":"prologue_bedroom_intro","step":0,
 "npcId":"story:prologue_bedroom_intro","npcName":"Cheren","lines":["..."]}
{"type":"story_choice","kind":"starter","sceneId":"prologue_bedroom_intro","step":4,
 "prompt":["Which Pokémon will you choose?"],
 "options":[{"id":"snivy","name":"Snivy","types":["Grass"],"level":5},
            {"id":"tepig","name":"Tepig","types":["Fire"],"level":5},
            {"id":"oshawott","name":"Oshawott","types":["Water"],"level":5}]}
{"type":"story_end","sceneId":"prologue_bedroom_intro"}
```

Client → server:

```json
{"type":"story_advance","sceneId":"prologue_bedroom_intro","step":0}
{"type":"story_choice","sceneId":"prologue_bedroom_intro","step":4,"optionId":"tepig"}
```

`story_begin` announces a scene; the first page or choice follows. `say` steps wait
for `story_advance`, `chooseStarter` waits for `story_choice`. Both acknowledgements
must repeat the current `sceneId`/`step`; the server ignores stale or duplicated
messages so a lost or repeated click cannot skip pages. `step` is the index in the
scene and also identifies the page for idempotency. Movement is rejected with
`reason:"story_gate"` while a gate is closed, and ignored with `reason:"story"` while
a scene is waiting. `story_end` is followed by a fresh `map_state` because story
NPCs and gate visibility may have changed. A `chooseStarter` choice carries
`kind:"starter"`; the client presents it as the gift-box scene instead of the
generic three-button choice card. `options[].types` supplies the type chips and
the partner spotlight colour.

A `battle` step pauses the scene instead of sending a page: the server sends
`battle_start` (with `battle.mode:"trainer"`) and waits. The client plays the battle
through `battle_action` as usual, and when the player closes the `battle_end` result
box it sends:

```json
{"type":"battle_closed"}
```

Only then does the story resume with the win or lose pages that the scene queued for
that trainer. The server remembers the pending trainer per player, so a wild battle,
a duel or a late/duplicated `battle_closed` cannot advance a scene by accident.

A `walk` step moves one NPC along a tile path and pauses the scene until it arrives,
the same way the ROM's scripts apply a movement sequence and wait for the object:

```json
{"type":"npc_move","npcId":"prologue_bianca_bedroom","msPerTile":500,
 "path":[{"x":6,"y":4,"dir":"right"},{"x":7,"y":4,"dir":"right"},
         {"x":7,"y":3,"dir":"up"}],
 "face":"down","vanish":true}
```

`dir` is per hop and always present: the server computes it from the previous
tile, so the client never infers a facing from coordinates (the ROM's movement
actions carry the direction the same way). `face` (optional) overrides the
facing once the walk ends — `"up" | "down" | "left" | "right" | "player"`, where
`"player"` is resolved against the player's live tile at send time. `vanish`
(optional) removes the sprite on arrival, mirroring the ROM's `0x45`
"end and disappear" action used when a character leaves the map.

There is no client acknowledgement: the server schedules the resume for
`path.length * msPerTile + 120` ms, and the client plays the same path at the
same tile time, so both sides finish together. The step is skipped (no message,
no pause) when the NPC is missing, hidden from that player, or a tile on the path
is not walkable; a path that is not exactly one tile per hop, or that crosses a
blocked tile, is logged as a content error and skipped. Paths are authored in
`server/content/story/*.json` and checked by `npm run validate-content`; the NPC
keeps its walked position for the rest of the scene and returns to its authored
tile with the `map_state` sent at `story_end`.

A `face` step turns an NPC without moving it — the ROM's standalone turn actions
(`0x20`–`0x23`), which a script uses before speaking so the character looks at the
player. It does not pause the scene:

```json
{"type":"npc_face","npcId":"prologue_mom_bedroom","dir":"left"}
```

`facing: "player"` is turned into a concrete direction server-side, from the
NPC's and the player's tiles at the moment the step runs.

### `pokedex_state`
```json
{
  "type":"pokedex_state",
  "seen":[495,504],
  "caught":[495],
  "total":649,
  "entries":[
    {"dex":495,"id":"snivy","name":"Snivy","types":["Grass"],
     "evolutions":[{"to":"servine","name":"Servine","method":"level","level":17}]}
  ]
}
```
Sent when a sighting/capture/evolution changes the registry, and as the reply to
`pokedex_request`. `entries` is omitted on incremental updates; only the catalog request
carries all 649 entries, so the client caches it for the Dex menu.

### `move_learn_request`
```json
{
  "type":"move_learn_request",
  "source":"party",
  "index":0,
  "moveId":"growth",
  "move":{"id":"growth","name":"Growth","type":"Normal","power":0,"accuracy":0,"priority":0,"pp":20},
  "moves":[...],
  "creatureName":"Snivy",
  "creatureLevel":13
}
```
Sent one at a time when a level-up move could not enter a free slot. The client presents
it modally and answers with `learn_move` (`replaceIndex` of a current move, or `-1` to
decline). The queue lives on the creature's `pendingMoves` array and survives
reconnects; after a decision the server sends `party_state` and the next prompt, if any.
`source:"box"` uses the PC box index instead of a party index.

### `party_state`
```json
{
  "type":"party_state",
  "party":[...],
  "box":[...],
  "inventory":{"items":{"poke_ball":10,"potion":3}},
  "money":500,
  "wins":0,
  "pokedex":{"seen":[495,504],"caught":[495]},
  "maxParty":6,
  "maxBox":30
}
```
Sent after healing, item use, shop transactions, move learning/forgetting and PC moves.
`box` is the current PC storage; HUD updates use `party`, `inventory`, `money` and
`pokedex`. A healer also restores every move's PP. Every creature carries `ability`
(a Showdown id such as `overgrow`), `abilitySlot` (`0`/`1` normal, `2` hidden), and
the localized outbound fields `abilityName`/`abilityDescription`.

### `shop_state`
```json
{
  "type":"shop_state",
  "shop":{
    "id":"nuvema_mart",
    "name":"Nuvema Mart",
    "items":[
      {"id":"poke_ball","name":"Poké Ball","category":"ball","price":200,
       "sellPrice":100,"description":"A device for catching wild Pokémon.",
       "icon":"poke_ball","owned":10},
      {"id":"potion","name":"Potion","category":"medicine","price":300,
       "sellPrice":150,"description":"Restores 20 HP to one Pokémon.",
       "icon":"potion","owned":3}
    ]
  },
  "money":500,
  "inventory":{"items":{"poke_ball":10,"potion":3}}
}
```
Sent when a `shop` NPC is interacted with and after every successful buy/sell.
`owned` is a convenience copy of the current stack count.

### `pc_state`
```json
{
  "type":"pc_state",
  "party":[...],
  "box":[...],
  "maxParty":6,
  "maxBox":30
}
```
Sent when a `pc` NPC is interacted with and after every successful storage action.
Creatures in `box` carry the same fields as party creatures, including HP and status.

### `move_service`
```json
{
  "type":"move_service",
  "npcId":"test_move_tutor",
  "npcName":"Move Tutor",
  "service":"tutor",
  "party":[...],
  "moves":[{"id":"workup","name":"Work Up","type":"Normal","power":0,"accuracy":0,"pp":20,"category":"status"}]
}
```
Sent for `move_tutor` and `move_reminder` NPCs. For `service:"tutor"` the shared
`moves` list is the NPC's catalog; the client greys out moves the selected creature
already knows. For `service:"reminder"` each party entry additionally carries
`relearn`, a list of level-up moves the creature can remember right now.

### `trade_service`
```json
{
  "type":"trade_service",
  "npcId":"test_link_trade",
  "npcName":"Link Trade",
  "party":[{"species":"kadabra","name":"Kadabra","level":16,"tradeable":true}]
}
```
Sent for `trade` NPCs. `tradeable` is true when a `trade` evolution matches the
creature (including its held item).

### `ability_service`
```json
{
  "type":"ability_service",
  "npcId":"test_ability_expert",
  "npcName":"Ability Expert",
  "party":[{
    "species":"snivy","name":"Snivy","level":5,
    "ability":"overgrow","abilitySlot":0,
    "abilityName":"Overgrow","abilityDescription":"Powers up Grass-type moves in a pinch.",
    "abilities":[
      {"id":"overgrow","name":"Overgrow","description":"...","slot":0,"hidden":false},
      {"id":"contrary","name":"Contrary","description":"...","slot":2,"hidden":true}
    ]
  }]
}
```
Sent for `ability` NPCs. `abilities` is every legal Gen 5 ability for the species,
with the slot and hidden flag; the current choice is `ability`/`abilitySlot`.

Client → server:
```json
{"type":"set_ability","npcId":"test_ability_expert","partyIndex":0,"abilityId":"contrary"}
```
Validated at Manhattan distance 2, outside battle, and against the selected species's
legal abilities. A successful switch replies with `party_state` and a fresh
`ability_service`; an unknown or foreign ability is rejected with `error`.

### `evolution_event`
```json
{
  "type":"evolution_event",
  "evolution":{
    "fromSpecies":"pikachu","fromName":"Pikachu","fromTypes":["Electric"],
    "toSpecies":"raichu","toName":"Raichu","toTypes":["Electric"]
  }
}
```
Sent after an out-of-battle evolution (item, trade, or a level-up that happened
outside the battle settlement). The party state and journal entry are sent alongside
it; the client can use this event for an evolution animation later.

### `battle_start` / `battle_turn`
```json
{
  "type":"battle_start",
  "battle":{
    "id":"<uuid>",
    "mode":"wild",
    "playerName":"Ash",
    "party":[{"species":"snivy","name":"Snivy","level":5,"types":["Grass"],"maxHp":19,"hp":19,"moves":[...]},
             {"species":"tepig","name":"Tepig","level":5,"types":["Fire"],"maxHp":21,"hp":21,"moves":[...]}],
    "activeIndex":0,
    "player":{"species":"snivy","name":"Snivy","level":5,"types":["Grass"],"maxHp":19,"hp":19,"moves":[...]},
    "wild":{"species":"patrat","name":"Patrat","level":2,"types":["Normal"],"maxHp":13,"hp":13,"moves":[...]},
    "log":["A wild Patrat appeared!","Go, Snivy!"],
    "events":[],
    "turn":0,
    "awaitingAction":true,
    "mustSwitch":false,
    "inventory":{"items":{"poke_ball":10,"potion":3}},
    "maxParty":6,
    "status":"active"
  }
}
```
`battle_turn` has the same `battle` shape with an updated log, party HP, active index,
turn, and flags. `inventory` is a battle-local copy of the bag: used balls and medicine
are deducted immediately and synced back to the character at `battle_end`. When the
active creature faints and a healthy reserve exists, `mustSwitch` is true and the
client must send a `switch` action. `status` can be `active|won|lost|fled|caught`.

A duel uses `mode:"duel"` and additionally carries `opponentName`. The state is sent
per viewer: `party`/`player`/`activeIndex` are the recipient's side, while `wild` is the
opponent's active creature (the key is kept for client compatibility). `events` and
`sides` are also relative to the recipient. Duel snapshots have no usable bag, and
`awaitingAction` is true only while that specific player still owes a choice.

A story battle uses `mode:"trainer"` and carries `opponentName` plus `trainerId` (the
content trainer id, useful for logging). `wild` is again the opponent's active
creature, and the opening log names the trainer (`Bianca wants to battle!`,
`Bianca sent out Oshawott!`). The client shows a trainer banner and hides Run.

`events` is reset at the start of every resolved turn and lists that turn's visual beats
in actual order. The client uses it to select the correct move animation and to apply
HP changes as the matching damage event plays:

```json
[
  {"type":"move","side":"player","moveId":33,"moveName":"Tackle","moveType":"Normal","moveCategory":"physical","target":"wild"},
  {"type":"damage","side":"wild","amount":6,"hp":9,"maxHp":15},
  {"type":"effective","multiplier":2},
  {"type":"critical"},
  {"type":"faint","side":"wild"},
  {"type":"switch","side":"player","name":"Snivy"},
  {"type":"heal","side":"player","hp":19,"maxHp":19},
  {"type":"status","side":"wild","status":"brn"},
  {"type":"curestatus","side":"player","status":"psn"},
  {"type":"boost","side":"player","stat":"atk","amount":1},
  {"type":"ability","side":"wild","abilityId":"intimidate","abilityName":"Intimidate",
   "description":"On switch-in, this Pokemon lowers the Attack of adjacent opponents by 1 stage."},
  {"type":"miss","side":"wild"},
  {"type":"run","success":false},
  {"type":"catch","itemId":"poke_ball","success":true},
  {"type":"item","itemId":"potion","targetIndex":0}
]
```

`side` is always `player` or `wild`. `moveId` is the Gen 5 move number used by the ROM
animation manifest. `moveCategory` is lower-case `physical|special|status`. Clients
must tolerate unknown event types. `ability` events are localized for the recipient's
locale; The initial `battle_start.events` array may also contain switch-in ability
activations (for example Intimidate), so the client can show the same banner before the
first turn.

### `battle_end`
```json
{
  "type":"battle_end",
  "battleId":"<uuid>",
  "result":"won",
  "message":"You won 60 coins! Snivy evolved into Servine!",
  "travel":false,
  "evolution":{"fromSpecies":"snivy","fromName":"Snivy","fromTypes":["Grass"],
               "toSpecies":"servine","toName":"Servine","toTypes":["Grass"]},
  "battle":{ "...": "final battle state including XP/level-up log lines and remaining PP" },
  "player":{"money":560,"wins":1,"party":[...],"inventory":{"items":{"poke_ball":9,"potion":2}},
            "pokedex":{"seen":[495,504],"caught":[495,496]},
            "sprite":0,"mapId":"unova_full","x":788,"y":722,"dir":"up"}
}
```
`result` is `won|lost|fled|caught`. For a duel it is only `won|lost`; friendly duels
award no coins, wins or XP, do not move the character, and heal both parties before
`battle_end` is sent. A story battle (`mode:"trainer"`) is also only `won|lost`: XP is
awarded for every defeated team member, the trainer's `reward` is added to the win
payout, and a loss does **not** teleport the player home — the party is healed and the
story continues with the scene's lose pages. Winning a wild battle awards coins and XP; level-ups add stats,
learn moves when a slot is free, evolve the active creature when the level/condition is
met, and preserve spent PP. A full move set leaves the new move in `pendingMoves`; the
server follows `battle_end` with `move_learn_request`. Catching consumes the chosen ball,
marks the species caught and adds the wild creature to the party when there is room.
`evolution` is `null` unless an evolution happened. `fromTypes`/`toTypes` are the
species type arrays before and after evolving; the client needs the old pair because the
final `battle` snapshot already contains the evolved creature, and it uses them to draw
the pre-evolution sprite during the evolution sequence. On a loss the character is healed
(including PP), its status is cleared and it is moved to `game.json`'s `startingMap`
(Nuvema Town); when `travel` is true, a new `map_state` is sent immediately before
`battle_end`.

### `notice`
```json
{"type":"notice","text":"Your team was healed."}
```

### `pong`
```json
{"type":"pong","t":171234567890,"now":171234567891}
```

### `error`
```json
{"type":"error","message":"Incorrect username or password."}
```
The socket stays open for recoverable errors (wrong password, invalid name, rate
limit). Authentication/session errors during `resume` require logging in again.

## Server authority checklist

- Movement cooldown, bounds, collision, NPC blocking
- Starting map (`game.json` `startingMap`) and spawn coordinates
- Portal destinations and map membership
- Encounter rolls and wild creature generation
- Battle turn order, accuracy, damage, dual-type effectiveness, fainting, forced switches
- Catch chance, chosen ball, ball consumption, party capacity, caught-party insertion
- Battle medicine use, item consumption, revive/status rules, HP caps
- Party switching and active-creature selection
- XP awards, level-ups, stat growth, level evolution, pending move learning/forgetting
- Per-move PP loading, spending, zero-PP rejection and persistence
- Pokédex seen/caught registration, starter seeding and evolution registration
- Coins, item stacks, buying/selling prices, healing (HP/status/PP), respawn, persistence
- PC deposit/withdraw/swap limits and NPC proximity checks
- Chat length/rate limiting
- Username/character/starter validation and password hashing (scrypt)
