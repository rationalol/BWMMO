import type { Dir, EncounterDef, MapDef, NpcDef, PortalDef } from "../content/types.js";

const WALKABLE = new Set([".", ",", "g", "f", "=", "P"]);
const BLOCKED = new Set(["#", "~", "H", "S", "B"]);

export const KNOWN_TILES = new Set([...WALKABLE, ...BLOCKED]);
export const WALKABLE_TILES = WALKABLE;

export function getMap(maps: Record<string, MapDef>, mapId: string): MapDef {
  const map = maps[mapId];
  if (!map) throw new Error(`Unknown map: ${mapId}`);
  return map;
}

export function tileAt(map: MapDef, x: number, y: number): string {
  if (x < 0 || y < 0 || x >= map.width || y >= map.height) return "#";
  return map.tiles[y][x];
}

export function isWalkable(map: MapDef, x: number, y: number): boolean {
  return WALKABLE.has(tileAt(map, x, y));
}

interface HeightGrid {
  cellSize: number;
  scale: number;
  values: Int16Array;
}

const HEIGHT_CACHE = new WeakMap<MapDef, HeightGrid | null>();

/** Decode the per-chunk base64 height grids once per map. */
function heightGrid(map: MapDef): HeightGrid | null {
  if (HEIGHT_CACHE.has(map)) return HEIGHT_CACHE.get(map) ?? null;
  const visual = map.visual;
  if (!visual) {
    HEIGHT_CACHE.set(map, null);
    return null;
  }
  const cellSize = visual.cellSize || 32;
  const scale = visual.heightScale && visual.heightScale > 0 ? visual.heightScale : 16;
  const values = new Int16Array(map.width * map.height);
  let found = false;
  for (const chunk of visual.chunks) {
    if (!chunk.heights) continue;
    const cellX = chunk.cellX ?? 0;
    const cellY = chunk.cellY ?? chunk.cell ?? 0;
    const raw = Buffer.from(chunk.heights, "base64");
    const count = Math.min(32 * 32, raw.length >> 1);
    for (let i = 0; i < count; i++) {
      const localX = i % 32;
      const localY = Math.floor(i / 32);
      const x = cellX * cellSize + localX;
      const y = cellY * cellSize + localY;
      if (x < 0 || y < 0 || x >= map.width || y >= map.height) continue;
      values[y * map.width + x] = raw.readInt16LE(i * 2);
    }
    found = true;
  }
  if (!found) {
    HEIGHT_CACHE.set(map, null);
    return null;
  }
  const grid = { cellSize, scale, values };
  HEIGHT_CACHE.set(map, grid);
  return grid;
}

/** Ground height at a tile in world units; 0 when the map has no heights. */
export function heightAt(map: MapDef, x: number, y: number): number {
  const grid = heightGrid(map);
  if (!grid || x < 0 || y < 0 || x >= map.width || y >= map.height) return 0;
  const raw = grid.values[y * map.width + x];
  return raw === 0 ? 0 : raw / grid.scale;
}

export const MAX_STEP_UP = 24;
export const MAX_STEP_DOWN = 128;

/**
 * Height-aware step rule. The permission grid decides the floor plan; this
 * rejects walking up a wall/cliff face while still allowing a drop down a
 * ledge. The client mirrors the same rule for prediction.
 */
export function canStep(
  map: MapDef,
  fromX: number,
  fromY: number,
  toX: number,
  toY: number
): boolean {
  const delta = heightAt(map, toX, toY) - heightAt(map, fromX, fromY);
  return delta <= MAX_STEP_UP && delta >= -MAX_STEP_DOWN;
}

export function isTallGrass(map: MapDef, x: number, y: number): boolean {
  return tileAt(map, x, y) === "g";
}

export function hasNpcAt(map: MapDef, x: number, y: number, exceptId?: string): boolean {
  return map.npcs.some((npc) => npc.id !== exceptId && npc.x === x && npc.y === y);
}

export function getPortal(map: MapDef, x: number, y: number): PortalDef | undefined {
  return map.portals.find((portal) => portal.x === x && portal.y === y);
}

/**
 * ROM warps store the direction the player has to walk into the door. Portals
 * without one (hand-authored maps, scripted warps) accept any direction.
 */
export function portalAcceptsDirection(portal: PortalDef, dir: Dir): boolean {
  return portal.entryDir === undefined || portal.entryDir === dir;
}

const DIRECTION_DELTA: Record<Dir, [number, number]> = {
  up: [0, -1],
  down: [0, 1],
  left: [-1, 0],
  right: [1, 0]
};

/**
 * Snapped door triggers sit on the floor in front of a solid door, so the
 * player has to press into the door. Real doorway tiles, and snapped tiles
 * whose contact direction opens onto more floor, fire on the step itself.
 */
export function portalTriggersOnStep(map: MapDef, portal: PortalDef): boolean {
  if (portal.entryDir === undefined || portal.onWarpTile === true) return true;
  const [dx, dy] = DIRECTION_DELTA[portal.entryDir];
  return isWalkable(map, portal.x + dx, portal.y + dy);
}

/** Returns the encounter table for a tile, using area zones before the map fallback. */
export function encounterAt(map: MapDef, x: number, y: number): EncounterDef | undefined {
  for (const zone of map.encounterZones ?? []) {
    if (x >= zone.x && x < zone.x + zone.width && y >= zone.y && y < zone.y + zone.height) {
      return zone;
    }
  }
  return map.encounter;
}

export function findNpc(map: MapDef, npcId: string): NpcDef | undefined {
  return map.npcs.find((npc) => npc.id === npcId);
}

export interface TileWindow {
  x: number;
  y: number;
  width: number;
  height: number;
  tiles: string[];
}

/**
 * A square slice of the map grid centred on a tile. The slice is clamped to
 * the map bounds, so edge tiles still receive a full window when possible.
 */
export function tileWindow(
  map: MapDef,
  centerX: number,
  centerY: number,
  radius: number
): TileWindow {
  const safeRadius = Math.max(0, Math.floor(radius));
  const width = Math.min(map.width, safeRadius * 2 + 1);
  const height = Math.min(map.height, safeRadius * 2 + 1);
  const x = Math.max(0, Math.min(map.width - width, centerX - Math.floor(width / 2)));
  const y = Math.max(0, Math.min(map.height - height, centerY - Math.floor(height / 2)));
  const tiles = map.tiles.slice(y, y + height).map((row) => row.slice(x, x + width));
  return { x, y, width, height, tiles };
}

/** True when the player is close enough to a window edge for a recentre. */
export function needsTileWindowRefresh(
  window: TileWindow,
  x: number,
  y: number,
  margin: number
): boolean {
  const safeMargin = Math.max(0, margin);
  const left = x - window.x;
  const right = window.x + window.width - 1 - x;
  const top = y - window.y;
  const bottom = window.y + window.height - 1 - y;
  return Math.min(left, right, top, bottom) < safeMargin;
}

/** Chebyshev interest check used for player visibility and broadcasts. */
export function withinView(
  a: { mapId: string; x: number; y: number },
  b: { mapId: string; x: number; y: number },
  radius: number
): boolean {
  return (
    a.mapId === b.mapId &&
    Math.max(Math.abs(a.x - b.x), Math.abs(a.y - b.y)) <= Math.max(0, radius)
  );
}

export function directionDelta(direction: Dir): [number, number] {
  switch (direction) {
    case "up":
      return [0, -1];
    case "down":
      return [0, 1];
    case "left":
      return [-1, 0];
    case "right":
      return [1, 0];
  }
}

/**
 * Structural validation for map files. Species/encounter references are
 * validated by the content loader, which knows about the species table.
 */
export function validateMaps(maps: Record<string, MapDef>): string[] {
  const errors: string[] = [];
  for (const map of Object.values(maps)) {
    if (!map.id) errors.push("map is missing an id");
    if (map.tiles.length !== map.height) {
      errors.push(`${map.id}: height ${map.height} != tile rows ${map.tiles.length}`);
    }
    if (map.tiles.length === 0) errors.push(`${map.id}: has no tiles`);
    for (let y = 0; y < map.tiles.length; y++) {
      const row = map.tiles[y];
      if (row.length !== map.width) {
        errors.push(`${map.id}: row ${y} has length ${row.length}, expected ${map.width}`);
      }
      for (const char of row) {
        if (!KNOWN_TILES.has(char)) {
          errors.push(`${map.id}: row ${y} contains unknown tile '${char}'`);
        }
      }
    }
    if (!isWalkable(map, map.spawn.x, map.spawn.y)) {
      errors.push(`${map.id}: spawn (${map.spawn.x},${map.spawn.y}) is not walkable`);
    }
    if (hasNpcAt(map, map.spawn.x, map.spawn.y)) {
      errors.push(`${map.id}: spawn is occupied by an NPC`);
    }
    if (!["up", "down", "left", "right"].includes(map.spawn.dir)) {
      errors.push(`${map.id}: invalid spawn direction`);
    }

    const npcIds = new Set<string>();
    for (const npc of map.npcs) {
      if (npcIds.has(npc.id)) errors.push(`${map.id}: duplicate npc id ${npc.id}`);
      npcIds.add(npc.id);
      if (!isWalkable(map, npc.x, npc.y)) {
        errors.push(`${map.id}: npc ${npc.id} stands on a blocked tile`);
      }
      if (!Array.isArray(npc.dialogue) || npc.dialogue.length === 0) {
        errors.push(`${map.id}: npc ${npc.id} has no dialogue`);
      }
      if (npc.setFlags !== undefined) {
        if (!Array.isArray(npc.setFlags) || npc.setFlags.some((flag) => !Number.isInteger(flag))) {
          errors.push(`${map.id}: npc ${npc.id} has invalid setFlags`);
        }
      }
      if (npc.dialogueVariants !== undefined) {
        if (!Array.isArray(npc.dialogueVariants)) {
          errors.push(`${map.id}: npc ${npc.id} dialogueVariants must be an array`);
        } else {
          for (const variant of npc.dialogueVariants) {
            if (!Array.isArray(variant.lines) || variant.lines.length === 0) {
              errors.push(`${map.id}: npc ${npc.id} has an empty dialogue variant`);
            }
            if (
              !variant.flags ||
              typeof variant.flags !== "object" ||
              Array.isArray(variant.flags)
            ) {
              errors.push(`${map.id}: npc ${npc.id} has invalid dialogue variant flags`);
            } else {
              for (const [flag, value] of Object.entries(variant.flags)) {
                if (!Number.isInteger(Number(flag)) || !Number.isFinite(value)) {
                  errors.push(`${map.id}: npc ${npc.id} has invalid flag ${flag}`);
                }
              }
            }
            if (
              variant.setFlags !== undefined &&
              (!Array.isArray(variant.setFlags) ||
                variant.setFlags.some((flag) => !Number.isInteger(flag)))
            ) {
              errors.push(`${map.id}: npc ${npc.id} has invalid variant setFlags`);
            }
          }
        }
      }
    }

    const portalSources = new Set<string>();
    for (const portal of map.portals) {
      const key = `${portal.x},${portal.y}`;
      if (portalSources.has(key)) errors.push(`${map.id}: duplicate portal at ${key}`);
      portalSources.add(key);
      if (tileAt(map, portal.x, portal.y) !== "P") {
        errors.push(`${map.id}: portal at (${portal.x},${portal.y}) is not on a P tile`);
      }
      const target = maps[portal.targetMap];
      if (!target) {
        errors.push(`${map.id}: portal target map ${portal.targetMap} is missing`);
      } else if (!isWalkable(target, portal.targetX, portal.targetY)) {
        errors.push(
          `${map.id}: portal target (${portal.targetMap},${portal.targetX},${portal.targetY}) is not walkable`
        );
      }
    }

    if (map.encounter) {
      if (!(map.encounter.rate >= 0 && map.encounter.rate <= 1)) {
        errors.push(`${map.id}: encounter rate must be 0..1`);
      }
      if (!Array.isArray(map.encounter.table) || map.encounter.table.length === 0) {
        errors.push(`${map.id}: encounter table is empty`);
      }
    }
  }
  return errors;
}
