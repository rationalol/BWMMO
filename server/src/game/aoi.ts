import { withinView } from "./maps.js";

/** Anything the AOI index can locate on a map. */
export interface AoiEntity {
  accountId: string;
  character: { mapId: string; x: number; y: number };
}

/** Tile width of one spatial bucket. 32 keeps a 64-tile view to 5x5 buckets. */
export const DEFAULT_AOI_CELL_SIZE = 32;

/**
 * Uniform-grid index for "who is near this player" queries.
 *
 * Players only ever occupy one bucket per map. A view query walks the buckets
 * covering the square around the observer and then applies the exact Chebyshev
 * check, so results match a full scan while staying local as the player count
 * grows.
 */
export class AoiIndex<T extends AoiEntity> {
  private readonly maps = new Map<string, Map<string, Set<T>>>();
  /** accountId -> the bucket currently holding that player. */
  private readonly placements = new Map<string, { mapId: string; cell: string }>();

  constructor(private readonly cellSize: number = DEFAULT_AOI_CELL_SIZE) {
    if (!Number.isInteger(cellSize) || cellSize <= 0) {
      throw new Error("AOI cell size must be a positive integer.");
    }
  }

  get size(): number {
    return this.placements.size;
  }

  add(entity: T): void {
    this.remove(entity.accountId);
    const mapId = entity.character.mapId;
    const cell = this.cellKey(entity.character.x, entity.character.y);
    let buckets = this.maps.get(mapId);
    if (!buckets) {
      buckets = new Map();
      this.maps.set(mapId, buckets);
    }
    let bucket = buckets.get(cell);
    if (!bucket) {
      bucket = new Set();
      buckets.set(cell, bucket);
    }
    bucket.add(entity);
    this.placements.set(entity.accountId, { mapId, cell });
  }

  /** Re-index an entity after its character position changed. */
  update(entity: T): void {
    this.add(entity);
  }

  remove(entityOrId: T | string): boolean {
    const accountId =
      typeof entityOrId === "string" ? entityOrId : entityOrId.accountId;
    const placement = this.placements.get(accountId);
    if (!placement) return false;
    this.placements.delete(accountId);

    const buckets = this.maps.get(placement.mapId);
    if (!buckets) return true;
    const bucket = buckets.get(placement.cell);
    if (bucket) {
      for (const entity of bucket) {
        if (entity.accountId === accountId) bucket.delete(entity);
      }
      if (bucket.size === 0) buckets.delete(placement.cell);
    }
    if (buckets.size === 0) this.maps.delete(placement.mapId);
    return true;
  }

  /** All indexed entities within `radius` Chebyshev tiles of the point. */
  query(mapId: string, x: number, y: number, radius: number): T[] {
    const buckets = this.maps.get(mapId);
    if (!buckets) return [];

    const safeRadius = Math.max(0, radius);
    const minX = Math.floor((x - safeRadius) / this.cellSize);
    const maxX = Math.floor((x + safeRadius) / this.cellSize);
    const minY = Math.floor((y - safeRadius) / this.cellSize);
    const maxY = Math.floor((y + safeRadius) / this.cellSize);
    const result: T[] = [];
    const seen = new Set<string>();
    for (let cellY = minY; cellY <= maxY; cellY++) {
      for (let cellX = minX; cellX <= maxX; cellX++) {
        const bucket = buckets.get(`${cellX},${cellY}`);
        if (!bucket) continue;
        for (const entity of bucket) {
          if (seen.has(entity.accountId)) continue;
          if (
            !withinView(
              { mapId, x, y },
              {
                mapId: entity.character.mapId,
                x: entity.character.x,
                y: entity.character.y
              },
              safeRadius
            )
          ) {
            continue;
          }
          seen.add(entity.accountId);
          result.push(entity);
        }
      }
    }
    return result;
  }

  clear(): void {
    this.maps.clear();
    this.placements.clear();
  }

  private cellKey(x: number, y: number): string {
    return `${Math.floor(x / this.cellSize)},${Math.floor(y / this.cellSize)}`;
  }
}
