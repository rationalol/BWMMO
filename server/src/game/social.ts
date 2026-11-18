import { CONFIG } from "../config.js";
import { asString, type Conn, type Dict, type PlayerSession } from "./protocol.js";
import type { GameHost } from "./runtime.js";
import type { CharacterState } from "./types.js";

export const MAX_FRIENDS = 50;
const MAX_NEARBY = 30;
const MAX_OUTGOING_REQUESTS = 20;

interface FriendView {
  id: string;
  name: string;
  online: boolean;
  mapId?: string;
  location?: string;
}

interface RequestView {
  id: string;
  name: string;
  online: boolean;
  at: number;
}

interface NearbyView {
  id: string;
  name: string;
  distance: number;
  mapId: string;
  location: string;
  friend: boolean;
  /** This player has a pending request to the nearby trainer. */
  requested: boolean;
  /** The nearby trainer has a pending request to this player. */
  incoming: boolean;
}

interface ResolvedCharacter {
  accountId: string;
  character: CharacterState;
  online: PlayerSession | null;
}

/**
 * Friend requests, mutual friend lists and direct messages. A friendship only
 * exists after the recipient accepts; pending requests are persisted in the
 * store so they survive a restart and offline recipients.
 */
export class SocialController {
  constructor(private readonly host: GameHost) {}

  handleRequest(conn: Conn): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    this.sendSocialState(player);
  }

  /** `friend_request`: create a pending request instead of adding directly. */
  handleFriendRequest(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    const target = this.resolveTarget(msg);
    if (!target) {
      this.host.sendError(conn, "That trainer does not exist.");
      return;
    }
    const character = player.character;
    const targetCharacter = target.character;
    if (targetCharacter.id === character.id) {
      this.host.sendError(conn, "You cannot add yourself.");
      return;
    }
    character.friends ??= [];
    targetCharacter.friends ??= [];
    if (character.friends.includes(targetCharacter.id)) {
      this.host.send(player.conn, {
        type: "notice",
        text: `You are already friends with ${targetCharacter.name}.`
      });
      this.sendSocialState(player);
      return;
    }
    if (this.host.store.hasFriendRequest(character.id, targetCharacter.id)) {
      this.host.send(player.conn, {
        type: "notice",
        text: "That friend request is already pending."
      });
      this.sendSocialState(player);
      return;
    }
    if (this.host.store.hasFriendRequest(targetCharacter.id, character.id)) {
      this.host.send(player.conn, {
        type: "notice",
        text: `${targetCharacter.name} already sent you a friend request. Accept it in the Social panel.`
      });
      this.sendSocialState(player);
      return;
    }
    if (
      this.host.store.friendRequestsFrom(character.id).length >=
      MAX_OUTGOING_REQUESTS
    ) {
      this.host.sendError(conn, "You have too many pending friend requests.");
      return;
    }

    this.host.store.addFriendRequest(character.id, targetCharacter.id);
    this.host.send(player.conn, {
      type: "notice",
      text: `Friend request sent to ${targetCharacter.name}.`
    });
    this.sendSocialState(player);
    if (target.online) {
      this.host.send(target.online.conn, {
        type: "notice",
        text: `${character.name} sent you a friend request.`
      });
      this.sendSocialState(target.online);
    }
  }

  handleFriendAccept(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    const requesterId = asString(msg.playerId)?.trim() ?? "";
    if (requesterId === "") {
      this.host.sendError(conn, "Choose a friend request first.");
      return;
    }
    if (!this.host.store.hasFriendRequest(requesterId, player.character.id)) {
      this.host.sendError(conn, "That friend request is no longer available.");
      this.sendSocialState(player);
      return;
    }
    const requester = this.resolveCharacter(requesterId);
    if (!requester) {
      this.host.sendError(conn, "That trainer does not exist.");
      this.sendSocialState(player);
      return;
    }

    const character = player.character;
    const requesterCharacter = requester.character;
    character.friends ??= [];
    requesterCharacter.friends ??= [];
    const addingToAcceptor = !character.friends.includes(requesterCharacter.id);
    const addingToRequester = !requesterCharacter.friends.includes(character.id);
    if (addingToAcceptor && character.friends.length >= MAX_FRIENDS) {
      this.host.sendError(conn, `Your friend list is full (${MAX_FRIENDS}).`);
      return;
    }
    if (addingToRequester && requesterCharacter.friends.length >= MAX_FRIENDS) {
      this.host.sendError(conn, "That trainer's friend list is full.");
      return;
    }

    if (addingToAcceptor) character.friends.push(requesterCharacter.id);
    if (addingToRequester) requesterCharacter.friends.push(character.id);
    this.host.store.saveCharacter(player.accountId, character);
    this.host.store.saveCharacter(requester.accountId, requesterCharacter);
    this.host.store.removeFriendRequest(requesterCharacter.id, character.id);
    // A reciprocal pending request is answered by this accept as well.
    this.host.store.removeFriendRequest(character.id, requesterCharacter.id);

    this.host.send(player.conn, {
      type: "notice",
      text: `You are now friends with ${requesterCharacter.name}.`
    });
    this.sendSocialState(player);
    if (requester.online) {
      this.host.send(requester.online.conn, {
        type: "notice",
        text: `${character.name} accepted your friend request.`
      });
      this.sendSocialState(requester.online);
    }
  }

  handleFriendDecline(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    const requesterId = asString(msg.playerId)?.trim() ?? "";
    if (requesterId === "") {
      this.host.sendError(conn, "Choose a friend request first.");
      return;
    }
    if (!this.host.store.removeFriendRequest(requesterId, player.character.id)) {
      this.host.sendError(conn, "That friend request is no longer available.");
      this.sendSocialState(player);
      return;
    }
    // Declining also withdraws a reciprocal request from the acceptor.
    this.host.store.removeFriendRequest(player.character.id, requesterId);

    const requester = this.resolveCharacter(requesterId);
    this.sendSocialState(player);
    if (requester?.online) {
      this.host.send(requester.online.conn, {
        type: "notice",
        text: `${player.character.name} declined your friend request.`
      });
      this.sendSocialState(requester.online);
    }
  }

  handleFriendCancel(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    const targetId = asString(msg.playerId)?.trim() ?? "";
    if (targetId === "") {
      this.host.sendError(conn, "Choose a pending request first.");
      return;
    }
    if (!this.host.store.removeFriendRequest(player.character.id, targetId)) {
      this.host.send(player.conn, {
        type: "notice",
        text: "That friend request is no longer pending."
      });
      this.sendSocialState(player);
      return;
    }

    const target = this.resolveCharacter(targetId);
    this.host.send(player.conn, { type: "notice", text: "Friend request canceled." });
    this.sendSocialState(player);
    if (target?.online) {
      this.host.send(target.online.conn, {
        type: "notice",
        text: `${player.character.name} canceled their friend request.`
      });
      this.sendSocialState(target.online);
    }
  }

  handleFriendRemove(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    const targetId = asString(msg.playerId)?.trim() ?? "";
    if (targetId === "") {
      this.host.sendError(conn, "Choose a friend to remove.");
      return;
    }
    const character = player.character;
    character.friends = (character.friends ?? []).filter((id) => id !== targetId);
    this.host.store.saveCharacter(player.accountId, character);
    this.host.store.removeFriendRequest(character.id, targetId);
    this.host.store.removeFriendRequest(targetId, character.id);

    const target = this.resolveCharacter(targetId);
    if (target) {
      target.character.friends = (target.character.friends ?? []).filter(
        (id) => id !== character.id
      );
      this.host.store.saveCharacter(target.accountId, target.character);
    }

    this.sendSocialState(player);
    if (target?.online) this.sendSocialState(target.online);
  }

  handleDirectMessage(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    const targetId = asString(msg.toId)?.trim() ?? "";
    const text = (asString(msg.text) ?? "")
      .replace(/[\u0000-\u001f\u007f]/g, "")
      .trim();
    if (text.length === 0 || text.length > CONFIG.maxChatLength) {
      this.host.sendError(conn, `Messages must be 1-${CONFIG.maxChatLength} characters.`);
      return;
    }

    const target = this.host.onlinePlayer(targetId);
    if (!target) {
      this.host.sendError(conn, "That trainer is not online.");
      return;
    }
    if (target === player) {
      this.host.sendError(conn, "You cannot message yourself.");
      return;
    }
    const isFriend = (player.character.friends ?? []).includes(target.character.id);
    const isNearby = player.visiblePlayers.has(target.accountId);
    if (!isFriend && !isNearby) {
      this.host.sendError(conn, "You can only message friends or trainers nearby.");
      return;
    }

    const now = Date.now();
    if (now - player.lastDirectAt < CONFIG.chatCooldownMs) {
      this.host.sendError(conn, "You are messaging too fast.");
      return;
    }
    player.lastDirectAt = now;

    this.host.send(target.conn, {
      type: "direct_message",
      fromId: player.character.id,
      fromName: player.character.name,
      text,
      at: now
    });
    this.host.send(player.conn, {
      type: "direct_message",
      toId: target.character.id,
      toName: target.character.name,
      text,
      at: now,
      outgoing: true
    });
  }

  /** Snapshot used by the Social tab and the bottom-right Social panel. */
  sendSocialState(player: PlayerSession): void {
    const locale = player.conn.locale;
    const character = player.character;
    const friendIds = [...new Set(character.friends ?? [])];
    const incomingRecords = this.host.store.friendRequestsTo(character.id);
    const outgoingRecords = this.host.store.friendRequestsFrom(character.id);
    const incomingIds = new Set(incomingRecords.map((request) => request.from));
    const outgoingIds = new Set(outgoingRecords.map((request) => request.to));

    const friends: FriendView[] = [];
    for (const id of friendIds) {
      const online = this.host.onlinePlayer(id);
      if (online) {
        friends.push({
          id,
          name: online.character.name,
          online: true,
          mapId: online.character.mapId,
          location: this.host.locationName(
            locale,
            online.character.mapId,
            online.character.x,
            online.character.y
          )
        });
        continue;
      }
      const stored = this.host.store.characterById(id);
      if (stored) friends.push({ id, name: stored.character.name, online: false });
    }
    friends.sort((a, b) => {
      if (a.online !== b.online) return a.online ? -1 : 1;
      return a.name.localeCompare(b.name);
    });

    const incomingRequests = this.requestViews(incomingRecords, "from");
    const outgoingRequests = this.requestViews(outgoingRecords, "to");

    const friendSet = new Set(friendIds);
    const nearby: NearbyView[] = this.host.visibility
      .visibleOthers(player)
      .map((other) => ({
        id: other.character.id,
        name: other.character.name,
        distance:
          Math.abs(other.character.x - character.x) +
          Math.abs(other.character.y - character.y),
        mapId: other.character.mapId,
        location: this.host.locationName(
          locale,
          other.character.mapId,
          other.character.x,
          other.character.y
        ),
        friend: friendSet.has(other.character.id),
        requested: outgoingIds.has(other.character.id),
        incoming: incomingIds.has(other.character.id)
      }))
      .sort((a, b) => a.distance - b.distance || a.name.localeCompare(b.name))
      .slice(0, MAX_NEARBY);

    this.host.send(player.conn, {
      type: "social_state",
      friends,
      incomingRequests,
      outgoingRequests,
      nearby,
      maxFriends: MAX_FRIENDS
    });
  }

  private requestViews(
    records: Array<{ from: string; to: string; at: number }>,
    peer: "from" | "to"
  ): RequestView[] {
    const views: RequestView[] = [];
    for (const record of records) {
      const resolved = this.resolveCharacter(record[peer]);
      if (!resolved) continue;
      views.push({
        id: resolved.character.id,
        name: resolved.character.name,
        online: Boolean(resolved.online),
        at: record.at
      });
    }
    return views.sort((a, b) => b.at - a.at);
  }

  private resolveTarget(msg: Dict): ResolvedCharacter | null {
    const targetId = asString(msg.playerId)?.trim() ?? "";
    const targetName = asString(msg.name)?.trim() ?? "";
    if (targetId !== "") return this.resolveCharacter(targetId);
    if (targetName !== "") {
      const stored = this.host.store.characterByName(targetName);
      return stored ? { ...stored, online: this.host.onlinePlayer(stored.character.id) } : null;
    }
    return null;
  }

  private resolveCharacter(characterId: string): ResolvedCharacter | null {
    const online = this.host.onlinePlayer(characterId);
    if (online) {
      return {
        accountId: online.accountId,
        character: online.character,
        online
      };
    }
    const stored = this.host.store.characterById(characterId);
    return stored ? { ...stored, online: null } : null;
  }
}
