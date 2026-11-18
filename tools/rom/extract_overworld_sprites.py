#!/usr/bin/env python3
"""Extract Gen 5 overworld NPC sprite sheets from a BW ROM.

`a/0/4/9` is the field map-model texture archive: every entry is a BTX0
holding a 32x32 sprite sheet (walk/idle frames for people, Pokémon and a few
props). Zone-entity `model` ids do **not** index that archive directly; they
index the 0x1C-byte object-code table in `a/0/4/8`, whose `resource[0]` field
is the sprite id. For model ids below 0xDF the table index is the model id
itself (`FLDMMDL_ObjCodeToTableIndex`; ids 0x1000+ are rebased).

    model 78 (Pokémon Center nurse) -> sprite 83 (t4x4pcwoman)
    model 147 (Mom)                 -> sprite 144
    model 7   (Cheren)              -> sprite 12
    model 134 (Bianca)              -> sprite 135

The default run reads the generated `unova_*` maps and the story packs and
extracts every NPC sprite id they reference (4 and above; 0-3 are player
actors). Pass --ids to extract specific sprite ids instead, or --models to
extract by field model id.

Output (gitignored, local personal use only):

    client/assets/bw/overworld/npc_<id>/frames/frame_XX.png
    client/assets/bw/overworld/npc_<id>/actor.json
    client/assets/bw/overworld/manifest.json

The actor.json format matches the field actors under
`client/assets/bw/nuvema/actors`, so the 3D client can load both through the
same SpriteFrames path.

This reader is stdlib-only: the NDS filesystem/NARC/BTX0 decoders live in the
local aletheia source tree (`.tools/aletheia_src/tools`), so no `ndspy`
install is required.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ALETHEIA = ROOT / ".tools" / "aletheia_src" / "tools"
sys.path.insert(0, str(ALETHEIA))
sys.path.insert(0, str(ALETHEIA / "assets"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

# Shared with tools/rom/audit_assets.py so the extractor's self-check and the
# audit cannot drift apart.
from sprite_frames import face_offset  # noqa: E402

try:
    import ndsrom  # noqa: E402  (NDS header / FNT / FAT reader)
    import narc  # noqa: E402  (NARC archive reader)
    import nsbmd  # noqa: E402  (BTX0/TEX0 texture decoder)
except ImportError as error:  # pragma: no cover - environment guard
    raise SystemExit(
        "Missing local ROM readers. Expected the aletheia tools at "
        f"{ALETHEIA} (tools/ndsrom.py, tools/assets/narc.py, "
        "tools/assets/nsbmd.py).\n"
        f"Import error: {error}"
    )

SPRITE_NARC = "a/0/4/9"
OBJCODE_NARC = "a/0/4/8"
OBJCODE_RECORD_SIZE = 0x1C
OBJCODE_RESOURCE_OFFSET = 0x10
SPRITE_PLAYER_MAX = 3


def find_rom(value: str) -> Path:
    path = Path(value)
    if path.is_file():
        return path
    if path.is_dir():
        candidates = sorted(path.glob("*.nds"))
        if candidates:
            return candidates[0]
    for candidate in sorted(ROOT.glob("*.nds")):
        return candidate
    raise SystemExit(f"No .nds ROM found in {path} or {ROOT}")


def read_narc(rom: bytes, path: str) -> narc.Narc:
    fnt_off, fnt_size, fat_off, fat_size = struct.unpack_from("<IIII", rom, 0x40)
    files = dict(ndsrom.parse_fnt(rom, fnt_off, fnt_size))
    file_id = files.get(path)
    if file_id is None:
        raise SystemExit(f"ROM has no file {path!r}")
    fat = ndsrom.parse_fat(rom, fat_off, fat_size)
    start, end = fat[file_id]
    return narc.parse(rom[start:end], path=path)


def subfile(archive: narc.Narc, index: int) -> bytes:
    raw = archive.read(index)
    _, decoded = narc.try_decompress(raw)
    return decoded if decoded is not None else raw


def sprite_table(archive: narc.Narc) -> list[int]:
    """Sprite ids indexed by object-code row (the `model` id space)."""
    data = subfile(archive, 0)
    count = struct.unpack_from("<I", data, 0)[0]
    sprites: list[int] = []
    for index in range(count):
        offset = 4 + index * OBJCODE_RECORD_SIZE + OBJCODE_RESOURCE_OFFSET
        if offset + 4 > len(data):
            break
        sprite = struct.unpack_from("<I", data, offset)[0]
        sprites.append(sprite if sprite < 0x10000 else 0)
    return sprites


def objcode_table_index(model_id: int) -> int:
    if model_id < 0xDF:
        return model_id
    if 0x1000 <= model_id < 0x1236:
        return model_id - 0xF21
    if 0x2000 <= model_id < 0x200A:
        return model_id - 0x1CEB
    return 0xA


def direction_layout(
    frame_count: int, sheet_name: str
) -> tuple[dict[str, tuple[int, ...]], bool]:
    """Direction groups for a Gen 5 walk sheet, plus whether right is mirrored.

    Verified frame by frame against the extracted PNGs (see
    ``docs/research/field_actor_model.md``); the layouts are:

    - 12/14/16/20-frame sheets (``t4x4cycle``, ``t4x4x14``, ``t4x4x20``,
      ``t4x4nflip``): three frames per direction, **up 0-2, down 3-5,
      left 6-8, right 9-11**. Left comes first — reading it as right is the
      bug that made every NPC walk backwards.
    - 7-frame ``t4x4flip`` and 9-frame ``t4x4pcwoman``: two frames for up and
      down, three for the side, and the sheet holds **only the left side**;
      the game mirrors it for right.

    Returns ``(groups, mirror_right)``; ids are 0-based texture indices.
    """
    flip = sheet_name.startswith("t4x4flip") or sheet_name.startswith("t4x4pcwoman")
    if flip and frame_count >= 7:
        layout = {"up": (0, 1), "down": (2, 3), "left": (4, 5, 6)}
        return _clip_layout(layout, frame_count), True
    if frame_count >= 12:
        layout = {
            "up": (0, 1, 2),
            "down": (3, 4, 5),
            "left": (6, 7, 8),
            "right": (9, 10, 11),
        }
        return _clip_layout(layout, frame_count), False
    # Unknown short sheet: assume the two/three frame pattern with one side
    # drawn, which at least keeps horizontal movement on a real side sprite.
    layout = {"up": (0, 1), "down": (2, 3), "left": (4, 5)}
    return _clip_layout(layout, frame_count), True


def _clip_layout(
    layout: dict[str, tuple[int, ...]], frame_count: int
) -> dict[str, tuple[int, ...]]:
    return {
        name: tuple(min(index, frame_count - 1) for index in frames)
        for name, frames in layout.items()
    }


def animations_for(
    frame_count: int, sheet_name: str
) -> tuple[dict[str, list[int]], bool]:
    """Build the actor.json animation table for one sheet.

    The second value says whether the right side was mirrored from the left;
    ``extract_sprite`` then writes those mirrored frames and rewrites the right
    animations to point at them.
    """
    groups, mirror_right = direction_layout(frame_count, sheet_name)
    up, down, left = groups["up"], groups["down"], groups["left"]
    right = groups.get("right", left)
    animations = {
        "idle_down": list(down[:1]),
        "walk_down": list(down),
        "idle_up": list(up[:1]),
        "walk_up": list(up),
        "idle_left": list(left[:1]),
        "walk_left": list(left),
        "idle_right": list(right[:1]),
        "walk_right": list(right),
    }
    return animations, mirror_right


def with_transparency(rgba: bytes, record, texel_region: bytes) -> bytes:
    """Make palette index 0 transparent.

    Field sprite sheets use a solid green as their backdrop; the color lives
    in palette slot 0 and is not meant to be drawn. The TEX0 record's
    color0-transparent bit is not set on every sheet (Cheren's, for one), so
    keying off index 0 is what actually reproduces the in-game cutout.
    """
    if record.format not in (2, 3, 4):
        return rgba
    texel = texel_region[record.offset:record.offset + texture_size(record)]
    count = record.width * record.height
    out = bytearray(rgba)
    if record.format == 3:
        for byte_index, value in enumerate(texel):
            for sub, index in enumerate((value & 0x0F, value >> 4)):
                pixel = byte_index * 2 + sub
                if pixel < count and index == 0:
                    out[pixel * 4 + 3] = 0
    elif record.format == 2:
        for byte_index, value in enumerate(texel):
            for sub in range(4):
                pixel = byte_index * 4 + sub
                if pixel < count and ((value >> (sub * 2)) & 3) == 0:
                    out[pixel * 4 + 3] = 0
    else:  # format 4: one 8-bit palette index per pixel
        for pixel, value in enumerate(texel[:count]):
            if value == 0:
                out[pixel * 4 + 3] = 0
    return bytes(out)


def texture_size(record) -> int:
    bits = {1: 8, 2: 2, 3: 4, 4: 8, 6: 8}.get(record.format, 4)
    return record.width * record.height * bits // 8


def mirror_rgba(rgba: bytes, width: int, height: int) -> bytes:
    out = bytearray(len(rgba))
    stride = width * 4
    for row in range(height):
        start = row * stride
        line = rgba[start : start + stride]
        for x in range(width):
            out[start + (width - 1 - x) * 4 : start + (width - x) * 4] = line[
                x * 4 : x * 4 + 4
            ]
    return bytes(out)


def extract_sprite(out: Path, sprite_id: int, entry: bytes) -> dict:
    container = nsbmd.parse_container(entry)
    tex0 = nsbmd.find_tex0(container)
    textures = nsbmd.decode_all_textures(tex0)
    if not textures:
        raise ValueError("sprite archive has no texture")
    texel_region = tex0.texel_bytes()
    sheet_name = textures[0][0].name.split(".")[0]
    key = f"npc_{sprite_id}"
    sprite_dir = out / key
    frames_dir = sprite_dir / "frames"

    images: list[tuple[int, int, bytes]] = []
    for record, _palette, rgba, _ratio in textures:
        if record.width != 32 or record.height != 32:
            raise ValueError(f"unexpected frame size {record.width}x{record.height}")
        images.append((record.width, record.height, with_transparency(rgba, record, texel_region)))

    animations, mirror_right = animations_for(len(images), sheet_name)
    if mirror_right:
        # "flip" sheets only draw the left side; the original mirrors it. Append
        # the mirrored frames so the client can keep using frame indices.
        side = list(animations["walk_left"])
        mirrored: dict[int, int] = {}
        for source in side:
            width, height, rgba = images[source]
            mirrored[source] = len(images)
            images.append((width, height, mirror_rgba(rgba, width, height)))
        animations["walk_right"] = [mirrored[index] for index in side]
        animations["idle_right"] = [mirrored[side[0]]]

    # Self-check: the extracted frames must actually face the way the layout
    # claims. Runs only when the sprite has skin pixels; Pokémon sheets are
    # skipped. Getting this backwards is invisible until someone watches an NPC
    # walk sideways, so fail loudly instead.
    def offset_of(index: int) -> float | None:
        width, height, rgba = images[index]
        return face_offset(rgba, width, height)

    left_offset = offset_of(animations["walk_left"][0])
    right_offset = offset_of(animations["walk_right"][0])
    if left_offset is not None and right_offset is not None:
        if left_offset > -0.02 or right_offset < 0.02:
            raise ValueError(
                f"direction check failed (left {left_offset:+.2f}, "
                f"right {right_offset:+.2f}); the sheet layout changed"
            )

    frames_dir.mkdir(parents=True, exist_ok=True)
    for old in frames_dir.glob("frame_*.png"):
        old.unlink()
    for index, (width, height, rgba) in enumerate(images, start=1):
        nsbmd.write_png_rgba8(
            str(frames_dir / f"frame_{index:02d}.png"),
            width,
            height,
            rgba,
        )

    actor = {
        "source": f"{SPRITE_NARC}[{sprite_id}] {sheet_name}",
        "key": key,
        "frameSize": 32,
        # These tables are 0-based texture indices, unlike the Nuvema player
        # actor tables; the client adds this offset when building PNG paths.
        "frameOffset": 1,
        "sheetFrames": len(textures),
        "mirrored": mirror_right,
        "animations": animations,
    }
    (sprite_dir / "actor.json").write_text(
        json.dumps(actor, indent=2) + "\n", encoding="utf-8"
    )
    extra = f" +{len(images) - len(textures)} mirrored" if mirror_right else ""
    print(f"  {key:<10} {sheet_name:<24} {len(textures):>2} frames{extra}")
    return {
        "name": sheet_name,
        "frames": len(images),
        "sheetFrames": len(textures),
        "mirrored": mirror_right,
        "dir": f"{key}/frames",
    }


def collect_sprite_ids(maps_dir: Path, story_dir: Path, max_sprite: int) -> set[int]:
    ids: set[int] = set()

    def scan(path: Path) -> None:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return
        for npc in data.get("npcs", []):
            value = npc.get("sprite")
            if isinstance(value, int) and SPRITE_PLAYER_MAX < value <= max_sprite:
                ids.add(value)

    for path in sorted(maps_dir.glob("*.json")):
        scan(path)
    if story_dir.is_dir():
        for path in sorted(story_dir.glob("*.json")):
            scan(path)
    return ids


def merge_manifest(out: Path, extracted: dict[str, dict]) -> None:
    path = out / "manifest.json"
    manifest: dict[str, dict] = {}
    if path.is_file():
        try:
            manifest = json.loads(path.read_text(encoding="utf-8")).get("sprites", {})
        except (OSError, json.JSONDecodeError):
            manifest = {}
    manifest.update(extracted)
    payload = {
        "source": f"{SPRITE_NARC} field sprite sheets (object codes {OBJCODE_NARC})",
        "sprites": dict(sorted(manifest.items(), key=lambda item: int(item[0]))),
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument(
        "--out", default="client/assets/bw/overworld", help="output directory"
    )
    parser.add_argument(
        "--maps",
        default="server/content/maps",
        help="scan these maps for NPC sprite ids",
    )
    parser.add_argument(
        "--story",
        default="server/content/story",
        help="scan these story packs for NPC sprite ids",
    )
    parser.add_argument(
        "--ids", default="", help="comma-separated sprite ids to extract"
    )
    parser.add_argument(
        "--models", default="", help="comma-separated field model ids to resolve"
    )
    args = parser.parse_args()

    rom_path = find_rom(args.rom)
    out = (ROOT / args.out).resolve()
    maps_dir = (ROOT / args.maps).resolve()
    story_dir = (ROOT / args.story).resolve()

    print(f"ROM:   {rom_path}")
    print(f"Output:{out}")
    rom = rom_path.read_bytes()
    sprites = read_narc(rom, SPRITE_NARC)
    objcodes = read_narc(rom, OBJCODE_NARC)

    ids = {int(value) for value in args.ids.split(",") if value.strip()}
    if args.models.strip():
        table = sprite_table(objcodes)
        for value in args.models.split(","):
            value = value.strip()
            if not value:
                continue
            model_id = int(value)
            index = objcode_table_index(model_id)
            sprite = table[index] if 0 <= index < len(table) else 0
            print(f"  model {model_id} -> sprite {sprite}")
            if sprite > SPRITE_PLAYER_MAX:
                ids.add(sprite)
    if not ids and not args.models.strip():
        ids = collect_sprite_ids(maps_dir, story_dir, sprites.file_count - 1)
    if not ids:
        print("No NPC sprite ids to extract (pass --ids/--models).", file=sys.stderr)
        return 1

    out.mkdir(parents=True, exist_ok=True)
    extracted: dict[str, dict] = {}
    for sprite_id in sorted(ids):
        if not 0 <= sprite_id < sprites.file_count:
            print(f"Warning: sprite {sprite_id} outside archive", file=sys.stderr)
            continue
        try:
            extracted[str(sprite_id)] = extract_sprite(
                out, sprite_id, subfile(sprites, sprite_id)
            )
        except (ValueError, nsbmd.Nsbmd0Error) as error:
            print(f"Warning: sprite {sprite_id}: {error}", file=sys.stderr)

    merge_manifest(out, extracted)
    print(f"Extracted {len(extracted)} sprite sheets -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
