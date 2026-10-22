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
  learnset: LearnEntry[];
  evolutions: EvolutionDef[];
}

export interface DialogueVariantDef {
  flags: Record<string, number>;
  lines: string[];
  setFlags?: number[];
}

export type ItemCategory = "ball" | "medicine" | "key";

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
}

export interface ShopDef {
  id: string;
  name: string;
  /** Item ids sold by this shop, in display order. */
  items: string[];
}

export type NpcKind = "healer" | "guide" | "npc" | "shop" | "pc";

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

export interface MapDef {
  id: string;
  name: string;
  width: number;
  height: number;
  tiles: string[];
  spawn: { x: number; y: number; dir: Dir };
  npcs: NpcDef[];
  portals: PortalDef[];
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
}
