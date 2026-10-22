import type { EvolutionDef, GameContent, MoveDef, SpeciesDef } from "../content/types.js";
import type {
  CreatureGender,
  CreatureMove,
  CreatureState,
  StatBlock
} from "./types.js";

export const MAX_MOVES = 4;

export const PLAYER_COLORS = [
  "#e76f51",
  "#2a9d8f",
  "#457b9d",
  "#9b5de5",
  "#f4a261",
  "#577590",
  "#e63946",
  "#43aa8b"
];

// Species with no gender at all. This is the Gen 5 genderless set plus the
// legendary block; the exact ratio is cosmetic and only drives the party icon.
const GENDERLESS_DEX = new Set<number>([
  81, 82, 100, 101, 120, 121, 132, 137, 233, 374, 375, 376, 462, 474, 479,
  599, 600, 601,
  144, 145, 146, 150, 151, 243, 244, 245, 249, 250, 251,
  377, 378, 379, 382, 383, 384, 385, 386,
  480, 481, 482, 483, 484, 485, 486, 487, 489, 490, 491, 492, 493, 494,
  638, 639, 640, 641, 642, 643, 644, 645, 646, 647, 648, 649
]);

export function genderForDex(dex: number): CreatureGender {
  if (GENDERLESS_DEX.has(dex)) return "genderless";
  return Math.random() < 0.5 ? "male" : "female";
}

export interface LevelStats {
  maxHp: number;
  atk: number;
  def: number;
  spAtk: number;
  spDef: number;
  speed: number;
}

export const NATURES = [
  "Hardy", "Lonely", "Brave", "Adamant", "Naughty",
  "Bold", "Docile", "Relaxed", "Impish", "Lax",
  "Timid", "Hasty", "Serious", "Jolly", "Naive",
  "Modest", "Mild", "Quiet", "Bashful", "Rash",
  "Calm", "Gentle", "Sassy", "Careful", "Quirky"
];

export function statsForLevel(species: SpeciesDef, level: number): LevelStats {
  // Gen 5-style stats without IVs/EVs/nature; keeps battle math proportionate.
  return {
    maxHp: Math.floor((2 * species.baseHp * level) / 100) + level + 10,
    atk: Math.floor((2 * species.baseAtk * level) / 100) + 5,
    def: Math.floor((2 * species.baseDef * level) / 100) + 5,
    spAtk: Math.floor((2 * species.baseSpAtk * level) / 100) + 5,
    spDef: Math.floor((2 * species.baseSpDef * level) / 100) + 5,
    speed: Math.floor((2 * species.baseSpeed * level) / 100) + 5
  };
}

export function randomIvBlock(): StatBlock {
  const roll = () => Math.floor(Math.random() * 32);
  return {
    hp: roll(), atk: roll(), def: roll(),
    spAtk: roll(), spDef: roll(), speed: roll()
  };
}

export function emptyEvBlock(): StatBlock {
  return { hp: 0, atk: 0, def: 0, spAtk: 0, spDef: 0, speed: 0 };
}

export function randomNature(): string {
  return NATURES[Math.floor(Math.random() * NATURES.length)];
}

export function movesForLevel(
  content: GameContent,
  species: SpeciesDef,
  level: number
): MoveDef[] {
  const eligible = species.learnset
    .filter((entry) => entry.level <= level)
    .sort((a, b) => a.level - b.level);
  const seen = new Set<string>();
  const moveIds: string[] = [];
  for (const entry of eligible) {
    if (seen.has(entry.move)) continue;
    seen.add(entry.move);
    moveIds.push(entry.move);
  }
  return moveIds
    .slice(-4)
    .map((moveId) => content.moves[moveId])
    .filter((move): move is MoveDef => Boolean(move));
}

export function maxPpForMove(move: MoveDef): number {
  return Math.max(1, Math.floor(move.pp ?? 5));
}

export function freshMove(move: MoveDef): CreatureMove {
  const maxPp = maxPpForMove(move);
  return { ...move, currentPp: maxPp, maxPp };
}

export function movePp(move: CreatureMove): { current: number; max: number } {
  const max = Math.max(1, Math.floor(move.maxPp ?? move.pp ?? 5));
  const current = Math.max(
    0,
    Math.min(max, Math.floor(move.currentPp ?? max))
  );
  return { current, max };
}

/**
 * Migrates one creature's moves to the persisted PP shape and removes stale
 * pending learns. Returns true when the save needs to be written back.
 */
export function normalizeCreatureProgress(
  content: GameContent,
  creature: CreatureState
): boolean {
  let changed = false;
  const rawMoves = Array.isArray(creature.moves) ? creature.moves : [];
  const moves: CreatureMove[] = [];
  const known = new Set<string>();
  for (const raw of rawMoves) {
    if (!raw || typeof raw !== "object" || typeof raw.id !== "string") {
      changed = true;
      continue;
    }
    const key = raw.id.toLowerCase().replace(/[^a-z0-9]/g, "");
    const definition = content.moves[key];
    if (!definition || known.has(definition.id)) {
      changed = true;
      continue;
    }
    known.add(definition.id);
    const maxPp = maxPpForMove(definition);
    const currentPp = Number.isFinite(raw.currentPp)
      ? Math.max(0, Math.min(maxPp, Math.floor(raw.currentPp as number)))
      : maxPp;
    moves.push({ ...definition, currentPp, maxPp });
    if (
      raw.id !== definition.id ||
      raw.maxPp !== maxPp ||
      raw.currentPp !== currentPp
    ) {
      changed = true;
    }
  }
  if (moves.length !== rawMoves.length) changed = true;
  creature.moves = moves;

  const rawPending = Array.isArray(creature.pendingMoves)
    ? creature.pendingMoves
    : [];
  const pending: string[] = [];
  const queued = new Set<string>();
  for (const value of rawPending) {
    if (typeof value !== "string") {
      changed = true;
      continue;
    }
    const key = value.toLowerCase().replace(/[^a-z0-9]/g, "");
    const definition = content.moves[key];
    if (
      !definition ||
      known.has(definition.id) ||
      queued.has(definition.id)
    ) {
      changed = true;
      continue;
    }
    queued.add(definition.id);
    pending.push(definition.id);
  }
  if (pending.length !== rawPending.length) changed = true;
  if (pending.length > 0) creature.pendingMoves = pending;
  else if (creature.pendingMoves !== undefined) {
    delete creature.pendingMoves;
    if (rawPending.length > 0) changed = true;
  }
  return changed;
}

export function pendingMovesFor(creature: CreatureState): string[] {
  return Array.isArray(creature.pendingMoves) ? creature.pendingMoves : [];
}

export interface MoveLearnResult {
  ok: boolean;
  error?: string;
  move?: CreatureMove;
  skipped?: boolean;
}

/**
 * Resolves a queued level-up move. `null` means "do not learn it"; an index
 * replaces that move slot. When a slot is free the replacement index is ignored.
 */
export function resolvePendingMove(
  content: GameContent,
  creature: CreatureState,
  moveId: string,
  replaceIndex: number | null
): MoveLearnResult {
  const pending = pendingMovesFor(creature);
  if (!pending.includes(moveId)) {
    return { ok: false, error: "That move is not waiting to be learned." };
  }
  const definition = content.moves[moveId];
  if (!definition) return { ok: false, error: "That move does not exist." };
  if (creature.moves.some((move) => move.id === definition.id)) {
    return { ok: false, error: "That move is already known." };
  }

  let learned: CreatureMove | null = null;
  if (replaceIndex === null) {
    // Explicitly declined; just drop the queued move below.
  } else if (!Number.isInteger(replaceIndex) || replaceIndex < 0) {
    return { ok: false, error: "Choose a move to forget." };
  } else if (creature.moves.length < MAX_MOVES) {
    learned = freshMove(definition);
    creature.moves.push(learned);
  } else {
    if (replaceIndex >= creature.moves.length) {
      return { ok: false, error: "That move slot does not exist." };
    }
    learned = freshMove(definition);
    creature.moves[replaceIndex] = learned;
  }

  creature.pendingMoves = pending.filter((id) => id !== moveId);
  if (creature.pendingMoves.length === 0) delete creature.pendingMoves;
  return replaceIndex === null
    ? { ok: true, skipped: true }
    : { ok: true, move: learned ?? undefined };
}

export function forgetMove(
  creature: CreatureState,
  moveIndex: number
): MoveLearnResult {
  if (!Number.isInteger(moveIndex) || moveIndex < 0 || moveIndex >= creature.moves.length) {
    return { ok: false, error: "That move slot does not exist." };
  }
  if (creature.moves.length <= 1) {
    return { ok: false, error: "A creature must keep at least one move." };
  }
  const [move] = creature.moves.splice(moveIndex, 1);
  return { ok: true, move };
}

function conditionMatches(creature: CreatureState, evolution: EvolutionDef): boolean {
  if (evolution.gender && creature.gender !== evolution.gender) return false;
  const condition = evolution.condition ?? "";
  if (condition.includes("Atk stat >")) return creature.atk > creature.def;
  if (condition.includes("Atk stat <")) return creature.atk < creature.def;
  if (condition.includes("Atk stat equal")) return creature.atk === creature.def;
  return true;
}

/** Returns the level-up evolution that should fire for this creature, if any. */
export function levelEvolutionFor(
  content: GameContent,
  creature: CreatureState
): EvolutionDef | null {
  const species = content.species[creature.species];
  if (!species) return null;
  for (const evolution of species.evolutions) {
    if (evolution.method !== "level" && evolution.method !== "levelMove" && evolution.method !== "levelHold") {
      continue;
    }
    if (evolution.level !== undefined && creature.level < evolution.level) continue;
    if (
      evolution.method === "levelMove" &&
      evolution.move !== undefined &&
      !creature.moves.some((move) => move.id === evolution.move)
    ) {
      continue;
    }
    if (
      evolution.method === "levelHold" &&
      evolution.item !== undefined &&
      creature.heldItem !== evolution.item
    ) {
      continue;
    }
    if (!conditionMatches(creature, evolution)) continue;
    return evolution;
  }
  return null;
}

export interface EvolutionResult {
  fromSpecies: string;
  fromName: string;
  toSpecies: string;
  toName: string;
}

/** Applies one evolution, preserving level, XP, moves, PP and pending learns. */
export function evolveCreature(
  content: GameContent,
  creature: CreatureState,
  evolution: EvolutionDef
): EvolutionResult | null {
  const from = content.species[creature.species];
  const to = content.species[evolution.to];
  if (!from || !to) return null;
  const oldMaxHp = creature.maxHp;
  const stats = statsForLevel(to, creature.level);
  const fromName = creature.name;
  creature.species = to.id;
  if (creature.name === from.name) creature.name = to.name;
  creature.types = [...to.types];
  creature.maxHp = stats.maxHp;
  const hpGain = stats.maxHp - oldMaxHp;
  creature.hp = Math.max(0, Math.min(creature.maxHp, creature.hp + hpGain));
  creature.atk = stats.atk;
  creature.def = stats.def;
  creature.spAtk = stats.spAtk;
  creature.spDef = stats.spDef;
  creature.speed = stats.speed;
  creature.baseXp = to.baseXp;
  creature.catchRate = to.catchRate;
  return {
    fromSpecies: from.id,
    fromName,
    toSpecies: to.id,
    toName: to.name
  };
}

export function createCreature(
  content: GameContent,
  speciesId: string,
  level: number
): CreatureState {
  const species = content.species[speciesId];
  if (!species) throw new Error(`Unknown species: ${speciesId}`);
  const stats = statsForLevel(species, level);
  return {
    species: species.id,
    name: species.name,
    level,
    gender: genderForDex(species.dex),
    types: [...species.types],
    xp: 0,
    xpToNext: xpToNext(content, level),
    ...stats,
    hp: stats.maxHp,
    ivs: randomIvBlock(),
    evs: emptyEvBlock(),
    nature: randomNature(),
    heldItem: null,
    moves: movesForLevel(content, species, level).map(freshMove),
    baseXp: species.baseXp,
    catchRate: species.catchRate
  };
}

export function createStarter(content: GameContent, starterId: string): CreatureState {
  return createCreature(content, starterId, 5);
}

export function createWildCreature(
  content: GameContent,
  speciesId: string,
  level: number
): CreatureState {
  return createCreature(content, speciesId, level);
}

export function xpToNext(content: GameContent, level: number): number {
  return content.config.xpLevelBase + level * content.config.xpLevelGrowth;
}

export interface XpResult {
  levelsGained: number;
  learned: string[];
  pendingMoves: string[];
  evolution: EvolutionResult | null;
}

/**
 * Adds XP and handles any number of level-ups. Mutates the creature and appends
 * human-readable lines to `log` so the battle result can show them. A level-up
 * move only enters the pending queue when all four move slots are occupied;
 * the player then chooses a move to forget or declines through the protocol.
 */
export function awardExperience(
  content: GameContent,
  creature: CreatureState,
  amount: number,
  log: string[]
): XpResult {
  const species = content.species[creature.species];
  if (!species) throw new Error(`Unknown species: ${creature.species}`);
  if (amount <= 0 || creature.hp <= 0) {
    return { levelsGained: 0, learned: [], pendingMoves: [], evolution: null };
  }

  creature.xp += Math.floor(amount);
  log.push(`${creature.name} gained ${Math.floor(amount)} XP.`);

  let levelsGained = 0;
  const learned: string[] = [];
  const pendingMoves: string[] = [];
  const queued = new Set(pendingMovesFor(creature));
  while (creature.level < 100 && creature.xp >= xpToNext(content, creature.level)) {
    creature.xp -= xpToNext(content, creature.level);
    creature.level += 1;
    levelsGained += 1;

    const oldMaxHp = creature.maxHp;
    const stats = statsForLevel(species, creature.level);
    creature.maxHp = stats.maxHp;
    creature.hp = Math.min(creature.maxHp, creature.hp + (stats.maxHp - oldMaxHp));
    creature.atk = stats.atk;
    creature.def = stats.def;
    creature.spAtk = stats.spAtk;
    creature.spDef = stats.spDef;
    creature.speed = stats.speed;
    creature.xpToNext = xpToNext(content, creature.level);

    const known = new Set(creature.moves.map((move) => move.id));
    for (const entry of species.learnset.filter((item) => item.level === creature.level)) {
      const move = content.moves[entry.move];
      if (!move || known.has(move.id) || queued.has(move.id)) continue;
      if (creature.moves.length < MAX_MOVES) {
        const learnedMove = freshMove(move);
        creature.moves.push(learnedMove);
        known.add(move.id);
        learned.push(move.name);
        log.push(`${creature.name} learned ${move.name}!`);
      } else {
        queued.add(move.id);
        creature.pendingMoves ??= [];
        creature.pendingMoves.push(move.id);
        pendingMoves.push(move.id);
        log.push(`${creature.name} wants to learn ${move.name}!`);
      }
    }
    log.push(`${creature.name} grew to Lv.${creature.level}!`);
  }

  let evolution: EvolutionResult | null = null;
  const evolutionDef = levelEvolutionFor(content, creature);
  if (evolutionDef) {
    log.push(`What? ${creature.name} is evolving!`);
    evolution = evolveCreature(content, creature, evolutionDef);
    if (evolution) {
      log.push(
        `Congratulations! Your ${evolution.fromName} evolved into ${evolution.toName}!`
      );
    }
  }

  return { levelsGained, learned, pendingMoves, evolution };
}

export function healParty(party: CreatureState[]): void {
  for (const creature of party) {
    creature.hp = creature.maxHp;
    creature.status = undefined;
    for (const move of creature.moves) {
      const { max } = movePp(move);
      move.maxPp = max;
      move.currentPp = max;
    }
  }
}
