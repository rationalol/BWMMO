import crypto from "node:crypto";
import { CONFIG } from "../config.js";
import {
  createDuelBattle,
  disposeBattle,
  duelViewFor,
  submitDuelTurn,
  type BattleAction,
  type BattleState,
  type DuelSide
} from "./battle.js";
import { healParty } from "./creatures.js";
import {
  asInt,
  asString,
  type Conn,
  type Dict,
  type PlayerSession
} from "./protocol.js";
import type { GameHost } from "./runtime.js";

const DUEL_REQUEST_TTL_MS = 30_000;

interface PendingDuel {
  from: PlayerSession;
  to: PlayerSession;
  fromId: string;
  toId: string;
  expiresAt: number;
  timer: ReturnType<typeof setTimeout>;
}

interface ActiveDuel {
  battle: BattleState;
  p1: PlayerSession;
  p2: PlayerSession;
}

/**
 * Friend duels: a pseudo-persistent invite handshake, then a two-player
 * Showdown battle. Unlike wild encounters, a duel has no bag, no Balls and no
 * running; both parties are cloned into the simulator and healed afterwards.
 */
export class DuelController {
  private readonly pendingFrom = new Map<string, PendingDuel>();
  private readonly pendingTo = new Map<string, PendingDuel>();
  private readonly activeByBattle = new Map<string, ActiveDuel>();
  private readonly activeByAccount = new Map<string, ActiveDuel>();

  constructor(private readonly host: GameHost) {}

  handleRequest(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    const targetId = asString(msg.playerId)?.trim() ?? "";
    if (targetId === "") {
      this.host.sendError(conn, "Choose a friend to duel.");
      return;
    }
    const target = this.host.onlinePlayer(targetId);
    if (!target) {
      this.host.sendError(conn, "That trainer is not online.");
      return;
    }
    if (target.accountId === player.accountId) {
      this.host.sendError(conn, "You cannot duel yourself.");
      return;
    }
    const playerFriends = player.character.friends ?? [];
    const targetFriends = target.character.friends ?? [];
    if (
      !playerFriends.includes(target.character.id) ||
      !targetFriends.includes(player.character.id)
    ) {
      this.host.sendError(conn, "You can only duel friends.");
      return;
    }
    if (player.battleId || target.battleId) {
      this.host.sendError(conn, "Both trainers need to be out of battle first.");
      return;
    }
    if (!hasHealthyCreature(player) || !hasHealthyCreature(target)) {
      this.host.sendError(conn, "Both trainers need a healthy Pokémon.");
      return;
    }
    if (this.pendingFrom.has(player.character.id)) {
      this.host.sendError(conn, "You already have a duel request pending.");
      return;
    }
    if (this.pendingTo.has(target.character.id)) {
      this.host.sendError(conn, "That trainer already has a duel request.");
      return;
    }

    const expiresAt = Date.now() + DUEL_REQUEST_TTL_MS;
    const request: PendingDuel = {
      from: player,
      to: target,
      fromId: player.character.id,
      toId: target.character.id,
      expiresAt,
      timer: setTimeout(() => this.expire(request), DUEL_REQUEST_TTL_MS)
    };
    request.timer.unref?.();
    this.pendingFrom.set(request.fromId, request);
    this.pendingTo.set(request.toId, request);

    this.host.send(player.conn, {
      type: "duel_request_sent",
      toId: target.character.id,
      toName: target.character.name,
      expiresAt
    });
    this.host.send(target.conn, {
      type: "duel_request",
      fromId: player.character.id,
      fromName: player.character.name,
      expiresAt
    });
    this.host.send(player.conn, {
      type: "notice",
      text: `Duel request sent to ${target.character.name}.`
    });
    this.host.send(target.conn, {
      type: "notice",
      text: `${player.character.name} challenges you to a duel!`
    });
    console.log(
      `[duel] ${player.character.name} -> ${target.character.name} request`
    );
  }

  handleAccept(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    const requesterId = asString(msg.playerId)?.trim() ?? "";
    if (requesterId === "") {
      this.host.sendError(conn, "Choose a duel request first.");
      return;
    }
    const request = this.pendingTo.get(player.character.id);
    if (!request || request.from.character.id !== requesterId) {
      this.host.sendError(conn, "That duel request is no longer available.");
      return;
    }
    const requester = request.from;

    if (this.host.onlinePlayer(requester.character.id) !== requester) {
      this.host.sendError(conn, "That trainer is no longer online.");
      return;
    }
    if (requester.battleId || player.battleId) {
      this.host.sendError(conn, "Both trainers need to be out of battle first.");
      return;
    }
    if (!hasHealthyCreature(requester) || !hasHealthyCreature(player)) {
      this.host.sendError(conn, "Both trainers need a healthy Pokémon.");
      return;
    }

    this.clearPending(request);
    this.cancelForPlayer(requester);
    this.cancelForPlayer(player);
    let battle: BattleState;
    try {
      battle = createDuelBattle(
        crypto.randomUUID(),
        requester.character.party.map((creature) => structuredClone(creature)),
        requester.character.name,
        player.character.party.map((creature) => structuredClone(creature)),
        player.character.name,
        this.host.content.config.maxParty
      );
    } catch (error) {
      this.host.sendError(
        conn,
        error instanceof Error ? error.message : "The duel could not start."
      );
      this.host.send(requester.conn, {
        type: "duel_request_cancelled",
        toId: player.character.id,
        name: player.character.name
      });
      this.host.send(player.conn, {
        type: "duel_request_cancelled",
        fromId: requester.character.id,
        name: requester.character.name
      });
      return;
    }

    const duel: ActiveDuel = { battle, p1: requester, p2: player };
    this.activeByBattle.set(battle.id, duel);
    this.activeByAccount.set(requester.accountId, duel);
    this.activeByAccount.set(player.accountId, duel);
    requester.battleId = battle.id;
    player.battleId = battle.id;

    this.host.send(requester.conn, {
      type: "battle_start",
      battle: this.viewFor(requester, duel)
    });
    this.host.send(player.conn, {
      type: "battle_start",
      battle: this.viewFor(player, duel)
    });
    console.log(
      `[duel] ${requester.character.name} vs ${player.character.name} started (${battle.id})`
    );
  }

  handleDecline(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    const requesterId = asString(msg.playerId)?.trim() ?? "";
    const request = this.pendingTo.get(player.character.id);
    if (!request || request.from.character.id !== requesterId) {
      this.host.sendError(conn, "That duel request is no longer available.");
      return;
    }
    this.clearPending(request);
    this.host.send(request.from.conn, {
      type: "duel_declined",
      playerId: player.character.id,
      name: player.character.name
    });
    this.host.send(request.from.conn, {
      type: "notice",
      text: `${player.character.name} declined your duel request.`
    });
    this.host.send(player.conn, { type: "notice", text: "Duel request declined." });
    console.log(
      `[duel] ${player.character.name} declined ${request.from.character.name}`
    );
  }

  handleCancel(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    const targetId = asString(msg.playerId)?.trim() ?? "";
    const request = this.pendingFrom.get(player.character.id);
    if (!request || request.to.character.id !== targetId) {
      this.host.sendError(conn, "That duel request is no longer pending.");
      return;
    }
    this.clearPending(request);
    this.host.send(request.to.conn, {
      type: "duel_request_cancelled",
      fromId: player.character.id,
      name: player.character.name
    });
    this.host.send(request.to.conn, {
      type: "notice",
      text: `${player.character.name} cancelled their duel request.`
    });
    this.host.send(player.conn, {
      type: "duel_request_cancelled",
      toId: request.to.character.id,
      name: request.to.character.name
    });
    this.host.send(player.conn, { type: "notice", text: "Duel request cancelled." });
  }

  /** Cancels queued invites for a player entering a wild battle or disconnecting. */
  cancelForPlayer(player: PlayerSession): void {
    const outgoing = this.pendingFrom.get(player.character.id);
    if (outgoing) {
      this.clearPending(outgoing);
      this.host.send(outgoing.to.conn, {
        type: "duel_request_cancelled",
        fromId: player.character.id,
        name: player.character.name
      });
      this.host.send(outgoing.to.conn, {
        type: "notice",
        text: `${player.character.name} cancelled their duel request.`
      });
      this.host.send(player.conn, {
        type: "duel_request_cancelled",
        toId: outgoing.to.character.id,
        name: outgoing.to.character.name
      });
    }
    const incoming = this.pendingTo.get(player.character.id);
    if (incoming) {
      this.clearPending(incoming);
      this.host.send(incoming.from.conn, {
        type: "duel_request_cancelled",
        toId: player.character.id,
        name: player.character.name
      });
      this.host.send(incoming.from.conn, {
        type: "notice",
        text: `${player.character.name} is no longer available for a duel.`
      });
    }
  }

  /** Returns true when the message belonged to an active duel. */
  handleAction(conn: Conn, msg: Dict): boolean {
    const player = conn.player;
    if (!player || !player.battleId) return false;
    const duel = this.activeByAccount.get(player.accountId);
    if (!duel || duel.battle.id !== player.battleId) return false;

    let action: BattleAction;
    if (msg.action === "run") {
      action = { action: "run" };
    } else if (msg.action === "catch") {
      action = { action: "catch", itemId: asString(msg.itemId) ?? "poke_ball" };
    } else if (msg.action === "item") {
      action = {
        action: "item",
        itemId: asString(msg.itemId) ?? "",
        partyIndex: asInt(msg.partyIndex) ?? -1
      };
    } else if (msg.action === "switch") {
      action = { action: "switch", partyIndex: asInt(msg.partyIndex) ?? -1 };
    } else if (msg.action === "move") {
      action = { action: "move", moveIndex: asInt(msg.moveIndex) ?? -1 };
    } else {
      this.host.sendError(conn, "Unknown battle action.");
      return true;
    }

    const side: DuelSide = duel.p1.accountId === player.accountId ? "p1" : "p2";
    let resolved: boolean;
    try {
      resolved = submitDuelTurn(duel.battle, side, action).resolved;
    } catch (error) {
      this.host.sendError(
        conn,
        error instanceof Error ? error.message : "Invalid battle action."
      );
      return true;
    }

    if (duel.battle.status !== "active") {
      this.finishDuel(duel);
      return true;
    }
    if (resolved) {
      for (const participant of [duel.p1, duel.p2]) {
        this.host.send(participant.conn, {
          type: "battle_turn",
          battle: this.viewFor(participant, duel)
        });
      }
    } else {
      this.host.send(player.conn, {
        type: "battle_turn",
        battle: this.viewFor(player, duel)
      });
    }
    return true;
  }

  /** Release a player's active duel when their socket leaves. */
  detach(player: PlayerSession): void {
    this.cancelForPlayer(player);
    const duel = this.activeByAccount.get(player.accountId);
    if (duel) this.finishDuel(duel, player);
  }

  activeView(player: PlayerSession): BattleState | null {
    const duel = this.activeByAccount.get(player.accountId);
    if (!duel || duel.battle.status !== "active") return null;
    const view = this.viewFor(player, duel);
    // A locale refresh is a snapshot, not a new turn; do not replay effects.
    view.events = [];
    return view;
  }

  clear(): void {
    for (const request of this.pendingFrom.values()) {
      clearTimeout(request.timer);
    }
    this.pendingFrom.clear();
    this.pendingTo.clear();
    for (const battleId of this.activeByBattle.keys()) {
      disposeBattle(battleId);
    }
    this.activeByBattle.clear();
    this.activeByAccount.clear();
  }

  private finishDuel(duel: ActiveDuel, forfeiter?: PlayerSession): void {
    if (this.activeByBattle.get(duel.battle.id) !== duel) return;
    this.activeByBattle.delete(duel.battle.id);
    this.activeByAccount.delete(duel.p1.accountId);
    this.activeByAccount.delete(duel.p2.accountId);

    if (forfeiter) {
      duel.battle.status = forfeiter === duel.p1 ? "lost" : "won";
      duel.battle.log.push(`${forfeiter.character.name} left the duel.`);
      duel.battle.events = [];
      duel.battle.eventsOpponent = [];
      duel.battle.awaitingAction = false;
      duel.battle.awaitingOpponent = false;
      duel.battle.mustSwitch = false;
      duel.battle.mustSwitchOpponent = false;
    }

    for (const participant of [duel.p1, duel.p2]) {
      const side: DuelSide = participant === duel.p1 ? "p1" : "p2";
      const finalParty =
        side === "p1" ? duel.battle.party : duel.battle.opponentParty ?? [];
      participant.character.party = finalParty.map((creature) =>
        structuredClone(creature)
      );
      // Friendly sparring restores both teams; no money, wins or XP change.
      healParty(participant.character.party);
      participant.battleId = null;
      participant.encounterGraceUntil = Date.now() + CONFIG.encounterGraceMs;
      this.host.store.saveCharacter(participant.accountId, participant.character);
    }

    for (const participant of [duel.p1, duel.p2]) {
      const other = participant === duel.p1 ? duel.p2 : duel.p1;
      const battle = this.viewFor(participant, duel);
      const result: "won" | "lost" = battle.status === "won" ? "won" : "lost";
      const message =
        result === "won"
          ? `You won the duel against ${other.character.name}!`
          : `You lost the duel against ${other.character.name}.`;
      const character = participant.character;
      const locale = participant.conn.locale;
      this.host.send(participant.conn, {
        type: "battle_end",
        battleId: duel.battle.id,
        result,
        message,
        travel: false,
        evolution: null,
        battle,
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
    }

    disposeBattle(duel.battle.id);
    console.log(
      `[duel] ${duel.p1.character.name} vs ${duel.p2.character.name} ended (${duel.battle.id}, ${duel.battle.status})`
    );
  }

  private expire(request: PendingDuel): void {
    if (this.pendingFrom.get(request.fromId) !== request) return;
    this.clearPending(request);
    const fromName = request.from.character.name;
    const toName = request.to.character.name;
    this.host.send(request.from.conn, {
      type: "duel_request_expired",
      toId: request.toId,
      name: toName
    });
    this.host.send(request.from.conn, {
      type: "notice",
      text: "Your duel request expired."
    });
    this.host.send(request.to.conn, {
      type: "duel_request_expired",
      fromId: request.fromId,
      name: fromName
    });
    this.host.send(request.to.conn, {
      type: "notice",
      text: `Duel request from ${fromName} expired.`
    });
  }

  private clearPending(request: PendingDuel): void {
    clearTimeout(request.timer);
    if (this.pendingFrom.get(request.fromId) === request) {
      this.pendingFrom.delete(request.fromId);
    }
    if (this.pendingTo.get(request.toId) === request) {
      this.pendingTo.delete(request.toId);
    }
  }

  private viewFor(player: PlayerSession, duel: ActiveDuel): BattleState {
    const side: DuelSide = duel.p1.accountId === player.accountId ? "p1" : "p2";
    const base = duelViewFor(duel.battle, side);
    const locale = player.conn.locale;
    return {
      ...base,
      party: base.party.map((creature) => this.host.i18n.creature(locale, creature)),
      player: this.host.i18n.creature(locale, base.player),
      wild: this.host.i18n.creature(locale, base.wild),
      events: base.events.map((event) =>
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
}

function hasHealthyCreature(player: PlayerSession): boolean {
  return player.character.party.some((creature) => creature.hp > 0);
}
