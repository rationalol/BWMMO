import { WebSocket } from "ws";
import type { Dir, NpcDef, StoryStepDef } from "../content/types.js";
import type { TileWindow } from "./maps.js";
import type { CharacterState } from "./types.js";

export type Dict = Record<string, unknown>;

/** One WebSocket connection; a connection owns at most one player session. */
export interface Conn {
  ws: WebSocket;
  ip: string;
  accountId: string | null;
  player: PlayerSession | null;
  locale: string;
  messageTimes: number[];
  alive: boolean;
}

/** A scene instance running for one player. */
export interface StorySessionState {
  sceneId: string;
  /** Next step to execute in `steps`. */
  index: number;
  /**
   * `battle` is the story waiting for a scripted trainer battle to finish;
   * `timer` is a `walk` step waiting for the NPC to reach its last tile.
   */
  awaiting: "advance" | "choice" | "battle" | "timer";
  /** Scene steps plus any player-specific reaction pages. */
  steps: StoryStepDef[];
  startedAt: number;
  /**
   * Tiles the scene has walked NPCs to. The original reads the object's live
   * position, so a second movement sequence starts where the first one ended;
   * mirroring that here keeps authored paths and `facing: "player"` correct
   * after an NPC has already moved.
   */
  npcTiles: Record<string, { x: number; y: number }>;
  /** `battle`: pages queued for the win/lose branch once the battle resolves. */
  pendingBattle?: {
    trainerId: string;
    speaker: string;
    win: string[];
    lose: string[];
    resultFlag?: string;
  };
}

export interface PlayerSession {
  conn: Conn;
  accountId: string;
  username: string;
  character: CharacterState;
  lastMoveAt: number;
  lastChatAt: number;
  lastDirectAt: number;
  battleId: string | null;
  encounterGraceUntil: number;
  /** Accounts whose characters this player currently has on screen. */
  visiblePlayers: Set<string>;
  /** Tile slice last sent to this client, used to decide window refreshes. */
  tileWindow: TileWindow | null;
  /**
   * Door tile the player just arrived on. Portals stay inert until the player
   * steps off it so a wide doorway cannot bounce the player straight back.
   */
  portalLock: { mapId: string; x: number; y: number } | null;
  /** The pending-move prompt currently waiting for a client decision. */
  pendingLearnKey: string | null;
  /** Story scene in progress; movement and services are locked while set. */
  story?: StorySessionState | null;
  /** Last time a locked gate message was sent, so holding a key is quiet. */
  lastStoryGateAt?: number;
  /**
   * A story battle whose result box is still on screen. The scene resumes when
   * the client sends `battle_closed`.
   */
  pendingStoryBattle?: { trainerId: string; result: string } | null;
}

export const DIRECTIONS: Record<Dir, [number, number]> = {
  up: [0, -1],
  down: [0, 1],
  left: [-1, 0],
  right: [1, 0]
};

export const USERNAME_PATTERN = /^[A-Za-z0-9_]{3,20}$/;
export const CHARACTER_NAME_PATTERN = /^[A-Za-z0-9_]{2,16}$/;
export const SUPPORTED_LOCALES = ["en", "zh_CN", "zh_TW", "ja", "ko"];

export function normalizeLocale(value: string): string | null {
  const code = value.trim().replace(/-/g, "_");
  if (SUPPORTED_LOCALES.includes(code)) return code;
  if (code.startsWith("zh")) {
    return /TW|HK|Hant/i.test(code) ? "zh_TW" : "zh_CN";
  }
  if (code.startsWith("ja")) return "ja";
  if (code.startsWith("ko")) return "ko";
  if (code.startsWith("en")) return "en";
  return null;
}

export function asString(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

export function asInt(value: unknown): number | null {
  return typeof value === "number" && Number.isInteger(value) ? value : null;
}

export function publicPlayer(player: PlayerSession) {
  return {
    id: player.character.id,
    name: player.character.name,
    color: player.character.color,
    sprite: player.character.sprite,
    mapId: player.character.mapId,
    x: player.character.x,
    y: player.character.y,
    dir: player.character.dir
  };
}

export function publicNpc(npc: NpcDef) {
  return {
    id: npc.id,
    name: npc.name,
    x: npc.x,
    y: npc.y,
    color: npc.color,
    kind: npc.kind,
    sprite: npc.sprite ?? null,
    movement: npc.movement ?? 0
  };
}

export function sendMessage(conn: Conn, message: Dict): void {
  if (conn.ws.readyState !== WebSocket.OPEN) return;
  try {
    conn.ws.send(JSON.stringify(message));
  } catch (error) {
    console.warn(
      `[net] failed to send '${String(message.type)}':`,
      error instanceof Error ? error.message : error
    );
  }
}

export function sendError(conn: Conn, message: string): void {
  sendMessage(conn, { type: "error", message });
}
