import type { GameContent } from "../content/types.js";
import {
  awardEffortValues,
  awardExperience,
  emptyEvGain,
  evGainTotal,
  healParty,
  type EvGain,
  type EvolutionResult
} from "./creatures.js";
import { markSpeciesCaught } from "./pokedex.js";
import type { BattleState, BattleStatus } from "./battle.js";
import type { CharacterState, CreatureState } from "./types.js";

const EV_STAT_ORDER: Array<keyof EvGain> = ["hp", "atk", "def", "spAtk", "spDef", "speed"];

const EV_STAT_LABELS: Record<keyof EvGain, string> = {
  hp: "HP",
  atk: "Attack",
  def: "Defense",
  spAtk: "Sp. Atk",
  spDef: "Sp. Def",
  speed: "Speed"
};

function describeEvGain(gain: EvGain): string {
  return EV_STAT_ORDER.filter((stat) => gain[stat] > 0)
    .map((stat) => `${gain[stat]} ${EV_STAT_LABELS[stat]}`)
    .join(", ");
}

export interface LevelUpRecord {
  /** Name and species at the time the level was gained, before evolution. */
  name: string;
  species: string;
  level: number;
}

export interface LearnedMoveRecord {
  name: string;
  species: string;
  moveId: string;
}

export interface BattleSettlement {
  result: BattleStatus;
  message: string;
  /** True when the character was knocked out and moved back to the start map. */
  travel: boolean;
  caught: CreatureState | null;
  evolution: EvolutionResult | null;
  pokedexChanged: boolean;
  /** Every level gained by the battler, before any evolution is applied. */
  levelUps: LevelUpRecord[];
  /** Moves learned automatically from level-ups. */
  learnedMoves: LearnedMoveRecord[];
  /** EVs the battler picked up from the defeated creatures. */
  effortValues: EvGain;
}

/**
 * Applies the outcome of a finished battle to the persisted character: XP,
 * rewards, catches, evolution and the black-out teleport. Transport and
 * visibility updates stay with the caller.
 *
 * The caller must clear visibility before calling this when the battle was
 * lost, because the black-out moves the character.
 */
export function settleBattle(
  content: GameContent,
  character: CharacterState,
  battle: BattleState
): BattleSettlement {
  const result = battle.status;
  const wild = battle.wild;
  const trainer = battle.mode === "trainer";
  // A trainer battle only pays for the creatures that actually fainted; a wild
  // battle (or a duel, which uses its own settlement) has a single foe.
  const defeated = trainer
    ? (battle.opponentParty ?? []).filter((creature) => creature.hp <= 0)
    : [wild];
  const foes = defeated.length > 0 ? defeated : [wild];
  let message: string;
  let travel = false;
  let caught: CreatureState | null = null;
  let evolution: EvolutionResult | null = null;
  let pokedexChanged = false;
  const levelUps: LevelUpRecord[] = [];
  const learnedMoves: LearnedMoveRecord[] = [];
  const effortValues = emptyEvGain();

  if (result === "won" || result === "caught") {
    const factor = result === "caught" ? content.config.catchXpFactor : 1;
    const xp = Math.max(
      1,
      Math.floor(
        foes.reduce(
          (total, foe) => total + (foe.baseXp + foe.level * 2) * factor,
          0
        )
      )
    );
    const levelBefore = battle.player.level;
    const nameBefore = battle.player.name;
    const speciesBefore = battle.player.species;
    const xpResult = awardExperience(content, battle.player, xp, battle.log, {
      mapId: character.mapId,
      party: battle.party
    });
    evolution = xpResult.evolution;
    for (const moveId of xpResult.learnedIds) {
      learnedMoves.push({ name: nameBefore, species: speciesBefore, moveId });
    }
    const levelsGained = battle.player.level - levelBefore;
    if (levelsGained > 0) {
      levelUps.push({ name: nameBefore, species: speciesBefore, level: battle.player.level });
      battle.log.push(`${battle.player.name} reached Lv.${battle.player.level}!`);
    }

    if (result === "won") {
      // The active battler takes the effort values of every defeated foe, the
      // same creature that receives the XP in this simplified participation
      // model. A caught wild creature never yields EVs.
      for (const foe of foes) {
        const species = content.species[foe.species];
        if (!species) continue;
        const gain = awardEffortValues(battle.player, species, species.evYield);
        for (const stat of EV_STAT_ORDER) effortValues[stat] += gain[stat];
      }
      const evSummary = describeEvGain(effortValues);
      if (evSummary !== "") {
        battle.log.push(`${battle.player.name} gained ${evSummary} EVs.`);
      }
      const reward = trainer ? battle.reward ?? 0 : content.config.winReward;
      character.money += reward;
      character.wins += 1;
      if (trainer) {
        const name = battle.opponentName ?? "the Trainer";
        message =
          reward > 0
            ? `You defeated ${name} and earned ${reward} coins!`
            : `You defeated ${name}!`;
      } else {
        message = `You won ${content.config.winReward} coins!`;
      }
      if (evSummary !== "") {
        const plural = evGainTotal(effortValues) === 1 ? "EV" : "EVs";
        message += ` ${battle.player.name} gained ${evSummary} ${plural}.`;
      }
    } else {
      if (markSpeciesCaught(content, character, wild.species)) {
        pokedexChanged = true;
      }
      if (character.party.length < content.config.maxParty) {
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
    // A scripted loss must not send the player home mid-scene: the story picks
    // up right after the battle box closes.
    message = trainer ? "You lost the battle." : "You blacked out.";
    travel = !trainer;
  } else {
    message = "You got away safely.";
  }

  character.party = battle.party.map((creature) => structuredClone(creature));
  character.inventory = structuredClone(battle.inventory);
  if (caught) character.party.push(caught);

  if (evolution) {
    if (markSpeciesCaught(content, character, evolution.toSpecies)) {
      pokedexChanged = true;
    }
    message += ` ${evolution.fromName} evolved into ${evolution.toName}!`;
  }

  if (result === "lost") {
    healParty(character.party);
    if (!trainer) {
      const home = content.maps[content.config.startingMap || "town"];
      character.mapId = home.id;
      character.x = home.spawn.x;
      character.y = home.spawn.y;
      character.dir = home.spawn.dir;
      message = `You blacked out and woke up in ${home.name}.`;
    }
  }

  return {
    result,
    message,
    travel,
    caught,
    evolution,
    pokedexChanged,
    levelUps,
    learnedMoves,
    effortValues
  };
}
