import { Battle, Dex } from "@pkmn/sim";
import { applyMedicine, itemCount, removeItem } from "./items.js";
import { movePp } from "./creatures.js";
import { resolveAbilityForSpecies } from "./abilities.js";
import type { ItemDef } from "../content/types.js";
import type { CreatureState, Inventory, PType, StatBlock } from "./types.js";

export type BattleStatus = "active" | "won" | "lost" | "fled" | "caught";

export type BattleMode = "wild" | "duel" | "trainer";

export type BattleSide = "player" | "wild";

export type DuelSide = "p1" | "p2";

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
  | {
      type: "ability";
      side: BattleSide;
      abilityId: string;
      /** Localized in BattlesController.view before it reaches the client. */
      abilityName?: string;
      description?: string;
    }
  | { type: "switch"; side: BattleSide; name: string }
  | { type: "run"; success: boolean }
  | { type: "catch"; itemId: string; success: boolean; shakes?: number }
  | { type: "item"; itemId: string; targetIndex: number };

export interface BattleState {
  id: string;
  mode: BattleMode;
  playerName: string;
  party: CreatureState[];
  activeIndex: number;
  player: CreatureState;
  /** Opponent's active creature. Wild battles and duels both use this key. */
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
  /** Duel/trainer: the other trainer's display name. */
  opponentName?: string;
  /** Duel/trainer: the other trainer's full party and active slot. */
  opponentParty?: CreatureState[];
  opponentActiveIndex?: number;
  opponent?: CreatureState;
  /** Duel-only: mirrored event stream for the opponent's client. */
  eventsOpponent?: BattleEvent[];
  awaitingOpponent?: boolean;
  mustSwitchOpponent?: boolean;
  /** Duel-only: choices submitted for the current turn, before it resolves. */
  choices?: { player: BattleAction | null; opponent: BattleAction | null };
  /** Trainer-only: content trainer id, so the story can resume afterwards. */
  trainerId?: string;
  /** Trainer-only: coins paid for winning (story battles usually pay none). */
  reward?: number;
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

const HIDDEN_NOOP_MOVE = "splash";

interface ShowdownSession {
  battle: Battle;
  partyPokemon: any[];
  wildPokemon: any;
  /** Duel-only: p2's party in original party-index order. */
  opponentPartyPokemon?: any[];
  duel?: boolean;
  logIndex: number;
  hpBefore: Map<string, number>;
  lastRawLine: string;
  items: Record<string, ItemDef>;
}

const sessions = new Map<string, ShowdownSession>();

function toShowdownId(id: string): string {
  return id.toLowerCase().replace(/[^a-z0-9]/g, "");
}

/** Our stat blocks use spAtk/spDef; Showdown's sets use spa/spd. */
function toShowdownStatBlock(block: StatBlock | undefined): Record<string, number> {
  return {
    hp: block?.hp ?? 0,
    atk: block?.atk ?? 0,
    def: block?.def ?? 0,
    spa: block?.spAtk ?? 0,
    spd: block?.spDef ?? 0,
    spe: block?.speed ?? 0
  };
}

function toPokemonSet(creature: CreatureState, withNoop: boolean): any {
  const moves = creature.moves.map((move) => toShowdownId(move.id)).filter(Boolean);
  if (withNoop && !moves.includes(HIDDEN_NOOP_MOVE)) moves.push(HIDDEN_NOOP_MOVE);
  const ability = resolveAbilityForSpecies(
    creature.species,
    creature.ability,
    creature.abilitySlot
  );
  return {
    species: toShowdownId(creature.species),
    level: creature.level,
    moves,
    ability: ability?.id ?? "",
    item: "",
    // Persisted training is authoritative: the same IV/EV/nature inputs feed
    // both statsForCreature and Showdown, so the HUD and damage agree.
    nature: creature.nature ?? "Serious",
    evs: toShowdownStatBlock(creature.evs),
    ivs: toShowdownStatBlock(creature.ivs)
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

/**
 * Abilities that announce themselves on switch-in happen during the team
 * selection `makeChoices` call, before the session starts tracking the log.
 * Scan that initial block for ability activations so Intimidate and friends
 * still reach the client as a notification.
 */
function initialAbilityEvents(log: string[]): BattleEvent[] {
  const events: BattleEvent[] = [];
  const seen = new Set<string>();
  for (const raw of log) {
    const parts = raw.split("|");
    const kind = parts[1] ?? "";
    let ident = "";
    let abilityName = "";
    if (kind === "-ability") {
      ident = parts[2] ?? "";
      abilityName = parts[3] ?? "";
    } else {
      const source = parts.find((part) => part.startsWith("[from] ability: "));
      if (!source) continue;
      ident = parts[2] ?? "";
      if (!/^p[1-4]/.test(ident)) continue;
      abilityName = source.slice("[from] ability: ".length);
    }
    const ability = Dex.abilities.get(abilityName);
    if (!ability?.id) continue;
    const key = `${sideOf(ident)}:${ability.id}`;
    if (seen.has(key)) continue;
    seen.add(key);
    events.push({
      type: "ability",
      side: sideOf(ident),
      abilityId: ability.id,
      abilityName: ability.name ?? abilityName
    });
  }
  return events;
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
  if (session.opponentPartyPokemon) {
    for (const pokemon of session.opponentPartyPokemon) {
      if (pokemon) session.hpBefore.set(`p2:${pokemon.name}`, pokemon.hp);
    }
  } else if (session.wildPokemon) {
    session.hpBefore.set(`p2:${session.wildPokemon.name}`, session.wildPokemon.hp);
  }
}

function translateLogs(session: ShowdownSession, state: BattleState): void {
  const battle = session.battle;
  const lines = battle.log.slice(session.logIndex);
  session.logIndex = battle.log.length;
  const emittedAbilities = new Set<string>();
  let activeMoveSide: BattleSide | null = null;
  const emitAbility = (side: BattleSide, abilityName: string) => {
    const ability = Dex.abilities.get(abilityName);
    if (!ability?.id) return;
    const key = `${side}:${ability.id}`;
    if (emittedAbilities.has(key)) return;
    emittedAbilities.add(key);
    addEvent(state, {
      type: "ability",
      side,
      abilityId: ability.id,
      abilityName: ability.name ?? abilityName
    });
  };
  for (const raw of lines) {
    if (raw === session.lastRawLine) continue;
    session.lastRawLine = raw;
    if (!raw.startsWith("|")) continue;
    const parts = raw.split("|");
    const kind = parts[1];
    if (!kind) continue;
    if (kind === "debug") {
      // Showdown reports damage-modifier abilities such as Overgrow as a
      // debug line; turn that into the same notification as an activation.
      const match = /^(.+?) boost$/.exec(parts[2] ?? "");
      if (match && activeMoveSide) emitAbility(activeMoveSide, match[1]);
      continue;
    }
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
      kind === "-anim"
    ) {
      continue;
    }

    const abilitySource = parts.find((part) =>
      part.startsWith("[from] ability: ")
    );
    if (kind !== "-ability" && abilitySource) {
      const ident = parts[2] ?? "";
      if (/^p[1-4]/.test(ident)) {
        emitAbility(
          sideOf(ident),
          abilitySource.slice("[from] ability: ".length)
        );
      }
    }

    if (kind === "-ability") {
      const ident = parts[2] ?? "";
      emitAbility(sideOf(ident), parts[3] ?? "");
      continue;
    }
    if (kind === "move") {
      const ident = parts[2] ?? "";
      activeMoveSide = sideOf(ident);
      const moveName = parts[3] ?? "";
      // Wild battles inject Splash as a hidden no-op; a duel may really use it.
      if (moveName === "Splash" && !session.duel) continue;
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
      addLog(
        state,
        `${state.mode === "wild" && isWild(ident) ? "Wild " : ""}${name} used ${moveName}!`
      );
      continue;
    }
    if (kind === "switch" || kind === "drag") {
      const ident = parts[2] ?? "";
      const name = cleanIdent(ident);
      addEvent(state, { type: "switch", side: sideOf(ident), name });
      if (isWild(ident) && state.mode === "trainer") {
        addLog(state, `${state.opponentName ?? "The opponent"} sent out ${name}!`);
      } else if (session.duel) addLog(state, `${name} was sent out!`);
      else if (isWild(ident)) addLog(state, `Wild ${name} appeared!`);
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

function syncPokemonToShowdown(pokemon: any, creature: CreatureState): void {
  pokemon.hp = Math.max(0, Math.min(creature.hp, pokemon.maxhp));
  pokemon.status = creature.status ?? "";
  // A Revive can bring a benched creature back mid-battle; keep Showdown's
  // fainted bookkeeping in step or it refuses the next switch.
  pokemon.fainted = pokemon.hp <= 0;
}

function syncPartyToShowdown(pokemon: any[], party: CreatureState[]): void {
  for (let index = 0; index < party.length; index++) {
    const entry = pokemon[index];
    const creature = party[index];
    if (entry && creature) syncPokemonToShowdown(entry, creature);
  }
}

function syncPokemonFromShowdown(pokemon: any, creature: CreatureState): void {
  creature.hp = Math.max(0, pokemon.hp);
  creature.maxHp = pokemon.maxhp;
  creature.status = pokemon.status || undefined;
  syncPpFromShowdown(pokemon, creature);
}

function syncPartyFromShowdown(pokemon: any[], party: CreatureState[]): void {
  for (let index = 0; index < party.length; index++) {
    const entry = pokemon[index];
    const creature = party[index];
    if (entry && creature) syncPokemonFromShowdown(entry, creature);
  }
}

function syncToShowdown(session: ShowdownSession, state: BattleState): void {
  syncPartyToShowdown(session.partyPokemon, state.party);
  if (session.opponentPartyPokemon && state.opponentParty) {
    syncPartyToShowdown(session.opponentPartyPokemon, state.opponentParty);
  } else if (session.wildPokemon) {
    syncPokemonToShowdown(session.wildPokemon, state.wild);
  }
}

function syncFromShowdown(session: ShowdownSession, state: BattleState): void {
  syncPartyFromShowdown(session.partyPokemon, state.party);
  const opponentParty = state.opponentParty;
  if (session.opponentPartyPokemon && opponentParty) {
    syncPartyFromShowdown(session.opponentPartyPokemon, opponentParty);
    const p2Active = session.battle.p2.active[0];
    const p2Index = p2Active ? session.opponentPartyPokemon.indexOf(p2Active) : -1;
    if (p2Index >= 0) {
      state.opponentActiveIndex = p2Index;
      state.opponent = opponentParty[p2Index];
      // `wild` stays the generic "other side" slot the view and journal read.
      state.wild = opponentParty[p2Index];
    }
  } else if (session.wildPokemon) {
    syncPokemonFromShowdown(session.wildPokemon, state.wild);
  }

  const active = session.battle.p1.active[0];
  const activeIndex = active ? session.partyPokemon.indexOf(active) : -1;
  if (activeIndex >= 0) {
    state.activeIndex = activeIndex;
    state.player = state.party[activeIndex];
  }

  const p1Alive = state.party.some((creature) => creature.hp > 0);
  const p2Alive = opponentParty
    ? opponentParty.some((creature) => creature.hp > 0)
    : state.wild.hp > 0;
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

function flipSide(side: BattleSide): BattleSide {
  return side === "player" ? "wild" : "player";
}

/** Rewrites a turn's events from p1's perspective to the opponent's. */
export function mirrorDuelEvents(events: BattleEvent[]): BattleEvent[] {
  return events.map((event) => {
    if (!("side" in event)) return { ...event };
    const flipped: BattleEvent = { ...event, side: flipSide(event.side) };
    if ("target" in flipped && flipped.target) {
      flipped.target = flipSide(flipped.target);
    }
    return flipped;
  });
}

function syncDuelFromShowdown(session: ShowdownSession, state: BattleState): void {
  const opponentParty = state.opponentParty;
  if (!opponentParty) throw new Error("Duel opponent party is missing");
  syncPartyFromShowdown(session.partyPokemon, state.party);
  syncPartyFromShowdown(session.opponentPartyPokemon ?? [], opponentParty);

  const p1Active = session.battle.p1.active[0];
  const p1Index = p1Active ? session.partyPokemon.indexOf(p1Active) : -1;
  if (p1Index >= 0) {
    state.activeIndex = p1Index;
    state.player = state.party[p1Index];
  }
  const p2Active = session.battle.p2.active[0];
  const p2Index = p2Active
    ? (session.opponentPartyPokemon ?? []).indexOf(p2Active)
    : -1;
  if (p2Index >= 0) {
    state.opponentActiveIndex = p2Index;
    state.opponent = opponentParty[p2Index];
    state.wild = state.opponent;
  }

  const p1Alive = state.party.some((creature) => creature.hp > 0);
  const p2Alive = opponentParty.some((creature) => creature.hp > 0);
  if (!p2Alive) {
    state.status = "won";
    addLog(state, `${state.playerName} won the duel!`);
  } else if (!p1Alive) {
    state.status = "lost";
    addLog(state, `${state.opponentName ?? "The opponent"} won the duel!`);
  } else if (session.battle.ended) {
    state.status = session.battle.winner === state.playerName ? "won" : "lost";
    addLog(state, `${session.battle.winner ?? "The winner"} won the duel!`);
  }

  if (state.status !== "active") {
    state.awaitingAction = false;
    state.awaitingOpponent = false;
    state.mustSwitch = false;
    state.mustSwitchOpponent = false;
    sessions.delete(state.id);
    return;
  }

  state.mustSwitch = session.battle.p1.requestState === "switch";
  state.awaitingAction =
    session.battle.p1.requestState === "move" ||
    session.battle.p1.requestState === "switch";
  state.mustSwitchOpponent = session.battle.p2.requestState === "switch";
  state.awaitingOpponent =
    session.battle.p2.requestState === "move" ||
    session.battle.p2.requestState === "switch";
}

function duelChoiceString(
  session: ShowdownSession,
  side: DuelSide,
  party: CreatureState[],
  activeIndex: number,
  action: BattleAction
): string {
  const battleSide = side === "p1" ? session.battle.p1 : session.battle.p2;
  const pokemonList =
    side === "p1" ? session.partyPokemon : session.opponentPartyPokemon ?? [];
  if (action.action === "move") {
    const active = party[activeIndex];
    return `move ${toShowdownId(active.moves[action.moveIndex].id)}`;
  }
  if (action.action !== "switch") {
    throw new Error("Invalid battle action");
  }
  const target = pokemonList[action.partyIndex];
  const slot = target ? battleSide.pokemon.indexOf(target) + 1 : 0;
  if (slot <= 0) throw new Error("That creature is not in the battle");
  return `switch ${slot}`;
}

/**
 * Submits one side's decision. The turn resolves only when every side that
 * currently has a Showdown request (move or forced switch) has chosen.
 */
export function submitDuelTurn(
  state: BattleState,
  side: DuelSide,
  action: BattleAction
): { resolved: boolean } {
  if (state.mode !== "duel") throw new Error("This is not a duel");
  if (state.status !== "active") throw new Error("The duel has already ended");
  const session = sessions.get(state.id);
  if (!session?.duel || !session.opponentPartyPokemon) {
    throw new Error("Battle simulator is not available");
  }
  const battleSide = side === "p1" ? session.battle.p1 : session.battle.p2;
  const awaiting = side === "p1" ? state.awaitingAction : state.awaitingOpponent;
  if (!awaiting) throw new Error("Waiting for your opponent.");
  const party = side === "p1" ? state.party : state.opponentParty;
  const activeIndex = side === "p1" ? state.activeIndex : state.opponentActiveIndex ?? 0;
  if (!party) throw new Error("Duel party is missing");
  const active = party[activeIndex];

  if (action.action === "run") {
    throw new Error("You cannot run from a trainer duel.");
  }
  if (action.action === "catch") {
    throw new Error("You cannot use Poké Balls in a trainer duel.");
  }
  if (action.action === "item") {
    throw new Error("You cannot use items in a trainer duel.");
  }
  if (action.action === "switch") {
    const index = action.partyIndex;
    if (!Number.isInteger(index) || index < 0 || index >= party.length) {
      throw new Error("Invalid party index");
    }
    if (index === activeIndex) throw new Error("That creature is already active");
    if (party[index].hp <= 0) throw new Error("That creature has fainted");
  } else if (action.action === "move") {
    if (battleSide.requestState !== "move") {
      throw new Error("Choose a replacement first");
    }
    const index = action.moveIndex;
    if (!Number.isInteger(index) || index < 0 || index >= active.moves.length) {
      throw new Error("Invalid move index");
    }
    if (movePp(active.moves[index]).current <= 0) {
      throw new Error("That move has no PP left");
    }
  } else {
    throw new Error("Invalid battle action");
  }

  const choices = state.choices;
  if (!choices) throw new Error("Duel choice state is missing");
  if (side === "p1") {
    if (choices.player) throw new Error("You already chose an action.");
    choices.player = action;
    state.awaitingAction = false;
  } else {
    if (choices.opponent) throw new Error("You already chose an action.");
    choices.opponent = action;
    state.awaitingOpponent = false;
  }

  // The previous turn's animation has already been delivered; waiting
  // snapshots must not replay it.
  state.events = [];
  state.eventsOpponent = [];

  const p1Needs =
    session.battle.p1.requestState === "move" ||
    session.battle.p1.requestState === "switch";
  const p2Needs =
    session.battle.p2.requestState === "move" ||
    session.battle.p2.requestState === "switch";
  if (p1Needs && !choices.player) return { resolved: false };
  if (p2Needs && !choices.opponent) return { resolved: false };

  const p1Choice =
    p1Needs && choices.player
      ? duelChoiceString(session, "p1", state.party, state.activeIndex, choices.player)
      : "";
  const p2Choice =
    p2Needs && choices.opponent
      ? duelChoiceString(
          session,
          "p2",
          state.opponentParty ?? [],
          state.opponentActiveIndex ?? 0,
          choices.opponent
        )
      : "";

  state.turn += 1;
  state.events = [];
  state.eventsOpponent = [];
  syncToShowdown(session, state);
  captureHpBefore(session);
  try {
    session.battle.makeChoices(p1Choice, p2Choice);
  } catch (error) {
    choices.player = null;
    choices.opponent = null;
    state.awaitingAction = p1Needs;
    state.awaitingOpponent = p2Needs;
    throw error;
  }
  translateLogs(session, state);
  state.eventsOpponent = mirrorDuelEvents(state.events);
  choices.player = null;
  choices.opponent = null;
  syncDuelFromShowdown(session, state);
  return { resolved: true };
}

/** Mirrors a duel state for the p2 client; wild states pass through unchanged. */
export function duelViewFor(state: BattleState, side: DuelSide): BattleState {
  const base: BattleState =
    state.mode !== "duel" || side === "p1"
      ? state
      : {
          ...state,
          playerName: state.opponentName ?? "Opponent",
          party: state.opponentParty ?? [],
          activeIndex: state.opponentActiveIndex ?? 0,
          player: state.opponent ?? state.wild,
          wild: state.player,
          events: state.eventsOpponent ?? [],
          awaitingAction: state.awaitingOpponent ?? false,
          mustSwitch: state.mustSwitchOpponent ?? false,
          status:
            state.status === "won"
              ? "lost"
              : state.status === "lost"
                ? "won"
                : state.status,
          opponentName: state.playerName,
          opponentParty: state.party,
          opponentActiveIndex: state.activeIndex,
          opponent: state.player,
          eventsOpponent: state.events,
          awaitingOpponent: state.awaitingAction,
          mustSwitchOpponent: state.mustSwitch,
          inventory: { items: {} }
        };
  const view = { ...base };
  // These are server bookkeeping, not client-facing battle state.
  delete view.choices;
  delete view.eventsOpponent;
  delete view.opponentParty;
  delete view.opponentActiveIndex;
  delete view.opponent;
  delete view.awaitingOpponent;
  delete view.mustSwitchOpponent;
  return view;
}

export function createDuelBattle(
  id: string,
  party: CreatureState[],
  playerName: string,
  opponentParty: CreatureState[],
  opponentName: string,
  maxParty: number
): BattleState {
  const activeIndex = party.findIndex((creature) => creature.hp > 0);
  if (activeIndex < 0) throw new Error("The player's party has no healthy creature");
  const opponentActiveIndex = opponentParty.findIndex((creature) => creature.hp > 0);
  if (opponentActiveIndex < 0) {
    throw new Error("The opponent's party has no healthy creature");
  }

  const battle = new Battle({
    formatid: "gen5customgame",
    // PvP uses a fresh seed per duel; wild battles stay deterministic.
    seed: [0, 1, 2, 3].map(() => Math.floor(Math.random() * 0x100000000))
  } as any);
  battle.setPlayer("p1", {
    name: playerName,
    team: party.map((creature) => toPokemonSet(creature, false))
  });
  battle.setPlayer("p2", {
    name: opponentName,
    team: opponentParty.map((creature) => toPokemonSet(creature, false))
  });
  const p1Order = [
    activeIndex,
    ...party.map((_, index) => index).filter((index) => index !== activeIndex)
  ];
  const p2Order = [
    opponentActiveIndex,
    ...opponentParty
      .map((_, index) => index)
      .filter((index) => index !== opponentActiveIndex)
  ];
  battle.makeChoices(
    `team ${p1Order.map((index) => index + 1).join("")}`,
    `team ${p2Order.map((index) => index + 1).join("")}`
  );

  const partyPokemon: any[] = new Array(party.length);
  for (let index = 0; index < p1Order.length; index++) {
    partyPokemon[p1Order[index]] = battle.p1.pokemon[index];
  }
  const opponentPartyPokemon: any[] = new Array(opponentParty.length);
  for (let index = 0; index < p2Order.length; index++) {
    opponentPartyPokemon[p2Order[index]] = battle.p2.pokemon[index];
  }

  for (let index = 0; index < party.length; index++) {
    const pokemon = partyPokemon[index];
    if (!pokemon) continue;
    pokemon.hp = Math.max(0, Math.min(party[index].hp, pokemon.maxhp));
    applyPersistedPp(pokemon, party[index]);
  }
  for (let index = 0; index < opponentParty.length; index++) {
    const pokemon = opponentPartyPokemon[index];
    if (!pokemon) continue;
    pokemon.hp = Math.max(0, Math.min(opponentParty[index].hp, pokemon.maxhp));
    applyPersistedPp(pokemon, opponentParty[index]);
  }

  const session: ShowdownSession = {
    battle,
    partyPokemon,
    wildPokemon: opponentPartyPokemon[opponentActiveIndex],
    opponentPartyPokemon,
    duel: true,
    logIndex: battle.log.length,
    hpBefore: new Map(),
    lastRawLine: "",
    items: {}
  };
  sessions.set(id, session);

  const player = party[activeIndex];
  const opponent = opponentParty[opponentActiveIndex];
  const initialAbilities = initialAbilityEvents(battle.log);
  return {
    id,
    mode: "duel",
    playerName,
    party,
    activeIndex,
    player,
    wild: opponent,
    opponentName,
    opponentParty,
    opponentActiveIndex,
    opponent,
    eventsOpponent: mirrorDuelEvents(initialAbilities),
    awaitingOpponent: true,
    mustSwitchOpponent: false,
    choices: { player: null, opponent: null },
    log: [
      `${playerName} and ${opponentName} started a duel!`,
      `Go, ${player.name}!`,
      `Go, ${opponent.name}!`
    ],
    events: initialAbilities,
    turn: 0,
    awaitingAction: true,
    mustSwitch: false,
    status: "active",
    inventory: { items: {} },
    maxParty
  };
}

/** The creature the AI currently controls: a wild mon or a trainer's active. */
function opponentActive(session: ShowdownSession): any {
  if (session.opponentPartyPokemon) return session.battle.p2.active[0];
  return session.wildPokemon;
}

function chooseWildMove(session: ShowdownSession): string {
  const pokemon = opponentActive(session);
  if (!pokemon) return "tackle";
  const slots = (pokemon.moveSlots ?? []) as Array<{ id: string; pp: number }>;
  const available = slots.filter((slot) => slot.pp > 0);
  const damaging = available.find((slot) => (Dex.moves.get(slot.id)?.basePower ?? 0) > 0);
  return (damaging ?? available[0] ?? slots[0])?.id ?? "struggle";
}

/**
 * Trainer parties keep battling after a faint, so Showdown asks p2 for a
 * replacement. The AI sends out its next healthy creature automatically.
 */
function pendingOpponentSwitch(session: ShowdownSession): string | null {
  const team = session.opponentPartyPokemon;
  if (!team) return null;
  // `p2.activeRequest` is the per-slot "active" fragment (it carries
  // `forceSwitch`, not `requestType`); the side's `requestState` is the
  // reliable way to ask "is p2 being made to replace its active creature?".
  if (session.battle.p2.requestState !== "switch") return null;
  const active = session.battle.p2.active[0];
  const index = team.findIndex((pokemon) => pokemon && pokemon !== active && pokemon.hp > 0);
  return index >= 0 ? `switch ${index + 1}` : null;
}

/**
 * Resolves a pending p2 replacement. When the player also has to switch, the
 * choice is left for `resolveTurn` so both sides can answer together.
 */
function autoSwitchOpponent(session: ShowdownSession): void {
  if (session.battle.p1.requestState === "switch") return;
  const choice = pendingOpponentSwitch(session);
  if (!choice) return;
  session.battle.makeChoices("", choice);
}

function runNoopTurn(session: ShowdownSession, state: BattleState): void {
  const wildMove = chooseWildMove(session);
  session.battle.makeChoices(`move ${HIDDEN_NOOP_MOVE}`, `move ${wildMove}`);
  autoSwitchOpponent(session);
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
    mode: "wild",
    playerName,
    party,
    activeIndex,
    player: party[activeIndex],
    wild,
    log: [`A wild ${wild.name} appeared!`, `Go, ${party[activeIndex].name}!`],
    events: initialAbilityEvents(battle.log),
    turn: 0,
    awaitingAction: true,
    mustSwitch: false,
    status: "active",
    inventory: structuredClone(inventory),
    maxParty
  };
}

/**
 * Scripted trainer battle: the player faces a content-defined team. The AI
 * picks moves and sends out replacements on its own; the story layer decides
 * what happens after the result.
 */
export function createTrainerBattle(
  id: string,
  party: CreatureState[],
  opponentParty: CreatureState[],
  opponentName: string,
  playerName: string,
  inventory: Inventory,
  maxParty: number,
  items: Record<string, ItemDef>,
  trainer?: { id?: string; reward?: number }
): BattleState {
  const activeIndex = party.findIndex((creature) => creature.hp > 0);
  if (activeIndex < 0) throw new Error("The party has no healthy creature");
  const opponentActiveIndex = opponentParty.findIndex((creature) => creature.hp > 0);
  if (opponentActiveIndex < 0) throw new Error("The opponent has no healthy creature");

  const battle = new Battle({ formatid: "gen5customgame", seed: [1, 2, 3, 4] } as any);
  battle.setPlayer("p1", {
    name: playerName,
    team: party.map((creature) => toPokemonSet(creature, true))
  });
  battle.setPlayer("p2", {
    name: opponentName,
    team: opponentParty.map((creature) => toPokemonSet(creature, false))
  });
  const order = [
    activeIndex,
    ...party.map((_, index) => index).filter((index) => index !== activeIndex)
  ];
  const order2 = [
    opponentActiveIndex,
    ...opponentParty
      .map((_, index) => index)
      .filter((index) => index !== opponentActiveIndex)
  ];
  battle.makeChoices(
    `team ${order.map((index) => index + 1).join("")}`,
    `team ${order2.map((index) => index + 1).join("")}`
  );

  const partyPokemon: any[] = new Array(party.length);
  for (let index = 0; index < order.length; index++) {
    partyPokemon[order[index]] = battle.p1.pokemon[index];
  }
  const opponentPartyPokemon: any[] = new Array(opponentParty.length);
  for (let index = 0; index < order2.length; index++) {
    opponentPartyPokemon[order2[index]] = battle.p2.pokemon[index];
  }

  const session: ShowdownSession = {
    battle,
    partyPokemon,
    wildPokemon: opponentPartyPokemon[opponentActiveIndex],
    opponentPartyPokemon,
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
  for (let index = 0; index < opponentParty.length; index++) {
    const pokemon = opponentPartyPokemon[index];
    if (pokemon) {
      pokemon.hp = Math.max(0, Math.min(opponentParty[index].hp, pokemon.maxhp));
      applyPersistedPp(pokemon, opponentParty[index]);
    }
  }

  const lead = opponentParty[opponentActiveIndex];
  return {
    id,
    mode: "trainer",
    playerName,
    party,
    activeIndex,
    player: party[activeIndex],
    wild: lead,
    opponentParty,
    opponentActiveIndex,
    opponent: lead,
    opponentName,
    trainerId: trainer?.id,
    reward: trainer?.reward ?? 0,
    log: [
      `${opponentName} wants to battle!`,
      `${opponentName} sent out ${lead.name}!`,
      `Go, ${party[activeIndex].name}!`
    ],
    events: initialAbilityEvents(battle.log),
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
  if (state.mode === "trainer") {
    if (action.action === "run") throw new Error("There's no running from a Trainer battle");
    if (action.action === "catch") throw new Error("You can't catch another Trainer's Pokémon");
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
      // Both sides can be asked for a replacement in the same beat.
      const opponentSwitch = pendingOpponentSwitch(session);
      if (opponentSwitch) {
        session.battle.makeChoices(`switch ${slot}`, opponentSwitch);
      } else {
        session.battle.makeChoices(`switch ${slot}`);
      }
    } else {
      const wildMove = chooseWildMove(session);
      session.battle.makeChoices(`switch ${slot}`, `move ${wildMove}`);
      autoSwitchOpponent(session);
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
  autoSwitchOpponent(session);
  translateLogs(session, state);
  syncFromShowdown(session, state);
  return state;
}
