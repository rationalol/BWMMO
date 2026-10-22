import test from "node:test";
import assert from "node:assert/strict";
import type { NpcDef } from "../src/content/types.js";
import { renderDialogueLine, selectDialogue } from "../src/game/dialogue.js";

const npc: NpcDef = {
  id: "test_npc",
  name: "Tester",
  x: 0,
  y: 0,
  color: "#ffffff",
  kind: "npc",
  dialogue: ["Default line."],
  setFlags: [100],
  dialogueVariants: [
    {
      flags: { "2402": 1 },
      lines: ["Later line."],
      setFlags: [200]
    }
  ]
};

test("dialogue selects the default branch for a new character", () => {
  assert.deepEqual(selectDialogue(npc, undefined), {
    lines: ["Default line."],
    setFlags: [100]
  });
  assert.deepEqual(selectDialogue(npc, { "2402": 0 }), {
    lines: ["Default line."],
    setFlags: [100]
  });
});

test("dialogue selects a matching story-flag variant", () => {
  assert.deepEqual(selectDialogue(npc, { "2402": 1 }), {
    lines: ["Later line."],
    setFlags: [200]
  });
});

test("dialogue ignores non-matching variants and renders player placeholders", () => {
  assert.deepEqual(selectDialogue(npc, { "2402": 2 }), {
    lines: ["Default line."],
    setFlags: [100]
  });
  assert.equal(
    renderDialogueLine("Hello, {name}! {rival} and {nickname} wait.", "Ash"),
    "Hello, Ash! your friend and your partner wait."
  );
});
