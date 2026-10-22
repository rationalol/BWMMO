import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { loadContent } from "../src/content/loader.js";
import { ContentLocalizer } from "../src/i18n/localizer.js";
import { createStarter } from "../src/game/creatures.js";
import { loadOutdoorLocations, locationAt } from "../src/game/locations.js";

const content = loadContent();
const HERE = path.dirname(fileURLToPath(import.meta.url));

function tempLocaleDir(names: unknown): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "bwmmo-i18n-"));
  fs.writeFileSync(path.join(dir, "zh_CN.json"), JSON.stringify(names));
  return dir;
}

test("content localizer overlays names by id and preserves game ids", () => {
  const dir = tempLocaleDir({
    locale: "zh_CN",
    species: {
      snivy: "藤藤蛇",
      bulbasaur: "妙蛙种子"
    },
    moves: {
      tackle: "撞击",
      pound: "拍击"
    },
    items: {
      potion: "伤药"
    },
    shops: {
      nuvema_mart: "诺文镇商店"
    },
    maps: {
      unova_full: "合众"
    },
    npcs: {
      "Nurse Joy": "乔伊小姐"
    }
  });
  try {
    const i18n = new ContentLocalizer(content, dir);
    assert.equal(i18n.speciesName("zh_CN", "snivy"), "藤藤蛇");
    assert.equal(i18n.speciesName("zh_CN", "bulbasaur"), "妙蛙种子");
    assert.equal(i18n.moveName("zh_CN", "pound"), "拍击");
    assert.equal(i18n.itemName("zh_CN", "potion"), "伤药");
    assert.equal(i18n.shopName("zh_CN", "nuvema_mart"), "诺文镇商店");
    assert.equal(i18n.mapName("zh_CN", "unova_full"), "合众");
    assert.equal(i18n.npcName("zh_CN", "Nurse Joy"), "乔伊小姐");

    // English remains the canonical fallback.
    assert.equal(i18n.speciesName("en", "snivy"), "Snivy");
    assert.equal(i18n.moveName("en", "pound"), "Pound");
    assert.equal(i18n.npcName("en", "Nurse Joy"), "Nurse Joy");

    const starter = createStarter(content, "snivy");
    const view = i18n.creature("zh_CN", starter);
    assert.equal(view.species, starter.species);
    assert.equal(view.name, "藤藤蛇");
    assert.equal(view.moves[0].id, starter.moves[0].id);
    assert.equal(view.moves[0].name, "撞击");

    // The original save data must not be mutated by rendering.
    assert.equal(starter.name, "Snivy");
    assert.equal(starter.moves[0].name, "Tackle");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("the shipped zh_CN catalog covers every species, move and item", () => {
  const catalogPath = path.resolve(HERE, "..", "content", "i18n", "zh_CN", "names.json");
  const catalog = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
  assert.equal(Object.keys(catalog.species).length, Object.keys(content.species).length);
  assert.equal(Object.keys(catalog.moves).length, Object.keys(content.moves).length);
  assert.equal(Object.keys(catalog.items).length, Object.keys(content.items).length);
  assert.equal(catalog.species.snivy, "藤藤蛇");
  assert.equal(catalog.moves.pound, "拍击");
  assert.equal(catalog.items.potion, "伤药");
  assert.equal(catalog.species[Object.keys(content.species)[0]].length > 0, true);
});

test("outdoor location grid resolves towns and routes", () => {
  const grid = loadOutdoorLocations();
  assert.ok(grid, "outdoor location grid should load");
  assert.equal(locationAt(grid!, 784, 753), "Nuvema Town");
  assert.equal(locationAt(grid!, 768, 720), "Route 1");
  const catalog = JSON.parse(
    fs.readFileSync(path.resolve(HERE, "..", "content", "i18n", "zh_CN", "names.json"), "utf8")
  );
  assert.equal(catalog.locations["Nuvema Town"], "诺文镇");
  assert.equal(catalog.locations["Route 1"], "1号道路");
});
