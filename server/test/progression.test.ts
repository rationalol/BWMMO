import test from "node:test";
import assert from "node:assert/strict";
import { loadContent } from "../src/content/loader.js";
import {
  MAX_MOVES,
  awardExperience,
  createCreature,
  evolveCreature,
  forgetMove,
  healParty,
  levelEvolutionFor,
  normalizeCreatureProgress,
  pendingMovesFor,
  resolvePendingMove,
  xpToNext
} from "../src/game/creatures.js";
import {
  markSpeciesCaught,
  markSpeciesSeen,
  normalizePokedex
} from "../src/game/pokedex.js";
import { createBattle, resolveTurn } from "../src/game/battle.js";
import type { CharacterState } from "../src/game/types.js";

const content = loadContent();

test("creatures start with persisted PP and level evolutions come from content", () => {
  const snivy = createCreature(content, "snivy", 5);
  assert.ok(snivy.moves.length > 0);
  for (const move of snivy.moves) {
    assert.equal(move.currentPp, move.maxPp);
    assert.ok((move.currentPp ?? 0) > 0);
  }
  assert.deepEqual(content.species.snivy.evolutions, [
    { to: "servine", method: "level", level: 17 }
  ]);
  assert.deepEqual(content.species.servine.evolutions, [
    { to: "serperior", method: "level", level: 36 }
  ]);
});

test("a level-up evolves the creature and preserves PP", () => {
  const creature = createCreature(content, "snivy", 16);
  creature.moves[0].currentPp = 1;
  const log: string[] = [];
  const result = awardExperience(content, creature, xpToNext(content, 16), log);

  assert.equal(creature.level, 17);
  assert.equal(creature.species, "servine");
  assert.equal(creature.name, "Servine");
  assert.equal(result.evolution?.toSpecies, "servine");
  assert.equal(creature.moves[0].currentPp, 1);
  assert.ok(log.some((line) => line.includes("evolving")));
  assert.ok(log.some((line) => line.includes("evolved into Servine")));
});

test("special evolutions do not fire from level alone", () => {
  const eevee = createCreature(content, "eevee", 20);
  const result = awardExperience(content, eevee, xpToNext(content, 20), []);
  assert.equal(eevee.species, "eevee");
  assert.equal(result.evolution, null);
  assert.equal(levelEvolutionFor(content, eevee), null);
});

test("Tyrogue evolution follows its stat condition", () => {
  const tyrogue = createCreature(content, "tyrogue", 20);
  tyrogue.atk = 15;
  tyrogue.def = 20;
  const evolution = levelEvolutionFor(content, tyrogue);
  assert.equal(evolution?.to, "hitmonchan");
  const result = evolveCreature(content, tyrogue, evolution!);
  assert.equal(result?.toSpecies, "hitmonchan");
});

test("a full move set queues the new move instead of overwriting slot one", () => {
  const creature = createCreature(content, "snivy", 12);
  assert.equal(creature.moves.length, MAX_MOVES);
  const firstMove = creature.moves[0].id;
  const log: string[] = [];
  const result = awardExperience(content, creature, xpToNext(content, 12), log);

  assert.equal(creature.level, 13);
  assert.equal(creature.moves.length, MAX_MOVES);
  assert.equal(creature.moves[0].id, firstMove);
  assert.deepEqual(pendingMovesFor(creature), ["growth"]);
  assert.deepEqual(result.pendingMoves, ["growth"]);
  assert.ok(log.some((line) => line.includes("wants to learn Growth")));

  const learned = resolvePendingMove(content, creature, "growth", 2);
  assert.equal(learned.ok, true);
  assert.equal(creature.moves[2].id, "growth");
  assert.equal(creature.moves[2].currentPp, creature.moves[2].maxPp);
  assert.deepEqual(pendingMovesFor(creature), []);
});

test("declining a queued move removes it without touching the move set", () => {
  const creature = createCreature(content, "snivy", 12);
  awardExperience(content, creature, xpToNext(content, 12), []);
  const ids = creature.moves.map((move) => move.id);
  const result = resolvePendingMove(content, creature, "growth", null);
  assert.equal(result.ok, true);
  assert.equal(result.skipped, true);
  assert.deepEqual(creature.moves.map((move) => move.id), ids);
  assert.deepEqual(pendingMovesFor(creature), []);
});

test("an invalid replacement keeps the queued move", () => {
  const creature = createCreature(content, "snivy", 12);
  awardExperience(content, creature, xpToNext(content, 12), []);
  const result = resolvePendingMove(content, creature, "growth", 99);
  assert.equal(result.ok, false);
  assert.deepEqual(pendingMovesFor(creature), ["growth"]);
});

test("forgetting a move frees a slot and keeps at least one move", () => {
  const creature = createCreature(content, "snivy", 20);
  const forgotten = forgetMove(creature, 0);
  assert.equal(forgotten.ok, true);
  assert.equal(creature.moves.length, 3);
  creature.moves = [creature.moves[0]];
  const last = forgetMove(creature, 0);
  assert.equal(last.ok, false);
});

test("old saves gain PP fields and stale pending moves are dropped", () => {
  const creature = createCreature(content, "snivy", 10);
  const legacy = creature as unknown as {
    moves: Array<{ currentPp?: number; maxPp?: number }>;
    pendingMoves?: string[];
  };
  for (const move of legacy.moves) {
    delete move.currentPp;
    delete move.maxPp;
  }
  creature.pendingMoves = ["vinewhip", "not_a_move"];
  const changed = normalizeCreatureProgress(content, creature);
  assert.equal(changed, true);
  for (const move of creature.moves) {
    assert.equal(move.currentPp, move.maxPp);
  }
  assert.deepEqual(pendingMovesFor(creature), []);
});

test("PP spent in battle is persisted and zero-PP moves are rejected", () => {
  const party = [createCreature(content, "snivy", 5)];
  party[0].moves[0].currentPp = 1;
  const battle = createBattle(
    `pp-${Math.random()}`,
    party,
    createCreature(content, "patrat", 3),
    "Tester",
    { items: { poke_ball: 10 } },
    6,
    content.items
  );
  resolveTurn(battle, { action: "move", moveIndex: 0 }, () => 0.9);
  assert.equal(battle.party[0].moves[0].currentPp, 0);
  assert.equal(battle.party[0].moves[0].maxPp, 35);
  assert.throws(
    () => resolveTurn(battle, { action: "move", moveIndex: 0 }, () => 0.9),
    /no PP left/
  );
});

test("healing restores HP, status and PP", () => {
  const creature = createCreature(content, "snivy", 8);
  creature.hp = 1;
  creature.status = "psn";
  for (const move of creature.moves) move.currentPp = 0;
  healParty([creature]);
  assert.equal(creature.hp, creature.maxHp);
  assert.equal(creature.status, undefined);
  for (const move of creature.moves) {
    assert.equal(move.currentPp, move.maxPp);
  }
});

test("the pokedex records seen and caught species and repairs old saves", () => {
  const character: CharacterState = {
    id: "dex-test",
    name: "Dexter",
    color: "#e76f51",
    mapId: "unova_full",
    x: 784,
    y: 753,
    dir: "down",
    sprite: 0,
    money: 0,
    wins: 0,
    party: [createCreature(content, "snivy", 5)],
    box: [],
    inventory: { items: {} }
  };
  assert.equal(normalizePokedex(content, character), true);
  assert.deepEqual(character.pokedex, { seen: [495], caught: [495] });
  assert.equal(markSpeciesSeen(content, character, "patrat"), true);
  assert.equal(markSpeciesSeen(content, character, "patrat"), false);
  assert.equal(markSpeciesCaught(content, character, "patrat"), true);
  assert.deepEqual(character.pokedex, { seen: [495, 504], caught: [495, 504] });
  normalizePokedex(content, character);
  assert.deepEqual(character.pokedex, { seen: [495, 504], caught: [495, 504] });
});
