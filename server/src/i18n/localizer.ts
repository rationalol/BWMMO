import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { GameContent, MapDef, NpcDef } from "../content/types.js";
import { canonicalAbility, resolveAbilityForSpecies } from "../game/abilities.js";
import type { CharacterState, CreatureState } from "../game/types.js";

interface LocaleNames {
  locale?: string;
  species?: Record<string, string>;
  moves?: Record<string, string>;
  items?: Record<string, string>;
  shops?: Record<string, string>;
  locations?: Record<string, string>;
  maps?: Record<string, string>;
  npcs?: Record<string, string>;
  abilities?: Record<string, string>;
  abilityDescriptions?: Record<string, string>;
}

/** Dialogue blocks keyed by their canonical English text (lines joined). */
interface LocaleDialogue {
  locale?: string;
  dialogues?: Record<string, string[]>;
}

const here = path.dirname(fileURLToPath(import.meta.url));
export const DEFAULT_I18N_DIR = path.resolve(here, "..", "..", "content", "i18n");

/**
 * Resolves display names for game content. The base content keeps canonical
 * English names (and those are what saves store); this class only produces
 * localized copies for outbound client payloads.
 */
export class ContentLocalizer {
  private readonly content: GameContent;
  private readonly locales = new Map<string, LocaleNames>();
  private readonly dialogues = new Map<string, Map<string, string[]>>();

  constructor(content: GameContent, directory: string = DEFAULT_I18N_DIR) {
    this.content = content;
    let entries: fs.Dirent[] = [];
    try {
      entries = fs.readdirSync(directory, { withFileTypes: true });
    } catch {
      return;
    }
    const files: Array<{ file: string; fallbackLocale: string }> = [];
    for (const entry of entries) {
      if (entry.isDirectory()) {
        const namesFile = path.join(directory, entry.name, "names.json");
        if (fs.existsSync(namesFile)) {
          files.push({ file: namesFile, fallbackLocale: entry.name });
        }
        // Manual overrides load after the generated table for the same locale.
        for (const name of ["dialogue.json", "dialogue_manual.json"]) {
          const dialogueFile = path.join(directory, entry.name, name);
          if (fs.existsSync(dialogueFile)) {
            this.loadDialogue(dialogueFile, entry.name);
          }
        }
      } else if (entry.isFile() && entry.name.endsWith(".json")) {
        files.push({
          file: path.join(directory, entry.name),
          fallbackLocale: path.basename(entry.name, ".json")
        });
      }
    }
    for (const { file, fallbackLocale } of files.sort((a, b) => a.file.localeCompare(b.file))) {
      try {
        const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
        if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) continue;
        const data = parsed as LocaleNames;
        const locale = typeof data.locale === "string" ? data.locale : fallbackLocale;
        this.locales.set(locale, data);
      } catch (error) {
        console.warn(`[i18n] could not load ${file}:`, error);
      }
    }
  }

  private loadDialogue(file: string, fallbackLocale: string): void {
    try {
      const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return;
      const data = parsed as LocaleDialogue;
      if (!data.dialogues || typeof data.dialogues !== "object") return;
      const locale = typeof data.locale === "string" ? data.locale : fallbackLocale;
      let table = this.dialogues.get(locale);
      if (!table) {
        table = new Map();
        this.dialogues.set(locale, table);
      }
      for (const [english, lines] of Object.entries(data.dialogues)) {
        if (Array.isArray(lines) && lines.every((line) => typeof line === "string")) {
          table.set(english, lines);
        }
      }
    } catch (error) {
      console.warn(`[i18n] could not load ${file}:`, error);
    }
  }

  speciesName(locale: string, id: string): string {
    return (
      this.locales.get(locale)?.species?.[id] ??
      this.content.species[id]?.name ??
      id
    );
  }

  moveName(locale: string, id: string): string {
    return (
      this.locales.get(locale)?.moves?.[id] ??
      this.content.moves[id]?.name ??
      id
    );
  }

  itemName(locale: string, id: string): string {
    return (
      this.locales.get(locale)?.items?.[id] ??
      this.content.items[id]?.name ??
      id
    );
  }

  mapName(locale: string, id: string): string {
    const localeNames = this.locales.get(locale);
    const canonical = this.content.maps[id]?.name;
    return (
      localeNames?.maps?.[id] ??
      // Indoor maps carry the ROM location name (e.g. "Pinwheel Forest"), so
      // reuse the location table for them as well.
      (canonical ? localeNames?.locations?.[canonical] : undefined) ??
      canonical ??
      id
    );
  }

  shopName(locale: string, id: string): string {
    return (
      this.locales.get(locale)?.shops?.[id] ??
      this.content.shops[id]?.name ??
      id
    );
  }

  npcName(locale: string, name: string): string {
    return this.locales.get(locale)?.npcs?.[name] ?? name;
  }

  abilityName(locale: string, id: string): string {
    return (
      this.locales.get(locale)?.abilities?.[id] ??
      canonicalAbility(id)?.name ??
      id
    );
  }

  abilityDescription(locale: string, id: string): string {
    return (
      this.locales.get(locale)?.abilityDescriptions?.[id] ??
      canonicalAbility(id)?.description ??
      ""
    );
  }

  /**
   * Translates a whole dialogue block. Keys are the canonical English lines
   * joined with newlines: the translated table can reflow a segment into a
   * different number of pages, so it is matched per block, not per line.
   */
  dialogue(locale: string, lines: string[]): string[] {
    if (lines.length === 0) return lines;
    return this.dialogues.get(locale)?.get(lines.join("\n")) ?? lines;
  }

  locationName(locale: string, name: string): string {
    return this.locales.get(locale)?.locations?.[name] ?? name;
  }

  creature(locale: string, creature: CreatureState): CreatureState {
    const species = this.content.species[creature.species];
    // A name that differs from the canonical species name is a nickname and
    // must survive language switches untouched.
    const displayName =
      species && creature.name && creature.name !== species.name
        ? creature.name
        : this.speciesName(locale, creature.species);
    const ability = resolveAbilityForSpecies(
      creature.species,
      creature.ability,
      creature.abilitySlot
    );
    return {
      ...creature,
      name: displayName,
      ability: ability?.id ?? creature.ability,
      abilitySlot: ability?.slot ?? creature.abilitySlot,
      abilityName: ability ? this.abilityName(locale, ability.id) : undefined,
      abilityDescription: ability
        ? this.abilityDescription(locale, ability.id)
        : undefined,
      moves: creature.moves.map((move) => ({
        ...move,
        name: this.moveName(locale, move.id)
      }))
    };
  }

  character(locale: string, character: CharacterState): CharacterState {
    return {
      ...character,
      party: character.party.map((creature) => this.creature(locale, creature)),
      box: character.box.map((creature) => this.creature(locale, creature))
    };
  }

  item<T extends { id: string; name: string }>(locale: string, item: T): T {
    return { ...item, name: this.itemName(locale, item.id) };
  }

  npc(locale: string, npc: NpcDef): NpcDef {
    return { ...npc, name: this.npcName(locale, npc.name) };
  }

  map(locale: string, map: MapDef): MapDef {
    return {
      ...map,
      name: this.mapName(locale, map.id),
      npcs: map.npcs.map((npc) => this.npc(locale, npc))
    };
  }
}
