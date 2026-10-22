import type { GameContent } from "../content/types.js";
import type { CharacterState, PokedexState } from "./types.js";

function sortedNumbers(values: Iterable<number>): number[] {
  return [...new Set(values)].sort((a, b) => a - b);
}

export function emptyPokedex(): PokedexState {
  return { seen: [], caught: [] };
}

function validDexNumbers(content: GameContent): Set<number> {
  return new Set(Object.values(content.species).map((species) => species.dex));
}

/**
 * Repairs older saves and fills the registry from everything the trainer owns.
 * Returns true when the character should be persisted.
 */
export function normalizePokedex(
  content: GameContent,
  character: CharacterState
): boolean {
  const valid = validDexNumbers(content);
  let changed = false;
  const current = character.pokedex;
  if (
    !current ||
    !Array.isArray(current.seen) ||
    !Array.isArray(current.caught)
  ) {
    character.pokedex = emptyPokedex();
    changed = true;
  }
  const raw = character.pokedex!;
  const seen = sortedNumbers(
    raw.seen.filter(
      (dex) => Number.isInteger(dex) && valid.has(dex)
    )
  );
  const caught = sortedNumbers(
    raw.caught.filter(
      (dex) => Number.isInteger(dex) && valid.has(dex)
    )
  );
  if (
    seen.length !== raw.seen.length ||
    caught.length !== raw.caught.length ||
    seen.some((dex, index) => dex !== raw.seen[index]) ||
    caught.some((dex, index) => dex !== raw.caught[index])
  ) {
    changed = true;
  }

  const seenSet = new Set(seen);
  const caughtSet = new Set(caught);
  for (const creature of [...character.party, ...character.box]) {
    const species = content.species[creature.species];
    if (!species) continue;
    if (!seenSet.has(species.dex)) {
      seenSet.add(species.dex);
      changed = true;
    }
    if (!caughtSet.has(species.dex)) {
      caughtSet.add(species.dex);
      changed = true;
    }
  }
  character.pokedex = {
    seen: sortedNumbers(seenSet),
    caught: sortedNumbers(caughtSet)
  };
  return changed;
}

function mark(
  content: GameContent,
  character: CharacterState,
  speciesId: string,
  key: "seen" | "caught"
): boolean {
  const species = content.species[speciesId];
  if (!species) return false;
  const dex = species.dex;
  const state = character.pokedex ?? emptyPokedex();
  character.pokedex = state;
  if (key === "caught" && !state.seen.includes(dex)) {
    state.seen.push(dex);
    state.seen.sort((a, b) => a - b);
  }
  if (state[key].includes(dex)) return false;
  state[key].push(dex);
  state[key].sort((a, b) => a - b);
  return true;
}

export function markSpeciesSeen(
  content: GameContent,
  character: CharacterState,
  speciesId: string
): boolean {
  return mark(content, character, speciesId, "seen");
}

export function markSpeciesCaught(
  content: GameContent,
  character: CharacterState,
  speciesId: string
): boolean {
  return mark(content, character, speciesId, "caught");
}
