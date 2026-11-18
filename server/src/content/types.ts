export type Dir = "up" | "down" | "left" | "right";

export type PType =
  | "Normal"
  | "Fighting"
  | "Flying"
  | "Poison"
  | "Ground"
  | "Rock"
  | "Bug"
  | "Ghost"
  | "Steel"
  | "Fire"
  | "Water"
  | "Grass"
  | "Electric"
  | "Psychic"
  | "Ice"
  | "Dragon"
  | "Dark";

export interface MoveDef {
  id: string;
  name: string;
  type: PType;
  power: number;
  accuracy: number;
  priority: number;
  pp?: number;
  category?: "status" | "physical" | "special";
  romMoveId?: number;
}

export interface LearnEntry {
  level: number;
  move: string;
}

export type EvolutionMethod =
  | "level"
  | "useItem"
  | "trade"
  | "levelFriendship"
  | "levelMove"
  | "levelHold"
  | "levelExtra";

export interface EvolutionDef {
  to: string;
  method: EvolutionMethod;
  level?: number;
  item?: string;
  move?: string;
  condition?: string;
  gender?: "male" | "female";
}

/** EVs awarded for defeating one creature of this species (Gen 5: 0-3 each). */
export interface EvYieldDef {
  hp: number;
  atk: number;
  def: number;
  spAtk: number;
  spDef: number;
  speed: number;
}

export interface SpeciesDef {
  id: string;
  name: string;
  dex: number;
  types: PType[];
  baseHp: number;
  baseAtk: number;
  baseDef: number;
  baseSpAtk: number;
  baseSpDef: number;
  baseSpeed: number;
  baseXp: number;
  catchRate: number;
  /** Effort values this species hands out when it is defeated. */
  evYield: EvYieldDef;
  learnset: LearnEntry[];
  evolutions: EvolutionDef[];
}

export interface DialogueVariantDef {
  flags: Record<string, number>;
  lines: string[];
  setFlags?: number[];
}

/**
 * Story conditions compare persisted work values (ROM event flags or authored
 * counters). A missing flag reads as 0, so `{ "prologue.pokedex": 1 }` means
 * "the Pokédex has been received".
 */
export type StoryCondition = Record<string, number>;

export type StoryStepType =
  | "say"
  | "chooseStarter"
  | "setFlag"
  | "giveStarter"
  | "givePokemon"
  | "giveItem"
  | "heal"
  | "warp"
  | "notice"
  | "battle"
  | "walk"
  | "face";

/** One button in a `chooseStarter` step; picking it grants that partner. */
export interface StoryStarterOptionDef {
  /** Stable id echoed back by the client (`snivy`, `tepig`, `oshawott`). */
  id: string;
  species: string;
  level: number;
  /** Lines shown right after the player picks this option. */
  lines?: string[];
  /**
   * Value written to the step's `flag` when this option is picked. The ROM
   * stores the pick in work 0x4030 (0 Tepig, 1 Oshawott, 2 Snivy); scenes use
   * the same numbering so a later `battle` variant can mirror it.
   */
  value?: number;
}

/**
 * A trainer battle that is part of a scene. The first variant whose `when`
 * matches the player's story flags picks the trainer, so one scene can stage
 * different opponents depending on an earlier choice.
 */
export interface StoryBattleVariantDef {
  when?: StoryCondition;
  trainer: string;
}

/** One Pokémon on a story trainer's team. */
export interface StoryTrainerCreatureDef {
  species: string;
  level: number;
}

/** A scripted opponent, addressed by id from `battle` steps. */
export interface StoryTrainerDef {
  name: string;
  sprite?: number;
  /** Team in send-out order; the first healthy creature leads. */
  party: StoryTrainerCreatureDef[];
  /** Coins awarded for winning. Story battles usually pay nothing, so 0. */
  reward?: number;
}

/** One tile of a `walk` path. */
export interface StoryWalkPointDef {
  x: number;
  y: number;
}

/**
 * Where an NPC ends up looking. `"player"` turns it toward the player's tile,
 * which is what the original does before a conversation: a turn action aimed
 * at the player object rather than a fixed direction.
 */
export type StoryFacingDef = Dir | "player";

/** One imperative beat inside a scene, executed in order by the server. */
export interface StoryStepDef {
  type: StoryStepType;
  /**
   * Skip this step unless the condition matches. This is the scene-level
   * equivalent of the ROM's conditional jump (0x1F) around a block of script,
   * and it is how a scene reacts to an earlier `battle` result.
   */
  when?: StoryCondition;
  /** `say`: speaker shown above the dialogue page. */
  speaker?: string;
  /** `say`: pages rendered by the client dialogue panel. */
  lines?: string[];
  /** `setFlag`: flag key and the value to write (default 1). */
  flag?: string;
  value?: number;
  /** `giveItem`: catalog id and stack count. */
  itemId?: string;
  count?: number;
  /** `givePokemon`: species id and level. */
  species?: string;
  level?: number;
  /** `warp`: destination tile and facing. */
  mapId?: string;
  x?: number;
  y?: number;
  dir?: Dir;
  /** `notice`: toast text. */
  text?: string;
  /** `chooseStarter`: question rendered above the three partner buttons. */
  prompt?: string[];
  /** `chooseStarter`: options the player may pick from. */
  options?: StoryStarterOptionDef[];
  /** `battle`: trainer used when no variant matches. */
  trainer?: string;
  /** `battle`: candidate trainers, first matching `when` wins. */
  variants?: StoryBattleVariantDef[];
  /** `battle`: pages played after the player wins. */
  win?: string[];
  /** `battle`: pages played after the player loses. The scene still goes on. */
  lose?: string[];
  /**
   * `walk`: NPC to move, by map NPC id (story-owned NPCs included). The
   * original game's scripts do the same with an "apply movement" sequence:
   * the NPC steps tile by tile and the script waits for it to arrive.
   */
  npcId?: string;
  /** `walk`: tiles to step through, in order; each hop must be adjacent. */
  path?: StoryWalkPointDef[];
  /** `walk`: milliseconds per tile (default 500, the client's walk speed). */
  msPerTile?: number;
  /**
   * `face`: NPC to turn, by map NPC id.
   * `walk` + `facing`: the direction to settle in after arriving. The last hop
   * already sets the facing, so this only matters when the NPC should turn at
   * the end — the original appends a turn action to the movement sequence for
   * exactly that, e.g. a rival who walks to the stairs and then turns to look
   * back before leaving.
   */
  facing?: StoryFacingDef;
  /**
   * `walk`: remove the NPC when it reaches the end of the path. This is the
   * ROM's `0x45` "end and disappear" action — the last entry in an exit
   * movement sequence, used when a character walks off (down stairs, out a
   * door) instead of staying on the map.
   */
  vanish?: boolean;
  /**
   * `battle`: flag that receives the result the way the ROM stores it in a
   * work variable — 1 for a win, 0 for a loss (work 0x8010 in the bedroom
   * scene). Later steps can branch on it with `when`.
   */
  resultFlag?: string;
}

export interface StorySceneDef {
  id: string;
  steps: StoryStepDef[];
}

/** An NPC supplied by the story layer and merged into a map at load time. */
export interface StoryNpcDef extends NpcDef {
  mapId: string;
}

/** Talk-to-NPC scene that is not attached to a story-owned NPC. */
export interface StoryInteractionDef {
  mapId: string;
  npcId: string;
  scene: string;
  when?: StoryCondition;
}

/** A tile trigger that runs a scene once the player steps onto it. */
export interface StoryTriggerDef {
  id: string;
  mapId: string;
  x: number;
  y: number;
  width: number;
  height: number;
  when?: StoryCondition;
  scene: string;
  /** Set to 1 when the scene finishes so the trigger does not repeat. */
  onceFlag?: string;
}

/**
 * A passage that stays closed until `when` matches. Movement is rejected while
 * the gate is locked; the client receives a short explanation instead.
 */
export interface StoryGateDef {
  id: string;
  mapId: string;
  x: number;
  y: number;
  width: number;
  height: number;
  when?: StoryCondition;
  speaker?: string;
  lines: string[];
}

/** Scene that starts automatically after entering a map. */
export interface StoryEnterDef {
  id: string;
  mapId: string;
  scene: string;
  when?: StoryCondition;
  onceFlag?: string;
}

export interface StoryContent {
  version: number;
  /** Map a newly created character starts on (defaults to config.startingMap). */
  startMap?: string;
  /** Flags written into every new character save. */
  initialFlags?: StoryCondition;
  scenes: Record<string, StorySceneDef>;
  /** Scripted opponents referenced by `battle` steps. */
  trainers?: Record<string, StoryTrainerDef>;
  npcs: StoryNpcDef[];
  interactions: StoryInteractionDef[];
  triggers: StoryTriggerDef[];
  gates: StoryGateDef[];
  onEnter: StoryEnterDef[];
}

export type ItemCategory = "ball" | "medicine" | "tm" | "evolution" | "key";

export interface ItemDef {
  id: string;
  name: string;
  category: ItemCategory;
  /** Buy price in coins. Selling returns half of this, rounded down. */
  price: number;
  description: string;
  /** Client icon name: assets/bw/ui/items/<icon>.png or assets/ui/icons/item_<icon>.svg. */
  icon: string;
  /** Catch-rate multiplier when this ball is thrown. */
  ballBonus?: number;
  /** HP restored by a medicine; 0/undefined when it does not heal. */
  heal?: number;
  /** Medicine cures a major status condition. */
  cureStatus?: boolean;
  /** Medicine revives a fainted creature to half of its max HP. */
  revive?: boolean;
  /** Move taught by a TM; required when category is "tm". */
  moveId?: string;
}

export interface ShopDef {
  id: string;
  name: string;
  /** Item ids sold by this shop, in display order. */
  items: string[];
}

export type NpcKind =
  | "healer"
  | "guide"
  | "npc"
  | "shop"
  | "pc"
  | "move_tutor"
  | "move_reminder"
  | "trade"
  | "friendship"
  | "ability";

export interface NpcDef {
  id: string;
  name: string;
  x: number;
  y: number;
  color: string;
  kind: NpcKind;
  sprite?: number;
  dialogue: string[];
  dialogueVariants?: DialogueVariantDef[];
  setFlags?: number[];
  /** Required for kind "shop": the shop this clerk opens. */
  shopId?: string;
  /** Required for kind "move_tutor": the moves this tutor can teach. */
  moveList?: string[];
  /** Story-owned NPCs may only exist for players at a given story point. */
  visibleWhen?: StoryCondition;
  /** Scene to run instead of the default dialogue when `sceneWhen` matches. */
  scene?: string;
  sceneWhen?: StoryCondition;
  /**
   * ROM idle movement type: 0 stands still, 1 looks around in place, busier
   * values pace in a small loop. The client only uses zero versus non-zero —
   * anything else would need the ROM's NPC behaviour state machine.
   */
  movement?: number;
}

export interface PortalDef {
  x: number;
  y: number;
  targetMap: string;
  targetX: number;
  targetY: number;
  /** Facing after the warp; the opposite of the target door's contact side. */
  targetDir?: Dir;
  /** ROM contact direction: the way the player must walk into this door. */
  entryDir?: Dir;
  /**
   * False when the portal tile was snapped to the walkable floor in front of a
   * solid door. Such a spot is not the doorway itself: the player has to stand
   * on it and press into the door instead of just stepping onto it.
   */
  onWarpTile?: boolean;
}

export interface EncounterEntry {
  species: string;
  minLevel: number;
  maxLevel: number;
  weight: number;
}

export interface EncounterDef {
  rate: number;
  table: EncounterEntry[];
}

export interface EncounterZoneDef extends EncounterDef {
  id: string;
  name: string;
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface VisualPropDef {
  x: number;
  y: number;
  z: number;
  rotation: number;
  file: string;
}

export interface VisualChunkDef {
  asset: string;
  cell?: number;
  cellX?: number;
  cellY?: number;
  offsetX: number;
  offsetZ: number;
  mapFile?: string;
  heights?: string;
  props?: VisualPropDef[];
}

export interface MapVisualDef {
  originX: number;
  originZ: number;
  tile: number;
  cellSize: number;
  heightScale?: number;
  chunks: VisualChunkDef[];
}

/** Furniture and scenery the player can examine with the interact key. */
export interface MapInteractableDef {
  id: string;
  x: number;
  y: number;
  /** ROM object script id; 0 would mean "no script" and is never written. */
  script: number;
  label: string;
  dialogue: string[];
}

export interface MapDef {
  id: string;
  name: string;
  width: number;
  height: number;
  tiles: string[];
  spawn: { x: number; y: number; dir: Dir };
  npcs: NpcDef[];
  portals: PortalDef[];
  interactables?: MapInteractableDef[];
  /** Separate map matrices that are outdoors (forests, bridges, fields). */
  outdoor?: boolean;
  encounter?: EncounterDef;
  encounterZones?: EncounterZoneDef[];
  visual?: MapVisualDef;
}

export type RawMapDef = Omit<MapDef, "width" | "height">;

export interface GameConfig {
  maxParty: number;
  maxBox: number;
  startingMap: string;
  startingMoney: number;
  startingBalls: number;
  /** Extra items added on top of startingBalls, keyed by item id. */
  startingItems?: Record<string, number>;
  winReward: number;
  catchXpFactor: number;
  xpLevelBase: number;
  xpLevelGrowth: number;
}

export interface GameContent {
  version: number;
  config: GameConfig;
  moves: Record<string, MoveDef>;
  species: Record<string, SpeciesDef>;
  items: Record<string, ItemDef>;
  shops: Record<string, ShopDef>;
  starters: string[];
  maps: Record<string, MapDef>;
  /** Optional authored story layer (scenes, triggers, gates, story NPCs). */
  story?: StoryContent;
}
