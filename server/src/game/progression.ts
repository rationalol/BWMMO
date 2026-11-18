import { forgetMove, pendingMovesFor, resolvePendingMove } from "./creatures.js";
import { asInt, asString, type Dict, type PlayerSession } from "./protocol.js";
import type { GameHost } from "./runtime.js";
import type { CharacterState, CreatureState } from "./types.js";

/** Party/Dex snapshots and the queued level-up move prompts. */
export class ProgressionController {
  private readonly pokedexCatalogCache = new Map<string, Dict[]>();

  constructor(private readonly host: GameHost) {}

  sendPartyState(player: PlayerSession): void {
    const character = player.character;
    const view = this.host.i18n.character(player.conn.locale, character);
    this.host.send(player.conn, {
      type: "party_state",
      party: view.party,
      box: view.box,
      inventory: character.inventory,
      money: character.money,
      wins: character.wins,
      pokedex: character.pokedex ?? { seen: [], caught: [] },
      maxParty: this.host.content.config.maxParty,
      maxBox: this.host.content.config.maxBox
    });
  }

  sendPokedexState(player: PlayerSession, includeEntries: boolean): void {
    const pokedex = player.character.pokedex ?? { seen: [], caught: [] };
    this.host.send(player.conn, {
      type: "pokedex_state",
      seen: pokedex.seen,
      caught: pokedex.caught,
      total: Object.keys(this.host.content.species).length,
      entries: includeEntries ? this.pokedexCatalog(player.conn.locale) : undefined
    });
  }

  handlePokedexRequest(conn: PlayerSession["conn"]): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    this.sendPokedexState(player, true);
  }

  /**
   * Sends one prompt at a time. The decision is persisted on the creature, so
   * reconnecting or closing the client cannot lose a queued level-up move.
   */
  sendNextMoveLearn(player: PlayerSession): void {
    if (player.battleId) return;
    const next = this.firstPendingLearn(player.character);
    if (!next) {
      player.pendingLearnKey = null;
      return;
    }
    const key = `${next.source}:${next.index}:${next.moveId}`;
    if (player.pendingLearnKey === key) return;
    const move = this.host.content.moves[next.moveId];
    if (!move) {
      player.pendingLearnKey = null;
      return;
    }
    player.pendingLearnKey = key;
    const view = this.host.i18n.creature(player.conn.locale, next.creature);
    this.host.send(player.conn, {
      type: "move_learn_request",
      source: next.source,
      index: next.index,
      moveId: next.moveId,
      move: { ...move, name: this.host.i18n.moveName(player.conn.locale, move.id) },
      moves: view.moves,
      creatureName: view.name,
      creatureLevel: next.creature.level
    });
  }

  handleLearnMove(conn: PlayerSession["conn"], msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    if (player.battleId) {
      this.host.sendError(conn, "Finish the battle first.");
      return;
    }
    const source = asString(msg.source);
    if (source !== "party" && source !== "box") {
      this.host.sendError(conn, "Choose a valid creature.");
      return;
    }
    const index = asInt(msg.index);
    const list = source === "party" ? player.character.party : player.character.box;
    if (index === null || index < 0 || index >= list.length) {
      this.host.sendError(conn, "That creature does not exist.");
      return;
    }
    const moveId = asString(msg.moveId) ?? "";
    const rawReplace = msg.replaceIndex;
    let replaceIndex: number | null;
    if (rawReplace === null || rawReplace === undefined || rawReplace === -1) {
      replaceIndex = null;
    } else {
      replaceIndex = asInt(rawReplace);
      if (replaceIndex === null) {
        this.host.sendError(conn, "Choose a move slot to replace.");
        return;
      }
    }
    const creature = list[index];
    const result = resolvePendingMove(this.host.content, creature, moveId, replaceIndex);
    if (!result.ok) {
      this.host.sendError(conn, result.error ?? "That move cannot be learned.");
      // The client closes its prompt when it sends a decision. Re-send the
      // still-pending request so a stale slot choice cannot strand the queue.
      player.pendingLearnKey = null;
      this.sendNextMoveLearn(player);
      return;
    }
    player.pendingLearnKey = null;
    this.host.store.saveCharacter(player.accountId, player.character);
    this.sendPartyState(player);
    const moveName =
      result.move?.name ?? this.host.content.moves[moveId]?.name ?? "the move";
    this.host.send(conn, {
      type: "notice",
      text: result.skipped
        ? `${creature.name} did not learn ${moveName}.`
        : `${creature.name} learned ${moveName}!`
    });
    if (!result.skipped) {
      this.host.sendJournal(player, {
        kind: "learn_move",
        actor: this.host.i18n.creature(player.conn.locale, creature).name,
        move: this.host.i18n.moveName(player.conn.locale, moveId)
      });
    }
    this.sendNextMoveLearn(player);
  }

  handleForgetMove(conn: PlayerSession["conn"], msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    if (player.battleId) {
      this.host.sendError(conn, "Finish the battle first.");
      return;
    }
    const partyIndex = asInt(msg.partyIndex);
    const moveIndex = asInt(msg.moveIndex);
    if (
      partyIndex === null ||
      partyIndex < 0 ||
      partyIndex >= player.character.party.length ||
      moveIndex === null
    ) {
      this.host.sendError(conn, "Choose a party member and move first.");
      return;
    }
    const creature = player.character.party[partyIndex];
    const result = forgetMove(creature, moveIndex);
    if (!result.ok) {
      this.host.sendError(conn, result.error ?? "That move cannot be forgotten.");
      return;
    }
    this.host.store.saveCharacter(player.accountId, player.character);
    this.sendPartyState(player);
    this.host.send(conn, {
      type: "notice",
      text: `${creature.name} forgot ${result.move?.name ?? "the move"}.`
    });
    if (result.move) {
      this.host.sendJournal(player, {
        kind: "forget_move",
        actor: this.host.i18n.creature(player.conn.locale, creature).name,
        move: this.host.i18n.moveName(player.conn.locale, result.move.id)
      });
    }
    this.sendNextMoveLearn(player);
  }

  private firstPendingLearn(
    character: CharacterState
  ): { source: "party" | "box"; index: number; creature: CreatureState; moveId: string } | null {
    const collections: Array<["party" | "box", CreatureState[]]> = [
      ["party", character.party],
      ["box", character.box]
    ];
    for (const [source, creatures] of collections) {
      for (let index = 0; index < creatures.length; index++) {
        const moveId = pendingMovesFor(creatures[index])[0];
        if (moveId) return { source, index, creature: creatures[index], moveId };
      }
    }
    return null;
  }

  private pokedexCatalog(locale: string): Dict[] {
    const cached = this.pokedexCatalogCache.get(locale);
    if (cached) return cached;
    const catalog = Object.values(this.host.content.species)
      .sort((a, b) => a.dex - b.dex)
      .map((species) => ({
        dex: species.dex,
        id: species.id,
        name: this.host.i18n.speciesName(locale, species.id),
        types: species.types,
        evolutions: species.evolutions.map((evolution) => ({
          to: evolution.to,
          name: this.host.i18n.speciesName(locale, evolution.to),
          method: evolution.method,
          level: evolution.level ?? null
        }))
      }));
    this.pokedexCatalogCache.set(locale, catalog);
    return catalog;
  }
}
