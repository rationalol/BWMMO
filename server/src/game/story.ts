import type {
  Dir,
  MapDef,
  NpcDef,
  StoryCondition,
  StoryFacingDef,
  StoryGateDef,
  StoryStepDef,
  StoryContent
} from "../content/types.js";
import { isWalkable } from "./maps.js";
import { createCreature, healParty } from "./creatures.js";
import { renderDialogueLine } from "./dialogue.js";
import { addItem } from "./items.js";
import { markSpeciesCaught } from "./pokedex.js";
import {
  asInt,
  asString,
  type Dict,
  type PlayerSession,
  type StorySessionState
} from "./protocol.js";
import type { GameHost } from "./runtime.js";

/** Repeating a locked gate message this often is enough to feel responsive. */
const GATE_COOLDOWN_MS = 2_500;

/**
 * One tile of a cutscene walk. Matches the client's WALK_SPEED (32 world units
 * per second on 16-unit tiles) so the scene resumes right as the NPC arrives.
 */
const WALK_MS_PER_TILE = 500;

/** Dominant-axis direction between two tiles; the caller guarantees they differ. */
function directionBetween(from: { x: number; y: number }, to: { x: number; y: number }): Dir {
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  if (dx === 0 && dy === 0) return "down";
  if (Math.abs(dx) >= Math.abs(dy)) return dx > 0 ? "right" : "left";
  return dy > 0 ? "down" : "up";
}

/**
 * Authored story layer: scenes, NPC/tile triggers, locked passages and the
 * starter grant. A scene is a list of imperative steps; `say` and
 * `chooseStarter` pause until the client answers, everything else runs at once.
 */
export class StoryController {
  constructor(private readonly host: GameHost) {}

  get content(): StoryContent | null {
    return this.host.content.story ?? null;
  }

  /** True when every key in `condition` equals the player's stored value. */
  matches(
    condition: StoryCondition | undefined,
    flags: Record<string, number> | undefined
  ): boolean {
    if (!condition) return true;
    const values = flags ?? {};
    return Object.entries(condition).every(([flag, value]) => (values[flag] ?? 0) === value);
  }

  npcVisible(npc: NpcDef, flags: Record<string, number> | undefined): boolean {
    return this.matches(npc.visibleWhen, flags);
  }

  /** NPC collision is per player: a story NPC hidden from you must not block you. */
  blocksAt(
    map: MapDef,
    x: number,
    y: number,
    flags: Record<string, number> | undefined
  ): boolean {
    return map.npcs.some((npc) => this.npcVisible(npc, flags) && npc.x === x && npc.y === y);
  }

  isBusy(player: PlayerSession): boolean {
    return player.story !== null;
  }

  /** Start the scene attached to entering a map (login or teleport). */
  onEnter(player: PlayerSession): void {
    const story = this.content;
    if (!story || player.story) return;
    const flags = player.character.storyFlags;
    for (const enter of story.onEnter) {
      if (enter.mapId !== player.character.mapId) continue;
      if (!this.matches(enter.when, flags)) continue;
      if (enter.onceFlag && (flags?.[enter.onceFlag] ?? 0) === 1) continue;
      if (enter.onceFlag) this.setFlag(player, enter.onceFlag, 1);
      this.startScene(player, enter.scene);
      return;
    }
  }

  /** Run a tile trigger after a move; returns true when a scene started. */
  onStep(player: PlayerSession, mapId: string, x: number, y: number): void {
    const story = this.content;
    if (!story || player.story) return;
    const flags = player.character.storyFlags;
    for (const trigger of story.triggers) {
      if (trigger.mapId !== mapId) continue;
      if (
        x < trigger.x ||
        y < trigger.y ||
        x >= trigger.x + trigger.width ||
        y >= trigger.y + trigger.height
      ) {
        continue;
      }
      if (!this.matches(trigger.when, flags)) continue;
      if (trigger.onceFlag && (flags?.[trigger.onceFlag] ?? 0) === 1) continue;
      if (trigger.onceFlag) this.setFlag(player, trigger.onceFlag, 1);
      this.startScene(player, trigger.scene);
      return;
    }
  }

  /**
   * Talk-to-NPC scene hook. Returns true when the interaction was consumed by
   * the story layer, so the caller must skip the ordinary NPC dialogue.
   */
  interact(player: PlayerSession, npc: NpcDef): boolean {
    const story = this.content;
    if (!story) return false;
    if (player.story) return true;
    const flags = player.character.storyFlags;
    let sceneId: string | null = null;
    if (npc.scene && this.matches(npc.sceneWhen, flags)) {
      sceneId = npc.scene;
    } else {
      const interaction = story.interactions.find(
        (entry) =>
          entry.mapId === player.character.mapId &&
          entry.npcId === npc.id &&
          this.matches(entry.when, flags)
      );
      sceneId = interaction?.scene ?? null;
    }
    if (!sceneId) return false;
    return this.startScene(player, sceneId);
  }

  /** The first locked gate covering this tile, or null when the way is open. */
  gateAt(player: PlayerSession, mapId: string, x: number, y: number): StoryGateDef | null {
    const story = this.content;
    if (!story) return null;
    const flags = player.character.storyFlags;
    for (const gate of story.gates) {
      if (gate.mapId !== mapId) continue;
      if (
        x < gate.x ||
        y < gate.y ||
        x >= gate.x + gate.width ||
        y >= gate.y + gate.height
      ) {
        continue;
      }
      if (this.matches(gate.when, flags)) return gate;
    }
    return null;
  }

  /** Explain a locked passage (rate-limited so holding a direction is quiet). */
  showGate(player: PlayerSession, gate: StoryGateDef): void {
    const now = Date.now();
    if (now - (player.lastStoryGateAt ?? 0) < GATE_COOLDOWN_MS) return;
    player.lastStoryGateAt = now;
    this.host.send(player.conn, {
      type: "dialogue",
      npcId: `gate:${gate.id}`,
      npcName: this.host.i18n.npcName(
        player.conn.locale,
        gate.speaker ?? ""
      ),
      kind: "gate",
      lines: this.host.i18n
        .dialogue(player.conn.locale, gate.lines)
        .map((line) =>
          renderDialogueLine(line, player.character.name, player.conn.locale)
        )
    });
  }

  startScene(player: PlayerSession, sceneId: string): boolean {
    const story = this.content;
    if (!story || player.story) return false;
    const scene = story.scenes[sceneId];
    if (!scene) return false;
    const state: StorySessionState = {
      sceneId,
      index: 0,
      awaiting: "advance",
      steps: [...scene.steps],
      startedAt: Date.now(),
      npcTiles: {}
    };
    player.story = state;
    this.host.send(player.conn, { type: "story_begin", sceneId });
    this.run(player);
    return true;
  }

  /** Client closed a story dialogue page. */
  advance(player: PlayerSession, msg: Dict): void {
    const state = player.story;
    if (!state || state.awaiting !== "advance") return;
    const sceneId = asString(msg.sceneId);
    if (sceneId && sceneId !== state.sceneId) return;
    // `step` rejects stale acknowledgements (for example one queued before a
    // scene warp) so they cannot skip a page.
    const step = asInt(msg.step);
    if (step !== null && step !== state.index) return;
    state.index += 1;
    this.run(player);
  }

  /** Client picked a starter. */
  choose(player: PlayerSession, msg: Dict): void {
    const state = player.story;
    if (!state || state.awaiting !== "choice") return;
    const sceneId = asString(msg.sceneId);
    if (sceneId && sceneId !== state.sceneId) return;
    const stepIndex = asInt(msg.step);
    if (stepIndex !== null && stepIndex !== state.index) return;
    const step = state.steps[state.index];
    if (!step || step.type !== "chooseStarter") return;
    const optionId = asString(msg.optionId) ?? "";
    const option = (step.options ?? []).find((entry) => entry.id === optionId);
    if (!option) {
      this.host.sendError(player.conn, "That partner is not available.");
      return;
    }
    this.grantPokemon(player, option.species, option.level);
    // Remember which partner was picked (ROM work 0x4030) so later steps such
    // as a `battle` variant can react to the choice.
    if (step.flag && option.value !== undefined) {
      this.setFlag(player, step.flag, option.value);
    }
    state.index += 1;
    // Apply the scene's follow-up bookkeeping (setFlag, giveItem, ...) before
    // the reaction page. A player who disconnects mid-page would otherwise have
    // a partner but no `starterChosen` flag, and the intro would hand out a
    // second partner on the next login.
    while (state.index < state.steps.length) {
      const next = state.steps[state.index];
      if (!this.stepActive(player, next)) {
        state.index += 1;
        continue;
      }
      if (next.type === "say" || next.type === "chooseStarter") break;
      this.executeStep(player, state, next);
      state.index += 1;
    }
    if (option.lines && option.lines.length > 0) {
      // Play the reaction as an ordinary page before the rest of the scene.
      state.steps.splice(state.index, 0, {
        type: "say",
        speaker: "",
        lines: option.lines
      });
    }
    this.run(player);
  }

  /** False when a step's `when` guard skips it (ROM conditional jump). */
  private stepActive(player: PlayerSession, step: StoryStepDef): boolean {
    return this.matches(step.when, player.character.storyFlags);
  }

  /**
   * Pick the trainer for a `battle` step. Variants mirror the ROM's branch on
   * a work value (for example the chosen starter in 0x4030); the first match
   * wins and `step.trainer` is the fallback.
   */
  private resolveTrainerId(step: StoryStepDef, player: PlayerSession): string {
    const flags = player.character.storyFlags ?? {};
    for (const variant of step.variants ?? []) {
      if (this.matches(variant.when, flags)) return variant.trainer;
    }
    return step.trainer ?? "";
  }

  /**
   * The client closed the battle result box. Play the win/lose pages the
   * `battle` step queued, then continue the scene. Called for every battle, so
   * ordinary wild battles are ignored here.
   */
  onBattleClosed(player: PlayerSession): void {
    const pending = player.pendingStoryBattle;
    if (!pending) return;
    player.pendingStoryBattle = null;
    const state = player.story;
    if (!state || state.awaiting !== "battle" || !state.pendingBattle) return;
    if (state.pendingBattle.trainerId !== pending.trainerId) return;
    const branch =
      pending.result === "won" ? state.pendingBattle.win : state.pendingBattle.lose;
    const speaker = state.pendingBattle.speaker;
    const resultFlag = state.pendingBattle.resultFlag;
    state.pendingBattle = undefined;
    state.awaiting = "advance";
    state.index += 1;
    // Store the result before the branch pages run: later steps use `when` on
    // this flag to pick their own lines, exactly like the ROM's 0x8010.
    if (resultFlag) this.setFlag(player, resultFlag, pending.result === "won" ? 1 : 0);
    if (branch.length > 0) {
      state.steps.splice(state.index, 0, { type: "say", speaker, lines: branch });
    }
    this.run(player);
  }

  private run(player: PlayerSession): void {
    const state = player.story;
    if (!state) return;
    while (state.index < state.steps.length) {
      const step = state.steps[state.index];
      if (!this.stepActive(player, step)) {
        state.index += 1;
        continue;
      }
      const waiting = this.executeStep(player, state, step);
      if (waiting) return;
      state.index += 1;
    }
    this.finish(player);
  }

  /** Returns true when the step is waiting for a client message. */
  private executeStep(
    player: PlayerSession,
    state: StorySessionState,
    step: StoryStepDef
  ): boolean {
    const name = player.character.name;
    switch (step.type) {
      case "say": {
        this.host.send(player.conn, {
          type: "dialogue",
          npcId: `story:${state.sceneId}`,
          npcName: this.host.i18n.npcName(
            player.conn.locale,
            step.speaker ?? ""
          ),
          kind: "story",
          sceneId: state.sceneId,
          step: state.index,
          lines: this.host.i18n
            .dialogue(player.conn.locale, step.lines ?? [])
            .map((line) => renderDialogueLine(line, name, player.conn.locale))
        });
        state.awaiting = "advance";
        return true;
      }
      case "chooseStarter": {
        const options = (step.options ?? []).map((option) => {
          const species = this.host.content.species[option.species];
          return {
            id: option.id,
            name: this.host.i18n.speciesName(player.conn.locale, option.species),
            types: species?.types ?? [],
            level: option.level
          };
        });
        this.host.send(player.conn, {
          type: "story_choice",
          kind: "starter",
          sceneId: state.sceneId,
          step: state.index,
          prompt: this.host.i18n
            .dialogue(player.conn.locale, step.prompt ?? [])
            .map((line) => renderDialogueLine(line, name, player.conn.locale)),
          options
        });
        state.awaiting = "choice";
        return true;
      }
      case "setFlag": {
        if (step.flag) this.setFlag(player, step.flag, step.value ?? 1);
        return false;
      }
      case "giveStarter":
      case "givePokemon": {
        const species = step.species ?? "";
        if (species) this.grantPokemon(player, species, step.level ?? 5);
        return false;
      }
      case "giveItem": {
        const itemId = step.itemId ?? "";
        const count = step.count ?? 1;
        if (itemId) {
          const added = addItem(player.character.inventory, itemId, count);
          const itemName = this.host.i18n.itemName(player.conn.locale, itemId);
          this.host.store.saveCharacter(player.accountId, player.character);
          this.host.sendPartyState(player);
          this.host.send(player.conn, {
            type: "notice",
            text:
              added > 0
                ? `You received ${itemName} x${added}.`
                : `Your bag is full. ${itemName} was left behind.`
          });
        }
        return false;
      }
      case "heal": {
        healParty(player.character.party);
        healParty(player.character.box);
        this.host.store.saveCharacter(player.accountId, player.character);
        this.host.sendPartyState(player);
        return false;
      }
      case "warp": {
        const mapId = step.mapId ?? "";
        const map = this.host.content.maps[mapId];
        if (map) {
          const character = player.character;
          this.host.visibility.clear(player);
          character.mapId = map.id;
          character.x = step.x ?? map.spawn.x;
          character.y = step.y ?? map.spawn.y;
          character.dir = step.dir ?? map.spawn.dir;
          player.portalLock = { mapId: map.id, x: character.x, y: character.y };
          this.host.store.saveCharacter(player.accountId, character);
          this.host.afterTeleport(player);
        }
        return false;
      }
      case "notice": {
        this.host.send(player.conn, {
          type: "notice",
          text: renderDialogueLine(step.text ?? "", name)
        });
        return false;
      }
      case "walk": {
        const wait = this.startNpcWalk(player, step);
        if (wait <= 0) return false;
        state.awaiting = "timer";
        setTimeout(() => {
          // Logging out, warping or a new scene leaves a stale timer behind;
          // only resume the scene that requested the walk.
          if (player.story !== state || state.awaiting !== "timer") return;
          state.index += 1;
          this.run(player);
        }, wait);
        return true;
      }
      case "face": {
        // A turn action finishes immediately; there is nothing to wait for.
        this.turnNpc(player, step);
        return false;
      }
      case "battle": {
        const trainerId = this.resolveTrainerId(step, player);
        const trainer = trainerId ? this.content?.trainers?.[trainerId] : undefined;
        if (!trainerId || !trainer) {
          this.host.sendError(player.conn, "That battle is not available.");
          return false;
        }
        state.pendingBattle = {
          trainerId,
          speaker: step.speaker ?? trainer.name,
          win: [...(step.win ?? [])],
          lose: [...(step.lose ?? [])],
          resultFlag: step.resultFlag
        };
        state.awaiting = "battle";
        this.host.startTrainerBattle(player, trainerId, trainer);
        return true;
      }
      default:
        return false;
    }
  }

  /** Tile an NPC stands on: the scene's walked position, else its authored one. */
  private npcTile(player: PlayerSession, npc: NpcDef): { x: number; y: number } {
    const walked = player.story?.npcTiles?.[npc.id];
    return walked ? { x: walked.x, y: walked.y } : { x: npc.x, y: npc.y };
  }

  /** Resolve a `facing` value against the player's live tile. */
  private resolveFacing(
    player: PlayerSession,
    facing: StoryFacingDef,
    from: { x: number; y: number }
  ): Dir | null {
    if (facing !== "player") return facing;
    const target = { x: player.character.x, y: player.character.y };
    if (target.x === from.x && target.y === from.y) return null;
    return directionBetween(from, target);
  }

  /**
   * Turn an NPC in place. The ROM encodes this as a one-action movement
   * sequence (0x20-0x23 — up/down/left/right turn) applied to the object, so a
   * script can make an NPC look at the player before speaking without moving
   * it. Facing the player is the one case a fixed action cannot express, so
   * the direction is computed from the two live tiles.
   */
  private turnNpc(player: PlayerSession, step: StoryStepDef): void {
    const map = this.host.map(player.character.mapId);
    const npcId = step.npcId ?? "";
    const npc = map.npcs.find((entry) => entry.id === npcId);
    if (!npc) {
      console.error(`story: face step targets unknown NPC '${npcId}' on ${map.id}`);
      return;
    }
    if (!this.npcVisible(npc, player.character.storyFlags)) return;
    const dir = this.resolveFacing(player, step.facing ?? "down", this.npcTile(player, npc));
    if (!dir) return;
    this.host.send(player.conn, { type: "npc_face", npcId, dir });
  }

  /**
   * Start a cutscene walk and report how long the scene should wait for it.
   * The original game applies a movement sequence to the object and only
   * resumes the script once the object arrives, so the wait mirrors the path.
   * Returns 0 when the step cannot play (missing or hidden NPC, blocked tile),
   * which makes the scene continue instead of stalling on an unseen sprite.
   */
  private startNpcWalk(player: PlayerSession, step: StoryStepDef): number {
    const map = this.host.map(player.character.mapId);
    const npcId = step.npcId ?? "";
    const npc = map.npcs.find((entry) => entry.id === npcId);
    if (!npc || !this.npcVisible(npc, player.character.storyFlags)) return 0;
    const points = step.path ?? [];
    if (points.length === 0) return 0;
    // Start from wherever the scene has already walked this NPC, not from its
    // authored tile: the original asks the object where it is, so a second
    // movement sequence continues from the first one's end.
    let previous = this.npcTile(player, npc);
    for (const point of points) {
      const hop = Math.abs(point.x - previous.x) + Math.abs(point.y - previous.y);
      if (hop !== 1) {
        console.error(
          `story: ${npcId} walk is not one tile per hop on ${map.id}: ` +
            `(${previous.x},${previous.y}) -> (${point.x},${point.y})`
        );
        return 0;
      }
      if (!isWalkable(map, point.x, point.y)) {
        console.error(
          `story: ${npcId} cannot walk to (${point.x},${point.y}) on ${map.id}; ` +
            `that tile is blocked in the map data`
        );
        return 0;
      }
      previous = point;
    }
    const msPerTile = step.msPerTile ?? WALK_MS_PER_TILE;
    const path = points.map((point, index) => {
      const from = index === 0 ? this.npcTile(player, npc) : points[index - 1];
      return { x: point.x, y: point.y, dir: directionBetween(from, point) };
    });
    const end = points[points.length - 1];
    const state = player.story;
    if (state) {
      if (!state.npcTiles) state.npcTiles = {};
      state.npcTiles[npcId] = { x: end.x, y: end.y };
    }
    const message: Dict = { type: "npc_move", npcId, path, msPerTile };
    const face = step.facing ? this.resolveFacing(player, step.facing, end) : null;
    if (face) message.face = face;
    // The ROM's movement sequences end with 0x45 "disappear" when the character
    // leaves the map rather than staying where it stopped.
    if (step.vanish) message.vanish = true;
    this.host.send(player.conn, message);
    return path.length * msPerTile + 120;
  }

  private setFlag(player: PlayerSession, flag: string, value: number): void {
    const character = player.character;
    character.storyFlags ??= {};
    character.storyFlags[flag] = value;
    this.host.store.saveCharacter(player.accountId, character);
  }

  private grantPokemon(player: PlayerSession, speciesId: string, level: number): void {
    const content = this.host.content;
    if (!content.species[speciesId]) return;
    const creature = createCreature(content, speciesId, level);
    const character = player.character;
    if (character.party.length < content.config.maxParty) {
      character.party.push(creature);
    } else {
      character.box.push(creature);
    }
    markSpeciesCaught(content, character, speciesId);
    this.host.store.saveCharacter(player.accountId, character);
    this.host.sendPartyState(player);
    this.host.sendPokedexState(player, false);
    this.host.sendJournal(player, {
      kind: "catch",
      actor: character.name,
      target: this.host.i18n.speciesName(player.conn.locale, speciesId),
      wild: false
    });
  }

  private finish(player: PlayerSession): void {
    const state = player.story;
    player.story = null;
    if (!state) return;
    this.host.send(player.conn, { type: "story_end", sceneId: state.sceneId });
    // Visibility may have changed (story NPCs appearing or leaving).
    this.host.sendMapState(player);
  }
}
