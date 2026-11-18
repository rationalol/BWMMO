import { Dex } from "@pkmn/sim";

/**
 * Gen 5 ability slots. The server persists the Showdown ability id plus the
 * slot (0/1 normal, 2 hidden) so a species with two legal abilities keeps the
 * player's choice instead of silently reverting to the first one.
 */
export interface AbilityOption {
  id: string;
  name: string;
  /** Canonical English short description from Showdown. */
  description: string;
  slot: number;
  hidden: boolean;
}

const gen5 = Dex.forGen(5);

function showdownId(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]/g, "");
}

export function canonicalAbility(id: string): AbilityOption | null {
  if (!id) return null;
  const ability = gen5.abilities.get(showdownId(id));
  if (!ability?.id || !ability.name) return null;
  return {
    id: ability.id,
    name: ability.name,
    description: ability.shortDesc ?? ability.desc ?? "",
    slot: -1,
    hidden: false
  };
}

export function abilityOptionsForSpecies(speciesId: string): AbilityOption[] {
  const species = gen5.species.get(showdownId(speciesId));
  if (!species?.abilities) return [];
  const byId = new Map<string, AbilityOption>();
  for (const [key, rawName] of Object.entries(species.abilities)) {
    if (typeof rawName !== "string" || rawName === "") continue;
    const info = canonicalAbility(rawName);
    if (!info) continue;
    const hidden = key === "H";
    const slot = hidden ? 2 : Number(key);
    const current = byId.get(info.id);
    // A few species list the same ability in both normal slots. Show it once,
    // preferring the non-hidden slot so the UI does not offer duplicates.
    if (
      !current ||
      (current.hidden && !hidden) ||
      (current.hidden === hidden && slot < current.slot)
    ) {
      byId.set(info.id, { ...info, slot, hidden });
    }
  }
  return [...byId.values()].sort((a, b) => a.slot - b.slot);
}

export function defaultAbilityForSpecies(speciesId: string): AbilityOption | null {
  return abilityOptionsForSpecies(speciesId)[0] ?? null;
}

/** Resolve a stored choice against the current species, falling back to slot 0. */
export function resolveAbilityForSpecies(
  speciesId: string,
  abilityId?: string,
  abilitySlot?: number
): AbilityOption | null {
  const options = abilityOptionsForSpecies(speciesId);
  if (options.length === 0) return null;
  if (abilityId) {
    const byId = options.find((option) => option.id === showdownId(abilityId));
    // An unrecognised id must not silently select a hidden slot from stale
    // data; missing/legacy saves without an id can still fall back by slot.
    return byId ?? options[0];
  }
  if (Number.isInteger(abilitySlot)) {
    const bySlot = options.find((option) => option.slot === abilitySlot);
    if (bySlot) return bySlot;
  }
  return options[0];
}

/** Apply the canonical ability id/slot pair to a stored creature. */
export function assignAbility(
  target: { species: string; ability?: string; abilitySlot?: number },
  preferredId?: string,
  preferredSlot?: number
): AbilityOption | null {
  const resolved = resolveAbilityForSpecies(
    target.species,
    preferredId ?? target.ability,
    preferredSlot ?? target.abilitySlot
  );
  if (!resolved) return null;
  target.ability = resolved.id;
  target.abilitySlot = resolved.slot;
  return resolved;
}
