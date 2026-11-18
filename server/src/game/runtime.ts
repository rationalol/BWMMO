import type {
  EncounterEntry,
  GameContent,
  MapDef,
  StoryTrainerDef
} from "../content/types.js";
import type { ContentLocalizer } from "../i18n/localizer.js";
import type { Store } from "../store.js";
import type { JournalEntry } from "./journal.js";
import type { Conn, Dict, PlayerSession } from "./protocol.js";
import type { StoryController } from "./story.js";
import type { VisibilityService } from "./visibility.js";

/**
 * The surface domain controllers use to talk to the server shell. Keeping it
 * explicit prevents controllers from reaching into each other and makes the
 * GameServer class a composition root instead of a god object.
 */
export interface GameHost {
  readonly content: GameContent;
  readonly i18n: ContentLocalizer;
  readonly store: Store;
  readonly visibility: VisibilityService;
  readonly story: StoryController;

  map(mapId: string): MapDef;
  locationName(locale: string, mapId: string, x: number, y: number): string;

  send(conn: Conn, message: Dict): void;
  sendError(conn: Conn, message: string): void;
  sendJournal(player: PlayerSession, entry: JournalEntry): void;
  sendMapState(player: PlayerSession): void;
  sendPartyState(player: PlayerSession): void;
  sendPokedexState(player: PlayerSession, includeEntries: boolean): void;
  sendNextMoveLearn(player: PlayerSession): void;

  /** Look up a live session by its public character id. */
  onlinePlayer(characterId: string): PlayerSession | null;

  /** Re-index a player after a teleport, send map_state and refresh visibility. */
  afterTeleport(player: PlayerSession): void;
  startWildBattle(player: PlayerSession, map: MapDef, entry: EncounterEntry): void;

  /** Start a scripted trainer battle; the scene waits for its result. */
  startTrainerBattle(
    player: PlayerSession,
    trainerId: string,
    trainer: StoryTrainerDef
  ): void;
}
