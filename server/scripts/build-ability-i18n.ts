/**
 * Fill the zh_CN ability name/description tables from PokeAPI.
 *
 * The Gen 5 ability slots come from Showdown's dex (the same source the battle
 * adapter uses), so this only needs to fetch the localized strings. Results are
 * cached in .tools/ability-i18n-cache.json; the generated names.json is the
 * committed source of truth used by the server at runtime.
 *
 * Run from server/:
 *   npx tsx scripts/build-ability-i18n.ts
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { abilityOptionsForSpecies } from "../src/game/abilities.js";
import { loadContent } from "../src/content/loader.js";

interface PokeApiAbility {
  name: string;
  names?: Array<{ name: string; language: { name: string } }>;
  flavor_text_entries?: Array<{
    flavor_text: string;
    language: { name: string };
    version_group: { name: string };
  }>;
}

interface CacheEntry {
  name?: string;
  description?: string;
}

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const namesPath = path.join(root, "content", "i18n", "zh_CN", "names.json");
const cachePath = path.resolve(root, "..", ".tools", "ability-i18n-cache.json");
const API = "https://pokeapi.co/api/v2";

function normalize(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]/g, "");
}

function plainChinese(value: string): string {
  return value.replace(/\s+/g, "");
}

function readCache(): Record<string, CacheEntry> {
  try {
    const parsed = JSON.parse(fs.readFileSync(cachePath, "utf8"));
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

async function fetchJson(url: string): Promise<any> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${response.status} ${response.statusText}: ${url}`);
  return response.json();
}

async function main(): Promise<void> {
  const content = loadContent();
  const abilityNames = new Map<string, string>();
  for (const species of Object.values(content.species)) {
    for (const ability of abilityOptionsForSpecies(species.id)) {
      abilityNames.set(ability.id, ability.name);
    }
  }
  console.log(
    `[ability-i18n] species=${Object.keys(content.species).length} abilities=${abilityNames.size}`
  );

  const list = (await fetchJson(`${API}/ability?limit=400`)) as {
    results: Array<{ name: string; url: string }>;
  };
  const byNormalized = new Map<string, { name: string; url: string }>();
  for (const entry of list.results) byNormalized.set(normalize(entry.name), entry);

  const cache = readCache();
  const abilities: Record<string, string> = {};
  const descriptions: Record<string, string> = {};
  const missing: string[] = [];
  let fetched = 0;
  for (const [abilityId, display] of [...abilityNames].sort((a, b) =>
    a[0].localeCompare(b[0])
  )) {
    const cached = cache[abilityId];
    if (cached?.name) {
      abilities[abilityId] = cached.name;
      if (cached.description) descriptions[abilityId] = cached.description;
      continue;
    }
    const entry =
      byNormalized.get(normalize(display)) ??
      byNormalized.get(normalize(abilityId));
    if (!entry) {
      missing.push(abilityId);
      continue;
    }
    try {
      const data = (await fetchJson(entry.url)) as PokeApiAbility;
      const zhName =
        data.names?.find((item) => item.language.name === "zh-hans")?.name ?? "";
      const zhEntries =
        data.flavor_text_entries?.filter(
          (item) => item.language.name === "zh-hans"
        ) ?? [];
      const gen5 = zhEntries.find((item) =>
        ["black-white", "black-2-white-2"].includes(item.version_group.name)
      );
      const chosen = gen5 ?? zhEntries[zhEntries.length - 1];
      const description = chosen ? plainChinese(chosen.flavor_text) : "";
      if (!zhName || !description) {
        missing.push(abilityId);
        continue;
      }
      abilities[abilityId] = zhName;
      descriptions[abilityId] = description;
      cache[abilityId] = { name: zhName, description };
      fetched += 1;
      if (fetched % 20 === 0) {
        console.log(`[ability-i18n] fetched ${fetched}`);
        fs.writeFileSync(cachePath, `${JSON.stringify(cache, null, 2)}\n`);
      }
      await new Promise((resolve) => setTimeout(resolve, 60));
    } catch (error) {
      console.warn(`[ability-i18n] ${abilityId}:`, String(error));
      missing.push(abilityId);
    }
  }
  fs.mkdirSync(path.dirname(cachePath), { recursive: true });
  fs.writeFileSync(cachePath, `${JSON.stringify(cache, null, 2)}\n`);

  if (missing.length > 0) {
    console.error(`[ability-i18n] missing translations: ${missing.join(", ")}`);
    process.exitCode = 1;
    return;
  }

  const source = JSON.parse(fs.readFileSync(namesPath, "utf8"));
  source.abilities = abilities;
  source.abilityDescriptions = descriptions;
  fs.writeFileSync(namesPath, `${JSON.stringify(source, null, 2)}\n`);
  console.log(
    `[ability-i18n] wrote ${namesPath} (${Object.keys(abilities).length} abilities)`
  );
}

await main();
