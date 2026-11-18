import test from "node:test";
import assert from "node:assert/strict";
import { loadContent } from "../src/content/loader.js";
import { settleBattle } from "../src/game/battle-outcome.js";
import { createStarter, createWildCreature, xpToNext } from "../src/game/creatures.js";
import type { BattleState, BattleStatus } from "../src/game/battle.js";
import type { CharacterState, CreatureState } from "../src/game/types.js";

const content = loadContent();

function makeCharacter(): CharacterState {
  const starter = createStarter(content, "snivy");
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
    party: [starter],
    box: [],
    inventory: { items: { poke_ball: 5, potion: 1 } },
    pokedex: { seen: [], caught: [] },
    storyFlags: {}
  };
}

function makeBattle(
  status: BattleStatus,
  character: CharacterState,
  wild: CreatureState
): BattleState {
  return {
    id: "battle",
    mode: "wild",
    playerName: character.name,
    party: character.party,
    activeIndex: 0,
    player: character.party[0],
    wild,
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

test("a win pays the reward and syncs the party", () => {
  const character = makeCharacter();
  const battle = makeBattle("won", character, createWildCreature(content, "patrat", 3));
  const result = settleBattle(content, character, battle);

  assert.equal(result.result, "won");
  assert.equal(result.travel, false);
  assert.equal(result.pokedexChanged, false);
  assert.equal(character.money, 100 + content.config.winReward);
  assert.equal(character.wins, 1);
  assert.match(result.message, /coins/);
  assert.equal(character.party[0].hp, battle.party[0].hp);
});

test("a loss heals the team and warps to the starting map", () => {
  const character = makeCharacter();
  character.party[0].hp = 0;
  character.party[0].status = "psn";
  const battle = makeBattle("lost", character, createWildCreature(content, "patrat", 20));
  const result = settleBattle(content, character, battle);

  const home = content.maps[content.config.startingMap];
  assert.equal(result.result, "lost");
  assert.equal(result.travel, true);
  assert.equal(character.mapId, home.id);
  assert.equal(character.x, home.spawn.x);
  assert.equal(character.y, home.spawn.y);
  assert.equal(character.dir, home.spawn.dir);
  assert.equal(character.party[0].hp, character.party[0].maxHp);
  assert.equal(character.party[0].status, undefined);
  assert.match(result.message, new RegExp(home.name));
});

test("a caught creature joins the party and the dex", () => {
  const character = makeCharacter();
  const wild = createWildCreature(content, "patrat", 3);
  const battle = makeBattle("caught", character, wild);
  const result = settleBattle(content, character, battle);

  assert.equal(result.result, "caught");
  assert.equal(result.travel, false);
  assert.equal(character.party.length, 2);
  assert.equal(character.party[1].species, "patrat");
  assert.equal(character.party[1].xp, 0);
  assert.ok(character.pokedex?.caught.includes(content.species.patrat.dex));
  assert.equal(result.pokedexChanged, true);
  assert.match(result.message, /was caught/);
});

test("a full party still marks the creature as caught", () => {
  const character = makeCharacter();
  character.party = Array.from({ length: content.config.maxParty }, () =>
    createStarter(content, "snivy")
  );
  const battle = makeBattle("caught", character, createWildCreature(content, "patrat", 3));
  const result = settleBattle(content, character, battle);

  assert.equal(result.result, "caught");
  assert.equal(character.party.length, content.config.maxParty);
  assert.ok(character.pokedex?.caught.includes(content.species.patrat.dex));
  assert.match(result.message, /party is full/);
});

test("fleeing keeps the character in place and pays nothing", () => {
  const character = makeCharacter();
  const battle = makeBattle("fled", character, createWildCreature(content, "patrat", 3));
  const result = settleBattle(content, character, battle);

  assert.equal(result.result, "fled");
  assert.equal(result.travel, false);
  assert.equal(character.money, 100);
  assert.equal(character.mapId, "unova_full");
  assert.equal(result.message, "You got away safely.");
});

test("a win reports level ups against the pre-evolution name", () => {
  const character = makeCharacter();
  const starter = createStarter(content, "snivy");
  starter.level = 16;
  starter.xp = xpToNext(content, 16) - 1;
  character.party = [starter];
  const battle = makeBattle("won", character, createWildCreature(content, "patrat", 30));
  battle.player = starter;

  const result = settleBattle(content, character, battle);

  assert.equal(result.result, "won");
  assert.equal(result.levelUps.length, 1);
  assert.equal(result.levelUps[0].name, "Snivy");
  assert.equal(result.levelUps[0].species, "snivy");
  assert.equal(result.levelUps[0].level, 17);
  assert.equal(result.evolution?.toSpecies, "servine");
  assert.equal(character.party[0].species, "servine");
});
