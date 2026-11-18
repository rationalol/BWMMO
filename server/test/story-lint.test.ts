import assert from "node:assert/strict";
import test from "node:test";
import { lintStory } from "../scripts/story-lint.ts";
import type { StoryContent, StorySceneDef, StoryStepDef } from "../src/content/types.js";

const MAPS = new Set(["m"]);

function content(partial: Partial<StoryContent>): StoryContent {
  return {
    version: 1,
    initialFlags: {},
    scenes: {},
    trainers: {},
    npcs: [],
    interactions: [],
    triggers: [],
    gates: [],
    onEnter: [],
    ...partial
  };
}

function scene(id: string, steps: StoryStepDef[]): StorySceneDef {
  return { id, steps };
}

function say(lines: string[], when?: Record<string, number>): StoryStepDef {
  return { type: "say", lines, when };
}

function enter(sceneId: string, when?: Record<string, number>): StoryContent["onEnter"] {
  return [{ id: `enter_${sceneId}`, mapId: "m", scene: sceneId, when }];
}

function codes(story: StoryContent): string[] {
  return lintStory(story, MAPS).findings.map((finding) => finding.code);
}

test("a playable story produces no findings", () => {
  const story = content({
    scenes: {
      start: scene("start", [
        say(["hello"]),
        { type: "setFlag", flag: "done", value: 1 },
        say(["goodbye"], { done: 1 })
      ])
    },
    onEnter: enter("start")
  });
  const result = lintStory(story, MAPS);
  assert.deepEqual(result.findings, []);
  // The starting state plus the state after the scene sets `done`.
  assert.equal(result.stats.states, 2);
});

test("a condition asking for a value nothing writes is an error", () => {
  const story = content({
    scenes: {
      start: scene("start", [
        { type: "setFlag", flag: "stage", value: 1 },
        say(["only at stage 2"], { stage: 2 })
      ])
    },
    onEnter: enter("start")
  });
  const found = codes(story);
  assert.ok(found.includes("unsatisfiable-condition"), found.join(","));
  assert.ok(found.includes("dead-step"), found.join(","));
});

test("a scene whose guard can never be satisfied is unreachable", () => {
  const story = content({
    scenes: { hidden: scene("hidden", [say(["never"])]) },
    onEnter: enter("hidden", { unlocked: 1 })
  });
  const found = codes(story);
  assert.ok(found.includes("unreachable-scene"), found.join(","));
});

test("a gate locked in every reachable state is reported", () => {
  const story = content({
    scenes: { start: scene("start", [say(["hi"])]) },
    onEnter: enter("start"),
    gates: [
      {
        id: "wall",
        mapId: "m",
        x: 0,
        y: 0,
        width: 1,
        height: 1,
        when: { never: 0 },
        lines: ["locked"]
      }
    ]
  });
  assert.ok(codes(story).includes("gate-never-opens"));
});

test("a gate that a scene unlocks is not reported", () => {
  const story = content({
    scenes: {
      start: scene("start", [
        say(["hi"]),
        { type: "setFlag", flag: "gateOpen", value: 1 }
      ])
    },
    onEnter: enter("start"),
    gates: [
      {
        id: "door",
        mapId: "m",
        x: 0,
        y: 0,
        width: 1,
        height: 1,
        when: { gateOpen: 0 },
        lines: ["locked"]
      }
    ]
  });
  const result = lintStory(story, MAPS);
  assert.deepEqual(
    result.findings.filter((finding) => finding.code.startsWith("gate-")),
    []
  );
  assert.equal(result.stats.states, 2);
});

test("both battle results are explored, so win and lose branches stay alive", () => {
  const story = content({
    scenes: {
      start: scene("start", [
        {
          type: "battle",
          trainer: "rival",
          resultFlag: "won",
          win: ["nice"],
          lose: ["ouch"]
        },
        say(["victory line"], { won: 1 }),
        say(["defeat line"], { won: 0 })
      ])
    },
    trainers: { rival: { name: "Rival", party: [{ species: "tepig", level: 5 }] } },
    onEnter: enter("start")
  });
  const result = lintStory(story, MAPS);
  assert.ok(!result.findings.some((finding) => finding.code === "dead-step"));
  assert.equal(result.stats.states, 2);
});

test("a battle without a fallback trainer is an error", () => {
  const story = content({
    scenes: {
      start: scene("start", [
        {
          type: "battle",
          variants: [{ when: { starter: 0 }, trainer: "a" }],
          resultFlag: "won"
        }
      ])
    },
    trainers: { a: { name: "A", party: [{ species: "tepig", level: 5 }] } },
    onEnter: enter("start")
  });
  assert.ok(codes(story).includes("battle-no-fallback"));
});

test("a starter option without a value is reported", () => {
  const story = content({
    scenes: {
      start: scene("start", [
        {
          type: "chooseStarter",
          flag: "starter",
          prompt: ["pick"],
          options: [
            { id: "tepig", species: "tepig", level: 5, value: 0 },
            { id: "oshawott", species: "oshawott", level: 5 }
          ]
        }
      ])
    },
    onEnter: enter("start")
  });
  assert.ok(codes(story).includes("starter-option-without-value"));
});

test("a flag that is written but never read is reported", () => {
  const story = content({
    initialFlags: { unused: 0 },
    scenes: {
      start: scene("start", [{ type: "setFlag", flag: "unused", value: 1 }])
    },
    onEnter: enter("start")
  });
  assert.ok(codes(story).includes("unused-write"));
});
