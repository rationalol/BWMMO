import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { GameContent, MapDef, NpcDef } from "../content/types.js";
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
    return (
      this.locales.get(locale)?.maps?.[id] ??
      this.content.maps[id]?.name ??
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
    return {
      ...creature,
      name: displayName,
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
