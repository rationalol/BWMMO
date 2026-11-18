/**
 * Two-account friend duel smoke test against a running server.
 *
 * Terminal 1:
 *   PORT=3571 DATA_DIR=../.tools/duel-smoke-data ENCOUNTER_RATE=0 npm start
 * Terminal 2:
 *   SMOKE_URL=ws://127.0.0.1:3571 npm run smoke:duel
 */
import assert from "node:assert/strict";
import WebSocket from "ws";

type Dict = Record<string, any>;
type Predicate = (message: Dict) => boolean;

const URL = process.env.SMOKE_URL ?? "ws://127.0.0.1:3571";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

class Client {
  private ws!: WebSocket;
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
  }

  open(): Promise<void> {
    this.ws = new WebSocket(URL);
    this.ws.on("message", (data) => this.onMessage(data.toString()));
    return new Promise((resolve, reject) => {
      if (this.ws.readyState === WebSocket.OPEN) {
        resolve();
        return;
      }
      if (
        this.ws.readyState === WebSocket.CLOSING ||
        this.ws.readyState === WebSocket.CLOSED
      ) {
        reject(new Error(`${this.name}: socket closed before open`));
        return;
      }
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

  waitForTypes(
    types: string[],
    predicate: Predicate = () => true,
    timeout = 8000
  ): Promise<Dict> {
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

  drain(type: string): void {
    this.queue = this.queue.filter((message) => message.type !== type);
  }

  send(message: Dict): void {
    this.ws.send(JSON.stringify(message));
  }

  close(): void {
    this.ws.close();
  }
}

const suffix = Math.random().toString(36).slice(2, 8).toUpperCase();
const password = "smoke123";
const accountA = `DuelA${suffix}`;
const accountB = `DuelB${suffix}`;
const nameA = `Iris${suffix}`;
const nameB = `Cilan${suffix}`;

async function register(
  client: Client,
  username: string,
  characterName: string,
  color: string,
  starter: string
): Promise<{ token: string; characterId: string; character: Dict; position: Dict }> {
  client.send({ type: "register", username, password });
  const auth = await client.waitFor("auth_ok");
  assert.equal(auth.character, null);
  client.send({ type: "create_character", name: characterName, color, starter });
  const created = await client.waitFor("character_created");
  const state = await client.waitFor("map_state");
  return {
    token: auth.token as string,
    characterId: created.character.id as string,
    character: created.character as Dict,
    position: {
      x: state.self.x,
      y: state.self.y,
      mapId: state.self.mapId
    }
  };
}

async function makeFriends(a: Client, b: Client, idsA: { characterId: string }, idsB: { characterId: string }) {
  a.drain("social_state");
  b.drain("social_state");
  a.send({ type: "friend_request", playerId: idsB.characterId });
  await b.waitFor(
    "social_state",
    (message) => (message.incomingRequests as Dict[]).length === 1
  );
  b.send({ type: "friend_accept", playerId: idsA.characterId });
  await a.waitFor(
    "social_state",
    (message) => (message.friends as Dict[]).length === 1
  );
  await b.waitFor(
    "social_state",
    (message) => (message.friends as Dict[]).length === 1
  );
}

function moveIndex(battle: Dict): number {
  const moves: Dict[] = battle.player.moves;
  const index = moves.findIndex((move) => Number(move.power ?? 0) > 0);
  return index >= 0 ? index : 0;
}

async function main(): Promise<void> {
  console.log(`Duel smoke testing ${URL} (suffix ${suffix})`);
  const a = new Client("A");
  const b = new Client("B");
  await a.open();
  const idsA = await register(a, accountA, nameA, "#e76f51", "snivy");
  await b.open();
  const idsB = await register(b, accountB, nameB, "#2a9d8f", "tepig");
  console.log("  [ok] two accounts entered the world");

  a.send({ type: "duel_request", playerId: idsB.characterId });
  await a.waitFor(
    "error",
    (message) => String(message.message).includes("only duel friends")
  );
  console.log("  [ok] duel requests are restricted to friends");

  await makeFriends(a, b, idsA, idsB);
  console.log("  [ok] accounts are mutual friends");

  a.drain("duel_request_sent");
  b.drain("duel_request");
  a.send({ type: "duel_request", playerId: idsB.characterId });
  const request = await b.waitFor("duel_request");
  assert.equal(request.fromName, nameA);
  assert.equal((await a.waitFor("duel_request_sent")).toName, nameB);

  b.send({ type: "duel_decline", playerId: idsA.characterId });
  assert.equal((await a.waitFor("duel_declined")).playerId, idsB.characterId);
  console.log("  [ok] the target can decline a duel request");

  a.drain("duel_request_sent");
  b.drain("duel_request");
  a.send({ type: "duel_request", playerId: idsB.characterId });
  await b.waitFor("duel_request");
  a.send({ type: "duel_cancel", playerId: idsB.characterId });
  await b.waitFor(
    "duel_request_cancelled",
    (message) => message.fromId === idsA.characterId
  );
  console.log("  [ok] the sender can cancel a duel request");

  a.drain("duel_request_sent");
  b.drain("duel_request");
  a.send({ type: "duel_request", playerId: idsB.characterId });
  await b.waitFor("duel_request");
  b.send({ type: "duel_accept", playerId: idsA.characterId });
  const startA = await a.waitFor("battle_start");
  const startB = await b.waitFor("battle_start");
  const battleA = startA.battle as Dict;
  const battleB = startB.battle as Dict;
  assert.equal(battleA.mode, "duel");
  assert.equal(battleB.mode, "duel");
  assert.equal(battleA.playerName, nameA);
  assert.equal(battleA.opponentName, nameB);
  assert.equal(battleB.playerName, nameB);
  assert.equal(battleB.opponentName, nameA);
  assert.equal(battleA.id, battleB.id);
  console.log("  [ok] accepting starts a shared duel with mirrored views");

  const battleId = battleA.id as string;
  const initialMoneyA = Number(idsA.character.money);
  const initialWinsA = Number(idsA.character.wins);
  const initialMoneyB = Number(idsB.character.money);
  const initialWinsB = Number(idsB.character.wins);

  a.send({
    type: "battle_action",
    battleId,
    action: "catch",
    itemId: "poke_ball"
  });
  await a.waitFor(
    "error",
    (message) => String(message.message).includes("Poké Balls")
  );
  a.send({
    type: "battle_action",
    battleId,
    action: "item",
    itemId: "potion",
    partyIndex: 0
  });
  await a.waitFor(
    "error",
    (message) => String(message.message).includes("cannot use items")
  );
  a.send({ type: "battle_action", battleId, action: "run" });
  await a.waitFor(
    "error",
    (message) => String(message.message).includes("cannot run")
  );
  console.log("  [ok] balls, medicine and running are rejected server-side");

  let currentA = battleA;
  let currentB = battleB;
  let sentTurnA = -1;
  let sentTurnB = -1;
  let endA: Dict | null = null;
  let endB: Dict | null = null;
  for (let guard = 0; guard < 30; guard++) {
    if (currentA.status !== "active" || currentB.status !== "active") break;
    if (currentA.awaitingAction && sentTurnA !== currentA.turn) {
      sentTurnA = currentA.turn;
      a.send({
        type: "battle_action",
        battleId,
        action: "move",
        moveIndex: moveIndex(currentA)
      });
    }
    if (currentB.awaitingAction && sentTurnB !== currentB.turn) {
      sentTurnB = currentB.turn;
      b.send({
        type: "battle_action",
        battleId,
        action: "move",
        moveIndex: moveIndex(currentB)
      });
    }
    const prevTurn = Math.min(currentA.turn, currentB.turn);
    const nextA = await a.waitForTypes(
      ["battle_turn", "battle_end"],
      (message) =>
        message.type === "battle_end" ||
        Number(message.battle?.turn ?? -1) > prevTurn
    );
    const nextB = await b.waitForTypes(
      ["battle_turn", "battle_end"],
      (message) =>
        message.type === "battle_end" ||
        Number(message.battle?.turn ?? -1) > prevTurn
    );
    currentA = nextA.battle as Dict;
    currentB = nextB.battle as Dict;
    if (nextA.type === "battle_end") endA = nextA;
    if (nextB.type === "battle_end") endB = nextB;
    if (endA && endB) break;
  }
  assert.ok(endA && endB, "both clients should receive battle_end");
  assert.ok(
    ["won", "lost"].includes(String(endA.result)) &&
      ["won", "lost"].includes(String(endB.result)),
    "duel results should be win/loss"
  );
  assert.notEqual(endA.result, endB.result, "one trainer wins and one loses");
  assert.equal(endA.travel, false);
  assert.equal(endB.travel, false);
  assert.equal(endA.battle.mode, "duel");
  assert.equal(endB.battle.mode, "duel");
  console.log(`  [ok] duel resolved (${endA.result}/${endB.result}) without black-out travel`);

  for (const [end, initialMoney, initialWins] of [
    [endA, initialMoneyA, initialWinsA],
    [endB, initialMoneyB, initialWinsB]
  ] as const) {
    const player = end.player as Dict;
    assert.equal(Number(player.money), initialMoney, "friendly duels pay no coins");
    assert.equal(Number(player.wins), initialWins, "friendly duels do not count as wins");
    for (const creature of player.party as Dict[]) {
      assert.equal(creature.hp, creature.maxHp, "both teams are healed after a duel");
    }
    assert.equal(player.mapId, end === endA ? idsA.position.mapId : idsB.position.mapId);
    assert.equal(player.x, end === endA ? idsA.position.x : idsB.position.x);
    assert.equal(player.y, end === endA ? idsA.position.y : idsB.position.y);
  }
  console.log("  [ok] no rewards, both teams healed and positions preserved");

  a.close();
  b.close();
  await sleep(300);
  console.log("Duel smoke test PASSED");
  process.exit(0);
}

main().catch((error) => {
  console.error("Duel smoke test FAILED");
  console.error(error);
  process.exit(1);
});
