import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

function numberFromEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === "") return fallback;
  const value = Number(raw);
  return Number.isFinite(value) ? value : fallback;
}

function optionalNumber(name: string): number | null {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === "") return null;
  const value = Number(raw);
  return Number.isFinite(value) ? Math.trunc(value) : null;
}

function optionalEncounterRate(): number | null {
  const raw = process.env.ENCOUNTER_RATE;
  if (raw === undefined || raw.trim() === "") return null;
  const value = Number(raw);
  if (!Number.isFinite(value)) return null;
  return Math.min(1, Math.max(0, value));
}

export const CONFIG = {
  host: process.env.HOST ?? "0.0.0.0",
  port: numberFromEnv("PORT", 2567),
  dataDir: process.env.DATA_DIR ?? path.resolve(here, "..", "data"),
  moveCooldownMs: 130,
  chatCooldownMs: 800,
  maxChatLength: 200,
  maxMessageBytes: 8192,
  messagesPerSecond: 40,
  tileWindowRadius: numberFromEnv("TILE_WINDOW_RADIUS", 32),
  tileWindowRefreshMargin: numberFromEnv("TILE_WINDOW_MARGIN", 16),
  playerViewRadius: numberFromEnv("AOI_RADIUS", 64),
  encounterRateOverride: optionalEncounterRate(),
  debugStartX: optionalNumber("DEBUG_START_X"),
  debugStartY: optionalNumber("DEBUG_START_Y"),
  encounterGraceMs: 1500,
  saveDebounceMs: 500,
  autosaveMs: 10_000,
  tokenTtlMs: 7 * 24 * 60 * 60 * 1000
};
