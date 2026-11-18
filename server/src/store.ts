import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import type { CharacterState } from "./game/types.js";
import { CONFIG } from "./config.js";

export interface AccountRecord {
  id: string;
  username: string;
  salt: string;
  hash: string;
  createdAt: number;
}

interface TokenRecord {
  accountId: string;
  expiresAt: number;
}

/** A pending friend request; friendships themselves live on the character. */
export interface FriendRequestRecord {
  from: string;
  to: string;
  at: number;
}

interface StoreData {
  version: 1;
  accounts: Record<string, AccountRecord>;
  tokens: Record<string, TokenRecord>;
  characters: Record<string, CharacterState>;
  friendRequests: FriendRequestRecord[];
}

function emptyData(): StoreData {
  return { version: 1, accounts: {}, tokens: {}, characters: {}, friendRequests: [] };
}

function hashPassword(password: string, salt: string): string {
  return crypto.scryptSync(password, salt, 64).toString("hex");
}

/**
 * Prototype persistence: a single atomically-written JSON file with debounced
 * saves. The public surface is intentionally small so it can be replaced with
 * PostgreSQL later without touching the game logic.
 */
export class Store {
  private readonly file: string;
  private data: StoreData;
  private saveTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(dataDir: string) {
    fs.mkdirSync(dataDir, { recursive: true });
    this.file = path.join(dataDir, "store.json");
    this.data = this.load();
    this.purgeExpiredTokens();
  }

  private load(): StoreData {
    if (!fs.existsSync(this.file)) return emptyData();
    const raw = fs.readFileSync(this.file, "utf8");
    const parsed = JSON.parse(raw) as Partial<StoreData>;
    if (parsed.version !== 1) {
      throw new Error(`Unsupported store version in ${this.file}`);
    }
    return {
      version: 1,
      accounts: parsed.accounts ?? {},
      tokens: parsed.tokens ?? {},
      characters: parsed.characters ?? {},
      friendRequests: Array.isArray(parsed.friendRequests) ? parsed.friendRequests : []
    };
  }

  private scheduleSave(): void {
    if (this.saveTimer) return;
    this.saveTimer = setTimeout(() => {
      this.saveTimer = null;
      this.flush();
    }, CONFIG.saveDebounceMs);
  }

  private purgeExpiredTokens(): void {
    const now = Date.now();
    let changed = false;
    for (const [token, record] of Object.entries(this.data.tokens)) {
      if (record.expiresAt <= now) {
        delete this.data.tokens[token];
        changed = true;
      }
    }
    if (changed) this.scheduleSave();
  }

  register(username: string, password: string): { ok: true; account: AccountRecord } | { ok: false; error: string } {
    const key = username.toLowerCase();
    if (this.data.accounts[key]) {
      return { ok: false, error: "That username is already registered." };
    }
    const salt = crypto.randomBytes(16).toString("hex");
    const account: AccountRecord = {
      id: crypto.randomUUID(),
      username,
      salt,
      hash: hashPassword(password, salt),
      createdAt: Date.now()
    };
    this.data.accounts[key] = account;
    this.scheduleSave();
    return { ok: true, account };
  }

  login(username: string, password: string): AccountRecord | null {
    const account = this.data.accounts[username.toLowerCase()];
    if (!account) return null;
    const candidate = Buffer.from(hashPassword(password, account.salt), "hex");
    const stored = Buffer.from(account.hash, "hex");
    if (candidate.length !== stored.length) return null;
    if (!crypto.timingSafeEqual(candidate, stored)) return null;
    return account;
  }

  issueToken(accountId: string): string {
    const token = crypto.randomBytes(32).toString("base64url");
    this.data.tokens[token] = {
      accountId,
      expiresAt: Date.now() + CONFIG.tokenTtlMs
    };
    this.scheduleSave();
    return token;
  }

  /**
   * Invalidate every token issued for an account. Logging out is account-wide:
   * a second device holding an older token must not silently resume the same
   * trainer after the player asked to sign out.
   */
  revokeTokens(accountId: string): void {
    let changed = false;
    for (const [token, record] of Object.entries(this.data.tokens)) {
      if (record.accountId !== accountId) continue;
      delete this.data.tokens[token];
      changed = true;
    }
    if (changed) this.scheduleSave();
  }

  resume(token: string): AccountRecord | null {
    const record = this.data.tokens[token];
    if (!record || record.expiresAt <= Date.now()) {
      if (record) {
        delete this.data.tokens[token];
        this.scheduleSave();
      }
      return null;
    }
    const account = Object.values(this.data.accounts).find((entry) => entry.id === record.accountId);
    return account ?? null;
  }

  getCharacter(accountId: string): CharacterState | null {
    const character = this.data.characters[accountId];
    return character ? structuredClone(character) : null;
  }

  /** Character id is the stable public identity used by friends and DMs. */
  characterById(characterId: string): { accountId: string; character: CharacterState } | null {
    for (const [accountId, character] of Object.entries(this.data.characters)) {
      if (character.id === characterId) {
        return { accountId, character: structuredClone(character) };
      }
    }
    return null;
  }

  characterByName(name: string): { accountId: string; character: CharacterState } | null {
    const needle = name.toLowerCase();
    for (const [accountId, character] of Object.entries(this.data.characters)) {
      if (character.name.toLowerCase() === needle) {
        return { accountId, character: structuredClone(character) };
      }
    }
    return null;
  }

  saveCharacter(accountId: string, character: CharacterState): void {
    this.data.characters[accountId] = structuredClone(character);
    this.scheduleSave();
  }

  hasCharacter(accountId: string): boolean {
    return Boolean(this.data.characters[accountId]);
  }

  isNameTaken(name: string): boolean {
    const needle = name.toLowerCase();
    return Object.values(this.data.characters).some(
      (character) => character.name.toLowerCase() === needle
    );
  }

  characterCount(): number {
    return Object.keys(this.data.characters).length;
  }

  /** Returns false when the request already exists. */
  addFriendRequest(from: string, to: string): boolean {
    if (this.hasFriendRequest(from, to)) return false;
    this.data.friendRequests.push({ from, to, at: Date.now() });
    this.scheduleSave();
    return true;
  }

  removeFriendRequest(from: string, to: string): boolean {
    const remaining = this.data.friendRequests.filter(
      (request) => !(request.from === from && request.to === to)
    );
    if (remaining.length === this.data.friendRequests.length) return false;
    this.data.friendRequests = remaining;
    this.scheduleSave();
    return true;
  }

  hasFriendRequest(from: string, to: string): boolean {
    return this.data.friendRequests.some(
      (request) => request.from === from && request.to === to
    );
  }

  friendRequestsFrom(characterId: string): FriendRequestRecord[] {
    return this.data.friendRequests
      .filter((request) => request.from === characterId)
      .map((request) => ({ ...request }));
  }

  friendRequestsTo(characterId: string): FriendRequestRecord[] {
    return this.data.friendRequests
      .filter((request) => request.to === characterId)
      .map((request) => ({ ...request }));
  }

  allCharacters(): Array<{ accountId: string; character: CharacterState }> {
    return Object.entries(this.data.characters).map(([accountId, character]) => ({
      accountId,
      character: structuredClone(character)
    }));
  }

  flush(): void {
    if (this.saveTimer) {
      clearTimeout(this.saveTimer);
      this.saveTimer = null;
    }
    const tmp = `${this.file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(this.data, null, 2), "utf8");
    fs.renameSync(tmp, this.file);
  }

  close(): void {
    this.flush();
  }
}
