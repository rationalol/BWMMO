import test from "node:test";
import assert from "node:assert/strict";
import { loadContent } from "../src/content/loader.js";
import { createCreature } from "../src/game/creatures.js";
import { depositToBox, swapPartyWithBox, withdrawFromBox } from "../src/game/pc.js";
import type { CharacterState } from "../src/game/types.js";

const content = loadContent();

function makeCharacter(partyIds: string[] = ["snivy", "tepig"]): CharacterState {
  return {
    id: "char",
    name: "Tester",
    color: "#e76f51",
    mapId: "unova_full",
    x: 784,
    y: 753,
    dir: "down",
    sprite: 0,
    money: 500,
    wins: 0,
    party: partyIds.map((id) => createCreature(content, id, 5)),
    box: [],
    inventory: { items: { poke_ball: 10 } },
    storyFlags: {}
  };
}

test("deposit keeps the creature's HP and status", () => {
  const character = makeCharacter();
  character.party[1].hp = 3;
  character.party[1].status = "brn";
  const result = depositToBox(character, 1, 30);
  assert.equal(result.ok, true);
  assert.equal(character.party.length, 1);
  assert.equal(character.box.length, 1);
  assert.equal(character.box[0].species, "tepig");
  assert.equal(character.box[0].hp, 3);
  assert.equal(character.box[0].status, "brn");
});

test("deposit refuses to empty the party or overflow the box", () => {
  const character = makeCharacter(["snivy"]);
  assert.equal(depositToBox(character, 0, 30).ok, false);
  assert.equal(character.party.length, 1);

  const full = makeCharacter();
  full.box = [createCreature(content, "patrat", 2)];
  const result = depositToBox(full, 0, 1);
  assert.equal(result.ok, false);
  assert.match(result.error ?? "", /box is full/);
});

test("withdraw refuses when the party is full", () => {
  const character = makeCharacter([
    "snivy",
    "tepig",
    "oshawott",
    "pansage",
    "pansear",
    "panpour"
  ]);
  character.box = [createCreature(content, "patrat", 2)];
  const result = withdrawFromBox(character, 0, 6);
  assert.equal(result.ok, false);
  assert.match(result.error ?? "", /party is full/);
  assert.equal(character.box.length, 1);
});

test("withdraw moves the stored creature back into the party", () => {
  const character = makeCharacter(["snivy"]);
  character.box = [createCreature(content, "patrat", 2)];
  const result = withdrawFromBox(character, 0, 6);
  assert.equal(result.ok, true);
  assert.equal(character.party.length, 2);
  assert.equal(character.party[1].species, "patrat");
  assert.equal(character.box.length, 0);
});

test("swap exchanges a party and a stored creature", () => {
  const character = makeCharacter(["snivy"]);
  character.box = [createCreature(content, "patrat", 2)];
  const result = swapPartyWithBox(character, 0, 0);
  assert.equal(result.ok, true);
  assert.equal(character.party[0].species, "patrat");
  assert.equal(character.box[0].species, "snivy");
});

test("invalid indices are rejected", () => {
  const character = makeCharacter();
  assert.equal(depositToBox(character, 9, 30).ok, false);
  assert.equal(withdrawFromBox(character, 0, 6).ok, false);
  assert.equal(swapPartyWithBox(character, -1, 0).ok, false);
});
