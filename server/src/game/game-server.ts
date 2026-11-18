import crypto from "node:crypto";
import { WebSocket } from "ws";
import { CONFIG } from "../config.js";
import type {
  EncounterEntry,
  GameContent,
  MapDef,
  StoryTrainerDef
} from "../content/types.js";
import { ContentLocalizer } from "../i18n/localizer.js";
import { Store, type AccountRecord } from "../store.js";
import { BattleController } from "./battles.js";
import { normalizeCharacter } from "./character-normalizer.js";
import { createStarter, movesForLevel, PLAYER_COLORS } from "./creatures.js";
import { buildStartingInventory } from "./items.js";
import type { JournalEntry } from "./journal.js";
import { loadOutdoorLocations, locationAt, type OutdoorLocationGrid } from "./locations.js";
import { isWalkable, tileWindow, validateMaps } from "./maps.js";
import { normalizePokedex } from "./pokedex.js";
import {
  CHARACTER_NAME_PATTERN,
  SUPPORTED_LOCALES,
  USERNAME_PATTERN,
  asInt,
  asString,
  normalizeLocale,
  publicNpc,
  publicPlayer,
  sendError as emitError,
  sendMessage,
  type Conn,
  type Dict,
  type PlayerSession
} from "./protocol.js";
import { ProgressionController } from "./progression.js";
import type { GameHost } from "./runtime.js";
import { DuelController } from "./duels.js";
import { ServiceController } from "./services.js";
import { SocialController } from "./social.js";
import { StoryController } from "./story.js";
import type { CharacterState } from "./types.js";
import { VisibilityService } from "./visibility.js";
import { loadWorldMap, type WorldMapContent } from "./world-map.js";
import { WorldController } from "./world.js";

/**
 * Server composition root: authentication, the connection lifecycle and the
 * snapshots that span domains. Movement, battles, NPC services and progression
 * live in their own controllers and talk to the shared state through GameHost.
 */
export class GameServer implements GameHost {
  readonly store: Store;
  readonly content: GameContent;
  readonly i18n: ContentLocalizer;
  readonly visibility: VisibilityService;
  private readonly outdoorLocations: OutdoorLocationGrid | null;
  private readonly worldMap: WorldMapContent | null;
  private readonly worldMapViews = new Map<string, Record<string, unknown>>();
  private readonly conns = new Set<Conn>();
  private readonly players = new Map<string, PlayerSession>();
  private readonly heartbeatTimer: ReturnType<typeof setInterval>;
  private readonly autosaveTimer: ReturnType<typeof setInterval>;
  private readonly startedAt = Date.now();
  private readonly progression: ProgressionController;
  private readonly services: ServiceController;
  private readonly social: SocialController;
  private readonly duels: DuelController;
  private readonly battles: BattleController;
  private readonly world: WorldController;
  readonly story: StoryController;

  constructor(store: Store, content: GameContent) {
    this.store = store;
    this.content = content;
    this.i18n = new ContentLocalizer(content);
    this.outdoorLocations = loadOutdoorLocations();
    this.worldMap = loadWorldMap();
    this.visibility = new VisibilityService();
    this.progression = new ProgressionController(this);
    this.services = new ServiceController(this);
    this.social = new SocialController(this);
    this.duels = new DuelController(this);
    this.battles = new BattleController(this);
    this.story = new StoryController(this);
    this.world = new WorldController(this);

    const mapErrors = validateMaps(content.maps);
    if (mapErrors.length > 0) {
      throw new Error(`Invalid map data:\n${mapErrors.join("\n")}`);
    }
    this.migrateSeamlessWorld();

    this.heartbeatTimer = setInterval(() => this.heartbeat(), 30_000);
    this.heartbeatTimer.unref();
    this.autosaveTimer = setInterval(() => this.autosave(), CONFIG.autosaveMs);
    this.autosaveTimer.unref();
  }

  get onlineCount(): number {
    return this.players.size;
  }

  get uptimeSeconds(): number {
    return Math.floor((Date.now() - this.startedAt) / 1000);
  }

  get characterCount(): number {
    return this.store.characterCount();
  }

  /**
   * Older saves used one map per ROM matrix cell. The seamless outdoor world
   * places those cells at increasing y offsets, so translate saved positions
   * once at startup instead of dropping existing characters.
   */
  private migrateSeamlessWorld(): void {
    const legacyOffsets: Record<string, { x: number; y: number }> = {
      nuvema: { x: 768, y: 736 },
      route1_south: { x: 768, y: 704 },
      route1_north: { x: 768, y: 672 },
      unova: { x: 768, y: 672 }
    };
    for (const { accountId, character } of this.store.allCharacters()) {
      const offset = legacyOffsets[character.mapId];
      if (offset === undefined) continue;
      character.mapId = "unova_full";
      character.x += offset.x;
      character.y += offset.y;
      this.store.saveCharacter(accountId, character);
    }
  }

  map(mapId: string): MapDef {
    return this.content.maps[mapId];
  }

  /** Localized town/route name for the player's current tile. */
  locationName(locale: string, mapId: string, x: number, y: number): string {
    if (mapId === "unova_full" && this.outdoorLocations) {
      const raw = locationAt(this.outdoorLocations, x, y);
      if (raw) return this.i18n.locationName(locale, raw);
    }
    return this.i18n.mapName(locale, mapId);
  }

  /** The Unova world map's marker list, localized once per locale. */
  private worldMapView(locale: string): Record<string, unknown> | undefined {
    if (!this.worldMap) return undefined;
    const cached = this.worldMapViews.get(locale);
    if (cached) return cached;
    const view = {
      width: this.worldMap.width,
      height: this.worldMap.height,
      places: this.worldMap.places.map((place) => ({
        name: this.i18n.locationName(locale, place.key),
        x: place.x,
        y: place.y,
        kind: place.kind
      }))
    };
    this.worldMapViews.set(locale, view);
    return view;
  }

  private starterOptions(locale: string) {
    return this.content.starters.map((id) => {
      const species = this.content.species[id];
      const moves = movesForLevel(this.content, species, 5).map((move) =>
        this.i18n.moveName(locale, move.id)
      );
      return {
        id: species.id,
        name: this.i18n.speciesName(locale, species.id),
        types: species.types,
        level: 5,
        moves
      };
    });
  }

  attach(ws: WebSocket, ip: string): void {
    const conn: Conn = {
      ws,
      ip,
      accountId: null,
      player: null,
      locale: "en",
      messageTimes: [],
      alive: true
    };
    this.conns.add(conn);
    console.log(`[net] connect ${ip} (${this.conns.size} sockets)`);

    ws.on("message", (data) => this.onMessage(conn, data));
    ws.on("pong", () => {
      conn.alive = true;
    });
    ws.on("close", () => this.onClose(conn));
    ws.on("error", (error) => {
      console.warn(`[net] socket error from ${ip}: ${error.message}`);
    });

    this.send(conn, {
      type: "hello",
      version: 3,
      message: "BWMMO prototype server",
      locales: SUPPORTED_LOCALES
    });
  }

  private onMessage(conn: Conn, data: WebSocket.RawData): void {
    const now = Date.now();
    conn.messageTimes = conn.messageTimes.filter((time) => now - time < 1000);
    conn.messageTimes.push(now);
    if (conn.messageTimes.length > CONFIG.messagesPerSecond) {
      this.sendError(conn, "Too many messages.");
      conn.ws.close(1008, "rate limit");
      return;
    }

    let msg: Dict;
    try {
      const parsed: unknown = JSON.parse(data.toString());
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        this.sendError(conn, "Malformed message.");
        return;
      }
      msg = parsed as Dict;
    } catch {
      this.sendError(conn, "Malformed JSON.");
      return;
    }

    const type = asString(msg.type);
    if (!type) {
      this.sendError(conn, "Message type is required.");
      return;
    }

    try {
      this.dispatch(conn, type, msg);
    } catch (error) {
      console.error(`[game] handler error for '${type}':`, error);
      this.sendError(conn, "The server could not process that action.");
    }
  }

  private dispatch(conn: Conn, type: string, msg: Dict): void {
    switch (type) {
      case "ping":
        this.send(conn, { type: "pong", t: msg.t ?? null, now: Date.now() });
        return;
      case "set_locale":
        if (this.applyLocale(conn, msg)) this.refreshLocale(conn);
        return;
      case "register":
        this.handleRegister(conn, msg);
        return;
      case "login":
        this.handleLogin(conn, msg);
        return;
      case "resume":
        this.handleResume(conn, msg);
        return;
      default:
        break;
    }

    if (!conn.accountId) {
      this.sendError(conn, "Please log in first.");
      return;
    }

    switch (type) {
      case "logout":
        this.handleLogout(conn);
        return;
      case "create_character":
        this.handleCreateCharacter(conn, msg);
        return;
      case "move":
        this.world.handleMove(conn, msg);
        return;
      case "turn":
        this.world.handleTurn(conn, msg);
        return;
      case "chat":
        this.handleChat(conn, msg);
        return;
      case "direct_message":
        this.social.handleDirectMessage(conn, msg);
        return;
      case "social_state":
        this.social.handleRequest(conn);
        return;
      case "friend_request":
      case "friend_add":
        this.social.handleFriendRequest(conn, msg);
        return;
      case "friend_accept":
        this.social.handleFriendAccept(conn, msg);
        return;
      case "friend_decline":
        this.social.handleFriendDecline(conn, msg);
        return;
      case "friend_cancel":
        this.social.handleFriendCancel(conn, msg);
        return;
      case "friend_remove":
        this.social.handleFriendRemove(conn, msg);
        return;
      case "duel_request":
        this.duels.handleRequest(conn, msg);
        return;
      case "duel_accept":
        this.duels.handleAccept(conn, msg);
        return;
      case "duel_decline":
        this.duels.handleDecline(conn, msg);
        return;
      case "duel_cancel":
        this.duels.handleCancel(conn, msg);
        return;
      case "story_advance":
        if (conn.player) this.story.advance(conn.player, msg);
        return;
      case "story_choice":
        if (conn.player) this.story.choose(conn.player, msg);
        return;
      case "battle_closed":
        // The player dismissed the result box; a scripted battle scene can
        // continue now that the client is back in the world.
        if (conn.player) this.story.onBattleClosed(conn.player);
        return;
      case "interact":
        this.services.handleInteract(conn, msg);
        return;
      case "use_item":
        this.services.handleUseItem(conn, msg);
        return;
      case "shop_buy":
        this.services.handleShopBuy(conn, msg);
        return;
      case "shop_sell":
        this.services.handleShopSell(conn, msg);
        return;
      case "pc_deposit":
        this.services.handlePcDeposit(conn, msg);
        return;
      case "pc_withdraw":
        this.services.handlePcWithdraw(conn, msg);
        return;
      case "pc_swap":
        this.services.handlePcSwap(conn, msg);
        return;
      case "pc_release":
        this.services.handlePcRelease(conn, msg);
        return;
      case "rename_creature":
        this.services.handleRename(conn, msg);
        return;
      case "teach_move":
        this.services.handleTeachMove(conn, msg);
        return;
      case "trade_evolve":
        this.services.handleTradeEvolve(conn, msg);
        return;
      case "set_ability":
        this.services.handleSetAbility(conn, msg);
        return;
      case "pokedex_request":
        this.progression.handlePokedexRequest(conn);
        return;
      case "learn_move":
        this.progression.handleLearnMove(conn, msg);
        return;
      case "forget_move":
        this.progression.handleForgetMove(conn, msg);
        return;
      case "battle_action":
        if (!this.duels.handleAction(conn, msg)) {
          this.battles.handleAction(conn, msg);
        }
        return;
      default:
        this.sendError(conn, `Unknown message type: ${type}`);
    }
  }

  private applyLocale(conn: Conn, msg: Dict): boolean {
    const value = asString(msg.locale);
    if (!value) return false;
    const locale = normalizeLocale(value);
    if (!locale || locale === conn.locale) return false;
    conn.locale = locale;
    return true;
  }

  /** Re-render the player's already-open state after a language switch. */
  private refreshLocale(conn: Conn): void {
    const player = conn.player;
    if (!player) return;
    this.sendPartyState(player);
    if (!player.battleId) {
      this.sendMapState(player);
      return;
    }
    const battle = this.duels.activeView(player) ?? this.battles.activeView(player);
    if (battle) {
      this.send(conn, { type: "battle_turn", battle });
    }
  }

  private handleRegister(conn: Conn, msg: Dict): void {
    this.applyLocale(conn, msg);
    if (conn.accountId) {
      this.sendError(conn, "You are already logged in.");
      return;
    }
    const username = asString(msg.username)?.trim() ?? "";
    const password = asString(msg.password) ?? "";
    if (!USERNAME_PATTERN.test(username)) {
      this.sendError(conn, "Username must be 3-20 letters, numbers, or underscores.");
      return;
    }
    if (password.length < 4 || password.length > 72) {
      this.sendError(conn, "Password must be 4-72 characters.");
      return;
    }
    const result = this.store.register(username, password);
    if (!result.ok) {
      this.sendError(conn, result.error);
      return;
    }
    const token = this.store.issueToken(result.account.id);
    this.authenticate(conn, result.account, token);
  }

  private handleLogin(conn: Conn, msg: Dict): void {
    this.applyLocale(conn, msg);
    if (conn.accountId) {
      this.sendError(conn, "You are already logged in.");
      return;
    }
    const username = asString(msg.username)?.trim() ?? "";
    const password = asString(msg.password) ?? "";
    const account = this.store.login(username, password);
    if (!account) {
      this.sendError(conn, "Incorrect username or password.");
      return;
    }
    const token = this.store.issueToken(account.id);
    this.authenticate(conn, account, token);
  }

  /**
   * Explicit sign-out. Revoke the account's tokens so the saved session can no
   * longer `resume`, save and remove the player, then let the socket close.
   * The character itself is untouched; logging in again continues the story.
   */
  private handleLogout(conn: Conn): void {
    if (!conn.accountId) {
      this.sendError(conn, "Please log in first.");
      return;
    }
    const accountId = conn.accountId;
    const player = conn.player;
    conn.accountId = null;
    if (player) this.removePlayer(player, { save: true, notify: true });
    this.store.revokeTokens(accountId);
    try {
      conn.ws.close(4000, "logged out");
    } catch {
      // The socket may already be gone.
    }
  }

  private handleResume(conn: Conn, msg: Dict): void {
    this.applyLocale(conn, msg);
    if (conn.accountId) {
      this.sendError(conn, "You are already logged in.");
      return;
    }
    const token = asString(msg.token) ?? "";
    const account = this.store.resume(token);
    if (!account) {
      this.sendError(conn, "Session expired. Please log in again.");
      return;
    }
    this.authenticate(conn, account, token);
  }

  private authenticate(conn: Conn, account: AccountRecord, token: string): void {
    if (conn.accountId) {
      this.sendError(conn, "You are already logged in.");
      return;
    }

    const existing = this.players.get(account.id);
    if (existing) {
      this.removePlayer(existing, { save: true, notify: true });
      existing.conn.player = null;
      this.sendError(existing.conn, "Signed in from another connection.");
      try {
        existing.conn.ws.close(4001, "replaced by a newer session");
      } catch {
        // The socket may already be gone.
      }
    }

    conn.accountId = account.id;
    const character = this.store.getCharacter(account.id);
    let normalized = false;
    if (character) normalized = normalizeCharacter(this.content, character);
    if (character && normalized) this.store.saveCharacter(account.id, character);

    this.send(conn, {
      type: "auth_ok",
      token,
      username: account.username,
      character: character ? this.i18n.character(conn.locale, character) : null,
      starters: this.starterOptions(conn.locale),
      items: Object.values(this.content.items).map((item) =>
        this.i18n.item(conn.locale, item)
      ),
      maxParty: this.content.config.maxParty,
      maxBox: this.content.config.maxBox
    });

    if (character) {
      this.enterWorld(conn, character);
    }
  }

  private handleCreateCharacter(conn: Conn, msg: Dict): void {
    if (!conn.accountId) {
      this.sendError(conn, "Please log in first.");
      return;
    }
    if (conn.player || this.store.hasCharacter(conn.accountId)) {
      this.sendError(conn, "This account already has a character.");
      return;
    }
    const name = asString(msg.name)?.trim() ?? "";
    const color = asString(msg.color) ?? "";
    const story = this.content.story;
    const skipStory = Boolean(story && CONFIG.debugSkipStory);
    // With a story layer the partner is granted by the opening scene, exactly
    // like the original game; the create payload's starter is only a fallback.
    // DEBUG_SKIP_STORY keeps the WebSocket smoke tests on the post-prologue map.
    const starterId =
      (asString(msg.starter) ?? "").trim() || this.content.starters[0];
    const spriteValue = asInt(msg.sprite);
    const trainerSprite = spriteValue === null ? 0 : spriteValue;
    if (!CHARACTER_NAME_PATTERN.test(name)) {
      this.sendError(conn, "Trainer name must be 2-16 letters, numbers, or underscores.");
      return;
    }
    if (this.store.isNameTaken(name)) {
      this.sendError(conn, "That trainer name is already taken.");
      return;
    }
    if (!PLAYER_COLORS.includes(color)) {
      this.sendError(conn, "Please choose one of the offered trainer colors.");
      return;
    }
    if ((!story || skipStory) && !this.content.starters.includes(starterId)) {
      this.sendError(conn, "Please choose one of the offered partner Pokemon.");
      return;
    }
    if (trainerSprite < 0 || trainerSprite > 1) {
      this.sendError(conn, "Invalid trainer style.");
      return;
    }

    const startMap = this.map(
      (skipStory ? this.content.config.startingMap : story?.startMap) ??
        this.content.config.startingMap ??
        "town"
    );
    const spawnX = CONFIG.debugStartX ?? startMap.spawn.x;
    const spawnY = CONFIG.debugStartY ?? startMap.spawn.y;
    const storyFlags = skipStory
      ? {
          ...(story?.initialFlags ?? {}),
          "prologue.starterChosen": 1,
          "prologue.momDone": 1,
          "prologue.pokedex": 1,
          "prologue.routeUnlocked": 1
        }
      : { ...(story?.initialFlags ?? {}) };
    const character: CharacterState = {
      id: crypto.randomUUID(),
      name,
      color,
      mapId: startMap.id,
      x: spawnX,
      y: spawnY,
      dir: startMap.spawn.dir,
      sprite: trainerSprite,
      money: this.content.config.startingMoney,
      wins: 0,
      party: story && !skipStory ? [] : [createStarter(this.content, starterId)],
      box: [],
      inventory: buildStartingInventory(this.content),
      pokedex: { seen: [], caught: [] },
      storyFlags,
      friends: []
    };
    normalizePokedex(this.content, character);
    this.store.saveCharacter(conn.accountId, character);
    this.send(conn, {
      type: "character_created",
      character: this.i18n.character(conn.locale, character)
    });
    this.enterWorld(conn, character);
  }

  private enterWorld(conn: Conn, character: CharacterState): void {
    if (!conn.accountId) return;
    let map = this.content.maps[character.mapId];
    if (
      !map ||
      !isWalkable(map, character.x, character.y) ||
      this.story.blocksAt(map, character.x, character.y, character.storyFlags)
    ) {
      // Prefer the story's opening map so a broken save can still reach the
      // prologue instead of being dropped into the unrelated demo town.
      const fallbackId = this.content.story?.startMap;
      map = (fallbackId ? this.content.maps[fallbackId] : undefined) ?? this.map("town");
      character.mapId = map.id;
      character.x = map.spawn.x;
      character.y = map.spawn.y;
      character.dir = map.spawn.dir;
    }

    const player: PlayerSession = {
      conn,
      accountId: conn.accountId,
      username: character.name,
      character,
      lastMoveAt: 0,
      lastChatAt: 0,
      lastDirectAt: 0,
      battleId: null,
      encounterGraceUntil: 0,
      visiblePlayers: new Set(),
      tileWindow: null,
      portalLock: null,
      pendingLearnKey: null,
      story: null,
      lastStoryGateAt: 0
    };
    conn.player = player;
    this.players.set(conn.accountId, player);
    this.visibility.add(player);
    this.sendMapState(player);
    this.visibility.refresh(player);
    this.social.sendSocialState(player);
    this.send(player.conn, {
      type: "notice",
      text: `Welcome, ${character.name}! The full Unova overworld is online.`
    });
    this.store.saveCharacter(player.accountId, character);
    this.sendNextMoveLearn(player);
    this.story.onEnter(player);
    console.log(
      `[game] ${character.name} (${player.username}) entered ${character.mapId} at ${character.x},${character.y}; ${this.players.size} online`
    );
  }

  private handleChat(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.sendError(conn, "Create a character before chatting.");
      return;
    }
    const raw = asString(msg.text) ?? "";
    const text = raw.replace(/[\u0000-\u001f\u007f]/g, "").trim();
    if (text.length === 0 || text.length > CONFIG.maxChatLength) {
      this.sendError(conn, `Chat messages must be 1-${CONFIG.maxChatLength} characters.`);
      return;
    }
    const now = Date.now();
    if (now - player.lastChatAt < CONFIG.chatCooldownMs) {
      this.sendError(conn, "You are chatting too fast.");
      return;
    }
    player.lastChatAt = now;

    const map = this.map(player.character.mapId);
    const message = {
      type: "chat",
      playerId: player.character.id,
      name: player.character.name,
      text,
      mapId: map.id,
      mapName: map.name
    };
    for (const other of this.players.values()) {
      this.send(other.conn, message);
    }
  }

  /** Re-index a teleported player, send their new map_state and refresh views. */
  afterTeleport(player: PlayerSession): void {
    this.visibility.add(player);
    this.sendMapState(player);
    this.visibility.refresh(player);
    this.story.onEnter(player);
  }

  startWildBattle(player: PlayerSession, map: MapDef, entry: EncounterEntry): void {
    // A pending duel invite cannot survive a wild encounter.
    this.duels.cancelForPlayer(player);
    this.battles.startWildBattle(player, map, entry);
  }

  startTrainerBattle(
    player: PlayerSession,
    trainerId: string,
    trainer: StoryTrainerDef
  ): void {
    this.duels.cancelForPlayer(player);
    this.battles.startTrainerBattle(player, trainerId, trainer);
  }

  sendMapState(player: PlayerSession): void {
    const character = player.character;
    const map = this.map(character.mapId);
    const locale = player.conn.locale;
    const view = this.i18n.character(locale, character);
    const window = tileWindow(
      map,
      character.x,
      character.y,
      CONFIG.tileWindowRadius
    );
    player.tileWindow = window;
    this.send(player.conn, {
      type: "map_state",
      map: {
        id: map.id,
        name: this.i18n.mapName(locale, map.id),
        width: map.width,
        height: map.height,
        tiles: window.tiles,
        tileX: window.x,
        tileY: window.y,
        tileWidth: window.width,
        tileHeight: window.height,
        windowed: window.width < map.width || window.height < map.height,
        outdoor: map.outdoor === true,
        npcs: map.npcs
          .filter((npc) => this.story.npcVisible(npc, character.storyFlags))
          .map((npc) => publicNpc(this.i18n.npc(locale, npc))),
        interactables: map.interactables ?? [],
        visual: map.visual
      },
      self: {
        id: character.id,
        name: character.name,
        color: character.color,
        sprite: character.sprite,
        mapId: character.mapId,
        x: character.x,
        y: character.y,
        dir: character.dir,
        money: character.money,
        wins: character.wins,
        party: view.party,
        inventory: character.inventory,
        pokedex: character.pokedex ?? { seen: [], caught: [] }
      },
      players: this.visibility.visibleOthers(player).map(publicPlayer),
      online: this.players.size,
      maxParty: this.content.config.maxParty,
      maxBox: this.content.config.maxBox,
      pokedexTotal: Object.keys(this.content.species).length,
      location: this.locationName(locale, character.mapId, character.x, character.y),
      worldMap: this.worldMapView(locale)
    });
  }

  sendPartyState(player: PlayerSession): void {
    this.progression.sendPartyState(player);
  }

  sendPokedexState(player: PlayerSession, includeEntries: boolean): void {
    this.progression.sendPokedexState(player, includeEntries);
  }

  sendNextMoveLearn(player: PlayerSession): void {
    this.progression.sendNextMoveLearn(player);
  }

  private removePlayer(
    player: PlayerSession,
    options: { save: boolean; notify: boolean }
  ): void {
    this.duels.detach(player);
    this.battles.detach(player);
    this.visibility.clear(player, options.notify);
    this.players.delete(player.accountId);
    player.conn.player = null;
    if (options.save) {
      this.store.saveCharacter(player.accountId, player.character);
    }
    console.log(
      `[game] ${player.character.name} left ${player.character.mapId}; ${this.players.size} online`
    );
  }

  private onClose(conn: Conn): void {
    this.conns.delete(conn);
    if (conn.player) {
      const player = conn.player;
      conn.player = null;
      this.removePlayer(player, { save: true, notify: true });
    }
    console.log(`[net] disconnect ${conn.ip} (${this.conns.size} sockets)`);
  }

  send(conn: Conn, message: Dict): void {
    sendMessage(conn, message);
  }

  sendError(conn: Conn, message: string): void {
    emitError(conn, message);
  }

  sendJournal(player: PlayerSession, entry: JournalEntry): void {
    this.send(player.conn, { type: "journal", entry });
  }

  onlinePlayer(characterId: string): PlayerSession | null {
    for (const player of this.players.values()) {
      if (player.character.id === characterId) return player;
    }
    return null;
  }

  private heartbeat(): void {
    for (const conn of this.conns) {
      if (!conn.alive) {
        console.warn(`[net] heartbeat timeout for ${conn.ip}`);
        conn.ws.terminate();
        continue;
      }
      conn.alive = false;
      try {
        conn.ws.ping();
      } catch {
        // The close handler will clean up.
      }
    }
  }

  private autosave(): void {
    for (const player of this.players.values()) {
      this.store.saveCharacter(player.accountId, player.character);
    }
    try {
      this.store.flush();
    } catch (error) {
      console.error("[store] autosave failed:", error);
    }
  }

  stop(): void {
    clearInterval(this.heartbeatTimer);
    clearInterval(this.autosaveTimer);
    for (const player of this.players.values()) {
      this.store.saveCharacter(player.accountId, player.character);
    }
    for (const conn of this.conns) {
      try {
        conn.ws.close(1001, "server shutting down");
      } catch {
        // Ignore sockets that are already closed.
      }
    }
    this.conns.clear();
    this.players.clear();
    this.duels.clear();
    this.battles.clear();
    this.visibility.dispose();
    this.store.close();
  }
}
