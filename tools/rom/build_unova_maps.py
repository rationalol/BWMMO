#!/usr/bin/env python3
"""Build playable indoor maps and door portals from ROM zone entities.

Inputs:
  server/content/rom/zone_entities.json   (extract_zone_entities.py)
  server/content/rom/npc_dialogues.json    (extract_dialogues.py)
  server/content/worlds/unova_full.json    (build_unova_world.py)
  server/content/worlds/unova_indoor.json  (build_unova_indoor_worlds.py)
  server/content/maps/unova_full.json      (existing NPCs preserved)

Outputs:
  server/content/maps/unova_full.json      (fresh collision/visual + portals)
  server/content/maps/unova_in_<zone>.json (one map per walkable indoor scene)

Doors come from `a/1/2/5` warp entries. A warp's coordinates point at the door
tile; the destination is the target warp's own tile in the target zone. Each
portal keeps the source warp's contact direction as `entryDir`, so the server
only uses the door when the player walks into it the same way the ROM expects.
`onWarpTile` is false when the trigger was snapped to the walkable strip in
front of a solid door (the full 1x3/3x1 frontage), which means the player must
press into the door instead of simply stepping onto the trigger tile.
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ndspy.rom

import glb_bounds
from build_unova_world import encounter_table
from extract_nuvema import ZONE_HEADER, find_rom, read_narc
from extract_dialogues import decrypt_text_sections
from field_models import load_sprite_table, sprite_for_model

WALKABLE = set(".,gf=P")
# Some ROM warps sit on surfable water (boats, tower stairs over a pool). The
# tile becomes "P" when it is used as a trigger, so it may be entered on foot.
WARP_TRIGGER = WALKABLE | {"~"}
# Indoor collision comes from the permission grid, which only marks floor and
# walls. Furniture that the original game collides against is a prop mesh, so
# the map builder stamps the tiles each piece of furniture covers. These limits
# keep large scenery (floors, trees, trains, smoke) and flat decor (mats, paper)
# out: only furniture-sized meshes standing on the floor block a tile.
FURNITURE_MIN_HEIGHT = 6.0
FURNITURE_MAX_BASE = 12.0
FURNITURE_MAX_SPAN = 3.2
FURNITURE_MAX_TILES = 12
FURNITURE_COVER = 0.4
FURNITURE_SKIP_PREFIXES = (
    "buill", "thouse", "r4_build", "r5_build",  # building shells
    "pc_01", "c04_football", "searock",  # Pokémon Center exterior scenery
    "yuka",  # floor surfaces
    "warp",  # warp/stair markers: the portal tile must stay usable
    "kemuri",  # smoke and particle planes
    "_test",
)
# Label shown in the dialogue box when the player examines a piece of furniture.
# The ROM's object scripts are separate from the NPC scripts and almost never
# decode through our VM yet, so the map carries this fallback line instead.
FURNITURE_LABELS = {
    "tv": ("TV", "It's a TV."),
    "pc": ("PC", "It's a PC."),
    "pcshelf": ("PC", "It's a PC."),
    "pcmachine": ("PC", "It's a machine."),
    "pcev": ("Machine", "It's a machine."),
    "pcdesk": ("Counter", "It's a counter."),
    "pcchair": ("Chair", "It's a chair."),
    "shelf": ("Bookshelf", "It's a bookshelf."),
    "desk": ("Desk", "It's a desk."),
    "table": ("Table", "It's a table."),
    "bed": ("Bed", "It's a bed."),
    "plant": ("Potted Plant", "It's a potted plant."),
    "vase": ("Vase", "It's a vase."),
    "globe": ("Globe", "It's a globe."),
    "stair": ("Stairs", "It's a staircase."),
    "object": ("Machine", "It's a machine."),
}
FURNITURE_DEFAULT = ("Furniture", "It's furniture.")
ASSETS_ROOT = Path(__file__).resolve().parents[2] / "client" / "assets" / "bw"
# Story/resident NPCs have no event scripts yet and can block narrow indoor
# paths (the Pinwheel Forest entrance crowd did exactly that). Keep only
# functional service NPCs until the story layer exists.
SERVICE_NPC_KINDS = {"healer", "shop", "pc"}
DIRECTIONS = ("down", "up", "left", "right")
CONTACT_TO_DIR = {1: "down", 2: "up", 3: "right", 4: "left"}
APPROACH_DELTA = {"down": (0, 1), "up": (0, -1), "left": (-1, 0), "right": (1, 0)}
OPPOSITE = {"down": "up", "up": "down", "left": "right", "right": "left"}
COLORS = ["#f2b8c6", "#a9d6e5", "#c7f9cc", "#ffd6a5", "#d0bfff", "#ffc9de"]

NUVEMA_NAMES = {
    390: "Player's House",
    391: "Player's House 2F",
    392: "Bianca's House",
    393: "Bianca's House 2F",
    394: "Cheren's House",
    395: "Cheren's House 2F",
    396: "Professor Juniper's Lab",
}


def indoor_map_id(zone: int) -> str:
    return f"unova_in_{zone}"


def nearest_walkable(
    tiles: list[str],
    x: int,
    y: int,
    radius: int = 3,
    accept: set[str] = WALKABLE,
) -> tuple[int, int] | None:
    height = len(tiles)
    width = len(tiles[0]) if height else 0
    if 0 <= x < width and 0 <= y < height and tiles[y][x] in accept:
        return x, y
    for distance in range(1, radius + 1):
        best = None
        for dy in range(-distance, distance + 1):
            for dx in range(-distance, distance + 1):
                if max(abs(dx), abs(dy)) != distance:
                    continue
                nx, ny = x + dx, y + dy
                if not (0 <= nx < width and 0 <= ny < height):
                    continue
                if tiles[ny][nx] not in accept:
                    continue
                score = abs(dx) + abs(dy)
                if best is None or score < best[0]:
                    best = (score, nx, ny)
        if best is not None:
            return best[1], best[2]
    return None


def warp_tiles(
    tiles: list[str], warp: dict
) -> tuple[list[tuple[int, int]], bool]:
    """Walkable tiles a warp covers, and whether they are the warp's own tiles.

    A warp's anchor is the top-left tile in 1/16-tile space and width/height
    count tiles. Side doors are usually 1x3 and building doors 3x1. When the
    doorway is solid in the permission grid, the trigger is the whole walkable
    strip on the contact side of the doorway, so every tile of the original
    doorway accepts the entrance; the second value is false then, so the server
    knows the player is standing at the door rather than in it.

    Surf tiles count as trigger tiles: several ROM warps (boats, the pool in
    Dragonspiral Tower) sit on water, and the builder turns each trigger into
    a walkable "P" tile.
    """
    height = len(tiles)
    width = len(tiles[0]) if height else 0
    ax, ay = warp["x"] // 16, warp["y"] // 16
    fw = max(1, int(warp.get("width", 1)))
    fh = max(1, int(warp.get("height", 1)))
    covered = []
    for y in range(ay, ay + fh):
        if not (0 <= y < height):
            continue
        for x in range(ax, ax + fw):
            if not (0 <= x < width):
                continue
            if tiles[y][x] in WARP_TRIGGER:
                covered.append((x, y))
    if covered:
        return covered, True
    # Solid doorway: the ROM warp covers the full door (1x3 or 3x1), so the
    # contact strip in front of it has the same length. Returning only the
    # nearest tile made side doors require pixel-perfect alignment.
    approach = CONTACT_TO_DIR.get(warp.get("contactDirection"))
    if approach:
        dx, dy = APPROACH_DELTA[approach]
        frontage = []
        for y in range(ay, ay + fh):
            for x in range(ax, ax + fw):
                fx, fy = x - dx, y - dy
                if 0 <= fx < width and 0 <= fy < height and tiles[fy][fx] in WALKABLE:
                    frontage.append((fx, fy))
        if frontage:
            return frontage, False
    snapped = nearest_walkable(tiles, ax, ay, radius=2, accept=WARP_TRIGGER)
    return ([snapped] if snapped is not None else []), False


def scene_kind(map_file: str) -> str:
    name = map_file.rsplit("/", 1)[-1].lower()
    if "labo" in name or "lab" in name:
        return "Laboratory"
    if name.startswith("m_pc") or "pokecenter" in name or "pc_" in name:
        return "Pokémon Center"
    if "shop" in name or "mart" in name:
        return "Poké Mart"
    if "gym" in name:
        return "Gym"
    if name.startswith("m_hh") or name.startswith("m_fh"):
        return "House"
    if "cave" in name or name.startswith("m_cv"):
        return "Cave"
    return "Interior"


def scene_name(scene: dict, zone_names: dict[int, str] | None = None) -> str:
    zone = scene["zone"]
    if zone in NUVEMA_NAMES:
        return NUVEMA_NAMES[zone]
    map_file = scene["visual"]["chunks"][0]["mapFile"] if scene["visual"]["chunks"] else ""
    kind = scene_kind(map_file)
    # Centers keep their functional name: the content tests identify the 14
    # healers through it (and the HUD shows it while inside).
    if kind == "Pokémon Center":
        return kind
    if zone_names and zone_names.get(zone):
        return zone_names[zone]
    return kind


# Separate map matrices also hold outdoor locations (forests, deserts, bridges
# and stadium fields). They need the exterior camera and sky; building rooms
# keep the closer indoor camera. The map model name is the reliable signal:
# m_dun0x/1x outdoor dungeon themes, h0* bridges, and the Black City/White
# Forest/Anville town maps.
OUTDOOR_SCENE_PREFIXES = (
    "m_dun0101",  # Dreamyard
    "m_dun0201", "m_dun0202",  # Pinwheel Forest / Rumination Field
    "m_dun0301",  # Desert Resort
    "m_dun1001",  # Giant Chasm exterior
    "m_dun1801",  # Moor of Icirrus
    "m_dun1901",  # Abundant Shrine
    "m_dun2101",  # Lostlorn Forest
    "h0",  # Skyarrow / Driftveil / Tubeline / Village / Marvelous bridges
    "wf_", "bc_", "t05_",  # White Forest / Black City / Anville Town
    "m_football", "m_baseball", "m_soccer",  # Nimbasa sports fields
)


def scene_is_outdoor(scene: dict) -> bool:
    map_file = scene["visual"]["chunks"][0]["mapFile"] if scene["visual"]["chunks"] else ""
    name = map_file.rsplit("/", 1)[-1].lower()
    return name.startswith(OUTDOOR_SCENE_PREFIXES)


def target_facing(zones: dict[int, dict], target_zone: int, target_warp: int) -> str | None:
    target = zones.get(target_zone)
    if target is None or target_warp >= len(target["warps"]):
        return None
    contact = target["warps"][target_warp]["contactDirection"]
    facing = CONTACT_TO_DIR.get(contact)
    return OPPOSITE.get(facing) if facing else None


def resolve_destination(
    zones: dict[int, dict],
    scenes: dict[int, dict],
    outdoor_tiles: list[str],
    outdoor_zones: set[int],
    target_zone: int,
    target_warp: int,
) -> tuple[str, int, int] | None:
    target = zones.get(target_zone)
    if target is None or target_warp >= len(target["warps"]):
        return None
    warp = target["warps"][target_warp]
    tx, ty = warp["x"] // 16, warp["y"] // 16
    # The overworld matrix is not the only map type with zone type 0: forests,
    # caves and dungeons use the same type on their own matrix. Only route to
    # unova_full when the zone actually exists in the overworld grid.
    if target["type"] == 0 and target_zone in outdoor_zones:
        position = nearest_walkable(outdoor_tiles, tx, ty)
        if position is None:
            return None
        return "unova_full", position[0], position[1]
    scene = scenes.get(target_zone)
    if scene is None:
        return None
    # The arrival tile is the target warp's own tile, which becomes "P" when
    # that warp builds its own portal, so surf tiles are valid arrivals.
    position = nearest_walkable(scene["tiles"], tx, ty, accept=WARP_TRIGGER)
    if position is None:
        return None
    return indoor_map_id(target_zone), position[0], position[1]


def npc_dialogue(
    zone: int, npc: dict, dialogues: dict
) -> tuple[str, list[str], str, list[dict], list[int]]:
    fallback_name, fallback_lines, kind = npc_name(zone, npc)
    profile = (
        dialogues.get("zones", {})
        .get(str(zone), {})
        .get("npcs", {})
        .get(str(npc["id"]))
    )
    if not profile:
        return fallback_name, fallback_lines, kind, [], []
    name = profile.get("name") or fallback_name
    lines = profile.get("lines") or fallback_lines
    variants = profile.get("variants", [])
    set_flags = profile.get("setFlags", [])
    return name, lines, kind, variants, set_flags


def npc_name(zone: int, npc: dict) -> tuple[str, list[str], str]:
    # Every Pokémon Center in BW puts the nurse behind the counter with script
    # 2100 (model 78). The generic indoor fallback used to turn her into a
    # Resident, which left the Center unable to heal.
    if npc.get("script") == 2100:
        return (
            "Nurse Joy",
            [
                "Welcome to the Pokémon Center!",
                "Let me take care of your Pokémon.",
                "There! Your team is fighting fit again."
            ],
            "healer",
        )
    if zone == 396:
        if npc["id"] == 0:
            return (
                "Professor Juniper",
                [
                    "Pokémon are wonderful partners. Take good care of the one you chose!",
                    "The lab is open to every trainer in Unova."
                ],
                "guide",
            )
        if npc["id"] == 4:
            return ("Pokémon", ["Skreet! Skreet!"], "npc")
        return (
            "Lab Assistant",
            ["Professor Juniper is studying how Pokémon grow stronger."],
            "npc",
        )
    if zone == 390 and npc["script"] == 2:
        return (
            "Mom",
            ["Off on an adventure already? Don't forget to say hello to everyone in town!"],
            "healer",
        )
    if zone in (390, 392, 394):
        return (
            "Resident",
            ["Nuvema Town is quiet, but every journey starts somewhere."],
            "npc",
        )
    return (
        "Resident",
        ["Welcome in. The door is always open for traveling trainers."],
        "npc",
    )


def seal_center_counter(tiles: list[list[str]]) -> None:
    """Close the area behind the Pokémon Center counter.

    The ROM permission grid marks the floor inside the U-shaped counter as
    walkable because the counter itself is a prop with its own collision mesh.
    Our indoor collision only reads the permission grid, so without this patch
    the player can step around Nurse Joy into the counter. Keep the nurse's
    own tile walkable for validation and the row in front open for dialogue.
    """
    for y, blocked_x in (
        (8, (5, 9)),
        (9, (4, 5, 9, 10)),
        (10, (5, 6, 8, 9)),
    ):
        if y >= len(tiles):
            continue
        for x in blocked_x:
            if x < len(tiles[y]):
                tiles[y][x] = "#"


def prop_label(filename: str) -> tuple[str, str]:
    stem = filename[:-4] if filename.lower().endswith(".glb") else filename
    base = stem.split("_")[0].rstrip("0123456789")
    return FURNITURE_LABELS.get(base, FURNITURE_DEFAULT)


def furniture_footprint(
    prop: dict,
    chunk: dict,
    visual: dict,
    assets_root: Path,
) -> tuple[set[tuple[int, int]], str, str]:
    """Tiles a placed prop covers, plus the label to show when examined.

    Prop placements are chunk-local; the chunk carries the cell offset the
    client adds to its root node. Rotation is the same Y rotation the client
    applies, so the AABB matches what is drawn.
    """
    name = str(prop.get("file", "")).rsplit("/", 1)[-1].lower()
    if name.startswith(FURNITURE_SKIP_PREFIXES):
        return set(), "", ""
    model = glb_bounds.bounds(assets_root / str(prop.get("file", "")))
    if model is None:
        return set(), "", ""
    (min_x, min_y, min_z), (max_x, max_y, max_z) = model
    if max_y - min_y < FURNITURE_MIN_HEIGHT or min_y > FURNITURE_MAX_BASE:
        return set(), "", ""
    angle = math.radians(float(prop.get("rotation", 0.0)))
    cos_a, sin_a = math.cos(angle), math.sin(angle)
    corners_x: list[float] = []
    corners_z: list[float] = []
    for x in (min_x, max_x):
        for z in (min_z, max_z):
            corners_x.append(x * cos_a + z * sin_a)
            corners_z.append(-x * sin_a + z * cos_a)
    base_x = float(chunk.get("offsetX", 0.0)) + float(prop.get("x", 0.0))
    base_z = float(chunk.get("offsetZ", 0.0)) + float(prop.get("z", 0.0))
    world_x0, world_x1 = base_x + min(corners_x), base_x + max(corners_x)
    world_z0, world_z1 = base_z + min(corners_z), base_z + max(corners_z)
    tile = float(visual.get("tile", 16.0)) or 16.0
    origin_x = float(visual.get("originX", -248.0))
    origin_z = float(visual.get("originZ", -248.0))
    x0, x1 = (world_x0 - origin_x) / tile, (world_x1 - origin_x) / tile
    z0, z1 = (world_z0 - origin_z) / tile, (world_z1 - origin_z) / tile
    if x1 - x0 > FURNITURE_MAX_SPAN or z1 - z0 > FURNITURE_MAX_SPAN:
        return set(), "", ""
    covered: set[tuple[int, int]] = set()
    for tile_y in range(math.floor(z0), math.ceil(z1)):
        for tile_x in range(math.floor(x0), math.ceil(x1)):
            overlap_x = min(x1, tile_x + 1) - max(x0, tile_x)
            overlap_z = min(z1, tile_y + 1) - max(z0, tile_y)
            if overlap_x > 0 and overlap_z > 0 and overlap_x * overlap_z >= FURNITURE_COVER:
                covered.add((tile_x, tile_y))
    if not covered:
        # A prop around one tile wide that straddles a tile corner covers none
        # of the four tiles well; the ROM still treats it as one solid tile.
        covered.add((math.floor((x0 + x1) / 2), math.floor((z0 + z1) / 2)))
    if len(covered) > FURNITURE_MAX_TILES:
        return set(), "", ""
    label, line = prop_label(name)
    return covered, label, line


def stamp_furniture(
    tiles: list[list[str]],
    scene: dict,
    prop_tiles: dict[tuple[int, int], tuple[str, str]],
    reserved: set[tuple[int, int]],
    assets_root: Path,
) -> int:
    """Mark furniture tiles solid, keeping spawn, portals, NPCs and objects.

    `prop_tiles` is also filled here so the interactable records can borrow the
    label of the mesh that sits on their tile.
    """
    visual = scene.get("visual") or {}
    for chunk in visual.get("chunks") or []:
        for prop in chunk.get("props") or []:
            covered, label, line = furniture_footprint(prop, chunk, visual, assets_root)
            for cell in covered:
                prop_tiles.setdefault(cell, (label, line))
    blocked = 0
    for x, y in prop_tiles:
        if not (0 <= y < len(tiles) and 0 <= x < len(tiles[y])):
            continue
        if (x, y) in reserved:
            continue
        if tiles[y][x] not in ".,gf=":
            continue
        tiles[y][x] = "#"
        blocked += 1
    return blocked


def build_indoor_map(
    scene: dict,
    zone_entities: dict[int, dict],
    zones: dict[int, dict],
    scenes: dict[int, dict],
    outdoor_tiles: list[str],
    outdoor_zones: set[int],
    dialogues: dict,
    zone_names: dict[int, str] | None = None,
    npc_sprites: list[int] | None = None,
    encounter: dict | None = None,
) -> dict | None:
    zone = scene["zone"]
    name = scene_name(scene, zone_names)
    tiles = [list(row) for row in scene["tiles"]]
    width, height = scene["width"], scene["height"]
    if name == "Pokémon Center":
        seal_center_counter(tiles)

    spawn = None
    for warp in zone_entities.get(zone, {}).get("warps", []):
        spawn = nearest_walkable(scene["tiles"], warp["x"] // 16, warp["y"] // 16)
        if spawn is not None:
            break
    if spawn is None:
        for y in range(height):
            for x in range(width):
                if tiles[y][x] in WALKABLE:
                    spawn = (x, y)
                    break
            if spawn:
                break
    if spawn is None:
        return None

    portals = []
    used_sources = set()
    for warp in zone_entities.get(zone, {}).get("warps", []):
        covered, on_warp_tile = warp_tiles(scene["tiles"], warp)
        sources = [cell for cell in covered if cell not in used_sources]
        if not sources:
            continue
        destination = resolve_destination(
            zones,
            scenes,
            outdoor_tiles,
            outdoor_zones,
            warp["targetZone"],
            warp["targetWarp"],
        )
        if destination is None:
            continue
        target_map, tx, ty = destination
        facing = target_facing(zones, warp["targetZone"], warp["targetWarp"])
        entry = CONTACT_TO_DIR.get(warp["contactDirection"])
        for sx, sy in sources:
            used_sources.add((sx, sy))
            tiles[sy][sx] = "P"
            portal = {
                "x": sx,
                "y": sy,
                "targetMap": target_map,
                "targetX": tx,
                "targetY": ty,
                "onWarpTile": on_warp_tile,
            }
            if facing:
                portal["targetDir"] = facing
            if entry:
                portal["entryDir"] = entry
            portals.append(portal)

    npcs = []
    occupied = {(spawn[0], spawn[1])} | used_sources
    entities = zone_entities.get(zone, {}).get("npcs", [])
    # Conditional NPCs are separate records in the ROM: a record whose
    # `spawnFlag` is set only appears after that flag is raised, and it usually
    # repeats the model and script of an unflagged one. Zone 390 (the player's
    # house) stores Mom twice — id 0 with spawnFlag 0 at (6,5) and id 3 with
    # spawnFlag 736 at (6,6) — so ignoring the flag put her on two tiles at
    # once. Per-NPC flags are not modelled yet, so keep the unconditional
    # record and drop the flagged copy when it duplicates it.
    unconditional = {
        (entity["model"], entity["script"])
        for entity in entities
        if not entity.get("spawnFlag")
    }
    for entity in entities:
        if entity.get("spawnFlag") and (
            entity["model"],
            entity["script"],
        ) in unconditional:
            continue
        position = nearest_walkable(scene["tiles"], entity["x"], entity["z"], radius=2)
        if position is None or position in occupied:
            continue
        display_name, dialogue, kind, variants, set_flags = npc_dialogue(
            zone, entity, dialogues
        )
        if kind not in SERVICE_NPC_KINDS:
            continue
        npc = {
            "id": f"z{zone}_n{entity['id']}",
            "name": display_name,
            "x": position[0],
            "y": position[1],
            "color": COLORS[entity["model"] % len(COLORS)],
            "kind": kind,
            "sprite": (
                sprite_for_model(npc_sprites, entity["model"])
                if npc_sprites is not None
                else 0
            ),
            "dialogue": dialogue,
            # ROM movement type: 0 stands still, 1 looks around in place, and
            # busier values walk short loops. The client uses anything non-zero
            # as "this NPC idles with animation instead of standing frozen".
            "movement": int(entity.get("movement", 0)),
        }
        if variants:
            npc["dialogueVariants"] = variants
        if set_flags:
            npc["setFlags"] = set_flags
        occupied.add(position)
        npcs.append(npc)

    entries = zone_entities.get(zone, {}).get("interactables") or []
    interactable_tiles = {
        (int(entry["x"]), int(entry["z"]))
        for entry in entries
        if "x" in entry and "z" in entry
    }
    prop_tiles: dict[tuple[int, int], tuple[str, str]] = {}
    blocked = stamp_furniture(
        tiles, scene, prop_tiles, occupied | interactable_tiles, ASSETS_ROOT
    )

    scripts = dialogues.get("zones", {}).get(str(zone), {}).get("scripts", {})
    interactables = []
    unreachable = 0
    seen_objects: set[tuple[int, int, int]] = set()
    for entry in entries:
        x, y = int(entry.get("x", -1)), int(entry.get("z", -1))
        script = int(entry.get("script", 0))
        if script <= 0 or not (0 <= x < width and 0 <= y < height):
            continue
        # Furniture collision can enclose an object (the Pokémon Center mart
        # counter is one); an object the player cannot reach cannot be
        # examined, so it is left out of the map.
        reachable = tiles[y][x] in WALKABLE or any(
            0 <= x + dx < width
            and 0 <= y + dy < height
            and tiles[y + dy][x + dx] in WALKABLE
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))
        )
        if not reachable:
            unreachable += 1
            continue
        key = (x, y, script)
        if key in seen_objects:
            continue
        seen_objects.add(key)
        label, fallback = prop_tiles.get((x, y), FURNITURE_DEFAULT)
        profile = scripts.get(str(script)) or {}
        interactables.append(
            {
                "id": f"z{zone}_o{len(interactables)}",
                "x": x,
                "y": y,
                "script": script,
                "label": label or FURNITURE_DEFAULT[0],
                "dialogue": profile.get("lines") or [fallback],
            }
        )

    map_def = {
        "id": indoor_map_id(zone),
        "name": name,
        "zone": zone,
        "outdoor": scene_is_outdoor(scene),
        "spawn": {"x": spawn[0], "y": spawn[1], "dir": "down"},
        "tiles": ["".join(row) for row in tiles],
        "npcs": npcs,
        "portals": portals,
        "visual": scene["visual"],
    }
    if interactables:
        map_def["interactables"] = interactables
    if encounter:
        map_def["encounter"] = encounter
    map_def["_blockedTiles"] = blocked
    map_def["_unreachableObjects"] = unreachable
    return map_def


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument("--entities", default="server/content/rom/zone_entities.json")
    parser.add_argument("--dialogues", default="server/content/rom/npc_dialogues.json")
    parser.add_argument("--outdoor", default="server/content/worlds/unova_full.json")
    parser.add_argument("--indoor", default="server/content/worlds/unova_indoor.json")
    parser.add_argument("--maps", default="server/content/maps")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    rom_path = find_rom((root / args.rom).resolve() if not Path(args.rom).is_absolute() else Path(args.rom))
    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))
    overworld = read_narc(rom, "a/0/0/9")[0]
    _, _, grid_width, grid_height = struct.unpack_from("<HHHH", overworld, 0)
    models = struct.unpack_from(f"<{grid_width * grid_height}I", overworld, 8)
    zone_grid = struct.unpack_from(
        f"<{grid_width * grid_height}I", overworld, 8 + 4 * grid_width * grid_height
    )
    outdoor_zones = {
        zone for zone, model in zip(zone_grid, models) if zone != 0xFFFFFFFF and model != 0xFFFFFFFF
    }

    entity_data = json.loads((root / args.entities).read_text(encoding="utf-8"))
    dialogue_path = (root / args.dialogues).resolve()
    if dialogue_path.exists():
        dialogue_data = json.loads(dialogue_path.read_text(encoding="utf-8"))
    else:
        dialogue_data = {"zones": {}}
        print(f"Warning: {dialogue_path} missing; using fallback NPC dialogue")
    zones = {zone["id"]: zone for zone in entity_data["zones"]}
    zone_data = read_narc(rom, "a/0/1/2")[0]
    location_text = decrypt_text_sections(read_narc(rom, "a/0/0/2")[89])
    zone_names: dict[int, str] = {}
    game = json.loads((root / "server" / "content" / "game.json").read_text(encoding="utf-8"))
    species_by_dex = {
        species["dex"]: species_id
        for species_id, species in game.get("species", {}).items()
    }
    encounter_tables = read_narc(rom, "a/1/2/6")
    encounters: dict[int, dict] = {}
    for zone_id in zones:
        header = ZONE_HEADER.unpack_from(zone_data, zone_id * ZONE_HEADER.size)
        text_index = header[14] & 0xFF
        if text_index < len(location_text) and location_text[text_index]:
            zone_names[zone_id] = location_text[text_index]
        table = encounter_table(rom, header, species_by_dex, encounter_tables)
        if table:
            encounters[zone_id] = {"rate": 0.1, "table": table}
    scene_data = json.loads((root / args.indoor).read_text(encoding="utf-8"))
    scenes = {scene["zone"]: scene for scene in scene_data["scenes"]}
    outdoor_world = json.loads((root / args.outdoor).read_text(encoding="utf-8"))
    outdoor_tiles = list(outdoor_world["tiles"])

    maps_dir = (root / args.maps).resolve()
    existing_outdoor_path = maps_dir / "unova_full.json"
    existing_outdoor = (
        json.loads(existing_outdoor_path.read_text(encoding="utf-8"))
        if existing_outdoor_path.exists()
        else {}
    )

    indoor_maps = {}
    skipped = 0
    portal_count = 0
    blocked_total = 0
    object_count = 0
    unreachable_total = 0
    npc_sprites = load_sprite_table(rom)
    for scene in scene_data["scenes"]:
        map_def = build_indoor_map(
            scene,
            zones,
            zones,
            scenes,
            outdoor_tiles,
            outdoor_zones,
            dialogue_data,
            zone_names,
            npc_sprites,
            encounters.get(scene["zone"]),
        )
        if map_def is None:
            skipped += 1
            continue
        blocked_total += map_def.pop("_blockedTiles", 0)
        unreachable_total += map_def.pop("_unreachableObjects", 0)
        object_count += len(map_def.get("interactables", []))
        indoor_maps[map_def["id"]] = map_def
        portal_count += len(map_def["portals"])

    outdoor_portals = []
    used_sources = set()
    for zone_id in sorted(outdoor_zones):
        zone = zones.get(zone_id)
        if zone is None or zone["type"] != 0:
            continue
        for warp in zone["warps"]:
            covered, on_warp_tile = warp_tiles(outdoor_tiles, warp)
            sources = [cell for cell in covered if cell not in used_sources]
            if not sources:
                continue
            destination = resolve_destination(
                zones,
                scenes,
                outdoor_tiles,
                outdoor_zones,
                warp["targetZone"],
                warp["targetWarp"],
            )
            if destination is None:
                continue
            target_map, tx, ty = destination
            if target_map.startswith("unova_in_") and int(target_map.rsplit("_", 1)[1]) not in {
                map_def["zone"] for map_def in indoor_maps.values()
            }:
                continue
            facing = target_facing(zones, warp["targetZone"], warp["targetWarp"])
            entry = CONTACT_TO_DIR.get(warp["contactDirection"])
            for sx, sy in sources:
                used_sources.add((sx, sy))
                outdoor_tiles[sy] = outdoor_tiles[sy][:sx] + "P" + outdoor_tiles[sy][sx + 1:]
                portal = {
                    "x": sx,
                    "y": sy,
                    "targetMap": target_map,
                    "targetX": tx,
                    "targetY": ty,
                    "onWarpTile": on_warp_tile,
                }
                if facing:
                    portal["targetDir"] = facing
                if entry:
                    portal["entryDir"] = entry
                outdoor_portals.append(portal)

    outdoor_map = {
        **existing_outdoor,
        "id": "unova_full",
        "name": "Unova",
        "spawn": outdoor_world["spawn"],
        "tiles": outdoor_tiles,
        "npcs": existing_outdoor.get("npcs", []),
        "portals": outdoor_portals,
        "encounterZones": outdoor_world.get("encounterZones", []),
        "visual": outdoor_world["visual"],
    }
    outdoor_map.pop("width", None)
    outdoor_map.pop("height", None)
    existing_outdoor_path.write_text(json.dumps(outdoor_map, indent=2) + "\n", encoding="utf-8")

    replaced = 0
    for path in maps_dir.glob("unova_in_*.json"):
        zone = int(path.stem.rsplit("_", 1)[1])
        if zone not in {map_def["zone"] for map_def in indoor_maps.values()}:
            path.unlink()
            replaced += 1
    for map_def in indoor_maps.values():
        path = maps_dir / f"{map_def['id']}.json"
        path.write_text(json.dumps(map_def, indent=2) + "\n", encoding="utf-8")

    print(
        f"Wrote {len(indoor_maps)} indoor maps ({skipped} scenes skipped, "
        f"{portal_count} indoor portals, {blocked_total} furniture tiles blocked, "
        f"{object_count} examine targets, {unreachable_total} enclosed objects dropped), "
        f"unova_full with {len(outdoor_portals)} portals"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
