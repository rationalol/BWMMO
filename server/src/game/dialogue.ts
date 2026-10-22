import type { NpcDef } from "../content/types.js";

export interface DialogueSelection {
  lines: string[];
  setFlags: number[];
}

/**
 * Picks the first dialogue variant whose story flags all match. Unspecified
 * flags are zero, matching a new character. Falls back to the default lines.
 */
export function selectDialogue(
  npc: NpcDef,
  storyFlags: Record<string, number> | undefined
): DialogueSelection {
  const flags = storyFlags ?? {};
  for (const variant of npc.dialogueVariants ?? []) {
    const matches = Object.entries(variant.flags).every(
      ([flag, expected]) => (flags[flag] ?? 0) === expected
    );
    if (matches) {
      return { lines: variant.lines, setFlags: variant.setFlags ?? [] };
    }
  }
  return { lines: npc.dialogue, setFlags: npc.setFlags ?? [] };
}

export function renderDialogueLine(line: string, playerName: string): string {
  return line
    .replaceAll("{name}", playerName)
    .replaceAll("{rival}", "your friend")
    .replaceAll("{nickname}", "your partner");
}
