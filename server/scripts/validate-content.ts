import { DEFAULT_CONTENT_DIR, loadContent } from "../src/content/loader.js";

const directory = process.env.CONTENT_DIR ?? DEFAULT_CONTENT_DIR;
const content = loadContent(directory);
console.log(
  `Content OK: ${Object.keys(content.maps).length} maps, ` +
    `${Object.keys(content.species).length} species, ` +
    `${Object.keys(content.moves).length} moves, ` +
    `${content.starters.length} starters`
);
for (const map of Object.values(content.maps)) {
  const zoneEncounters =
    map.encounterZones?.reduce((sum, zone) => sum + zone.table.length, 0) ?? 0;
  const encounters = (map.encounter?.table.length ?? 0) + zoneEncounters;
  const zoneLabel = map.encounterZones?.length
    ? `, ${map.encounterZones.length} encounter zones`
    : "";
  console.log(
    `  ${map.id}: ${map.name} (${map.width}x${map.height}, ${map.npcs.length} NPCs, ` +
      `${encounters} encounters${zoneLabel})`
  );
}
