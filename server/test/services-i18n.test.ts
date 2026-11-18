import test from "node:test";
import assert from "node:assert/strict";
import { loadContent } from "../src/content/loader.js";
import { ContentLocalizer } from "../src/i18n/localizer.js";
import { createCreature } from "../src/game/creatures.js";
import { ServiceController } from "../src/game/services.js";
import type { Conn, Dict, PlayerSession } from "../src/game/protocol.js";
import type { GameHost } from "../src/game/runtime.js";
import type { CharacterState } from "../src/game/types.js";

const content = loadContent();

function harness(locale: string, character: CharacterState) {
  const sent: Dict[] = [];
  const conn = {
    ws: {},
    ip: "test",
    accountId: "acc-npc",
    player: null,
    locale,
    messageTimes: [],
    alive: true
  } as unknown as Conn;
  const player: PlayerSession = {
    conn,
    accountId: "acc-npc",
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
    pendingLearnKey: null,
    story: null,
    lastStoryGateAt: 0
  };
  conn.player = player;
  const host = {
    content,
    i18n: new ContentLocalizer(content),
    // No story scene owns this NPC; fall through to ordinary dialogue.
    story: { interact: () => false, npcVisible: () => true },
    map: (mapId: string) => content.maps[mapId],
    send: (_conn: Conn, message: Dict) => sent.push(message),
    sendError: (_conn: Conn, message: string) =>
      sent.push({ type: "error", message }),
    sendPartyState: () => undefined,
    sendJournal: () => undefined,
    store: { saveCharacter: () => undefined },
    locationName: () => "Nuvema Town",
    onlinePlayer: () => null
  } as unknown as GameHost;
  return { controller: new ServiceController(host), player, sent };
}

function character(mapId: string, x: number, y: number): CharacterState {
  return {
    id: "char-npc",
    name: "Nate",
    color: "#e76f51",
    mapId,
    x,
    y,
    dir: "up",
    sprite: 0,
    money: 0,
    wins: 0,
    party: [],
    box: [],
    inventory: { items: {} },
    pokedex: { seen: [], caught: [] },
    storyFlags: {},
    friends: []
  };
}

function dialogueOf(sent: Dict[]): Dict | undefined {
  return [...sent].reverse().find((message) => message.type === "dialogue");
}

test("talking to an NPC sends the Chinese block for a zh_CN client", () => {
  // Mom stands at (6,5) in the bedroom; the player talks from below.
  const zh = harness("zh_CN", character("unova_in_390", 6, 4));
  zh.controller.handleInteract(zh.player.conn, { npcId: "z390_n0" });
  const page = dialogueOf(zh.sent);
  assert.ok(page);
  assert.equal(page!.npcName, "妈妈");
  assert.deepEqual(page!.lines, ["你也要向博士\n好好道谢的对吧？\n快点去吧！"]);

  // The shared Nurse Joy block comes from the hand-written table.
  const nurse = harness("zh_CN", character("unova_in_1", 7, 9));
  nurse.controller.handleInteract(nurse.player.conn, { npcId: "z1_n4" });
  const nursePage = dialogueOf(nurse.sent);
  assert.ok(nursePage);
  assert.equal(nursePage!.npcName, "乔伊小姐");
  assert.deepEqual(nursePage!.lines, [
    "欢迎来到宝可梦中心！",
    "让我来照顾你的宝可梦吧。",
    "好了！\n你的队伍又生龙活虎了。"
  ]);
});

test("an English client still receives the canonical lines", () => {
  const en = harness("en", character("unova_in_390", 6, 4));
  en.controller.handleInteract(en.player.conn, { npcId: "z390_n0" });
  const page = dialogueOf(en.sent);
  assert.ok(page);
  assert.equal(page!.npcName, "Mom");
  assert.deepEqual(page!.lines, [
    "You're going to thank the\nprofessor too, right?",
    "Better get going, honey!"
  ]);
});

test("the ability expert lists and persists a chosen ability", () => {
  const ch = character("unova_in_396", 12, 8);
  ch.party = [createCreature(content, "snivy", 5)];
  const { controller, player, sent } = harness("zh_CN", ch);
  controller.handleInteract(player.conn, { npcId: "test_ability_expert" });

  const page = dialogueOf(sent);
  assert.ok(page);
  assert.equal(page!.npcName, "特性专家");
  assert.deepEqual(page!.lines, ["我可以唤醒宝可梦\n内在的潜力。\n来选择特性吧。"]);
  const service = [...sent].reverse().find((message) => message.type === "ability_service");
  assert.ok(service);
  const entry = (service!.party as Dict[])[0];
  assert.equal(entry.ability, "overgrow");
  assert.equal(entry.abilityName, "茂盛");
  assert.equal((entry.abilities as Dict[]).length, 2);
  assert.equal((entry.abilities as Dict[])[0].name, "茂盛");
  assert.equal((entry.abilities as Dict[])[1].name, "唱反调");
  assert.equal((entry.abilities as Dict[])[1].hidden, true);

  controller.handleSetAbility(player.conn, {
    npcId: "test_ability_expert",
    partyIndex: 0,
    abilityId: "contrary"
  });
  assert.equal(player.character.party[0].ability, "contrary");
  assert.equal(player.character.party[0].abilitySlot, 2);
  const updated = [...sent].reverse().find((message) => message.type === "ability_service");
  assert.ok(updated);
  assert.equal((updated!.party as Dict[])[0].abilityName, "唱反调");

  controller.handleSetAbility(player.conn, {
    npcId: "test_ability_expert",
    partyIndex: 0,
    abilityId: "not-an-ability"
  });
  const error = [...sent].reverse().find((message) => message.type === "error");
  assert.ok(error);
  assert.equal(player.character.party[0].ability, "contrary");
});

test("examining furniture answers from the map's object list", () => {
  // The TV in the player's bedroom covers (2,2); Nate faces it from (2,3).
  const { controller, player, sent } = harness("en", character("unova_in_391", 2, 3));
  controller.handleInteract(player.conn, { objectX: 2, objectY: 2 });
  const page = dialogueOf(sent);
  assert.ok(page);
  assert.equal(page!.kind, "object");
  assert.equal(page!.npcName, "TV");
  assert.deepEqual(page!.lines, ["It's a TV."]);
});

test("a zh_CN client examines furniture in Chinese", () => {
  const { controller, player, sent } = harness("zh_CN", character("unova_in_391", 2, 3));
  controller.handleInteract(player.conn, { objectX: 2, objectY: 2 });
  const page = dialogueOf(sent);
  assert.ok(page);
  assert.equal(page!.kind, "object");
  assert.equal(page!.npcName, "电视");
  assert.deepEqual(page!.lines, ["是一台电视。"]);

  // The unlabelled fallback keeps its generic line in both languages.
  const shelf = harness("zh_CN", character("unova_in_391", 3, 4));
  shelf.controller.handleInteract(shelf.player.conn, { objectX: 3, objectY: 3 });
  const shelfPage = dialogueOf(shelf.sent);
  assert.ok(shelfPage);
  assert.equal(shelfPage!.npcName, "家具");
  assert.deepEqual(shelfPage!.lines, ["是一件家具。"]);
});

test("an object out of reach is refused", () => {
  const { controller, player, sent } = harness("en", character("unova_in_391", 8, 2));
  controller.handleInteract(player.conn, { objectX: 2, objectY: 2 });
  assert.equal(dialogueOf(sent), undefined);
  const error = sent.find((message) => message.type === "error");
  assert.ok(error);
  assert.equal(error!.message, "There is nothing close enough to examine.");
});

test("a tile with no object reports nothing to examine", () => {
  const { controller, player, sent } = harness("en", character("unova_in_391", 8, 2));
  controller.handleInteract(player.conn, { objectX: 8, objectY: 3 });
  assert.equal(dialogueOf(sent), undefined);
  const error = sent.find((message) => message.type === "error");
  assert.ok(error);
  assert.equal(error!.message, "There is nothing to examine there.");
});
