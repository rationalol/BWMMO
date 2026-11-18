import test from "node:test";
import assert from "node:assert/strict";
import { loadContent } from "../src/content/loader.js";
import {
  createDuelBattle,
  duelViewFor,
  submitDuelTurn,
  type BattleState
} from "../src/game/battle.js";
import { createCreature } from "../src/game/creatures.js";

const content = loadContent();

function attackIndex(state: BattleState, side: "p1" | "p2" = "p1"): number {
  const party = side === "p1" ? state.party : state.opponentParty!;
  const active = side === "p1" ? state.player : state.opponent!;
  const index = active.moves.findIndex((move) => (move.power ?? 0) > 0);
  assert.ok(index >= 0, `${side} should know an attacking move`);
  return index;
}

function makeDuel(
  p1: string[] = ["snivy", "tepig"],
  p2: string[] = ["oshawott", "patrat"],
  p1Level = 5,
  p2Level = 5
): BattleState {
  return createDuelBattle(
    `duel-${Math.random()}`,
    p1.map((id) => createCreature(content, id, p1Level)),
    "Ash",
    p2.map((id) => createCreature(content, id, p2Level)),
    "Misty",
    6
  );
}

test("a duel starts with both parties and mirrored client views", () => {
  const state = makeDuel();
  assert.equal(state.mode, "duel");
  assert.equal(state.status, "active");
  assert.equal(state.awaitingAction, true);
  assert.equal(state.awaitingOpponent, true);
  assert.equal(state.playerName, "Ash");
  assert.equal(state.opponentName, "Misty");
  assert.equal(state.party.length, 2);
  assert.equal(state.opponentParty?.length, 2);
  assert.equal(state.player.species, "snivy");
  assert.equal(state.opponent?.species, "oshawott");
  assert.equal(state.wild.species, "oshawott");

  const b = duelViewFor(state, "p2");
  assert.equal(b.playerName, "Misty");
  assert.equal(b.opponentName, "Ash");
  assert.equal(b.player.species, "oshawott");
  assert.equal(b.wild.species, "snivy");
  assert.equal(b.party.length, 2);
  assert.equal("choices" in b, false);
  assert.equal("eventsOpponent" in b, false);
});

test("both players must choose before the turn resolves", () => {
  const state = makeDuel();
  const first = submitDuelTurn(state, "p1", {
    action: "move",
    moveIndex: attackIndex(state, "p1")
  });
  assert.equal(first.resolved, false);
  assert.equal(state.turn, 0);
  assert.equal(state.awaitingAction, false);
  assert.equal(state.awaitingOpponent, true);

  const second = submitDuelTurn(state, "p2", {
    action: "move",
    moveIndex: attackIndex(state, "p2")
  });
  assert.equal(second.resolved, true);
  assert.equal(state.turn, 1);
  assert.ok(state.events.length > 0);
  assert.equal(state.eventsOpponent?.length, state.events.length);
  assert.equal(state.awaitingAction, true);
  assert.equal(state.awaitingOpponent, true);
  const p1Damage = state.events.some(
    (event) => event.type === "damage" && event.side === "player"
  );
  const p2Damage = state.events.some(
    (event) => event.type === "damage" && event.side === "wild"
  );
  assert.ok(p1Damage || p2Damage, "the resolved turn should damage a battler");
});

test("duels reject running, balls and medicine", () => {
  const state = makeDuel();
  assert.throws(
    () => submitDuelTurn(state, "p1", { action: "run" }),
    /cannot run/i
  );
  assert.throws(
    () => submitDuelTurn(state, "p1", { action: "catch", itemId: "poke_ball" }),
    /Poké Balls/i
  );
  assert.throws(
    () => submitDuelTurn(state, "p1", {
      action: "item",
      itemId: "potion",
      partyIndex: 0
    }),
    /cannot use items/i
  );
  assert.equal(state.turn, 0);
  assert.equal(state.awaitingAction, true);
  assert.equal(state.choices?.player, null);
});

test("a fainted battler must switch and only that side is asked", () => {
  const state = makeDuel(["snivy", "tepig"], ["tepig"], 50, 60);
  state.party[0].hp = 1;
  submitDuelTurn(state, "p1", {
    action: "move",
    moveIndex: attackIndex(state, "p1")
  });
  submitDuelTurn(state, "p2", {
    action: "move",
    moveIndex: attackIndex(state, "p2")
  });
  assert.equal(state.status, "active");
  assert.equal(state.mustSwitch, true);
  assert.equal(state.awaitingAction, true);
  assert.equal(state.awaitingOpponent, false);
  const before = state.player.species;
  const result = submitDuelTurn(state, "p1", { action: "switch", partyIndex: 1 });
  assert.equal(result.resolved, true);
  assert.notEqual(state.player.species, before);
  assert.equal(state.awaitingAction, true);
  assert.equal(state.awaitingOpponent, true);
});

test("the opponent can also be the side that must switch", () => {
  const state = makeDuel(["tepig"], ["snivy", "oshawott"], 60, 50);
  state.opponentParty![0].hp = 1;
  submitDuelTurn(state, "p1", {
    action: "move",
    moveIndex: attackIndex(state, "p1")
  });
  submitDuelTurn(state, "p2", {
    action: "move",
    moveIndex: attackIndex(state, "p2")
  });
  assert.equal(state.status, "active");
  assert.equal(state.mustSwitchOpponent, true);
  assert.equal(state.awaitingOpponent, true);
  assert.equal(state.awaitingAction, false);
  const before = state.opponent?.species;
  const result = submitDuelTurn(state, "p2", { action: "switch", partyIndex: 1 });
  assert.equal(result.resolved, true);
  assert.notEqual(state.opponent?.species, before);
  assert.equal(state.awaitingAction, true);
  assert.equal(state.awaitingOpponent, true);
});

test("a duel ends when one party has no healthy creature", () => {
  const state = makeDuel(["snivy"], ["tepig"], 5, 60);
  let guard = 0;
  while (state.status === "active" && guard++ < 10) {
    const move1 = attackIndex(state, "p1");
    const move2 = attackIndex(state, "p2");
    if (state.awaitingAction) {
      submitDuelTurn(state, "p1", { action: "move", moveIndex: move1 });
    }
    if (state.awaitingOpponent) {
      submitDuelTurn(state, "p2", { action: "move", moveIndex: move2 });
    }
  }
  assert.notEqual(state.status, "active");
  assert.equal(state.status, "lost");
  assert.equal(state.awaitingAction, false);
  assert.equal(state.awaitingOpponent, false);
  assert.equal(duelViewFor(state, "p2").status, "won");
});
