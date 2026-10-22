import type { Dir, MoveDef, PType } from "../content/types.js";

export type { Dir, MoveDef, PType } from "../content/types.js";

export type CreatureGender = "male" | "female" | "genderless";

export interface StatBlock {
  hp: number;
  atk: number;
  def: number;
  spAtk: number;
  spDef: number;
  speed: number;
}

/** A move as owned by one creature; `pp` is the species-independent maximum. */
export interface CreatureMove extends MoveDef {
  /** Remaining PP, persisted between battles. */
  currentPp?: number;
  /** Cached maximum so old saves keep their original PP after content edits. */
  maxPp?: number;
}

export interface PokedexState {
  /** National dex numbers that have been encountered. */
  seen: number[];
  /** National dex numbers that are currently or previously owned. */
  caught: number[];
}

export interface CreatureState {
  species: string;
  name: string;
  level: number;
  types: PType[];
  xp: number;
  maxHp: number;
  hp: number;
  atk: number;
  def: number;
  spAtk?: number;
  spDef?: number;
  speed: number;
  ivs?: StatBlock;
  evs?: StatBlock;
  nature?: string;
  heldItem?: string | null;
  xpToNext?: number;
  moves: CreatureMove[];
  /** Level-up moves that could not be learned because all four slots are full. */
  pendingMoves?: string[];
  baseXp: number;
  catchRate: number;
  status?: string;
  gender?: CreatureGender;
}

export interface Inventory {
  /** Item id -> stack count. Ball stacks are used by the battle catch action. */
  items: Record<string, number>;
}

export interface CharacterState {
  id: string;
  name: string;
  color: string;
  mapId: string;
  x: number;
  y: number;
  dir: Dir;
  sprite: number;
  money: number;
  wins: number;
  party: CreatureState[];
  /** Pokémon stored in the PC; they keep their HP and status. */
  box: CreatureState[];
  inventory: Inventory;
  /** Seen/caught registry; filled from the party for older saves. */
  pokedex?: PokedexState;
  /** Persisted ROM event-work flags used by conditional NPC dialogue. */
  storyFlags?: Record<string, number>;
}
