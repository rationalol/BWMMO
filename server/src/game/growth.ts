import type { EvolutionDef, GameContent, MoveDef, NpcDef } from "../content/types.js";
import { conditionMatches, friendshipOf, MAX_FRIENDSHIP, pendingMovesFor } from "./creatures.js";
import type { CharacterState, CreatureState } from "./types.js";

export type StorageSource = "party" | "box";

export const MAX_NICKNAME_LENGTH = 12;

export interface MoveQueueResult {
  ok: boolean;
  error?: string;
  move?: MoveDef;
}

/**
 * Puts a move into the same pending queue the level-up path uses, so the
 * existing learn/replace prompt handles tutors, TMs and the reminder alike.
 */
export function queueMoveLearn(
  content: GameContent,
  creature: CreatureState,
  moveId: string
): MoveQueueResult {
  const move = content.moves[moveId];
  if (!move) return { ok: false, error: "That move does not exist." };
  if (creature.moves.some((known) => known.id === move.id)) {
    return { ok: false, error: `${creature.name} already knows ${move.name}.` };
  }
  if (pendingMovesFor(creature).includes(move.id)) {
    return { ok: false, error: `${creature.name} is already waiting to learn ${move.name}.` };
  }
  creature.pendingMoves ??= [];
  creature.pendingMoves.push(move.id);
  return { ok: true, move };
}

function learnsetMoves(
  content: GameContent,
  creature: CreatureState
): MoveDef[] {
  const species = content.species[creature.species];
  if (!species) return [];
  const seen = new Set<string>();
  const moves: MoveDef[] = [];
  for (const entry of species.learnset) {
    if (entry.level > creature.level) continue;
    if (seen.has(entry.move)) continue;
    seen.add(entry.move);
    const move = content.moves[entry.move];
    if (move) moves.push(move);
  }
  return moves;
}

/** Every level-up move this creature could remember right now. */
export function relearnableMoves(
  content: GameContent,
  creature: CreatureState
): MoveDef[] {
  const known = new Set(creature.moves.map((move) => move.id));
  const pending = new Set(pendingMovesFor(creature));
  return learnsetMoves(content, creature).filter(
    (move) => !known.has(move.id) && !pending.has(move.id)
  );
}

/** The moves a tutor NPC advertises, minus the ones the creature knows. */
export function tutorMovesFor(
  content: GameContent,
  npc: NpcDef,
  creature: CreatureState
): MoveDef[] {
  const known = new Set(creature.moves.map((move) => move.id));
  const pending = new Set(pendingMovesFor(creature));
  const moves: MoveDef[] = [];
  for (const moveId of npc.moveList ?? []) {
    const move = content.moves[moveId];
    if (!move || known.has(move.id) || pending.has(move.id)) continue;
    moves.push(move);
  }
  return moves;
}

export function tutorKnowsMove(npc: NpcDef, moveId: string): boolean {
  return (npc.moveList ?? []).includes(moveId);
}

export function canRememberMove(
  content: GameContent,
  creature: CreatureState,
  moveId: string
): boolean {
  return relearnableMoves(content, creature).some((move) => move.id === moveId);
}

function levelAllows(creature: CreatureState, evolution: EvolutionDef): boolean {
  return evolution.level === undefined || creature.level >= evolution.level;
}

/** The evolution triggered by using an item on this creature, if any. */
export function itemEvolutionFor(
  content: GameContent,
  creature: CreatureState,
  itemId: string
): EvolutionDef | null {
  const species = content.species[creature.species];
  if (!species) return null;
  for (const evolution of species.evolutions) {
    if (evolution.method !== "useItem") continue;
    if (evolution.item !== itemId) continue;
    if (!levelAllows(creature, evolution)) continue;
    if (!conditionMatches(creature, evolution)) continue;
    return evolution;
  }
  return null;
}

/** The evolution a link trade would trigger for this creature. */
export function tradeEvolutionFor(
  content: GameContent,
  creature: CreatureState
): EvolutionDef | null {
  const species = content.species[creature.species];
  if (!species) return null;
  for (const evolution of species.evolutions) {
    if (evolution.method !== "trade") continue;
    if (evolution.item !== undefined && creature.heldItem !== evolution.item) continue;
    if (!levelAllows(creature, evolution)) continue;
    if (!conditionMatches(creature, evolution)) continue;
    return evolution;
  }
  return null;
}

/** Maxes the friendship of every party member; used by the test NPC. */
export function maxFriendship(party: CreatureState[]): void {
  for (const creature of party) creature.friendship = MAX_FRIENDSHIP;
}

export function friendshipLabel(creature: CreatureState): string {
  const value = friendshipOf(creature);
  if (value >= MAX_FRIENDSHIP) return "maxed out";
  if (value >= 220) return "very high";
  if (value >= 150) return "high";
  if (value >= 70) return "normal";
  return "low";
}

export interface RenameResult {
  ok: boolean;
  error?: string;
  creature?: CreatureState;
}

/**
 * Trims and validates a nickname. Unicode is allowed (the font covers CJK),
 * control characters and line breaks are not, and the result is capped at 12
 * characters rather than bytes.
 */
export function normalizeNickname(value: string): string | null {
  const name = value.trim();
  if (name.length === 0 || name.length > MAX_NICKNAME_LENGTH * 4) return null;
  if (/[\u0000-\u001f\u007f]/.test(name)) return null;
  if ([...name].length > MAX_NICKNAME_LENGTH) return null;
  return name;
}

export function renameCreature(
  character: CharacterState,
  source: StorageSource,
  index: number,
  rawName: string
): RenameResult {
  const list = source === "party" ? character.party : character.box;
  if (!Number.isInteger(index) || index < 0 || index >= list.length) {
    return { ok: false, error: "That Pokémon does not exist." };
  }
  const name = normalizeNickname(rawName);
  if (!name) {
    return {
      ok: false,
      error: `Enter a nickname of 1-${MAX_NICKNAME_LENGTH} characters.`
    };
  }
  const creature = list[index];
  creature.name = name;
  return { ok: true, creature };
}

export interface ReleaseResult {
  ok: boolean;
  error?: string;
  creature?: CreatureState;
}

/**
 * Releases a boxed Pokémon. Party members are never released, so the player
 * always keeps at least one usable partner; the client has already confirmed.
 */
export function releaseFromBox(
  character: CharacterState,
  boxIndex: number
): ReleaseResult {
  if (
    !Number.isInteger(boxIndex) ||
    boxIndex < 0 ||
    boxIndex >= character.box.length
  ) {
    return { ok: false, error: "That box slot does not exist." };
  }
  const [creature] = character.box.splice(boxIndex, 1);
  return { ok: true, creature };
}
