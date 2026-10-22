import test from "node:test";
import assert from "node:assert/strict";
import { loadContent } from "../src/content/loader.js";
import {
  catchChance,
  catchShakes,
  createBattle,
  effectiveness,
  resolveTurn,
  type BattleState
} from "../src/game/battle.js";
import {
  awardExperience,
  createCreature,
  xpToNext
} from "../src/game/creatures.js";
import type { Inventory } from "../src/game/types.js";

const content = loadContent();
const highRng = () => 0.9;

function makeParty(ids: string[], level = 5) {
  return ids.map((id) => createCreature(content, id, level));
}

function makeInventory(extra: Record<string, number> = {}): Inventory {
  return { items: { poke_ball: 10, ...extra } };
}

function makeBattle(
  partyIds: string[] = ["snivy"],
  wildId = "patrat",
  wildLevel = 3,
  inventory: Inventory = makeInventory()
): BattleState {
  return createBattle(
    `battle-${Math.random()}`,
    makeParty(partyIds),
    createCreature(content, wildId, wildLevel),
    "Tester",
    inventory,
    6,
    content.items
  );
}

test("player wins a normal wild encounter", () => {
  const battle = makeBattle(["snivy"], "patrat", 3);
  let turns = 0;
  while (battle.status === "active" && turns < 20) {
    resolveTurn(battle, { action: "move", moveIndex: 0 }, highRng);
    turns++;
  }
  assert.equal(battle.status, "won");
  assert.ok(battle.player.hp > 0);
  assert.ok(battle.log.some((line) => line.includes("You won the battle!")));
  assert.ok(battle.log.some((line) => line.includes("fainted")));
  assert.equal(battle.awaitingAction, false);
});

test("battle snapshots expose structured animation events", () => {
  const battle = makeBattle();
  assert.deepEqual(battle.events, []);
  const attackIndex = battle.player.moves.findIndex((move) => (move.power ?? 0) > 0);
  assert.ok(attackIndex >= 0);
  resolveTurn(battle, { action: "move", moveIndex: attackIndex }, highRng);
  const events = battle.events as Array<Record<string, any>>;
  const moves = events.filter((event) => event.type === "move");
  assert.ok(moves.length >= 1);
  const playerMove = moves.find(
    (event) => event.type === "move" && event.side === "player"
  );
  assert.ok(playerMove);
  assert.ok(playerMove.moveId > 0);
  assert.ok(playerMove.moveType.length > 0);
  assert.ok(["physical", "special", "status"].includes(playerMove.moveCategory));
  const damages = events.filter((event) => event.type === "damage");
  assert.ok(damages.length >= 1);
  for (const event of damages) {
    assert.ok(event.maxHp > 0);
    assert.ok(event.hp >= 0 && event.hp <= event.maxHp);
    assert.ok(event.amount > 0);
  }
});

test("run and catch outcomes are represented in the event stream", () => {
  const runBattle = makeBattle();
  resolveTurn(runBattle, { action: "run" }, () => 0.1);
  assert.deepEqual(runBattle.events[0], { type: "run", success: true });

  const failedRun = makeBattle();
  resolveTurn(failedRun, { action: "run" }, () => 0.99);
  assert.deepEqual(failedRun.events[0], { type: "run", success: false });
  assert.ok(failedRun.events.some((event) => event.type === "move"));

  const catchBattle = makeBattle();
  resolveTurn(catchBattle, { action: "catch" }, () => 0.0);
  assert.deepEqual(catchBattle.events[0], {
    type: "catch",
    itemId: "poke_ball",
    success: true,
    shakes: 3
  });
});

test("run can succeed and end the battle", () => {
  const battle = makeBattle();
  resolveTurn(battle, { action: "run" }, () => 0.1);
  assert.equal(battle.status, "fled");
  assert.ok(battle.log.some((line) => line.includes("Got away safely")));
});

test("a failed escape gives the wild creature a free hit", () => {
  const battle = makeBattle();
  const hpBefore = battle.player.hp;
  resolveTurn(battle, { action: "run" }, () => 0.99);
  assert.equal(battle.status, "active");
  assert.ok(battle.player.hp < hpBefore);
  assert.ok(battle.log.some((line) => line.includes("Couldn't escape")));
  assert.equal(battle.awaitingAction, true);
});

test("a very strong wild creature can defeat the player", () => {
  const battle = makeBattle(["snivy"], "patrat", 50);
  let turns = 0;
  while (battle.status === "active" && turns < 5) {
    resolveTurn(battle, { action: "move", moveIndex: 0 }, highRng);
    turns++;
  }
  assert.equal(battle.status, "lost");
  assert.equal(battle.player.hp, 0);
  assert.ok(battle.log.some((line) => line.includes("blacked out")));
});

test("invalid actions are rejected without consuming the turn", () => {
  const battle = makeBattle();
  assert.throws(
    () => resolveTurn(battle, { action: "move", moveIndex: 99 }, highRng),
    /Invalid move index/
  );
  assert.equal(battle.awaitingAction, true);
  assert.equal(battle.turn, 0);
  assert.throws(
    () => resolveTurn(battle, { action: "switch", partyIndex: 99 }, highRng),
    /Invalid party index/
  );
  assert.equal(battle.awaitingAction, true);
});

test("catch success consumes a ball and ends the battle", () => {
  const battle = makeBattle();
  resolveTurn(battle, { action: "catch" }, () => 0.0);
  assert.equal(battle.status, "caught");
  assert.equal(battle.inventory.items.poke_ball, 9);
  assert.ok(battle.log.some((line) => line.includes("was caught")));
});

test("catch uses the chosen ball type and its bonus", () => {
  const battle = makeBattle(["snivy"], "patrat", 3, makeInventory({ great_ball: 1 }));
  resolveTurn(battle, { action: "catch", itemId: "great_ball" }, () => 0.0);
  assert.equal(battle.status, "caught");
  assert.equal(battle.inventory.items.great_ball, undefined);
  assert.equal(battle.inventory.items.poke_ball, 10);
  assert.ok(battle.log.some((line) => line.includes("Great Ball")));
});

test("a failed catch gives the wild creature a free hit", () => {
  const battle = makeBattle();
  const hpBefore = battle.player.hp;
  resolveTurn(battle, { action: "catch" }, () => 0.999);
  assert.equal(battle.status, "active");
  assert.equal(battle.inventory.items.poke_ball, 9);
  assert.ok(battle.player.hp < hpBefore);
  assert.ok(battle.log.some((line) => line.includes("broke free")));
});

test("catch is rejected with no balls left", () => {
  const battle = makeBattle(["snivy"], "patrat", 3, { items: {} });
  assert.throws(
    () => resolveTurn(battle, { action: "catch" }, () => 0.0),
    /no Poké Ball left/
  );
  assert.equal(battle.awaitingAction, true);
  assert.equal(battle.turn, 0);
});

test("catch is rejected when the party is full", () => {
  const battle = makeBattle(
    ["snivy", "tepig", "oshawott", "pansage", "pansear", "panpour"],
    "patrat",
    3
  );
  assert.throws(() => resolveTurn(battle, { action: "catch" }, () => 0.0), /party is full/);
  assert.equal(battle.inventory.items.poke_ball, 10);
  assert.equal(battle.awaitingAction, true);
});

test("catch chance improves as the wild creature weakens", () => {
  const full = createCreature(content, "snivy", 3);
  const weak = createCreature(content, "snivy", 3);
  weak.hp = Math.max(1, Math.floor(weak.maxHp * 0.1));
  assert.ok(catchChance(weak) > catchChance(full));
  assert.ok(catchChance(full) > 0);
  assert.ok(catchChance(weak) <= 1);
});

test("a stronger ball improves the catch chance", () => {
  const weak = createCreature(content, "snivy", 3);
  weak.hp = 1;
  assert.ok(catchChance(weak, 2) > catchChance(weak, 1));
  assert.ok(catchChance(weak, 2) <= 1);
});

test("status conditions improve the catch chance", () => {
  const healthy = createCreature(content, "snivy", 3);
  healthy.hp = 1;
  const asleep = createCreature(content, "snivy", 3);
  asleep.hp = 1;
  asleep.status = "slp";
  const poisoned = createCreature(content, "snivy", 3);
  poisoned.hp = 1;
  poisoned.status = "psn";
  assert.ok(catchChance(asleep, 1) > catchChance(healthy, 1));
  assert.ok(catchChance(poisoned, 1) > catchChance(healthy, 1));
  assert.ok(catchChance(asleep, 1) > catchChance(poisoned, 1));
});

test("capture needs three shake checks", () => {
  const wild = createCreature(content, "snivy", 3);
  wild.hp = 1;
  const values = [0.0, 0.0, 0.0];
  assert.equal(catchShakes(wild, 1, () => values.shift() ?? 0.999), 3);
  const failLast = [0.0, 0.0, 0.999];
  assert.equal(catchShakes(wild, 1, () => failLast.shift() ?? 0.999), 2);
  assert.equal(catchShakes(wild, 1, () => 0.999), 0);
});

test("a potion heals the party and costs a turn", () => {
  const battle = makeBattle(["snivy"], "patrat", 3, makeInventory({ potion: 2 }));
  battle.party[0].hp = 3;
  battle.player.hp = 3;
  resolveTurn(battle, { action: "item", itemId: "potion", partyIndex: 0 }, highRng);
  assert.equal(battle.status, "active");
  assert.ok(battle.player.hp > 3);
  assert.ok(battle.player.hp <= battle.player.maxHp);
  assert.equal(battle.inventory.items.potion, 1);
  assert.equal(battle.turn, 1);
  assert.ok(battle.log.some((line) => line.includes("recovered")));
});

test("using a potion at full HP is rejected without consuming it", () => {
  const battle = makeBattle(["snivy"], "patrat", 3, makeInventory({ potion: 1 }));
  assert.throws(
    () => resolveTurn(battle, { action: "item", itemId: "potion", partyIndex: 0 }, highRng),
    /full HP/
  );
  assert.equal(battle.inventory.items.potion, 1);
  assert.equal(battle.awaitingAction, true);
  assert.equal(battle.turn, 0);
});

test("full heal clears a status condition", () => {
  const battle = makeBattle(["snivy"], "patrat", 3, makeInventory({ full_heal: 1 }));
  battle.party[0].status = "psn";
  resolveTurn(battle, { action: "item", itemId: "full_heal", partyIndex: 0 }, highRng);
  assert.equal(battle.party[0].status, undefined);
  assert.equal(battle.inventory.items.full_heal, undefined);
});

test("revive wakes a benched creature and it can be switched in", () => {
  const battle = makeBattle(
    ["snivy", "tepig"],
    "patrat",
    3,
    makeInventory({ revive: 1 })
  );
  battle.party[1].hp = 0;
  battle.party[1].status = "psn";
  resolveTurn(battle, { action: "item", itemId: "revive", partyIndex: 1 }, highRng);
  assert.equal(battle.inventory.items.revive, undefined);
  assert.ok(battle.party[1].hp > 0);
  assert.equal(battle.party[1].status, undefined);
  resolveTurn(battle, { action: "switch", partyIndex: 1 }, highRng);
  assert.equal(battle.activeIndex, 1);
  assert.equal(battle.player.name, "Tepig");
});

test("voluntary switching costs a turn and the wild attacks", () => {
  const battle = makeBattle(["snivy", "tepig"], "panpour", 3);
  const switchedIn = battle.party[1];
  resolveTurn(battle, { action: "switch", partyIndex: 1 }, highRng);
  assert.equal(battle.activeIndex, 1);
  assert.equal(battle.player, switchedIn);
  assert.ok(battle.player.hp < battle.player.maxHp);
  assert.equal(battle.awaitingAction, true);
  assert.ok(battle.log.some((line) => line.includes("Go, Tepig!")));
});

test("a fainted active creature forces a switch, and the replacement is safe", () => {
  const battle = makeBattle(["snivy", "tepig"], "patrat", 50);
  battle.player.hp = 1;
  resolveTurn(battle, { action: "move", moveIndex: 0 }, highRng);

  assert.equal(battle.status, "active");
  assert.equal(battle.mustSwitch, true);
  assert.equal(battle.awaitingAction, true);
  assert.throws(
    () => resolveTurn(battle, { action: "move", moveIndex: 0 }, highRng),
    /Choose a replacement/
  );

  const replacement = battle.party[1];
  const hpBefore = replacement.hp;
  resolveTurn(battle, { action: "switch", partyIndex: 1 }, highRng);
  assert.equal(battle.mustSwitch, false);
  assert.equal(battle.activeIndex, 1);
  assert.equal(battle.player.hp, hpBefore);
  assert.ok(battle.log.some((line) => line.includes("Go, Tepig!")));
});

test("losing every party member ends the battle", () => {
  const battle = makeBattle(["snivy", "tepig"], "patrat", 50);
  battle.party[0].hp = 1;
  battle.party[1].hp = 0;
  resolveTurn(battle, { action: "move", moveIndex: 0 }, highRng);
  assert.equal(battle.status, "lost");
  assert.equal(battle.mustSwitch, false);
});

test("type effectiveness handles dual types", () => {
  assert.equal(effectiveness("Electric", ["Water", "Flying"]), 4);
  assert.equal(effectiveness("Grass", ["Water", "Rock"]), 4);
  assert.equal(effectiveness("Fire", ["Water"]), 0.5);
  assert.equal(effectiveness("Normal", ["Rock"]), 0.5);
  assert.equal(effectiveness("Electric", ["Grass"]), 0.5);
});

test("experience levels a creature up and teaches new moves", () => {
  const creature = createCreature(content, "snivy", 6);
  const oldMaxHp = creature.maxHp;
  const log: string[] = [];
  const required = xpToNext(content, 6);
  const result = awardExperience(content, creature, required + 10, log);

  assert.equal(creature.level, 7);
  assert.equal(result.levelsGained, 1);
  assert.ok(creature.maxHp > oldMaxHp);
  assert.ok(creature.moves.some((move) => move.id === "vinewhip"));
  assert.ok(log.some((line) => line.includes("grew to Lv.7")));
});

test("small amounts of experience do not force a level", () => {
  const creature = createCreature(content, "snivy", 5);
  const log: string[] = [];
  const result = awardExperience(content, creature, 1, log);
  assert.equal(result.levelsGained, 0);
  assert.equal(creature.level, 5);
  assert.equal(creature.xp, 1);
});
