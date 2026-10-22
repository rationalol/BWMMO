import test from "node:test";
import assert from "node:assert/strict";
import { loadContent } from "../src/content/loader.js";
import { createCreature } from "../src/game/creatures.js";
import {
  MAX_STACK,
  addItem,
  applyMedicine,
  buildStartingInventory,
  itemCount,
  removeItem,
  sellPrice
} from "../src/game/items.js";

const content = loadContent();

test("starting inventory merges the ball count and starting items", () => {
  const inventory = buildStartingInventory(content);
  assert.equal(inventory.items.poke_ball, content.config.startingBalls);
  assert.equal(inventory.items.potion, 3);
});

test("item stacks add, cap and remove", () => {
  const inventory = { items: {} as Record<string, number> };
  assert.equal(addItem(inventory, "potion", 2), 2);
  assert.equal(itemCount(inventory, "potion"), 2);
  assert.equal(addItem(inventory, "potion", MAX_STACK), MAX_STACK - 2);
  assert.equal(itemCount(inventory, "potion"), MAX_STACK);
  assert.equal(removeItem(inventory, "potion", 5), 5);
  assert.equal(itemCount(inventory, "potion"), MAX_STACK - 5);
  assert.equal(removeItem(inventory, "potion", MAX_STACK), MAX_STACK - 5);
  assert.equal(itemCount(inventory, "potion"), 0);
  assert.equal("potion" in inventory.items, false);
});

test("selling returns half the buy price", () => {
  assert.equal(sellPrice(content.items.poke_ball), 100);
  assert.equal(sellPrice(content.items.potion), 150);
  assert.equal(sellPrice(content.items.potion), 150);
});

test("a potion heals without exceeding max HP", () => {
  const creature = createCreature(content, "snivy", 5);
  creature.hp = creature.maxHp - 5;
  const result = applyMedicine(content.items.potion, creature);
  assert.equal(result.ok, true);
  assert.equal(creature.hp, creature.maxHp);
  assert.ok(result.message?.includes("recovered"));
});

test("a potion is rejected at full HP", () => {
  const creature = createCreature(content, "snivy", 5);
  const result = applyMedicine(content.items.potion, creature);
  assert.equal(result.ok, false);
  assert.match(result.error ?? "", /full HP/);
});

test("full heal only cures status", () => {
  const creature = createCreature(content, "snivy", 5);
  creature.hp = 3;
  creature.status = "par";
  const result = applyMedicine(content.items.full_heal, creature);
  assert.equal(result.ok, true);
  assert.equal(creature.status, undefined);
  assert.equal(creature.hp, 3);
  assert.equal(applyMedicine(content.items.full_heal, creature).ok, false);
});

test("revive restores half HP and clears status", () => {
  const creature = createCreature(content, "snivy", 8);
  creature.hp = 0;
  creature.status = "psn";
  const result = applyMedicine(content.items.revive, creature);
  assert.equal(result.ok, true);
  assert.equal(creature.hp, Math.floor(creature.maxHp / 2));
  assert.equal(creature.status, undefined);
  assert.equal(applyMedicine(content.items.revive, creature).ok, false);
});

test("balls are not medicine", () => {
  const creature = createCreature(content, "snivy", 5);
  const result = applyMedicine(content.items.poke_ball, creature);
  assert.equal(result.ok, false);
});
