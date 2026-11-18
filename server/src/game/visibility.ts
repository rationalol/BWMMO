import { CONFIG } from "../config.js";
import { withinView } from "./maps.js";
import { AoiIndex } from "./aoi.js";
import {
  publicPlayer,
  sendMessage,
  type Conn,
  type Dict,
  type PlayerSession
} from "./protocol.js";

export type MessageSender = (conn: Conn, message: Dict) => void;

interface Position {
  mapId: string;
  x: number;
  y: number;
}

/**
 * Owns the spatial index and the two-way "who can see whom" bookkeeping.
 *
 * The previous implementation scanned every online player on each move. Here a
 * move queries only the buckets around the old and new tile, while still
 * sending exactly the same player_joined/player_left diffs.
 */
export class VisibilityService {
  private readonly index = new AoiIndex<PlayerSession>();
  private readonly byId = new Map<string, PlayerSession>();

  constructor(private readonly send: MessageSender = sendMessage) {}

  get size(): number {
    return this.index.size;
  }

  add(player: PlayerSession): void {
    this.index.add(player);
    this.byId.set(player.accountId, player);
  }

  visibleOthers(player: PlayerSession): PlayerSession[] {
    return this.nearby(player, player.character);
  }

  /**
   * Fill the player's view and tell nearby players about them. Used after a
   * spawn or teleport, where the client already received the players array in
   * map_state.
   */
  refresh(player: PlayerSession): void {
    const nearby = this.nearby(player, player.character);
    player.visiblePlayers = new Set(nearby.map((other) => other.accountId));
    for (const other of nearby) {
      if (other.visiblePlayers.has(player.accountId)) continue;
      other.visiblePlayers.add(player.accountId);
      this.send(other.conn, {
        type: "player_joined",
        player: publicPlayer(player)
      });
    }
  }

  /**
   * Diff visibility in both directions after a step. `previous` must be the
   * position before the character was moved.
   */
  reconcileAfterMove(player: PlayerSession, previous: Position): void {
    this.index.update(player);
    const nearbyNow = this.nearby(player, player.character);
    const nowIds = new Set(nearbyNow.map((other) => other.accountId));
    const previousView = new Set(player.visiblePlayers);

    for (const other of nearbyNow) {
      if (previousView.has(other.accountId)) continue;
      player.visiblePlayers.add(other.accountId);
      this.send(player.conn, {
        type: "player_joined",
        player: publicPlayer(other)
      });
    }
    for (const accountId of previousView) {
      if (nowIds.has(accountId)) continue;
      player.visiblePlayers.delete(accountId);
      const other = this.byId.get(accountId);
      if (other) {
        this.send(player.conn, {
          type: "player_left",
          playerId: other.character.id
        });
      }
    }

    // Players who could see this character before or after the step. Together
    // these two neighbourhoods cover every possible viewer of a one-tile move.
    const related = new Map<string, PlayerSession>();
    for (const other of this.nearby(player, previous)) {
      related.set(other.accountId, other);
    }
    for (const other of nearbyNow) {
      related.set(other.accountId, other);
    }
    for (const other of related.values()) {
      const visible = this.canSee(other.character, player.character);
      const known = other.visiblePlayers.has(player.accountId);
      if (visible && !known) {
        other.visiblePlayers.add(player.accountId);
        this.send(other.conn, {
          type: "player_joined",
          player: publicPlayer(player)
        });
      } else if (!visible && known) {
        other.visiblePlayers.delete(player.accountId);
        this.send(other.conn, {
          type: "player_left",
          playerId: player.character.id
        });
      }
    }
  }

  /** Sends an event to every nearby player who currently sees this character. */
  broadcast(player: PlayerSession, message: Dict): void {
    for (const other of this.nearby(player, player.character)) {
      if (!other.visiblePlayers.has(player.accountId)) continue;
      this.send(other.conn, message);
    }
  }

  /**
   * Remove a character from everyone's view and from the spatial index. Call
   * this before changing map/position and before removing the session.
   */
  clear(player: PlayerSession, notify = true): void {
    for (const other of this.nearby(player, player.character)) {
      if (!other.visiblePlayers.delete(player.accountId)) continue;
      if (notify) {
        this.send(other.conn, {
          type: "player_left",
          playerId: player.character.id
        });
      }
    }
    player.visiblePlayers.clear();
    this.index.remove(player);
    this.byId.delete(player.accountId);
  }

  dispose(): void {
    this.index.clear();
    this.byId.clear();
  }

  private nearby(player: PlayerSession, at: Position): PlayerSession[] {
    return this.index
      .query(at.mapId, at.x, at.y, CONFIG.playerViewRadius)
      .filter((other) => other.accountId !== player.accountId);
  }

  private canSee(a: Position, b: Position): boolean {
    return withinView(a, b, CONFIG.playerViewRadius);
  }
}
