import crypto from "node:crypto";
import { WebSocket } from "ws";
import { CONFIG } from "../config.js";
import { Store, type AccountRecord } from "../store.js";
import {
  canStep,
  encounterAt,
  findNpc,
  getMap,
  getPortal,
  hasNpcAt,
  isTallGrass,
  isWalkable,
  needsTileWindowRefresh,
  portalAcceptsDirection,
  portalTriggersOnStep,
  tileWindow,
  validateMaps,
  withinView,
  type TileWindow
} from "./maps.js";
import {
  PLAYER_COLORS,
  awardExperience,
  createStarter,
  createWildCreature,
  emptyEvBlock,
  forgetMove,
  genderForDex,
  healParty,
  movesForLevel,
  normalizeCreatureProgress,
  pendingMovesFor,
  randomIvBlock,
  randomNature,
  resolvePendingMove,
  statsForLevel,
  xpToNext
} from "./creatures.js";
import {
  markSpeciesCaught,
  markSpeciesSeen,
  normalizePokedex
} from "./pokedex.js";
import {
  MAX_STACK,
  addItem,
  applyMedicine,
  buildStartingInventory,
  buyTotal,
  itemCount,
  removeItem,
  sellPrice,
  shopItemsForClient
} from "./items.js";
import { depositToBox, swapPartyWithBox, withdrawFromBox } from "./pc.js";
import { createBattle, disposeBattle, resolveTurn, type BattleAction, type BattleState } from "./battle.js";
import { renderDialogueLine, selectDialogue } from "./dialogue.js";
import { ContentLocalizer } from "../i18n/localizer.js";
import { loadOutdoorLocations, locationAt, type OutdoorLocationGrid } from "./locations.js";
import type { CharacterState, CreatureState, Dir, PType } from "./types.js";
import type { EncounterEntry, GameContent, MapDef } from "../content/types.js";

const DIRECTIONS: Record<Dir, [number, number]> = {
  up: [0, -1],
  down: [0, 1],
  left: [-1, 0],
  right: [1, 0]
};

const USERNAME_PATTERN = /^[A-Za-z0-9_]{3,20}$/;
const CHARACTER_NAME_PATTERN = /^[A-Za-z0-9_]{2,16}$/;
const SUPPORTED_LOCALES = ["en", "zh_CN", "zh_TW", "ja", "ko"];

function normalizeLocale(value: string): string | null {
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

interface Conn {
  ws: WebSocket;
  ip: string;
  accountId: string | null;
  player: PlayerSession | null;
  locale: string;
  messageTimes: number[];
  alive: boolean;
}

interface PlayerSession {
  conn: Conn;
  accountId: string;
  username: string;
  character: CharacterState;
  lastMoveAt: number;
  lastChatAt: number;
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
}

type Dict = Record<string, unknown>;

function asString(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function asInt(value: unknown): number | null {
  return typeof value === "number" && Number.isInteger(value) ? value : null;
}

function publicPlayer(player: PlayerSession) {
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

function publicNpc(npc: MapDef["npcs"][number]) {
  return {
    id: npc.id,
    name: npc.name,
    x: npc.x,
    y: npc.y,
    color: npc.color,
    kind: npc.kind,
    sprite: npc.sprite ?? null
  };
}

export class GameServer {
  private readonly store: Store;
  private readonly content: GameContent;
  private readonly i18n: ContentLocalizer;
  private readonly outdoorLocations: OutdoorLocationGrid | null;
  private readonly conns = new Set<Conn>();
  private readonly players = new Map<string, PlayerSession>();
  private readonly battles = new Map<string, BattleState>();
  private readonly heartbeatTimer: ReturnType<typeof setInterval>;
  private readonly autosaveTimer: ReturnType<typeof setInterval>;
  private readonly startedAt = Date.now();
  private readonly pokedexCatalogCache = new Map<string, Dict[]>();

  constructor(store: Store, content: GameContent) {
    this.store = store;
    this.content = content;
    this.i18n = new ContentLocalizer(content);
    this.outdoorLocations = loadOutdoorLocations();
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

  get uptimeSeconds(): number {
    return Math.floor((Date.now() - this.startedAt) / 1000);
  }

  get characterCount(): number {
    return this.store.characterCount();
  }

  private map(mapId: string): MapDef {
    return getMap(this.content.maps, mapId);
  }

  private canSee(a: PlayerSession, b: PlayerSession): boolean {
    return withinView(
      { mapId: a.character.mapId, x: a.character.x, y: a.character.y },
      { mapId: b.character.mapId, x: b.character.x, y: b.character.y },
      CONFIG.playerViewRadius
    );
  }

  private visibleOthers(player: PlayerSession): PlayerSession[] {
    const result: PlayerSession[] = [];
    for (const other of this.players.values()) {
      if (other.accountId === player.accountId) continue;
      if (this.canSee(player, other)) result.push(other);
    }
    return result;
  }

  /** Sends an event to every nearby player who currently sees this character. */
  private broadcastToVisible(player: PlayerSession, message: Dict): void {
    for (const other of this.players.values()) {
      if (other.accountId === player.accountId) continue;
      if (!other.visiblePlayers.has(player.accountId)) continue;
      this.send(other.conn, message);
    }
  }

  /** Tells nearby players about a character that just entered their view. */
  private announcePresence(player: PlayerSession): void {
    for (const other of this.players.values()) {
      if (other.accountId === player.accountId) continue;
      if (!this.canSee(other, player)) continue;
      if (other.visiblePlayers.has(player.accountId)) continue;
      other.visiblePlayers.add(player.accountId);
      this.send(other.conn, { type: "player_joined", player: publicPlayer(player) });
    }
  }

  /** Diffs both directions after a move: subject->others and others->subject. */
  private reconcileVisibility(player: PlayerSession): void {
    for (const other of this.players.values()) {
      if (other.accountId === player.accountId) continue;
      const visible = this.canSee(player, other);
      const known = player.visiblePlayers.has(other.accountId);
      if (visible && !known) {
        player.visiblePlayers.add(other.accountId);
        this.send(player.conn, { type: "player_joined", player: publicPlayer(other) });
      } else if (!visible && known) {
        player.visiblePlayers.delete(other.accountId);
        this.send(player.conn, { type: "player_left", playerId: other.character.id });
      }
    }
    for (const other of this.players.values()) {
      if (other.accountId === player.accountId) continue;
      const visible = this.canSee(other, player);
      const known = other.visiblePlayers.has(player.accountId);
      if (visible && !known) {
        other.visiblePlayers.add(player.accountId);
        this.send(other.conn, { type: "player_joined", player: publicPlayer(player) });
      } else if (!visible && known) {
        other.visiblePlayers.delete(player.accountId);
        this.send(other.conn, { type: "player_left", playerId: player.character.id });
      }
    }
  }

  /**
   * Removes a character from every other player's view. Call this before
   * changing map/position and before removing the session.
   */
  private clearVisibility(player: PlayerSession): void {
    for (const other of this.players.values()) {
      if (other.accountId === player.accountId) continue;
      if (other.visiblePlayers.delete(player.accountId)) {
        this.send(other.conn, { type: "player_left", playerId: player.character.id });
      }
    }
    player.visiblePlayers.clear();
  }

  private maybeSendTileWindow(player: PlayerSession, map: MapDef): void {
    const current = player.tileWindow;
    if (!current) return;
    if (current.width >= map.width && current.height >= map.height) return;
    const { x, y } = player.character;
    if (
      !needsTileWindowRefresh(current, x, y, CONFIG.tileWindowRefreshMargin)
    ) {
      return;
    }
    const next = tileWindow(map, x, y, CONFIG.tileWindowRadius);
    player.tileWindow = next;
    this.send(player.conn, {
      type: "map_window",
      mapId: map.id,
      x: next.x,
      y: next.y,
      width: next.width,
      height: next.height,
      tiles: next.tiles
    });
  }

  /** Localized town/route name for the player's current tile. */
  private locationName(locale: string, mapId: string, x: number, y: number): string {
    if (mapId === "unova_full" && this.outdoorLocations) {
      const raw = locationAt(this.outdoorLocations, x, y);
      if (raw) return this.i18n.locationName(locale, raw);
    }
    return this.i18n.mapName(locale, mapId);
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

  private normalizeCharacter(character: CharacterState): boolean {
    let changed = false;
    if (!Number.isInteger(character.sprite) || character.sprite < 0) {
      character.sprite = 0;
      changed = true;
    }
    if (!character.inventory || typeof character.inventory !== "object") {
      character.inventory = buildStartingInventory(this.content);
      changed = true;
    } else {
      const legacy = character.inventory as unknown as {
        balls?: number;
        items?: Record<string, number>;
      };
      if (!legacy.items || typeof legacy.items !== "object" || Array.isArray(legacy.items)) {
        // Pre-item saves only tracked a single Proto Ball counter.
        const items: Record<string, number> = {};
        const balls = typeof legacy.balls === "number" ? Math.max(0, Math.floor(legacy.balls)) : 0;
        if (balls > 0) items.poke_ball = Math.min(MAX_STACK, balls);
        legacy.items = items;
        changed = true;
      }
      const items = legacy.items;
      for (const [itemId, count] of Object.entries(items)) {
        if (!this.content.items[itemId] || !Number.isInteger(count) || count <= 0) {
          delete items[itemId];
          changed = true;
        } else if (count > MAX_STACK) {
          items[itemId] = MAX_STACK;
          changed = true;
        }
      }
      if ("balls" in legacy) {
        delete (legacy as { balls?: number }).balls;
        changed = true;
      }
      character.inventory = { items };
    }
    if (!Array.isArray(character.box)) {
      character.box = [];
      changed = true;
    }
    if (character.box.length > this.content.config.maxBox) {
      character.box = character.box.slice(0, this.content.config.maxBox);
      changed = true;
    }
    if (
      !character.storyFlags ||
      typeof character.storyFlags !== "object" ||
      Array.isArray(character.storyFlags)
    ) {
      character.storyFlags = {};
      changed = true;
    }
    if (!Array.isArray(character.party) || character.party.length === 0) {
      character.party = [createStarter(this.content, this.content.starters[0])];
      changed = true;
    }
    if (character.party.length > this.content.config.maxParty) {
      character.party = character.party.slice(0, this.content.config.maxParty);
      changed = true;
    }
    for (const creature of [...character.party, ...character.box]) {
      const legacy = creature as unknown as { type?: PType };
      if (!Array.isArray(creature.types) || creature.types.length === 0) {
        creature.types = legacy.type ? [legacy.type] : ["Normal"];
        changed = true;
      }
      if (!Number.isFinite(creature.xp)) {
        creature.xp = 0;
        changed = true;
      }
      const species = this.content.species[creature.species];
      if (!creature.gender) {
        creature.gender = genderForDex(species?.dex ?? 0);
        changed = true;
      }
      if (species) {
        const levelStats = statsForLevel(species, creature.level);
        if (!Number.isFinite(creature.spAtk)) {
          creature.spAtk = levelStats.spAtk;
          changed = true;
        }
        if (!Number.isFinite(creature.spDef)) {
          creature.spDef = levelStats.spDef;
          changed = true;
        }
      }
      if (!creature.ivs) {
        creature.ivs = randomIvBlock();
        changed = true;
      }
      if (!creature.evs) {
        creature.evs = emptyEvBlock();
        changed = true;
      }
      if (!creature.nature) {
        creature.nature = randomNature();
        changed = true;
      }
      if (!("heldItem" in creature)) {
        creature.heldItem = null;
        changed = true;
      }
      if (!Number.isFinite(creature.xpToNext)) {
        creature.xpToNext = xpToNext(this.content, creature.level);
        changed = true;
      }
      if (typeof creature.baseXp !== "number") {
        creature.baseXp = species?.baseXp ?? 10;
        changed = true;
      }
      if (typeof creature.catchRate !== "number") {
        creature.catchRate = species?.catchRate ?? 0.5;
        changed = true;
      }
      if (!creature.name) {
        creature.name = species?.name ?? "Partner";
        changed = true;
      }
      if (!Array.isArray(creature.moves) || creature.moves.length === 0) {
        creature.moves = species ? movesForLevel(this.content, species, creature.level) : [];
        changed = true;
      }
      if (normalizeCreatureProgress(this.content, creature)) changed = true;
    }
    if (normalizePokedex(this.content, character)) changed = true;
    return changed;
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
      case "create_character":
        this.handleCreateCharacter(conn, msg);
        return;
      case "move":
        this.handleMove(conn, msg);
        return;
      case "turn":
        this.handleTurn(conn, msg);
        return;
      case "chat":
        this.handleChat(conn, msg);
        return;
      case "interact":
        this.handleInteract(conn, msg);
        return;
      case "use_item":
        this.handleUseItem(conn, msg);
        return;
      case "shop_buy":
        this.handleShopBuy(conn, msg);
        return;
      case "shop_sell":
        this.handleShopSell(conn, msg);
        return;
      case "pc_deposit":
        this.handlePcDeposit(conn, msg);
        return;
      case "pc_withdraw":
        this.handlePcWithdraw(conn, msg);
        return;
      case "pc_swap":
        this.handlePcSwap(conn, msg);
        return;
      case "pokedex_request":
        this.handlePokedexRequest(conn);
        return;
      case "learn_move":
        this.handleLearnMove(conn, msg);
        return;
      case "forget_move":
        this.handleForgetMove(conn, msg);
        return;
      case "battle_action":
        this.handleBattleAction(conn, msg);
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
    const battle = this.battles.get(player.battleId);
    if (battle) {
      this.send(conn, {
        type: "battle_turn",
        battle: this.battleView(player, battle)
      });
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
    if (character) normalized = this.normalizeCharacter(character);
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
    const starterId = asString(msg.starter) ?? this.content.starters[0];
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
    if (!this.content.starters.includes(starterId)) {
      this.sendError(conn, "Please choose one of the offered partner Pokemon.");
      return;
    }
    if (trainerSprite < 0 || trainerSprite > 1) {
      this.sendError(conn, "Invalid trainer style.");
      return;
    }

    const startMap = this.map(this.content.config.startingMap || "town");
    const spawnX = CONFIG.debugStartX ?? startMap.spawn.x;
    const spawnY = CONFIG.debugStartY ?? startMap.spawn.y;
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
      party: [createStarter(this.content, starterId)],
      box: [],
      inventory: buildStartingInventory(this.content),
      pokedex: { seen: [], caught: [] },
      storyFlags: {}
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
      hasNpcAt(map, character.x, character.y)
    ) {
      map = this.map("town");
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
      battleId: null,
      encounterGraceUntil: 0,
      visiblePlayers: new Set(),
      tileWindow: null,
      portalLock: null,
      pendingLearnKey: null
    };
    conn.player = player;
    this.players.set(conn.accountId, player);
    this.sendMapState(player);
    player.visiblePlayers = new Set(
      this.visibleOthers(player).map((other) => other.accountId)
    );
    this.announcePresence(player);
    this.send(player.conn, {
      type: "notice",
      text: `Welcome, ${character.name}! The full Unova overworld is online.`
    });
    this.store.saveCharacter(player.accountId, character);
    this.sendNextMoveLearn(player);
    console.log(
      `[game] ${character.name} (${player.username}) entered ${character.mapId} at ${character.x},${character.y}; ${this.players.size} online`
    );
  }

  private handleMove(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.sendError(conn, "Create a character before moving.");
      return;
    }
    const dirValue = asString(msg.dir);
    if (!dirValue || !(dirValue in DIRECTIONS)) {
      this.sendError(conn, "Invalid direction.");
      return;
    }
    const dir = dirValue as Dir;
    const seq = asInt(msg.seq) ?? 0;
    const run = msg.run === true;
    const character = player.character;
    const now = Date.now();

    if (player.battleId) {
      this.send(conn, {
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

    if (now - player.lastMoveAt < CONFIG.moveCooldownMs) {
      this.send(conn, {
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

    const map = this.map(character.mapId);
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

    if (
      !isWalkable(map, nx, ny) ||
      hasNpcAt(map, nx, ny) ||
      !canStep(map, character.x, character.y, nx, ny)
    ) {
      if (previousDir !== dir) {
        this.broadcastToVisible(player, {
          type: "player_turned",
          playerId: character.id,
          mapId: character.mapId,
          x: character.x,
          y: character.y,
          dir
        });
      }
      this.send(conn, {
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

    character.x = nx;
    character.y = ny;
    this.clearPortalLockIfLeft(player);
    this.store.saveCharacter(player.accountId, character);
    this.send(conn, {
      type: "move_ack",
      seq,
      accepted: true,
      x: nx,
      y: ny,
      dir,
      run,
      mapId: character.mapId,
      location: this.locationName(conn.locale, character.mapId, nx, ny)
    });
    this.reconcileVisibility(player);
    const moved = {
      type: "player_moved",
      playerId: character.id,
      mapId: map.id,
      x: nx,
      y: ny,
      dir,
      run
    };
    this.broadcastToVisible(player, moved);

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

    this.maybeSendTileWindow(player, map);

    const encounter = encounterAt(map, nx, ny);
    if (
      encounter &&
      isTallGrass(map, nx, ny) &&
      now >= player.encounterGraceUntil
    ) {
      const rate = CONFIG.encounterRateOverride ?? encounter.rate;
      if (Math.random() < rate) {
        const entry = this.pickEncounter(encounter.table);
        if (entry) this.startWildBattle(player, map, entry);
      }
    }
  }

  private handleTurn(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.sendError(conn, "Create a character before turning.");
      return;
    }
    const dirValue = asString(msg.dir);
    if (!dirValue || !(dirValue in DIRECTIONS)) {
      this.sendError(conn, "Invalid direction.");
      return;
    }
    const dir = dirValue as Dir;
    const character = player.character;
    if (player.battleId || character.dir === dir) return;
    character.dir = dir;
    this.broadcastToVisible(player, {
      type: "player_turned",
      playerId: character.id,
      mapId: character.mapId,
      x: character.x,
      y: character.y,
      dir
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
    const targetMap = this.map(targetMapId);
    this.clearVisibility(player);
    player.character.mapId = targetMap.id;
    player.character.x = x;
    player.character.y = y;
    player.character.dir = direction ?? targetMap.spawn.dir;
    player.portalLock = { mapId: targetMap.id, x, y };
    this.store.saveCharacter(player.accountId, player.character);

    this.sendMapState(player);
    player.visiblePlayers = new Set(
      this.visibleOthers(player).map((other) => other.accountId)
    );
    this.announcePresence(player);
    console.log(
      `[game] ${player.character.name} travelled ${oldMapId} -> ${targetMap.id}`
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

  private handleInteract(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.sendError(conn, "Create a character first.");
      return;
    }
    if (player.battleId) {
      this.sendError(conn, "Finish the battle first.");
      return;
    }
    const npcId = asString(msg.npcId) ?? "";
    const map = this.map(player.character.mapId);
    const npc = findNpc(map, npcId);
    if (!npc) {
      this.sendError(conn, "That person is not here.");
      return;
    }
    const distance =
      Math.abs(npc.x - player.character.x) + Math.abs(npc.y - player.character.y);
    if (distance > 2) {
      this.sendError(conn, "There is nobody close enough to talk to.");
      return;
    }

    const selection = selectDialogue(npc, player.character.storyFlags);
    this.send(conn, {
      type: "dialogue",
      npcId: npc.id,
      npcName: this.i18n.npcName(conn.locale, npc.name),
      kind: npc.kind,
      lines: selection.lines.map((line) =>
        renderDialogueLine(line, player.character.name)
      )
    });

    if (selection.setFlags.length > 0) {
      player.character.storyFlags ??= {};
      for (const flag of selection.setFlags) {
        player.character.storyFlags[String(flag)] = 1;
      }
      this.store.saveCharacter(player.accountId, player.character);
    }

    if (npc.kind === "healer") {
      healParty(player.character.party);
      healParty(player.character.box);
      this.store.saveCharacter(player.accountId, player.character);
      this.sendPartyState(player);
      this.send(conn, { type: "notice", text: "Your team was healed, cured, and had its PP restored." });
      return;
    }

    if (npc.kind === "shop" && npc.shopId) {
      const shop = this.content.shops[npc.shopId];
      if (shop) this.sendShopState(player, shop.id);
      return;
    }

    if (npc.kind === "pc") {
      this.sendPcState(player);
    }
  }

  private battleView(player: PlayerSession, battle: BattleState): BattleState {
    const locale = player.conn.locale;
    return {
      ...battle,
      party: battle.party.map((creature) => this.i18n.creature(locale, creature)),
      player: this.i18n.creature(locale, battle.player),
      wild: this.i18n.creature(locale, battle.wild)
    };
  }

  private sendPartyState(player: PlayerSession): void {
    const character = player.character;
    const view = this.i18n.character(player.conn.locale, character);
    this.send(player.conn, {
      type: "party_state",
      party: view.party,
      box: view.box,
      inventory: character.inventory,
      money: character.money,
      wins: character.wins,
      pokedex: character.pokedex ?? { seen: [], caught: [] },
      maxParty: this.content.config.maxParty,
      maxBox: this.content.config.maxBox
    });
  }

  private pokedexCatalog(locale: string): Dict[] {
    const cached = this.pokedexCatalogCache.get(locale);
    if (cached) return cached;
    const catalog = Object.values(this.content.species)
      .sort((a, b) => a.dex - b.dex)
      .map((species) => ({
        dex: species.dex,
        id: species.id,
        name: this.i18n.speciesName(locale, species.id),
        types: species.types,
        evolutions: species.evolutions.map((evolution) => ({
          to: evolution.to,
          name: this.i18n.speciesName(locale, evolution.to),
          method: evolution.method,
          level: evolution.level ?? null
        }))
      }));
    this.pokedexCatalogCache.set(locale, catalog);
    return catalog;
  }

  private sendPokedexState(player: PlayerSession, includeEntries: boolean): void {
    const pokedex = player.character.pokedex ?? { seen: [], caught: [] };
    this.send(player.conn, {
      type: "pokedex_state",
      seen: pokedex.seen,
      caught: pokedex.caught,
      total: Object.keys(this.content.species).length,
      entries: includeEntries ? this.pokedexCatalog(player.conn.locale) : undefined
    });
  }

  private handlePokedexRequest(conn: Conn): void {
    const player = conn.player;
    if (!player) {
      this.sendError(conn, "Create a character first.");
      return;
    }
    this.sendPokedexState(player, true);
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

  /**
   * Sends one prompt at a time. The decision is persisted on the creature, so
   * reconnecting or closing the client cannot lose a queued level-up move.
   */
  private sendNextMoveLearn(player: PlayerSession): void {
    if (player.battleId) return;
    const next = this.firstPendingLearn(player.character);
    if (!next) {
      player.pendingLearnKey = null;
      return;
    }
    const key = `${next.source}:${next.index}:${next.moveId}`;
    if (player.pendingLearnKey === key) return;
    const move = this.content.moves[next.moveId];
    if (!move) {
      player.pendingLearnKey = null;
      return;
    }
    player.pendingLearnKey = key;
    const view = this.i18n.creature(player.conn.locale, next.creature);
    this.send(player.conn, {
      type: "move_learn_request",
      source: next.source,
      index: next.index,
      moveId: next.moveId,
      move: { ...move, name: this.i18n.moveName(player.conn.locale, move.id) },
      moves: view.moves,
      creatureName: view.name,
      creatureLevel: next.creature.level
    });
  }

  private handleLearnMove(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.sendError(conn, "Create a character first.");
      return;
    }
    if (player.battleId) {
      this.sendError(conn, "Finish the battle first.");
      return;
    }
    const source = asString(msg.source);
    if (source !== "party" && source !== "box") {
      this.sendError(conn, "Choose a valid creature.");
      return;
    }
    const index = asInt(msg.index);
    const list = source === "party" ? player.character.party : player.character.box;
    if (index === null || index < 0 || index >= list.length) {
      this.sendError(conn, "That creature does not exist.");
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
        this.sendError(conn, "Choose a move slot to replace.");
        return;
      }
    }
    const creature = list[index];
    const result = resolvePendingMove(this.content, creature, moveId, replaceIndex);
    if (!result.ok) {
      this.sendError(conn, result.error ?? "That move cannot be learned.");
      // The client closes its prompt when it sends a decision. Re-send the
      // still-pending request so a stale slot choice cannot strand the queue.
      player.pendingLearnKey = null;
      this.sendNextMoveLearn(player);
      return;
    }
    player.pendingLearnKey = null;
    this.store.saveCharacter(player.accountId, player.character);
    this.sendPartyState(player);
    const moveName = result.move?.name ?? this.content.moves[moveId]?.name ?? "the move";
    this.send(conn, {
      type: "notice",
      text: result.skipped
        ? `${creature.name} did not learn ${moveName}.`
        : `${creature.name} learned ${moveName}!`
    });
    this.sendNextMoveLearn(player);
  }

  private handleForgetMove(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.sendError(conn, "Create a character first.");
      return;
    }
    if (player.battleId) {
      this.sendError(conn, "Finish the battle first.");
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
      this.sendError(conn, "Choose a party member and move first.");
      return;
    }
    const creature = player.character.party[partyIndex];
    const result = forgetMove(creature, moveIndex);
    if (!result.ok) {
      this.sendError(conn, result.error ?? "That move cannot be forgotten.");
      return;
    }
    this.store.saveCharacter(player.accountId, player.character);
    this.sendPartyState(player);
    this.send(conn, {
      type: "notice",
      text: `${creature.name} forgot ${result.move?.name ?? "the move"}.`
    });
    this.sendNextMoveLearn(player);
  }

  private sendShopState(player: PlayerSession, shopId: string): void {
    const shop = this.content.shops[shopId];
    if (!shop) return;
    const locale = player.conn.locale;
    this.send(player.conn, {
      type: "shop_state",
      shop: {
        id: shop.id,
        name: this.i18n.shopName(locale, shop.id),
        items: shopItemsForClient(shop, this.content, player.character.inventory).map(
          (item) => this.i18n.item(locale, item)
        )
      },
      money: player.character.money,
      inventory: player.character.inventory
    });
  }

  private sendPcState(player: PlayerSession): void {
    const view = this.i18n.character(player.conn.locale, player.character);
    this.send(player.conn, {
      type: "pc_state",
      party: view.party,
      box: view.box,
      maxParty: this.content.config.maxParty,
      maxBox: this.content.config.maxBox
    });
  }

  /** Shops and the PC can only be used while standing next to their NPC. */
  private serviceNpcNearby(
    player: PlayerSession,
    predicate: (npc: MapDef["npcs"][number]) => boolean
  ): boolean {
    const map = this.map(player.character.mapId);
    return map.npcs.some((npc) => {
      if (!predicate(npc)) return false;
      const distance =
        Math.abs(npc.x - player.character.x) + Math.abs(npc.y - player.character.y);
      return distance <= 2;
    });
  }

  private handleUseItem(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.sendError(conn, "Create a character first.");
      return;
    }
    if (player.battleId) {
      this.sendError(conn, "Use items from the battle menu.");
      return;
    }
    const itemId = asString(msg.itemId) ?? "";
    const item = this.content.items[itemId];
    if (!item || item.category !== "medicine") {
      this.sendError(conn, "That item cannot be used here.");
      return;
    }
    const partyIndex = asInt(msg.partyIndex);
    if (partyIndex === null || partyIndex < 0 || partyIndex >= player.character.party.length) {
      this.sendError(conn, "Choose a party member first.");
      return;
    }
    if (itemCount(player.character.inventory, itemId) <= 0) {
      this.sendError(conn, `You have no ${item.name} left.`);
      return;
    }
    const target = player.character.party[partyIndex];
    const result = applyMedicine(item, target);
    if (!result.ok) {
      this.sendError(conn, result.error ?? "That item had no effect.");
      return;
    }
    removeItem(player.character.inventory, itemId, 1);
    this.store.saveCharacter(player.accountId, player.character);
    this.sendPartyState(player);
    this.send(conn, { type: "notice", text: result.message ?? `Used ${item.name}.` });
  }

  private handleShopBuy(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.sendError(conn, "Create a character first.");
      return;
    }
    if (player.battleId) {
      this.sendError(conn, "Finish the battle first.");
      return;
    }
    const shopId = asString(msg.shopId) ?? "";
    const shop = this.content.shops[shopId];
    if (!shop) {
      this.sendError(conn, "That shop is not open.");
      return;
    }
    if (!this.serviceNpcNearby(player, (npc) => npc.kind === "shop" && npc.shopId === shopId)) {
      this.sendError(conn, "You are not at that shop counter.");
      return;
    }
    const itemId = asString(msg.itemId) ?? "";
    if (!shop.items.includes(itemId)) {
      this.sendError(conn, "That item is not sold here.");
      return;
    }
    const item = this.content.items[itemId];
    if (!item) {
      this.sendError(conn, "That item does not exist.");
      return;
    }
    const qty = asInt(msg.qty) ?? 1;
    if (qty < 1 || qty > MAX_STACK) {
      this.sendError(conn, "Choose a quantity between 1 and 99.");
      return;
    }
    const owned = itemCount(player.character.inventory, itemId);
    if (owned + qty > MAX_STACK) {
      this.sendError(conn, `You cannot carry more than ${MAX_STACK} ${item.name}.`);
      return;
    }
    const cost = buyTotal(item, qty);
    if (player.character.money < cost) {
      this.sendError(conn, "You do not have enough money.");
      return;
    }
    player.character.money -= cost;
    addItem(player.character.inventory, itemId, qty);
    this.store.saveCharacter(player.accountId, player.character);
    this.sendShopState(player, shopId);
    this.sendPartyState(player);
    this.send(conn, {
      type: "notice",
      text: `Bought ${qty}x ${item.name} for ${cost} coins.`
    });
  }

  private handleShopSell(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.sendError(conn, "Create a character first.");
      return;
    }
    if (player.battleId) {
      this.sendError(conn, "Finish the battle first.");
      return;
    }
    const shopId = asString(msg.shopId) ?? "";
    if (!this.serviceNpcNearby(player, (npc) => npc.kind === "shop" && npc.shopId === shopId)) {
      this.sendError(conn, "You are not at that shop counter.");
      return;
    }
    const itemId = asString(msg.itemId) ?? "";
    const item = this.content.items[itemId];
    if (!item) {
      this.sendError(conn, "That item does not exist.");
      return;
    }
    const qty = asInt(msg.qty) ?? 1;
    if (qty < 1 || qty > MAX_STACK) {
      this.sendError(conn, "Choose a quantity between 1 and 99.");
      return;
    }
    if (itemCount(player.character.inventory, itemId) < qty) {
      this.sendError(conn, `You do not have ${qty}x ${item.name}.`);
      return;
    }
    const removed = removeItem(player.character.inventory, itemId, qty);
    const earned = sellPrice(item) * removed;
    player.character.money += earned;
    this.store.saveCharacter(player.accountId, player.character);
    this.sendShopState(player, shopId);
    this.sendPartyState(player);
    this.send(conn, {
      type: "notice",
      text: `Sold ${removed}x ${item.name} for ${earned} coins.`
    });
  }

  private handlePcDeposit(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.sendError(conn, "Create a character first.");
      return;
    }
    if (!this.serviceNpcNearby(player, (npc) => npc.kind === "pc")) {
      this.sendError(conn, "You are not at a PC.");
      return;
    }
    const partyIndex = asInt(msg.partyIndex);
    if (partyIndex === null) {
      this.sendError(conn, "Choose a party member first.");
      return;
    }
    const result = depositToBox(
      player.character,
      partyIndex,
      this.content.config.maxBox
    );
    if (!result.ok) {
      this.sendError(conn, result.error ?? "That Pokémon cannot be stored.");
      return;
    }
    this.store.saveCharacter(player.accountId, player.character);
    this.sendPcState(player);
    this.sendPartyState(player);
    this.send(conn, { type: "notice", text: "Pokémon stored in the PC." });
  }

  private handlePcWithdraw(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.sendError(conn, "Create a character first.");
      return;
    }
    if (!this.serviceNpcNearby(player, (npc) => npc.kind === "pc")) {
      this.sendError(conn, "You are not at a PC.");
      return;
    }
    const boxIndex = asInt(msg.boxIndex);
    if (boxIndex === null) {
      this.sendError(conn, "Choose a stored Pokémon first.");
      return;
    }
    const result = withdrawFromBox(
      player.character,
      boxIndex,
      this.content.config.maxParty
    );
    if (!result.ok) {
      this.sendError(conn, result.error ?? "That Pokémon cannot be withdrawn.");
      return;
    }
    this.store.saveCharacter(player.accountId, player.character);
    this.sendPcState(player);
    this.sendPartyState(player);
    this.send(conn, { type: "notice", text: "Pokémon withdrawn from the PC." });
  }

  private handlePcSwap(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.sendError(conn, "Create a character first.");
      return;
    }
    if (!this.serviceNpcNearby(player, (npc) => npc.kind === "pc")) {
      this.sendError(conn, "You are not at a PC.");
      return;
    }
    const partyIndex = asInt(msg.partyIndex);
    const boxIndex = asInt(msg.boxIndex);
    if (partyIndex === null || boxIndex === null) {
      this.sendError(conn, "Choose one party member and one stored Pokémon.");
      return;
    }
    const result = swapPartyWithBox(player.character, partyIndex, boxIndex);
    if (!result.ok) {
      this.sendError(conn, result.error ?? "Those Pokémon cannot be swapped.");
      return;
    }
    this.store.saveCharacter(player.accountId, player.character);
    this.sendPcState(player);
    this.sendPartyState(player);
    this.send(conn, { type: "notice", text: "Party and PC Pokémon were swapped." });
  }

  private startWildBattle(
    player: PlayerSession,
    map: MapDef,
    entry: EncounterEntry
  ): void {
    const character = player.character;
    if (!character.party.some((creature) => creature.hp > 0)) {
      this.send(player.conn, {
        type: "notice",
        text: "Your team is exhausted. Visit a nurse before searching for Pokemon."
      });
      return;
    }
    const level =
      entry.minLevel + Math.floor(Math.random() * (entry.maxLevel - entry.minLevel + 1));
    const wild = createWildCreature(this.content, entry.species, level);
    if (markSpeciesSeen(this.content, character, wild.species)) {
      this.store.saveCharacter(player.accountId, character);
      this.sendPokedexState(player, false);
    }
    const party = character.party.map((creature) => structuredClone(creature));
    const battle = createBattle(
      crypto.randomUUID(),
      party,
      wild,
      character.name,
      character.inventory,
      this.content.config.maxParty,
      this.content.items
    );
    this.battles.set(battle.id, battle);
    player.battleId = battle.id;
    this.send(player.conn, { type: "battle_start", battle: this.battleView(player, battle) });
    console.log(
      `[battle] ${character.name} encountered wild ${wild.name} L${wild.level} in ${map.id} (${battle.id})`
    );
  }

  private handleBattleAction(conn: Conn, msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.sendError(conn, "Create a character first.");
      return;
    }
    const battleId = asString(msg.battleId) ?? "";
    const battle = this.battles.get(battleId);
    if (!battle || player.battleId !== battleId) {
      this.sendError(conn, "That battle is not active.");
      return;
    }

    let action: BattleAction;
    if (msg.action === "run") {
      action = { action: "run" };
    } else if (msg.action === "catch") {
      const itemId = asString(msg.itemId) ?? "poke_ball";
      action = { action: "catch", itemId };
      if (player.character.party.length >= this.content.config.maxParty) {
        this.sendError(conn, "Your party is full.");
        return;
      }
    } else if (msg.action === "item") {
      const itemId = asString(msg.itemId) ?? "";
      const partyIndex = asInt(msg.partyIndex);
      if (itemId === "" || partyIndex === null) {
        this.sendError(conn, "An item and target are required.");
        return;
      }
      action = { action: "item", itemId, partyIndex };
    } else if (msg.action === "switch") {
      const partyIndex = asInt(msg.partyIndex);
      if (partyIndex === null) {
        this.sendError(conn, "A party index is required.");
        return;
      }
      action = { action: "switch", partyIndex };
    } else if (msg.action === "move") {
      const moveIndex = asInt(msg.moveIndex);
      if (moveIndex === null) {
        this.sendError(conn, "A move index is required.");
        return;
      }
      action = { action: "move", moveIndex };
    } else {
      this.sendError(conn, "Unknown battle action.");
      return;
    }

    try {
      resolveTurn(battle, action);
    } catch (error) {
      this.sendError(conn, error instanceof Error ? error.message : "Invalid battle action.");
      return;
    }

    this.syncBattleToCharacter(player, battle);
    this.store.saveCharacter(player.accountId, player.character);

    if (battle.status === "active") {
      this.send(conn, { type: "battle_turn", battle: this.battleView(player, battle) });
    } else {
      this.finishBattle(player, battle);
    }
  }

  private syncBattleToCharacter(player: PlayerSession, battle: BattleState): void {
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
    const result = battle.status;
    const wild = battle.wild;
    let message: string;
    let travel = false;
    let caught: CreatureState | null = null;
    let evolution: { fromSpecies: string; fromName: string; toSpecies: string; toName: string } | null =
      null;
    let pokedexChanged = false;

    if (result === "won" || result === "caught") {
      const xp = Math.max(
        1,
        Math.floor(
          (wild.baseXp + wild.level * 2) *
            (result === "caught" ? this.content.config.catchXpFactor : 1)
        )
      );
      const levelBefore = battle.player.level;
      const xpResult = awardExperience(this.content, battle.player, xp, battle.log);
      evolution = xpResult.evolution;
      const levelsGained = battle.player.level - levelBefore;
      if (levelsGained > 0) {
        battle.log.push(`${battle.player.name} reached Lv.${battle.player.level}!`);
      }

      if (result === "won") {
        character.money += this.content.config.winReward;
        character.wins += 1;
        message = `You won ${this.content.config.winReward} coins!`;
      } else {
        if (markSpeciesCaught(this.content, character, wild.species)) {
          pokedexChanged = true;
        }
        if (character.party.length < this.content.config.maxParty) {
          caught = structuredClone(wild);
          caught.xp = 0;
          battle.log.push(`${caught.name} joined your party!`);
          message = `${wild.name} was caught!`;
        } else {
          message = `${wild.name} was caught, but your party is full.`;
          battle.log.push("Your party is full, so it was released.");
        }
      }
    } else if (result === "lost") {
      message = "You blacked out.";
      travel = true;
    } else {
      message = "You got away safely.";
    }

    character.party = battle.party.map((creature) => structuredClone(creature));
    character.inventory = structuredClone(battle.inventory);
    if (caught) character.party.push(caught);

    if (evolution) {
      if (markSpeciesCaught(this.content, character, evolution.toSpecies)) {
        pokedexChanged = true;
      }
      message += ` ${evolution.fromName} evolved into ${evolution.toName}!`;
    }

    if (result === "lost") {
      healParty(character.party);
      this.clearVisibility(player);
      const home = this.map(this.content.config.startingMap || "town");
      character.mapId = home.id;
      character.x = home.spawn.x;
      character.y = home.spawn.y;
      character.dir = home.spawn.dir;
      message = `You blacked out and woke up in ${home.name}.`;
    }

    player.battleId = null;
    this.battles.delete(battle.id);
    disposeBattle(battle.id);
    player.encounterGraceUntil = Date.now() + CONFIG.encounterGraceMs;
    this.store.saveCharacter(player.accountId, character);

    this.send(player.conn, { type: "battle_turn", battle: this.battleView(player, battle) });
    if (pokedexChanged) this.sendPokedexState(player, false);

    if (travel) {
      this.sendMapState(player);
      player.visiblePlayers = new Set(
        this.visibleOthers(player).map((other) => other.accountId)
      );
      this.announcePresence(player);
    }

    const locale = player.conn.locale;
    const evolutionView = evolution
      ? {
          ...evolution,
          fromName: this.i18n.speciesName(locale, evolution.fromSpecies),
          toName: this.i18n.speciesName(locale, evolution.toSpecies)
        }
      : evolution;
    this.send(player.conn, {
      type: "battle_end",
      battleId: battle.id,
      result,
      message,
      travel,
      evolution: evolutionView,
      battle: this.battleView(player, battle),
      player: {
        money: character.money,
        wins: character.wins,
        party: this.i18n.character(locale, character).party,
        inventory: character.inventory,
        pokedex: character.pokedex ?? { seen: [], caught: [] },
        sprite: character.sprite,
        mapId: character.mapId,
        x: character.x,
        y: character.y,
        dir: character.dir
      }
    });
    this.sendNextMoveLearn(player);
    console.log(
      `[battle] ${character.name} ${result} (${battle.id}); money=${character.money} wins=${character.wins} party=${character.party.length}`
    );
  }

  private sendMapState(player: PlayerSession): void {
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
        npcs: map.npcs.map((npc) => publicNpc(this.i18n.npc(locale, npc))),
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
      players: this.visibleOthers(player).map(publicPlayer),
      online: this.players.size,
      maxParty: this.content.config.maxParty,
      maxBox: this.content.config.maxBox,
      pokedexTotal: Object.keys(this.content.species).length,
      location: this.locationName(locale, character.mapId, character.x, character.y)
    });
  }

  private removePlayer(
    player: PlayerSession,
    options: { save: boolean; notify: boolean }
  ): void {
    if (player.battleId) {
      const battle = this.battles.get(player.battleId);
      if (battle) {
        this.syncBattleToCharacter(player, battle);
        this.battles.delete(player.battleId);
        disposeBattle(player.battleId);
      }
      player.battleId = null;
    }
    if (options.notify) {
      this.clearVisibility(player);
    }
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

  private send(conn: Conn, message: Dict): void {
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

  private sendError(conn: Conn, message: string): void {
    this.send(conn, { type: "error", message });
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
    this.battles.clear();
    this.store.close();
  }
}
