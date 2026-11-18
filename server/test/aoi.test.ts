import test from "node:test";
import assert from "node:assert/strict";
import { AoiIndex, type AoiEntity } from "../src/game/aoi.js";
import { withinView } from "../src/game/maps.js";

interface Entity extends AoiEntity {
  accountId: string;
  character: { mapId: string; x: number; y: number };
}

function entity(id: string, mapId: string, x: number, y: number): Entity {
  return { accountId: id, character: { mapId, x, y } };
}

const RADIUS = 64;

test("grid queries match a full scan across cell boundaries", () => {
  const index = new AoiIndex<Entity>();
  const entities: Entity[] = [];
  let seed = 123456789;
  const random = () => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff;
  };

  for (let i = 0; i < 600; i++) {
    const mapId = i % 3 === 0 ? "second" : "unova_full";
    const item = entity(
      `p${i}`,
      mapId,
      Math.floor(random() * 928),
      Math.floor(random() * 864)
    );
    entities.push(item);
    index.add(item);
  }

  for (let i = 0; i < 150; i++) {
    const mapId = i % 4 === 0 ? "second" : "unova_full";
    const x = Math.floor(random() * 928);
    const y = Math.floor(random() * 864);
    const expected = entities
      .filter((item) => withinView({ mapId, x, y }, item.character, RADIUS))
      .map((item) => item.accountId)
      .sort();
    const actual = index
      .query(mapId, x, y, RADIUS)
      .map((item) => item.accountId)
      .sort();
    assert.deepEqual(actual, expected, `query at ${mapId} ${x},${y}`);
  }
});

test("the Chebyshev boundary is inclusive at the radius", () => {
  const index = new AoiIndex<Entity>();
  index.add(entity("center", "m", 100, 100));
  index.add(entity("edge", "m", 164, 100));
  index.add(entity("diagonal", "m", 164, 164));
  index.add(entity("outside", "m", 165, 100));
  index.add(entity("other-map", "elsewhere", 100, 100));

  const ids = index
    .query("m", 100, 100, RADIUS)
    .map((item) => item.accountId)
    .sort();
  assert.deepEqual(ids, ["center", "diagonal", "edge"]);
});

test("updates move an entity between buckets", () => {
  const index = new AoiIndex<Entity>();
  const player = entity("p", "m", 10, 10);
  index.add(player);
  assert.equal(index.size, 1);
  assert.equal(index.query("m", 10, 10, 0).length, 1);

  player.character.x = 500;
  player.character.y = 500;
  index.update(player);
  assert.equal(index.query("m", 10, 10, RADIUS).length, 0);
  assert.equal(index.query("m", 500, 500, 0).length, 1);
  assert.deepEqual(index.query("m", 500, 500, 0), [player]);
});

test("failed updates are not duplicated", () => {
  const index = new AoiIndex<Entity>();
  const player = entity("p", "m", 10, 10);
  index.add(player);
  index.add(player);
  assert.equal(index.size, 1);
  assert.equal(index.query("m", 10, 10, 0).length, 1);
});

test("removals clean up empty buckets and ignore unknown ids", () => {
  const index = new AoiIndex<Entity>();
  const a = entity("a", "m", 1, 1);
  const b = entity("b", "other", 2, 2);
  index.add(a);
  index.add(b);
  assert.equal(index.remove("missing"), false);
  assert.equal(index.remove(a), true);
  assert.equal(index.remove(a), false);
  assert.equal(index.size, 1);
  assert.deepEqual(index.query("m", 1, 1, RADIUS), []);
  assert.deepEqual(
    index.query("other", 2, 2, 0).map((item) => item.accountId),
    ["b"]
  );
});

test("negative coordinates work and clear empties the index", () => {
  const index = new AoiIndex<Entity>();
  index.add(entity("a", "m", -70, -70));
  index.add(entity("b", "m", -6, -6));
  assert.deepEqual(
    index.query("m", 0, 0, 70).map((item) => item.accountId),
    ["a", "b"]
  );
  index.clear();
  assert.equal(index.size, 0);
  assert.deepEqual(index.query("m", 0, 0, 1000), []);
});
