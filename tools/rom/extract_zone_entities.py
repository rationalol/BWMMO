#!/usr/bin/env python3
"""Extract Gen 5 zone entities (NPCs, warps, triggers) from a BW ROM.

`a/1/2/5` holds one file per zone. Each file starts with a relative pointer to
initialization scripts followed by four section counts:

    u32 pInitializationScripts
    u8  interactableCount
    u8  npcCount
    u8  warpCount
    u8  triggerCount

Entries follow in that order. Warp positions use the game's 1/16-tile
coordinate space, so one tile is 16 units.

Output: server/content/rom/zone_entities.json (or --out).
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ndspy.rom  # noqa: E402

from extract_nuvema import ZONE_HEADER, find_rom, read_narc  # noqa: E402

INTERACTABLE = struct.Struct("<4HIIi")  # 20 bytes
NPC = struct.Struct("<12HIHHHh")  # 36 bytes
WARP = struct.Struct("<HHBBHhhHHHH")  # 20 bytes
TRIGGER = struct.Struct("<9HhH")  # 22 bytes


def parse_entities(data: bytes) -> dict:
    if len(data) < 8:
        raise ValueError("zone entity file is shorter than its header")
    init_pointer = struct.unpack_from("<I", data, 0)[0]
    interactable_count, npc_count, warp_count, trigger_count = struct.unpack_from(
        "<BBBB", data, 4
    )
    offset = 8
    interactables = []
    npcs = []
    warps = []
    triggers = []

    for _ in range(interactable_count):
        values = INTERACTABLE.unpack_from(data, offset)
        offset += INTERACTABLE.size
        interactables.append(
            {
                "script": values[0],
                "condition": values[1],
                "interactability": values[2],
                "railIndex": values[3],
                "x": values[4],
                "z": values[5],
                "y": values[6],
            }
        )

    for _ in range(npc_count):
        values = NPC.unpack_from(data, offset)
        offset += NPC.size
        npcs.append(
            {
                "id": values[0],
                "model": values[1],
                "movement": values[2],
                "type": values[3],
                "spawnFlag": values[4],
                "script": values[5],
                "faceDirection": values[6],
                "param1": values[7],
                "param2": values[8],
                "param3": values[9],
                "traversalWidth": values[10],
                "traversalHeight": values[11],
                "coordinateSystem": values[12],
                "x": values[13],
                "z": values[14],
                "railY": values[15],
                "y": values[16],
            }
        )

    for _ in range(warp_count):
        values = WARP.unpack_from(data, offset)
        offset += WARP.size
        warps.append(
            {
                "targetZone": values[0],
                "targetWarp": values[1],
                "contactDirection": values[2],
                "transition": values[3],
                "coordinateType": values[4],
                "x": values[5],
                "z": values[6],
                "y": values[7],
                "width": values[8],
                "height": values[9],
                "coordinateSystem": values[10],
            }
        )

    for _ in range(trigger_count):
        values = TRIGGER.unpack_from(data, offset)
        offset += TRIGGER.size
        triggers.append(
            {
                "script": values[0],
                "workReferenceValue": values[1],
                "work": values[2],
                "unknown1": values[3],
                "unknown2": values[4],
                "x": values[5],
                "z": values[6],
                "width": values[7],
                "height": values[8],
                "y": values[9],
                "unknown3": values[10],
            }
        )

    init_offset = 4 + init_pointer
    if init_offset > len(data):
        raise ValueError(f"initialization pointer {init_pointer} is out of range")
    init_scripts = data[init_offset:]

    return {
        "interactables": interactables,
        "npcs": npcs,
        "warps": warps,
        "triggers": triggers,
        "initScriptBytes": len(init_scripts),
        "initScriptsHex": init_scripts.hex(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument(
        "--out",
        default="server/content/rom/zone_entities.json",
        help="output JSON",
    )
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    rom_path = find_rom((root / args.rom).resolve() if not Path(args.rom).is_absolute() else Path(args.rom))
    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))
    headers = read_narc(rom, "a/0/1/2")[0]
    entity_files = read_narc(rom, "a/1/2/5")

    zones = []
    totals = {"interactables": 0, "npcs": 0, "warps": 0, "triggers": 0}
    for zone_id, data in enumerate(entity_files):
        if zone_id * ZONE_HEADER.size + ZONE_HEADER.size > len(headers):
            break
        header = ZONE_HEADER.unpack_from(headers, zone_id * ZONE_HEADER.size)
        try:
            entities = parse_entities(data)
        except (struct.error, ValueError) as error:
            print(f"Warning: zone {zone_id} entities: {error}", file=sys.stderr)
            continue
        zone = {
            "id": zone_id,
            "type": header[0],
            "area": header[2],
            "matrix": header[3],
            "scripts": list(header[4:7]),
            "parent": header[12],
            "coords": list(header[13:17]),
            "initPointer": struct.unpack_from("<I", data, 0)[0],
            **entities,
        }
        zones.append(zone)
        for key in totals:
            totals[key] += len(entities[key])

    out = (root / args.out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        json.dumps(
            {
                "source": "Pokemon Black/White ROM (local extraction)",
                "tileUnits": 16,
                "zones": zones,
                "totals": totals,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {out}")
    print(
        f"{len(zones)} zones: {totals['interactables']} interactables, "
        f"{totals['npcs']} NPCs, {totals['warps']} warps, {totals['triggers']} triggers"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
