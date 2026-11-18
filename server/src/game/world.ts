import { CONFIG } from "../config.js";
import type { EncounterEntry, MapDef } from "../content/types.js";
import {
  canStep,
  encounterAt,
  getPortal,
  isTallGrass,
  isWalkable,
  needsTileWindowRefresh,
  portalAcceptsDirection,
  portalTriggersOnStep,
  tileWindow
} from "./maps.js";
import {
  DIRECTIONS,
  asInt,
  asString,
  type Dict,
  type PlayerSession
} from "./protocol.js";
import type { GameHost } from "./runtime.js";
import type { Dir } from "./types.js";

/** Movement, doors, tile-window streaming and encounter rolls. */
export class WorldController {
  constructor(private readonly host: GameHost) {}

  handleMove(conn: PlayerSession["conn"], msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character before moving.");
      return;
    }
    const dirValue = asString(msg.dir);
    if (!dirValue || !(dirValue in DIRECTIONS)) {
      this.host.sendError(conn, "Invalid direction.");
      return;
    }
    const dir = dirValue as Dir;
    const seq = asInt(msg.seq) ?? 0;
    const run = msg.run === true;
    const character = player.character;
    const now = Date.now();

    if (player.battleId) {
      this.host.send(conn, {
        type: "move_ack",
        seq,
        accepted: false,
        reason: "in_battle",
        x: character.x,
        y: character.y,
        dir: character.dir,
        run,
        mapId: character.mapId
      });
      return;
    }

    if (this.host.story.isBusy(player)) {
      this.host.send(conn, {
        type: "move_ack",
        seq,
        accepted: false,
        reason: "story",
        x: character.x,
        y: character.y,
        dir: character.dir,
        run,
        mapId: character.mapId
      });
      return;
    }

    if (now - player.lastMoveAt < CONFIG.moveCooldownMs) {
      this.host.send(conn, {
        type: "move_ack",
        seq,
        accepted: false,
        reason: "too_fast",
        x: character.x,
        y: character.y,
        dir: character.dir,
        run,
        mapId: character.mapId
      });
      return;
    }
    player.lastMoveAt = now;

    const map = this.host.map(character.mapId);
    const [dx, dy] = DIRECTIONS[dir];
    const nx = character.x + dx;
    const ny = character.y + dy;
    const underfootPortal = getPortal(map, character.x, character.y);
    const previousDir = character.dir;
    character.dir = dir;

    if (underfootPortal && !this.portalLocked(player)) {
      // Standing on a door trigger and walking the way the ROM door faces uses
      // it, even when the next tile is the solid door itself. Legacy portals
      // without an entry direction keep the old walk-into-the-wall behaviour.
      const usesDoor =
        underfootPortal.entryDir === undefined
          ? !isWalkable(map, nx, ny)
          : portalAcceptsDirection(underfootPortal, dir);
      if (usesDoor) {
        this.travel(
          player,
          underfootPortal.targetMap,
          underfootPortal.targetX,
          underfootPortal.targetY,
          underfootPortal.targetDir
        );
        return;
      }
    }

    if (!isWalkable(map, nx, ny) || !canStep(map, character.x, character.y, nx, ny)) {
      if (previousDir !== dir) {
        this.host.visibility.broadcast(player, {
          type: "player_turned",
          playerId: character.id,
          mapId: character.mapId,
          x: character.x,
          y: character.y,
          dir
        });
      }
      this.host.send(conn, {
        type: "move_ack",
        seq,
        accepted: false,
        reason: "blocked",
        x: character.x,
        y: character.y,
        dir: character.dir,
        run,
        mapId: character.mapId
      });
      return;
    }

    // Story gates: the tile is walkable but the road is closed for this player.
    const gate = this.host.story.gateAt(player, map.id, nx, ny);
    if (gate) {
      if (previousDir !== dir) {
        this.host.visibility.broadcast(player, {
          type: "player_turned",
          playerId: character.id,
          mapId: character.mapId,
          x: character.x,
          y: character.y,
          dir
        });
      }
      this.host.send(conn, {
        type: "move_ack",
        seq,
        accepted: false,
        reason: "story_gate",
        x: character.x,
        y: character.y,
        dir: character.dir,
        run,
        mapId: character.mapId
      });
      this.host.story.showGate(player, gate);
      return;
    }

    // Story NPCs block like ordinary map NPCs. This runs after the gate check
    // so the gate keeps ownership of its dialogue even when a visible story
    // character stands on the locked tiles (the player sees who stops them).
    if (this.host.story.blocksAt(map, nx, ny, character.storyFlags)) {
      if (previousDir !== dir) {
        this.host.visibility.broadcast(player, {
          type: "player_turned",
          playerId: character.id,
          mapId: character.mapId,
          x: character.x,
          y: character.y,
          dir
        });
      }
      this.host.send(conn, {
        type: "move_ack",
        seq,
        accepted: false,
        reason: "blocked",
        x: character.x,
        y: character.y,
        dir: character.dir,
        run,
        mapId: character.mapId
      });
      return;
    }

    const previousPosition = { mapId: character.mapId, x: character.x, y: character.y };
    character.x = nx;
    character.y = ny;
    this.clearPortalLockIfLeft(player);
    this.host.store.saveCharacter(player.accountId, character);
    this.host.send(conn, {
      type: "move_ack",
      seq,
      accepted: true,
      x: nx,
      y: ny,
      dir,
      run,
      mapId: character.mapId,
      location: this.host.locationName(conn.locale, character.mapId, nx, ny)
    });
    this.host.visibility.reconcileAfterMove(player, previousPosition);
    const moved = {
      type: "player_moved",
      playerId: character.id,
      mapId: map.id,
      x: nx,
      y: ny,
      dir,
      run
    };
    this.host.visibility.broadcast(player, moved);

    const portal = getPortal(map, nx, ny);
    if (portal && !underfootPortal && !this.portalLocked(player)) {
      // ROM doors only open when walked into from their contact side, and a
      // snapped trigger in front of a solid door waits for the next step into
      // the door itself (handled by the underfoot check above).
      if (portalAcceptsDirection(portal, dir) && portalTriggersOnStep(map, portal)) {
        this.travel(player, portal.targetMap, portal.targetX, portal.targetY, portal.targetDir);
        return;
      }
    }

    this.host.story.onStep(player, map.id, nx, ny);
    this.maybeSendTileWindow(player, map);
    if (this.host.story.isBusy(player)) return;

    const encounter = encounterAt(map, nx, ny);
    if (
      encounter &&
      isTallGrass(map, nx, ny) &&
      now >= player.encounterGraceUntil
    ) {
      const rate = CONFIG.encounterRateOverride ?? encounter.rate;
      if (Math.random() < rate) {
        const entry = this.pickEncounter(encounter.table);
        if (entry) this.host.startWildBattle(player, map, entry);
      }
    }
  }

  handleTurn(conn: PlayerSession["conn"], msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character before turning.");
      return;
    }
    const dirValue = asString(msg.dir);
    if (!dirValue || !(dirValue in DIRECTIONS)) {
      this.host.sendError(conn, "Invalid direction.");
      return;
    }
    const dir = dirValue as Dir;
    const character = player.character;
    if (player.battleId || character.dir === dir) return;
    character.dir = dir;
    this.host.visibility.broadcast(player, {
      type: "player_turned",
      playerId: character.id,
      mapId: character.mapId,
      x: character.x,
      y: character.y,
      dir
    });
  }

  private maybeSendTileWindow(player: PlayerSession, map: MapDef): void {
    const current = player.tileWindow;
    if (!current) return;
    if (current.width >= map.width && current.height >= map.height) return;
    const { x, y } = player.character;
    if (!needsTileWindowRefresh(current, x, y, CONFIG.tileWindowRefreshMargin)) {
      return;
    }
    const next = tileWindow(map, x, y, CONFIG.tileWindowRadius);
    player.tileWindow = next;
    this.host.send(player.conn, {
      type: "map_window",
      mapId: map.id,
      x: next.x,
      y: next.y,
      width: next.width,
      height: next.height,
      tiles: next.tiles
    });
  }

  private pickEncounter(table: EncounterEntry[]): EncounterEntry | null {
    const total = table.reduce((sum, entry) => sum + entry.weight, 0);
    if (total <= 0) return null;
    let roll = Math.random() * total;
    for (const entry of table) {
      roll -= entry.weight;
      if (roll <= 0) return entry;
    }
    return table[table.length - 1] ?? null;
  }

  private portalLocked(player: PlayerSession): boolean {
    const lock = player.portalLock;
    if (!lock) return false;
    const c = player.character;
    if (c.mapId === lock.mapId && c.x === lock.x && c.y === lock.y) return true;
    player.portalLock = null;
    return false;
  }

  /** Drop the arrival guard as soon as the player leaves the door tile. */
  private clearPortalLockIfLeft(player: PlayerSession): void {
    const lock = player.portalLock;
    if (!lock) return;
    const c = player.character;
    if (c.mapId !== lock.mapId || c.x !== lock.x || c.y !== lock.y) {
      player.portalLock = null;
    }
  }

  private travel(
    player: PlayerSession,
    targetMapId: string,
    x: number,
    y: number,
    direction?: Dir
  ): void {
    const oldMapId = player.character.mapId;
    const targetMap = this.host.map(targetMapId);
    this.host.visibility.clear(player);
    player.character.mapId = targetMap.id;
    player.character.x = x;
    player.character.y = y;
    player.character.dir = direction ?? targetMap.spawn.dir;
    player.portalLock = { mapId: targetMap.id, x, y };
    this.host.store.saveCharacter(player.accountId, player.character);

    this.host.afterTeleport(player);
    console.log(
      `[game] ${player.character.name} travelled ${oldMapId} -> ${targetMap.id}`
    );
  }
}
