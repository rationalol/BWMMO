import type { CharacterState } from "./types.js";

export interface StorageResult {
  ok: boolean;
  error?: string;
}

/**
 * Moves a party member into the PC. The party must keep at least one creature
 * so the player can never lock themselves out of the world.
 */
export function depositToBox(
  character: CharacterState,
  partyIndex: number,
  maxBox: number
): StorageResult {
  if (!Number.isInteger(partyIndex) || partyIndex < 0 || partyIndex >= character.party.length) {
    return { ok: false, error: "That party slot does not exist." };
  }
  if (character.party.length <= 1) {
    return { ok: false, error: "You must keep at least one Pokémon in your party." };
  }
  if (character.box.length >= maxBox) {
    return { ok: false, error: "Your PC box is full." };
  }
  const [creature] = character.party.splice(partyIndex, 1);
  character.box.push(creature);
  return { ok: true };
}

export function withdrawFromBox(
  character: CharacterState,
  boxIndex: number,
  maxParty: number
): StorageResult {
  if (!Number.isInteger(boxIndex) || boxIndex < 0 || boxIndex >= character.box.length) {
    return { ok: false, error: "That PC slot does not exist." };
  }
  if (character.party.length >= maxParty) {
    return { ok: false, error: "Your party is full." };
  }
  const [creature] = character.box.splice(boxIndex, 1);
  character.party.push(creature);
  return { ok: true };
}

/** Swaps a party member with a boxed one, available even when both are full. */
export function swapPartyWithBox(
  character: CharacterState,
  partyIndex: number,
  boxIndex: number
): StorageResult {
  if (!Number.isInteger(partyIndex) || partyIndex < 0 || partyIndex >= character.party.length) {
    return { ok: false, error: "That party slot does not exist." };
  }
  if (!Number.isInteger(boxIndex) || boxIndex < 0 || boxIndex >= character.box.length) {
    return { ok: false, error: "That PC slot does not exist." };
  }
  const partyCreature = character.party[partyIndex];
  const boxCreature = character.box[boxIndex];
  character.party[partyIndex] = boxCreature;
  character.box[boxIndex] = partyCreature;
  return { ok: true };
}
