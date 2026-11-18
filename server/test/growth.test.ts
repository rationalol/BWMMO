import test from "node:test";
import assert from "node:assert/strict";
import { loadContent } from "../src/content/loader.js";
import {
  awardExperience,
  createCreature,
  evolveCreature,
  forgetMove,
  levelEvolutionFor,
  pendingMovesFor,
  resolvePendingMove,
  xpToNext
} from "../src/game/creatures.js";
import {
  canRememberMove,
  itemEvolutionFor,
  maxFriendship,
  normalizeNickname,
  queueMoveLearn,
  relearnableMoves,
  releaseFromBox,
  renameCreature,
  tradeEvolutionFor,
  tutorMovesFor
} from "../src/game/growth.js";
import type { CharacterState, CreatureState } from "../src/game/types.js";

const content = loadContent();

function characterWith(party: CreatureState[], box: CreatureState[] = []): CharacterState {
  return {
    id: "test-character",
    name: "Tester",
    color: "#e76f51",
    mapId: "unova_in_396",
    x: 8,
    y: 9,
    dir: "down",
    sprite: 0,
    money: 0,
    wins: 0,
    party,
    box,
    inventory: { items: {} }
  };
}

test("TMs reference real moves and are reusable content", () => {
  const tms = Object.values(content.items).filter((item) => item.category === "tm");
  assert.ok(tms.length >= 5);
  for (const tm of tms) {
    assert.ok(tm.moveId, `${tm.id} should teach a move`);
    assert.ok(content.moves[tm.moveId!], `${tm.id} references ${tm.moveId}`);
  }
});

test("evolution stones are content items", () => {
  for (const itemId of [
    "firestone",
    "waterstone",
    "thunderstone",
    "leafstone",
    "moonstone",
    "sunstone",
    "shinystone",
    "duskstone",
    "dawnstone"
  ]) {
    assert.equal(content.items[itemId]?.category, "evolution", itemId);
  }
});

test("tutor and reminder queue moves through the existing learn prompt", () => {
  const snivy = createCreature(content, "snivy", 17);
  const forgotten = snivy.moves[0];
  const forgetResult = forgetMove(snivy, 0);
  assert.equal(forgetResult.ok, true);
  assert.equal(canRememberMove(content, snivy, forgotten.id), true);
  assert.ok(relearnableMoves(content, snivy).some((move) => move.id === forgotten.id));

  const queued = queueMoveLearn(content, snivy, forgotten.id);
  assert.equal(queued.ok, true);
  assert.ok(pendingMovesFor(snivy).includes(forgotten.id));
  const alreadyQueued = queueMoveLearn(content, snivy, forgotten.id);
  assert.equal(alreadyQueued.ok, false);

  // Three moves remain, so the free slot is filled without a replacement.
  const resolved = resolvePendingMove(content, snivy, forgotten.id, 0);
  assert.equal(resolved.ok, true);
  assert.ok(snivy.moves.some((move) => move.id === forgotten.id));
});

test("tutor moves come from the NPC list and skip known moves", () => {
  const tutor = content.maps.unova_in_396.npcs.find((npc) => npc.id === "test_move_tutor");
  assert.ok(tutor);
  assert.ok(tutor!.moveList?.includes("workup"));
  const snivy = createCreature(content, "snivy", 5);
  const available = tutorMovesFor(content, tutor!, snivy);
  assert.ok(available.some((move) => move.id === "workup"));
  assert.equal(available.some((move) => snivy.moves.some((known) => known.id === move.id)), false);
});

test("item evolutions use the species table", () => {
  const pikachu = createCreature(content, "pikachu", 20);
  const evolution = itemEvolutionFor(content, pikachu, "thunderstone");
  assert.equal(evolution?.to, "raichu");
  assert.equal(itemEvolutionFor(content, pikachu, "waterstone"), null);
  const result = evolveCreature(content, pikachu, evolution!);
  assert.equal(pikachu.species, "raichu");
  assert.equal(result?.fromSpecies, "pikachu");
});

test("trade evolutions work with and without a held item", () => {
  const kadabra = createCreature(content, "kadabra", 30);
  assert.equal(tradeEvolutionFor(content, kadabra)?.to, "alakazam");
  const machoke = createCreature(content, "machoke", 30);
  assert.equal(tradeEvolutionFor(content, machoke)?.to, "machamp");

  const poliwhirl = createCreature(content, "poliwhirl", 30);
  assert.equal(tradeEvolutionFor(content, poliwhirl), null);
  poliwhirl.heldItem = "kingsrock";
  assert.equal(tradeEvolutionFor(content, poliwhirl)?.to, "politoed");
});

test("friendship evolutions need 220 friendship", () => {
  const golbat = createCreature(content, "golbat", 30);
  golbat.friendship = 219;
  assert.equal(levelEvolutionFor(content, golbat), null);
  golbat.friendship = 220;
  assert.equal(levelEvolutionFor(content, golbat)?.to, "crobat");

  golbat.friendship = 100;
  maxFriendship([golbat]);
  assert.equal(golbat.friendship, 255);
});

test("a level-up raises friendship and can trigger the friendship evolution", () => {
  const golbat = createCreature(content, "golbat", 29);
  golbat.friendship = 220;
  const result = awardExperience(content, golbat, xpToNext(content, 29), []);
  assert.equal(golbat.level, 30);
  assert.equal(result.evolution?.toSpecies, "crobat");
  assert.equal(golbat.friendship, 222);
});

test("location evolutions only fire in the original area", () => {
  const magneton = createCreature(content, "magneton", 30);
  assert.equal(levelEvolutionFor(content, magneton, { mapId: "unova_in_396" }), null);
  assert.equal(
    levelEvolutionFor(content, magneton, { mapId: "unova_in_195" })?.to,
    "magnezone"
  );
});

test("nicknames are trimmed and length-limited", () => {
  assert.equal(normalizeNickname("  Sprout  "), "Sprout");
  assert.equal(normalizeNickname("藤藤蛇"), "藤藤蛇");
  assert.equal(normalizeNickname("   "), null);
  assert.equal(normalizeNickname("1234567890123"), null);
  assert.equal(normalizeNickname("bad\nname"), null);

  const character = characterWith([createCreature(content, "snivy", 5)]);
  const result = renameCreature(character, "party", 0, "  Ivy  ");
  assert.equal(result.ok, true);
  assert.equal(character.party[0].name, "Ivy");
  const bad = renameCreature(character, "party", 0, "");
  assert.equal(bad.ok, false);
});

test("release only removes boxed creatures", () => {
  const boxed = createCreature(content, "patrat", 4);
  const character = characterWith([createCreature(content, "snivy", 5)], [boxed]);
  const result = releaseFromBox(character, 0);
  assert.equal(result.ok, true);
  assert.equal(character.box.length, 0);
  assert.equal(result.creature?.species, "patrat");
  assert.equal(releaseFromBox(character, 0).ok, false);
  assert.equal(character.party.length, 1);
});
