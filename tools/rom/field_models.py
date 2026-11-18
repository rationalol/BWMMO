"""Gen 5 field model ids and the object-code table.

Zone entities name NPCs by a `model` id. That id is an object-code row, not a
sprite index: each 0x1C-byte record in `a/0/4/8` describes the field model, and
`resource[0]` (offset 0x10) is the sprite sheet id in `a/0/4/9`.

`FLDMMDL_ObjCodeToTableIndex` rebases ids at 0x1000 and 0x2000; everything below
0xDF maps through unchanged. Object codes 0x2000+ resolve to 0xFFFF00xx, which
are event-driven models without a standalone sheet.
"""

from __future__ import annotations

import struct

import ndspy.rom

from extract_nuvema import read_narc

OBJCODE_NARC = "a/0/4/8"
OBJCODE_RECORD_SIZE = 0x1C
OBJCODE_RESOURCE_OFFSET = 0x10


def objcode_table_index(model_id: int) -> int:
    if model_id < 0xDF:
        return model_id
    if 0x1000 <= model_id < 0x1236:
        return model_id - 0xF21
    if 0x2000 <= model_id < 0x200A:
        return model_id - 0x1CEB
    return 0xA


def load_sprite_table(rom: ndspy.rom.NintendoDSRom) -> list[int]:
    """Sprite ids indexed by object-code row."""
    data = read_narc(rom, OBJCODE_NARC)[0]
    if len(data) < 4:
        raise ValueError("object code table is empty")
    count = struct.unpack_from("<I", data, 0)[0]
    sprites: list[int] = []
    for index in range(count):
        offset = 4 + index * OBJCODE_RECORD_SIZE + OBJCODE_RESOURCE_OFFSET
        if offset + 4 > len(data):
            break
        sprites.append(struct.unpack_from("<I", data, offset)[0])
    return sprites


def sprite_for_model(sprites: list[int], model_id: int) -> int:
    index = objcode_table_index(model_id)
    if not 0 <= index < len(sprites):
        return 0
    sprite = sprites[index]
    # Special/event models (0x2000+) resolve to 0xFFFF00xx and have no
    # standalone sheet; the client falls back to the hero card for those.
    return sprite if sprite < 0x10000 else 0
