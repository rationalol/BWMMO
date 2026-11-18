import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export type WorldMapPlaceKind = "town" | "route" | "landmark";

export interface WorldMapPlace {
  key: string;
  x: number;
  y: number;
  kind: WorldMapPlaceKind;
}

export interface WorldMapContent {
  width: number;
  height: number;
  places: WorldMapPlace[];
}

const here = path.dirname(fileURLToPath(import.meta.url));
export const DEFAULT_WORLD_MAP_FILE = path.resolve(
  here,
  "..",
  "..",
  "content",
  "rom",
  "world_map.json"
);

const KINDS = new Set<WorldMapPlaceKind>(["town", "route", "landmark"]);

/**
 * Loads the original Unova town map's place list (see
 * tools/rom/extract_town_map.py). The map is optional: without extracted ROM
 * content the server simply omits it from map_state.
 */
export function loadWorldMap(
  file: string = DEFAULT_WORLD_MAP_FILE
): WorldMapContent | null {
  try {
    const parsed = JSON.parse(fs.readFileSync(file, "utf8")) as {
      image?: { width?: unknown; height?: unknown };
      places?: unknown;
    };
    const width = parsed.image?.width;
    const height = parsed.image?.height;
    if (
      !Number.isInteger(width) ||
      !Number.isInteger(height) ||
      !Array.isArray(parsed.places)
    ) {
      return null;
    }
    const mapWidth = width as number;
    const mapHeight = height as number;
    const places: WorldMapPlace[] = [];
    const seen = new Set<string>();
    for (const entry of parsed.places) {
      if (!entry || typeof entry !== "object") return null;
      const place = entry as Record<string, unknown>;
      const key = place.key;
      const x = place.x;
      const y = place.y;
      const kind = place.kind;
      if (
        typeof key !== "string" ||
        !key ||
        seen.has(key) ||
        !Number.isInteger(x) ||
        !Number.isInteger(y) ||
        (x as number) < 0 ||
        (y as number) < 0 ||
        (x as number) >= mapWidth ||
        (y as number) >= mapHeight ||
        typeof kind !== "string" ||
        !KINDS.has(kind as WorldMapPlaceKind)
      ) {
        return null;
      }
      seen.add(key);
      places.push({
        key,
        x: x as number,
        y: y as number,
        kind: kind as WorldMapPlaceKind
      });
    }
    if (places.length === 0) return null;
    return { width: mapWidth, height: mapHeight, places };
  } catch (error) {
    console.warn(`[world-map] could not load ${file}:`, error);
    return null;
  }
}
