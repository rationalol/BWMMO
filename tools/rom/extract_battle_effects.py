#!/usr/bin/env python3
"""Extract Gen 5 move-animation scripts and SPA particle textures.

The battle engine in `a/0/6/6` stores one script per move. Each script is a
list of timed commands: camera moves, particle spawns, projectiles, sprite
shakes, screen color changes, sound cues and waits. The particles themselves
live in `a/0/0/6`: every effect has a small APS header followed by one or more
TPS texture blocks (an 8-bit coverage mask followed by a BGR555 palette).

This tool writes a runtime-friendly manifest and one horizontal atlas per
effect. The Godot client walks the original scripts and instantiates the
original textures, so move timing, target selection, projectile paths and
secondary hit effects come from the ROM rather than a hand-written table.

The output is local, personal-use data and goes under the gitignored
`client/assets/bw/` tree. It is not redistributed with the project.
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ndspy.rom  # noqa: E402
from PIL import Image  # noqa: E402

from extract_nuvema import find_rom, read_narc  # noqa: E402

MOVE_ANIMATION_NARC = "a/0/6/6"
PARTICLE_NARC = "a/0/0/6"
MOVE_COUNT = 559
TPS_HEADER_SIZE = 0x20

# Opcode names and argument counts from the Gen 5 battle-animation script
# format. IDs not listed here are not emitted by the game's move scripts.
COMMANDS: list[tuple[str, int]] = [
    ("MoveCamera", 5),
    ("AdjustCamera", 10),
    ("Cmd2", 6),
    ("ShakeScreen", 6),
    ("Cmd4", 2),
    ("Cmd5", 0),
    ("LoadSPA", 1),
    ("PlaySPAAnimation", 11),
    ("PlaySPAScreenAnimation", 15),
    ("PlaySPAAnimation2", 11),
    ("CmdA", 10),
    ("CmdB", 1),
    ("PlaySPAProjectile", 11),
    ("PlaySPAProjectile2", 13),
    ("PlaySPAProjectile3", 11),
    ("CmdF", 13),
    ("PlaySPACircle", 10),
    ("Cmd11", 10),
    ("ShakeSprite", 7),
    ("MoveSprite", 9),
    ("Cmd14", 6),
    ("DistortSprite", 7),
    ("TiltSprite", 6),
    ("SpriteOpacity", 6),
    ("Cmd18", 6),
    ("Cmd19", 4),
    ("FreezeSprite", 2),
    ("ChangeColor", 5),
    ("ChangeVisibility", 2),
    ("Cmd1D", 2),
    ("Cmd1E", 7),
    ("Cmd1F", 1),
    ("Cmd20", 5),
    ("Cmd21", 8),
    ("Cmd22", 2),
    ("Cmd23", 1),
    ("LoadBackground", 1),
    ("MoveBackground", 6),
    ("DistortBackground", 6),
    ("Cmd27", 2),
    ("Cmd28", 1),
    ("Cmd29", 6),
    ("ChangeBackgroundColor", 5),
    ("ApplyBackground", 2),
    ("Cmd2C", 7),
    ("Cmd2D", 7),
    ("Cmd2E", 7),
    ("Cmd2F", 7),
    ("Cmd30", 2),
    ("Cmd31", 5),
    ("Cmd32", 1),
    ("Cmd33", 2),
    ("PlaySound", 9),
    ("Cmd35", 1),
    ("SwitchAudioSide", 8),
    ("AdjustSound", 9),
    ("WaitForCommands", 1),
    ("Wait", 1),
    ("AudioContainer", 1),
    ("CheckMoveUser", 4),
    ("Cmd3C", 4),
    ("Cmd3D", 3),
    ("Cmd3E", 1),
    ("Cmd3F", 1),
    ("Cmd40", 2),
    ("Cmd41", 1),
    ("Cmd42", 7),
    ("PlayPokemonCry", 7),
    ("Cmd44", 1),
    ("Cmd45", 6),
    ("Cmd46", 3),
    ("Cmd47", 0),
    ("CheckMoveUserElse", 1),
    ("Cmd49", 0),
    ("CallMoveAnimation", 1),
    ("Cmd4B", 1),
    ("Cmd4C", 1),
    ("End", 0),
]

# Commands the client actually renders. Sound and background commands are
# omitted so the manifest stays small; their timing is already represented by
# the surrounding Wait/WaitForCommands commands.
SERIALISED_COMMANDS = {
    "MoveCamera",
    "AdjustCamera",
    "ShakeScreen",
    "LoadSPA",
    "PlaySPAAnimation",
    "PlaySPAScreenAnimation",
    "PlaySPAAnimation2",
    "PlaySPAProjectile",
    "PlaySPAProjectile2",
    "PlaySPAProjectile3",
    "PlaySPACircle",
    "ShakeSprite",
    "MoveSprite",
    "DistortSprite",
    "TiltSprite",
    "SpriteOpacity",
    "FreezeSprite",
    "ChangeColor",
    "ChangeVisibility",
    "WaitForCommands",
    "Wait",
    "CheckMoveUser",
    "CheckMoveUserElse",
    "CallMoveAnimation",
    "End",
}

PARTICLE_COMMANDS = {
    "PlaySPAAnimation",
    "PlaySPAScreenAnimation",
    "PlaySPAAnimation2",
    "PlaySPAProjectile",
    "PlaySPAProjectile2",
    "PlaySPAProjectile3",
    "PlaySPACircle",
}


def u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def s32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<i", data, offset)[0]


def parse_sequences(data: bytes, move_id: int) -> list[list[list[int]]]:
    """Return move sequences as [[[opcode, args...], ...], ...]."""
    if len(data) < 4:
        return []
    count = u32(data, 0)
    if count <= 0 or count > 16 or 4 + count * 56 > len(data):
        raise ValueError(f"move {move_id}: invalid sequence count {count}")
    sequences: list[list[list[int]]] = []
    for sequence_index in range(count):
        position = u32(data, 4 + 56 * sequence_index)
        if position < 4 + count * 56 or position >= len(data):
            raise ValueError(f"move {move_id}: bad sequence offset {position:#x}")
        commands: list[list[int]] = []
        while position < len(data):
            if position + 2 > len(data):
                raise ValueError(f"move {move_id}: truncated opcode")
            command_id = struct.unpack_from("<H", data, position)[0]
            if command_id >= len(COMMANDS):
                raise ValueError(f"move {move_id}: unknown opcode {command_id:#x}")
            _name, argc = COMMANDS[command_id]
            end = position + 2 + argc * 4
            if end > len(data):
                raise ValueError(f"move {move_id}: truncated command {command_id:#x}")
            args = [
                s32(data, position + 2 + index * 4)
                for index in range(argc)
            ]
            commands.append([command_id, *args])
            position = end
            if command_id == 0x4D:
                break
        # A handful of call-only sequences end at EOF instead of carrying an
        # explicit End command (for example the multi-hit dispatcher on move
        # 290). Treat EOF as an implicit return.
        if not commands or commands[-1][0] != 0x4D:
            commands.append([0x4D])
        sequences.append(commands)
    return sequences


def tps_blocks(data: bytes) -> list[dict]:
    """Find and decode every TPS block in one SPA effect file."""
    blocks = []
    position = 0
    while True:
        position = data.find(b" TPS", position)
        if position < 0:
            break
        if position + TPS_HEADER_SIZE > len(data):
            break
        fields = struct.unpack_from("<8I", data, position)
        texture_size = fields[2]
        palette_size = fields[4]
        block_size = fields[5]
        payload_start = position + TPS_HEADER_SIZE
        if (
            texture_size <= 0
            or palette_size <= 0
            or block_size < TPS_HEADER_SIZE
            or payload_start + texture_size + palette_size > len(data)
            or position + block_size > len(data)
        ):
            position += 1
            continue
        mask = data[payload_start:payload_start + texture_size]
        palette_raw = data[
            payload_start + texture_size:payload_start + texture_size + palette_size
        ]
        palette = []
        for offset in range(0, len(palette_raw) - 1, 2):
            value = struct.unpack_from("<H", palette_raw, offset)[0]
            red = (value & 0x1F) << 3
            green = ((value >> 5) & 0x1F) << 3
            blue = ((value >> 10) & 0x1F) << 3
            palette.append((
                red | (red >> 5),
                green | (green >> 5),
                blue | (blue >> 5),
            ))
        while len(palette) > 1 and palette[-1] == (0, 0, 0):
            palette.pop()
        blocks.append({
            "mask": mask,
            "palette": palette or [(255, 255, 255)],
            "size": texture_size,
        })
        position += max(block_size, TPS_HEADER_SIZE)
    return blocks


def texture_dimensions(size: int) -> tuple[int, int]:
    """Choose the natural, nearly-square layout for an 8-bit mask."""
    root = math.isqrt(size)
    if root * root == size:
        return root, root
    best: tuple[int, int] | None = None
    for width in range(1, 257):
        if size % width != 0:
            continue
        height = size // width
        if height > 256:
            continue
        if best is None:
            best = (width, height)
            continue
        if abs(math.log(width / height)) < abs(math.log(best[0] / best[1])):
            best = (width, height)
    return best or (size, 1)


def mask_to_rgba(mask: bytes, palette: list[tuple[int, int, int]]) -> Image.Image:
    width, height = texture_dimensions(len(mask))
    # Most impact/dust effects use a one-colour white palette. For those the
    # mask is pure coverage. Colour ramps (fire, embers, bubbles) map coverage
    # to the original BGR555 gradient.
    single_colour = len(palette) <= 1 or len(set(palette)) == 1
    if single_colour:
        colour = palette[0] if palette else (255, 255, 255)
        if colour == (0, 0, 0):
            colour = (255, 255, 255)
        fill = bytes((colour[0], colour[1], colour[2]))
        alpha = bytes(min(255, int(value * 1.15)) for value in mask)
        rgba = bytearray(len(mask) * 4)
        rgba[0::4] = bytes((colour[0],)) * len(mask)
        rgba[1::4] = bytes((colour[1],)) * len(mask)
        rgba[2::4] = bytes((colour[2],)) * len(mask)
        rgba[3::4] = alpha
        return Image.frombytes("RGBA", (width, height), bytes(rgba))

    palette_count = len(palette)
    lookup = bytearray(256)
    for value in range(256):
        index = min(palette_count - 1, value * palette_count // 256)
        colour = palette[index]
        lookup[value] = index
    rgba = bytearray(len(mask) * 4)
    for index, value in enumerate(mask):
        colour = palette[lookup[value]]
        rgba[index * 4] = colour[0]
        rgba[index * 4 + 1] = colour[1]
        rgba[index * 4 + 2] = colour[2]
        rgba[index * 4 + 3] = min(255, int(value * 1.15))
    return Image.frombytes("RGBA", (width, height), bytes(rgba))


def build_effect_atlas(effect_id: int, blocks: list[dict], out_dir: Path) -> dict:
    images = [mask_to_rgba(block["mask"], block["palette"]) for block in blocks]
    atlas_width = sum(image.width for image in images)
    atlas_height = max(image.height for image in images)
    atlas = Image.new("RGBA", (atlas_width, atlas_height), (0, 0, 0, 0))
    frames = []
    x = 0
    for image in images:
        atlas.alpha_composite(image, (x, 0))
        frames.append([x, 0, image.width, image.height])
        x += image.width
    file_name = f"effect_{effect_id:03d}.png"
    atlas.save(out_dir / file_name, optimize=False, compress_level=3)
    return {
        "file": file_name,
        "frames": frames,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument(
        "--out",
        default="client/assets/bw/battle_effects",
        help="output directory",
    )
    parser.add_argument("--check", action="store_true", help="validate without writing")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    rom_path = find_rom(
        (root / args.rom).resolve()
        if not Path(args.rom).is_absolute()
        else Path(args.rom)
    )
    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))
    scripts = read_narc(rom, MOVE_ANIMATION_NARC)
    particles = read_narc(rom, PARTICLE_NARC)
    if len(scripts) <= MOVE_COUNT:
        raise SystemExit(
            f"{MOVE_ANIMATION_NARC} has {len(scripts)} scripts; expected >{MOVE_COUNT}"
        )

    move_manifest: dict[str, dict] = {}
    referenced_effects: set[int] = set()
    problems: list[str] = []
    for move_id in range(1, MOVE_COUNT + 1):
        try:
            sequences = parse_sequences(scripts[move_id], move_id)
        except ValueError as error:
            problems.append(str(error))
            continue
        serialised_sequences = []
        for sequence in sequences:
            serialised = []
            for command in sequence:
                command_id = int(command[0])
                name, argc = COMMANDS[command_id]
                if name not in SERIALISED_COMMANDS:
                    continue
                values = [int(value) for value in command[1:1 + argc]]
                serialised.append([name, *values])
                if name == "LoadSPA" and values:
                    referenced_effects.add(values[0])
                if name in PARTICLE_COMMANDS and values:
                    referenced_effects.add(values[0])
            serialised_sequences.append(serialised)
        move_manifest[str(move_id)] = {"sequences": serialised_sequences}

    referenced_effects = {
        effect_id
        for effect_id in referenced_effects
        if 0 <= effect_id < len(particles)
    }
    if problems:
        print(f"Skipped {len(problems)} malformed scripts:", file=sys.stderr)
        for problem in problems[:10]:
            print(f"  {problem}", file=sys.stderr)

    effect_manifest: dict[str, dict] = {}
    effect_blocks: dict[int, list[dict]] = {}
    for effect_id in sorted(referenced_effects):
        blocks = tps_blocks(particles[effect_id])
        if not blocks:
            problems.append(f"effect {effect_id}: no TPS textures")
            continue
        effect_blocks[effect_id] = blocks

    if args.check:
        referenced_particles = 0
        for move in move_manifest.values():
            for sequence in move["sequences"]:
                for command in sequence:
                    if command[0] in PARTICLE_COMMANDS:
                        referenced_particles += 1
        print(
            "Battle effect check passed: "
            f"{len(move_manifest)} moves, "
            f"{len(effect_blocks)} effects, "
            f"{referenced_particles} particle spawns, "
            f"{sum(len(v) for v in effect_blocks.values())} textures"
        )
        if problems:
            print(f"{len(problems)} problems:", file=sys.stderr)
            for problem in problems[:20]:
                print(f"  {problem}", file=sys.stderr)
            return 1
        return 0

    out_dir = root / args.out
    out_dir.mkdir(parents=True, exist_ok=True)
    # Remove old atlases so renamed effects do not leave stale files behind.
    for old in out_dir.glob("effect_*.png"):
        old.unlink()

    for effect_id, blocks in effect_blocks.items():
        effect_manifest[str(effect_id)] = build_effect_atlas(effect_id, blocks, out_dir)

    manifest = {
        "source": "Pokemon Black/White ROM (local extraction)",
        "moveScriptNarc": MOVE_ANIMATION_NARC,
        "particleNarc": PARTICLE_NARC,
        "moves": move_manifest,
        "effects": effect_manifest,
    }
    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    atlas_bytes = sum(
        path.stat().st_size for path in out_dir.glob("effect_*.png")
    )
    print(
        f"Wrote {len(effect_manifest)} effect atlases "
        f"({atlas_bytes / 1024 / 1024:.1f} MiB) and a {len(move_manifest)}-move manifest to "
        f"{out_dir}."
    )
    if problems:
        print(f"{len(problems)} problems:", file=sys.stderr)
        for problem in problems[:20]:
            print(f"  {problem}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
