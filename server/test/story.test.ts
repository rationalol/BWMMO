import test from "node:test";
import assert from "node:assert/strict";
import { loadContent, validateContent } from "../src/content/loader.js";
import { normalizeCharacter } from "../src/game/character-normalizer.js";
import { createCreature } from "../src/game/creatures.js";
import { StoryController } from "../src/game/story.js";
import { ContentLocalizer } from "../src/i18n/localizer.js";
import type { Conn, Dict, PlayerSession } from "../src/game/protocol.js";
import type { GameHost } from "../src/game/runtime.js";
import type { CharacterState } from "../src/game/types.js";

const content = loadContent();
const story = content.story;
assert.ok(story, "the story pack should be loaded");

function makeCharacter(
  flags: Record<string, number>,
  mapId = "unova_in_391",
  party: string[] = []
): CharacterState {
  return {
    id: "char-story",
    name: "Nate",
    color: "#e76f51",
    mapId,
    x: 8,
    y: 2,
    dir: "down",
    sprite: 0,
    money: 0,
    wins: 0,
    party: party.map((species) => createCreature(content, species, 5)),
    box: [],
    inventory: { items: {} },
    pokedex: { seen: [], caught: [] },
    storyFlags: { ...flags },
    friends: []
  };
}

function makePlayer(character: CharacterState, sent: Dict[]): PlayerSession {
  const conn = {
    ws: {},
    ip: "test",
    accountId: "acc-story",
    player: null,
    locale: "en",
    messageTimes: [],
    alive: true
  } as unknown as Conn;
  const player: PlayerSession = {
    conn,
    accountId: "acc-story",
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
  sent.length = 0;
  return player;
}

function makeHarness(character: CharacterState) {
  const sent: Dict[] = [];
  const stored: string[] = [];
  const trainerBattles: { trainerId: string }[] = [];
  const player = makePlayer(character, sent);
  const host = {
    content,
    i18n: new ContentLocalizer(content),
    store: {
      saveCharacter: (accountId: string) => stored.push(accountId)
    },
    visibility: { clear: () => undefined },
    send: (_conn: Conn, message: Dict) => sent.push(message),
    sendError: (_conn: Conn, message: string) => sent.push({ type: "error", message }),
    sendJournal: () => undefined,
    sendMapState: () => undefined,
    sendPartyState: (target: PlayerSession) => {
      sent.push({ type: "party_state", party: target.character.party });
    },
    sendPokedexState: () => undefined,
    sendNextMoveLearn: () => undefined,
    afterTeleport: () => undefined,
    startWildBattle: () => undefined,
    startTrainerBattle: (_target: PlayerSession, trainerId: string) =>
      trainerBattles.push({ trainerId }),
    map: (mapId: string) => content.maps[mapId],
    locationName: () => "Nuvema Town",
    onlinePlayer: () => null
  } as unknown as GameHost;
  return {
    controller: new StoryController(host),
    player,
    sent,
    stored,
    trainerBattles
  };
}

/** Pretend the client fought the scripted battle and dismissed the result box. */
function closeBattle(
  controller: StoryController,
  player: PlayerSession,
  result: "won" | "lost"
): void {
  const state = player.story;
  if (!state?.pendingBattle) throw new Error("no scripted battle is waiting");
  player.pendingStoryBattle = {
    trainerId: state.pendingBattle.trainerId,
    result
  };
  controller.onBattleClosed(player);
}

function last(sent: Dict[], type: string): Dict | undefined {
  return [...sent].reverse().find((message) => message.type === type);
}

/** Answer every dialogue page until the scene pauses or finishes. */
function playThrough(
  controller: StoryController,
  player: PlayerSession,
  sent: Dict[],
  limit = 30
): void {
  for (let i = 0; i < limit && player.story; i += 1) {
    const state = player.story;
    if (!state) return;
    if (state.awaiting !== "advance") return;
    const page = last(sent, "dialogue");
    controller.advance(player, {
      sceneId: state.sceneId,
      step: page?.kind === "story" ? page.step : state.index
    });
  }
}

/**
 * Page through the scene until it ends, waiting out cinematic `walk` steps.
 * The server holds the scene on a timer for the length of the path so the
 * client can animate the NPC, so a test must let real time pass.
 */
async function playToEnd(
  controller: StoryController,
  player: PlayerSession,
  sent: Dict[],
  timeoutMs = 8000
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    playThrough(controller, player, sent);
    if (!player.story) return;
    if (player.story.awaiting !== "timer") return;
    if (Date.now() > deadline) {
      throw new Error(`${player.story.sceneId} is still waiting for a cutscene walk`);
    }
    await new Promise((resolve) => setTimeout(resolve, 40));
  }
}

test("prologue content passes structural validation", () => {
  assert.deepEqual(validateContent(content), []);
  assert.equal(story?.startMap, "unova_in_391", "new characters start in their bedroom");
  assert.equal(story?.initialFlags?.["prologue.starterChosen"], 0);
  assert.ok(story?.scenes.prologue_bedroom_intro);
  assert.ok(story?.scenes.prologue_mom);
  assert.ok(story?.scenes.prologue_juniper_pokedex);
});

test("story NPCs are merged into their maps", () => {
  const bedroom = content.maps.unova_in_391.npcs.map((npc) => npc.id);
  assert.ok(bedroom.includes("prologue_cheren_bedroom"));
  assert.ok(bedroom.includes("prologue_bianca_bedroom"));
  const lab = content.maps.unova_in_396.npcs.map((npc) => npc.id);
  assert.ok(lab.includes("prologue_juniper_lab"));
  assert.ok(lab.includes("prologue_cedric_lab"));
});

test("conditions treat missing flags as zero", () => {
  const { controller } = makeHarness(makeCharacter({}));
  assert.equal(controller.matches(undefined, undefined), true);
  assert.equal(controller.matches({}, undefined), true);
  assert.equal(controller.matches({ "prologue.momDone": 0 }, undefined), true);
  assert.equal(controller.matches({ "prologue.momDone": 1 }, undefined), false);
  assert.equal(controller.matches({ "prologue.momDone": 1 }, { "prologue.momDone": 1 }), true);
  assert.equal(
    controller.matches(
      { "prologue.momDone": 1, "prologue.starterChosen": 1 },
      { "prologue.momDone": 1, "prologue.starterChosen": 0 }
    ),
    false,
    "every key in a condition must match"
  );
});

test("hidden story NPCs neither appear nor block movement", () => {
  const { controller, player } = makeHarness(makeCharacter({}));
  const bedroom = content.maps.unova_in_391;
  const cheren = bedroom.npcs.find((npc) => npc.id === "prologue_cheren_bedroom");
  assert.ok(cheren);
  assert.equal(controller.npcVisible(cheren!, player.character.storyFlags), true);
  assert.equal(controller.blocksAt(bedroom, cheren!.x, cheren!.y, player.character.storyFlags), true);

  player.character.storyFlags!["prologue.starterChosen"] = 1;
  assert.equal(
    controller.npcVisible(cheren!, player.character.storyFlags),
    true,
    "Cheren stays in the room for the two sparring battles"
  );

  player.character.storyFlags!["prologue.bedroomDone"] = 1;
  assert.equal(controller.npcVisible(cheren!, player.character.storyFlags), false);
  assert.equal(
    controller.blocksAt(bedroom, cheren!.x, cheren!.y, player.character.storyFlags),
    false,
    "an NPC hidden for this player must not be a wall"
  );
  assert.equal(controller.blocksAt(bedroom, 1, 1, player.character.storyFlags), false);
});

test("the northern Nuvema exit stays locked until the prologue is done", () => {
  const { controller, player } = makeHarness(makeCharacter({ "prologue.starterChosen": 0 }));
  const at = (flags: Record<string, number>) =>
    controller.gateAt({ ...player, character: { ...player.character, storyFlags: flags } }, "unova_full", 788, 738);

  assert.equal(at({ "prologue.starterChosen": 0 })?.id, "route1_no_starter");
  assert.equal(
    at({ "prologue.starterChosen": 1, "prologue.routeUnlocked": 0 })?.id,
    "route1_no_pokedex"
  );
  assert.equal(
    at({ "prologue.starterChosen": 1, "prologue.pokedex": 1 })?.id,
    "route1_no_pokedex",
    "the Pokédex flag alone does not open the road"
  );
  assert.equal(
    at({ "prologue.starterChosen": 1, "prologue.routeUnlocked": 1 }),
    null,
    "walking to the lab opens Route 1"
  );
  assert.equal(controller.gateAt(player, "unova_full", 700, 700), null);
  assert.equal(controller.gateAt(player, "unova_in_391", 788, 738), null);
});

test("the character stopping the player stands on the gate", () => {
  const { controller } = makeHarness(makeCharacter({}));
  const world = content.maps.unova_full;
  const bianca = world.npcs.find((npc) => npc.id === "prologue_route1_bianca");
  const cheren = world.npcs.find((npc) => npc.id === "prologue_route1_cheren");
  assert.ok(bianca, "Bianca guards the exit before a starter is chosen");
  assert.ok(cheren, "Cheren guards the exit before the Pokédex");
  assert.equal(bianca!.sprite, 135);
  assert.equal(cheren!.sprite, 12);
  assert.deepEqual([cheren!.x, cheren!.y], [788, 739]);

  const visible = (npc: typeof cheren, flags: Record<string, number>) =>
    controller.npcVisible(npc!, flags);
  assert.equal(visible(bianca, { "prologue.starterChosen": 0 }), true);
  assert.equal(visible(cheren, { "prologue.starterChosen": 0 }), false);
  assert.equal(
    visible(cheren, { "prologue.starterChosen": 1, "prologue.routeUnlocked": 0 }),
    true
  );
  assert.equal(
    visible(bianca, { "prologue.starterChosen": 1, "prologue.routeUnlocked": 0 }),
    false
  );
  assert.equal(
    visible(cheren, { "prologue.starterChosen": 1, "prologue.routeUnlocked": 1 }),
    false,
    "the road is empty once the route opens"
  );
});

test("the bedroom scene hands out the chosen partner", async () => {
  const { controller, player, sent, trainerBattles } = makeHarness(
    makeCharacter({ "prologue.starterChosen": 0, "prologue.started": 1 })
  );
  controller.onEnter(player);
  assert.ok(player.story, "entering the bedroom starts the intro");
  assert.equal(player.story?.sceneId, "prologue_bedroom_intro");
  assert.equal(last(sent, "story_begin")?.sceneId, "prologue_bedroom_intro");
  const first = last(sent, "dialogue");
  assert.equal(first?.kind, "story");
  // Steps 0 and 1 turn Cheren and Bianca toward the player first, so the scene
  // is already two steps in when the opening line is sent.
  assert.equal(first?.step, 2);
  assert.equal(first?.npcName, "Cheren");
  playThrough(controller, player, sent);
  const lines = sent
    .filter((message) => message.type === "dialogue")
    .flatMap((message) => (message.lines as string[] | undefined) ?? []);
  assert.ok(
    lines.some((line) => line.includes("Nate")),
    "dialogue placeholders should be rendered with the trainer name"
  );
  const choice = last(sent, "story_choice");
  assert.ok(choice, "the scene should ask which partner to take");
  assert.equal(choice?.kind, "starter", "the client can pick the gift-box presentation");
  const choiceOptions = choice?.options as Dict[];
  assert.deepEqual(
    choiceOptions.map((option) => option.id),
    ["snivy", "tepig", "oshawott"]
  );
  assert.deepEqual(choiceOptions[0]?.types, ["Grass"]);
  assert.equal(player.character.party.length, 0, "no partner before the choice");
  assert.equal(player.story?.awaiting, "choice");

  const choiceStep = player.story!.index;
  controller.choose(player, { sceneId: "prologue_bedroom_intro", step: choiceStep, optionId: "tepig" });

  assert.equal(player.character.party.length, 1);
  assert.equal(player.character.party[0]!.species, "tepig");
  assert.equal(player.character.party[0]!.level, 5);
  assert.equal(player.character.party[0]!.moves.length > 0, true, "the partner knows moves");
  assert.equal(player.character.storyFlags!["prologue.starterChosen"], 1);
  assert.equal(player.character.storyFlags!["2402"], 1, "the ROM work flag is preserved");
  assert.equal(
    player.character.storyFlags!["prologue.starter"],
    0,
    "the pick is stored with the ROM numbering (0 Tepig, 1 Oshawott, 2 Snivy)"
  );
  assert.ok(player.character.pokedex!.caught.includes(498), "the partner is registered in the dex");

  // The ROM's first sparring battle: Bianca picks the partner that beats yours.
  playThrough(controller, player, sent);
  assert.equal(player.story?.awaiting, "battle", "the scene waits for the battle");
  assert.deepEqual(trainerBattles, [{ trainerId: "bianca_oshawott" }]);

  closeBattle(controller, player, "won");
  assert.equal(player.character.storyFlags!["8010"], 1, "the battle result is stored like work 0x8010");
  const winText = sent
    .filter((message) => message.type === "dialogue")
    .flatMap((message) => (message.lines as string[] | undefined) ?? [])
    .join("\n");
  assert.ok(winText.includes("awesome Trainer"), "the win branch plays Bianca's praise");

  // Cheren then challenges with the same partner the player took.
  playThrough(controller, player, sent);
  assert.equal(player.story?.awaiting, "battle");
  assert.deepEqual(trainerBattles, [
    { trainerId: "bianca_oshawott" },
    { trainerId: "cheren_tepig" }
  ]);

  closeBattle(controller, player, "won");
  playThrough(controller, player, sent);
  assert.equal(
    player.story?.awaiting,
    "timer",
    "the rivals walk out of the way before the scene ends"
  );
  const walkedAt = Date.now();
  await playToEnd(controller, player, sent);
  const walkMs = Date.now() - walkedAt;
  assert.ok(walkMs >= 1000, "the scene waits for the cutscene walk to finish");

  const moves = sent.filter((message) => message.type === "npc_move");
  assert.deepEqual(
    moves.map((message) => message.npcId),
    ["prologue_bianca_bedroom", "prologue_cheren_bedroom"],
    "the farewell shows both rivals leaving"
  );
  assert.deepEqual(
    (moves[0]?.path as Dict[]).map((point) => `${point.x},${point.y},${point.dir}`),
    ["6,4,right", "7,4,right", "7,3,up", "8,3,right", "8,2,up"],
    "each hop carries the facing the client should animate, and the path ends on the stairs"
  );
  assert.equal(moves[0]?.msPerTile, 500, "the default pace matches one map tile");
  assert.equal(moves[0]?.vanish, true, "the rivals disappear at the stairs, like the ROM's 0x45 action");
  // The scene opens by turning both rivals toward the player — the port's
  // version of the ROM applying a one-action turn sequence before dialogue.
  const faces = sent.filter((message) => message.type === "npc_face");
  assert.deepEqual(
    faces.map((message) => `${message.npcId}:${message.dir}`),
    [
      "prologue_cheren_bedroom:up",
      "prologue_bianca_bedroom:right"
    ],
    "the rivals turn to face the player before speaking"
  );
  assert.equal(player.story, null, "the scene finishes after both battles");
  assert.equal(last(sent, "story_end")?.sceneId, "prologue_bedroom_intro");
  assert.equal(player.character.storyFlags!["prologue.bedroomDone"], 1);
  assert.ok(
    sent.some(
      (message) =>
        message.type === "notice" && String(message.text).includes("apologize to Mom")
    )
  );
  assert.deepEqual((sent.filter((message) => message.type === "party_state").at(-1)?.party as unknown[] | undefined)?.length, 1);
});

test("the two sparring battles mirror the starter the player picked", () => {
  const pick = (optionId: string, value: number) => {
    const { controller, player, sent, trainerBattles } = makeHarness(
      makeCharacter({ "prologue.starterChosen": 0 })
    );
    controller.onEnter(player);
    playThrough(controller, player, sent);
    controller.choose(player, {
      sceneId: "prologue_bedroom_intro",
      step: player.story!.index,
      optionId
    });
    playThrough(controller, player, sent);
    assert.equal(player.character.storyFlags!["prologue.starter"], value);
    assert.equal(player.story?.awaiting, "battle");
    return { controller, player, sent, trainerBattles };
  };

  // Snivy (2): Bianca brings Tepig, Cheren brings Snivy.
  const snivy = pick("snivy", 2);
  assert.deepEqual(snivy.trainerBattles, [{ trainerId: "bianca_tepig" }]);
  closeBattle(snivy.controller, snivy.player, "lost");
  assert.equal(snivy.player.character.storyFlags!["8010"], 0, "a loss is written as 0");
  playThrough(snivy.controller, snivy.player, snivy.sent);
  assert.deepEqual(snivy.trainerBattles, [
    { trainerId: "bianca_tepig" },
    { trainerId: "cheren_snivy" }
  ]);

  // Oshawott (1): Bianca brings Snivy, Cheren brings Oshawott.
  const oshawott = pick("oshawott", 1);
  assert.deepEqual(oshawott.trainerBattles, [{ trainerId: "bianca_snivy" }]);
});

test("losing a sparring battle does not end the scene", () => {
  const { controller, player, sent } = makeHarness(
    makeCharacter({ "prologue.starterChosen": 0 })
  );
  controller.onEnter(player);
  playThrough(controller, player, sent);
  controller.choose(player, {
    sceneId: "prologue_bedroom_intro",
    step: player.story!.index,
    optionId: "tepig"
  });
  playThrough(controller, player, sent);
  closeBattle(controller, player, "lost");
  playThrough(controller, player, sent);
  const text = sent
    .filter((message) => message.type === "dialogue")
    .flatMap((message) => (message.lines as string[] | undefined) ?? [])
    .join("\n");
  assert.ok(text.includes("I got so absorbed"), "the lose branch plays Bianca's shock");
  assert.ok(text.includes("needs\nto be fixed up"), "the lose-only heal page is used");
  assert.equal(player.story?.awaiting, "battle", "the scene still reaches Cheren's battle");
});

test("dialogue after a battle waits for the result box to close", () => {
  const { controller, player, sent } = makeHarness(
    makeCharacter({ "prologue.starterChosen": 0 })
  );
  controller.onEnter(player);
  playThrough(controller, player, sent);
  controller.choose(player, {
    sceneId: "prologue_bedroom_intro",
    step: player.story!.index,
    optionId: "tepig"
  });
  playThrough(controller, player, sent);
  const before = sent.filter((message) => message.type === "dialogue").length;

  // A stray `battle_closed` from an ordinary wild battle must not advance the
  // scene, and the story must stay parked on the battle until it is reported.
  player.pendingStoryBattle = null;
  controller.onBattleClosed(player);
  assert.equal(player.story?.awaiting, "battle");
  assert.equal(sent.filter((message) => message.type === "dialogue").length, before);
});

test("the bedroom intro resumes after a disconnect and never replays once finished", () => {
  // Disconnected during the sparring battles: the partner and the pick are
  // already saved, so the scene must skip the choice and go straight to the
  // battle instead of soft-locking the player without `bedroomDone`.
  const resumed = makeHarness(
    makeCharacter({ "prologue.starterChosen": 1, "prologue.starter": 0 }, "unova_in_391", [
      "tepig"
    ])
  );
  resumed.controller.onEnter(resumed.player);
  assert.equal(resumed.player.story?.sceneId, "prologue_bedroom_intro");
  playThrough(resumed.controller, resumed.player, resumed.sent);
  assert.equal(resumed.player.story?.awaiting, "battle");
  assert.deepEqual(resumed.trainerBattles, [{ trainerId: "bianca_oshawott" }]);
  assert.equal(resumed.player.character.party.length, 1, "no second partner is granted");

  // Once the scene has finished, walking back into the bedroom is quiet.
  const done = makeHarness(
    makeCharacter(
      { "prologue.starterChosen": 1, "prologue.starter": 0, "prologue.bedroomDone": 1 },
      "unova_in_391",
      ["tepig"]
    )
  );
  done.controller.onEnter(done.player);
  assert.equal(done.player.story, null);
});

test("a stale or repeated page acknowledgement does not skip dialogue", () => {
  const { controller, player, sent } = makeHarness(makeCharacter({}));
  controller.onEnter(player);
  // Read the page index off the message: the scene runs its turn steps first,
  // so the opening dialogue is not step 0.
  const index = Number(last(sent, "dialogue")?.step ?? -1);
  assert.ok(index >= 0, "the scene opens on a dialogue page");
  assert.equal(player.story?.index, index);
  controller.advance(player, { sceneId: "prologue_bedroom_intro", step: index });
  const after = player.story!.index;
  assert.equal(after, index + 1);
  controller.advance(player, { sceneId: "prologue_bedroom_intro", step: index });
  assert.equal(player.story?.index, after, "the old page must be ignored");
  controller.advance(player, { sceneId: "another_scene", step: index + 1 });
  assert.equal(player.story?.index, after, "messages from another scene are ignored");
  assert.equal(sent.filter((message) => message.type === "dialogue").length, 2);
});

test("only an offered partner can be chosen", () => {
  const { controller, player } = makeHarness(makeCharacter({}));
  controller.onEnter(player);
  playThrough(controller, player, []);
  assert.equal(player.story?.awaiting, "choice");
  const step = player.story!.index;
  controller.choose(player, { sceneId: "prologue_bedroom_intro", step, optionId: "mewtwo" });
  assert.equal(player.character.party.length, 0);
  assert.equal(player.story?.awaiting, "choice", "the scene waits for a valid pick");
});

test("talk-to-NPC prologue scenes respect their conditions", () => {
  // Mom only talks about the journey once a partner exists.
  const before = makeHarness(makeCharacter({ "prologue.starterChosen": 0 }, "unova_in_390"));
  const momBefore = content.maps.unova_in_390.npcs.find((npc) => npc.id === "z390_n0");
  if (!momBefore) throw new Error("Mom should exist in the house");
  assert.equal(before.controller.interact(before.player, momBefore), false);
  assert.equal(before.player.story, null);

  const after = makeHarness(makeCharacter({ "prologue.starterChosen": 1 }, "unova_in_390"));
  // Zone 390 id3 duplicated id0 in the ROM data (same model, same script, but
  // gated behind spawnFlag 736), so the map now keeps only z390_n0.
  const momAfter = content.maps.unova_in_390.npcs.find((npc) => npc.id === "z390_n0");
  if (!momAfter) throw new Error("Mom should exist in the house");
  assert.equal(after.controller.interact(after.player, momAfter), true);
  assert.equal(after.player.story?.sceneId, "prologue_mom");
  playThrough(after.controller, after.player, after.sent);
  assert.equal(after.player.character.storyFlags!["prologue.momDone"], 1);
  assert.equal(after.player.story, null);

  // Once healed, Mom is a normal NPC again.
  assert.equal(after.controller.interact(after.player, momAfter), false);
});

test("the lab scene starts on entry and unlocks Route 1", () => {
  const { controller, player, sent } = makeHarness(
    makeCharacter({ "prologue.starterChosen": 1, "prologue.momDone": 1 }, "unova_in_396")
  );
  controller.onEnter(player);
  assert.equal(player.story?.sceneId, "prologue_juniper_pokedex");
  playThrough(controller, player, sent);
  assert.equal(player.character.storyFlags!["prologue.pokedex"], 1);
  assert.equal(player.character.storyFlags!["prologue.routeUnlocked"], 1);
  assert.equal(controller.gateAt(player, "unova_full", 788, 738), null);

  // Walking in again must not replay the cutscene.
  controller.onEnter(player);
  assert.equal(player.story, null);
});

test("the lab scene waits for the mother scene", () => {
  const { controller, player } = makeHarness(
    makeCharacter({ "prologue.starterChosen": 1, "prologue.momDone": 0 }, "unova_in_396")
  );
  controller.onEnter(player);
  assert.equal(player.story, null);
  const juniper = content.maps.unova_in_396.npcs.find((npc) => npc.id === "prologue_juniper_lab");
  if (!juniper) throw new Error("Juniper should exist in the lab");
  assert.equal(controller.interact(player, juniper), false, "she asks you to see Mom first");
});

test("old saves keep their auto starter; story saves do not", () => {
  const legacy = makeCharacter({});
  normalizeCharacter(content, legacy);
  assert.equal(legacy.party.length, 1, "a pre-story save gets the safety-net starter");

  const fresh = makeCharacter({ "prologue.starterChosen": 0 });
  normalizeCharacter(content, fresh);
  assert.equal(fresh.party.length, 0, "story characters wait for the gift box");
});

test("broken story references are reported", () => {
  const broken = structuredClone(content);
  broken.story!.startMap = "missing_map";
  broken.story!.gates.push({
    id: "bad_gate",
    mapId: "missing_map",
    x: 0,
    y: 0,
    width: 1,
    height: 1,
    when: { "prologue.starterChosen": 0 },
    lines: ["nope"]
  });
  broken.story!.scenes.prologue_mom.steps.push({ type: "warp", mapId: "nowhere" });
  broken.story!.scenes.prologue_mom.steps.push({ type: "givePokemon", species: "missingno" });
  const errors = validateContent(broken);
  assert.ok(errors.some((error) => error.includes("story.startMap")));
  assert.ok(errors.some((error) => error.includes("bad_gate")));
  assert.ok(errors.some((error) => error.includes("nowhere")));
  assert.ok(errors.some((error) => error.includes("missingno")));
});

test("story dialogue and speaker names follow the client locale", () => {
  const english = makeHarness(makeCharacter({}));
  english.controller.startScene(english.player, "prologue_bedroom_intro");
  const englishPage = last(english.sent, "dialogue");
  assert.ok(englishPage);
  assert.equal(englishPage!.npcName, "Cheren");
  assert.match(String((englishPage!.lines as string[]).join("\n")), /gift box/);

  const chinese = makeHarness(makeCharacter({}));
  chinese.player.conn.locale = "zh_CN";
  chinese.controller.startScene(chinese.player, "prologue_bedroom_intro");
  const chinesePage = last(chinese.sent, "dialogue");
  assert.ok(chinesePage);
  assert.equal(chinesePage!.npcName, "黑连");
  assert.deepEqual(chinesePage!.lines, [
    "快点打开\n礼物箱吧。",
    "宝可梦们一定也想\n快点与我们见面才对！"
  ]);
});
