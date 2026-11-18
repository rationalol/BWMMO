import test from "node:test";
import assert from "node:assert/strict";
import { CONFIG } from "../src/config.js";
import { withinView } from "../src/game/maps.js";
import type { Conn, Dict, PlayerSession } from "../src/game/protocol.js";
import { VisibilityService } from "../src/game/visibility.js";

interface Harness {
  visibility: VisibilityService;
  sent: Map<string, Dict[]>;
  players: PlayerSession[];
}

function makeHarness(): Harness {
  const sent = new Map<string, Dict[]>();
  const visibility = new VisibilityService((conn, message) => {
    const key = conn.accountId ?? "unknown";
    const queue = sent.get(key) ?? [];
    queue.push(message);
    sent.set(key, queue);
  });
  return { visibility, sent, players: [] };
}

function makePlayer(id: string, mapId: string, x: number, y: number): PlayerSession {
  const conn = {
    ws: {},
    ip: "test",
    accountId: id,
    player: null,
    locale: "en",
    messageTimes: [],
    alive: true
  } as unknown as Conn;
  return {
    conn,
    accountId: id,
    username: id,
    character: {
      id: `char-${id}`,
      name: id,
      color: "#fff",
      mapId,
      x,
      y,
      dir: "down",
      sprite: 0,
      money: 0,
      wins: 0,
      party: [],
      box: [],
      inventory: { items: {} },
      pokedex: { seen: [], caught: [] },
      storyFlags: {}
    },
    lastMoveAt: 0,
    lastChatAt: 0,
    lastDirectAt: 0,
    battleId: null,
    encounterGraceUntil: 0,
    visiblePlayers: new Set(),
    tileWindow: null,
    portalLock: null,
    pendingLearnKey: null
  };
}

function addPlayer(harness: Harness, player: PlayerSession): void {
  harness.players.push(player);
  harness.visibility.add(player);
  harness.visibility.refresh(player);
}

function typesFor(harness: Harness, accountId: string): string[] {
  return (harness.sent.get(accountId) ?? []).map((message) => String(message.type));
}

test("refresh announces a joining player to nearby players only", () => {
  const harness = makeHarness();
  const a = makePlayer("a", "m", 0, 0);
  const b = makePlayer("b", "m", 64, 0);
  const c = makePlayer("c", "m", 200, 0);

  addPlayer(harness, a);
  addPlayer(harness, b);
  addPlayer(harness, c);

  assert.deepEqual([...a.visiblePlayers].sort(), ["b"]);
  assert.deepEqual([...b.visiblePlayers].sort(), ["a"]);
  assert.deepEqual([...c.visiblePlayers], []);
  assert.deepEqual(typesFor(harness, "a"), ["player_joined"]);
  assert.deepEqual(typesFor(harness, "b"), []);
  assert.deepEqual(typesFor(harness, "c"), []);
});

test("a move sends joins and leaves in both directions", () => {
  const harness = makeHarness();
  const a = makePlayer("a", "m", 0, 0);
  const b = makePlayer("b", "m", 64, 0);
  const c = makePlayer("c", "m", 200, 0);
  addPlayer(harness, a);
  addPlayer(harness, b);
  addPlayer(harness, c);
  harness.sent.clear();

  const previous = { ...b.character };
  b.character.x = 200;
  harness.visibility.reconcileAfterMove(b, previous);

  assert.deepEqual([...a.visiblePlayers], []);
  assert.deepEqual([...b.visiblePlayers].sort(), ["c"]);
  assert.deepEqual([...c.visiblePlayers], ["b"]);
  assert.deepEqual(typesFor(harness, "a"), ["player_left"]);
  assert.deepEqual(typesFor(harness, "b"), ["player_joined", "player_left"]);
  assert.deepEqual(typesFor(harness, "c"), ["player_joined"]);
});

test("clear detaches a player and notifies current viewers", () => {
  const harness = makeHarness();
  const a = makePlayer("a", "m", 0, 0);
  const b = makePlayer("b", "m", 10, 10);
  addPlayer(harness, a);
  addPlayer(harness, b);
  harness.sent.clear();

  harness.visibility.clear(b);
  harness.players = harness.players.filter((player) => player !== b);

  assert.deepEqual([...a.visiblePlayers], []);
  assert.deepEqual([...b.visiblePlayers], []);
  assert.deepEqual(typesFor(harness, "a"), ["player_left"]);
  assert.equal(harness.visibility.size, 1);
});

test("visibility state matches a brute-force scan through random movement", () => {
  const harness = makeHarness();
  let next = 0;
  const spawn = () => {
    const player = makePlayer(
      `p${next++}`,
      next % 2 === 0 ? "m" : "other",
      Math.floor(Math.random() * 400),
      Math.floor(Math.random() * 400)
    );
    addPlayer(harness, player);
  };
  for (let i = 0; i < 12; i++) spawn();

  const assertParity = (step: number) => {
    for (const player of harness.players) {
      const expected = harness.players
        .filter(
          (other) =>
            other !== player &&
            withinView(player.character, other.character, CONFIG.playerViewRadius)
        )
        .map((other) => other.accountId)
        .sort();
      assert.deepEqual(
        [...player.visiblePlayers].sort(),
        expected,
        `visiblePlayers mismatch at step ${step} for ${player.accountId}`
      );
      assert.deepEqual(
        harness.visibility
          .visibleOthers(player)
          .map((other) => other.accountId)
          .sort(),
        expected,
        `visibleOthers mismatch at step ${step} for ${player.accountId}`
      );
    }
  };
  assertParity(0);

  for (let step = 1; step <= 300; step++) {
    const roll = Math.random();
    if (roll < 0.1) {
      spawn();
    } else if (roll < 0.2 && harness.players.length > 1) {
      const player = harness.players[Math.floor(Math.random() * harness.players.length)];
      harness.visibility.clear(player);
      harness.players = harness.players.filter((other) => other !== player);
    } else if (roll < 0.35) {
      const player = harness.players[Math.floor(Math.random() * harness.players.length)];
      harness.visibility.clear(player);
      player.character.mapId = Math.random() < 0.5 ? "m" : "other";
      player.character.x = Math.floor(Math.random() * 400);
      player.character.y = Math.floor(Math.random() * 400);
      harness.visibility.add(player);
      harness.visibility.refresh(player);
    } else {
      const player = harness.players[Math.floor(Math.random() * harness.players.length)];
      const previous = { ...player.character };
      player.character.x += Math.floor(Math.random() * 241) - 120;
      player.character.y += Math.floor(Math.random() * 241) - 120;
      harness.visibility.reconcileAfterMove(player, previous);
    }
    assertParity(step);
  }
});

test("broadcast only reaches players who currently see the subject", () => {
  const harness = makeHarness();
  const a = makePlayer("a", "m", 0, 0);
  const b = makePlayer("b", "m", 10, 0);
  const c = makePlayer("c", "m", 200, 0);
  addPlayer(harness, a);
  addPlayer(harness, b);
  addPlayer(harness, c);
  harness.sent.clear();

  harness.visibility.broadcast(a, { type: "player_moved", x: 1 });
  assert.deepEqual(typesFor(harness, "a"), []);
  assert.deepEqual(typesFor(harness, "b"), ["player_moved"]);
  assert.deepEqual(typesFor(harness, "c"), []);
});
