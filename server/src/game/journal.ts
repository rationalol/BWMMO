/**
 * Structured adventure-log entries. The server localizes content names (the
 * client does not ship the full species/move tables) and the client renders
 * the sentence itself from its UI locale, so a journal line can be re-rendered
 * after a language switch.
 */
export type JournalKind =
  | "encounter"
  | "move"
  | "faint"
  | "switch"
  | "ball"
  | "broke_free"
  | "catch"
  | "defeat"
  | "blackout"
  | "flee"
  | "escape_failed"
  | "level_up"
  | "evolution"
  | "learn_move"
  | "forget_move"
  | "heal"
  | "item_used"
  | "shop_buy"
  | "shop_sell"
  | "pc_deposit"
  | "pc_withdraw"
  | "pc_swap"
  | "rename"
  | "release";

export interface JournalEntry {
  kind: JournalKind;
  /** Trainer or creature that performed the action. */
  actor?: string;
  /** Creature/item/person the action was aimed at. */
  target?: string;
  move?: string;
  item?: string;
  level?: number;
  count?: number;
  money?: number;
  /** True when `target` is a wild creature. */
  wild?: boolean;
}
