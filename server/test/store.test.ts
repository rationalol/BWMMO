import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Store } from "../src/store.js";
import { loadContent } from "../src/content/loader.js";
import { createStarter } from "../src/game/creatures.js";

const content = loadContent();

function tempStore(): { store: Store; dir: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "bwmmo-store-"));
  return { store: new Store(dir), dir };
}

test("register, login, and password checking", () => {
  const { store, dir } = tempStore();
  try {
    const result = store.register("Ash", "pikachu");
    assert.equal(result.ok, true);
    assert.ok(store.login("ash", "pikachu"));
    assert.equal(store.login("ash", "wrong"), null);
    assert.equal(store.login("missing", "pikachu"), null);
    const duplicate = store.register("ash", "another");
    assert.equal(duplicate.ok, false);
  } finally {
    store.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("tokens can be resumed and survive a reload", () => {
  const { store, dir } = tempStore();
  try {
    const result = store.register("Misty", "starmie");
    assert.equal(result.ok, true);
    if (!result.ok) return;
    const token = store.issueToken(result.account.id);
    assert.equal(store.resume(token)?.username, "Misty");
    store.flush();

    const reloaded = new Store(dir);
    try {
      assert.equal(reloaded.resume(token)?.username, "Misty");
    } finally {
      reloaded.close();
    }
  } finally {
    store.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("characters are saved and name uniqueness is enforced", () => {
  const { store, dir } = tempStore();
  try {
    const result = store.register("Brock", "onix");
    assert.equal(result.ok, true);
    if (!result.ok) return;
    const accountId = result.account.id;
    const character = {
      id: "char-1",
      name: "Rocky",
      color: "#e76f51",
      mapId: "town",
      x: 15,
      y: 16,
      dir: "down" as const,
      sprite: 0,
      money: 500,
      wins: 0,
      party: [createStarter(content, "snivy")],
      box: [],
      inventory: { items: { poke_ball: 10, potion: 2 } }
    };
    store.saveCharacter(accountId, character);
    assert.equal(store.isNameTaken("rocky"), true);
    assert.equal(store.isNameTaken("other"), false);
    assert.deepEqual(store.getCharacter(accountId)?.name, "Rocky");
    assert.equal(store.hasCharacter(accountId), true);
    store.flush();

    const reloaded = new Store(dir);
    try {
      const loaded = reloaded.getCharacter(accountId);
      assert.equal(loaded?.party[0].species, "snivy");
      assert.equal(loaded?.party[0].types[0], "Grass");
      assert.equal(loaded?.inventory.items.poke_ball, 10);
      assert.equal(loaded?.inventory.items.potion, 2);
      assert.equal(loaded?.x, 15);
    } finally {
      reloaded.close();
    }
  } finally {
    store.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
