import type { EvYieldDef, EvolutionDef, GameContent, MoveDef, SpeciesDef } from "../content/types.js";
import { assignAbility, defaultAbilityForSpecies, resolveAbilityForSpecies } from "./abilities.js";
import type {
  CreatureGender,
  CreatureMove,
  CreatureState,
  StatBlock
} from "./types.js";

export const MAX_MOVES = 4;

export const DEFAULT_FRIENDSHIP = 70;
export const MAX_FRIENDSHIP = 255;
export const FRIENDSHIP_EVOLUTION_THRESHOLD = 220;

/** Gen 5 effort-value caps: 255 per stat, 510 across all six. */
export const MAX_EV_PER_STAT = 255;
export const MAX_EV_TOTAL = 510;

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

type StatKey = keyof StatBlock;

const STAT_KEYS: StatKey[] = ["hp", "atk", "def", "spAtk", "spDef", "speed"];

/** Gen 5 natures: five neutral ones plus one +10%/-10% pair each. */
const NATURE_MODIFIERS: Record<string, { plus: StatKey; minus: StatKey }> = {
  Lonely: { plus: "atk", minus: "def" },
  Brave: { plus: "atk", minus: "speed" },
  Adamant: { plus: "atk", minus: "spAtk" },
  Naughty: { plus: "atk", minus: "spDef" },
  Bold: { plus: "def", minus: "atk" },
  Relaxed: { plus: "def", minus: "speed" },
  Impish: { plus: "def", minus: "spAtk" },
  Lax: { plus: "def", minus: "spDef" },
  Timid: { plus: "speed", minus: "atk" },
  Hasty: { plus: "speed", minus: "def" },
  Jolly: { plus: "speed", minus: "spAtk" },
  Naive: { plus: "speed", minus: "spDef" },
  Modest: { plus: "spAtk", minus: "atk" },
  Mild: { plus: "spAtk", minus: "def" },
  Quiet: { plus: "spAtk", minus: "speed" },
  Rash: { plus: "spAtk", minus: "spDef" },
  Calm: { plus: "spDef", minus: "atk" },
  Gentle: { plus: "spDef", minus: "def" },
  Sassy: { plus: "spDef", minus: "speed" },
  Careful: { plus: "spDef", minus: "spAtk" }
};

function clampIv(value: unknown): number {
  if (!Number.isFinite(value)) return 0;
  return Math.max(0, Math.min(31, Math.floor(value as number)));
}

function clampEv(value: unknown): number {
  if (!Number.isFinite(value)) return 0;
  return Math.max(0, Math.min(MAX_EV_PER_STAT, Math.floor(value as number)));
}

function statWithNature(value: number, nature: string | undefined, stat: StatKey): number {
  const modifiers = nature ? NATURE_MODIFIERS[nature] : undefined;
  if (!modifiers) return value;
  if (modifiers.plus === stat) return Math.floor((value * 110) / 100);
  if (modifiers.minus === stat) return Math.floor((value * 90) / 100);
  return value;
}

/**
 * Gen 5 stat formula (identical to the one Showdown applies to a set, so the
 * stored stats and the battle engine never disagree):
 *
 *   HP     = floor((2*base + IV + floor(EV/4)) * level / 100) + level + 10
 *   others = floor((floor((2*base + IV + floor(EV/4)) * level / 100) + 5) * nature)
 *
 * Missing IV/EV/nature data reads as an untrained, neutral creature, which is
 * exactly what older saves and content-only callers expect.
 */
export function statsForCreature(
  species: SpeciesDef,
  source: {
    level: number;
    ivs?: StatBlock;
    evs?: StatBlock;
    nature?: string;
  }
): LevelStats {
  const level = Math.max(1, Math.min(100, Math.floor(source.level)));
  const iv = (stat: StatKey) => clampIv(source.ivs?.[stat]);
  const ev = (stat: StatKey) => clampEv(source.evs?.[stat]);
  const core = (base: number, stat: StatKey) =>
    Math.floor(((2 * base + iv(stat) + Math.floor(ev(stat) / 4)) * level) / 100);

  // Shedinja is the one species whose HP is fixed at 1.
  const maxHp = species.baseHp === 1 ? 1 : core(species.baseHp, "hp") + level + 10;
  return {
    maxHp,
    atk: statWithNature(core(species.baseAtk, "atk") + 5, source.nature, "atk"),
    def: statWithNature(core(species.baseDef, "def") + 5, source.nature, "def"),
    spAtk: statWithNature(core(species.baseSpAtk, "spAtk") + 5, source.nature, "spAtk"),
    spDef: statWithNature(core(species.baseSpDef, "spDef") + 5, source.nature, "spDef"),
    speed: statWithNature(core(species.baseSpeed, "speed") + 5, source.nature, "speed")
  };
}

/**
 * Recomputes every derived stat from species + level + IV/EV/nature. HP keeps
 * the same amount of damage: a larger maximum heals by the difference, a
 * smaller one caps the current HP.
 */
export function recalculateCreatureStats(
  species: SpeciesDef,
  creature: CreatureState
): LevelStats {
  const stats = statsForCreature(species, creature);
  const oldMaxHp = Number.isFinite(creature.maxHp) ? creature.maxHp : stats.maxHp;
  const currentHp = Number.isFinite(creature.hp) ? creature.hp : stats.maxHp;
  creature.maxHp = stats.maxHp;
  creature.hp =
    currentHp <= 0
      ? 0
      : Math.max(0, Math.min(stats.maxHp, currentHp + (stats.maxHp - oldMaxHp)));
  creature.atk = stats.atk;
  creature.def = stats.def;
  creature.spAtk = stats.spAtk;
  creature.spDef = stats.spDef;
  creature.speed = stats.speed;
  return stats;
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

export function evTotalOf(evs: StatBlock | undefined): number {
  return STAT_KEYS.reduce((total, stat) => total + clampEv(evs?.[stat]), 0);
}

/**
 * Clamps a persisted EV block to the Gen 5 caps, spending the 510-point
 * budget in stat order. Returns true when the block had to change.
 */
export function normalizeEvBlock(evs: StatBlock): boolean {
  let changed = false;
  let used = 0;
  for (const stat of STAT_KEYS) {
    const raw = evs[stat];
    let value = clampEv(raw);
    value = Math.min(value, Math.max(0, MAX_EV_TOTAL - used));
    used += value;
    if (value !== raw) {
      evs[stat] = value;
      changed = true;
    }
  }
  return changed;
}

/** EV points actually applied after the per-stat and total caps. */
export interface EvGain {
  hp: number;
  atk: number;
  def: number;
  spAtk: number;
  spDef: number;
  speed: number;
}

export function emptyEvGain(): EvGain {
  return { hp: 0, atk: 0, def: 0, spAtk: 0, spDef: 0, speed: 0 };
}

export function evGainTotal(gain: EvGain): number {
  return STAT_KEYS.reduce((total, stat) => total + (gain[stat] ?? 0), 0);
}

/**
 * Adds the defeated species' EV yield to one creature and immediately
 * recomputes its stats so the gain matters in the next battle. Yields that
 * would cross the 255-per-stat or 510-total cap are clipped.
 */
export function awardEffortValues(
  creature: CreatureState,
  species: SpeciesDef,
  evYield: EvYieldDef
): EvGain {
  const evs = creature.evs ?? emptyEvBlock();
  creature.evs = evs;
  let remaining = Math.max(0, MAX_EV_TOTAL - evTotalOf(evs));
  const gain = emptyEvGain();
  for (const stat of STAT_KEYS) {
    const room = Math.max(0, MAX_EV_PER_STAT - clampEv(evs[stat]));
    const add = Math.max(0, Math.min(evYield[stat] ?? 0, room, remaining));
    if (add > 0) {
      evs[stat] = clampEv(evs[stat]) + add;
      gain[stat] = add;
      remaining -= add;
    }
  }
  if (evGainTotal(gain) > 0) recalculateCreatureStats(species, creature);
  return gain;
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

/** Reads the persisted friendship, defaulting old saves to the base value. */
export function friendshipOf(creature: CreatureState): number {
  const value = creature.friendship;
  if (!Number.isFinite(value)) return DEFAULT_FRIENDSHIP;
  return Math.max(0, Math.min(MAX_FRIENDSHIP, Math.floor(value as number)));
}

/** Raises friendship (used by level-ups, healing and the test NPC). */
export function raiseFriendship(creature: CreatureState, amount: number): void {
  creature.friendship = Math.max(
    0,
    Math.min(MAX_FRIENDSHIP, friendshipOf(creature) + Math.floor(amount))
  );
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

  const resolvedAbility = resolveAbilityForSpecies(
    creature.species,
    creature.ability,
    creature.abilitySlot
  );
  if (!resolvedAbility) {
    if (creature.ability !== undefined || creature.abilitySlot !== undefined) {
      delete creature.ability;
      delete creature.abilitySlot;
      changed = true;
    }
  } else if (
    creature.ability !== resolvedAbility.id ||
    creature.abilitySlot !== resolvedAbility.slot
  ) {
    creature.ability = resolvedAbility.id;
    creature.abilitySlot = resolvedAbility.slot;
    changed = true;
  }
  // Localized view fields must never leak into the save file.
  if (creature.abilityName !== undefined || creature.abilityDescription !== undefined) {
    delete creature.abilityName;
    delete creature.abilityDescription;
    changed = true;
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

export interface EvolutionContext {
  /** Current map, used by location-based levelExtra evolutions. */
  mapId?: string;
  /** Party at the time of the check, used by "with a Remoraid in party". */
  party?: CreatureState[];
}

export function conditionMatches(creature: CreatureState, evolution: EvolutionDef): boolean {
  if (evolution.gender && creature.gender !== evolution.gender) return false;
  const condition = evolution.condition ?? "";
  if (condition.includes("Atk stat >")) return creature.atk > creature.def;
  if (condition.includes("Atk stat <")) return creature.atk < creature.def;
  if (condition.includes("Atk stat equal")) return creature.atk === creature.def;
  return true;
}

/** Location/party requirements for the five levelExtra evolutions. */
function extraConditionMatches(
  content: GameContent,
  creature: CreatureState,
  evolution: EvolutionDef,
  context: EvolutionContext
): boolean {
  const condition = evolution.condition ?? "";
  if (condition.includes("Remoraid in party")) {
    return (context.party ?? []).some((member) => member.species === "remoraid");
  }
  const mapName = context.mapId ? content.maps[context.mapId]?.name ?? "" : "";
  if (condition.includes("special magnetic field")) return mapName === "Chargestone Cave";
  if (condition.includes("Ice Rock")) {
    return mapName === "Twist Mountain" || mapName === "Giant Chasm";
  }
  if (condition.includes("Moss Rock")) return mapName === "Pinwheel Forest";
  return false;
}

/** Returns the level-up evolution that should fire for this creature, if any. */
export function levelEvolutionFor(
  content: GameContent,
  creature: CreatureState,
  context: EvolutionContext = {}
): EvolutionDef | null {
  const species = content.species[creature.species];
  if (!species) return null;
  for (const evolution of species.evolutions) {
    if (
      evolution.method !== "level" &&
      evolution.method !== "levelMove" &&
      evolution.method !== "levelHold" &&
      evolution.method !== "levelFriendship" &&
      evolution.method !== "levelExtra"
    ) {
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
    if (
      evolution.method === "levelFriendship" &&
      friendshipOf(creature) < FRIENDSHIP_EVOLUTION_THRESHOLD
    ) {
      continue;
    }
    if (
      evolution.method === "levelExtra" &&
      !extraConditionMatches(content, creature, evolution, context)
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
  fromTypes: string[];
  toSpecies: string;
  toName: string;
  toTypes: string[];
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
  const fromName = creature.name;
  const fromTypes = [...from.types];
  creature.species = to.id;
  if (creature.name === from.name) creature.name = to.name;
  creature.types = [...to.types];
  // Keep the chosen ability when the evolved species can still have it;
  // otherwise fall back to the evolved species's first legal ability.
  assignAbility(creature);
  // Evolution keeps IVs, EVs and nature; only the base stats change.
  recalculateCreatureStats(to, creature);
  creature.baseXp = to.baseXp;
  creature.catchRate = to.catchRate;
  return {
    fromSpecies: from.id,
    fromName,
    fromTypes,
    toSpecies: to.id,
    toName: to.name,
    toTypes: [...to.types]
  };
}

export function createCreature(
  content: GameContent,
  speciesId: string,
  level: number
): CreatureState {
  const species = content.species[speciesId];
  if (!species) throw new Error(`Unknown species: ${speciesId}`);
  const ivs = randomIvBlock();
  const evs = emptyEvBlock();
  const nature = randomNature();
  const stats = statsForCreature(species, { level, ivs, evs, nature });
  const ability = defaultAbilityForSpecies(species.id);
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
    ivs,
    evs,
    nature,
    heldItem: null,
    ability: ability?.id,
    abilitySlot: ability?.slot,
    friendship: DEFAULT_FRIENDSHIP,
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
  /** Content move ids for the moves in `learned`, in the same order. */
  learnedIds: string[];
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
  log: string[],
  context: EvolutionContext = {}
): XpResult {
  const species = content.species[creature.species];
  if (!species) throw new Error(`Unknown species: ${creature.species}`);
  if (amount <= 0 || creature.hp <= 0) {
    return { levelsGained: 0, learned: [], learnedIds: [], pendingMoves: [], evolution: null };
  }

  creature.xp += Math.floor(amount);
  log.push(`${creature.name} gained ${Math.floor(amount)} XP.`);

  let levelsGained = 0;
  const learned: string[] = [];
  const learnedIds: string[] = [];
  const pendingMoves: string[] = [];
  const queued = new Set(pendingMovesFor(creature));
  while (creature.level < 100 && creature.xp >= xpToNext(content, creature.level)) {
    creature.xp -= xpToNext(content, creature.level);
    creature.level += 1;
    levelsGained += 1;

    recalculateCreatureStats(species, creature);
    creature.xpToNext = xpToNext(content, creature.level);
    raiseFriendship(creature, 2);

    const known = new Set(creature.moves.map((move) => move.id));
    for (const entry of species.learnset.filter((item) => item.level === creature.level)) {
      const move = content.moves[entry.move];
      if (!move || known.has(move.id) || queued.has(move.id)) continue;
      if (creature.moves.length < MAX_MOVES) {
        const learnedMove = freshMove(move);
        creature.moves.push(learnedMove);
        known.add(move.id);
        learned.push(move.name);
        learnedIds.push(move.id);
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
  const evolutionDef = levelEvolutionFor(content, creature, context);
  if (evolutionDef) {
    log.push(`What? ${creature.name} is evolving!`);
    evolution = evolveCreature(content, creature, evolutionDef);
    if (evolution) {
      log.push(
        `Congratulations! Your ${evolution.fromName} evolved into ${evolution.toName}!`
      );
    }
  }

  return { levelsGained, learned, learnedIds, pendingMoves, evolution };
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
