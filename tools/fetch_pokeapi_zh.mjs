#!/usr/bin/env node
/**
 * Build the zh_CN content-name catalog for BWMMO.
 *
 * Species and move IDs in server/content/game.json line up with PokeAPI
 * (`species.dex` and `move.romMoveId`). PokeAPI's GraphQL endpoint can return
 * every zh-hans species/move name in one request, so this script does not
 * need hundreds of individual REST calls. Item names use the REST endpoint
 * because there are only eight items.
 */

import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..");
const GAME_FILE = path.join(ROOT, "server", "content", "game.json");
const OUT_FILE = path.join(ROOT, "server", "content", "i18n", "zh_CN", "names.json");
const CACHE_DIR = path.join(ROOT, ".tools", "pokeapi-cache");
const GRAPHQL_URL = "https://beta.pokeapi.co/graphql/v1beta";
const ZH_HANS_LANGUAGE_ID = 12;

const MANUAL_MAPS = {
  Unova: "合众",
  "Route 1": "1号道路",
  "Whispering Grove": "低语林",
  "Willow Town": "柳镇",
  Interior: "室内",
  "Pokémon Center": "宝可梦中心",
  Laboratory: "研究所",
  Gym: "道馆",
  "Player's House": "玩家家",
  "Player's House 2F": "玩家家 2F",
  "Bianca's House": "白露家",
  "Bianca's House 2F": "白露家 2F",
  "Cheren's House": "黑连家",
  "Cheren's House 2F": "黑连家 2F",
  "Professor Juniper's Lab": "红豆杉博士研究所"
};

const MANUAL_LOCATIONS = {
  "Accumula Town": "唐草镇",
  "Chargestone Cave": "电气石洞穴",
  "Cold Storage": "冷藏仓库",
  "Desert Resort": "沙漠度假地",
  "Dragonspiral Tower": "龙旋塔",
  "Driftveil City": "帆巴市",
  "Giant Chasm": "巨人洞窟",
  "Icirrus City": "雪花市",
  "Lacunosa Town": "涟漪镇",
  "Liberty Garden": "自由庭院",
  "Mistralton City": "吹寄市",
  "Nacrene City": "七宝市",
  "Nimbasa City": "雷文市",
  "Nuvema Town": "诺文镇",
  "Opelucid City": "双龙市",
  "P2 Laboratory": "P2研究所",
  "Pinwheel Forest": "矢车森林",
  "Route 1": "1号道路",
  "Route 2": "2号道路",
  "Route 3": "3号道路",
  "Route 4": "4号道路",
  "Route 5": "5号道路",
  "Route 6": "6号道路",
  "Route 7": "7号道路",
  "Route 8": "8号道路",
  "Route 9": "9号道路",
  "Route 10": "10号道路",
  "Route 11": "11号道路",
  "Route 12": "12号道路",
  "Route 13": "13号道路",
  "Route 14": "14号道路",
  "Route 15": "15号道路",
  "Route 16": "16号道路",
  "Route 17": "17号道路",
  "Route 18": "18号道路",
  "Striaton City": "三曜市",
  "Twist Mountain": "螺旋山",
  "Undella Bay": "丰饶湾",
  "Undella Town": "丰饶镇",
  "Unity Tower": "联合塔"
};

const MANUAL_SHOPS = {
  nuvema_mart: "诺文镇商店"
};

const MANUAL_NPCS = {
  Resident: "居民",
  "Team Plasma": "等离子队",
  "Nurse Joy": "乔伊小姐",
  Bianca: "白露",
  Cheren: "黑连",
  Iris: "艾莉丝",
  Alder: "阿戴克",
  Burgh: "亚堤",
  Ryoku: "琉克",
  Zinzolin: "维奥",
  Bronius: "布朗",
  Cedric: "赛德",
  Giallo: "杰洛",
  Lenora: "芦荟",
  Elesa: "小菊儿",
  Skyla: "风露",
  Mom: "妈妈",
  "Professor Juniper": "红豆杉博士",
  "Ranger Fern": "巡护员蕨",
  "Hiker Milo": "登山男米洛",
  "Nurse Willow": "薇洛护士",
  "Guide Rowan": "向导罗文",
  PC: "PC",
  "Mart Clerk": "商店店员",
  Fennel: "芬妮",
  Amanita: "阿玛尼塔",
  Wye: "怀",
  Aha: "阿哈",
  Ditoh: "迪托",
  Drayden: "夏卡",
  Brycen: "淡竹",
  Koontz: "昆茨",
  Russo: "鲁索",
  Derleth: "德莱斯",
  Gorm: "哥德",
  Rood: "罗德",
  Clay: "亚坤",
  "Bianca's Dad": "白露爸爸",
  "Bianca's Mom": "白露妈妈",
  "Cheren's Dad": "黑连爸爸",
  "Cheren's Mom": "黑连妈妈",
  Pokémon: "宝可梦",
  Cynthia: "竹兰",
  Caitlin: "嘉德丽雅",
  Shauntal: "婉龙",
  Gesundheit: "格松海特"
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function requestJson(url, options = {}, attempts = 4) {
  let lastError;
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 180_000);
      const response = await fetch(url, { ...options, signal: controller.signal });
      clearTimeout(timer);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return await response.json();
    } catch (error) {
      lastError = error;
      await sleep(500 * 2 ** attempt);
    }
  }
  throw new Error(`${url}: ${lastError?.message ?? "request failed"}`);
}

async function graphqlNames() {
  const cacheFile = path.join(CACHE_DIR, "graphql-zh.json");
  try {
    return JSON.parse(await fs.readFile(cacheFile, "utf8"));
  } catch {
    // Not cached yet.
  }
  const query = `{
    species: pokemon_v2_pokemonspeciesname(
      where: {language_id: {_eq: ${ZH_HANS_LANGUAGE_ID}}},
      limit: 1000
    ) { name pokemon_species_id }
    moves: pokemon_v2_movename(
      where: {language_id: {_eq: ${ZH_HANS_LANGUAGE_ID}}},
      limit: 1000
    ) { name move_id }
  }`;
  const json = await requestJson(GRAPHQL_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query })
  });
  if (json.errors?.length) {
    throw new Error(json.errors.map((error) => error.message).join("; "));
  }
  const result = json.data ?? {};
  await fs.mkdir(CACHE_DIR, { recursive: true });
  await fs.writeFile(cacheFile, JSON.stringify(result));
  return result;
}

function zhHansName(entry) {
  const names = Array.isArray(entry?.names) ? entry.names : [];
  const match = names.find(
    (item) => String(item?.language?.name ?? "").toLowerCase() === "zh-hans"
  );
  return typeof match?.name === "string" ? match.name : "";
}

async function itemName(slug) {
  const cacheFile = path.join(CACHE_DIR, "item", `${slug}.json`);
  try {
    const cached = JSON.parse(await fs.readFile(cacheFile, "utf8"));
    return zhHansName(cached);
  } catch {
    // Not cached yet.
  }
  const data = await requestJson(`https://pokeapi.co/api/v2/item/${slug}`);
  await fs.mkdir(path.dirname(cacheFile), { recursive: true });
  await fs.writeFile(cacheFile, JSON.stringify(data));
  return zhHansName(data);
}

async function main() {
  const game = JSON.parse(await fs.readFile(GAME_FILE, "utf8"));
  const raw = await graphqlNames();
  const speciesById = new Map(
    (raw.species ?? []).map((entry) => [entry.pokemon_species_id, entry.name])
  );
  const movesById = new Map(
    (raw.moves ?? []).map((entry) => [entry.move_id, entry.name])
  );

  const missing = [];
  const speciesNames = {};
  for (const species of Object.values(game.species ?? {})) {
    const name = speciesById.get(Number(species.dex));
    if (name) speciesNames[species.id] = name;
    else missing.push(`species ${species.id} (dex ${species.dex})`);
  }

  const moveNames = {};
  for (const move of Object.values(game.moves ?? {})) {
    const name = movesById.get(Number(move.romMoveId));
    if (name) moveNames[move.id] = name;
    else missing.push(`move ${move.id} (romMoveId ${move.romMoveId})`);
  }

  const itemNames = {};
  for (const item of Object.values(game.items ?? {})) {
    const slug = String(item.id).replaceAll("_", "-");
    const name = await itemName(slug);
    if (name) itemNames[item.id] = name;
    else missing.push(`item ${item.id} (${slug})`);
  }

  const mapNames = new Map();
  const npcNames = new Set();
  const mapsDir = path.join(ROOT, "server", "content", "maps");
  for (const file of (await fs.readdir(mapsDir)).filter((name) => name.endsWith(".json"))) {
    const map = JSON.parse(await fs.readFile(path.join(mapsDir, file), "utf8"));
    if (!Array.isArray(map.tiles)) continue;
    if (map.name) mapNames.set(map.id, map.name);
    for (const npc of map.npcs ?? []) {
      if (npc.name) npcNames.add(npc.name);
    }
  }

  const output = {
    locale: "zh_CN",
    source: "PokeAPI zh-hans names plus the project glossary",
    species: speciesNames,
    moves: moveNames,
    items: itemNames,
    locations: MANUAL_LOCATIONS,
    shops: Object.fromEntries(
      Object.values(game.shops ?? {}).map((shop) => [
        shop.id,
        MANUAL_SHOPS[shop.id] ?? shop.name
      ])
    ),
    maps: Object.fromEntries(
      [...mapNames.entries()]
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([id, name]) => [id, MANUAL_MAPS[name] ?? name])
    ),
    npcs: Object.fromEntries(
      [...npcNames].sort().map((name) => [name, MANUAL_NPCS[name] ?? name])
    )
  };

  await fs.mkdir(path.dirname(OUT_FILE), { recursive: true });
  await fs.writeFile(OUT_FILE, JSON.stringify(output, null, 2) + "\n");

  console.log(`species names: ${Object.keys(speciesNames).length}/${Object.keys(game.species ?? {}).length}`);
  console.log(`move names:    ${Object.keys(moveNames).length}/${Object.keys(game.moves ?? {}).length}`);
  console.log(`item names:    ${Object.keys(itemNames).length}/${Object.keys(game.items ?? {}).length}`);
  console.log(`maps:          ${Object.keys(output.maps).length}`);
  console.log(`npcs:          ${Object.keys(output.npcs).length}`);
  if (missing.length) {
    console.warn(`missing names: ${missing.length}`);
    for (const entry of missing.slice(0, 20)) console.warn(`  - ${entry}`);
    if (missing.length > 20) console.warn("  - ...");
  }
  console.log(`wrote ${path.relative(ROOT, OUT_FILE)}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
