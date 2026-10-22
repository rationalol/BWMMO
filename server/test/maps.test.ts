import test from "node:test";
import assert from "node:assert/strict";
import { loadContent } from "../src/content/loader.js";
import {
  canStep,
  encounterAt,
  getPortal,
  hasNpcAt,
  heightAt,
  isTallGrass,
  isWalkable,
  needsTileWindowRefresh,
  portalAcceptsDirection,
  portalTriggersOnStep,
  tileWindow,
  validateMaps,
  withinView
} from "../src/game/maps.js";

const content = loadContent();
const maps = content.maps;

test("content loads and every map passes structural validation", () => {
  assert.deepEqual(validateMaps(maps), []);
  assert.equal(Object.keys(maps).length, 378);
});

test("all maps are rectangular; hand-authored maps are bordered", () => {
  for (const map of Object.values(maps)) {
    assert.equal(map.tiles.length, map.height, `${map.id} height`);
    for (const row of map.tiles) {
      assert.equal(row.length, map.width, `${map.id} width`);
    }
  }
  // ROM interiors can legitimately open onto a neighbouring room/cave edge.
  for (const map of Object.values(maps)) {
    if (map.id.startsWith("unova_in_")) continue;
    for (let x = 0; x < map.width; x++) {
      assert.ok(["#", "P"].includes(map.tiles[0][x]), `${map.id} top border at ${x}`);
      assert.ok(
        ["#", "P"].includes(map.tiles[map.height - 1][x]),
        `${map.id} bottom border at ${x}`
      );
    }
    for (let y = 0; y < map.height; y++) {
      assert.ok(["#", "P"].includes(map.tiles[y][0]), `${map.id} left border at ${y}`);
      assert.ok(
        ["#", "P"].includes(map.tiles[y][map.width - 1]),
        `${map.id} right border at ${y}`
      );
    }
  }
});

test("every Pokémon Center interior has a working Nurse Joy", () => {
  const centers = Object.values(maps).filter((map) => map.name === "Pokémon Center");
  assert.equal(centers.length, 14);
  for (const center of centers) {
    const healers = center.npcs.filter((npc) => npc.kind === "healer");
    assert.equal(healers.length, 1, `${center.id} should have one healer`);
    assert.equal(healers[0].name, "Nurse Joy", `${center.id} healer name`);
    assert.equal(healers[0].x, 7, `${center.id} healer counter x`);
    assert.equal(healers[0].y, 10, `${center.id} healer counter y`);
    // The U-shaped counter is a scene prop, not permission-grid geometry. Seal
    // its inside so the player cannot slip around the nurse and stand on it.
    for (const x of [5, 6, 8, 9]) {
      assert.equal(isWalkable(center, x, 10), false, `${center.id} counter ${x},10`);
    }
    assert.equal(isWalkable(center, 7, 10), true, `${center.id} nurse tile`);
    assert.equal(isWalkable(center, 7, 11), true, `${center.id} front approach`);
  }
});

test("wide ROM doorways expose a portal on every walkable door tile", () => {
  // Side doors are 1x3 and building doors 3x1 in the ROM warp data. Only
  // marking the anchor tile left most of the visible doorway inert.
  const gate = maps.unova_in_320;
  const rightDoor = [
    [15, 4],
    [15, 5],
    [15, 6]
  ] as const;
  const leftDoor = [
    [1, 4],
    [1, 5],
    [1, 6]
  ] as const;
  for (const [x, y] of [...rightDoor, ...leftDoor]) {
    assert.ok(getPortal(gate, x, y), `gate door tile ${x},${y} should warp`);
  }
  const rightTargets = rightDoor.map(([x, y]) => getPortal(gate, x, y)!);
  const leftTargets = leftDoor.map(([x, y]) => getPortal(gate, x, y)!);
  assert.equal(new Set(rightTargets.map((p) => `${p.targetMap},${p.targetX},${p.targetY}`)).size, 1);
  assert.equal(new Set(leftTargets.map((p) => `${p.targetMap},${p.targetX},${p.targetY}`)).size, 1);
  assert.notEqual(
    `${rightTargets[0].targetX},${rightTargets[0].targetY}`,
    `${leftTargets[0].targetX},${leftTargets[0].targetY}`,
    "each gate side leads to its own spot outdoors"
  );

  const lab = maps.unova_in_396;
  for (const [x, y] of [
    [3, 11],
    [4, 11],
    [5, 11]
  ] as const) {
    assert.ok(getPortal(lab, x, y), `lab door tile ${x},${y} should warp`);
  }
});

test("the gate's right doorway is usable from the tile the player stands on", () => {
  const gate = maps.unova_in_320;
  assert.ok(isWalkable(gate, 15, 5), "middle of the right doorway is floor");
  assert.ok(getPortal(gate, 15, 5), "standing in the doorway counts as using the door");
  assert.equal(isWalkable(gate, 16, 5), false, "the wall is still solid");
});

test("Nuvema house side door keeps the ROM's full 1x3 frontage", () => {
  const outdoor = maps.unova_full;
  for (const y of [647, 648, 649]) {
    const door = getPortal(outdoor, 760, y);
    assert.ok(door, `frontage tile 760,${y} should warp`);
    assert.equal(door.targetMap, "unova_in_320");
    assert.equal(door.entryDir, "right");
    assert.equal(door.onWarpTile, false);
    assert.equal(portalAcceptsDirection(door, "right"), true);
    assert.equal(portalTriggersOnStep(outdoor, door), false);
  }
  assert.equal(getPortal(outdoor, 760, 646), undefined, "outside the 1x3 frontage is inert");
});

test("ROM doors keep the contact direction that opens them", () => {
  const outdoor = maps.unova_full;

  const labDoor = getPortal(outdoor, 777, 741)!;
  assert.equal(labDoor.targetMap, "unova_in_396");
  assert.equal(labDoor.entryDir, "up", "Nuvema lab door is entered with W");
  assert.equal(labDoor.onWarpTile, false, "trigger sits on the doorstep in front of the door");
  assert.equal(portalAcceptsDirection(labDoor, "up"), true);
  for (const dir of ["down", "left", "right"] as const) {
    assert.equal(portalAcceptsDirection(labDoor, dir), false, `W is the only way in, not ${dir}`);
  }
  assert.equal(
    portalTriggersOnStep(outdoor, labDoor),
    false,
    "walking onto the doorstep must not warp"
  );

  const sideDoor = getPortal(outdoor, 446, 437)!;
  assert.equal(sideDoor.entryDir, "right", "west-wall door is entered with D");
  assert.equal(sideDoor.onWarpTile, false);
  assert.equal(portalAcceptsDirection(sideDoor, "right"), true);
  assert.equal(portalAcceptsDirection(sideDoor, "up"), false, "W must not enter this side door");

  const eastDoor = outdoor.portals.find(
    (portal) => portal.entryDir === "left" && portal.onWarpTile === true
  );
  assert.ok(eastDoor, "the ROM also has doors entered with A");
  assert.equal(portalAcceptsDirection(eastDoor!, "left"), true);

  const labExit = maps.unova_in_396.portals.find((portal) => portal.targetMap === "unova_full")!;
  assert.equal(labExit.entryDir, "down", "leaving the lab walks south");
  assert.equal(labExit.targetDir, "down", "arriving outside faces the street");
  assert.equal(
    portalTriggersOnStep(maps.unova_in_396, labExit),
    true,
    "the doormat is the warp tile itself"
  );
});

test("snapped triggers whose entry side opens onto floor still fire on the step", () => {
  // A snapped trigger is usually placed in front of a solid door, but the
  // helper also has to handle a snapped trigger that opens onto more floor.
  const room = maps.unova_in_123;
  const openLink = {
    ...getPortal(room, 9, 4)!,
    x: 9,
    y: 3,
    entryDir: "right" as const,
    onWarpTile: false
  };
  assert.ok(isWalkable(room, 10, 3), "the link opens onto the next room");
  assert.equal(portalTriggersOnStep(room, openLink), true);
});

test("solid side-door triggers sit in front of the door and need a push", () => {
  const room = maps.unova_in_123;
  const link = getPortal(room, 9, 4)!;
  assert.equal(link.onWarpTile, false);
  assert.equal(link.entryDir, "right");
  assert.equal(isWalkable(room, 10, 4), false, "the doorway itself is solid");
  assert.equal(portalTriggersOnStep(room, link), false);
});

test("legacy hand-authored portals keep any-direction behaviour", () => {
  const townPortal = getPortal(maps.town, 15, 18)!;
  assert.equal(townPortal.entryDir, undefined);
  assert.equal(townPortal.onWarpTile, undefined);
  for (const dir of ["up", "down", "left", "right"] as const) {
    assert.equal(portalAcceptsDirection(townPortal, dir), true);
  }
  assert.equal(portalTriggersOnStep(maps.town, townPortal), true);
});

test("every ROM portal records whether its trigger is the doorway or the floor in front", () => {
  for (const map of Object.values(maps)) {
    if (map.id !== "unova_full" && !map.id.startsWith("unova_in_")) continue;
    for (const portal of map.portals) {
      assert.equal(
        typeof portal.onWarpTile,
        "boolean",
        `${map.id} portal at ${portal.x},${portal.y} needs onWarpTile`
      );
      if (portal.entryDir !== undefined) {
        assert.ok(
          ["up", "down", "left", "right"].includes(portal.entryDir),
          `${map.id} portal at ${portal.x},${portal.y} has an invalid entryDir`
        );
      }
    }
  }
});

test("town, route, and grove portals link correctly", () => {
  const townPortal = getPortal(maps.town, 15, 18);
  const routeSouth = getPortal(maps.route1, 15, 24);
  const routeNorth = getPortal(maps.route1, 15, 1);
  const grovePortal = getPortal(maps.grove, 15, 23);

  assert.ok(townPortal);
  assert.ok(routeSouth);
  assert.ok(routeNorth);
  assert.ok(grovePortal);

  assert.equal(townPortal.targetMap, "route1");
  assert.equal(townPortal.targetX, 15);
  assert.equal(townPortal.targetY, 23);

  assert.equal(routeSouth.targetMap, "town");
  assert.equal(routeSouth.targetX, 15);
  assert.equal(routeSouth.targetY, 17);

  assert.equal(routeNorth.targetMap, "grove");
  assert.equal(routeNorth.targetX, 15);
  assert.equal(routeNorth.targetY, 22);

  assert.equal(grovePortal.targetMap, "route1");
  assert.equal(grovePortal.targetX, 15);
  assert.equal(grovePortal.targetY, 2);

  assert.ok(isWalkable(maps.route1, townPortal.targetX, townPortal.targetY));
  assert.ok(isWalkable(maps.town, routeSouth.targetX, routeSouth.targetY));
  assert.ok(isWalkable(maps.grove, routeNorth.targetX, routeNorth.targetY));
  assert.ok(isWalkable(maps.route1, grovePortal.targetX, grovePortal.targetY));
});

test("outdoor Unova is one seamless full matrix world", () => {
  const map = maps.unova_full;
  assert.equal(map.width, 928);
  assert.equal(map.height, 864);
  assert.ok(map.portals.length > 0, "outdoor doors should link into interiors");
  const labDoor = map.portals.find((portal) => portal.x === 777 && portal.y === 741);
  assert.equal(labDoor?.targetMap, "unova_in_396", "Nuvema lab door");
  assert.equal(labDoor?.targetDir, "up", "entering the lab faces into the room");
  const labExit = maps.unova_in_396.portals.find((portal) => portal.targetMap === "unova_full");
  assert.equal(labExit?.targetDir, "down", "leaving the lab faces the street");
  assert.ok(map.visual, "seamless world needs a server-owned visual manifest");
  assert.equal(map.visual.originZ, -248);
  assert.equal(map.visual.chunks.length, 109);
  assert.equal(map.spawn.x, 784);
  assert.equal(map.spawn.y, 753);

  for (const y of [735, 736, 703, 704]) {
    for (const x of [787, 788]) {
      assert.ok(isWalkable(map, x, y), `seam tile ${x},${y}`);
    }
  }

  const seen = new Set<string>();
  const queue: Array<[number, number]> = [[map.spawn.x, map.spawn.y]];
  seen.add(`${map.spawn.x},${map.spawn.y}`);
  while (queue.length > 0) {
    const [x, y] = queue.shift()!;
    for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]] as const) {
      const nx = x + dx;
      const ny = y + dy;
      const key = `${nx},${ny}`;
      if (seen.has(key)) continue;
      if (!isWalkable(map, nx, ny)) continue;
      if (hasNpcAt(map, nx, ny)) continue;
      seen.add(key);
      queue.push([nx, ny]);
    }
  }
  assert.ok(seen.has("788,722"), "spawn should reach Route 1 tall grass");
  assert.ok(seen.has("788,700"), "spawn should reach the northern part of Route 1");

  let grassTiles = 0;
  for (let y = 0; y < map.height; y++) {
    for (let x = 0; x < map.width; x++) {
      if (isTallGrass(map, x, y)) grassTiles++;
    }
  }
  assert.ok(grassTiles >= 150, `seamless world needs grass on both Route 1 cells, got ${grassTiles}`);
});

test("spawn points are walkable and free of NPCs", () => {
  for (const map of Object.values(maps)) {
    assert.ok(isWalkable(map, map.spawn.x, map.spawn.y), `${map.id} spawn`);
    assert.equal(hasNpcAt(map, map.spawn.x, map.spawn.y), false, `${map.id} spawn npc`);
  }
});

test("town is safe; the routes have encounter grass", () => {
  assert.equal(maps.town.encounter, undefined);
  assert.ok(maps.route1.encounter);
  assert.ok(maps.grove.encounter);
  assert.ok(maps.unova_full.encounterZones);
  for (const mapId of ["route1", "grove", "unova_full"]) {
    const map = maps[mapId];
    let grassTiles = 0;
    for (let y = 0; y < map.height; y++) {
      for (let x = 0; x < map.width; x++) {
        if (isTallGrass(map, x, y)) grassTiles++;
      }
    }
    assert.ok(grassTiles >= 30, `${mapId} needs a useful amount of grass, got ${grassTiles}`);
  }
});

test("Route 1 uses the ROM grass table and Nuvema has no encounters", () => {
  const route = encounterAt(maps.unova_full, 788, 722);
  assert.ok(route);
  assert.equal(route.rate, 0.1);
  assert.equal(
    route.table.reduce((sum, entry) => sum + entry.weight, 0),
    100
  );
  assert.deepEqual(
    [...new Set(route.table.map((entry) => entry.species))].sort(),
    ["lillipup", "patrat"]
  );
  for (const entry of route.table) {
    assert.ok(entry.minLevel >= 2 && entry.maxLevel <= 4, "Route 1 levels are 2..4");
  }
  assert.equal(encounterAt(maps.unova_full, 784, 753), undefined);
});

test("height-aware movement blocks cliff climbs but allows drops", () => {
  const map = maps.unova_full;
  assert.equal(heightAt(map, 784, 753), 0, "Nuvema's spawn is the flat base level");
  assert.equal(heightAt(map, 789, 647), 0);
  assert.equal(heightAt(map, 790, 647), 40, "the Route 1 ledge is 40 units tall");
  assert.equal(canStep(map, 789, 647, 790, 647), false, "cannot climb the ledge");
  assert.equal(canStep(map, 790, 647, 789, 647), true, "can drop down the ledge");
  assert.equal(heightAt(maps.town, 15, 18), 0, "legacy maps without heights stay flat");
  assert.equal(canStep(maps.town, 14, 18, 15, 18), true);
});

test("npc positions block movement", () => {
  for (const map of Object.values(maps)) {
    for (const npc of map.npcs) {
      assert.ok(isWalkable(map, npc.x, npc.y), `${map.id}/${npc.id} stands on walkable tile`);
      assert.ok(hasNpcAt(map, npc.x, npc.y), `${map.id}/${npc.id} should block`);
    }
  }
});

test("tile windows stream a bounded slice of the seamless map", () => {
  const map = maps.unova_full;
  const window = tileWindow(map, 784, 753, 32);

  assert.equal(window.width, 65);
  assert.equal(window.height, 65);
  assert.equal(window.x, 752);
  assert.equal(window.y, 721);
  assert.equal(window.tiles.length, 65);
  assert.equal(window.tiles[32][32], map.tiles[753][784]);
  for (let y = 0; y < window.height; y++) {
    assert.equal(window.tiles[y].length, 65);
    assert.equal(window.tiles[y], map.tiles[721 + y].slice(752, 817));
  }

  const topLeft = tileWindow(map, 0, 0, 32);
  assert.deepEqual([topLeft.x, topLeft.y, topLeft.width, topLeft.height], [0, 0, 65, 65]);
  const bottomRight = tileWindow(map, map.width - 1, map.height - 1, 32);
  assert.deepEqual(
    [bottomRight.x, bottomRight.y],
    [map.width - 65, map.height - 65]
  );

  const small = tileWindow(maps.town, maps.town.spawn.x, maps.town.spawn.y, 32);
  assert.equal(small.width, maps.town.width);
  assert.equal(small.height, maps.town.height);
  assert.deepEqual(small.tiles, maps.town.tiles);
});

test("tile window refreshes near the edge and AOI uses Chebyshev distance", () => {
  const window = tileWindow(maps.unova_full, 784, 753, 32);
  assert.equal(needsTileWindowRefresh(window, 784, 753, 16), false);
  assert.equal(needsTileWindowRefresh(window, window.x + 16, 753, 16), false);
  assert.equal(needsTileWindowRefresh(window, window.x + 15, 753, 16), true);
  assert.equal(
    needsTileWindowRefresh(window, 784, window.y + window.height - 17, 16),
    false
  );
  assert.equal(
    needsTileWindowRefresh(window, 784, window.y + window.height - 16, 16),
    true
  );

  const here = { mapId: "unova_full", x: 784, y: 753 };
  assert.equal(withinView(here, { mapId: "unova_full", x: 848, y: 817 }, 64), true);
  assert.equal(withinView(here, { mapId: "unova_full", x: 849, y: 753 }, 64), false);
  assert.equal(withinView(here, { mapId: "unova_in_396", x: 784, y: 753 }, 64), false);
});
