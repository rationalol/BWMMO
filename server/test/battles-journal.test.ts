import test from "node:test";
import assert from "node:assert/strict";
import { loadContent } from "../src/content/loader.js";
import { BattleController } from "../src/game/battles.js";
import { createStarter } from "../src/game/creatures.js";
import { ContentLocalizer } from "../src/i18n/localizer.js";
import type { JournalEntry } from "../src/game/journal.js";
import type { Conn, PlayerSession } from "../src/game/protocol.js";
import type { GameHost } from "../src/game/runtime.js";
import type { CharacterState } from "../src/game/types.js";

const content = loadContent();

function makePlayer(): PlayerSession {
  const character: CharacterState = {
    id: "char-journal",
    name: "Demo",
    color: "#e76f51",
    mapId: "unova_full",
    x: 780,
    y: 750,
    dir: "down",
    sprite: 0,
    money: 0,
    wins: 0,
    party: [createStarter(content, "snivy")],
    box: [],
    inventory: { items: { poke_ball: 5 } },
    pokedex: { seen: [], caught: [] },
    storyFlags: {},
    friends: []
  };
  const conn = {
    ws: {},
    ip: "test",
    accountId: "acc-journal",
    player: null,
    locale: "en",
    messageTimes: [],
    alive: true
  } as unknown as Conn;
  const player: PlayerSession = {
    conn,
    accountId: "acc-journal",
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
  return player;
}

test("wild encounters and moves produce journal entries", () => {
  const player = makePlayer();
  const journals: JournalEntry[] = [];
  const host = {
    content,
    i18n: new ContentLocalizer(content),
    store: { saveCharacter: () => undefined },
    visibility: { clear: () => undefined },
    send: () => undefined,
    sendError: (_conn: Conn, message: string) => {
      throw new Error(message);
    },
    sendJournal: (_player: PlayerSession, entry: JournalEntry) => {
      journals.push(entry);
    },
    sendMapState: () => undefined,
    sendPartyState: () => undefined,
    sendPokedexState: () => undefined,
    sendNextMoveLearn: () => undefined,
    afterTeleport: () => undefined,
    startWildBattle: () => undefined,
    map: () => content.maps.unova_full,
    locationName: () => "Route 1",
    onlinePlayer: () => null
  } as unknown as GameHost;

  const controller = new BattleController(host);
  controller.startWildBattle(player, content.maps.unova_full, {
    species: "patrat",
    minLevel: 2,
    maxLevel: 2,
    weight: 1
  });

  assert.equal(journals[0].kind, "encounter");
  assert.equal(journals[0].actor, "Demo");
  assert.equal(journals[0].target, "Patrat");

  const battleId = player.battleId;
  assert.ok(battleId);
  controller.handleAction(player.conn, {
    battleId,
    action: "move",
    moveIndex: 0
  });

  const move = journals.find(
    (entry) => entry.kind === "move" && entry.actor === "Snivy"
  );
  assert.ok(move);
  assert.equal(typeof move?.move, "string");
  assert.notEqual(move?.move, "");
});
