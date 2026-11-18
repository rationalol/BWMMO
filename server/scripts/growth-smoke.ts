/**
 * End-to-end growth checks (tutor, reminder, TMs, item/trade evolution,
 * friendship, rename and release).
 *
 * Start the server with the story skipped so the test spawns in Nuvema:
 *   PORT=3567 DEBUG_SKIP_STORY=1 ENCOUNTER_RATE=0 \
 *     DATA_DIR=./data-growth-smoke npm start
 * Then:
 *   SMOKE_URL=ws://127.0.0.1:3567 npm run smoke:growth
 */
import assert from "node:assert/strict";
import WebSocket from "ws";
import { loadContent } from "../src/content/loader.js";
import { canStep, isWalkable } from "../src/game/maps.js";

type Dict = Record<string, any>;
type Predicate = (message: Dict) => boolean;

const content = loadContent();
const maps = content.maps;
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

  waitFor(type: string, predicate: Predicate = () => true, timeout = 8000): Promise<Dict> {
    return this.waitForTypes([type], predicate, timeout);
  }

  waitForTypes(types: string[], predicate: Predicate = () => true, timeout = 8000): Promise<Dict> {
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
      this.waiters.push({ types, predicate, resolve, timer });
    });
  }

  send(message: Dict): void {
    this.ws.send(JSON.stringify(message));
  }

  close(): void {
    this.ws.close();
  }
}

let moveSeq = 0;

async function move(client: Client, dir: string): Promise<Dict> {
  const seq = moveSeq++;
  client.send({ type: "move", dir, seq });
  const ack = await client.waitFor("move_ack", (message) => message.seq === seq);
  assert.equal(ack.accepted, true, `${client.name}: move ${dir} was rejected (${ack.reason})`);
  await sleep(STEP_WAIT_MS);
  return ack;
}

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

/** Answers every story page until `story_end`; returns the scene id. */
async function finishStory(client: Client): Promise<string> {
  const begin = await client.waitFor("story_begin");
  const sceneId = String(begin.sceneId);
  while (true) {
    const next = await client.waitForTypes(
      ["dialogue", "story_choice", "story_end"],
      () => true,
      8000
    );
    if (next.type === "story_end") return sceneId;
    if (next.type === "story_choice") {
      throw new Error(`${client.name}: unexpected story choice in ${sceneId}`);
    }
    client.send({ type: "story_advance", sceneId });
  }
}

const suffix = Math.random().toString(36).slice(2, 8).toUpperCase();
const password = "smoke123";
const name = `Growth${suffix}`;

async function main(): Promise<void> {
  console.log(`Growth smoke testing ${URL} (suffix ${suffix})`);
  const a = new Client("A");
  await a.open();
  a.send({ type: "register", username: name, password });
  const auth = await a.waitFor("auth_ok");
  assert.equal(auth.character, null);
  a.send({ type: "create_character", name, color: "#e76f51", starter: "snivy" });
  const state = await a.waitFor("map_state");
  assert.equal(state.map.id, "unova_full", "start the server with DEBUG_SKIP_STORY=1");
  console.log("  [ok] created a post-prologue character");

  await walk(a, "unova_full", [784, 753], [786, 751]);
  await walk(a, "unova_full", [786, 751], [777, 741]);
  await pushDoor(a, "up", "unova_in_396");
  console.log("  [ok] reached Professor Juniper's Lab");

  // The first talk runs the test-kit scene: items plus three training partners.
  await walk(a, "unova_in_396", [3, 11], [12, 8]);
  a.send({ type: "interact", npcId: "test_lab_supply" });
  await finishStory(a);
  const kit = await a.waitFor("party_state", (message) => message.party?.length === 4);
  assert.deepEqual(
    kit.party.map((creature: Dict) => creature.species),
    ["snivy", "pikachu", "kadabra", "golbat"]
  );
  assert.equal(kit.inventory.items.tm_workup, 1);
  assert.equal(kit.inventory.items.thunderstone, 1);
  assert.equal(kit.inventory.items.firestone, 1);
  console.log("  [ok] test kit grants TMs, stones and three partners");

  a.send({ type: "interact", npcId: "test_lab_supply" });
  await a.waitFor("dialogue", (message) => message.npcId === "test_lab_supply");
  const labShop = await a.waitFor("shop_state");
  assert.equal(labShop.shop.id, "lab_supply");
  assert.ok(labShop.shop.items.some((item: Dict) => item.id === "tm_toxic"));
  console.log("  [ok] Lab Supply opens its shop after the kit");

  // Move tutor.
  await walk(a, "unova_in_396", [12, 8], [8, 8]);
  a.send({ type: "interact", npcId: "test_move_tutor" });
  await a.waitFor("dialogue", (message) => message.npcId === "test_move_tutor");
  const tutorState = await a.waitFor("move_service");
  assert.equal(tutorState.service, "tutor");
  assert.ok(tutorState.moves.some((moveDef: Dict) => moveDef.id === "workup"));
  a.send({
    type: "teach_move",
    npcId: "test_move_tutor",
    partyIndex: 0,
    moveId: "workup"
  });
  const tutorPrompt = await a.waitFor(
    "move_learn_request",
    (message) => message.moveId === "workup"
  );
  assert.equal(tutorPrompt.source, "party");
  a.send({
    type: "learn_move",
    source: "party",
    index: 0,
    moveId: "workup",
    replaceIndex: 0
  });
  await a.waitFor(
    "party_state",
    (message) => message.party?.[0]?.moves?.some((moveDef: Dict) => moveDef.id === "workup")
  );
  console.log("  [ok] move tutor teaches through the learn prompt");

  // Move reminder: forget Tackle, then remember it again.
  a.send({ type: "forget_move", partyIndex: 0, moveIndex: 0 });
  await a.waitFor(
    "party_state",
    (message) => message.party?.[0]?.moves?.length === 2
  );
  a.send({ type: "interact", npcId: "test_move_reminder" });
  await a.waitFor("dialogue", (message) => message.npcId === "test_move_reminder");
  const reminderState = await a.waitFor("move_service");
  assert.equal(reminderState.service, "reminder");
  const relearn = reminderState.party?.[0]?.relearn ?? [];
  assert.ok(relearn.some((moveDef: Dict) => moveDef.id === "tackle"));
  a.send({
    type: "teach_move",
    npcId: "test_move_reminder",
    partyIndex: 0,
    moveId: "tackle"
  });
  await a.waitFor("move_learn_request", (message) => message.moveId === "tackle");
  a.send({
    type: "learn_move",
    source: "party",
    index: 0,
    moveId: "tackle",
    replaceIndex: 0
  });
  await a.waitFor(
    "party_state",
    (message) => message.party?.[0]?.moves?.some((moveDef: Dict) => moveDef.id === "tackle")
  );
  console.log("  [ok] move reminder remembers forgotten level-up moves");

  // TM item: reusable, queues the move and uses the same learn prompt.
  a.send({ type: "use_item", itemId: "tm_toxic", partyIndex: 0 });
  await a.waitFor("move_learn_request", (message) => message.moveId === "toxic");
  a.send({
    type: "learn_move",
    source: "party",
    index: 0,
    moveId: "toxic",
    replaceIndex: 0
  });
  const afterTm = await a.waitFor(
    "party_state",
    (message) => message.party?.[0]?.moves?.some((moveDef: Dict) => moveDef.id === "toxic")
  );
  assert.equal(afterTm.inventory.items.tm_toxic, 1, "TMs are reusable");
  console.log("  [ok] TM teaches a move and stays in the bag");

  // Item evolution: Thunder Stone on Pikachu.
  a.send({ type: "use_item", itemId: "thunderstone", partyIndex: 1 });
  const itemEvolution = await a.waitFor(
    "evolution_event",
    (message) => message.evolution?.toSpecies === "raichu"
  );
  assert.equal(itemEvolution.evolution.fromSpecies, "pikachu");
  const afterItem = await a.waitFor(
    "party_state",
    (message) => message.party?.[1]?.species === "raichu"
  );
  assert.equal(afterItem.inventory.items.thunderstone ?? 0, 0);
  console.log("  [ok] Thunder Stone evolves Pikachu and is consumed");

  // Trade evolution: Kadabra at the link-trade station.
  await walk(a, "unova_in_396", [8, 8], [10, 8]);
  a.send({ type: "interact", npcId: "test_link_trade" });
  await a.waitFor("dialogue", (message) => message.npcId === "test_link_trade");
  const tradeState = await a.waitFor("trade_service");
  assert.equal(tradeState.party?.[2]?.tradeable, true);
  a.send({
    type: "trade_evolve",
    npcId: "test_link_trade",
    partyIndex: 2
  });
  await a.waitFor(
    "evolution_event",
    (message) => message.evolution?.toSpecies === "alakazam"
  );
  await a.waitFor(
    "party_state",
    (message) => message.party?.[2]?.species === "alakazam"
  );
  console.log("  [ok] link trade evolves Kadabra into Alakazam");

  // Friendship service.
  await walk(a, "unova_in_396", [10, 8], [12, 8]);
  a.send({ type: "interact", npcId: "test_bond_expert" });
  await a.waitFor("dialogue", (message) => message.npcId === "test_bond_expert");
  const bonded = await a.waitFor(
    "party_state",
    (message) =>
      Array.isArray(message.party) &&
      message.party.length > 0 &&
      message.party.every((creature: Dict) => creature.friendship === 255)
  );
  assert.equal(bonded.party[3].species, "golbat");
  console.log("  [ok] Bond Expert maxes party friendship");

  // Rename, deposit and release through the test PC.
  await walk(a, "unova_in_396", [12, 8], [13, 10]);
  a.send({ type: "interact", npcId: "test_pc" });
  await a.waitFor("dialogue", (message) => message.npcId === "test_pc");
  await a.waitFor("pc_state");
  a.send({
    type: "rename_creature",
    source: "party",
    index: 0,
    name: "Smoky"
  });
  await a.waitFor(
    "party_state",
    (message) => message.party?.[0]?.name === "Smoky"
  );
  a.send({ type: "pc_deposit", partyIndex: 3 });
  const deposited = await a.waitFor("pc_state", (message) => message.box?.length === 1);
  assert.equal(deposited.party.length, 3, "deposit should leave three party members");
  a.send({ type: "pc_release", boxIndex: 0 });
  const released = await a.waitFor(
    "pc_state",
    (message) => message.box?.length === 0 && message.party?.length === 3
  );
  assert.equal(
    released.party.length,
    3,
    `release party: ${released.party.map((creature: Dict) => creature.name).join(", ")}`
  );
  console.log("  [ok] rename, deposit and release work from the PC");

  a.close();
  console.log("GROWTH SMOKE TEST PASSED");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
