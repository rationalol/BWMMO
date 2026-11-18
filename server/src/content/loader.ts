import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { isWalkable, validateMaps } from "../game/maps.js";
import type {
  EncounterDef,
  GameConfig,
  GameContent,
  ItemDef,
  MapDef,
  MoveDef,
  RawMapDef,
  ShopDef,
  SpeciesDef,
  StoryCondition,
  StoryContent,
  StoryStepDef
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

/**
 * Read every optional story pack. Each pack is merged into one layer so a
 * later chapter can be added without touching the server code.
 */
function loadStory(directory: string): StoryContent | undefined {
  const storyDir = path.join(directory, "story");
  let files: string[] = [];
  try {
    files = fs.readdirSync(storyDir).filter((file) => file.endsWith(".json")).sort();
  } catch {
    return undefined;
  }
  if (files.length === 0) return undefined;

  const merged: StoryContent = {
    version: 1,
    startMap: undefined,
    initialFlags: {},
    scenes: {},
    trainers: {},
    npcs: [],
    interactions: [],
    triggers: [],
    gates: [],
    onEnter: []
  };

  for (const file of files) {
    const raw = readJson(path.join(storyDir, file));
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new Error(`story/${file} must contain a JSON object`);
    }
    const pack = raw as Partial<StoryContent>;
    if (pack.version !== undefined) merged.version = pack.version;
    if (pack.startMap !== undefined) merged.startMap = pack.startMap;
    Object.assign(merged.initialFlags!, pack.initialFlags ?? {});
    for (const [id, scene] of Object.entries(pack.scenes ?? {})) {
      if (merged.scenes[id]) throw new Error(`story/${file}: duplicate scene '${id}'`);
      merged.scenes[id] = scene;
    }
    for (const [id, trainer] of Object.entries(pack.trainers ?? {})) {
      if (merged.trainers![id]) {
        throw new Error(`story/${file}: duplicate trainer '${id}'`);
      }
      merged.trainers![id] = trainer;
    }
    merged.npcs.push(...(pack.npcs ?? []));
    merged.interactions.push(...(pack.interactions ?? []));
    merged.triggers.push(...(pack.triggers ?? []));
    merged.gates.push(...(pack.gates ?? []));
    merged.onEnter.push(...(pack.onEnter ?? []));
  }
  return merged;
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

  const story = loadStory(directory);
  const content: GameContent = {
    version: game.version ?? 1,
    config: game.config as GameConfig,
    moves: game.moves ?? {},
    species: game.species ?? {},
    items: game.items ?? {},
    shops: game.shops ?? {},
    starters: game.starters ?? [],
    maps,
    story
  };

  // Story-owned NPCs become ordinary map entities so collision, interaction
  // and the client NPC list all share one code path. Per-player visibility is
  // applied at snapshot time through each NPC's `visibleWhen` condition.
  for (const npc of story?.npcs ?? []) {
    const map = maps[npc.mapId];
    if (map) map.npcs.push(npc);
  }

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

  const ITEM_CATEGORIES = new Set([
    "ball",
    "medicine",
    "tm",
    "evolution",
    "key"
  ]);
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
    } else if (item.category === "tm") {
      if (typeof item.moveId !== "string" || !content.moves[item.moveId]) {
        errors.push(`item '${id}': TMs need a valid moveId`);
      }
    } else if (item.category === "evolution") {
      if (item.moveId !== undefined) {
        errors.push(`item '${id}': evolution items cannot have a moveId`);
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
    if (!species.evYield || typeof species.evYield !== "object") {
      errors.push(`species '${id}': evYield is required`);
    } else {
      let evTotal = 0;
      for (const stat of ["hp", "atk", "def", "spAtk", "spDef", "speed"] as const) {
        const value = species.evYield[stat];
        if (!Number.isInteger(value) || value < 0 || value > 3) {
          errors.push(`species '${id}': evYield.${stat} must be an integer 0..3`);
        } else {
          evTotal += value;
        }
      }
      if (evTotal < 1 || evTotal > 3) {
        errors.push(`species '${id}': evYield total must be 1..3`);
      }
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
  errors.push(...validateStory(content));

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
    const NPC_KINDS = new Set([
      "healer",
      "guide",
      "npc",
      "shop",
      "pc",
      "move_tutor",
      "move_reminder",
      "trade",
      "friendship",
      "ability"
    ]);
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
      if (npc.kind === "move_tutor") {
        if (!Array.isArray(npc.moveList) || npc.moveList.length === 0) {
          errors.push(`${map.id}: move tutor '${npc.id}' needs a non-empty moveList`);
        } else {
          for (const moveId of npc.moveList) {
            if (!content.moves[moveId]) {
              errors.push(`${map.id}: move tutor '${npc.id}' lists unknown move '${moveId}'`);
            }
          }
        }
      } else if (npc.moveList !== undefined) {
        errors.push(`${map.id}: npc '${npc.id}' has moveList but kind '${npc.kind}'`);
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

function checkStoryCondition(
  label: string,
  condition: StoryCondition | undefined,
  errors: string[]
): void {
  if (condition === undefined) return;
  if (!condition || typeof condition !== "object" || Array.isArray(condition)) {
    errors.push(`${label}: condition must be an object`);
    return;
  }
  for (const [flag, value] of Object.entries(condition)) {
    if (!flag) errors.push(`${label}: condition has an empty flag`);
    if (!Number.isFinite(value) || !Number.isInteger(value)) {
      errors.push(`${label}: flag '${flag}' must be an integer`);
    }
  }
}

function checkStoryBounds(
  label: string,
  map: MapDef | undefined,
  x: number,
  y: number,
  width: number,
  height: number,
  errors: string[]
): void {
  if (!map) return;
  if (
    !Number.isInteger(x) ||
    !Number.isInteger(y) ||
    !Number.isInteger(width) ||
    !Number.isInteger(height) ||
    x < 0 ||
    y < 0 ||
    width <= 0 ||
    height <= 0 ||
    x + width > map.width ||
    y + height > map.height
  ) {
    errors.push(`${label}: bounds are outside the map`);
  }
}

/**
 * Structural validation for the story layer. Scenes are checked step by step;
 * every external reference (map, NPC, item, species, move) must resolve.
 */
export function validateStory(content: GameContent): string[] {
  const story = content.story;
  if (!story) return [];
  const errors: string[] = [];

  if (story.startMap !== undefined && !content.maps[story.startMap]) {
    errors.push(`story.startMap '${story.startMap}' does not exist`);
  }
  checkStoryCondition("story.initialFlags", story.initialFlags, errors);

  const sceneIds = new Set(Object.keys(story.scenes));
  // Story NPCs are already merged into their maps, so this also covers them.
  const npcIds = new Set<string>();
  const npcMaps = new Map<string, MapDef>();
  for (const map of Object.values(content.maps)) {
    for (const npc of map.npcs ?? []) {
      npcIds.add(npc.id);
      npcMaps.set(npc.id, map);
    }
  }
  const DIRECTIONS = new Set(["up", "down", "left", "right"]);
  const isFacing = (value: unknown) =>
    value === undefined || value === "player" || (typeof value === "string" && DIRECTIONS.has(value));
  const checkSceneRef = (label: string, sceneId: string) => {
    if (!sceneIds.has(sceneId)) errors.push(`${label}: unknown scene '${sceneId}'`);
  };

  const trainerIds = new Set<string>();
  for (const [id, trainer] of Object.entries(story.trainers ?? {})) {
    const label = `story trainer '${id}'`;
    trainerIds.add(id);
    if (!trainer || typeof trainer !== "object") {
      errors.push(`${label}: must be an object`);
      continue;
    }
    if (typeof trainer.name !== "string" || trainer.name.length === 0) {
      errors.push(`${label}: needs a name`);
    }
    if (!Array.isArray(trainer.party) || trainer.party.length === 0) {
      errors.push(`${label}: party must not be empty`);
    } else {
      for (const member of trainer.party) {
        if (!member || typeof member !== "object") {
          errors.push(`${label}: party member must be an object`);
          continue;
        }
        if (typeof member.species !== "string" || !content.species[member.species]) {
          errors.push(`${label}: unknown species '${String(member.species)}'`);
        }
        if (
          !Number.isInteger(member.level) ||
          (member.level ?? 0) < 1 ||
          (member.level ?? 0) > 100
        ) {
          errors.push(`${label}: party level must be 1..100`);
        }
      }
    }
    if (trainer.reward !== undefined && (!Number.isInteger(trainer.reward) || trainer.reward < 0)) {
      errors.push(`${label}: reward must be a non-negative integer`);
    }
  }
  const checkTrainerRef = (label: string, trainerId: unknown) => {
    if (typeof trainerId !== "string" || !trainerIds.has(trainerId)) {
      errors.push(`${label}: unknown trainer '${String(trainerId)}'`);
    }
  };

  const validStepTypes = new Set([
    "say",
    "chooseStarter",
    "setFlag",
    "giveStarter",
    "givePokemon",
    "giveItem",
    "heal",
    "warp",
    "notice",
    "battle",
    "walk",
    "face"
  ]);

  for (const [id, scene] of Object.entries(story.scenes)) {
    if (scene.id !== id) errors.push(`scene '${id}': id field must match its key`);
    if (!Array.isArray(scene.steps) || scene.steps.length === 0) {
      errors.push(`scene '${id}': steps must not be empty`);
      continue;
    }
    // Where each NPC stands as the scene plays. A walk must start from the tile
    // the previous walk left it on, exactly like the ROM, which reads the
    // object's live position. Steps behind a `when` may not run, so they are
    // checked but do not move the simulated tile.
    const walked = new Map<string, { x: number; y: number }>();
    scene.steps.forEach((step: StoryStepDef, index) => {
      const label = `scene '${id}' step ${index}`;
      if (!step || typeof step !== "object") {
        errors.push(`${label}: must be an object`);
        return;
      }
      if (!validStepTypes.has(step.type)) {
        errors.push(`${label}: invalid type '${String(step.type)}'`);
        return;
      }
      checkStoryCondition(`${label}.when`, step.when, errors);
      if (step.type === "say") {
        if (!Array.isArray(step.lines) || step.lines.length === 0) {
          errors.push(`${label}: say needs lines`);
        } else if (step.lines.some((line) => typeof line !== "string" || line.length === 0)) {
          errors.push(`${label}: say lines must be non-empty strings`);
        }
        if (step.speaker !== undefined && typeof step.speaker !== "string") {
          errors.push(`${label}: speaker must be a string`);
        }
      } else if (step.type === "chooseStarter") {
        if (step.prompt !== undefined && !Array.isArray(step.prompt)) {
          errors.push(`${label}: chooseStarter prompt must be an array of lines`);
        }
        if (!Array.isArray(step.options) || step.options.length === 0) {
          errors.push(`${label}: chooseStarter needs options`);
        } else {
          const seen = new Set<string>();
          for (const option of step.options) {
            if (!option || typeof option !== "object") {
              errors.push(`${label}: chooseStarter option must be an object`);
              continue;
            }
            if (typeof option.id !== "string" || option.id.length === 0) {
              errors.push(`${label}: chooseStarter option needs an id`);
            } else if (seen.has(option.id)) {
              errors.push(`${label}: duplicate option id '${option.id}'`);
            } else {
              seen.add(option.id);
            }
            if (typeof option.species !== "string" || !content.species[option.species]) {
              errors.push(`${label}: unknown option species '${String(option.species)}'`);
            }
            if (
              !Number.isInteger(option.level) ||
              (option.level ?? 0) < 1 ||
              (option.level ?? 0) > 100
            ) {
              errors.push(`${label}: chooseStarter option level must be 1..100`);
            }
            if (option.value !== undefined && !Number.isInteger(option.value)) {
              errors.push(`${label}: chooseStarter option value must be an integer`);
            }
            if (option.value !== undefined && (typeof step.flag !== "string" || step.flag === "")) {
              errors.push(`${label}: option value needs the step's flag`);
            }
          }
        }
      } else if (step.type === "setFlag") {
        if (typeof step.flag !== "string" || step.flag.length === 0) {
          errors.push(`${label}: setFlag needs a flag`);
        }
        if (step.value !== undefined && !Number.isInteger(step.value)) {
          errors.push(`${label}: setFlag value must be an integer`);
        }
      } else if (step.type === "givePokemon") {
        if (typeof step.species !== "string" || !content.species[step.species]) {
          errors.push(`${label}: unknown species '${String(step.species)}'`);
        }
        if (!Number.isInteger(step.level) || (step.level ?? 0) < 1 || (step.level ?? 0) > 100) {
          errors.push(`${label}: givePokemon level must be 1..100`);
        }
      } else if (step.type === "giveItem") {
        if (typeof step.itemId !== "string" || !content.items[step.itemId]) {
          errors.push(`${label}: unknown item '${String(step.itemId)}'`);
        }
        if (!Number.isInteger(step.count) || (step.count ?? 0) < 1) {
          errors.push(`${label}: giveItem count must be a positive integer`);
        }
      } else if (step.type === "warp") {
        const map = typeof step.mapId === "string" ? content.maps[step.mapId] : undefined;
        if (!map) {
          errors.push(`${label}: warp map '${String(step.mapId)}' does not exist`);
        } else {
          if (!Number.isInteger(step.x) || !Number.isInteger(step.y)) {
            errors.push(`${label}: warp needs integer coordinates`);
          } else if (
            (step.x ?? -1) < 0 ||
            (step.y ?? -1) < 0 ||
            (step.x ?? 0) >= map.width ||
            (step.y ?? 0) >= map.height
          ) {
            errors.push(`${label}: warp target is outside '${map.id}'`);
          }
        }
        if (step.dir !== undefined && !["up", "down", "left", "right"].includes(step.dir)) {
          errors.push(`${label}: invalid warp direction`);
        }
      } else if (step.type === "notice") {
        if (typeof step.text !== "string" || step.text.length === 0) {
          errors.push(`${label}: notice needs text`);
        }
      } else if (step.type === "walk") {
        if (typeof step.npcId !== "string" || step.npcId.length === 0) {
          errors.push(`${label}: walk needs an npcId`);
        } else if (!npcIds.has(step.npcId)) {
          errors.push(`${label}: walk targets unknown NPC '${step.npcId}'`);
        }
        if (!isFacing(step.facing)) {
          errors.push(`${label}: invalid walk facing`);
        }
        if (step.vanish !== undefined && typeof step.vanish !== "boolean") {
          errors.push(`${label}: walk vanish must be true or false`);
        }
        const map = step.npcId ? npcMaps.get(step.npcId) : undefined;
        const npc = map?.npcs.find((entry) => entry.id === step.npcId);
        if (!Array.isArray(step.path) || step.path.length === 0) {
          errors.push(`${label}: walk needs a path`);
        } else if (step.path.length > 24) {
          errors.push(`${label}: walk path is longer than 24 tiles`);
        } else {
          let previous: { x: number; y: number } | null = npc
            ? (walked.get(npc.id) ?? { x: npc.x, y: npc.y })
            : null;
          let bad = false;
          for (const point of step.path) {
            if (
              !point ||
              typeof point !== "object" ||
              !Number.isInteger(point.x) ||
              !Number.isInteger(point.y)
            ) {
              errors.push(`${label}: walk path points need integer x/y`);
              previous = null;
              bad = true;
              continue;
            }
            if (previous) {
              const hop =
                Math.abs(point.x - previous.x) + Math.abs(point.y - previous.y);
              if (hop !== 1) {
                errors.push(
                  `${label}: walk hops must be one tile, got ` +
                    `(${previous.x},${previous.y}) -> (${point.x},${point.y})`
                );
                bad = true;
              }
            }
            // A tile that is not walkable makes the server drop the whole walk
            // at runtime, which looks exactly like "the NPC never moved", so it
            // has to fail here instead.
            if (map && !isWalkable(map, point.x, point.y)) {
              errors.push(
                `${label}: walk point (${point.x},${point.y}) is not walkable on '${map.id}'`
              );
              bad = true;
            }
            previous = point;
          }
          const last = step.path[step.path.length - 1];
          if (
            !bad &&
            npc &&
            step.when === undefined &&
            last &&
            Number.isInteger(last.x) &&
            Number.isInteger(last.y)
          ) {
            walked.set(npc.id, { x: last.x, y: last.y });
          }
        }
        if (
          step.msPerTile !== undefined &&
          (!Number.isInteger(step.msPerTile) || step.msPerTile < 80 || step.msPerTile > 2000)
        ) {
          errors.push(`${label}: walk msPerTile must be 80..2000`);
        }
      } else if (step.type === "face") {
        if (typeof step.npcId !== "string" || step.npcId.length === 0) {
          errors.push(`${label}: face needs an npcId`);
        } else if (!npcIds.has(step.npcId)) {
          errors.push(`${label}: face targets unknown NPC '${step.npcId}'`);
        }
        if (step.facing === undefined) {
          errors.push(`${label}: face needs a facing (a direction or "player")`);
        } else if (!isFacing(step.facing)) {
          errors.push(`${label}: invalid face facing`);
        }
      } else if (step.type === "battle") {
        if (step.trainer === undefined && !(step.variants && step.variants.length > 0)) {
          errors.push(`${label}: battle needs a trainer or variants`);
        }
        if (step.trainer !== undefined) checkTrainerRef(label, step.trainer);
        if (step.variants !== undefined) {
          if (!Array.isArray(step.variants)) {
            errors.push(`${label}: battle variants must be an array`);
          } else {
            for (const variant of step.variants) {
              if (!variant || typeof variant !== "object") {
                errors.push(`${label}: battle variant must be an object`);
                continue;
              }
              checkTrainerRef(label, variant.trainer);
              checkStoryCondition(`${label} variant`, variant.when, errors);
            }
          }
        }
        for (const key of ["win", "lose"] as const) {
          const lines = step[key];
          if (lines === undefined) continue;
          if (!Array.isArray(lines) || lines.length === 0) {
            errors.push(`${label}: battle ${key} must be a non-empty array of lines`);
          } else if (lines.some((line) => typeof line !== "string" || line.length === 0)) {
            errors.push(`${label}: battle ${key} lines must be non-empty strings`);
          }
        }
        if (step.speaker !== undefined && typeof step.speaker !== "string") {
          errors.push(`${label}: speaker must be a string`);
        }
        if (step.resultFlag !== undefined && typeof step.resultFlag !== "string") {
          errors.push(`${label}: battle resultFlag must be a string`);
        }
      }
    });
  }

  for (const npc of story.npcs) {
    const label = `story npc '${npc.id}'`;
    const map = content.maps[npc.mapId];
    if (!map) {
      errors.push(`${label}: unknown map '${npc.mapId}'`);
      continue;
    }
    checkStoryBounds(label, map, npc.x, npc.y, 1, 1, errors);
    if (!isWalkable(map, npc.x, npc.y)) {
      errors.push(`${label}: stands on a blocked tile (${npc.x},${npc.y})`);
    }
    checkStoryCondition(`${label}.visibleWhen`, npc.visibleWhen, errors);
    if (npc.scene !== undefined) checkSceneRef(label, npc.scene);
    checkStoryCondition(`${label}.sceneWhen`, npc.sceneWhen, errors);
    if (typeof npc.name !== "string") errors.push(`${label}: name must be a string`);
    if (!Array.isArray(npc.dialogue) || npc.dialogue.length === 0) {
      errors.push(`${label}: dialogue must not be empty`);
    }
  }

  for (const interaction of story.interactions) {
    const label = `story interaction '${interaction.mapId}/${interaction.npcId}'`;
    const map = content.maps[interaction.mapId];
    if (!map) {
      errors.push(`${label}: unknown map`);
      continue;
    }
    if (!map.npcs.some((npc) => npc.id === interaction.npcId)) {
      errors.push(`${label}: npc does not exist`);
    }
    checkSceneRef(label, interaction.scene);
    checkStoryCondition(`${label}.when`, interaction.when, errors);
  }

  for (const trigger of story.triggers) {
    const label = `story trigger '${trigger.id}'`;
    const map = content.maps[trigger.mapId];
    if (!map) {
      errors.push(`${label}: unknown map '${trigger.mapId}'`);
      continue;
    }
    checkStoryBounds(label, map, trigger.x, trigger.y, trigger.width, trigger.height, errors);
    checkSceneRef(label, trigger.scene);
    checkStoryCondition(`${label}.when`, trigger.when, errors);
  }

  for (const gate of story.gates) {
    const label = `story gate '${gate.id}'`;
    const map = content.maps[gate.mapId];
    if (!map) {
      errors.push(`${label}: unknown map '${gate.mapId}'`);
      continue;
    }
    checkStoryBounds(label, map, gate.x, gate.y, gate.width, gate.height, errors);
    checkStoryCondition(`${label}.when`, gate.when, errors);
    if (!Array.isArray(gate.lines) || gate.lines.length === 0) {
      errors.push(`${label}: lines must not be empty`);
    }
  }

  for (const enter of story.onEnter) {
    const label = `story onEnter '${enter.id}'`;
    if (!content.maps[enter.mapId]) errors.push(`${label}: unknown map '${enter.mapId}'`);
    checkSceneRef(label, enter.scene);
    checkStoryCondition(`${label}.when`, enter.when, errors);
  }

  return errors;
}
