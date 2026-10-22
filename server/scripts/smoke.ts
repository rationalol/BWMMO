/**
 * End-to-end smoke test against a running server.
 *
 * Terminal 1:
 *   PORT=3567 DATA_DIR=./data-smoke npm start
 * Terminal 2:
 *   SMOKE_URL=ws://127.0.0.1:3567 npm run smoke
 */
import assert from "node:assert/strict";
import WebSocket from "ws";
import { loadContent } from "../src/content/loader.js";
import { canStep, isWalkable } from "../src/game/maps.js";

type Dict = Record<string, any>;

const content = loadContent();
const maps = content.maps;
type Predicate = (message: Dict) => boolean;

const URL = process.env.SMOKE_URL ?? "ws://127.0.0.1:2567";
const STEP_WAIT_MS = 180;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

class Client {
  private ws: WebSocket;
  private queue: Dict[] = [];
  private waiters: Array<{
    types: string[];
    predicate: Predicate;
    resolve: (message: Dict) => void;
    reject: (error: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }> = [];
  public readonly name: string;

  constructor(name: string) {
    this.name = name;
    this.ws = new WebSocket(URL);
    this.ws.on("message", (data) => this.onMessage(data.toString()));
  }

  open(): Promise<void> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${this.name}: open timeout`)), 5000);
      this.ws.once("open", () => {
        clearTimeout(timer);
        resolve();
      });
      this.ws.once("error", (error) => {
        clearTimeout(timer);
        reject(error);
      });
    });
  }

  private onMessage(raw: string): void {
    let message: Dict;
    try {
      message = JSON.parse(raw);
    } catch {
      return;
    }
    if (message.type === "error") {
      console.warn(`[${this.name}] server error:`, message.message);
    }
    const index = this.waiters.findIndex(
      (waiter) => waiter.types.includes(message.type) && waiter.predicate(message)
    );
    if (index >= 0) {
      const [waiter] = this.waiters.splice(index, 1);
      clearTimeout(waiter.timer);
      waiter.resolve(message);
      return;
    }
    if (message.type !== "hello" && message.type !== "pong") {
      this.queue.push(message);
    }
  }

  waitFor(type: string, predicate: Predicate = () => true, timeout = 5000): Promise<Dict> {
    return this.waitForTypes([type], predicate, timeout);
  }

  waitForTypes(types: string[], predicate: Predicate = () => true, timeout = 5000): Promise<Dict> {
    const index = this.queue.findIndex(
      (message) => types.includes(message.type) && predicate(message)
    );
    if (index >= 0) {
      const [message] = this.queue.splice(index, 1);
      return Promise.resolve(message);
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const pending = this.waiters.find((waiter) => waiter.timer === timer);
        if (pending) this.waiters.splice(this.waiters.indexOf(pending), 1);
        reject(new Error(`${this.name}: timed out waiting for ${types.join("|")}`));
      }, timeout);
      this.waiters.push({ types, predicate, resolve, reject, timer });
    });
  }

  take(type: string): Dict | null {
    const index = this.queue.findIndex((message) => message.type === type);
    if (index < 0) return null;
    return this.queue.splice(index, 1)[0];
  }

  send(message: Dict): void {
    this.ws.send(JSON.stringify(message));
  }

  close(): void {
    this.ws.close();
  }
}

let moveSeq = 0;

async function move(client: Client, dir: string, running = false): Promise<Dict> {
  const seq = moveSeq++;
  client.send({ type: "move", dir, seq, run: running });
  const ack = await client.waitFor("move_ack", (message) => message.seq === seq);
  assert.equal(ack.accepted, true, `${client.name}: move ${dir} was rejected (${ack.reason})`);
  assert.equal(ack.run, running, `${client.name}: run flag was not echoed`);
  await sleep(STEP_WAIT_MS);
  return ack;
}

/**
 * Press into a door while standing on its trigger tile. A solid ROM door
 * answers with a map_state instead of a move_ack.
 */
async function pushDoor(client: Client, dir: string, mapId: string): Promise<Dict> {
  const seq = moveSeq++;
  client.send({ type: "move", dir, seq });
  const state = await client.waitFor("map_state", (message) => message.map.id === mapId);
  await sleep(STEP_WAIT_MS);
  return state;
}

function findPath(
  mapId: string,
  start: [number, number],
  goal: [number, number]
): string[] | null {
  const map = maps[mapId];
  if (!map) throw new Error(`unknown map ${mapId}`);
  const npcs = new Set(map.npcs.map((npc) => `${npc.x},${npc.y}`));
  const portals = new Set(map.portals.map((portal) => `${portal.x},${portal.y}`));
  const goalKey = `${goal[0]},${goal[1]}`;
  // Wide doorways are several portal tiles in a row. Walking inside one is
  // safe, but stepping into it from normal floor triggers the door, so track
  // whether the walker is already on a door tile.
  const startKey = `${start[0]},${start[1]}`;
  const stateKey = (x: number, y: number, onDoor: boolean) => `${x},${y},${onDoor ? 1 : 0}`;
  const startState = stateKey(start[0], start[1], portals.has(startKey));
  const queue: Array<[number, number, boolean]> = [
    [start[0], start[1], portals.has(startKey)]
  ];
  const previous = new Map<string, { from: string; dir: string }>();
  previous.set(startState, { from: "", dir: "" });

  const reconstruct = (state: string): string[] => {
    const path: string[] = [];
    let current = state;
    while (current !== startState) {
      const entry = previous.get(current)!;
      path.push(entry.dir);
      current = entry.from;
    }
    return path.reverse();
  };

  while (queue.length > 0) {
    const [x, y, onDoor] = queue.shift()!;
    for (const [dir, dx, dy] of [
      ["up", 0, -1],
      ["down", 0, 1],
      ["left", -1, 0],
      ["right", 1, 0]
    ] as const) {
      const nx = x + dx;
      const ny = y + dy;
      const key = `${nx},${ny}`;
      if (!isWalkable(map, nx, ny) || !canStep(map, x, y, nx, ny)) continue;
      if (npcs.has(key)) continue;
      const entersDoor = portals.has(key);
      // Entering a doorway from normal floor warps, so only the destination
      // may be a door tile. Walking inside an already-entered doorway is fine.
      if (entersDoor && !onDoor && key !== goalKey) continue;
      const next = stateKey(nx, ny, entersDoor);
      if (key === goalKey) {
        if (entersDoor && onDoor) continue;
        previous.set(next, { from: stateKey(x, y, onDoor), dir });
        return reconstruct(next);
      }
      if (previous.has(next)) continue;
      previous.set(next, { from: stateKey(x, y, onDoor), dir });
      queue.push([nx, ny, entersDoor]);
    }
  }
  return null;
}

async function walk(
  client: Client,
  mapId: string,
  start: [number, number],
  goal: [number, number]
): Promise<void> {
  const path = findPath(mapId, start, goal);
  assert.ok(path, `${client.name}: no path from ${start} to ${goal} on ${mapId}`);
  for (const dir of path) {
    await move(client, dir);
  }
}

async function moveUntilBattle(client: Client, dirs: string[]): Promise<Dict> {
  for (const dir of dirs) {
    const battle = client.take("battle_start");
    if (battle) return battle;
    await move(client, dir);
  }
  const battle = client.take("battle_start");
  if (battle) return battle;
  return client.waitFor("battle_start", () => true, 8000);
}

const suffix = Math.random().toString(36).slice(2, 8).toUpperCase();
const password = "smoke123";
const nameA = `SmokeA${suffix}`;
const nameB = `SmokeB${suffix}`;

async function main(): Promise<void> {
  console.log(`Smoke testing ${URL} (suffix ${suffix})`);

  const a = new Client("A");
  await a.open();
  a.send({ type: "register", username: nameA, password });
  const authA = await a.waitFor("auth_ok");
  assert.equal(authA.character, null, "new account should not have a character");
  assert.equal(authA.starters.length, 3, "server should offer three starters");
  const tokenA = authA.token as string;
  assert.equal(authA.maxParty, 6);

  a.send({ type: "create_character", name: nameA, color: "#e76f51", starter: "snivy" });
  await a.waitFor("character_created");
  let stateA = await a.waitFor("map_state");
  assert.equal(stateA.map.id, "unova_full", "new characters should start in the seamless world");
  assert.equal(stateA.map.name, "Unova");
  assert.equal(stateA.self.x, 784);
  assert.equal(stateA.self.y, 753);
  assert.ok(stateA.map.visual, "server should own the visual chunk manifest");
  assert.equal(stateA.map.visual.chunks.length, 109);
  assert.equal(stateA.map.visual.originZ, -248);
  assert.equal(stateA.map.windowed, true, "the seamless map should send a local tile window");
  assert.equal(stateA.map.tileX, 752);
  assert.equal(stateA.map.tileY, 721);
  assert.equal(stateA.map.tileWidth, 65);
  assert.equal(stateA.map.tileHeight, 65);
  assert.equal(stateA.map.tiles.length, 65);
  assert.equal(stateA.map.tiles[0].length, 65);
  assert.equal(stateA.map.tiles[32][32], maps.unova_full.tiles[753][784]);
  assert.ok(stateA.map.tiles.length < stateA.map.height, "map_state should not carry the full grid");
  assert.deepEqual(stateA.self.pokedex, { seen: [495], caught: [495] });
  a.send({ type: "pokedex_request" });
  const dexState = await a.waitFor("pokedex_state", (message) => Boolean(message.entries));
  assert.equal(dexState.total, 649);
  assert.equal(dexState.entries.length, 649);
  assert.ok(dexState.entries.some((entry: Dict) => entry.dex === 495 && entry.name === "Snivy"));
  console.log("  [ok] pokedex starts with the starter and serves all 649 entries");
  console.log("  [ok] map_state carries a 65x65 tile window instead of the full grid");
  console.log("  [ok] account + character creation in seamless Unova");

  const b = new Client("B");
  await b.open();
  b.send({ type: "register", username: nameB, password });
  const authB = await b.waitFor("auth_ok");
  assert.equal(authB.character, null);
  b.send({ type: "create_character", name: nameB, color: "#2a9d8f", starter: "tepig" });
  await b.waitFor("character_created");
  const stateB = await b.waitFor("map_state");
  assert.equal(stateB.map.id, "unova_full");
  assert.ok(stateB.players.some((player: Dict) => player.name === nameA));
  const joinedA = await a.waitFor("player_joined", (message) => message.player.name === nameB);
  assert.ok(joinedA.player.id);
  console.log("  [ok] second player joins Unova; both clients see each other");

  await move(a, "right");
  const movedB = await b.waitFor(
    "player_moved",
    (message) => message.playerId === stateA.self.id
  );
  assert.equal(movedB.x, 785);
  assert.equal(movedB.y, 753);
  console.log("  [ok] server-authoritative movement is broadcast in the 3D world");

  a.send({ type: "chat", text: "hello from the smoke test" });
  const chatB = await b.waitFor("chat", (message) => message.name === nameA);
  assert.equal(chatB.text, "hello from the smoke test");
  assert.equal(chatB.mapName, "Unova");
  console.log("  [ok] global chat");

  const runAck = await move(a, "left", true);
  assert.equal(runAck.run, true);
  const runSeen = await b.waitFor(
    "player_moved",
    (message) => message.playerId === stateA.self.id && message.x === 784 && message.run === true
  );
  assert.equal(runSeen.y, 753);
  console.log("  [ok] run state is broadcast to nearby players");

  const turnPromise = b.waitFor(
    "player_turned",
    (message) => message.playerId === stateA.self.id && message.dir === "up"
  );
  a.send({ type: "turn", dir: "up" });
  const turned = await turnPromise;
  assert.equal(turned.x, 784, "turning in place must not move the character");
  assert.equal(turned.y, 753, "turning in place must not move the character");
  assert.equal(turned.mapId, "unova_full");
  console.log("  [ok] turning in place is broadcast without moving");

  // Nuvema service corner: PC, nurse and Mart clerk stand south of the spawn.
  await walk(a, "unova_full", [784, 753], [784, 760]);

  a.send({ type: "interact", npcId: "nurse_joy" });
  const nurseDialogue = await a.waitFor(
    "dialogue",
    (message) => message.npcId === "nurse_joy"
  );
  assert.equal(nurseDialogue.kind, "healer");
  const healed = await a.waitFor("notice", (message) =>
    String(message.text ?? message.message ?? "").includes("healed")
  );
  assert.ok(healed);
  console.log("  [ok] Nurse Joy heals the party and cures status");

  a.send({ type: "interact", npcId: "pc_terminal" });
  const pcState = await a.waitFor("pc_state");
  assert.equal(pcState.party.length, 1);
  assert.equal(pcState.box.length, 0);
  assert.equal(pcState.maxBox, 30);
  a.send({ type: "pc_deposit", partyIndex: 0 });
  const pcError = await a.waitFor("error", (message) =>
    String(message.message).includes("at least one")
  );
  assert.ok(pcError);
  console.log("  [ok] PC refuses to deposit the last party member");

  a.send({ type: "interact", npcId: "mart_clerk" });
  const clerkDialogue = await a.waitFor(
    "dialogue",
    (message) => message.npcId === "mart_clerk"
  );
  assert.equal(clerkDialogue.kind, "shop");
  const shopState = await a.waitFor("shop_state");
  assert.equal(shopState.shop.id, "nuvema_mart");
  assert.ok(
    shopState.shop.items.some((item: Dict) => item.id === "poke_ball" && item.price === 200),
    "the Mart should sell Poke Balls"
  );
  assert.ok(
    shopState.shop.items.some((item: Dict) => item.id === "potion" && item.price === 300),
    "the Mart should sell Potions"
  );
  assert.equal(shopState.money, 500);
  console.log("  [ok] Mart clerk opens the shop catalog");

  a.send({ type: "shop_buy", shopId: "nuvema_mart", itemId: "potion", qty: 1 });
  const afterBuy = await a.waitFor(
    "shop_state",
    (message) => message.inventory?.items?.potion === 4
  );
  assert.equal(afterBuy.money, 200, "buying a potion should cost 300 coins");
  assert.equal(afterBuy.inventory.items.poke_ball, 10);
  console.log("  [ok] buying an item spends coins and adds to the bag");

  a.send({ type: "shop_sell", shopId: "nuvema_mart", itemId: "potion", qty: 1 });
  const afterSell = await a.waitFor(
    "shop_state",
    (message) => message.inventory?.items?.potion === 3
  );
  assert.equal(afterSell.money, 350, "selling a potion should return 150 coins");
  console.log("  [ok] selling an item returns coins");

  await walk(a, "unova_full", [784, 760], [786, 751]);

  await walk(a, "unova_full", [786, 751], [777, 741]);
  // The lab door trigger is the doorstep; walking onto it does not enter.
  // Press north into the door itself.
  const labState = await pushDoor(a, "up", "unova_in_396");
  assert.equal(labState.map.name, "Professor Juniper's Lab");
  assert.equal(labState.self.x, 3);
  assert.equal(labState.self.y, 11);
  assert.equal(labState.self.dir, "up", "entering the lab should face into the room");
  assert.equal(labState.map.visual.originZ, -248);
  console.log("  [ok] entered the Nuvema lab through its outdoor door");

  await walk(a, "unova_in_396", [3, 11], [4, 10]);
  await move(a, "down");
  const outsideState = await a.waitFor("map_state", (message) => message.map.id === "unova_full");
  assert.equal(outsideState.self.x, 777);
  assert.equal(outsideState.self.y, 741);
  assert.equal(outsideState.self.dir, "down", "leaving the lab should face the street");
  console.log("  [ok] exited the lab back onto the seamless overworld");

  // Walk far enough south to approach the window edge; the server should
  // stream a fresh slice before the client can predict past it.
  await walk(a, "unova_full", [777, 741], [777, 758]);
  const mapWindow = await a.waitFor("map_window", (message) => message.mapId === "unova_full");
  assert.equal(mapWindow.width, 65);
  assert.equal(mapWindow.height, 65);
  assert.equal(mapWindow.tiles.length, 65);
  assert.ok(mapWindow.x <= 777 && 777 < mapWindow.x + mapWindow.width);
  assert.ok(mapWindow.y <= 758 && 758 < mapWindow.y + mapWindow.height);
  assert.ok(mapWindow.y > 709, "the window should recentre as the player moves south");
  assert.equal(
    mapWindow.tiles[758 - mapWindow.y][777 - mapWindow.x],
    maps.unova_full.tiles[758][777]
  );
  console.log("  [ok] map_window recentred the tile slice near the window edge");

  await walk(a, "unova_full", [777, 758], [788, 736]);
  const crossedSeam = await b.waitFor(
    "player_moved",
    (message) =>
      message.playerId === stateA.self.id && message.x === 788 && message.y === 736
  );
  assert.equal(crossedSeam.mapId, "unova_full");
  console.log("  [ok] crossed the Nuvema/Route 1 seam without a map transition");

  const battleStart = await moveUntilBattle(a, Array(20).fill("up"));
  assert.ok(battleStart.battle.id);
  assert.ok(battleStart.battle.wild.species);
  assert.ok(
    ["patrat", "lillipup"].includes(battleStart.battle.wild.species),
    `unexpected Route 1 species ${battleStart.battle.wild.species}`
  );
  assert.ok(
    battleStart.battle.wild.level >= 2 && battleStart.battle.wild.level <= 4,
    "Route 1 wild levels should be 2..4"
  );
  console.log(
    `  [ok] tall grass encounter: ${battleStart.battle.wild.name} L${battleStart.battle.wild.level}`
  );
  const wildDex = Number(
    dexState.entries.find((entry: Dict) => entry.id === battleStart.battle.wild.species)?.dex
  );
  const seenState = await a.waitFor(
    "pokedex_state",
    (message) => Array.isArray(message.seen) && message.seen.includes(wildDex)
  );
  assert.equal(seenState.caught.includes(wildDex), false, "a sighting is not a capture");
  console.log("  [ok] encountering a wild species marks it as seen");

  a.send({
    type: "battle_action",
    battleId: battleStart.battle.id,
    action: "move",
    moveIndex: 0
  });
  let update = await a.waitForTypes(["battle_turn", "battle_end"], () => true, 8000);
  assert.ok(update.battle);
  assert.ok(Array.isArray(update.battle.log) && update.battle.log.length > 0);
  const usedMove = update.battle.player.moves[0];
  assert.ok(usedMove.currentPp < usedMove.maxPp, "spent PP should be synced back");
  assert.equal(usedMove.maxPp, content.moves[usedMove.id].pp);
  console.log("  [ok] battle syncs spent PP back to the persisted party state");

  let guard = 0;
  while (
    update.type === "battle_turn" &&
    update.battle.status === "active" &&
    update.battle.awaitingAction &&
    guard++ < 10
  ) {
    a.send({
      type: "battle_action",
      battleId: battleStart.battle.id,
      action: "run"
    });
    update = await a.waitForTypes(["battle_turn", "battle_end"], () => true, 8000);
  }
  if (update.type === "battle_turn") {
    assert.notEqual(update.battle.status, "active", "battle should finish");
    update = await a.waitFor("battle_end", () => true, 8000);
  }
  assert.equal(update.type, "battle_end", "battle should finish");
  assert.notEqual(update.result, "lost", "starter should not black out");
  const afterBattle = update.player;
  assert.equal(afterBattle.mapId, "unova_full");
  assert.ok(Number.isInteger(afterBattle.x) && Number.isInteger(afterBattle.y));
  console.log(`  [ok] server resolved the battle (${update.result})`);

  a.close();
  await sleep(300);
  const a2 = new Client("A2");
  await a2.open();
  a2.send({ type: "resume", token: tokenA });
  const authA2 = await a2.waitFor("auth_ok");
  assert.ok(authA2.character, "resume should restore the character");
  const stateA2 = await a2.waitFor("map_state");
  assert.equal(stateA2.self.name, nameA);
  assert.equal(stateA2.map.id, "unova_full");
  assert.equal(stateA2.self.x, afterBattle.x);
  assert.equal(stateA2.self.y, afterBattle.y);
  assert.ok(stateA2.self.pokedex.seen.includes(wildDex));
  assert.ok(stateA2.self.pokedex.caught.includes(495));
  assert.equal(
    stateA2.self.party[0].moves[0].currentPp,
    afterBattle.party[0].moves[0].currentPp,
    "PP should survive a reconnect"
  );
  console.log("  [ok] reconnect restores position, Pokédex and spent PP");

  const starterHp = Number(stateA2.self.party[0].hp);
  const starterMax = Number(stateA2.self.party[0].maxHp);
  const potionsBefore = Number(stateA2.self.inventory.items.potion);
  a2.send({ type: "use_item", itemId: "potion", partyIndex: 0 });
  if (starterHp < starterMax) {
    const healedParty = await a2.waitFor(
      "party_state",
      (message) => message.party?.[0]?.hp > starterHp
    );
    assert.equal(healedParty.inventory.items.potion, potionsBefore - 1);
    console.log(
      `  [ok] potion healed the starter ${starterHp} -> ${healedParty.party[0].hp} HP`
    );
  } else {
    await a2.waitFor("error", (message) =>
      String(message.message).includes("full HP")
    );
    console.log("  [ok] potion is rejected at full HP");
  }

  a2.send({ type: "chat", text: "reconnected in seamless Unova" });
  const chatB2 = await b.waitFor(
    "chat",
    (message) => message.text === "reconnected in seamless Unova"
  );
  assert.equal(chatB2.name, nameA);
  console.log("  [ok] chat after reconnect");

  b.close();
  a2.close();
  await sleep(200);
  console.log("SMOKE TEST PASSED");
}

main().catch((error) => {
  console.error("SMOKE TEST FAILED");
  console.error(error);
  process.exit(1);
});
