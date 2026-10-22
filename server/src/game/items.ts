import type { GameContent, ItemDef, ShopDef } from "../content/types.js";
import type { CreatureState, Inventory } from "./types.js";

export const MAX_STACK = 99;

export function emptyInventory(): Inventory {
  return { items: {} };
}

export function itemCount(inventory: Inventory, itemId: string): number {
  const count = inventory.items[itemId];
  return Number.isFinite(count) && count > 0 ? Math.floor(count) : 0;
}

export function hasItem(inventory: Inventory, itemId: string): boolean {
  return itemCount(inventory, itemId) > 0;
}

/** Adds a stack, capped at MAX_STACK. Returns how many were actually added. */
export function addItem(inventory: Inventory, itemId: string, qty: number): number {
  if (!Number.isInteger(qty) || qty <= 0) return 0;
  const current = itemCount(inventory, itemId);
  const next = Math.min(MAX_STACK, current + qty);
  inventory.items[itemId] = next;
  return next - current;
}

/** Removes up to `qty` of an item. Returns how many were removed. */
export function removeItem(inventory: Inventory, itemId: string, qty: number): number {
  if (!Number.isInteger(qty) || qty <= 0) return 0;
  const current = itemCount(inventory, itemId);
  const removed = Math.min(current, qty);
  if (removed <= 0) return 0;
  if (current - removed <= 0) delete inventory.items[itemId];
  else inventory.items[itemId] = current - removed;
  return removed;
}

export function sellPrice(item: ItemDef): number {
  return Math.max(1, Math.floor(item.price / 2));
}

export function buyTotal(item: ItemDef, qty: number): number {
  return item.price * qty;
}

export function buildStartingInventory(content: GameContent): Inventory {
  const inventory = emptyInventory();
  const config = content.config;
  if (config.startingBalls > 0) {
    addItem(inventory, "poke_ball", config.startingBalls);
  }
  for (const [itemId, count] of Object.entries(config.startingItems ?? {})) {
    addItem(inventory, itemId, count);
  }
  return inventory;
}

export interface MedicineResult {
  ok: boolean;
  error?: string;
  /** Log line for the battle log or notice. */
  message?: string;
  healed?: number;
  curedStatus?: boolean;
  revived?: boolean;
}

/**
 * Applies a medicine to one creature. Does not consume the item; callers
 * remove it from the inventory only after this succeeds.
 */
export function applyMedicine(item: ItemDef, creature: CreatureState): MedicineResult {
  if (item.category !== "medicine") {
    return { ok: false, error: `${item.name} is not a medicine.` };
  }
  if (item.revive) {
    if (creature.hp > 0) {
      return { ok: false, error: `${creature.name} has not fainted.` };
    }
    const healed = Math.max(1, Math.floor(creature.maxHp / 2));
    creature.hp = Math.min(creature.maxHp, healed);
    creature.status = undefined;
    return {
      ok: true,
      message: `${creature.name} was revived!`,
      healed: creature.hp,
      revived: true
    };
  }
  if (creature.hp <= 0) {
    return { ok: false, error: `${creature.name} has fainted. Use a Revive first.` };
  }

  const heal = item.heal ?? 0;
  if (heal > 0 && creature.hp >= creature.maxHp) {
    return { ok: false, error: `${creature.name} is already at full HP.` };
  }
  let curedStatus = false;
  let healed = 0;
  if (heal > 0) {
    const before = creature.hp;
    creature.hp = Math.min(creature.maxHp, creature.hp + heal);
    healed = creature.hp - before;
  }
  if (item.cureStatus && creature.status) {
    creature.status = undefined;
    curedStatus = true;
  }
  if (item.cureStatus && !curedStatus && healed <= 0) {
    return { ok: false, error: `${creature.name} has no status condition.` };
  }
  const parts: string[] = [];
  if (healed > 0) parts.push(`recovered ${healed} HP`);
  if (curedStatus) parts.push("was cured of its status");
  if (parts.length === 0) {
    return { ok: false, error: `It had no effect on ${creature.name}.` };
  }
  return {
    ok: true,
    message: `${creature.name} ${parts.join(" and ")}!`,
    healed,
    curedStatus
  };
}

export function shopItemsForClient(
  shop: ShopDef,
  content: GameContent,
  inventory: Inventory
) {
  return shop.items
    .map((itemId) => content.items[itemId])
    .filter((item): item is ItemDef => Boolean(item))
    .map((item) => ({
      id: item.id,
      name: item.name,
      category: item.category,
      price: item.price,
      sellPrice: sellPrice(item),
      description: item.description,
      icon: item.icon,
      owned: itemCount(inventory, item.id)
    }));
}
