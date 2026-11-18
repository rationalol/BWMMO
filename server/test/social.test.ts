import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Store } from "../src/store.js";
import { SocialController } from "../src/game/social.js";
import type { Conn, Dict, PlayerSession } from "../src/game/protocol.js";
import type { GameHost } from "../src/game/runtime.js";
import type { CharacterState } from "../src/game/types.js";

function makeCharacter(id: string, name: string): CharacterState {
  return {
    id,
    name,
    color: "#e76f51",
    mapId: "unova_full",
    x: 780,
    y: 750,
    dir: "down",
    sprite: 0,
    money: 100,
    wins: 0,
    party: [],
    box: [],
    inventory: { items: {} },
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

function makeHarness() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "bwmmo-social-"));
  const store = new Store(dir);
  const sentA: Dict[] = [];
  const sentB: Dict[] = [];
  const a = makePlayer("acc-a", makeCharacter("char-a", "Ash"), sentA);
  const b = makePlayer("acc-b", makeCharacter("char-b", "Misty"), sentB);
  store.saveCharacter(a.accountId, a.character);
  store.saveCharacter(b.accountId, b.character);

  const players = [a, b];
  const host = {
    store,
    visibility: {
      visibleOthers: (player: PlayerSession) =>
        player === a ? [b] : player === b ? [a] : []
    },
    locationName: () => "Route 1",
    send: (conn: Conn, message: Dict) => {
      if (conn === a.conn) sentA.push(message);
      else if (conn === b.conn) sentB.push(message);
    },
    sendError: (conn: Conn, message: string) => {
      if (conn === a.conn) sentA.push({ type: "error", message });
      else if (conn === b.conn) sentB.push({ type: "error", message });
    },
    onlinePlayer: (characterId: string) =>
      players.find((player) => player.character.id === characterId) ?? null
  } as unknown as GameHost;

  return {
    dir,
    store,
    social: new SocialController(host),
    a,
    b,
    sentA,
    sentB,
    cleanup: () => {
      store.close();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  };
}

test("a friend request stays pending until the recipient accepts", () => {
  const harness = makeHarness();
  try {
    harness.social.handleFriendRequest(harness.a.conn, { playerId: "char-b" });

    assert.deepEqual(harness.a.character.friends, []);
    assert.deepEqual(harness.b.character.friends, []);
    assert.equal(harness.store.hasFriendRequest("char-a", "char-b"), true);
    assert.equal(harness.store.hasFriendRequest("char-b", "char-a"), false);

    const outgoing = harness.sentA
      .filter((message) => message.type === "social_state")
      .at(-1)?.outgoingRequests as Array<Dict>;
    assert.equal(outgoing[0].id, "char-b");
    const incoming = harness.sentB
      .filter((message) => message.type === "social_state")
      .at(-1)?.incomingRequests as Array<Dict>;
    assert.equal(incoming[0].id, "char-a");
    assert.ok(
      harness.sentB.some(
        (message) =>
          message.type === "notice" &&
          String(message.text).includes("friend request")
      )
    );
  } finally {
    harness.cleanup();
  }
});

test("accepting a request creates the mutual friendship and clears the request", () => {
  const harness = makeHarness();
  try {
    harness.social.handleFriendRequest(harness.a.conn, { playerId: "char-b" });
    harness.social.handleFriendAccept(harness.b.conn, { playerId: "char-a" });

    assert.deepEqual(harness.a.character.friends, ["char-b"]);
    assert.deepEqual(harness.b.character.friends, ["char-a"]);
    assert.deepEqual(harness.store.characterById("char-a")?.character.friends, ["char-b"]);
    assert.deepEqual(harness.store.characterById("char-b")?.character.friends, ["char-a"]);
    assert.equal(harness.store.hasFriendRequest("char-a", "char-b"), false);
    assert.ok(
      harness.sentA.some(
        (message) =>
          message.type === "notice" && String(message.text).includes("accepted")
      )
    );
  } finally {
    harness.cleanup();
  }
});

test("declining a request removes it and notifies the requester", () => {
  const harness = makeHarness();
  try {
    harness.social.handleFriendRequest(harness.a.conn, { playerId: "char-b" });
    harness.social.handleFriendDecline(harness.b.conn, { playerId: "char-a" });

    assert.deepEqual(harness.a.character.friends, []);
    assert.deepEqual(harness.b.character.friends, []);
    assert.equal(harness.store.hasFriendRequest("char-a", "char-b"), false);
    assert.ok(
      harness.sentA.some(
        (message) =>
          message.type === "notice" && String(message.text).includes("declined")
      )
    );
  } finally {
    harness.cleanup();
  }
});

test("a requester can cancel a pending request", () => {
  const harness = makeHarness();
  try {
    harness.social.handleFriendRequest(harness.a.conn, { playerId: "char-b" });
    harness.sentB.length = 0;
    harness.social.handleFriendCancel(harness.a.conn, { playerId: "char-b" });

    assert.equal(harness.store.hasFriendRequest("char-a", "char-b"), false);
    assert.ok(
      harness.sentB.some(
        (message) =>
          message.type === "notice" && String(message.text).includes("canceled")
      )
    );
  } finally {
    harness.cleanup();
  }
});

test("pending requests survive a store reload", () => {
  const harness = makeHarness();
  try {
    harness.social.handleFriendRequest(harness.a.conn, { playerId: "char-b" });
    harness.store.flush();

    const reloaded = new Store(harness.dir);
    try {
      assert.equal(reloaded.hasFriendRequest("char-a", "char-b"), true);
      assert.equal(reloaded.characterById("char-a")?.character.friends?.length, 0);
    } finally {
      reloaded.close();
    }
  } finally {
    harness.cleanup();
  }
});

test("removing a friend clears both lists", () => {
  const harness = makeHarness();
  try {
    harness.a.character.friends = ["char-b"];
    harness.b.character.friends = ["char-a"];
    harness.store.saveCharacter("acc-a", harness.a.character);
    harness.store.saveCharacter("acc-b", harness.b.character);

    harness.social.handleFriendRemove(harness.a.conn, { playerId: "char-b" });

    assert.deepEqual(harness.a.character.friends, []);
    assert.deepEqual(harness.b.character.friends, []);
    assert.deepEqual(harness.store.characterById("char-b")?.character.friends, []);
  } finally {
    harness.cleanup();
  }
});

test("a direct message reaches sender and recipient", () => {
  const harness = makeHarness();
  try {
    harness.a.character.friends = ["char-b"];
    harness.b.character.friends = ["char-a"];

    harness.social.handleDirectMessage(harness.a.conn, {
      toId: "char-b",
      text: "Can we trade?"
    });

    const incoming = harness.sentB.find((message) => message.type === "direct_message");
    assert.ok(incoming);
    assert.equal(incoming?.fromId, "char-a");
    assert.equal(incoming?.fromName, "Ash");
    assert.equal(incoming?.text, "Can we trade?");

    const echoed = harness.sentA.find((message) => message.type === "direct_message");
    assert.ok(echoed);
    assert.equal(echoed?.toId, "char-b");
    assert.equal(echoed?.outgoing, true);
  } finally {
    harness.cleanup();
  }
});

test("strangers can only message each other while nearby", () => {
  const harness = makeHarness();
  try {
    harness.social.handleDirectMessage(harness.a.conn, { toId: "char-b", text: "hi" });
    assert.ok(
      harness.sentA.some(
        (message) =>
          message.type === "error" &&
          String(message.message).includes("friends or trainers nearby")
      )
    );

    harness.a.visiblePlayers.add(harness.b.accountId);
    harness.sentA.length = 0;
    harness.sentB.length = 0;
    harness.social.handleDirectMessage(harness.a.conn, { toId: "char-b", text: "hi" });
    assert.ok(harness.sentB.some((message) => message.type === "direct_message"));
  } finally {
    harness.cleanup();
  }
});

test("the social snapshot lists nearby trainers and friend status", () => {
  const harness = makeHarness();
  try {
    harness.a.character.friends = ["char-b"];
    harness.b.character.x = 786;
    harness.b.character.y = 750;

    harness.social.sendSocialState(harness.a);

    const state = harness.sentA.find((message) => message.type === "social_state");
    assert.ok(state);
    const friends = state?.friends as Array<Dict>;
    assert.equal(friends.length, 1);
    assert.equal(friends[0].name, "Misty");
    assert.equal(friends[0].online, true);
    const incoming = state?.incomingRequests as Array<Dict>;
    const outgoing = state?.outgoingRequests as Array<Dict>;
    assert.deepEqual(incoming, []);
    assert.deepEqual(outgoing, []);
    const nearby = state?.nearby as Array<Dict>;
    assert.equal(nearby.length, 1);
    assert.equal(nearby[0].id, "char-b");
    assert.equal(nearby[0].distance, 6);
    assert.equal(nearby[0].friend, true);
    assert.equal(nearby[0].requested, false);
    assert.equal(nearby[0].incoming, false);
  } finally {
    harness.cleanup();
  }
});

test("nearby rows expose the direction of a pending request", () => {
  const harness = makeHarness();
  try {
    harness.social.handleFriendRequest(harness.a.conn, { playerId: "char-b" });
    harness.sentA.length = 0;
    harness.sentB.length = 0;
    harness.social.sendSocialState(harness.a);
    harness.social.sendSocialState(harness.b);

    const aState = harness.sentA.find((message) => message.type === "social_state");
    const aNearby = aState?.nearby as Array<Dict>;
    assert.equal((aState?.outgoingRequests as Array<Dict>).length, 1);
    assert.equal(aNearby[0].requested, true);
    assert.equal(aNearby[0].incoming, false);

    const bState = harness.sentB.find((message) => message.type === "social_state");
    const bNearby = bState?.nearby as Array<Dict>;
    assert.equal((bState?.incomingRequests as Array<Dict>).length, 1);
    assert.equal(bNearby[0].requested, false);
    assert.equal(bNearby[0].incoming, true);
  } finally {
    harness.cleanup();
  }
});
