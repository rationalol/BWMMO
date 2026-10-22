/**
 * Build the full Gen 5 game.json from ROM-derived species/move data.
 *
 * Inputs:
 *   content/rom/species_all.json  (extract_all_species.py)
 *   content/rom/moves.json        (extract_moves.py)
 *   content/game.json             (config/starters/version are preserved)
 *
 * Showdown's Gen 5 dex is used only to map national dex numbers and move names
 * to stable ids. ROM values remain the source for stats, types, power, accuracy,
 * PP, priority and level-up learnsets.
 */
import fs from "node:fs";
import path from "node:path";
import { Dex } from "@pkmn/sim";

interface RomMove {
  id: number;
  name: string;
  type: string;
  category: "status" | "physical" | "special";
  power: number;
  accuracy: number;
  pp: number;
  priority: number;
}

interface RomSpecies {
  dex: number;
  name: string;
  types: string[];
  baseStats: {
    hp: number;
    atk: number;
    def: number;
    spAtk: number;
    spDef: number;
    speed: number;
  };
  catchRate255: number;
  learnset: Array<{ moveId: number; level: number }>;
}

interface GameEvolution {
  to: string;
  method: string;
  level?: number;
  item?: string;
  move?: string;
  condition?: string;
  gender?: "male" | "female";
}

function slug(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]/g, "");
}

const contentDir = path.resolve("content");
const gamePath = path.join(contentDir, "game.json");
const romMoves = JSON.parse(
  fs.readFileSync(path.join(contentDir, "rom", "moves.json"), "utf8")
).moves as Record<string, RomMove>;
const romSpecies = JSON.parse(
  fs.readFileSync(path.join(contentDir, "rom", "species_all.json"), "utf8")
).species as Record<string, RomSpecies>;
const previous = JSON.parse(fs.readFileSync(gamePath, "utf8")) as Record<string, unknown>;

const gen5 = Dex.forGen(5);
const showdownSpecies = gen5.species
  .all()
  .filter((species: any) => species.name === species.baseSpecies);

const moves: Record<string, unknown> = {};
const moveByRomId = new Map<number, { id: string; name: string }>();
for (const romMove of Object.values(romMoves)) {
  const showdownMove = gen5.moves.get(romMove.name);
  if (!showdownMove) {
    throw new Error(`ROM move ${romMove.id} '${romMove.name}' is not in Showdown Gen 5`);
  }
  if (moves[showdownMove.id]) {
    throw new Error(`duplicate Showdown move id '${showdownMove.id}'`);
  }
  moves[showdownMove.id] = {
    id: showdownMove.id,
    name: showdownMove.name,
    type: romMove.type,
    category: romMove.category,
    power: romMove.power,
    accuracy: romMove.accuracy,
    pp: romMove.pp,
    priority: romMove.priority,
    romMoveId: romMove.id
  };
  moveByRomId.set(romMove.id, { id: showdownMove.id, name: showdownMove.name });
}

/**
 * Showdown's Gen 5 dex carries the ROM evolution table in a convenient form.
 * Only base-form targets imported by this content build are kept, so alternate
 * forms (Wormadam-Sandy, for example) never leak into the level-up chain.
 */
function evolutionsFor(showdown: any): GameEvolution[] {
  const evolutions: GameEvolution[] = [];
  for (const targetName of showdown.evos ?? []) {
    const target = gen5.species.get(targetName);
    if (
      !target ||
      target.num < 1 ||
      target.num > 649 ||
      target.name !== target.baseSpecies
    ) {
      continue;
    }
    const method = target.evoType ?? "level";
    if (method === "level" && !Number.isInteger(target.evoLevel)) continue;
    const evolution: GameEvolution = { to: target.id, method };
    if (Number.isInteger(target.evoLevel)) evolution.level = target.evoLevel;
    if (target.evoItem) evolution.item = slug(target.evoItem);
    if (target.evoMove) {
      const evoMove = gen5.moves.get(target.evoMove);
      if (evoMove) evolution.move = evoMove.id;
    }
    if (target.evoCondition) evolution.condition = target.evoCondition;
    // Gen 5 only evolves female Combee and gender determines Burmy's branch.
    // Showdown keeps those rules outside the evoCondition string.
    if (showdown.id === "burmy") {
      evolution.gender = target.id === "wormadam" ? "female" : "male";
    } else if (showdown.id === "combee" && target.id === "vespiquen") {
      evolution.gender = "female";
    }
    evolutions.push(evolution);
  }
  evolutions.sort(
    (a, b) =>
      (a.level ?? 0) - (b.level ?? 0) ||
      a.method.localeCompare(b.method) ||
      a.to.localeCompare(b.to)
  );
  return evolutions;
}

const species: Record<string, unknown> = {};
const unmappedSpecies: number[] = [];
for (let dex = 1; dex <= 649; dex++) {
  const rom = romSpecies[String(dex)];
  const showdown = showdownSpecies.find((entry: any) => entry.num === dex);
  if (!rom || !showdown) {
    unmappedSpecies.push(dex);
    continue;
  }
  if (showdown.types.join(",") !== rom.types.join(",")) {
    console.warn(
      `type mismatch dex ${dex} ${rom.name}: ROM ${rom.types.join("/")} ` +
        `Showdown ${showdown.types.join("/")}`
    );
  }
  const learnset: Array<{ level: number; move: string }> = [];
  const seen = new Set<string>();
  for (const entry of rom.learnset) {
    const mapped = moveByRomId.get(entry.moveId);
    if (!mapped || seen.has(mapped.id)) continue;
    seen.add(mapped.id);
    learnset.push({ level: Math.max(1, entry.level), move: mapped.id });
  }
  learnset.sort((a, b) => a.level - b.level || a.move.localeCompare(b.move));
  if (learnset.length === 0) {
    throw new Error(`dex ${dex} ${rom.name}: no mapped learnset moves`);
  }
  const total = Object.values(rom.baseStats).reduce((sum, value) => sum + value, 0);
  species[showdown.id] = {
    id: showdown.id,
    name: showdown.name,
    dex,
    types: rom.types,
    baseHp: rom.baseStats.hp,
    baseAtk: rom.baseStats.atk,
    baseDef: rom.baseStats.def,
    baseSpAtk: rom.baseStats.spAtk,
    baseSpDef: rom.baseStats.spDef,
    baseSpeed: rom.baseStats.speed,
    baseXp: Math.max(10, Math.round(total / 20)),
    catchRate: Number((rom.catchRate255 / 255).toFixed(3)),
    learnset,
    evolutions: evolutionsFor(showdown)
  };
}

const starters = (previous.starters as string[] | undefined) ?? ["snivy", "tepig", "oshawott"];
for (const starter of starters) {
  if (!species[starter]) throw new Error(`starter '${starter}' is missing from the full dex`);
}
for (const [id, value] of Object.entries(species)) {
  const entry = value as { evolutions: GameEvolution[] };
  for (const evolution of entry.evolutions) {
    if (!species[evolution.to]) {
      throw new Error(`${id}: evolution target '${evolution.to}' is missing`);
    }
  }
}
if (unmappedSpecies.length > 0) {
  throw new Error(`unmapped species: ${unmappedSpecies.join(", ")}`);
}

const backup = path.resolve("../.tools/game-subset-backup.json");
if (fs.existsSync(gamePath) && !fs.existsSync(backup)) {
  fs.mkdirSync(path.dirname(backup), { recursive: true });
  fs.copyFileSync(gamePath, backup);
}

const next = {
  ...previous,
  version: Number(previous.version ?? 1) + 1,
  moves,
  species,
  starters
};
fs.writeFileSync(gamePath, `${JSON.stringify(next, null, 2)}\n`);
console.log(
  `Wrote ${gamePath}: ${Object.keys(species).length} species, ` +
    `${Object.keys(moves).length} moves, ${starters.length} starters`
);
