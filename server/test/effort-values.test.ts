import test from "node:test";
import assert from "node:assert/strict";
import { Battle } from "@pkmn/sim";
import { loadContent } from "../src/content/loader.js";
import { settleBattle } from "../src/game/battle-outcome.js";
import type { BattleState, BattleStatus } from "../src/game/battle.js";
import { normalizeCharacter } from "../src/game/character-normalizer.js";
import {
  MAX_EV_PER_STAT,
  MAX_EV_TOTAL,
  awardEffortValues,
  createCreature,
  emptyEvBlock,
  statsForCreature
} from "../src/game/creatures.js";
import type { CharacterState, CreatureState, StatBlock } from "../src/game/types.js";

const content = loadContent();

function ivBlock(value: number): StatBlock {
  return { hp: value, atk: value, def: value, spAtk: value, spDef: value, speed: value };
}

function makeCharacter(party: CreatureState[]): CharacterState {
  return {
    id: "char",
    name: "Tester",
    color: "#e76f51",
    mapId: "unova_full",
    x: 784,
    y: 753,
    dir: "down",
    sprite: 0,
    money: 100,
    wins: 0,
    party,
    box: [],
    inventory: { items: {} },
    pokedex: { seen: [], caught: [] },
    storyFlags: {}
  };
}

function makeBattle(
  status: BattleStatus,
  character: CharacterState,
  wild: CreatureState,
  mode: "wild" | "trainer" = "wild",
  opponentParty?: CreatureState[]
): BattleState {
  return {
    id: "battle",
    mode,
    playerName: character.name,
    party: character.party,
    activeIndex: 0,
    player: character.party[0],
    wild,
    opponentParty,
    log: [],
    events: [],
    turn: 4,
    awaitingAction: false,
    mustSwitch: false,
    status,
    inventory: character.inventory,
    maxParty: content.config.maxParty
  };
}

test("every species carries a Gen 5 EV yield of 1-3 points", () => {
  const species = Object.values(content.species);
  assert.ok(species.length >= 649);
  for (const entry of species) {
    assert.ok(entry.evYield, `${entry.id} has no evYield`);
    let total = 0;
    for (const stat of ["hp", "atk", "def", "spAtk", "spDef", "speed"] as const) {
      const value = entry.evYield[stat];
      assert.ok(
        Number.isInteger(value) && value >= 0 && value <= 3,
        `${entry.id}.${stat} = ${value}`
      );
      total += value;
    }
    assert.ok(total >= 1 && total <= 3, `${entry.id} yields ${total} EVs`);
  }
  assert.deepEqual(content.species.patrat.evYield, {
    hp: 0, atk: 1, def: 0, spAtk: 0, spDef: 0, speed: 0
  });
  assert.deepEqual(content.species.audino.evYield, {
    hp: 2, atk: 0, def: 0, spAtk: 0, spDef: 0, speed: 0
  });
  assert.deepEqual(content.species.hydreigon.evYield, {
    hp: 0, atk: 0, def: 0, spAtk: 3, spDef: 0, speed: 0
  });
});

test("the stat formula folds IVs, EVs and nature in like Showdown", () => {
  const snivy = content.species.snivy;
  const stats = statsForCreature(snivy, {
    level: 50,
    ivs: ivBlock(31),
    evs: emptyEvBlock(),
    nature: "Serious"
  });
  assert.deepEqual(stats, {
    maxHp: 120, atk: 65, def: 75, spAtk: 65, spDef: 75, speed: 83
  });

  const trained = statsForCreature(snivy, {
    level: 50,
    ivs: ivBlock(31),
    evs: { hp: 252, atk: 0, def: 0, spAtk: 0, spDef: 0, speed: 252 },
    nature: "Timid"
  });
  assert.equal(trained.maxHp, 152);
  // Timid: -10% Attack, +10% Speed.
  assert.equal(trained.atk, 58);
  assert.equal(trained.speed, 126);
  // Untouched stats ignore the nature.
  assert.equal(trained.def, 75);

  const battle = new Battle({ formatid: "gen5customgame" } as any);
  const baseStats = {
    hp: snivy.baseHp,
    atk: snivy.baseAtk,
    def: snivy.baseDef,
    spa: snivy.baseSpAtk,
    spd: snivy.baseSpDef,
    spe: snivy.baseSpeed
  };
  const expected = (battle as any).spreadModify(baseStats, {
    level: 50,
    nature: "Timid",
    ivs: { hp: 31, atk: 31, def: 31, spa: 31, spd: 31, spe: 31 },
    evs: { hp: 252, atk: 0, def: 0, spa: 0, spd: 0, spe: 252 }
  });
  assert.deepEqual(
    [trained.maxHp, trained.atk, trained.def, trained.spAtk, trained.spDef, trained.speed],
    [expected.hp, expected.atk, expected.def, expected.spa, expected.spd, expected.spe]
  );
});

test("EV gains stop at 255 per stat and 510 total", () => {
  const creature = createCreature(content, "patrat", 100);
  creature.ivs = ivBlock(31);
  creature.nature = "Serious";
  creature.evs = emptyEvBlock();
  const patrat = content.species.patrat;
  const before = statsForCreature(patrat, creature).atk;
  let gained = 0;
  for (let win = 0; win < 300; win++) {
    const gain = awardEffortValues(creature, patrat, patrat.evYield);
    gained += gain.atk;
  }
  assert.equal(creature.evs!.atk, MAX_EV_PER_STAT);
  assert.equal(gained, MAX_EV_PER_STAT);
  // 252 EVs add 63 Attack at level 100.
  assert.equal(creature.atk, before + 63);
  assert.equal(awardEffortValues(creature, patrat, patrat.evYield).atk, 0);

  // The 510-point budget leaves no room for another yield.
  const extra = createCreature(content, "patrat", 100);
  extra.evs = { hp: 252, atk: 252, def: 6, spAtk: 0, spDef: 0, speed: 0 };
  assert.equal(extra.evs.hp + extra.evs.atk + extra.evs.def, MAX_EV_TOTAL);
  const speedYield = { hp: 0, atk: 0, def: 0, spAtk: 0, spDef: 0, speed: 3 };
  const gain = awardEffortValues(extra, patrat, speedYield);
  assert.deepEqual(gain, { hp: 0, atk: 0, def: 0, spAtk: 0, spDef: 0, speed: 0 });
});

test("winning a wild battle awards the defeated species' EVs", () => {
  const starter = createCreature(content, "snivy", 50);
  const character = makeCharacter([starter]);
  const wild = createCreature(content, "patrat", 3);
  const battle = makeBattle("won", character, wild);
  const result = settleBattle(content, character, battle);

  assert.equal(result.effortValues.atk, 1);
  assert.deepEqual(character.party[0].evs, {
    hp: 0, atk: 1, def: 0, spAtk: 0, spDef: 0, speed: 0
  });
  assert.match(result.message, /1 Attack EV\./);
  assert.ok(battle.log.some((line) => line.includes("gained 1 Attack EV")));
});

test("caught and lost battles award no EVs", () => {
  const starter = createCreature(content, "snivy", 50);
  const character = makeCharacter([starter]);
  const wild = createCreature(content, "patrat", 3);
  const caught = settleBattle(content, character, makeBattle("caught", character, wild));
  assert.equal(caught.effortValues.atk, 0);
  assert.equal(character.party[0].evs!.atk, 0);

  const character2 = makeCharacter([createCreature(content, "snivy", 50)]);
  const lost = settleBattle(
    content,
    character2,
    makeBattle("lost", character2, createCreature(content, "patrat", 3))
  );
  assert.equal(lost.effortValues.atk, 0);
  assert.equal(character2.party[0].evs!.atk, 0);
});

test("a trainer win awards every fainted opponent's yield", () => {
  const starter = createCreature(content, "snivy", 50);
  const character = makeCharacter([starter]);
  const patrat = createCreature(content, "patrat", 3);
  const audino = createCreature(content, "audino", 3);
  patrat.hp = 0;
  audino.hp = 0;
  const battle = makeBattle("won", character, audino, "trainer", [patrat, audino]);
  const result = settleBattle(content, character, battle);

  assert.deepEqual(result.effortValues, {
    hp: 2, atk: 1, def: 0, spAtk: 0, spDef: 0, speed: 0
  });
  assert.deepEqual(character.party[0].evs, {
    hp: 2, atk: 1, def: 0, spAtk: 0, spDef: 0, speed: 0
  });
  assert.match(result.message, /2 HP, 1 Attack EVs\./);
});

test("older saves migrate to trained stats on load", () => {
  const creature = createCreature(content, "snivy", 50);
  creature.ivs = ivBlock(31);
  creature.nature = "Adamant";
  // Values the pre-IV/EV server stored (no IVs, neutral nature).
  const legacy = statsForCreature(content.species.snivy, { level: 50 });
  Object.assign(creature, legacy);
  creature.hp = legacy.maxHp;
  delete creature.evs;

  const character = makeCharacter([creature]);
  assert.equal(normalizeCharacter(content, character), true);
  assert.deepEqual(creature.evs, emptyEvBlock());
  const expected = statsForCreature(content.species.snivy, creature);
  assert.deepEqual(
    [creature.maxHp, creature.atk, creature.def, creature.spAtk, creature.spDef, creature.speed],
    [expected.maxHp, expected.atk, expected.def, expected.spAtk, expected.spDef, expected.speed]
  );
  // Adamant: +10% Attack, -10% Sp. Atk.
  assert.equal(creature.atk, 71);
  assert.equal(creature.spAtk, 58);
});
