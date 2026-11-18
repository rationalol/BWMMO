import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { loadContent } from "../src/content/loader.js";
import { loadWorldMap } from "../src/game/world-map.js";
import { ContentLocalizer } from "../src/i18n/localizer.js";

const worldMap = loadWorldMap();

test("the extracted Unova map covers every named outdoor area", () => {
  assert.ok(worldMap, "world_map.json should load");
  assert.equal(worldMap.width, 256);
  assert.equal(worldMap.height, 168);
  assert.equal(worldMap.places.length, 40);

  const keys = new Set(worldMap.places.map((place) => place.key));
  assert.equal(keys.size, worldMap.places.length, "place keys are unique");
  const locations = JSON.parse(
    fs.readFileSync(
      new URL("../content/rom/outdoor_locations.json", import.meta.url),
      "utf8"
    )
  ) as { grid: string[][] };
  const named = new Set(locations.grid.flat().filter(Boolean));
  assert.equal(named.size, 40, "the world should name forty outdoor areas");
  for (const name of named) {
    assert.ok(keys.has(name), `${name} should have a world-map marker`);
  }
  for (const place of worldMap.places) {
    assert.ok(place.x >= 0 && place.x < worldMap.width, `${place.key} x in map`);
    assert.ok(place.y >= 0 && place.y < worldMap.height, `${place.key} y in map`);
    assert.ok(["town", "route", "landmark"].includes(place.kind), `${place.key} kind`);
  }
});

test("known places sit on the original town map markers", () => {
  const byKey = new Map(worldMap?.places.map((place) => [place.key, place]));
  assert.deepEqual(byKey.get("Nacrene City"), {
    key: "Nacrene City",
    x: 203,
    y: 118,
    kind: "town"
  });
  assert.deepEqual(byKey.get("Nuvema Town"), {
    key: "Nuvema Town",
    x: 232,
    y: 158,
    kind: "town"
  });
  assert.deepEqual(byKey.get("Route 3"), {
    key: "Route 3",
    x: 214,
    y: 118,
    kind: "route"
  });
  assert.deepEqual(byKey.get("Giant Chasm"), {
    key: "Giant Chasm",
    x: 198,
    y: 31,
    kind: "landmark"
  });
});

test("every place name has a Chinese label for the HUD", () => {
  const localizer = new ContentLocalizer(loadContent());
  for (const place of worldMap?.places ?? []) {
    const label = localizer.locationName("zh_CN", place.key);
    assert.notEqual(label, place.key, `${place.key} should be localized`);
  }
  assert.equal(localizer.locationName("zh_CN", "Nacrene City"), "七宝市");
  assert.equal(localizer.locationName("zh_CN", "Route 3"), "3号道路");
});

test("a missing world map is optional", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "bwmmo-world-map-"));
  const file = path.join(dir, "world_map.json");
  fs.writeFileSync(file, "{}");
  assert.equal(loadWorldMap(file), null);
  fs.rmSync(dir, { recursive: true, force: true });
});
