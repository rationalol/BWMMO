import test from "node:test";
import assert from "node:assert/strict";
import { loadContent, validateContent } from "../src/content/loader.js";

const content = loadContent();

test("content has the expected shape", () => {
  assert.equal(Object.keys(content.maps).length, 378);
  assert.equal(Object.keys(content.species).length, 649);
  assert.equal(Object.keys(content.moves).length, 559);
  assert.deepEqual(content.starters, ["snivy", "tepig", "oshawott"]);
  assert.equal(content.config.maxParty, 6);
  assert.equal(content.config.maxBox, 30);
  assert.equal(content.config.startingBalls, 10);
  assert.equal(content.config.startingMap, "unova_full");
  assert.equal(content.config.startingItems?.potion, 3);
});

test("items and shops cover the catch/heal loop", () => {
  assert.deepEqual(Object.keys(content.items).sort(), [
    "full_heal",
    "great_ball",
    "hyper_potion",
    "poke_ball",
    "potion",
    "revive",
    "super_potion",
    "ultra_ball"
  ]);
  assert.equal(content.items.poke_ball.category, "ball");
  assert.equal(content.items.poke_ball.ballBonus, 1);
  assert.equal(content.items.great_ball.ballBonus, 1.5);
  assert.equal(content.items.potion.heal, 20);
  assert.equal(content.items.full_heal.cureStatus, true);
  assert.equal(content.items.revive.revive, true);

  const mart = content.shops.nuvema_mart;
  assert.ok(mart, "Nuvema Mart should exist");
  assert.ok(mart.items.includes("poke_ball"));
  assert.ok(mart.items.includes("potion"));
  const clerk = content.maps.unova_full.npcs.find((npc) => npc.id === "mart_clerk");
  assert.equal(clerk?.kind, "shop");
  assert.equal(clerk?.shopId, "nuvema_mart");
  assert.equal(
    content.maps.unova_full.npcs.find((npc) => npc.id === "pc_terminal")?.kind,
    "pc"
  );
  assert.equal(
    content.maps.unova_full.npcs.find((npc) => npc.id === "nurse_joy")?.kind,
    "healer"
  );
});

test("content validation reports broken references", () => {
  const broken = structuredClone(content);
  broken.species.snivy.learnset.push({ level: 2, move: "missing_move" });
  broken.species.snivy.evolutions[0].to = "missing_species";
  broken.maps.town.spawn.x = -1;
  broken.shops.nuvema_mart.items.push("missing_item");
  const shopNpc = broken.maps.unova_full.npcs.find((npc) => npc.id === "mart_clerk");
  if (shopNpc) delete shopNpc.shopId;
  const errors = validateContent(broken);
  assert.ok(errors.some((error) => error.includes("unknown move 'missing_move'")));
  assert.ok(errors.some((error) => error.includes("spawn")));
  assert.ok(errors.some((error) => error.includes("unknown item 'missing_item'")));
  assert.ok(errors.some((error) => error.includes("needs a valid shopId")));
  assert.ok(
    errors.some((error) => error.includes("evolution target 'missing_species'"))
  );
});

test("full Gen 5 roster and move data are imported", () => {
  assert.equal(content.species.bulbasaur.dex, 1);
  assert.equal(content.species.genesect.dex, 649);
  assert.deepEqual(content.species.genesect.types, ["Bug", "Steel"]);
  assert.equal(content.moves.vinewhip.power, 35);
  assert.equal(content.moves.vinewhip.pp, 15);
  assert.equal(content.moves.quickattack.priority, 1);
  assert.equal(content.moves.swift.accuracy, 0);
});

test("the evolution graph points at content species", () => {
  assert.deepEqual(content.species.snivy.evolutions, [
    { to: "servine", method: "level", level: 17 }
  ]);
  assert.deepEqual(content.species.servine.evolutions, [
    { to: "serperior", method: "level", level: 36 }
  ]);
  let count = 0;
  for (const species of Object.values(content.species)) {
    for (const evolution of species.evolutions) {
      count += 1;
      assert.ok(content.species[evolution.to]);
      if (evolution.method === "level") assert.ok(evolution.level! >= 1);
      if (evolution.move) assert.ok(content.moves[evolution.move]);
    }
  }
  assert.ok(count >= 300);
});

test("every starter and encounter species exists", () => {
  for (const starter of content.starters) {
    assert.ok(content.species[starter], `missing starter ${starter}`);
  }
  for (const map of Object.values(content.maps)) {
    for (const entry of map.encounter?.table ?? []) {
      assert.ok(content.species[entry.species], `${map.id}: missing ${entry.species}`);
    }
    for (const zone of map.encounterZones ?? []) {
      for (const entry of zone.table) {
        assert.ok(content.species[entry.species], `${map.id}/${zone.id}: missing ${entry.species}`);
      }
    }
  }
});

test("species use ROM base stats, types, catch rates and learnsets", () => {
  const snivy = content.species.snivy;
  assert.deepEqual(snivy.types, ["Grass"]);
  assert.deepEqual(
    [snivy.baseHp, snivy.baseAtk, snivy.baseDef, snivy.baseSpAtk, snivy.baseSpDef, snivy.baseSpeed],
    [45, 45, 55, 45, 55, 63]
  );
  assert.equal(snivy.catchRate, 0.176);
  assert.deepEqual(snivy.learnset, [
    { level: 1, move: "tackle" },
    { level: 4, move: "leer" },
    { level: 7, move: "vinewhip" },
    { level: 10, move: "wrap" },
    { level: 13, move: "growth" },
    { level: 16, move: "leaftornado" },
    { level: 19, move: "leechseed" },
    { level: 22, move: "megadrain" },
    { level: 25, move: "slam" },
    { level: 28, move: "leafblade" },
    { level: 31, move: "coil" },
    { level: 34, move: "gigadrain" },
    { level: 37, move: "wringout" },
    { level: 40, move: "gastroacid" },
    { level: 43, move: "leafstorm" }
  ]);

  const pidove = content.species.pidove;
  assert.deepEqual(pidove.types, ["Normal", "Flying"]);
  assert.deepEqual(pidove.learnset.slice(0, 3), [
    { level: 1, move: "gust" },
    { level: 4, move: "growl" },
    { level: 8, move: "leer" }
  ]);

  for (const species of Object.values(content.species)) {
    assert.ok(species.baseHp > 0 && species.baseSpAtk > 0 && species.baseSpDef > 0);
    assert.ok(species.catchRate > 0 && species.catchRate <= 1);
    assert.ok(species.learnset.length > 0);
  }
});

test("content validation reports broken references", () => {
  const broken = structuredClone(content);
  broken.species.snivy.learnset.push({ level: 2, move: "missing_move" });
  broken.maps.town.spawn.x = -1;
  const errors = validateContent(broken);
  assert.ok(errors.some((error) => error.includes("unknown move 'missing_move'")));
  assert.ok(errors.some((error) => error.includes("spawn")));
});
