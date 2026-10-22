import { Battle, Dex } from "@pkmn/sim";
import { applyMedicine, itemCount, removeItem } from "./items.js";
import { movePp } from "./creatures.js";
import type { ItemDef } from "../content/types.js";
import type { CreatureState, Inventory, PType } from "./types.js";

export type BattleStatus = "active" | "won" | "lost" | "fled" | "caught";

export type BattleSide = "player" | "wild";

/**
 * Structured battle narration for the client. `log` stays the authoritative
 * human-readable feed; `events` carries the same turn in a form the animation
 * layer can consume without parsing English sentences.
 */
export type BattleEvent =
  | {
      type: "move";
      side: BattleSide;
      moveId: number;
      moveName: string;
      moveType: PType;
      moveCategory: string;
      target?: BattleSide;
    }
  | { type: "damage"; side: BattleSide; amount: number; hp: number; maxHp: number }
  | { type: "heal"; side: BattleSide; hp: number; maxHp: number }
  | { type: "faint"; side: BattleSide }
  | { type: "miss"; side: BattleSide }
  | { type: "effective"; multiplier: number }
  | { type: "critical" }
  | { type: "status"; side: BattleSide; status: string }
  | { type: "curestatus"; side: BattleSide; status: string }
  | { type: "boost"; side: BattleSide; stat: string; amount: number }
  | { type: "switch"; side: BattleSide; name: string }
  | { type: "run"; success: boolean }
  | { type: "catch"; itemId: string; success: boolean; shakes?: number }
  | { type: "item"; itemId: string; targetIndex: number };

export interface BattleState {
  id: string;
  playerName: string;
  party: CreatureState[];
  activeIndex: number;
  player: CreatureState;
  wild: CreatureState;
  log: string[];
  /** Visual beats produced by the most recent turn, in Showdown log order. */
  events: BattleEvent[];
  turn: number;
  awaitingAction: boolean;
  mustSwitch: boolean;
  status: BattleStatus;
  /** Battle-local copy of the bag; synced back to the character when it ends. */
  inventory: Inventory;
  maxParty: number;
}

export type BattleAction =
  | { action: "move"; moveIndex: number }
  | { action: "run" }
  | { action: "switch"; partyIndex: number }
  | { action: "catch"; itemId?: string }
  | { action: "item"; itemId: string; partyIndex: number };

export type Rng = () => number;

const TYPE_CHART: Partial<Record<PType, Partial<Record<PType, number>>>> = {
  Normal: { Rock: 0.5 },
  Electric: { Water: 2, Flying: 2, Grass: 0.5, Electric: 0.5 },
  Grass: { Water: 2, Rock: 2, Fire: 0.5, Grass: 0.5, Flying: 0.5 },
  Fire: { Grass: 2, Water: 0.5, Fire: 0.5, Rock: 0.5 },
  Water: { Fire: 2, Rock: 2, Grass: 0.5, Water: 0.5 },
  Rock: { Fire: 2, Flying: 2, Grass: 0.5 },
  Flying: { Grass: 2, Electric: 0.5, Rock: 0.5 }
};

export function effectiveness(moveType: PType, defenderTypes: PType[]): number {
  let multiplier = 1;
  for (const type of defenderTypes) {
    multiplier *= TYPE_CHART[moveType]?.[type] ?? 1;
  }
  return multiplier;
}

const ZERO_STATS = { hp: 0, atk: 0, def: 0, spa: 0, spd: 0, spe: 0 };
const HIDDEN_NOOP_MOVE = "splash";

interface ShowdownSession {
  battle: Battle;
  partyPokemon: any[];
  wildPokemon: any;
  logIndex: number;
  hpBefore: Map<string, number>;
  lastRawLine: string;
  items: Record<string, ItemDef>;
}

const sessions = new Map<string, ShowdownSession>();

function toShowdownId(id: string): string {
  return id.toLowerCase().replace(/[^a-z0-9]/g, "");
}

function abilityFor(speciesId: string): string {
  const species = Dex.species.get(toShowdownId(speciesId));
  if (!species?.abilities) return "";
  return Object.values(species.abilities).find((ability) => typeof ability === "string") ?? "";
}

function toPokemonSet(creature: CreatureState, withNoop: boolean): any {
  const moves = creature.moves.map((move) => toShowdownId(move.id)).filter(Boolean);
  if (withNoop && !moves.includes(HIDDEN_NOOP_MOVE)) moves.push(HIDDEN_NOOP_MOVE);
  return {
    species: toShowdownId(creature.species),
    level: creature.level,
    moves,
    ability: abilityFor(creature.species),
    item: "",
    nature: "Serious",
    evs: { ...ZERO_STATS },
    ivs: { ...ZERO_STATS }
  };
}

function addLog(state: BattleState, line: string): void {
  state.log.push(line);
  if (state.log.length > 120) state.log.splice(0, state.log.length - 120);
}

function cleanIdent(ident: string): string {
  return ident.replace(/^p[1-4][a-z]?: /, "");
}

function isWild(ident: string): boolean {
  return /^p2/.test(ident);
}

function sideOf(ident: string): BattleSide {
  return isWild(ident) ? "wild" : "player";
}

function addEvent(state: BattleState, event: BattleEvent): void {
  state.events.push(event);
}

function hpKey(ident: string): string {
  return `${ident.slice(0, 2)}:${cleanIdent(ident)}`;
}

const STATUS_TEXT: Record<string, string> = {
  brn: "was burned",
  par: "was paralyzed",
  slp: "fell asleep",
  psn: "was poisoned",
  tox: "was badly poisoned",
  frz: "was frozen"
};

const STAT_TEXT: Record<string, string> = {
  atk: "Attack",
  def: "Defense",
  spa: "Sp. Atk",
  spd: "Sp. Def",
  spe: "Speed",
  accuracy: "accuracy",
  evasion: "evasiveness"
};

function captureHpBefore(session: ShowdownSession): void {
  session.hpBefore.clear();
  for (const pokemon of session.partyPokemon) {
    if (pokemon) session.hpBefore.set(`p1:${pokemon.name}`, pokemon.hp);
  }
  if (session.wildPokemon) {
    session.hpBefore.set(`p2:${session.wildPokemon.name}`, session.wildPokemon.hp);
  }
}

function translateLogs(session: ShowdownSession, state: BattleState): void {
  const battle = session.battle;
  const lines = battle.log.slice(session.logIndex);
  session.logIndex = battle.log.length;
  for (const raw of lines) {
    if (raw === session.lastRawLine) continue;
    session.lastRawLine = raw;
    if (!raw.startsWith("|")) continue;
    const parts = raw.split("|");
    const kind = parts[1];
    if (!kind) continue;
    if (
      kind === "t:" ||
      kind === "split" ||
      kind === "turn" ||
      kind === "upkeep" ||
      kind === "teamsize" ||
      kind === "player" ||
      kind === "poke" ||
      kind === "gametype" ||
      kind === "gen" ||
      kind === "tier" ||
      kind === "clearpoke" ||
      kind === "teampreview" ||
      kind === "start" ||
      kind === "request" ||
      kind === "inactive" ||
      kind === "nothing" ||
      kind === "win" ||
      kind === "debug" ||
      kind === "-anim"
    ) {
      continue;
    }

    if (kind === "move") {
      const ident = parts[2] ?? "";
      const moveName = parts[3] ?? "";
      if (moveName === "Splash") continue;
      const name = cleanIdent(ident);
      const definition = Dex.moves.get(moveName);
      const targetIdent = parts[4] ?? "";
      addEvent(state, {
        type: "move",
        side: sideOf(ident),
        moveId: typeof definition?.num === "number" ? definition.num : 0,
        moveName,
        moveType: (definition?.type as PType) ?? "Normal",
        moveCategory: (definition?.category ?? "status").toLowerCase(),
        ...(targetIdent ? { target: sideOf(targetIdent) } : {})
      });
      addLog(state, `${isWild(ident) ? "Wild " : ""}${name} used ${moveName}!`);
      continue;
    }
    if (kind === "switch" || kind === "drag") {
      const ident = parts[2] ?? "";
      const name = cleanIdent(ident);
      addEvent(state, { type: "switch", side: sideOf(ident), name });
      if (isWild(ident)) addLog(state, `Wild ${name} appeared!`);
      else addLog(state, `Go, ${name}!`);
      continue;
    }
    if (kind === "-damage") {
      const ident = parts[2] ?? "";
      const condition = parts[3] ?? "";
      const match = /^(\d+)\/(\d+)/.exec(condition);
      if (!match) continue;
      const current = Number(match[1]);
      const maximum = Number(match[2]);
      const key = hpKey(ident);
      const before = session.hpBefore.get(key) ?? current;
      const dealt = Math.max(0, before - current);
      session.hpBefore.set(key, current);
      if (dealt > 0) {
        addEvent(state, {
          type: "damage",
          side: sideOf(ident),
          amount: dealt,
          hp: current,
          maxHp: maximum
        });
        addLog(state, `${cleanIdent(ident)} took ${dealt} damage.`);
      }
      continue;
    }
    if (kind === "-heal") {
      const ident = parts[2] ?? "";
      const condition = parts[3] ?? "";
      const match = /^(\d+)\/(\d+)/.exec(condition);
      addEvent(state, {
        type: "heal",
        side: sideOf(ident),
        hp: match ? Number(match[1]) : 0,
        maxHp: match ? Number(match[2]) : 0
      });
      addLog(state, `${cleanIdent(ident)} recovered HP.`);
      continue;
    }
    if (kind === "faint") {
      const ident = parts[2] ?? "";
      addEvent(state, { type: "faint", side: sideOf(ident) });
      addLog(state, `${cleanIdent(ident)} fainted!`);
      continue;
    }
    if (kind === "-supereffective") {
      addEvent(state, { type: "effective", multiplier: 2 });
      addLog(state, "It's super effective!");
      continue;
    }
    if (kind === "-resisted") {
      addEvent(state, { type: "effective", multiplier: 0.5 });
      addLog(state, "It's not very effective...");
      continue;
    }
    if (kind === "-immune") {
      addEvent(state, { type: "effective", multiplier: 0 });
      addLog(state, "It doesn't affect the target...");
      continue;
    }
    if (kind === "-crit") {
      addEvent(state, { type: "critical" });
      addLog(state, "A critical hit!");
      continue;
    }
    if (kind === "-miss") {
      const ident = parts[2] ?? "";
      addEvent(state, { type: "miss", side: sideOf(ident) });
      addLog(state, `${cleanIdent(ident)}'s attack missed!`);
      continue;
    }
    if (kind === "-status") {
      const ident = parts[2] ?? "";
      const status = parts[3] ?? "";
      addEvent(state, { type: "status", side: sideOf(ident), status });
      addLog(state, `${cleanIdent(ident)} ${STATUS_TEXT[status] ?? "was affected by a status"}.`);
      continue;
    }
    if (kind === "-curestatus") {
      const ident = parts[2] ?? "";
      addEvent(state, { type: "curestatus", side: sideOf(ident), status: parts[3] ?? "" });
      addLog(state, `${cleanIdent(ident)} was cured of its status.`);
      continue;
    }
    if (kind === "-boost" || kind === "-unboost") {
      const ident = parts[2] ?? "";
      const stat = parts[3] ?? "";
      const amount = Number(parts[4] ?? 0);
      const lowered = kind === "-unboost" || amount < 0;
      addEvent(state, {
        type: "boost",
        side: sideOf(ident),
        stat,
        amount: lowered ? -Math.abs(amount) : Math.abs(amount)
      });
      addLog(
        state,
        `${cleanIdent(ident)}'s ${STAT_TEXT[stat] ?? stat} ${lowered ? "fell" : "rose"}!`
      );
      continue;
    }
    if (kind === "cant") {
      const ident = parts[2] ?? "";
      addLog(state, `${cleanIdent(ident)} can't move!`);
    }
  }
}

function applyPersistedPp(pokemon: any, creature: CreatureState): void {
  const slots = (pokemon?.moveSlots ?? []) as Array<{
    id: string;
    pp: number;
    maxpp: number;
    ppUps?: number;
  }>;
  for (const slot of slots) {
    const move = creature.moves.find((entry) => toShowdownId(entry.id) === slot.id);
    if (!move) continue;
    const state = movePp(move);
    // Showdown defaults a fresh custom-game set to three PP Ups. Our content
    // PP is the ROM base value, so clear them and restore the saved remainder.
    slot.ppUps = 0;
    slot.maxpp = state.max;
    slot.pp = state.current;
  }
}

function syncPpFromShowdown(pokemon: any, creature: CreatureState): void {
  const slots = (pokemon?.moveSlots ?? []) as Array<{
    id: string;
    pp: number;
    maxpp: number;
  }>;
  for (const slot of slots) {
    const move = creature.moves.find((entry) => toShowdownId(entry.id) === slot.id);
    if (!move) continue;
    const max = movePp(move).max;
    move.maxPp = max;
    move.currentPp = Math.max(0, Math.min(max, slot.pp));
  }
}

function syncToShowdown(session: ShowdownSession, state: BattleState): void {
  for (let index = 0; index < state.party.length; index++) {
    const pokemon = session.partyPokemon[index];
    const creature = state.party[index];
    if (!pokemon || !creature) continue;
    pokemon.hp = Math.max(0, Math.min(creature.hp, pokemon.maxhp));
    if (creature.status !== undefined) pokemon.status = creature.status;
    else pokemon.status = "";
    // A Revive can bring a benched creature back mid-battle; keep Showdown's
    // fainted bookkeeping in step or it refuses the next switch.
    pokemon.fainted = pokemon.hp <= 0;
  }
  if (session.wildPokemon) {
    session.wildPokemon.hp = Math.max(0, Math.min(state.wild.hp, session.wildPokemon.maxhp));
    if (state.wild.status !== undefined) session.wildPokemon.status = state.wild.status;
    else session.wildPokemon.status = "";
  }
}

function syncFromShowdown(session: ShowdownSession, state: BattleState): void {
  for (let index = 0; index < state.party.length; index++) {
    const pokemon = session.partyPokemon[index];
    const creature = state.party[index];
    if (!pokemon || !creature) continue;
    creature.hp = Math.max(0, pokemon.hp);
    creature.maxHp = pokemon.maxhp;
    creature.status = pokemon.status || undefined;
    syncPpFromShowdown(pokemon, creature);
  }
  if (session.wildPokemon) {
    state.wild.hp = Math.max(0, session.wildPokemon.hp);
    state.wild.maxHp = session.wildPokemon.maxhp;
    state.wild.status = session.wildPokemon.status || undefined;
    syncPpFromShowdown(session.wildPokemon, state.wild);
  }

  const active = session.battle.p1.active[0];
  const activeIndex = active ? session.partyPokemon.indexOf(active) : -1;
  if (activeIndex >= 0) {
    state.activeIndex = activeIndex;
    state.player = state.party[activeIndex];
  }

  const p1Alive = state.party.some((creature) => creature.hp > 0);
  const p2Alive = state.wild.hp > 0;
  if (!p2Alive) {
    state.status = "won";
    addLog(state, "You won the battle!");
  } else if (!p1Alive) {
    state.status = "lost";
    addLog(state, "You blacked out...");
  } else if (session.battle.ended) {
    state.status = session.battle.winner === state.playerName ? "won" : "lost";
    addLog(state, state.status === "won" ? "You won the battle!" : "You blacked out...");
  }

  if (state.status !== "active") {
    state.awaitingAction = false;
    state.mustSwitch = false;
    sessions.delete(state.id);
    return;
  }

  state.mustSwitch = session.battle.requestState === "switch";
  state.awaitingAction =
    session.battle.requestState === "move" || session.battle.requestState === "switch";
}

function chooseWildMove(session: ShowdownSession): string {
  const pokemon = session.wildPokemon;
  if (!pokemon) return "tackle";
  const slots = (pokemon.moveSlots ?? []) as Array<{ id: string; pp: number }>;
  const available = slots.filter((slot) => slot.pp > 0);
  const damaging = available.find((slot) => (Dex.moves.get(slot.id)?.basePower ?? 0) > 0);
  return (damaging ?? available[0] ?? slots[0])?.id ?? "struggle";
}

function runNoopTurn(session: ShowdownSession, state: BattleState): void {
  const wildMove = chooseWildMove(session);
  session.battle.makeChoices(`move ${HIDDEN_NOOP_MOVE}`, `move ${wildMove}`);
  translateLogs(session, state);
  syncFromShowdown(session, state);
}

const STATUS_CATCH_BONUS: Record<string, number> = {
  slp: 2.5,
  frz: 2.5,
  par: 1.5,
  psn: 1.5,
  tox: 1.5,
  brn: 1.5
};

/**
 * Gen 5-style modified catch rate `a` and shake threshold `b`.
 *
 * `a = ((3*maxHP - 2*hp) * catchRate * ballBonus) / (3*maxHP) * statusBonus`
 *
 * The project's content stores catchRate as the ROM value / 255; round it back
 * to 0..255 here. `a` is kept at 1/4096 precision like the Gen 5 games, and
 * `b` is the Gen 3-5 shake threshold (`65536 / (255/a)^(1/4)`).
 * Critical captures and dark-grass/capture-power modifiers are not modeled.
 */
export function catchParameters(
  wild: CreatureState,
  ballBonus: number = 1
): { a: number; b: number; guaranteed: boolean } {
  const maxHp = Math.max(1, wild.maxHp);
  const hp = Math.max(0, Math.min(maxHp, wild.hp));
  const catchRate = Math.max(
    1,
    Math.min(255, Math.round(wild.catchRate * 255))
  );
  const bonus = Number.isFinite(ballBonus) && ballBonus > 0 ? ballBonus : 1;
  const status = String(wild.status ?? "").toLowerCase();
  const statusBonus = STATUS_CATCH_BONUS[status] ?? 1;
  const numerator = (3 * maxHp - 2 * hp) * catchRate * bonus * statusBonus;
  const a = Math.max(1, Math.floor((numerator * 4096) / (3 * maxHp)) / 4096);
  if (a >= 255) return { a, b: 65536, guaranteed: true };
  const b = Math.min(
    65536,
    Math.floor(65536 / Math.pow(255 / a, 0.25))
  );
  return { a, b, guaranteed: false };
}

/** Probability that all three shake checks pass. */
export function catchChance(wild: CreatureState, ballBonus: number = 1): number {
  const { b, guaranteed } = catchParameters(wild, ballBonus);
  if (guaranteed) return 1;
  return Math.min(1, Math.pow(b / 65536, 3));
}

/** Number of successful shake checks (0..3). */
export function catchShakes(
  wild: CreatureState,
  ballBonus: number = 1,
  rng: Rng = Math.random
): number {
  const { b, guaranteed } = catchParameters(wild, ballBonus);
  if (guaranteed) return 3;
  let shakes = 0;
  while (shakes < 3 && Math.floor(rng() * 65536) < b) shakes++;
  return shakes;
}

export function disposeBattle(id: string): void {
  sessions.delete(id);
}

export function createBattle(
  id: string,
  party: CreatureState[],
  wild: CreatureState,
  playerName: string,
  inventory: Inventory,
  maxParty: number,
  items: Record<string, ItemDef>
): BattleState {
  const activeIndex = party.findIndex((creature) => creature.hp > 0);
  if (activeIndex < 0) throw new Error("The party has no healthy creature");

  const battle = new Battle({
    formatid: "gen5customgame",
    seed: [1, 2, 3, 4]
  } as any);
  battle.setPlayer("p1", {
    name: playerName,
    team: party.map((creature) => toPokemonSet(creature, true))
  });
  battle.setPlayer("p2", {
    name: "Wild",
    team: [toPokemonSet(wild, false)]
  });
  const order = [activeIndex, ...party.map((_, index) => index).filter((index) => index !== activeIndex)];
  battle.makeChoices(`team ${order.map((index) => index + 1).join("")}`, "team 1");

  const partyPokemon: any[] = new Array(party.length);
  for (let index = 0; index < order.length; index++) {
    partyPokemon[order[index]] = battle.p1.pokemon[index];
  }

  const wildPokemon = battle.p2.pokemon[0];
  const session: ShowdownSession = {
    battle,
    partyPokemon,
    wildPokemon,
    logIndex: battle.log.length,
    hpBefore: new Map(),
    lastRawLine: "",
    items
  };
  sessions.set(id, session);

  for (let index = 0; index < party.length; index++) {
    const pokemon = partyPokemon[index];
    if (pokemon) {
      pokemon.hp = Math.max(0, Math.min(party[index].hp, pokemon.maxhp));
      applyPersistedPp(pokemon, party[index]);
    }
  }
  if (wildPokemon) {
    wildPokemon.hp = Math.max(0, Math.min(wild.hp, wildPokemon.maxhp));
    applyPersistedPp(wildPokemon, wild);
  }

  return {
    id,
    playerName,
    party,
    activeIndex,
    player: party[activeIndex],
    wild,
    log: [`A wild ${wild.name} appeared!`, `Go, ${party[activeIndex].name}!`],
    events: [],
    turn: 0,
    awaitingAction: true,
    mustSwitch: false,
    status: "active",
    inventory: structuredClone(inventory),
    maxParty
  };
}

/**
 * Resolves one player decision through the Pokémon Showdown Gen 5 simulator.
 * Encounter flow, capture, run checks, XP and rewards stay in our server layer.
 */
export function resolveTurn(
  state: BattleState,
  action: BattleAction,
  rng: Rng = Math.random
): BattleState {
  if (state.status !== "active" || !state.awaitingAction) {
    throw new Error("Battle is not awaiting an action");
  }
  if (state.mustSwitch && action.action !== "switch") {
    throw new Error("Choose a replacement first");
  }
  const session = sessions.get(state.id);
  if (!session) throw new Error("Battle simulator is not available");

  let switchIndex = -1;
  let ball: ItemDef | null = null;
  let medicine: ItemDef | null = null;
  let medicineTarget = -1;
  if (action.action === "switch") {
    switchIndex = action.partyIndex;
    if (
      !Number.isInteger(switchIndex) ||
      switchIndex < 0 ||
      switchIndex >= state.party.length
    ) {
      throw new Error("Invalid party index");
    }
    if (switchIndex === state.activeIndex) {
      throw new Error("That creature is already active");
    }
    if (state.party[switchIndex].hp <= 0) {
      throw new Error("That creature has fainted");
    }
  } else if (action.action === "catch") {
    const itemId = action.itemId ?? "poke_ball";
    const candidate = session.items[itemId];
    if (!candidate || candidate.category !== "ball") {
      throw new Error("That is not a Ball");
    }
    if (itemCount(state.inventory, itemId) <= 0) {
      throw new Error(`You have no ${candidate.name} left`);
    }
    if (state.party.length >= state.maxParty) throw new Error("Your party is full");
    ball = candidate;
  } else if (action.action === "item") {
    const candidate = session.items[action.itemId];
    if (!candidate || candidate.category !== "medicine") {
      throw new Error("That item cannot be used in battle");
    }
    if (itemCount(state.inventory, candidate.id) <= 0) {
      throw new Error(`You have no ${candidate.name} left`);
    }
    if (
      !Number.isInteger(action.partyIndex) ||
      action.partyIndex < 0 ||
      action.partyIndex >= state.party.length
    ) {
      throw new Error("Invalid party index");
    }
    medicine = candidate;
    medicineTarget = action.partyIndex;
    // Probe the effect before the turn is consumed so "already at full HP"
    // and similar rejections leave the battle awaiting an action.
    const probe = applyMedicine(candidate, structuredClone(state.party[medicineTarget]));
    if (!probe.ok) throw new Error(probe.error ?? "That item had no effect");
  } else if (action.action === "move") {
    if (
      !Number.isInteger(action.moveIndex) ||
      action.moveIndex < 0 ||
      action.moveIndex >= state.player.moves.length
    ) {
      throw new Error("Invalid move index");
    }
    if (movePp(state.player.moves[action.moveIndex]).current <= 0) {
      throw new Error("That move has no PP left");
    }
  }

  state.awaitingAction = false;
  state.turn += 1;
  state.events = [];
  syncToShowdown(session, state);
  captureHpBefore(session);

  if (action.action === "run") {
    if (rng() < 0.55) {
      addEvent(state, { type: "run", success: true });
      addLog(state, "Got away safely!");
      state.status = "fled";
      state.mustSwitch = false;
      sessions.delete(state.id);
      return state;
    }
    addEvent(state, { type: "run", success: false });
    addLog(state, "Couldn't escape!");
    runNoopTurn(session, state);
    return state;
  }

  if (action.action === "catch" && ball) {
    removeItem(state.inventory, ball.id, 1);
    addLog(state, `You threw a ${ball.name}!`);
    const shakes = catchShakes(state.wild, ball.ballBonus ?? 1, rng);
    if (shakes >= 3) {
      addEvent(state, {
        type: "catch",
        itemId: ball.id,
        success: true,
        shakes
      });
      addLog(state, `Gotcha! Wild ${state.wild.name} was caught!`);
      state.status = "caught";
      state.awaitingAction = false;
      state.mustSwitch = false;
      sessions.delete(state.id);
      return state;
    }
    addEvent(state, {
      type: "catch",
      itemId: ball.id,
      success: false,
      shakes
    });
    addLog(state, "It broke free!");
    runNoopTurn(session, state);
    return state;
  }

  if (action.action === "item" && medicine) {
    const target = state.party[medicineTarget];
    const result = applyMedicine(medicine, target);
    if (!result.ok) throw new Error(result.error ?? "That item had no effect");
    removeItem(state.inventory, medicine.id, 1);
    addEvent(state, {
      type: "item",
      itemId: medicine.id,
      targetIndex: medicineTarget
    });
    if (medicineTarget === state.activeIndex) {
      addEvent(state, {
        type: "heal",
        side: "player",
        hp: target.hp,
        maxHp: target.maxHp
      });
    }
    addLog(state, result.message ?? `Used ${medicine.name}.`);
    syncToShowdown(session, state);
    runNoopTurn(session, state);
    return state;
  }

  if (action.action === "switch") {
    const target = session.partyPokemon[switchIndex];
    const slot = session.battle.p1.pokemon.indexOf(target) + 1;
    if (slot <= 0) throw new Error("That creature is not in the battle");
    if (session.battle.requestState === "switch") {
      session.battle.makeChoices(`switch ${slot}`);
    } else {
      const wildMove = chooseWildMove(session);
      session.battle.makeChoices(`switch ${slot}`, `move ${wildMove}`);
    }
    translateLogs(session, state);
    syncFromShowdown(session, state);
    return state;
  }

  if (action.action !== "move") throw new Error("Invalid battle action");
  const moveIndex = action.moveIndex;
  const playerMove = state.player.moves[moveIndex];
  const moveId = toShowdownId(playerMove.id);
  const active = session.battle.p1.active[0];
  const knownMove = active?.moveSlots?.some((slot: { id: string }) => slot.id === moveId);
  if (!knownMove) throw new Error("That move is not available");
  const wildMove = chooseWildMove(session);
  session.battle.makeChoices(`move ${moveId}`, `move ${wildMove}`);
  translateLogs(session, state);
  syncFromShowdown(session, state);
  return state;
}
