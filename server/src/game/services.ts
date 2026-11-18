import { abilityOptionsForSpecies } from "./abilities.js";
import { evolveCreature, healParty, type EvolutionResult } from "./creatures.js";
import { renderDialogueLine, selectDialogue } from "./dialogue.js";
import {
  MAX_STACK,
  addItem,
  applyMedicine,
  buyTotal,
  itemCount,
  removeItem,
  sellPrice,
  shopItemsForClient
} from "./items.js";
import {
  canRememberMove,
  itemEvolutionFor,
  maxFriendship,
  queueMoveLearn,
  relearnableMoves,
  releaseFromBox,
  renameCreature,
  tradeEvolutionFor,
  tutorKnowsMove
} from "./growth.js";
import { findNpc } from "./maps.js";
import { markSpeciesCaught } from "./pokedex.js";
import { depositToBox, swapPartyWithBox, withdrawFromBox } from "./pc.js";
import { asInt, asString, type Dict, type PlayerSession } from "./protocol.js";
import type { GameHost } from "./runtime.js";
import type { ItemDef, MapDef, MoveDef } from "../content/types.js";

/** NPC dialogue, healing, shops, medicine and the PC. */
export class ServiceController {
  constructor(private readonly host: GameHost) {}

  handleInteract(conn: PlayerSession["conn"], msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    if (player.battleId) {
      this.host.sendError(conn, "Finish the battle first.");
      return;
    }
    const map = this.host.map(player.character.mapId);
    const npcId = asString(msg.npcId) ?? "";
    if (!npcId) {
      this.examineObject(player, map, msg);
      return;
    }
    const npc = findNpc(map, npcId);
    if (!npc || !this.host.story.npcVisible(npc, player.character.storyFlags)) {
      this.host.sendError(conn, "That person is not here.");
      return;
    }
    const distance =
      Math.abs(npc.x - player.character.x) + Math.abs(npc.y - player.character.y);
    if (distance > 2) {
      this.host.sendError(conn, "There is nobody close enough to talk to.");
      return;
    }

    // Story scenes replace the ordinary dialogue/heal/shop handling entirely.
    if (this.host.story.interact(player, npc)) return;

    const selection = selectDialogue(npc, player.character.storyFlags);
    this.host.send(conn, {
      type: "dialogue",
      npcId: npc.id,
      npcName: this.host.i18n.npcName(conn.locale, npc.name),
      kind: npc.kind,
      lines: this.host.i18n
        .dialogue(conn.locale, selection.lines)
        .map((line) =>
          renderDialogueLine(line, player.character.name, conn.locale)
        )
    });

    if (selection.setFlags.length > 0) {
      player.character.storyFlags ??= {};
      for (const flag of selection.setFlags) {
        player.character.storyFlags[String(flag)] = 1;
      }
      this.host.store.saveCharacter(player.accountId, player.character);
    }

    if (npc.kind === "move_tutor" || npc.kind === "move_reminder") {
      this.sendMoveService(player, npc);
      return;
    }

    if (npc.kind === "trade") {
      this.sendTradeService(player, npc);
      return;
    }

    if (npc.kind === "ability") {
      this.sendAbilityService(player, npc);
      return;
    }

    if (npc.kind === "friendship") {
      maxFriendship(player.character.party);
      this.host.store.saveCharacter(player.accountId, player.character);
      this.host.sendPartyState(player);
      this.host.send(conn, {
        type: "notice",
        text: "Every Pokémon in your party is now fully bonded with you!"
      });
      return;
    }

    if (npc.kind === "healer") {
      healParty(player.character.party);
      healParty(player.character.box);
      this.host.store.saveCharacter(player.accountId, player.character);
      this.host.sendPartyState(player);
      this.host.send(conn, {
        type: "notice",
        text: "Your team was healed, cured, and had its PP restored."
      });
      this.host.sendJournal(player, { kind: "heal", actor: player.character.name });
      return;
    }

    if (npc.kind === "shop" && npc.shopId) {
      const shop = this.host.content.shops[npc.shopId];
      if (shop) this.sendShopState(player, shop.id);
      return;
    }

    if (npc.kind === "pc") {
      this.sendPcState(player);
    }
  }

  /**
   * Furniture and scenery: the client sends the tile it is facing (or the tile
   * it stands on), and the map answers with the ROM object script's text when
   * we could decode it, else with the label's generic line.
   */
  private examineObject(
    player: PlayerSession,
    map: MapDef,
    msg: Dict
  ): void {
    const conn = player.conn;
    const x = asInt(msg.objectX);
    const y = asInt(msg.objectY);
    const target =
      x === null || y === null
        ? undefined
        : map.interactables?.find((obj) => obj.x === x && obj.y === y);
    if (!target) {
      this.host.sendError(conn, "There is nothing to examine there.");
      return;
    }
    const distance =
      Math.abs(target.x - player.character.x) +
      Math.abs(target.y - player.character.y);
    if (distance > 1) {
      this.host.sendError(conn, "There is nothing close enough to examine.");
      return;
    }
    this.host.send(conn, {
      type: "dialogue",
      npcId: target.id,
      npcName: this.host.i18n.npcName(conn.locale, target.label),
      kind: "object",
      lines: this.host.i18n
        .dialogue(conn.locale, target.dialogue)
        .map((line) =>
          renderDialogueLine(line, player.character.name, conn.locale)
        )
    });
  }

  handleUseItem(conn: PlayerSession["conn"], msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    if (player.battleId) {
      this.host.sendError(conn, "Use items from the battle menu.");
      return;
    }
    const itemId = asString(msg.itemId) ?? "";
    const item = this.host.content.items[itemId];
    if (!item) {
      this.host.sendError(conn, "That item does not exist.");
      return;
    }
    const partyIndex = asInt(msg.partyIndex);
    if (partyIndex === null || partyIndex < 0 || partyIndex >= player.character.party.length) {
      this.host.sendError(conn, "Choose a party member first.");
      return;
    }
    if (itemCount(player.character.inventory, itemId) <= 0) {
      this.host.sendError(conn, `You have no ${item.name} left.`);
      return;
    }
    const target = player.character.party[partyIndex];

    if (item.category === "tm") {
      this.useTm(player, item, target);
      return;
    }
    if (item.category === "evolution") {
      this.useEvolutionItem(player, item, target);
      return;
    }
    if (item.category !== "medicine") {
      this.host.sendError(conn, "That item cannot be used here.");
      return;
    }

    const result = applyMedicine(item, target);
    if (!result.ok) {
      this.host.sendError(conn, result.error ?? "That item had no effect.");
      return;
    }
    removeItem(player.character.inventory, itemId, 1);
    this.host.store.saveCharacter(player.accountId, player.character);
    this.host.sendPartyState(player);
    this.host.send(conn, {
      type: "notice",
      text: result.message ?? `Used ${item.name}.`
    });
    this.host.sendJournal(player, {
      kind: "item_used",
      actor: player.character.name,
      item: this.host.i18n.itemName(conn.locale, itemId),
      target: this.host.i18n.creature(conn.locale, target).name
    });
  }

  handleShopBuy(conn: PlayerSession["conn"], msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    if (player.battleId) {
      this.host.sendError(conn, "Finish the battle first.");
      return;
    }
    const shopId = asString(msg.shopId) ?? "";
    const shop = this.host.content.shops[shopId];
    if (!shop) {
      this.host.sendError(conn, "That shop is not open.");
      return;
    }
    if (!this.serviceNpcNearby(player, (npc) => npc.kind === "shop" && npc.shopId === shopId)) {
      this.host.sendError(conn, "You are not at that shop counter.");
      return;
    }
    const itemId = asString(msg.itemId) ?? "";
    if (!shop.items.includes(itemId)) {
      this.host.sendError(conn, "That item is not sold here.");
      return;
    }
    const item = this.host.content.items[itemId];
    if (!item) {
      this.host.sendError(conn, "That item does not exist.");
      return;
    }
    const qty = asInt(msg.qty) ?? 1;
    if (qty < 1 || qty > MAX_STACK) {
      this.host.sendError(conn, "Choose a quantity between 1 and 99.");
      return;
    }
    const owned = itemCount(player.character.inventory, itemId);
    if (owned + qty > MAX_STACK) {
      this.host.sendError(conn, `You cannot carry more than ${MAX_STACK} ${item.name}.`);
      return;
    }
    const cost = buyTotal(item, qty);
    if (player.character.money < cost) {
      this.host.sendError(conn, "You do not have enough money.");
      return;
    }
    player.character.money -= cost;
    addItem(player.character.inventory, itemId, qty);
    this.host.store.saveCharacter(player.accountId, player.character);
    this.sendShopState(player, shopId);
    this.host.sendPartyState(player);
    this.host.send(conn, {
      type: "notice",
      text: `Bought ${qty}x ${item.name} for ${cost} coins.`
    });
    this.host.sendJournal(player, {
      kind: "shop_buy",
      actor: player.character.name,
      item: this.host.i18n.itemName(conn.locale, itemId),
      count: qty,
      money: cost
    });
  }

  handleShopSell(conn: PlayerSession["conn"], msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    if (player.battleId) {
      this.host.sendError(conn, "Finish the battle first.");
      return;
    }
    const shopId = asString(msg.shopId) ?? "";
    if (!this.serviceNpcNearby(player, (npc) => npc.kind === "shop" && npc.shopId === shopId)) {
      this.host.sendError(conn, "You are not at that shop counter.");
      return;
    }
    const itemId = asString(msg.itemId) ?? "";
    const item = this.host.content.items[itemId];
    if (!item) {
      this.host.sendError(conn, "That item does not exist.");
      return;
    }
    const qty = asInt(msg.qty) ?? 1;
    if (qty < 1 || qty > MAX_STACK) {
      this.host.sendError(conn, "Choose a quantity between 1 and 99.");
      return;
    }
    if (itemCount(player.character.inventory, itemId) < qty) {
      this.host.sendError(conn, `You do not have ${qty}x ${item.name}.`);
      return;
    }
    const removed = removeItem(player.character.inventory, itemId, qty);
    const earned = sellPrice(item) * removed;
    player.character.money += earned;
    this.host.store.saveCharacter(player.accountId, player.character);
    this.sendShopState(player, shopId);
    this.host.sendPartyState(player);
    this.host.send(conn, {
      type: "notice",
      text: `Sold ${removed}x ${item.name} for ${earned} coins.`
    });
    this.host.sendJournal(player, {
      kind: "shop_sell",
      actor: player.character.name,
      item: this.host.i18n.itemName(conn.locale, itemId),
      count: removed,
      money: earned
    });
  }

  handlePcDeposit(conn: PlayerSession["conn"], msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    if (!this.serviceNpcNearby(player, (npc) => npc.kind === "pc")) {
      this.host.sendError(conn, "You are not at a PC.");
      return;
    }
    const partyIndex = asInt(msg.partyIndex);
    if (partyIndex === null) {
      this.host.sendError(conn, "Choose a party member first.");
      return;
    }
    const stored = player.character.party[partyIndex];
    const result = depositToBox(
      player.character,
      partyIndex,
      this.host.content.config.maxBox
    );
    if (!result.ok) {
      this.host.sendError(conn, result.error ?? "That Pokémon cannot be stored.");
      return;
    }
    this.host.store.saveCharacter(player.accountId, player.character);
    this.sendPcState(player);
    this.host.sendPartyState(player);
    this.host.send(conn, { type: "notice", text: "Pokémon stored in the PC." });
    if (stored) {
      this.host.sendJournal(player, {
        kind: "pc_deposit",
        target: this.host.i18n.creature(conn.locale, stored).name
      });
    }
  }

  handlePcWithdraw(conn: PlayerSession["conn"], msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    if (!this.serviceNpcNearby(player, (npc) => npc.kind === "pc")) {
      this.host.sendError(conn, "You are not at a PC.");
      return;
    }
    const boxIndex = asInt(msg.boxIndex);
    if (boxIndex === null) {
      this.host.sendError(conn, "Choose a stored Pokémon first.");
      return;
    }
    const stored = player.character.box[boxIndex];
    const result = withdrawFromBox(
      player.character,
      boxIndex,
      this.host.content.config.maxParty
    );
    if (!result.ok) {
      this.host.sendError(conn, result.error ?? "That Pokémon cannot be withdrawn.");
      return;
    }
    this.host.store.saveCharacter(player.accountId, player.character);
    this.sendPcState(player);
    this.host.sendPartyState(player);
    this.host.send(conn, { type: "notice", text: "Pokémon withdrawn from the PC." });
    if (stored) {
      this.host.sendJournal(player, {
        kind: "pc_withdraw",
        target: this.host.i18n.creature(conn.locale, stored).name
      });
    }
  }

  handlePcSwap(conn: PlayerSession["conn"], msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    if (!this.serviceNpcNearby(player, (npc) => npc.kind === "pc")) {
      this.host.sendError(conn, "You are not at a PC.");
      return;
    }
    const partyIndex = asInt(msg.partyIndex);
    const boxIndex = asInt(msg.boxIndex);
    if (partyIndex === null || boxIndex === null) {
      this.host.sendError(conn, "Choose one party member and one stored Pokémon.");
      return;
    }
    const partyCreature = player.character.party[partyIndex];
    const boxCreature = player.character.box[boxIndex];
    const result = swapPartyWithBox(player.character, partyIndex, boxIndex);
    if (!result.ok) {
      this.host.sendError(conn, result.error ?? "Those Pokémon cannot be swapped.");
      return;
    }
    this.host.store.saveCharacter(player.accountId, player.character);
    this.sendPcState(player);
    this.host.sendPartyState(player);
    this.host.send(conn, { type: "notice", text: "Party and PC Pokémon were swapped." });
    if (partyCreature && boxCreature) {
      this.host.sendJournal(player, {
        kind: "pc_swap",
        actor: this.host.i18n.creature(conn.locale, partyCreature).name,
        target: this.host.i18n.creature(conn.locale, boxCreature).name
      });
    }
  }

  handlePcRelease(conn: PlayerSession["conn"], msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    if (player.battleId) {
      this.host.sendError(conn, "Finish the battle first.");
      return;
    }
    if (!this.serviceNpcNearby(player, (npc) => npc.kind === "pc")) {
      this.host.sendError(conn, "You are not at a PC.");
      return;
    }
    const boxIndex = asInt(msg.boxIndex);
    if (boxIndex === null) {
      this.host.sendError(conn, "Choose a stored Pokémon first.");
      return;
    }
    const released = player.character.box[boxIndex];
    const result = releaseFromBox(player.character, boxIndex);
    if (!result.ok) {
      this.host.sendError(conn, result.error ?? "That Pokémon cannot be released.");
      return;
    }
    this.host.store.saveCharacter(player.accountId, player.character);
    this.sendPcState(player);
    this.host.sendPartyState(player);
    this.host.send(conn, {
      type: "notice",
      text: `${released?.name ?? "The Pokémon"} was released. Goodbye!`
    });
    if (released) {
      this.host.sendJournal(player, {
        kind: "release",
        target: this.host.i18n.creature(conn.locale, released).name
      });
    }
  }

  handleRename(conn: PlayerSession["conn"], msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    if (player.battleId) {
      this.host.sendError(conn, "Finish the battle first.");
      return;
    }
    if (!this.serviceNpcNearby(player, (npc) => npc.kind === "pc")) {
      this.host.sendError(conn, "You are not at a PC.");
      return;
    }
    const source = asString(msg.source);
    if (source !== "party" && source !== "box") {
      this.host.sendError(conn, "Choose a party or boxed Pokémon.");
      return;
    }
    const index = asInt(msg.index);
    if (index === null) {
      this.host.sendError(conn, "Choose a Pokémon first.");
      return;
    }
    const list = source === "party" ? player.character.party : player.character.box;
    const previousName = list[index]?.name ?? "";
    const result = renameCreature(
      player.character,
      source,
      index,
      asString(msg.name) ?? ""
    );
    if (!result.ok) {
      this.host.sendError(conn, result.error ?? "That Pokémon cannot be renamed.");
      return;
    }
    this.host.store.saveCharacter(player.accountId, player.character);
    this.sendPcState(player);
    this.host.sendPartyState(player);
    this.host.send(conn, {
      type: "notice",
      text: `${previousName || "Pokémon"} is now called ${result.creature?.name}.`
    });
    this.host.sendJournal(player, {
      kind: "rename",
      actor: result.creature?.name ?? previousName,
      target: previousName
    });
  }

  /** Tutor/TM/relearn all feed the same pending-move queue as level-ups. */
  handleTeachMove(conn: PlayerSession["conn"], msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    if (player.battleId) {
      this.host.sendError(conn, "Finish the battle first.");
      return;
    }
    const npc = this.npcInReach(
      player,
      asString(msg.npcId) ?? "",
      (candidate) => candidate.kind === "move_tutor" || candidate.kind === "move_reminder"
    );
    if (!npc) {
      this.host.sendError(conn, "There is no move tutor close enough.");
      return;
    }
    const partyIndex = asInt(msg.partyIndex);
    if (
      partyIndex === null ||
      partyIndex < 0 ||
      partyIndex >= player.character.party.length
    ) {
      this.host.sendError(conn, "Choose a party member first.");
      return;
    }
    const moveId = asString(msg.moveId) ?? "";
    const creature = player.character.party[partyIndex];
    if (npc.kind === "move_tutor") {
      if (!tutorKnowsMove(npc, moveId)) {
        this.host.sendError(conn, "That move tutor cannot teach that move.");
        return;
      }
    } else if (!canRememberMove(this.host.content, creature, moveId)) {
      this.host.sendError(conn, `${creature.name} cannot remember that move.`);
      return;
    }
    const queued = queueMoveLearn(this.host.content, creature, moveId);
    if (!queued.ok) {
      this.host.sendError(conn, queued.error ?? "That move cannot be taught.");
      return;
    }
    this.host.store.saveCharacter(player.accountId, player.character);
    this.host.sendPartyState(player);
    this.host.sendNextMoveLearn(player);
  }

  handleTradeEvolve(conn: PlayerSession["conn"], msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    if (player.battleId) {
      this.host.sendError(conn, "Finish the battle first.");
      return;
    }
    const npc = this.npcInReach(
      player,
      asString(msg.npcId) ?? "",
      (candidate) => candidate.kind === "trade"
    );
    if (!npc) {
      this.host.sendError(conn, "You are not at the link trade station.");
      return;
    }
    const partyIndex = asInt(msg.partyIndex);
    if (
      partyIndex === null ||
      partyIndex < 0 ||
      partyIndex >= player.character.party.length
    ) {
      this.host.sendError(conn, "Choose a party member first.");
      return;
    }
    const creature = player.character.party[partyIndex];
    const evolution = tradeEvolutionFor(this.host.content, creature);
    if (!evolution) {
      this.host.sendError(conn, `${creature.name} cannot evolve through a link trade.`);
      return;
    }
    const result = evolveCreature(this.host.content, creature, evolution);
    if (!result) {
      this.host.sendError(conn, "That Pokémon cannot evolve.");
      return;
    }
    if (evolution.item !== undefined) creature.heldItem = null;
    this.host.store.saveCharacter(player.accountId, player.character);
    this.publishEvolution(
      player,
      result,
      `${result.fromName} came back from the trade as ${result.toName}!`
    );
  }

  handleSetAbility(conn: PlayerSession["conn"], msg: Dict): void {
    const player = conn.player;
    if (!player) {
      this.host.sendError(conn, "Create a character first.");
      return;
    }
    if (player.battleId) {
      this.host.sendError(conn, "Finish the battle first.");
      return;
    }
    const npc = this.npcInReach(
      player,
      asString(msg.npcId) ?? "",
      (candidate) => candidate.kind === "ability"
    );
    if (!npc) {
      this.host.sendError(conn, "You are not at the ability expert.");
      return;
    }
    const partyIndex = asInt(msg.partyIndex);
    if (
      partyIndex === null ||
      partyIndex < 0 ||
      partyIndex >= player.character.party.length
    ) {
      this.host.sendError(conn, "Choose a party member first.");
      return;
    }
    const creature = player.character.party[partyIndex];
    const normalized = (asString(msg.abilityId) ?? "")
      .toLowerCase()
      .replace(/[^a-z0-9]/g, "");
    const chosen = abilityOptionsForSpecies(creature.species).find(
      (option) => option.id === normalized
    );
    if (!chosen) {
      this.host.sendError(conn, "That ability is not available for this Pokémon.");
      return;
    }
    const changed =
      creature.ability !== chosen.id || creature.abilitySlot !== chosen.slot;
    if (changed) {
      creature.ability = chosen.id;
      creature.abilitySlot = chosen.slot;
      delete creature.abilityName;
      delete creature.abilityDescription;
      this.host.store.saveCharacter(player.accountId, player.character);
      this.host.sendPartyState(player);
    }
    this.sendAbilityService(player, npc);
  }

  private sendMoveService(
    player: PlayerSession,
    npc: MapDef["npcs"][number]
  ): void {
    const locale = player.conn.locale;
    const service = npc.kind === "move_tutor" ? "tutor" : "reminder";
    const party = player.character.party.map((creature) => {
      const view = this.host.i18n.creature(locale, creature);
      if (service !== "reminder") return view;
      return {
        ...view,
        relearn: relearnableMoves(this.host.content, creature).map((move) =>
          this.moveView(locale, move)
        )
      };
    });
    const moves =
      service === "tutor"
        ? (npc.moveList ?? [])
            .map((moveId) => this.host.content.moves[moveId])
            .filter((move): move is MoveDef => Boolean(move))
            .map((move) => this.moveView(locale, move))
        : undefined;
    this.host.send(player.conn, {
      type: "move_service",
      npcId: npc.id,
      npcName: this.host.i18n.npcName(locale, npc.name),
      service,
      party,
      moves
    });
  }

  private sendTradeService(
    player: PlayerSession,
    npc: MapDef["npcs"][number]
  ): void {
    const locale = player.conn.locale;
    const party = player.character.party.map((creature) => ({
      ...this.host.i18n.creature(locale, creature),
      tradeable: Boolean(tradeEvolutionFor(this.host.content, creature))
    }));
    this.host.send(player.conn, {
      type: "trade_service",
      npcId: npc.id,
      npcName: this.host.i18n.npcName(locale, npc.name),
      party
    });
  }

  private sendAbilityService(
    player: PlayerSession,
    npc: MapDef["npcs"][number]
  ): void {
    const locale = player.conn.locale;
    const party = player.character.party.map((creature) => ({
      ...this.host.i18n.creature(locale, creature),
      abilities: abilityOptionsForSpecies(creature.species).map((option) => ({
        ...option,
        name: this.host.i18n.abilityName(locale, option.id),
        description: this.host.i18n.abilityDescription(locale, option.id)
      }))
    }));
    this.host.send(player.conn, {
      type: "ability_service",
      npcId: npc.id,
      npcName: this.host.i18n.npcName(locale, npc.name),
      party
    });
  }

  private moveView(locale: string, move: MoveDef) {
    return {
      id: move.id,
      name: this.host.i18n.moveName(locale, move.id),
      type: move.type,
      power: move.power,
      accuracy: move.accuracy,
      pp: move.pp ?? 5,
      category: move.category ?? "status"
    };
  }

  private useTm(
    player: PlayerSession,
    item: ItemDef,
    target: PlayerSession["character"]["party"][number]
  ): void {
    if (!item.moveId) {
      this.host.sendError(player.conn, "That TM has no move.");
      return;
    }
    const queued = queueMoveLearn(this.host.content, target, item.moveId);
    if (!queued.ok) {
      this.host.sendError(player.conn, queued.error ?? "That move cannot be taught.");
      return;
    }
    // Gen 5 TMs are reusable, so the item stays in the bag.
    this.host.store.saveCharacter(player.accountId, player.character);
    this.host.sendPartyState(player);
    this.host.sendNextMoveLearn(player);
    this.host.send(player.conn, {
      type: "notice",
      text: `${target.name} can learn ${queued.move?.name ?? "a new move"}!`
    });
  }

  private useEvolutionItem(
    player: PlayerSession,
    item: ItemDef,
    target: PlayerSession["character"]["party"][number]
  ): void {
    const evolution = itemEvolutionFor(this.host.content, target, item.id);
    if (!evolution) {
      this.host.sendError(
        player.conn,
        `${item.name} had no effect on ${target.name}.`
      );
      return;
    }
    const result = evolveCreature(this.host.content, target, evolution);
    if (!result) {
      this.host.sendError(player.conn, "That Pokémon cannot evolve.");
      return;
    }
    removeItem(player.character.inventory, item.id, 1);
    this.host.store.saveCharacter(player.accountId, player.character);
    this.publishEvolution(
      player,
      result,
      `${result.fromName} evolved into ${result.toName}!`
    );
  }

  private publishEvolution(
    player: PlayerSession,
    evolution: EvolutionResult,
    message: string
  ): void {
    const pokedexChanged = markSpeciesCaught(
      this.host.content,
      player.character,
      evolution.toSpecies
    );
    this.host.sendPartyState(player);
    if (pokedexChanged) this.host.sendPokedexState(player, false);
    this.host.send(player.conn, { type: "notice", text: message });
    this.host.send(player.conn, { type: "evolution_event", evolution });
    this.host.sendJournal(player, {
      kind: "evolution",
      actor: evolution.fromName,
      target: evolution.toName
    });
  }

  private sendShopState(player: PlayerSession, shopId: string): void {
    const shop = this.host.content.shops[shopId];
    if (!shop) return;
    const locale = player.conn.locale;
    this.host.send(player.conn, {
      type: "shop_state",
      shop: {
        id: shop.id,
        name: this.host.i18n.shopName(locale, shop.id),
        items: shopItemsForClient(shop, this.host.content, player.character.inventory).map(
          (item) => this.host.i18n.item(locale, item)
        )
      },
      money: player.character.money,
      inventory: player.character.inventory
    });
  }

  private sendPcState(player: PlayerSession): void {
    const view = this.host.i18n.character(player.conn.locale, player.character);
    this.host.send(player.conn, {
      type: "pc_state",
      party: view.party,
      box: view.box,
      maxParty: this.host.content.config.maxParty,
      maxBox: this.host.content.config.maxBox
    });
  }

  /** Finds one visible NPC within two tiles that matches the service kind. */
  private npcInReach(
    player: PlayerSession,
    npcId: string,
    predicate: (npc: MapDef["npcs"][number]) => boolean
  ): MapDef["npcs"][number] | null {
    const map = this.host.map(player.character.mapId);
    const npc = findNpc(map, npcId);
    if (!npc || !predicate(npc)) return null;
    if (!this.host.story.npcVisible(npc, player.character.storyFlags)) return null;
    const distance =
      Math.abs(npc.x - player.character.x) + Math.abs(npc.y - player.character.y);
    return distance <= 2 ? npc : null;
  }

  /** Shops and the PC can only be used while standing next to their NPC. */
  private serviceNpcNearby(
    player: PlayerSession,
    predicate: (npc: MapDef["npcs"][number]) => boolean
  ): boolean {
    const map = this.host.map(player.character.mapId);
    return map.npcs.some((npc) => {
      if (!predicate(npc)) return false;
      const distance =
        Math.abs(npc.x - player.character.x) + Math.abs(npc.y - player.character.y);
      return distance <= 2;
    });
  }
}
