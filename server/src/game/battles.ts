import crypto from "node:crypto";
import { CONFIG } from "../config.js";
import type { EncounterEntry, MapDef, StoryTrainerDef } from "../content/types.js";
import {
  createBattle,
  createTrainerBattle,
  disposeBattle,
  resolveTurn,
  type BattleAction,
  type BattleEvent,
  type BattleState
} from "./battle.js";
import { settleBattle } from "./battle-outcome.js";
import { createCreature, createWildCreature, healParty } from "./creatures.js";
import type { JournalEntry } from "./journal.js";
import { markSpeciesSeen } from "./pokedex.js";
import { asInt, asString, type Dict, type PlayerSession } from "./protocol.js";
import type { GameHost } from "./runtime.js";
import type { CreatureState } from "./types.js";

/** Wild encounters and the authoritative turn loop. */
export class BattleController {
  private readonly battles = new Map<string, BattleState>();
  /** ROM move number (Showdown `num`) -> content move id. */
  private readonly moveIdByRomId = new Map<number, string>();

  constructor(private readonly host: GameHost) {
    for (const move of Object.values(host.content.moves)) {
      if (typeof move.romMoveId === "number") {
        this.moveIdByRomId.set(move.romMoveId, move.id);
      }
    }
  }

  startWildBattle(player: PlayerSession, map: MapDef, entry: EncounterEntry): void {
    const character = player.character;
    if (!character.party.some((creature) => creature.hp > 0)) {
      this.host.send(player.conn, {
        type: "notice",
        text: "Your team is exhausted. Visit a nurse before searching for Pokemon."
      });
      return;
    }
    const level =
      entry.minLevel + Math.floor(Math.random() * (entry.maxLevel - entry.minLevel + 1));
    const wild = createWildCreature(this.host.content, entry.species, level);
    if (markSpeciesSeen(this.host.content, character, wild.species)) {
      this.host.store.saveCharacter(player.accountId, character);
      this.host.sendPokedexState(player, false);
    }
    const party = character.party.map((creature) => structuredClone(creature));
    const battle = createBattle(
      crypto.randomUUID(),
      party,
      wild,
      character.name,
      character.inventory,
      this.host.content.config.maxParty,
      this.host.content.items
    );
    this.battles.set(battle.id, battle);
    player.battleId = battle.id;
    this.host.sendJournal(player, {
      kind: "encounter",
      actor: character.name,
      target: this.host.i18n.speciesName(player.conn.locale, wild.species),
      wild: true
    });
    this.host.send(player.conn, {
      type: "battle_start",
      battle: this.view(player, battle)
    });
    console.log(
      `[battle] ${character.name} encountered wild ${wild.name} L${wild.level} in ${map.id} (${battle.id})`
    );
  }

  /**
   * Story battle against a content trainer. Unlike a wild encounter this is
   * not random and cannot be fled; the story layer decides what follows.
   */
  startTrainerBattle(
    player: PlayerSession,
    trainerId: string,
    trainer: StoryTrainerDef
  ): BattleState | null {
    const character = player.character;
    const content = this.host.content;
    // A scripted battle must never leave the player stuck with a fainted team:
    // the ROM's own scenes heal right before a challenge.
    if (!character.party.some((creature) => creature.hp > 0)) {
      healParty(character.party);
      healParty(character.box);
      this.host.store.saveCharacter(player.accountId, character);
      this.host.sendPartyState(player);
    }
    const opponentParty = trainer.party.map((member) =>
      createCreature(content, member.species, member.level)
    );
    let pokedexChanged = false;
    for (const creature of opponentParty) {
      if (markSpeciesSeen(content, character, creature.species)) pokedexChanged = true;
    }
    if (pokedexChanged) this.host.sendPokedexState(player, false);

    const party = character.party.map((creature) => structuredClone(creature));
    const battle = createTrainerBattle(
      crypto.randomUUID(),
      party,
      opponentParty,
      trainer.name,
      character.name,
      character.inventory,
      content.config.maxParty,
      content.items,
      { id: trainerId, reward: trainer.reward ?? 0 }
    );
    this.battles.set(battle.id, battle);
    player.battleId = battle.id;
    // `battle.mode` tells the client to use a trainer banner and hide Run.
    this.host.send(player.conn, {
      type: "battle_start",
      battle: this.view(player, battle)
    });
    console.log(
      `[battle] ${character.name} challenged ${trainer.name} (${trainerId}) with ${opponentParty.length} creature(s)`
    );
    return battle;
  }

  handleAction(conn: PlayerSession["conn"], msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    const battleId = asString(msg.battleId) ?? "";
    const battle = this.battles.get(battleId);
    if (!battle || player.battleId !== battleId) {
      this.host.sendError(conn, "That battle is not active.");
      return;
    }

    let action: BattleAction;
    if (msg.action === "run") {
      action = { action: "run" };
    } else if (msg.action === "catch") {
      const itemId = asString(msg.itemId) ?? "poke_ball";
      action = { action: "catch", itemId };
      if (player.character.party.length >= this.host.content.config.maxParty) {
        this.host.sendError(conn, "Your party is full.");
        return;
      }
    } else if (msg.action === "item") {
      const itemId = asString(msg.itemId) ?? "";
      const partyIndex = asInt(msg.partyIndex);
      if (itemId === "" || partyIndex === null) {
        this.host.sendError(conn, "An item and target are required.");
        return;
      }
      action = { action: "item", itemId, partyIndex };
    } else if (msg.action === "switch") {
      const partyIndex = asInt(msg.partyIndex);
      if (partyIndex === null) {
        this.host.sendError(conn, "A party index is required.");
        return;
      }
      action = { action: "switch", partyIndex };
    } else if (msg.action === "move") {
      const moveIndex = asInt(msg.moveIndex);
      if (moveIndex === null) {
        this.host.sendError(conn, "A move index is required.");
        return;
      }
      action = { action: "move", moveIndex };
    } else {
      this.host.sendError(conn, "Unknown battle action.");
      return;
    }

    try {
      resolveTurn(battle, action);
    } catch (error) {
      this.host.sendError(conn, error instanceof Error ? error.message : "Invalid battle action.");
      return;
    }

    this.journalTurn(player, battle, action);
    this.syncToCharacter(player, battle);
    this.host.store.saveCharacter(player.accountId, player.character);

    if (battle.status === "active") {
      this.host.send(conn, { type: "battle_turn", battle: this.view(player, battle) });
    } else {
      this.finishBattle(player, battle);
    }
  }

  view(player: PlayerSession, battle: BattleState): BattleState {
    const locale = player.conn.locale;
    return {
      ...battle,
      party: battle.party.map((creature) => this.host.i18n.creature(locale, creature)),
      player: this.host.i18n.creature(locale, battle.player),
      wild: this.host.i18n.creature(locale, battle.wild),
      events: battle.events.map((event) =>
        event.type === "ability"
          ? {
              ...event,
              abilityName: this.host.i18n.abilityName(locale, event.abilityId),
              description: this.host.i18n.abilityDescription(locale, event.abilityId)
            }
          : event
      )
    };
  }

  private localizedCreatureName(player: PlayerSession, creature: CreatureState): string {
    return this.host.i18n.creature(player.conn.locale, creature).name;
  }

  /** Saved names are canonical English unless the player nicknamed the creature. */
  private localizedSavedName(player: PlayerSession, name: string, speciesId: string): string {
    const species = this.host.content.species[speciesId];
    return species && name === species.name
      ? this.host.i18n.speciesName(player.conn.locale, speciesId)
      : name;
  }

  private localizedMoveName(
    player: PlayerSession,
    moveId: number,
    fallback: string
  ): string {
    const contentId = this.moveIdByRomId.get(moveId);
    return contentId
      ? this.host.i18n.moveName(player.conn.locale, contentId)
      : fallback;
  }

  /** Turns the structured battle events of one turn into journal lines. */
  private journalTurn(player: PlayerSession, battle: BattleState, action: BattleAction): void {
    const locale = player.conn.locale;
    const wildName = this.localizedCreatureName(player, battle.wild);
    const playerName = this.localizedCreatureName(player, battle.player);
    const journal = (entry: JournalEntry) => this.host.sendJournal(player, entry);

    if (action.action === "catch") {
      journal({
        kind: "ball",
        actor: player.character.name,
        item: this.host.i18n.itemName(locale, action.itemId ?? "poke_ball")
      });
    }

    for (const event of battle.events) {
      switch (event.type) {
        case "move":
          journal({
            kind: "move",
            actor: event.side === "wild" ? wildName : playerName,
            move: this.localizedMoveName(player, event.moveId, event.moveName)
          });
          break;
        case "faint":
          // A wild faint is followed by the settlement's "defeated" line.
          if (event.side === "player") journal({ kind: "faint", actor: playerName });
          break;
        case "switch":
          if (event.side === "player") journal({ kind: "switch", target: playerName });
          break;
        case "run":
          journal({
            kind: event.success ? "flee" : "escape_failed",
            actor: player.character.name
          });
          break;
        case "catch":
          if (!event.success) {
            journal({ kind: "broke_free", target: wildName, wild: true });
          }
          break;
        case "item":
          journal({
            kind: "item_used",
            actor: player.character.name,
            item: this.host.i18n.itemName(locale, event.itemId),
            target: this.localizedCreatureName(
              player,
              battle.party[event.targetIndex] ?? battle.player
            )
          });
          break;
      }
    }
  }

  /** Localized snapshot of the player's active battle, if any. */
  activeView(player: PlayerSession): BattleState | null {
    if (!player.battleId) return null;
    const battle = this.battles.get(player.battleId);
    return battle ? this.view(player, battle) : null;
  }

  /** Release every Showdown session; used when the server shuts down. */
  clear(): void {
    for (const battleId of this.battles.keys()) {
      disposeBattle(battleId);
    }
    this.battles.clear();
  }

  /** Flush a live battle back onto the character before the session leaves. */
  detach(player: PlayerSession): void {
    if (!player.battleId) return;
    const battle = this.battles.get(player.battleId);
    if (battle) {
      this.syncToCharacter(player, battle);
      this.battles.delete(player.battleId);
      disposeBattle(player.battleId);
    }
    player.battleId = null;
  }

  private syncToCharacter(player: PlayerSession, battle: BattleState): void {
    for (let index = 0; index < battle.party.length; index++) {
      const characterCreature = player.character.party[index];
      if (characterCreature) {
        characterCreature.hp = battle.party[index].hp;
        characterCreature.status = battle.party[index].status;
        characterCreature.moves = structuredClone(battle.party[index].moves);
        if (battle.party[index].pendingMoves) {
          characterCreature.pendingMoves = [...battle.party[index].pendingMoves!];
        } else {
          delete characterCreature.pendingMoves;
        }
      }
    }
    player.character.inventory = structuredClone(battle.inventory);
  }

  private finishBattle(player: PlayerSession, battle: BattleState): void {
    const character = player.character;
    // A black-out moves the character home, so detach from the old area first.
    if (battle.status === "lost") {
      this.host.visibility.clear(player);
    }
    const settlement = settleBattle(this.host.content, character, battle);

    player.battleId = null;
    this.battles.delete(battle.id);
    disposeBattle(battle.id);
    player.encounterGraceUntil = Date.now() + CONFIG.encounterGraceMs;
    if (battle.mode === "trainer" && battle.trainerId) {
      // The result box is still on screen. The story resumes once the client
      // reports that the player closed it (message `battle_closed`).
      player.pendingStoryBattle = {
        trainerId: battle.trainerId,
        result: battle.status
      };
    }
    this.host.store.saveCharacter(player.accountId, character);

    this.host.send(player.conn, {
      type: "battle_turn",
      battle: this.view(player, battle)
    });
    if (settlement.pokedexChanged) {
      this.host.sendPokedexState(player, false);
    }

    if (settlement.travel) {
      this.host.afterTeleport(player);
    }

    const locale = player.conn.locale;
    const evolution = settlement.evolution
      ? {
          ...settlement.evolution,
          fromName: this.host.i18n.speciesName(locale, settlement.evolution.fromSpecies),
          toName: this.host.i18n.speciesName(locale, settlement.evolution.toSpecies)
        }
      : settlement.evolution;
    this.host.send(player.conn, {
      type: "battle_end",
      battleId: battle.id,
      result: settlement.result,
      message: settlement.message,
      travel: settlement.travel,
      evolution,
      battle: this.view(player, battle),
      player: {
        money: character.money,
        wins: character.wins,
        party: this.host.i18n.character(locale, character).party,
        inventory: character.inventory,
        pokedex: character.pokedex ?? { seen: [], caught: [] },
        sprite: character.sprite,
        mapId: character.mapId,
        x: character.x,
        y: character.y,
        dir: character.dir
      }
    });
    const wildName = this.localizedCreatureName(player, battle.wild);
    if (settlement.result === "caught") {
      this.host.sendJournal(player, {
        kind: "catch",
        actor: character.name,
        target: wildName,
        wild: true
      });
    } else if (settlement.result === "won") {
      this.host.sendJournal(player, {
        kind: "defeat",
        actor: character.name,
        target: wildName,
        wild: true,
        money: this.host.content.config.winReward
      });
    } else if (settlement.result === "lost") {
      this.host.sendJournal(player, { kind: "blackout", actor: character.name });
    }
    for (const levelUp of settlement.levelUps) {
      this.host.sendJournal(player, {
        kind: "level_up",
        actor: this.localizedSavedName(player, levelUp.name, levelUp.species),
        level: levelUp.level
      });
    }
    for (const learned of settlement.learnedMoves) {
      this.host.sendJournal(player, {
        kind: "learn_move",
        actor: this.localizedSavedName(player, learned.name, learned.species),
        move: this.host.i18n.moveName(locale, learned.moveId)
      });
    }
    const evolved = settlement.evolution;
    if (evolved) {
      this.host.sendJournal(player, {
        kind: "evolution",
        actor: this.localizedSavedName(player, evolved.fromName, evolved.fromSpecies),
        target: this.localizedSavedName(player, evolved.toName, evolved.toSpecies)
      });
    }
    this.host.sendNextMoveLearn(player);
    console.log(
      `[battle] ${character.name} ${settlement.result} (${battle.id}); money=${character.money} wins=${character.wins} party=${character.party.length}`
    );
  }
}
