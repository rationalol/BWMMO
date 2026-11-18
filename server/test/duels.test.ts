import test from "node:test";
import assert from "node:assert/strict";
import { loadContent } from "../src/content/loader.js";
import { createCreature } from "../src/game/creatures.js";
import { DuelController } from "../src/game/duels.js";
import { ContentLocalizer } from "../src/i18n/localizer.js";
import type { Conn, Dict, PlayerSession } from "../src/game/protocol.js";
import type { GameHost } from "../src/game/runtime.js";
import type { CharacterState } from "../src/game/types.js";

const content = loadContent();

function makeCharacter(
  id: string,
  name: string,
  party: string[] = ["snivy"]
): CharacterState {
  return {
    id,
    name,
    color: "#e76f51",
    mapId: "unova_full",
    x: 780,
    y: 750,
    dir: "down",
    sprite: 0,
    money: 500,
    wins: 0,
    party: party.map((species) => createCreature(content, species, 5)),
    box: [],
    inventory: { items: { poke_ball: 5, potion: 1 } },
    pokedex: { seen: [], caught: [] },
    storyFlags: {},
    friends: []
  };
}

function makePlayer(
  accountId: string,
  character: CharacterState,
  sent: Dict[]
): PlayerSession {
  const conn = {
    ws: {},
    ip: "test",
    accountId,
    player: null,
    locale: "en",
    messageTimes: [],
    alive: true
  } as unknown as Conn;
  const player: PlayerSession = {
    conn,
    accountId,
    username: character.name,
    character,
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
  conn.player = player;
  sent.length = 0;
  return player;
}

function makeHarness(friends = true) {
  const sentA: Dict[] = [];
  const sentB: Dict[] = [];
  const a = makePlayer("acc-a", makeCharacter("char-a", "Ash", ["snivy", "tepig"]), sentA);
  const b = makePlayer(
    "acc-b",
    makeCharacter("char-b", "Misty", ["oshawott", "patrat"]),
    sentB
  );
  if (friends) {
    a.character.friends = ["char-b"];
    b.character.friends = ["char-a"];
  }
  const stored: string[] = [];
  const host = {
    content,
    i18n: new ContentLocalizer(content),
    store: {
      saveCharacter: (accountId: string) => stored.push(accountId)
    },
    visibility: { clear: () => undefined },
    send: (conn: Conn, message: Dict) => {
      if (conn === a.conn) sentA.push(message);
      else if (conn === b.conn) sentB.push(message);
    },
    sendError: (conn: Conn, message: string) => {
      if (conn === a.conn) sentA.push({ type: "error", message });
      else if (conn === b.conn) sentB.push({ type: "error", message });
    },
    sendJournal: () => undefined,
    sendMapState: () => undefined,
    sendPartyState: () => undefined,
    sendPokedexState: () => undefined,
    sendNextMoveLearn: () => undefined,
    afterTeleport: () => undefined,
    startWildBattle: () => undefined,
    map: () => content.maps.unova_full,
    locationName: () => "Route 1",
    onlinePlayer: (characterId: string) =>
      [a, b].find((player) => player.character.id === characterId) ?? null
  } as unknown as GameHost;
  return { a, b, sentA, sentB, stored, duels: new DuelController(host) };
}

function last(sent: Dict[], type: string): Dict | undefined {
  return [...sent].reverse().find((message) => message.type === type);
}

test("a duel request must target an online friend", () => {
  const harness = makeHarness(false);
  harness.duels.handleRequest(harness.a.conn, { playerId: "char-b" });
  assert.ok(
    harness.sentA.some(
      (message) =>
        message.type === "error" && String(message.message).includes("only duel friends")
    )
  );

  const friends = makeHarness(true);
  friends.duels.handleRequest(friends.a.conn, { playerId: "missing" });
  assert.ok(
    friends.sentA.some(
      (message) =>
        message.type === "error" && String(message.message).includes("not online")
    )
  );
});

test("accepting a duel starts a mirrored two-player battle", () => {
  const harness = makeHarness();
  harness.duels.handleRequest(harness.a.conn, { playerId: "char-b" });
  const request = last(harness.sentB, "duel_request");
  assert.equal(request?.fromName, "Ash");
  assert.equal(last(harness.sentA, "duel_request_sent")?.toName, "Misty");

  harness.duels.handleAccept(harness.b.conn, { playerId: "char-a" });
  const startA = last(harness.sentA, "battle_start")?.battle as Dict;
  const startB = last(harness.sentB, "battle_start")?.battle as Dict;
  assert.equal(startA.mode, "duel");
  assert.equal(startB.mode, "duel");
  assert.equal(startA.playerName, "Ash");
  assert.equal(startA.opponentName, "Misty");
  assert.equal(startB.playerName, "Misty");
  assert.equal(startB.opponentName, "Ash");
  assert.equal((startA.player as Dict).species, "snivy");
  assert.equal((startB.player as Dict).species, "oshawott");
  assert.equal(startA.id, startB.id);
  assert.equal(harness.a.battleId, startA.id);
  assert.equal(harness.b.battleId, startA.id);
});

test("declining a request notifies the sender", () => {
  const harness = makeHarness();
  harness.duels.handleRequest(harness.a.conn, { playerId: "char-b" });
  harness.duels.handleDecline(harness.b.conn, { playerId: "char-a" });
  assert.equal(last(harness.sentA, "duel_declined")?.playerId, "char-b");
  assert.ok(
    harness.sentA.some(
      (message) =>
        message.type === "notice" && String(message.text).includes("declined")
    )
  );
});

test("a duel rejects balls, medicine and running", () => {
  const harness = makeHarness();
  harness.duels.handleRequest(harness.a.conn, { playerId: "char-b" });
  harness.duels.handleAccept(harness.b.conn, { playerId: "char-a" });
  const battleId = harness.a.battleId!;

  harness.duels.handleAction(harness.a.conn, {
    battleId,
    action: "catch",
    itemId: "poke_ball"
  });
  assert.ok(
    harness.sentA.some(
      (message) =>
        message.type === "error" && String(message.message).includes("Poké Balls")
    )
  );
  harness.duels.handleAction(harness.a.conn, {
    battleId,
    action: "item",
    itemId: "potion",
    partyIndex: 0
  });
  assert.ok(
    harness.sentA.some(
      (message) =>
        message.type === "error" && String(message.message).includes("cannot use items")
    )
  );
  harness.duels.handleAction(harness.a.conn, { battleId, action: "run" });
  assert.ok(
    harness.sentA.some(
      (message) =>
        message.type === "error" && String(message.message).includes("cannot run")
    )
  );
});

test("both sides choose and receive their own turn snapshot", () => {
  const harness = makeHarness();
  harness.duels.handleRequest(harness.a.conn, { playerId: "char-b" });
  harness.duels.handleAccept(harness.b.conn, { playerId: "char-a" });
  const battleId = harness.a.battleId!;
  harness.sentA.length = 0;
  harness.sentB.length = 0;

  const moveA = harness.a.character.party[0].moves.findIndex(
    (move) => (move.power ?? 0) > 0
  );
  harness.duels.handleAction(harness.a.conn, {
    battleId,
    action: "move",
    moveIndex: moveA
  });
  const waitingA = last(harness.sentA, "battle_turn")?.battle as Dict;
  assert.equal(waitingA.awaitingAction, false);
  assert.equal(waitingA.awaitingOpponent, undefined);
  assert.deepEqual(waitingA.events, []);

  const moveB = harness.b.character.party[0].moves.findIndex(
    (move) => (move.power ?? 0) > 0
  );
  harness.duels.handleAction(harness.b.conn, {
    battleId,
    action: "move",
    moveIndex: moveB
  });
  const turnA = last(harness.sentA, "battle_turn")?.battle as Dict;
  const turnB = last(harness.sentB, "battle_turn")?.battle as Dict;
  assert.equal(turnA.turn, 1);
  assert.equal(turnB.turn, 1);
  assert.ok((turnA.events as Array<Dict>).length > 0);
  assert.ok((turnB.events as Array<Dict>).length > 0);
  assert.equal(turnA.playerName, "Ash");
  assert.equal(turnB.playerName, "Misty");
});

test("leaving a duel forfeits it, heals both teams and avoids black-out travel", () => {
  const harness = makeHarness();
  harness.duels.handleRequest(harness.a.conn, { playerId: "char-b" });
  harness.duels.handleAccept(harness.b.conn, { playerId: "char-a" });
  harness.a.character.party[0].hp = 1;
  harness.duels.detach(harness.a);

  const end = last(harness.sentB, "battle_end");
  assert.ok(end);
  assert.equal(end?.result, "won");
  assert.equal(end?.travel, false);
  assert.equal(harness.a.battleId, null);
  assert.equal(harness.b.battleId, null);
  for (const player of [harness.a, harness.b]) {
    for (const creature of player.character.party) {
      assert.equal(creature.hp, creature.maxHp);
    }
  }
  assert.ok(harness.stored.includes("acc-a"));
  assert.ok(harness.stored.includes("acc-b"));
});
