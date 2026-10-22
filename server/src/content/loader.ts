import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { validateMaps } from "../game/maps.js";
import type {
  EncounterDef,
  GameConfig,
  GameContent,
  ItemDef,
  MapDef,
  MoveDef,
  RawMapDef,
  ShopDef,
  SpeciesDef
} from "./types.js";

const here = path.dirname(fileURLToPath(import.meta.url));
export const DEFAULT_CONTENT_DIR = path.resolve(here, "..", "..", "content");

const VALID_TYPES = new Set([
  "Normal",
  "Fighting",
  "Flying",
  "Poison",
  "Ground",
  "Rock",
  "Bug",
  "Ghost",
  "Steel",
  "Fire",
  "Water",
  "Grass",
  "Electric",
  "Psychic",
  "Ice",
  "Dragon",
  "Dark"
]);

interface RawGame {
  version?: number;
  config?: Partial<GameConfig>;
  moves?: Record<string, MoveDef>;
  species?: Record<string, SpeciesDef>;
  items?: Record<string, ItemDef>;
  shops?: Record<string, ShopDef>;
  starters?: string[];
}

function readJson(file: string): unknown {
  let raw: string;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch (error) {
    throw new Error(`Could not read content file ${file}: ${String(error)}`);
  }
  try {
    return JSON.parse(raw);
  } catch (error) {
    throw new Error(`Invalid JSON in ${file}: ${String(error)}`);
  }
}

export function loadContent(directory: string = DEFAULT_CONTENT_DIR): GameContent {
  const gameFile = path.join(directory, "game.json");
  const rawGame = readJson(gameFile);
  if (!rawGame || typeof rawGame !== "object" || Array.isArray(rawGame)) {
    throw new Error(`${gameFile} must contain a JSON object`);
  }
  const game = rawGame as RawGame;

  const maps: Record<string, MapDef> = {};
  const mapsDir = path.join(directory, "maps");
  let mapFiles: string[] = [];
  try {
    mapFiles = fs.readdirSync(mapsDir).filter((file) => file.endsWith(".json")).sort();
  } catch (error) {
    throw new Error(`Could not read maps directory ${mapsDir}: ${String(error)}`);
  }

  const structuralErrors: string[] = [];
  for (const file of mapFiles) {
    const rawMap = readJson(path.join(mapsDir, file));
    if (!rawMap || typeof rawMap !== "object" || Array.isArray(rawMap)) {
      structuralErrors.push(`maps/${file}: must contain a JSON object`);
      continue;
    }
    const map = rawMap as RawMapDef;
    if (!Array.isArray(map.tiles) || map.tiles.some((row) => typeof row !== "string")) {
      structuralErrors.push(`maps/${file}: tiles must be an array of strings`);
      continue;
    }
    if (maps[map.id]) {
      structuralErrors.push(`maps/${file}: duplicate map id '${map.id}'`);
      continue;
    }
    maps[map.id] = {
      ...map,
      width: map.tiles[0]?.length ?? 0,
      height: map.tiles.length
    };
  }

  const content: GameContent = {
    version: game.version ?? 1,
    config: game.config as GameConfig,
    moves: game.moves ?? {},
    species: game.species ?? {},
    items: game.items ?? {},
    shops: game.shops ?? {},
    starters: game.starters ?? [],
    maps
  };

  const errors = [...structuralErrors, ...validateContent(content)];
  if (errors.length > 0) {
    throw new Error(`Invalid game content:\n- ${errors.join("\n- ")}`);
  }
  return content;
}

export function validateContent(content: GameContent): string[] {
  const errors: string[] = [];
  const config = content.config;
  if (!config || typeof config !== "object") {
    return ["game.json: missing config"];
  }
  for (const key of [
    "maxParty",
    "maxBox",
    "startingMoney",
    "startingBalls",
    "winReward",
    "catchXpFactor",
    "xpLevelBase",
    "xpLevelGrowth"
  ] as const) {
    const value = config[key];
    if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
      errors.push(`config.${key} must be a non-negative number`);
    }
  }
  if (config.maxParty < 1 || config.maxParty > 6) {
    errors.push("config.maxParty must be 1..6");
  }
  if (!Number.isInteger(config.maxBox) || config.maxBox < 1 || config.maxBox > 600) {
    errors.push("config.maxBox must be an integer 1..600");
  }
  if (typeof config.startingMap !== "string" || !content.maps[config.startingMap]) {
    errors.push("config.startingMap must name an existing map");
  }
  if (config.catchXpFactor < 0 || config.catchXpFactor > 1) {
    errors.push("config.catchXpFactor must be 0..1");
  }
  if (!Number.isInteger(config.startingBalls) || config.startingBalls > 99) {
    errors.push("config.startingBalls must be an integer 0..99");
  }
  if (config.startingBalls > 0 && !content.items.poke_ball) {
    errors.push("config.startingBalls requires an item with id 'poke_ball'");
  }
  if (config.startingItems !== undefined) {
    if (
      !config.startingItems ||
      typeof config.startingItems !== "object" ||
      Array.isArray(config.startingItems)
    ) {
      errors.push("config.startingItems must be an object of item id -> count");
    } else {
      for (const [itemId, count] of Object.entries(config.startingItems)) {
        if (!content.items[itemId]) {
          errors.push(`config.startingItems references unknown item '${itemId}'`);
        }
        if (!Number.isInteger(count) || count < 0) {
          errors.push(`config.startingItems.${itemId} must be a non-negative integer`);
        }
      }
    }
  }

  const ITEM_CATEGORIES = new Set(["ball", "medicine", "key"]);
  for (const [id, item] of Object.entries(content.items)) {
    if (item.id !== id) errors.push(`item '${id}': id field must match its key`);
    if (typeof item.name !== "string" || item.name.length === 0) {
      errors.push(`item '${id}': name is required`);
    }
    if (!ITEM_CATEGORIES.has(item.category)) {
      errors.push(`item '${id}': invalid category '${item.category}'`);
    }
    if (!Number.isInteger(item.price) || item.price < 0) {
      errors.push(`item '${id}': price must be a non-negative integer`);
    }
    if (typeof item.description !== "string" || item.description.length === 0) {
      errors.push(`item '${id}': description is required`);
    }
    if (typeof item.icon !== "string" || item.icon.length === 0) {
      errors.push(`item '${id}': icon is required`);
    }
    if (item.category === "ball") {
      if (!(typeof item.ballBonus === "number" && item.ballBonus > 0)) {
        errors.push(`item '${id}': balls need a positive ballBonus`);
      }
    } else if (item.category === "medicine") {
      const heals = typeof item.heal === "number" && item.heal > 0;
      if (!heals && item.cureStatus !== true && item.revive !== true) {
        errors.push(`item '${id}': medicine needs heal, cureStatus or revive`);
      }
      if (item.heal !== undefined && !(item.heal > 0)) {
        errors.push(`item '${id}': heal must be > 0 when present`);
      }
    }
  }

  for (const [id, shop] of Object.entries(content.shops)) {
    if (shop.id !== id) errors.push(`shop '${id}': id field must match its key`);
    if (typeof shop.name !== "string" || shop.name.length === 0) {
      errors.push(`shop '${id}': name is required`);
    }
    if (!Array.isArray(shop.items) || shop.items.length === 0) {
      errors.push(`shop '${id}': items must not be empty`);
      continue;
    }
    const seenItems = new Set<string>();
    for (const itemId of shop.items) {
      if (!content.items[itemId]) errors.push(`shop '${id}': unknown item '${itemId}'`);
      if (seenItems.has(itemId)) errors.push(`shop '${id}': duplicate item '${itemId}'`);
      seenItems.add(itemId);
    }
  }

  for (const [id, move] of Object.entries(content.moves)) {
    if (move.id !== id) errors.push(`move '${id}': id field must match its key`);
    if (!VALID_TYPES.has(move.type)) errors.push(`move '${id}': invalid type '${move.type}'`);
    if (typeof move.name !== "string" || move.name.length === 0) {
      errors.push(`move '${id}': name is required`);
    }
    if (
      !(move.power >= 0) ||
      !(move.accuracy === 0 || (move.accuracy >= 1 && move.accuracy <= 100))
    ) {
      errors.push(`move '${id}': power must be >= 0 and accuracy must be 0 or 1..100`);
    }
    if (!Number.isInteger(move.priority)) errors.push(`move '${id}': priority must be an integer`);
    if (
      move.pp !== undefined &&
      (!Number.isInteger(move.pp) || move.pp < 1)
    ) {
      errors.push(`move '${id}': pp must be a positive integer`);
    }
    if (
      move.romMoveId !== undefined &&
      (!Number.isInteger(move.romMoveId) || move.romMoveId < 1)
    ) {
      errors.push(`move '${id}': romMoveId must be a positive integer`);
    }
  }

  if (content.starters.length === 0) errors.push("starters must not be empty");
  for (const starter of content.starters) {
    if (!content.species[starter]) errors.push(`starter '${starter}' does not exist`);
  }

  for (const [id, species] of Object.entries(content.species)) {
    if (species.id !== id) errors.push(`species '${id}': id field must match its key`);
    if (typeof species.name !== "string" || species.name.length === 0) {
      errors.push(`species '${id}': name is required`);
    }
    if (!Number.isInteger(species.dex) || species.dex < 1) {
      errors.push(`species '${id}': dex must be a positive integer`);
    }
    if (!Array.isArray(species.types) || species.types.length === 0) {
      errors.push(`species '${id}': at least one type is required`);
    } else {
      for (const type of species.types) {
        if (!VALID_TYPES.has(type)) errors.push(`species '${id}': invalid type '${type}'`);
      }
    }
    for (const stat of ["baseHp", "baseAtk", "baseDef", "baseSpAtk", "baseSpDef", "baseSpeed", "baseXp"] as const) {
      if (!(species[stat] > 0)) errors.push(`species '${id}': ${stat} must be > 0`);
    }
    if (!(species.catchRate > 0 && species.catchRate <= 1)) {
      errors.push(`species '${id}': catchRate must be 0..1`);
    }
    if (!Array.isArray(species.learnset) || species.learnset.length === 0) {
      errors.push(`species '${id}': learnset must not be empty`);
      continue;
    }
    let hasLevelOneMove = false;
    for (const entry of species.learnset) {
      if (!Number.isInteger(entry.level) || entry.level < 1) {
        errors.push(`species '${id}': learnset level must be a positive integer`);
      }
      if (entry.level === 1) hasLevelOneMove = true;
      if (!content.moves[entry.move]) {
        errors.push(`species '${id}': unknown move '${entry.move}'`);
      }
    }
    if (!hasLevelOneMove) errors.push(`species '${id}': needs a level-1 move`);

    const EVOLUTION_METHODS = new Set([
      "level",
      "useItem",
      "trade",
      "levelFriendship",
      "levelMove",
      "levelHold",
      "levelExtra"
    ]);
    if (!Array.isArray(species.evolutions)) {
      errors.push(`species '${id}': evolutions must be an array`);
    } else {
      const targets = new Set<string>();
      for (const evolution of species.evolutions) {
        if (!evolution || typeof evolution !== "object") {
          errors.push(`species '${id}': invalid evolution entry`);
          continue;
        }
        if (typeof evolution.to !== "string" || !content.species[evolution.to]) {
          errors.push(`species '${id}': evolution target '${evolution.to}' does not exist`);
        } else if (targets.has(evolution.to)) {
          errors.push(`species '${id}': duplicate evolution target '${evolution.to}'`);
        } else {
          targets.add(evolution.to);
        }
        if (!EVOLUTION_METHODS.has(evolution.method)) {
          errors.push(`species '${id}': invalid evolution method '${evolution.method}'`);
        }
        if (
          evolution.level !== undefined &&
          (!Number.isInteger(evolution.level) || evolution.level < 1)
        ) {
          errors.push(`species '${id}': evolution level must be a positive integer`);
        }
        if (
          evolution.move !== undefined &&
          !content.moves[evolution.move]
        ) {
          errors.push(`species '${id}': evolution move '${evolution.move}' does not exist`);
        }
        if (
          evolution.gender !== undefined &&
          evolution.gender !== "male" &&
          evolution.gender !== "female"
        ) {
          errors.push(`species '${id}': invalid evolution gender`);
        }
      }
    }
  }

  const dexes = new Set<number>();
  for (const species of Object.values(content.species)) {
    if (Number.isInteger(species.dex)) {
      if (dexes.has(species.dex)) {
        errors.push(`duplicate national dex number ${species.dex}`);
      }
      dexes.add(species.dex);
    }
  }

  errors.push(...validateMaps(content.maps));

  const checkEncounter = (mapId: string, label: string, encounter?: EncounterDef) => {
    if (!encounter) return;
    if (!(encounter.rate >= 0 && encounter.rate <= 1)) {
      errors.push(`${mapId}: ${label} rate must be 0..1`);
    }
    if (!Array.isArray(encounter.table) || encounter.table.length === 0) {
      errors.push(`${mapId}: ${label} table is empty`);
      return;
    }
    let totalWeight = 0;
    for (const entry of encounter.table) {
      totalWeight += entry.weight;
      if (!content.species[entry.species]) {
        errors.push(`${mapId}: ${label} species '${entry.species}' does not exist`);
      }
      if (
        !Number.isInteger(entry.minLevel) ||
        !Number.isInteger(entry.maxLevel) ||
        entry.minLevel < 1 ||
        entry.maxLevel < entry.minLevel
      ) {
        errors.push(`${mapId}: ${label} invalid encounter levels for '${entry.species}'`);
      }
      if (!(entry.weight > 0)) {
        errors.push(`${mapId}: ${label} weight for '${entry.species}' must be > 0`);
      }
    }
    if (totalWeight <= 0) errors.push(`${mapId}: ${label} table has no weight`);
  };

  for (const map of Object.values(content.maps)) {
    checkEncounter(map.id, "encounter", map.encounter);
    const NPC_KINDS = new Set(["healer", "guide", "npc", "shop", "pc"]);
    for (const npc of map.npcs) {
      if (!NPC_KINDS.has(npc.kind)) {
        errors.push(`${map.id}: npc '${npc.id}' has invalid kind '${npc.kind}'`);
        continue;
      }
      if (npc.kind === "shop") {
        if (typeof npc.shopId !== "string" || !content.shops[npc.shopId]) {
          errors.push(`${map.id}: shop npc '${npc.id}' needs a valid shopId`);
        }
      } else if (npc.shopId !== undefined) {
        errors.push(`${map.id}: npc '${npc.id}' has shopId but kind '${npc.kind}'`);
      }
    }
    const zones = map.encounterZones ?? [];
    if (!Array.isArray(zones)) {
      errors.push(`${map.id}: encounterZones must be an array`);
      continue;
    }
    const ids = new Set<string>();
    for (const zone of zones) {
      const label = `zone '${zone.id}'`;
      if (typeof zone.id !== "string" || zone.id.length === 0) {
        errors.push(`${map.id}: encounter zone is missing an id`);
        continue;
      }
      if (ids.has(zone.id)) errors.push(`${map.id}: duplicate encounter zone '${zone.id}'`);
      ids.add(zone.id);
      if (typeof zone.name !== "string" || zone.name.length === 0) {
        errors.push(`${map.id}: ${label} is missing a name`);
      }
      if (
        !Number.isInteger(zone.x) ||
        !Number.isInteger(zone.y) ||
        !Number.isInteger(zone.width) ||
        !Number.isInteger(zone.height) ||
        zone.width <= 0 ||
        zone.height <= 0 ||
        zone.x < 0 ||
        zone.y < 0 ||
        zone.x + zone.width > map.width ||
        zone.y + zone.height > map.height
      ) {
        errors.push(`${map.id}: ${label} has invalid bounds`);
      }
      checkEncounter(map.id, label, zone);
    }
    for (let i = 0; i < zones.length; i++) {
      for (let j = i + 1; j < zones.length; j++) {
        const a = zones[i];
        const b = zones[j];
        if (
          a.x < b.x + b.width &&
          b.x < a.x + a.width &&
          a.y < b.y + b.height &&
          b.y < a.y + a.height
        ) {
          errors.push(`${map.id}: encounter zones '${a.id}' and '${b.id}' overlap`);
        }
      }
    }

    if (map.visual) {
      const visual = map.visual;
      if (
        !Number.isFinite(visual.originX) ||
        !Number.isFinite(visual.originZ) ||
        !(visual.tile > 0) ||
        !(visual.cellSize > 0)
      ) {
        errors.push(`${map.id}: visual origin/tile/cellSize is invalid`);
      }
      if (!Array.isArray(visual.chunks) || visual.chunks.length === 0) {
        errors.push(`${map.id}: visual chunks must not be empty`);
      } else {
        const cells = new Set<string>();
        const assets = new Set<string>();
        const maxCellX = Math.ceil(map.width / Math.max(1, visual.cellSize));
        const maxCellY = Math.ceil(map.height / Math.max(1, visual.cellSize));
        for (const chunk of visual.chunks) {
          if (typeof chunk.asset !== "string" || chunk.asset.length === 0) {
            errors.push(`${map.id}: visual chunk is missing an asset id`);
          } else if (assets.has(chunk.asset)) {
            errors.push(`${map.id}: duplicate visual chunk asset '${chunk.asset}'`);
          }
          assets.add(chunk.asset);
          const rawCellX = chunk.cellX;
          const rawCellY = chunk.cellY ?? chunk.cell;
          const cellX = Number.isInteger(rawCellX) ? (rawCellX as number) : 0;
          const cellY = Number.isInteger(rawCellY) ? (rawCellY as number) : -1;
          if (
            !Number.isInteger(cellX) ||
            !Number.isInteger(cellY) ||
            cellX < 0 ||
            cellY < 0 ||
            cellX >= maxCellX ||
            cellY >= maxCellY
          ) {
            errors.push(
              `${map.id}: visual chunk cell ${cellX},${cellY} is out of range`
            );
          } else if (cells.has(`${cellX},${cellY}`)) {
            errors.push(`${map.id}: duplicate visual chunk cell ${cellX},${cellY}`);
          }
          cells.add(`${cellX},${cellY}`);
          if (!Number.isFinite(chunk.offsetX) || !Number.isFinite(chunk.offsetZ)) {
            errors.push(`${map.id}: visual chunk '${chunk.asset}' has invalid offsets`);
          }
        }
      }
    }
  }

  return errors;
}
