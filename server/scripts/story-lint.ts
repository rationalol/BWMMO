#!/usr/bin/env node
/**
 * story:lint — static analysis for the story layer.
 *
 * `validate-content` checks that references resolve. This script asks a
 * different question: can the story actually be played to the end? It walks
 * the flag state space, branching on every possible battle result and starter
 * choice, and reports:
 *
 *   - conditions that can never become true (a flag written with values that
 *     no `when` ever asks for, or never written at all);
 *   - scenes that no entry point can trigger;
 *   - steps that are dead in every reachable state (a branch nothing can take);
 *   - gates that never open (a permanent wall) or never close;
 *   - flags that are written but never read, or read but never written;
 *   - battles with no fallback trainer.
 *
 * Geography is deliberately not modelled: the lint assumes the player can walk
 * to any reachable map. That makes `gate-never-opens` the only geometric claim
 * it makes, and it is still exact: a gate whose condition holds in every
 * reachable state is a wall no matter how the map is laid out.
 *
 * Usage:
 *   npm run story:lint
 *   npm run story:lint -- --content content --max-states 50000
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type {
  StoryCondition,
  StoryContent,
  StorySceneDef,
  StoryStepDef
} from "../src/content/types.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_CONTENT = path.resolve(HERE, "..", "content");

type Flags = Record<string, number>;

interface Location {
  where: string;
}

interface Pack {
  name: string;
  story: Partial<StoryContent>;
}

interface EntryPoint {
  scene: string;
  when?: StoryCondition;
  onceFlag?: string;
  label: string;
}

interface Finding {
  level: "error" | "warning";
  code: string;
  message: string;
}

const findings: Finding[] = [];
const report = (level: Finding["level"], code: string, message: string): void => {
  findings.push({ level, code, message });
};

function readJson(file: string): unknown {
  return JSON.parse(fs.readFileSync(file, "utf8")) as unknown;
}

function parseArgs(argv: string[]): { content: string; maxStates: number } {
  let content = DEFAULT_CONTENT;
  let maxStates = 50_000;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--content" && argv[index + 1]) {
      content = path.resolve(argv[index + 1]);
      index += 1;
    } else if (arg === "--max-states" && argv[index + 1]) {
      maxStates = Number.parseInt(argv[index + 1], 10);
      index += 1;
    }
  }
  return { content, maxStates };
}

/** Read every story pack in the same order (and with the same merge rules) as the loader. */
function loadPacks(contentDir: string): Pack[] {
  const storyDir = path.join(contentDir, "story");
  if (!fs.existsSync(storyDir)) return [];
  return fs
    .readdirSync(storyDir)
    .filter((file) => file.endsWith(".json"))
    .sort()
    .map((file) => ({
      name: file,
      story: readJson(path.join(storyDir, file)) as Partial<StoryContent>
    }));
}

/** Map ids, read from the head of each map file so 42 MB of tiles stay on disk. */
function loadMapIds(contentDir: string): Set<string> {
  const ids = new Set<string>();
  const mapsDir = path.join(contentDir, "maps");
  if (!fs.existsSync(mapsDir)) return ids;
  for (const file of fs.readdirSync(mapsDir)) {
    if (!file.endsWith(".json")) continue;
    const fd = fs.openSync(path.join(mapsDir, file), "r");
    const buffer = Buffer.alloc(256);
    const read = fs.readSync(fd, buffer, 0, buffer.length, 0);
    fs.closeSync(fd);
    const match = /^\s*\{\s*"id"\s*:\s*"([^"]+)"/.exec(buffer.toString("utf8", 0, read));
    if (match) ids.add(match[1]);
  }
  return ids;
}

/** A missing flag reads as 0, exactly like StoryController.matches. */
function matches(condition: StoryCondition | undefined, flags: Flags): boolean {
  if (!condition) return true;
  return Object.entries(condition).every(([flag, value]) => (flags[flag] ?? 0) === value);
}

function keyOf(flags: Flags): string {
  const keys = Object.keys(flags)
    .filter((flag) => (flags[flag] ?? 0) !== 0)
    .sort();
  return keys.length === 0 ? "-" : keys.map((flag) => `${flag}=${flags[flag]}`).join(",");
}

function withFlag(flags: Flags, flag: string, value: number): Flags {
  const next: Flags = { ...flags };
  if (value === 0) delete next[flag];
  else next[flag] = value;
  return next;
}

function dedupe(states: Flags[]): Flags[] {
  const seen = new Map<string, Flags>();
  for (const state of states) {
    const key = keyOf(state);
    if (!seen.has(key)) seen.set(key, state);
  }
  return [...seen.values()];
}

/** Every flag write the story can perform, with the values it can write. */
interface WriteTable {
  values: Map<string, Map<number, string[]>>;
  locations: Map<string, string[]>;
}

function recordWrite(table: WriteTable, flag: string, value: number, where: string): void {
  const perValue = table.values.get(flag) ?? new Map<number, string[]>();
  const sites = perValue.get(value) ?? [];
  sites.push(where);
  perValue.set(value, sites);
  table.values.set(flag, perValue);
  const all = table.locations.get(flag) ?? [];
  all.push(where);
  table.locations.set(flag, all);
}

/** Every (flag, value) a `when`/onceFlag condition reads. */
function recordCondition(
  reads: Map<string, Map<number, string[]>>,
  condition: StoryCondition | undefined,
  where: string
): void {
  for (const [flag, value] of Object.entries(condition ?? {})) {
    const perValue = reads.get(flag) ?? new Map<number, string[]>();
    const sites = perValue.get(value) ?? [];
    sites.push(where);
    perValue.set(value, sites);
    reads.set(flag, perValue);
  }
}

function mergeStories(packs: Pack[]): StoryContent {
  const merged: StoryContent = {
    version: 1,
    startMap: undefined,
    initialFlags: {},
    scenes: {},
    trainers: {},
    npcs: [],
    interactions: [],
    triggers: [],
    gates: [],
    onEnter: []
  };
  for (const pack of packs) {
    const story = pack.story;
    if (story.startMap !== undefined) merged.startMap = story.startMap;
    Object.assign(merged.initialFlags ?? {}, story.initialFlags ?? {});
    Object.assign(merged.scenes, story.scenes ?? {});
    Object.assign(merged.trainers ?? {}, story.trainers ?? {});
    merged.npcs.push(...(story.npcs ?? []));
    merged.interactions.push(...(story.interactions ?? []));
    merged.triggers.push(...(story.triggers ?? []));
    merged.gates.push(...(story.gates ?? []));
    merged.onEnter.push(...(story.onEnter ?? []));
  }
  return merged;
}

function collectEntries(story: StoryContent): EntryPoint[] {
  const entries: EntryPoint[] = [];
  for (const npc of story.npcs) {
    if (!npc.scene) continue;
    entries.push({
      scene: npc.scene,
      when: npc.sceneWhen,
      label: `story npc '${npc.id}' (${npc.mapId})`
    });
  }
  for (const interaction of story.interactions) {
    entries.push({
      scene: interaction.scene,
      when: interaction.when,
      label: `interaction '${interaction.mapId}/${interaction.npcId}'`
    });
  }
  for (const trigger of story.triggers) {
    entries.push({
      scene: trigger.scene,
      when: trigger.when,
      onceFlag: trigger.onceFlag,
      label: `trigger '${trigger.id}' (${trigger.mapId})`
    });
  }
  for (const enter of story.onEnter) {
    entries.push({
      scene: enter.scene,
      when: enter.when,
      onceFlag: enter.onceFlag,
      label: `onEnter '${enter.id}' (${enter.mapId})`
    });
  }
  return entries;
}

/** Every state the player can be in after `step` runs, branching where the game does. */
function applyStep(step: StoryStepDef, state: Flags): Flags[] {
  switch (step.type) {
    case "setFlag":
      return step.flag ? [withFlag(state, step.flag, step.value ?? 1)] : [state];
    case "battle": {
      if (!step.resultFlag) return [state];
      // The player can win or lose; the scene continues either way (story.ts
      // still heals and moves on after a loss).
      return [withFlag(state, step.resultFlag, 1), withFlag(state, step.resultFlag, 0)];
    }
    case "chooseStarter": {
      if (!step.flag) return [state];
      const values = new Set<number>();
      for (const option of step.options ?? []) {
        if (option.value !== undefined) values.add(option.value);
      }
      // Options without a value leave the flag untouched, like story.ts.
      const outputs = [...values].map((value) => withFlag(state, step.flag!, value));
      if (outputs.length === 0) outputs.push(state);
      return outputs;
    }
    default:
      return [state];
  }
}

interface SceneRun {
  ends: Flags[];
  active: Set<number>;
}

function runScene(scene: StorySceneDef, entry: Flags, maxStates: number): SceneRun {
  let states: Flags[] = [entry];
  const active = new Set<number>();
  for (let index = 0; index < scene.steps.length; index += 1) {
    const step = scene.steps[index];
    const next: Flags[] = [];
    for (const state of states) {
      if (!matches(step.when, state)) {
        next.push(state);
        continue;
      }
      active.add(index);
      for (const produced of applyStep(step, state)) next.push(produced);
    }
    states = dedupe(next);
    if (states.length > maxStates) {
      report(
        "warning",
        "scene-state-explosion",
        `scene '${scene.id}' exceeded ${maxStates} states at step ${index}; later steps are under-approximated`
      );
      break;
    }
  }
  return { ends: states, active };
}

export interface LintStats {
  scenes: number;
  steps: number;
  flagsWritten: number;
  flagsRead: number;
  states: number;
  entryPoints: number;
  maps: number;
}

export interface LintResult {
  findings: Finding[];
  stats: LintStats;
}

/** Lint an already merged story layer. Exported so tests can feed fixtures. */
export function lintStory(
  story: StoryContent,
  mapIds: Set<string>,
  maxStates = 50_000
): LintResult {
  findings.length = 0;

  const writes: WriteTable = { values: new Map(), locations: new Map() };
  const reads = new Map<string, Map<number, string[]>>();

  // Declared initial values count as something the player can observe, but
  // they are not "writes" — a flag that is only declared and never written is
  // worth flagging when something reads it.
  for (const [flag, value] of Object.entries(story.initialFlags ?? {})) {
    recordWrite(writes, flag, value, "initialFlags");
  }

  // --- collect writes and reads -------------------------------------------
  for (const [sceneId, scene] of Object.entries(story.scenes)) {
    scene.steps.forEach((step, index) => {
      const where = `scene '${sceneId}' step ${index}`;
      recordCondition(reads, step.when, where);
      if (step.type === "setFlag" && step.flag) {
        recordWrite(writes, step.flag, step.value ?? 1, where);
      }
      if (step.type === "battle") {
        if (step.resultFlag) {
          recordWrite(writes, step.resultFlag, 1, where);
          recordWrite(writes, step.resultFlag, 0, where);
        }
        for (const variant of step.variants ?? []) {
          recordCondition(reads, variant.when, `${where} variant`);
        }
      }
      if (step.type === "chooseStarter" && step.flag) {
        for (const option of step.options ?? []) {
          if (option.value !== undefined) {
            recordWrite(writes, step.flag, option.value, `${where} option '${option.id}'`);
          }
        }
      }
      if (step.type === "warp" && step.mapId && !mapIds.has(step.mapId)) {
        report("error", "missing-map", `${where}: warp target '${step.mapId}' does not exist`);
      }
      if (step.type === "battle") {
        const hasFallback = Boolean(step.trainer) || (step.variants ?? []).some((v) => !v.when);
        if (!hasFallback) {
          report("error", "battle-no-fallback", `${where}: battle has no trainer and no unconditional variant`);
        }
      }
      if (step.type === "say" && (step.lines ?? []).length === 0) {
        report("warning", "empty-say", `${where}: say step has no lines`);
      }
      if (step.type === "battle") {
        const variants = step.variants ?? [];
        variants.forEach((variant) => {
          if (variant.trainer && !(story.trainers ?? {})[variant.trainer]) {
            report("error", "missing-trainer", `${where}: unknown trainer '${variant.trainer}'`);
          }
        });
        if (step.trainer && !(story.trainers ?? {})[step.trainer]) {
          report("error", "missing-trainer", `${where}: unknown trainer '${step.trainer}'`);
        }
      }
    });
  }

  for (const npc of story.npcs) {
    recordCondition(reads, npc.sceneWhen, `story npc '${npc.id}' sceneWhen`);
    recordCondition(reads, npc.visibleWhen as StoryCondition | undefined, `story npc '${npc.id}' visibleWhen`);
    if (!mapIds.has(npc.mapId)) {
      report("error", "missing-map", `story npc '${npc.id}': map '${npc.mapId}' does not exist`);
    }
  }
  for (const interaction of story.interactions) {
    recordCondition(reads, interaction.when, `interaction '${interaction.mapId}/${interaction.npcId}'`);
    if (!story.scenes[interaction.scene]) {
      report("error", "missing-scene", `interaction '${interaction.mapId}/${interaction.npcId}': unknown scene '${interaction.scene}'`);
    }
    if (!mapIds.has(interaction.mapId)) {
      report("error", "missing-map", `interaction '${interaction.mapId}/${interaction.npcId}': map does not exist`);
    }
  }
  for (const trigger of story.triggers) {
    recordCondition(reads, trigger.when, `trigger '${trigger.id}'`);
    recordCondition(reads, trigger.onceFlag ? { [trigger.onceFlag]: 1 } : undefined, `trigger '${trigger.id}' onceFlag`);
    if (!story.scenes[trigger.scene]) {
      report("error", "missing-scene", `trigger '${trigger.id}': unknown scene '${trigger.scene}'`);
    }
    if (trigger.onceFlag) recordWrite(writes, trigger.onceFlag, 1, `trigger '${trigger.id}' onceFlag`);
  }
  for (const enter of story.onEnter) {
    recordCondition(reads, enter.when, `onEnter '${enter.id}'`);
    recordCondition(reads, enter.onceFlag ? { [enter.onceFlag]: 1 } : undefined, `onEnter '${enter.id}' onceFlag`);
    if (!story.scenes[enter.scene]) {
      report("error", "missing-scene", `onEnter '${enter.id}': unknown scene '${enter.scene}'`);
    }
    if (enter.onceFlag) recordWrite(writes, enter.onceFlag, 1, `onEnter '${enter.id}' onceFlag`);
  }
  for (const gate of story.gates) {
    recordCondition(reads, gate.when, `gate '${gate.id}'`);
  }

  // --- condition satisfiability ------------------------------------------
  for (const [flag, perValue] of reads) {
    for (const [value, sites] of perValue) {
      const writable = writes.values.get(flag)?.has(value) ?? false;
      if (value !== 0 && !writable) {
        const seen = writes.values.get(flag);
        const list = seen ? [...seen.keys()].sort().join("/") : "never written";
        report(
          "error",
          "unsatisfiable-condition",
          `${sites[0]} requires ${flag}=${value}, but ${flag} only ever takes ${list}`
        );
      }
      if (value === 0 && !writes.values.has(flag)) {
        report(
          "warning",
          "read-unwritten-flag",
          `${sites[0]} checks ${flag}=0, but nothing ever writes ${flag} (the check is always true)`
        );
      }
    }
  }

  // --- state space --------------------------------------------------------
  const start: Flags = { ...(story.initialFlags ?? {}) };
  const seen = new Map<string, Flags>([[keyOf(start), start]]);
  const queue: Flags[] = [start];
  const entries = collectEntries(story);
  for (const entry of entries) {
    if (!story.scenes[entry.scene]) {
      report("error", "missing-scene", `${entry.label}: unknown scene '${entry.scene}'`);
    }
  }

  const entryStates = new Map<string, Set<string>>();
  const activeSteps = new Map<string, Set<number>>();
  const processed = new Set<string>();
  let cursor = 0;
  let capped = false;

  while (cursor < queue.length) {
    const state = queue[cursor];
    cursor += 1;
    for (const entry of entries) {
      const scene = story.scenes[entry.scene];
      if (!scene) continue;
      if (!matches(entry.when, state)) continue;
      if (entry.onceFlag && (state[entry.onceFlag] ?? 0) === 1) continue;
      const base = entry.onceFlag ? withFlag(state, entry.onceFlag, 1) : state;
      const marker = `${entry.scene}|${keyOf(base)}`;
      if (processed.has(marker)) continue;
      processed.add(marker);

      const statesForScene = entryStates.get(entry.scene) ?? new Set<string>();
      statesForScene.add(keyOf(base));
      entryStates.set(entry.scene, statesForScene);

      const run = runScene(scene, base, maxStates);
      const active = activeSteps.get(entry.scene) ?? new Set<number>();
      for (const index of run.active) active.add(index);
      activeSteps.set(entry.scene, active);

      for (const end of run.ends) {
        const key = keyOf(end);
        if (seen.has(key)) continue;
        if (seen.size >= maxStates) {
          capped = true;
          break;
        }
        seen.set(key, end);
        queue.push(end);
      }
      if (capped) break;
    }
    if (capped) break;
  }
  if (capped) {
    report(
      "warning",
      "state-cap",
      `stopped after ${maxStates} states; reachability below is a lower bound`
    );
  }

  // --- scene reachability -------------------------------------------------
  const allEntries = new Set(entries.map((entry) => entry.scene));
  for (const sceneId of Object.keys(story.scenes)) {
    if (!allEntries.has(sceneId)) {
      report("error", "no-entry", `scene '${sceneId}' is not referenced by any NPC, interaction, trigger or onEnter`);
    } else if (!entryStates.has(sceneId)) {
      report("error", "unreachable-scene", `scene '${sceneId}' has entry points but none is reachable from initialFlags`);
    }
  }
  for (const [sceneId, scene] of Object.entries(story.scenes)) {
    const active = activeSteps.get(sceneId);
    if (!active) continue;
    scene.steps.forEach((step, index) => {
      if (active.has(index)) return;
      report(
        "warning",
        "dead-step",
        `scene '${sceneId}' step ${index} (${step.type}) is skipped in every reachable state`
      );
    });
    if (scene.steps.length > 0 && !active.has(scene.steps.length - 1)) {
      report(
        "warning",
        "dead-ending",
        `scene '${sceneId}' never reaches its last step in any reachable state`
      );
    }
  }

  // --- gates --------------------------------------------------------------
  const stateList = [...seen.values()];
  for (const gate of story.gates) {
    const closed = stateList.filter((state) => matches(gate.when, state)).length;
    const open = stateList.length - closed;
    if (open === 0) {
      report(
        "error",
        "gate-never-opens",
        `gate '${gate.id}' (${gate.mapId}) is locked in all ${stateList.length} reachable states: a permanent wall`
      );
    } else if (closed === 0) {
      report(
        "warning",
        "gate-never-locks",
        `gate '${gate.id}' (${gate.mapId}) is open in every reachable state`
      );
    }
  }

  // --- unused writes ------------------------------------------------------
  for (const flag of [...writes.locations.keys()].sort()) {
    if (reads.has(flag)) continue;
    const sites = writes.locations.get(flag)!.length;
    report(
      "warning",
      "unused-write",
      `${flag} is written in ${sites} place${sites === 1 ? "" : "s"} but never read by a condition`
    );
  }

  // --- starter choices ----------------------------------------------------
  for (const [sceneId, scene] of Object.entries(story.scenes)) {
    scene.steps.forEach((step, index) => {
      if (step.type !== "chooseStarter" || !step.flag) return;
      const missing = (step.options ?? []).filter((option) => option.value === undefined);
      if (missing.length > 0) {
        report(
          "warning",
          "starter-option-without-value",
          `scene '${sceneId}' step ${index}: option '${missing[0].id}' has no value, so '${step.flag}' is not written for it`
        );
      }
    });
  }

  return {
    findings: [...findings],
    stats: {
      scenes: Object.keys(story.scenes).length,
      steps: Object.values(story.scenes).reduce((sum, scene) => sum + scene.steps.length, 0),
      flagsWritten: writes.locations.size,
      flagsRead: reads.size,
      states: seen.size,
      entryPoints: entries.length,
      maps: mapIds.size
    }
  };
}

function main(): number {
  const { content: contentDir, maxStates } = parseArgs(process.argv.slice(2));
  const packs = loadPacks(contentDir);
  if (packs.length === 0) {
    console.error(`No story packs under ${path.join(contentDir, "story")}`);
    return 2;
  }
  const story = mergeStories(packs);
  const mapIds = loadMapIds(contentDir);
  const { findings: results, stats } = lintStory(story, mapIds, maxStates);

  const errors = results.filter((finding) => finding.level === "error");
  const warnings = results.filter((finding) => finding.level === "warning");

  console.log(`story:lint — ${packs.map((pack) => pack.name).join(", ")}`);
  console.log(
    `  ${stats.scenes} scenes, ${stats.steps} steps, ` +
      `${stats.flagsWritten} flags written, ${stats.flagsRead} read`
  );
  console.log(
    `  ${stats.states} reachable flag states, ${stats.entryPoints} entry points, ` +
      `${stats.maps} maps in content`
  );

  const order = { error: 0, warning: 1 } as const;
  const sorted = [...results].sort(
    (a, b) => order[a.level] - order[b.level] || a.code.localeCompare(b.code)
  );
  for (const finding of sorted) {
    console.log(
      `  ${finding.level === "error" ? "ERROR" : "WARN "} [${finding.code}] ${finding.message}`
    );
  }

  if (errors.length === 0) {
    console.log(`story lint passed (${warnings.length} warning${warnings.length === 1 ? "" : "s"})`);
    return 0;
  }
  console.log(
    `story lint failed: ${errors.length} error${errors.length === 1 ? "" : "s"}, ` +
      `${warnings.length} warning${warnings.length === 1 ? "" : "s"}`
  );
  return 1;
}

// Only run when invoked as a CLI; tests import lintStory directly.
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main();
}
