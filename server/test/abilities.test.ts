import test from "node:test";
import assert from "node:assert/strict";
import { loadContent } from "../src/content/loader.js";
import { ContentLocalizer } from "../src/i18n/localizer.js";
import {
  abilityOptionsForSpecies,
  resolveAbilityForSpecies
} from "../src/game/abilities.js";
import {
  createCreature,
  evolveCreature,
  normalizeCreatureProgress
} from "../src/game/creatures.js";
import { createBattle, resolveTurn } from "../src/game/battle.js";
import { BattleController } from "../src/game/battles.js";
import type { PlayerSession } from "../src/game/protocol.js";
import type { GameHost } from "../src/game/runtime.js";
import type { Inventory } from "../src/game/types.js";

const content = loadContent();

function inventory(): Inventory {
  return { items: { poke_ball: 10 } };
}

test("new creatures carry their default ability and slot", () => {
  const snivy = createCreature(content, "snivy", 5);
  assert.equal(snivy.ability, "overgrow");
  assert.equal(snivy.abilitySlot, 0);

  const pidgey = createCreature(content, "pidgey", 5);
  assert.equal(pidgey.ability, "keeneye");
  assert.equal(pidgey.abilitySlot, 0);
  const options = abilityOptionsForSpecies("pidgey");
  assert.deepEqual(
    options.map((option) => option.id),
    ["keeneye", "tangledfeet", "bigpecks"]
  );
  assert.equal(options[2].hidden, true);
});

test("normalization repairs missing or illegal abilities", () => {
  const creature = createCreature(content, "eevee", 5);
  delete creature.ability;
  delete creature.abilitySlot;
  assert.equal(normalizeCreatureProgress(content, creature), true);
  assert.equal(creature.ability, "runaway");
  assert.equal(creature.abilitySlot, 0);

  creature.ability = "not-a-real-ability";
  creature.abilitySlot = 2;
  assert.equal(normalizeCreatureProgress(content, creature), true);
  assert.equal(creature.ability, "runaway");
  assert.equal(creature.abilitySlot, 0);

  const resolved = resolveAbilityForSpecies("eevee", "adaptability", 1);
  assert.equal(resolved?.id, "adaptability");
  assert.equal(resolved?.slot, 1);

  const chosen = createCreature(content, "snivy", 5);
  chosen.ability = "contrary";
  chosen.abilitySlot = 2;
  const roundTrip = JSON.parse(JSON.stringify(chosen));
  normalizeCreatureProgress(content, roundTrip);
  assert.equal(roundTrip.ability, "contrary");
  assert.equal(roundTrip.abilitySlot, 2);
});

test("evolution keeps a legal ability and falls back when it is not", () => {
  const snivy = createCreature(content, "snivy", 15);
  const servineEvo = content.species.snivy.evolutions.find(
    (evolution) => evolution.to === "servine"
  );
  assert.ok(servineEvo);
  evolveCreature(content, snivy, servineEvo!);
  assert.equal(snivy.ability, "overgrow");

  const eevee = createCreature(content, "eevee", 15);
  eevee.ability = "runaway";
  eevee.abilitySlot = 0;
  const espeonEvo = content.species.eevee.evolutions.find(
    (evolution) => evolution.to === "espeon"
  );
  assert.ok(espeonEvo);
  evolveCreature(content, eevee, espeonEvo!);
  assert.equal(eevee.ability, "synchronize");
  assert.equal(eevee.abilitySlot, 0);
});

test("localized creature views include the ability name and description", () => {
  const localizer = new ContentLocalizer(content);
  const snivy = createCreature(content, "snivy", 5);
  const zh = localizer.creature("zh_CN", snivy);
  assert.equal(zh.ability, "overgrow");
  assert.equal(zh.abilityName, "茂盛");
  assert.ok(zh.abilityDescription?.includes("草属性"));
  const en = localizer.creature("en", snivy);
  assert.equal(en.abilityName, "Overgrow");
  assert.ok(en.abilityDescription?.includes("Grass"));

  const ids = new Set<string>();
  for (const species of Object.values(content.species)) {
    for (const option of abilityOptionsForSpecies(species.id)) ids.add(option.id);
  }
  for (const id of ids) {
    assert.notEqual(localizer.abilityName("zh_CN", id), id, `missing zh name for ${id}`);
    assert.ok(
      localizer.abilityDescription("zh_CN", id).length > 0,
      `missing zh description for ${id}`
    );
  }
});

test("battle state announces switch-in abilities", () => {
  const wild = createCreature(content, "sandile", 20);
  assert.equal(wild.ability, "intimidate");
  const battle = createBattle(
    "ability-intimidate",
    [createCreature(content, "snivy", 20)],
    wild,
    "Tester",
    inventory(),
    6,
    content.items
  );
  const event = battle.events.find((value) => value.type === "ability");
  assert.ok(event);
  assert.equal(event?.type, "ability");
  assert.equal((event as { abilityId?: string }).abilityId, "intimidate");
  assert.equal((event as { side?: string }).side, "wild");

  const moxie = createCreature(content, "sandile", 20);
  moxie.ability = "moxie";
  moxie.abilitySlot = 1;
  const noIntimidate = createBattle(
    "ability-moxie",
    [createCreature(content, "snivy", 20)],
    moxie,
    "Tester",
    inventory(),
    6,
    content.items
  );
  assert.equal(
    noIntimidate.events.some(
      (value) =>
        value.type === "ability" &&
        (value as { abilityId?: string }).abilityId === "intimidate"
    ),
    false
  );
});

test("a mid-battle switch-in produces an ability event", () => {
  const battle = createBattle(
    "ability-switch",
    [createCreature(content, "snivy", 20), createCreature(content, "sandile", 20)],
    createCreature(content, "patrat", 20),
    "Tester",
    inventory(),
    6,
    content.items
  );
  resolveTurn(battle, { action: "switch", partyIndex: 1 }, () => 0.99);
  assert.ok(
    battle.events.some(
      (value) => value.type === "ability" && value.side === "player"
    ),
    "Sandile's Intimidate should be in the turn events"
  );
});

test("battle views localize ability events for the client", () => {
  const localizer = new ContentLocalizer(content);
  const controller = new BattleController({
    content,
    i18n: localizer
  } as unknown as GameHost);
  const battle = createBattle(
    "ability-localized",
    [createCreature(content, "snivy", 20)],
    createCreature(content, "sandile", 20),
    "Tester",
    inventory(),
    6,
    content.items
  );
  const view = controller.view(
    { conn: { locale: "zh_CN" } } as unknown as PlayerSession,
    battle
  );
  const event = view.events.find((value) => value.type === "ability");
  assert.ok(event);
  assert.equal((event as { abilityName?: string }).abilityName, "威吓");
  assert.ok(
    (event as { description?: string }).description?.includes("攻击")
  );
});

test("damage boosts and passive ability sources become ability events", () => {
  const snivy = createCreature(content, "snivy", 50);
  snivy.hp = 1;
  const vineWhip = content.moves.vinewhip;
  assert.ok(vineWhip);
  snivy.moves = [{
    ...vineWhip!,
    currentPp: vineWhip!.pp,
    maxPp: vineWhip!.pp
  }];
  const growBattle = createBattle(
    "ability-overgrow",
    [snivy],
    createCreature(content, "magikarp", 5),
    "Tester",
    inventory(),
    6,
    content.items
  );
  resolveTurn(growBattle, { action: "move", moveIndex: 0 }, () => 0.99);
  assert.ok(
    growBattle.events.some(
      (value) =>
        value.type === "ability" &&
        (value as { abilityId?: string }).abilityId === "overgrow"
    ),
    "Overgrow's damage boost should be announced"
  );

  const sandile = createCreature(content, "sandile", 50);
  const earthquake = content.moves.earthquake;
  assert.ok(earthquake);
  sandile.moves = [{
    ...earthquake!,
    currentPp: earthquake!.pp,
    maxPp: earthquake!.pp
  }];
  const levitateBattle = createBattle(
    "ability-levitate",
    [sandile],
    createCreature(content, "eelektrik", 50),
    "Tester",
    inventory(),
    6,
    content.items
  );
  resolveTurn(levitateBattle, { action: "move", moveIndex: 0 }, () => 0.99);
  assert.ok(
    levitateBattle.events.some(
      (value) =>
        value.type === "ability" &&
        (value as { abilityId?: string }).abilityId === "levitate"
    ),
    "Levitate's immunity should name the ability"
  );
});
