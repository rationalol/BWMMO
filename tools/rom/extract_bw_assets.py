#!/usr/bin/env python3
"""Extract Gen 5 battle sprites from a local Pokemon Black/White ROM.

The tool reads the project's content file to map our species ids to national
dex numbers, opens `a/0/0/4` (pokegra), and writes 96x96 front/back PNGs for
the client to load.

This is intentionally a local, personal-use asset pipeline:
- it never downloads or redistributes game assets
- output goes to client/assets/bw/, which is gitignored
- the ROM is supplied by the user

The static battle sprite is stored as 4bpp NCGR tiles. The game uses a fixed
four-quadrant cell layout (from the community-documented BW NCER layout) to
assemble the 96x96 image. Palettes are NCLR files (16 colors, BGR555).

Requires: Python 3.10+, ndspy, Pillow
    pip install ndspy pillow
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import ndspy.narc
    import ndspy.rom
except ImportError:
    print("Missing dependency: pip install ndspy pillow", file=sys.stderr)
    raise

try:
    from PIL import Image
except ImportError:
    print("Missing dependency: pip install ndspy pillow", file=sys.stderr)
    raise


# (x, y, width, height, starting tile) for the 96x96 static sprite.
# This is the fixed single-cell layout used by the shared BW Pokemon NCER,
# as documented by the Gen 5 ROM-hacking community.
QUADRANTS = [
    (0, 0, 64, 64, 0),
    (64, 0, 32, 64, 64),
    (0, 64, 64, 32, 96),
    (64, 64, 32, 32, 128),
]

POKEGRA_NARC = "a/0/0/4"
TRAINER_NARC = "a/0/7/2"
SPRITE_SIZE = 96

# Shared cell layout for the BW trainer front sprites (96x96).
TRAINER_QUADRANTS = [
    (0, 0, 64, 64, 0),
    (64, 0, 16, 32, 64),
    (64, 32, 16, 32, 72),
    (0, 64, 32, 16, 80),
    (32, 64, 32, 16, 88),
    (64, 64, 16, 16, 96),
]


def lz11_decompress(data: bytes) -> bytes:
    """Decode Nintendo LZ11 (0x11) data; return unchanged if not compressed."""
    if not data or data[0] != 0x11:
        return bytes(data)
    if len(data) < 4:
        raise ValueError("truncated LZ11 header")
    out_size = data[1] | (data[2] << 8) | (data[3] << 16)
    out = bytearray()
    pos = 4
    while len(out) < out_size:
        if pos >= len(data):
            raise ValueError("truncated LZ11 stream")
        flags = data[pos]
        pos += 1
        for bit in range(7, -1, -1):
            if len(out) >= out_size:
                break
            if flags & (1 << bit):
                if pos >= len(data):
                    raise ValueError("truncated LZ11 block")
                b1 = data[pos]
                pos += 1
                if (b1 >> 4) == 0:
                    if pos + 1 >= len(data):
                        raise ValueError("truncated LZ11 block")
                    b2, b3 = data[pos], data[pos + 1]
                    pos += 2
                    length = (((b1 & 0xF) << 4) | (b2 >> 4)) + 0x11
                    disp = (((b2 & 0xF) << 8) | b3) + 1
                elif (b1 >> 4) == 1:
                    if pos + 2 >= len(data):
                        raise ValueError("truncated LZ11 block")
                    b2, b3, b4 = data[pos], data[pos + 1], data[pos + 2]
                    pos += 3
                    length = (((b1 & 0xF) << 12) | (b2 << 4) | (b3 >> 4)) + 0x111
                    disp = (((b3 & 0xF) << 8) | b4) + 1
                else:
                    if pos >= len(data):
                        raise ValueError("truncated LZ11 block")
                    b2 = data[pos]
                    pos += 1
                    length = (b1 >> 4) + 1
                    disp = (((b1 & 0xF) << 8) | b2) + 1
                if disp > len(out):
                    raise ValueError("LZ11 back-reference before output start")
                start = len(out) - disp
                for i in range(length):
                    out.append(out[start + i])
            else:
                if pos >= len(data):
                    raise ValueError("truncated LZ11 literal")
                out.append(data[pos])
                pos += 1
    return bytes(out[:out_size])


def parse_ncgr(data: bytes) -> tuple[int, int, int, int, bytes]:
    """Return width_tiles, height_tiles, bpp, data_size, pixel_data."""
    if data[:4] != b"RGCN":
        raise ValueError("not an NCGR file")
    height = int.from_bytes(data[0x18:0x1A], "little")
    width = int.from_bytes(data[0x1A:0x1C], "little")
    bpp = int.from_bytes(data[0x1C:0x20], "little")
    tiled = int.from_bytes(data[0x24:0x28], "little")
    data_size = int.from_bytes(data[0x28:0x2C], "little")
    if width in (0, 0xFFFF) or height in (0, 0xFFFF):
        raise ValueError("NCGR has no explicit dimensions")
    if tiled != 0:
        raise ValueError("expected a non-tiled/static NCGR")
    if bpp != 3:
        raise ValueError(f"expected 4bpp NCGR, got bpp={bpp}")
    return width, height, bpp, data_size, data[0x30:0x30 + data_size]


def parse_nclr(data: bytes) -> list[tuple[int, int, int]]:
    """Return RGB tuples for the first palette (index 0 is transparent)."""
    if data[:4] != b"RLCN":
        raise ValueError("not an NCLR file")
    count = int.from_bytes(data[0x24:0x28], "little")
    if count < 2 or count > 256:
        raise ValueError(f"unexpected NCLR color count {count}")
    raw = data[0x28:0x28 + count * 2]
    colors = []
    for i in range(count):
        value = int.from_bytes(raw[i * 2:i * 2 + 2], "little")
        r5 = value & 0x1F
        g5 = (value >> 5) & 0x1F
        b5 = (value >> 10) & 0x1F
        colors.append((r5 << 3 | r5 >> 2, g5 << 3 | g5 >> 2, b5 << 3 | b5 >> 2))
    return colors


def build_sprite(
    pixel_data: bytes,
    palette: list[tuple[int, int, int]],
    quadrants=QUADRANTS,
    size: int = SPRITE_SIZE,
) -> Image.Image:
    """Assemble a static NCGR using the supplied cell layout."""
    tile_count = len(pixel_data) // 32

    def pixel(tile: int, x: int, y: int) -> tuple[int, int, int, int]:
        index = tile * 64 + y * 8 + x
        byte = pixel_data[index // 2]
        color_index = (byte & 0xF) if index % 2 == 0 else (byte >> 4)
        if color_index == 0:
            return (0, 0, 0, 0)
        rgb = palette[color_index]
        return (rgb[0], rgb[1], rgb[2], 255)

    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pixels = image.load()
    for (ox, oy, w, h, start_tile) in quadrants:
        tw, th = w // 8, h // 8
        for ty in range(th):
            for tx in range(tw):
                tile = start_tile + ty * tw + tx
                if tile >= tile_count:
                    raise ValueError(f"cell layout needs tile {tile}, only {tile_count} available")
                for y in range(8):
                    for x in range(8):
                        color = pixel(tile, x, y)
                        if color[3]:
                            pixels[ox + tx * 8 + x, oy + ty * 8 + y] = color
    return image


def load_narc_file(narc: ndspy.narc.NARC, index: int) -> bytes:
    if index < 0 or index >= len(narc.files):
        raise IndexError(f"NARC file index {index} out of range")
    raw = bytes(narc.files[index])
    if not raw:
        raise ValueError(f"NARC file {index} is empty")
    return lz11_decompress(raw)


def parse_id_list(value: str) -> list[int]:
    ids: list[int] = []
    for part in value.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            start, end = part.split("-", 1)
            ids.extend(range(int(start), int(end) + 1))
        else:
            ids.append(int(part))
    return sorted(set(ids))


def find_rom(path: Path) -> Path:
    if path.is_file():
        return path
    candidates = sorted(path.glob("*.nds"))
    if not candidates:
        raise FileNotFoundError(f"no .nds file found in {path}")
    return candidates[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument("--content", default="server/content/game.json", help="game.json path")
    parser.add_argument("--out", default="client/assets/bw", help="output root")
    parser.add_argument("--only", default="", help="comma-separated species ids")
    parser.add_argument("--trainers", default="0-23", help="trainer id list/range, e.g. 0-23")
    parser.add_argument("--no-trainers", action="store_true", help="skip trainer extraction")
    parser.add_argument("--clean", action="store_true", help="remove existing PNGs first")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    rom_path = find_rom((root / args.rom).resolve() if not Path(args.rom).is_absolute() else Path(args.rom))
    content_path = root / args.content
    out_root = root / args.out
    sprite_dir = out_root / "pokemon"
    sprite_dir.mkdir(parents=True, exist_ok=True)
    trainer_dir = out_root / "trainers"
    trainer_dir.mkdir(parents=True, exist_ok=True)
    if args.clean:
        for old in sprite_dir.glob("*.png"):
            old.unlink()
        for old in trainer_dir.glob("*.png"):
            old.unlink()

    content = json.loads(content_path.read_text(encoding="utf-8"))
    wanted = {s.strip() for s in args.only.split(",") if s.strip()}
    species = content.get("species", {})
    if not species:
        raise SystemExit(f"no species found in {content_path}")

    print(f"ROM:     {rom_path}")
    print(f"Content: {content_path}")
    print(f"Output:  {sprite_dir}")

    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))
    game_code = bytes(rom.idCode).decode("ascii", "replace")
    print(f"Game:    {game_code}")
    if game_code not in {"IRAO", "IRAP", "IREO", "IREP"}:
        print(f"Warning: unexpected game code {game_code}; continuing", file=sys.stderr)

    narc = ndspy.narc.NARC(rom.getFileByName(POKEGRA_NARC))
    manifest = {
        "source": "Pokemon Black/White ROM (local extraction)",
        "tool": "tools/rom/extract_bw_assets.py",
        "species": {},
        "trainers": {},
    }
    extracted = 0

    for species_id, info in species.items():
        if wanted and species_id not in wanted:
            continue
        dex = info.get("dex")
        if not isinstance(dex, int) or dex < 1:
            print(f"skip {species_id}: missing dex", file=sys.stderr)
            continue
        base = dex * 20
        try:
            front_ncgr = load_narc_file(narc, base + 0)
            back_ncgr = load_narc_file(narc, base + 9)
            palette_nclr = bytes(narc.files[base + 18])
            palette = parse_nclr(palette_nclr)
            parse_ncgr(front_ncgr)
            parse_ncgr(back_ncgr)
        except Exception as exc:
            print(f"skip {species_id} (dex {dex}): {exc}", file=sys.stderr)
            continue

        front_data = parse_ncgr(front_ncgr)[4]
        back_data = parse_ncgr(back_ncgr)[4]
        front = build_sprite(front_data, palette)
        back = build_sprite(back_data, palette)
        front_path = sprite_dir / f"{species_id}_front.png"
        back_path = sprite_dir / f"{species_id}_back.png"
        front.save(front_path)
        back.save(back_path)
        manifest["species"][species_id] = {
            "dex": dex,
            "front": f"pokemon/{front_path.name}",
            "back": f"pokemon/{back_path.name}",
        }
        extracted += 1
        print(f"  {species_id:12} dex {dex:3}  front+back")

    if not args.no_trainers:
        trainer_ids = parse_id_list(args.trainers)
        trainer_narc = ndspy.narc.NARC(rom.getFileByName(TRAINER_NARC))
        extracted_trainers = 0
        for trainer_id in trainer_ids:
            base = trainer_id * 8
            if base + 7 >= len(trainer_narc.files):
                continue
            try:
                ncgr_raw = bytes(trainer_narc.files[base])
                if not ncgr_raw:
                    continue
                ncgr = lz11_decompress(ncgr_raw)
                palette = parse_nclr(bytes(trainer_narc.files[base + 7]))
                pixel_data = parse_ncgr(ncgr)[4]
                image = build_sprite(pixel_data, palette, TRAINER_QUADRANTS, 80)
            except Exception as exc:
                print(f"skip trainer {trainer_id}: {exc}", file=sys.stderr)
                continue
            trainer_path = trainer_dir / f"{trainer_id}.png"
            image.save(trainer_path)
            manifest["trainers"][str(trainer_id)] = f"trainers/{trainer_path.name}"
            extracted_trainers += 1
        print(f"Extracted {extracted_trainers} trainer sprites")

    manifest_path = out_root / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Extracted {extracted} species -> {manifest_path}")
    if extracted == 0:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
