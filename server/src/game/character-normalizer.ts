import type { GameContent } from "../content/types.js";
import {
  DEFAULT_FRIENDSHIP,
  MAX_FRIENDSHIP,
  createStarter,
  emptyEvBlock,
  genderForDex,
  movesForLevel,
  normalizeCreatureProgress,
  normalizeEvBlock,
  randomIvBlock,
  randomNature,
  recalculateCreatureStats,
  xpToNext
} from "./creatures.js";
import { MAX_STACK, buildStartingInventory } from "./items.js";
import { normalizePokedex } from "./pokedex.js";
import type { CharacterState, PType } from "./types.js";

/**
 * Repair characters written by older server versions. Every migration is
 * idempotent; the return value says whether the caller should persist the
 * character again.
 */
export function normalizeCharacter(content: GameContent, character: CharacterState): boolean {
  let changed = false;
  if (!Number.isInteger(character.sprite) || character.sprite < 0) {
    character.sprite = 0;
    changed = true;
  }
  if (!character.inventory || typeof character.inventory !== "object") {
    character.inventory = buildStartingInventory(content);
    changed = true;
  } else {
    const legacy = character.inventory as unknown as {
      balls?: number;
      items?: Record<string, number>;
    };
    if (!legacy.items || typeof legacy.items !== "object" || Array.isArray(legacy.items)) {
      // Pre-item saves only tracked a single Proto Ball counter.
      const items: Record<string, number> = {};
      const balls = typeof legacy.balls === "number" ? Math.max(0, Math.floor(legacy.balls)) : 0;
      if (balls > 0) items.poke_ball = Math.min(MAX_STACK, balls);
      legacy.items = items;
      changed = true;
    }
    const items = legacy.items;
    for (const [itemId, count] of Object.entries(items)) {
      if (!content.items[itemId] || !Number.isInteger(count) || count <= 0) {
        delete items[itemId];
        changed = true;
      } else if (count > MAX_STACK) {
        items[itemId] = MAX_STACK;
        changed = true;
      }
    }
    if ("balls" in legacy) {
      delete (legacy as { balls?: number }).balls;
      changed = true;
    }
    character.inventory = { items };
  }
  if (!Array.isArray(character.box)) {
    character.box = [];
    changed = true;
  }
  if (character.box.length > content.config.maxBox) {
    character.box = character.box.slice(0, content.config.maxBox);
    changed = true;
  }
  if (
    !character.storyFlags ||
    typeof character.storyFlags !== "object" ||
    Array.isArray(character.storyFlags)
  ) {
    character.storyFlags = {};
    changed = true;
  }
  if (!Array.isArray(character.friends)) {
    character.friends = [];
    changed = true;
  } else {
    const friends = [...new Set(character.friends.filter((id) => typeof id === "string" && id))];
    if (friends.length !== character.friends.length) {
      character.friends = friends;
      changed = true;
    }
  }
  if (!Array.isArray(character.party) || character.party.length === 0) {
    // Story-managed characters start with an empty party: the opening scene
    // hands out the first partner. Saves from before the story layer keep the
    // old safety net so nobody is left unable to play.
    const storyManaged =
      content.story !== undefined &&
      character.storyFlags?.["prologue.starterChosen"] !== undefined;
    character.party = storyManaged ? [] : [createStarter(content, content.starters[0])];
    changed = true;
  }
  if (character.party.length > content.config.maxParty) {
    character.party = character.party.slice(0, content.config.maxParty);
    changed = true;
  }
  for (const creature of [...character.party, ...character.box]) {
    const legacy = creature as unknown as { type?: PType };
    if (!Array.isArray(creature.types) || creature.types.length === 0) {
      creature.types = legacy.type ? [legacy.type] : ["Normal"];
      changed = true;
    }
    if (!Number.isFinite(creature.xp)) {
      creature.xp = 0;
      changed = true;
    }
    const species = content.species[creature.species];
    if (!creature.gender) {
      creature.gender = genderForDex(species?.dex ?? 0);
      changed = true;
    }
    if (!creature.ivs) {
      creature.ivs = randomIvBlock();
      changed = true;
    }
    if (!creature.evs) {
      creature.evs = emptyEvBlock();
      changed = true;
    } else if (normalizeEvBlock(creature.evs)) {
      changed = true;
    }
    if (!creature.nature) {
      creature.nature = randomNature();
      changed = true;
    }
    if (species) {
      // Derived stats may predate this save format (IVs/EVs/nature were once
      // cosmetic); recompute them so the client and Showdown agree.
      const before = [
        creature.hp,
        creature.maxHp,
        creature.atk,
        creature.def,
        creature.spAtk,
        creature.spDef,
        creature.speed
      ];
      const stats = recalculateCreatureStats(species, creature);
      const after = [
        creature.hp,
        creature.maxHp,
        stats.atk,
        stats.def,
        stats.spAtk,
        stats.spDef,
        stats.speed
      ];
      if (before.some((value, index) => value !== after[index])) changed = true;
    }
    if (!("heldItem" in creature)) {
      creature.heldItem = null;
      changed = true;
    }
    if (creature.friendship === undefined || !Number.isFinite(creature.friendship)) {
      creature.friendship = DEFAULT_FRIENDSHIP;
      changed = true;
    } else {
      const clamped = Math.max(
        0,
        Math.min(MAX_FRIENDSHIP, Math.floor(creature.friendship))
      );
      if (clamped !== creature.friendship) {
        creature.friendship = clamped;
        changed = true;
      }
    }
    if (!Number.isFinite(creature.xpToNext)) {
      creature.xpToNext = xpToNext(content, creature.level);
      changed = true;
    }
    if (typeof creature.baseXp !== "number") {
      creature.baseXp = species?.baseXp ?? 10;
      changed = true;
    }
    if (typeof creature.catchRate !== "number") {
      creature.catchRate = species?.catchRate ?? 0.5;
      changed = true;
    }
    if (!creature.name) {
      creature.name = species?.name ?? "Partner";
      changed = true;
    }
    if (!Array.isArray(creature.moves) || creature.moves.length === 0) {
      creature.moves = species ? movesForLevel(content, species, creature.level) : [];
      changed = true;
    }
    if (normalizeCreatureProgress(content, creature)) changed = true;
  }
  if (normalizePokedex(content, character)) changed = true;
  return changed;
}
