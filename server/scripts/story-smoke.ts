/**
 * Story smoke test: a brand-new account plays the whole Nuvema prologue over
 * the real WebSocket protocol.
 *
 * Terminal 1 (from server/):
 *   PORT=3599 DATA_DIR=./data-story-smoke node .build/src/index.js
 * Terminal 2 (from server/):
 *   STORY_SMOKE_URL=ws://127.0.0.1:3599 node .build/scripts/story-smoke.js
 *
 * Flow: register -> create without a starter -> bedroom scene -> choose Tepig
 * -> two sparring battles (Bianca, then Cheren) -> Mom heals -> Route 1 gate is
 * locked without the Pokédex -> lab scene -> gate opens -> reconnect keeps the
 * partner.
 */
import assert from "node:assert/strict";
import WebSocket from "ws";
import { loadContent } from "../src/content/loader.js";
import { canStep, isWalkable } from "../src/game/maps.js";

type Dict = Record<string, any>;
type Predicate = (message: Dict) => boolean;

const content = loadContent();
const maps = content.maps;
const URL = process.env.STORY_SMOKE_URL ?? "ws://127.0.0.1:2567";
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
    if (message.type !== "hello" && message.type !== "pong") this.queue.push(message);
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

const STORY_TYPES = ["dialogue", "story_choice", "story_end"];
const isStoryMessage = (message: Dict): boolean =>
  (message.type === "dialogue" && message.kind === "story") ||
  message.type === "story_choice" ||
  message.type === "story_end";

/**
 * Click through every `say` page and return the message that paused the scene:
 * a `story_choice` prompt, a `battle_start`, or `story_end`.
 */
async function playPages(client: Client): Promise<Dict> {
  const types = [...STORY_TYPES, "battle_start"];
  let message = await client.waitForTypes(types, (entry) =>
    entry.type === "battle_start" ? true : isStoryMessage(entry)
  );
  while (message.type === "dialogue") {
    client.send({
      type: "story_advance",
      sceneId: message.sceneId,
      step: message.step
    });
    message = await client.waitForTypes(types, (entry) =>
      entry.type === "battle_start" ? true : isStoryMessage(entry)
    );
  }
  return message;
}

/**
 * Fight a scripted trainer battle to the end using the ordinary battle
 * protocol: attack with the first move that still has PP, and pick a healthy
 * replacement whenever the active creature faints.
 */
async function fightTrainer(client: Client, start: Dict): Promise<Dict> {
  assert.equal(start.type, "battle_start");
  assert.equal(start.battle.mode, "trainer", "story battles are trainer battles");
  const battleId = start.battle.id;
  let message = start;
  let guard = 0;
  while (message.type !== "battle_end" && guard++ < 40) {
    const battle = message.battle;
    if (!battle || battle.status !== "active" || !battle.awaitingAction) {
      message = await client.waitForTypes(["battle_turn", "battle_end"]);
      continue;
    }
    if (battle.mustSwitch) {
      const partyIndex = battle.party.findIndex(
        (creature: Dict, index: number) => creature.hp > 0 && index !== battle.activeIndex
      );
      assert.ok(partyIndex >= 0, "a scripted battle must leave a healthy replacement");
      client.send({ type: "battle_action", battleId, action: "switch", partyIndex });
    } else {
      const moveIndex = battle.player.moves.findIndex((move: Dict) => move.currentPp > 0);
      assert.ok(moveIndex >= 0, "the partner should still have a usable move");
      client.send({ type: "battle_action", battleId, action: "move", moveIndex });
    }
    message = await client.waitForTypes(["battle_turn", "battle_end"]);
  }
  assert.equal(message.type, "battle_end", "the sparring battle should finish");
  // The client reports that the result box is closed; only then does the
  // story resume with the win/lose pages.
  client.send({ type: "battle_closed" });
  return message;
}

let moveSeq = 0;
let lastMoveSentAt = 0;

/** Pace moves above the server's 130 ms cooldown so walks never race it. */
async function sendMove(client: Client, dir: string, running = false): Promise<Dict> {
  const wait = 160 - (Date.now() - lastMoveSentAt);
  if (wait > 0) await sleep(wait);
  lastMoveSentAt = Date.now();
  const seq = moveSeq++;
  client.send({ type: "move", dir, seq, run: running });
  return client.waitFor("move_ack", (message) => message.seq === seq);
}

async function move(client: Client, dir: string, running = false): Promise<Dict> {
  const ack = await sendMove(client, dir, running);
  assert.equal(ack.accepted, true, `${client.name}: move ${dir} was rejected (${ack.reason})`);
  await sleep(STEP_WAIT_MS);
  return ack;
}

/** Walk into a map transition while standing on its trigger tile. */
async function useDoor(client: Client, dir: string, targetMap: string): Promise<Dict> {
  const wait = 160 - (Date.now() - lastMoveSentAt);
  if (wait > 0) await sleep(wait);
  lastMoveSentAt = Date.now();
  client.send({ type: "move", dir, seq: moveSeq++ });
  const state = await client.waitFor("map_state", (message) => message.map.id === targetMap);
  await sleep(STEP_WAIT_MS);
  return state;
}

/** Press into a solid ROM door on the next tile. */
async function pushDoor(client: Client, dir: string, targetMap: string): Promise<Dict> {
  await sleep(160);
  return useDoor(client, dir, targetMap);
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
  for (const dir of path) await move(client, dir);
}

const suffix = Math.random().toString(36).slice(2, 8).toUpperCase();
const password = "smoke123";
const trainer = `Story${suffix}`;

async function main(): Promise<void> {
  console.log(`Story smoke testing ${URL} (${trainer})`);
  const c = new Client("story");
  await c.open();

  c.send({ type: "register", username: trainer, password });
  const auth = await c.waitFor("auth_ok");
  assert.equal(auth.character, null, "a new account must not have a character");
  const token = auth.token as string;

  // Original-game creation: no partner at character creation.
  c.send({ type: "create_character", name: trainer, color: "#e76f51", starter: "" });
  await c.waitFor("character_created");
  let state = await c.waitFor("map_state");
  assert.equal(state.map.id, "unova_in_391", "new characters wake up in their bedroom");
  assert.equal(state.self.x, 8);
  assert.equal(state.self.y, 2);
  assert.equal(state.self.party.length, 0, "the prologue has not handed out a partner yet");
  assert.ok(
    state.map.npcs.some((npc: Dict) => npc.id === "prologue_cheren_bedroom"),
    "Cheren is waiting in the bedroom"
  );
  assert.ok(
    state.map.npcs.some((npc: Dict) => npc.id === "prologue_bianca_bedroom"),
    "Bianca is waiting in the bedroom"
  );
  console.log("  [ok] a new trainer starts in the bedroom with an empty party");

  const begin = await c.waitFor("story_begin");
  assert.equal(begin.sceneId, "prologue_bedroom_intro");
  let stop = await playPages(c);
  assert.equal(stop.type, "story_choice", "the intro should ask for a partner");
  assert.deepEqual(
    (stop.options as Dict[]).map((option) => option.id),
    ["snivy", "tepig", "oshawott"]
  );
  assert.equal(stop.options[1].name, "Tepig");
  assert.equal(stop.options[1].level, 5);
  console.log("  [ok] the bedroom cutscene leads into the starter choice");

  c.send({ type: "story_choice", sceneId: stop.sceneId, step: stop.step, optionId: "tepig" });
  const partyState = await c.waitFor(
    "party_state",
    (message) => message.party?.[0]?.species === "tepig"
  );
  assert.equal(partyState.party[0].level, 5);
  assert.ok(partyState.party[0].moves.length > 0, "the partner should know moves");

  // Bianca challenges the player first; her partner is the one that beats the
  // player's pick (Tepig -> Oshawott), exactly like the ROM's trainer 59/60/61.
  stop = await playPages(c);
  assert.equal(stop.type, "battle_start", "Bianca should challenge the player");
  assert.equal(stop.battle.opponentName, "Bianca");
  assert.equal(stop.battle.trainerId, "bianca_oshawott");
  assert.equal(stop.battle.wild.species, "oshawott");
  let end = await fightTrainer(c, stop);
  assert.ok(["won", "lost"].includes(end.result));
  console.log(`  [ok] Bianca's sparring battle resolved (${end.result})`);

  // Cheren always mirrors the player's pick (ROM trainer 53/54/55).
  stop = await playPages(c);
  assert.equal(stop.type, "battle_start", "Cheren should challenge the player next");
  assert.equal(stop.battle.opponentName, "Cheren");
  assert.equal(stop.battle.trainerId, "cheren_tepig");
  assert.equal(stop.battle.wild.species, "tepig");
  end = await fightTrainer(c, stop);
  assert.ok(["won", "lost"].includes(end.result));
  console.log(`  [ok] Cheren's sparring battle resolved (${end.result})`);

  stop = await playPages(c);
  assert.equal(stop.type, "story_end", "the intro ends after the second battle");
  assert.equal(stop.sceneId, "prologue_bedroom_intro");
  const afterIntro = await c.waitFor("map_state", (message) => message.map.id === "unova_in_391");
  assert.equal(afterIntro.self.party.length, 1);
  assert.equal(afterIntro.self.party[0].species, "tepig");
  assert.equal(
    afterIntro.map.npcs.some((npc: Dict) => npc.id === "prologue_cheren_bedroom"),
    false,
    "Cheren and Bianca leave for the lab once both battles are over"
  );
  assert.ok(
    afterIntro.self.party[0].hp > 0,
    "Cheren heals the partner before the scene ends"
  );
  assert.ok(
    (afterIntro.self.pokedex.caught as number[]).includes(498),
    "the partner is registered in the Pokédex"
  );
  console.log("  [ok] choosing Tepig grants the partner and the room battles replay the ROM");

  // Downstairs: press right on the stair tile.
  state = await useDoor(c, "right", "unova_in_390");
  assert.equal(state.self.x, 3);
  assert.equal(state.self.y, 2);
  await walk(c, "unova_in_390", [3, 2], [5, 5]);
  c.send({ type: "interact", npcId: "z390_n0" });
  const momBegin = await c.waitFor("story_begin");
  assert.equal(momBegin.sceneId, "prologue_mom");
  stop = await playPages(c);
  assert.equal(stop.type, "story_end");
  const momNotice = await c.waitFor(
    "notice",
    (message) => String(message.text).includes("Mom healed")
  );
  assert.ok(momNotice);
  console.log("  [ok] Mom's scene heals the team and sets the prologue forward");

  // Out the front door, then try the north exit before visiting the lab.
  await walk(c, "unova_in_390", [5, 5], [6, 9]);
  await move(c, "down");
  state = await c.waitFor("map_state", (message) => message.map.id === "unova_full");
  assert.equal(state.self.x, 782);
  assert.equal(state.self.y, 749);
  const gateCheren = state.map.npcs.find(
    (npc: Dict) => npc.id === "prologue_route1_cheren"
  );
  assert.ok(gateCheren, "Cheren must be visible on the route 1 gate tiles");
  assert.equal(gateCheren.x, 788);
  assert.equal(gateCheren.y, 739);
  assert.equal(gateCheren.sprite, 12, "Cheren uses his own overworld sheet");
  console.log("  [ok] the story NPC standing on the gate is visible to the player");

  await walk(c, "unova_full", [782, 749], [788, 741]);
  const blocked = await sendMove(c, "up");
  assert.equal(blocked.accepted, false, "Route 1 must stay closed without the Pokédex");
  assert.equal(blocked.reason, "story_gate");
  const gateLines = await c.waitFor("dialogue", (message) => message.kind === "gate");
  assert.equal(gateLines.npcName, "Cheren");
  assert.ok(String(gateLines.lines?.[0]).includes("Hold on"));
  console.log("  [ok] the Route 1 gate blocks the road with Cheren's explanation");

  // The lab: entering it plays the Pokédex scene automatically.
  await walk(c, "unova_full", [788, 741], [777, 741]);
  state = await pushDoor(c, "up", "unova_in_396");
  assert.equal(state.self.x, 3);
  assert.equal(state.self.y, 11);
  const labBegin = await c.waitFor("story_begin");
  assert.equal(labBegin.sceneId, "prologue_juniper_pokedex");
  stop = await playPages(c);
  assert.equal(stop.type, "story_end");
  const dexNotice = await c.waitFor(
    "notice",
    (message) => String(message.text).includes("Route 1 is now open")
  );
  assert.ok(dexNotice);
  console.log("  [ok] Professor Juniper's scene hands over the Pokédex");

  // Back outside and through the gate that was locked a minute ago. Step off
  // the spawn tile first: the door portal stays locked underfoot so arriving
  // players do not bounce straight back out.
  await walk(c, "unova_in_396", [3, 11], [4, 10]);
  state = await useDoor(c, "down", "unova_full");
  assert.equal(state.self.x, 777);
  assert.equal(state.self.y, 741);
  assert.equal(
    state.map.npcs.some((npc: Dict) => npc.id === "prologue_route1_cheren"),
    false,
    "Cheren leaves the gate once the Pokédex unlocks the route"
  );
  await walk(c, "unova_full", [777, 741], [788, 741]);
  const openAck = await move(c, "up");
  assert.equal(openAck.x, 788);
  assert.equal(openAck.y, 740, "the former gate tile is walkable once the Pokédex is held");
  assert.equal(c.take("dialogue"), null, "no gate message should be sent");
  console.log("  [ok] the same road is open after the Pokédex scene");

  // Reconnecting must not replay the intro or lose the partner.
  c.close();
  await sleep(300);
  const c2 = new Client("story2");
  await c2.open();
  c2.send({ type: "resume", token });
  const auth2 = await c2.waitFor("auth_ok");
  assert.ok(auth2.character, "resume should restore the character");
  const restored = await c2.waitFor("map_state");
  assert.equal(restored.map.id, "unova_full");
  assert.equal(restored.self.party.length, 1);
  assert.equal(restored.self.party[0].species, "tepig");
  await sleep(250);
  assert.equal(c2.take("story_begin"), null, "a finished prologue must not restart");
  console.log("  [ok] reconnecting keeps the partner and does not replay the prologue");

  c2.close();
  await sleep(150);
  console.log("STORY SMOKE TEST PASSED");
}

main().catch((error) => {
  console.error("STORY SMOKE TEST FAILED");
  console.error(error);
  process.exit(1);
});
