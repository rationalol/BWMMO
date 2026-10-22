import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export interface OutdoorLocationGrid {
  width: number;
  height: number;
  tileSize: number;
  grid: string[][];
}

const here = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_FILE = path.resolve(
  here,
  "..",
  "..",
  "content",
  "rom",
  "outdoor_locations.json"
);

export function loadOutdoorLocations(file: string = DEFAULT_FILE): OutdoorLocationGrid | null {
  try {
    const parsed = JSON.parse(fs.readFileSync(file, "utf8")) as OutdoorLocationGrid;
    if (
      !Number.isInteger(parsed.width) ||
      !Number.isInteger(parsed.height) ||
      !Number.isInteger(parsed.tileSize) ||
      !Array.isArray(parsed.grid)
    ) {
      return null;
    }
    return parsed;
  } catch (error) {
    console.warn(`[locations] could not load ${file}:`, error);
    return null;
  }
}

/** Returns the ROM location name for a world tile, or "" when outside the grid. */
export function locationAt(
  grid: OutdoorLocationGrid,
  x: number,
  y: number
): string {
  const cx = Math.floor(x / grid.tileSize);
  const cy = Math.floor(y / grid.tileSize);
  if (cx < 0 || cy < 0 || cx >= grid.width || cy >= grid.height) return "";
  return grid.grid[cy]?.[cx] ?? "";
}
