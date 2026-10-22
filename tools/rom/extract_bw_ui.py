#!/usr/bin/env python3
"""Extract original Black/White UI assets for the local client.

Outputs (all under client/assets/bw/ui, which is gitignored):
- window_frame.png: the game's 9-slice window frame, recoloured for the
  client's dark HUD (the geometry and bevel are the ROM's; only the palette is
  remapped so the panel fill matches the rest of the interface).
- bw_font.png / bw_font.fnt: the BW font converted to a BMFont atlas. Godot
  imports the .fnt as a FontFile, so labels can use the original glyphs.
- ui_manifest.json: source archive and palette notes.

The frame comes from ARCID_WINFRAME (a/0/0/5): file 10 is the 9-slice NCGR,
file 0 its palette. The font comes from ARCID_FONT (a/0/2/3), file 0.

Requires: ndspy, Pillow. The ROM is only read locally; extracted assets are not
redistributed by this repository.
"""

from __future__ import annotations

import argparse
import json
import struct
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


WINDOW_ARCHIVE = "a/0/0/5"
FONT_ARCHIVE = "a/0/2/3"
ITEM_ICON_ARCHIVE = "a/0/2/5"
TYPE_ICON_ARCHIVE = "a/0/8/3"
TYPE_ICON_NCLR = 33
TYPE_ICON_FIRST = 34
TYPE_NAMES = [
    "Normal", "Fighting", "Flying", "Poison", "Ground", "Rock", "Bug",
    "Ghost", "Steel", "Fire", "Water", "Grass", "Electric", "Psychic",
    "Ice", "Dragon", "Dark"
]
TYPE_PALETTE_INDEX = [0, 0, 1, 1, 0, 0, 2, 1, 0, 0, 1, 2, 0, 1, 1, 2, 0]
ITEM_ICON_INDICES = {
    "master_ball": (2, 3),
    "ultra_ball": (4, 5),
    "great_ball": (6, 7),
    "poke_ball": (8, 9),
}
FRAME_NCGR = 10
FRAME_NCLR = 0
FONT_FILE = 0

# Palette used by the frame's NCGR. The ROM's first colour is the DS colour key
# used for the area outside the window.
FRAME_COLORS = {
    (156, 214, 99): (0, 0, 0, 0),        # outside
    (165, 165, 165): (30, 51, 62, 255),  # outer bevel
    (198, 198, 198): (13, 25, 38, 245),  # panel fill
    (214, 214, 214): (52, 95, 79, 255),  # inner bevel
    (255, 255, 255): (110, 231, 164, 255),  # highlight
    (0, 0, 0): (5, 10, 17, 255),
}

# Characters the HUD needs beyond ASCII. They are looked up in the font's
# character maps; unsupported ones are skipped.
EXTRA_CODEPOINTS = {
    0x00D7: "×",
    0x00E9: "é",
    0x2026: "…",
    0x2605: "★",
    0x2642: "♂",
    0x2640: "♀",
    0x2192: "→",
}


def read_narc(rom, path: str) -> list[bytes]:
    return [bytes(entry) for entry in ndspy.narc.NARC(rom.getFileByName(path)).files]


def parse_nclr(data: bytes) -> list[list[tuple[int, int, int]]]:
    if data[:4] != b"RLCN":
        raise ValueError("not an NCLR file")
    data_size = int.from_bytes(data[0x20:0x24], "little")
    raw = data[0x28:0x28 + data_size]
    palettes: list[list[tuple[int, int, int]]] = []
    for start in range(0, len(raw), 32):
        chunk = raw[start:start + 32]
        if len(chunk) < 32:
            break
        colors = []
        for index in range(16):
            value = chunk[index * 2] | (chunk[index * 2 + 1] << 8)
            r5, g5, b5 = value & 31, (value >> 5) & 31, (value >> 10) & 31
            colors.append((r5 << 3 | r5 >> 2, g5 << 3 | g5 >> 2, b5 << 3 | b5 >> 2))
        palettes.append(colors)
    return palettes


def parse_ncgr(data: bytes) -> tuple[int, int, bytes]:
    if data[:4] != b"RGCN":
        raise ValueError("not an NCGR file")
    width = int.from_bytes(data[0x1A:0x1C], "little")
    height = int.from_bytes(data[0x18:0x1A], "little")
    data_size = int.from_bytes(data[0x28:0x2C], "little")
    if width in (0, 0xFFFF) or height in (0, 0xFFFF):
        raise ValueError("NCGR has no tile dimensions")
    return width, height, data[0x30:0x30 + data_size]


def decode_tile(pixel_data: bytes, tile: int, palette) -> Image.Image:
    image = Image.new("RGBA", (8, 8), (0, 0, 0, 0))
    pixels = image.load()
    for y in range(8):
        for x in range(8):
            byte = pixel_data[tile * 32 + y * 4 + (x // 2)]
            color_index = (byte & 0xF) if x % 2 == 0 else (byte >> 4)
            rgb = palette[color_index]
            pixels[x, y] = FRAME_COLORS.get(rgb, (8, 16, 26, 255))
    return image


def extract_window_frame(rom, out_dir: Path) -> dict:
    entries = read_narc(rom, WINDOW_ARCHIVE)
    palettes = parse_nclr(entries[FRAME_NCLR])
    _, _, pixel_data = parse_ncgr(entries[FRAME_NCGR])
    palette = palettes[0]

    # The game draws a 3x3 frame from nine consecutive tiles. Keep the centre
    # tile as the panel fill; the outside (DS colour key) becomes transparent.
    image = Image.new("RGBA", (24, 24), (0, 0, 0, 0))
    for tile in range(9):
        image.alpha_composite(decode_tile(pixel_data, tile, palette), ((tile % 3) * 8, (tile // 3) * 8))

    # The game fills the window's interior separately; tile 4 is not a uniform
    # fill in the source atlas, so replace it with the panel colour before the
    # texture is used as a scalable 9-slice.
    pixels = image.load()
    fill = (13, 25, 38, 245)
    for y in range(8, 16):
        for x in range(8, 16):
            pixels[x, y] = fill

    # One-pixel outer rule keeps the panel readable where the original art is
    # transparent outside the colour key.
    rule = (42, 74, 88, 255)
    for x in range(24):
        for y in (0, 23):
            if pixels[x, y][3] == 0:
                pixels[x, y] = rule
    for y in range(24):
        for x in (0, 23):
            if pixels[x, y][3] == 0:
                pixels[x, y] = rule

    path = out_dir / "window_frame.png"
    image.save(path)

    # Overlay variant: transparent centre, so the panel's glass background and
    # shadow stay visible underneath while the ROM frame supplies the bevel.
    overlay = image.copy()
    overlay_pixels = overlay.load()
    for y in range(8, 16):
        for x in range(8, 16):
            overlay_pixels[x, y] = (0, 0, 0, 0)
    overlay_path = out_dir / "window_frame_overlay.png"
    overlay.save(overlay_path)

    return {
        "path": "client/assets/bw/ui/window_frame.png",
        "overlay_path": "client/assets/bw/ui/window_frame_overlay.png",
        "source": f"{WINDOW_ARCHIVE}[{FRAME_NCGR}]",
        "palette": f"{WINDOW_ARCHIVE}[{FRAME_NCLR}] palette 0",
        "size": [24, 24],
        "texture_margin": 8,
    }


def extract_type_icons(rom, out_dir: Path) -> dict:
    entries = read_narc(rom, TYPE_ICON_ARCHIVE)
    palettes = parse_nclr(entries[TYPE_ICON_NCLR])
    icon_dir = out_dir / "types"
    icon_dir.mkdir(parents=True, exist_ok=True)
    written = {}
    for index, type_name in enumerate(TYPE_NAMES):
        ncgr = entries[TYPE_ICON_FIRST + index]
        data_size = int.from_bytes(ncgr[0x28:0x2C], "little")
        pixel_data = ncgr[0x30:0x30 + data_size]
        palette = palettes[TYPE_PALETTE_INDEX[index]]
        image = Image.new("RGBA", (32, 16), (0, 0, 0, 0))
        for tile in range(min(8, len(pixel_data) // 32)):
            image.alpha_composite(
                decode_item_tile(pixel_data, tile, palette),
                ((tile % 4) * 8, (tile // 4) * 8)
            )
        path = icon_dir / f"{type_name.lower()}.png"
        image.save(path)
        written[type_name] = f"client/assets/bw/ui/types/{type_name.lower()}.png"
    return written

def extract_item_icons(rom, out_dir: Path) -> dict:
    entries = read_narc(rom, ITEM_ICON_ARCHIVE)
    icon_dir = out_dir / "items"
    icon_dir.mkdir(parents=True, exist_ok=True)
    written = {}
    for name, (ncgr_index, nclr_index) in ITEM_ICON_INDICES.items():
        palettes = parse_nclr(entries[nclr_index])
        ncgr = entries[ncgr_index]
        data_size = int.from_bytes(ncgr[0x28:0x2C], "little")
        pixel_data = ncgr[0x30:0x30 + data_size]
        tiles = len(pixel_data) // 32
        columns = 4
        rows = max(1, (tiles + columns - 1) // columns)
        image = Image.new("RGBA", (columns * 8, rows * 8), (0, 0, 0, 0))
        for tile in range(tiles):
            image.alpha_composite(
                decode_item_tile(pixel_data, tile, palettes[0]),
                ((tile % columns) * 8, (tile // columns) * 8)
            )
        path = icon_dir / f"{name}.png"
        image.save(path)
        written[name] = f"client/assets/bw/ui/items/{name}.png"
    return written

def decode_item_tile(pixel_data: bytes, tile: int, palette) -> Image.Image:
    image = Image.new("RGBA", (8, 8), (0, 0, 0, 0))
    pixels = image.load()
    for y in range(8):
        for x in range(8):
            byte = pixel_data[tile * 32 + y * 4 + (x // 2)]
            color_index = (byte & 0xF) if x % 2 == 0 else (byte >> 4)
            if color_index == 0:
                continue
            rgb = palette[color_index]
            pixels[x, y] = (rgb[0], rgb[1], rgb[2], 255)
    return image

def parse_font_info(data: bytes) -> dict:
    font_type, line_feed, alter, left, default_glyph, default_char, encoding = struct.unpack_from(
        "<BBHBBBB", data, 0x18
    )
    glyph_offset, width_offset, map_offset = struct.unpack_from("<III", data, 0x20)
    cell_width, cell_height, cell_size = struct.unpack_from("<BBH", data, glyph_offset)
    baseline = struct.unpack_from("<b", data, glyph_offset + 4)[0]
    _, bpp, _ = struct.unpack_from("<BBB", data, glyph_offset + 5)
    return {
        "font_type": font_type,
        "line_feed": line_feed,
        "alter": alter,
        "default_left": left,
        "default_glyph_width": default_glyph,
        "default_char_width": default_char,
        "encoding": encoding,
        "glyph_offset": glyph_offset,
        "width_offset": width_offset,
        "map_offset": map_offset,
        "cell_width": cell_width,
        "cell_height": cell_height,
        "cell_size": cell_size,
        "baseline": baseline,
        "bpp": bpp,
        "glyphs_offset": glyph_offset + 8,
    }


def parse_character_maps(data: bytes, map_offset: int) -> list[dict]:
    """Read the CMAP chain.

    The ROM's maps have a 12-byte map header (first, last, method, next) and
    the payload starts at +12. The header is 16 bytes in the SDK struct; this
    ROM stores the direct offset in the last four bytes of that space.
    """
    maps: list[dict] = []
    offset = map_offset
    seen: set[int] = set()
    while offset and offset not in seen and offset + 12 <= len(data) and len(maps) < 64:
        seen.add(offset)
        first, last, method, reserved, next_offset = struct.unpack_from("<HHHHI", data, offset)
        payload = offset + 12
        maps.append({
            "first": first,
            "last": last,
            "method": method,
            "next": next_offset,
            "payload": payload,
        })
        offset = next_offset
    return maps


def char_to_glyph(data: bytes, maps: list[dict], codepoint: int) -> int | None:
    for entry in maps:
        first, last, method, payload = entry["first"], entry["last"], entry["method"], entry["payload"]
        if not (first <= codepoint <= last):
            continue
        if method == 0:
            if payload + 2 > len(data):
                return None
            base = struct.unpack_from("<H", data, payload)[0]
            if base == 0xFFFF:
                return None
            return base + codepoint - first
        if method == 1:
            offset = payload + (codepoint - first) * 2
            if offset + 2 > len(data):
                return None
            index = struct.unpack_from("<H", data, offset)[0]
            return None if index == 0xFFFF else index
        if method == 2:
            if payload + 2 > len(data):
                return None
            count = struct.unpack_from("<H", data, payload)[0]
            for index in range(count):
                offset = payload + 2 + index * 4
                if offset + 4 > len(data):
                    break
                char, glyph = struct.unpack_from("<HH", data, offset)
                if char == codepoint:
                    return None if glyph == 0xFFFF else glyph
            return None
    return None


def read_glyph(data: bytes, info: dict, glyph_index: int) -> tuple[int, int, int, int, list[list[int]]]:
    cell = data[
        info["glyphs_offset"] + glyph_index * info["cell_size"]:
        info["glyphs_offset"] + (glyph_index + 1) * info["cell_size"]
    ]
    if len(cell) < info["cell_size"]:
        raise ValueError(f"glyph {glyph_index} outside the glyph block")
    x_offset, width, advance = cell[0], cell[1], cell[2]
    bitmap = cell[3:]
    cell_width = info["cell_width"]
    row_bytes = (cell_width * 2 + 7) // 8
    rows: list[list[int]] = []
    for y in range(info["cell_height"]):
        row = []
        for x in range(cell_width):
            bit = x * 2
            value = (bitmap[y * row_bytes + bit // 8] >> (6 - (bit % 8))) & 3
            row.append(value)
        rows.append(row)
    return x_offset, width, advance, info["cell_height"], rows


def extract_font(rom, out_dir: Path) -> dict:
    entries = read_narc(rom, FONT_ARCHIVE)
    data = entries[FONT_FILE]
    info = parse_font_info(data)
    if info["bpp"] != 2:
        raise ValueError(f"unexpected font bpp {info['bpp']}")
    maps = parse_character_maps(data, info["map_offset"])

    codepoints = list(range(0x20, 0x7F)) + list(EXTRA_CODEPOINTS)
    glyphs: list[dict] = []
    for codepoint in codepoints:
        glyph_index = char_to_glyph(data, maps, codepoint)
        if glyph_index is None:
            continue
        x_offset, width, advance, height, rows = read_glyph(data, info, glyph_index)
        xs = [x for row in rows for x, value in enumerate(row) if value]
        if not xs:
            glyphs.append({
                "codepoint": codepoint,
                "glyph": glyph_index,
                "width": 1,
                "height": 1,
                "xoffset": 0,
                "yoffset": 0,
                "advance": advance,
                "rows": [],
                "crop_x": 0,
            })
            continue
        left, right = min(xs), max(xs)
        glyphs.append({
            "codepoint": codepoint,
            "glyph": glyph_index,
            "width": right - left + 1,
            "height": height,
            "xoffset": left,
            "yoffset": 0,
            "advance": advance,
            "rows": rows,
            "crop_x": left,
        })

    cell_w = max([glyph["width"] for glyph in glyphs] + [1])
    cell_h = info["cell_height"]
    columns = 16
    rows_count = (len(glyphs) + columns - 1) // columns
    atlas = Image.new("RGBA", (columns * (cell_w + 1), rows_count * (cell_h + 1)), (0, 0, 0, 0))
    atlas_pixels = atlas.load()
    char_lines: list[str] = []

    for index, glyph in enumerate(glyphs):
        cell_x = (index % columns) * (cell_w + 1)
        cell_y = (index // columns) * (cell_h + 1)
        left = glyph["crop_x"]
        for y, row in enumerate(glyph["rows"]):
            for x in range(glyph["width"]):
                if row[left + x]:
                    # Keep all ink opaque so the glyph stays legible when the
                    # font is tinted light on the dark HUD.
                    atlas_pixels[cell_x + x, cell_y + y] = (255, 255, 255, 255)
        char_lines.append(
            "char id={id} x={x} y={y} width={w} height={h} xoffset={xo} yoffset={yo} "
            "xadvance={adv} page=0 chnl=15".format(
                id=glyph["codepoint"],
                x=cell_x,
                y=cell_y,
                w=glyph["width"],
                h=glyph["height"],
                xo=glyph["xoffset"],
                yo=glyph["yoffset"],
                adv=glyph["advance"],
            )
        )

    png_path = out_dir / "bw_font.png"
    fnt_path = out_dir / "bw_font.fnt"
    atlas.save(png_path)
    fnt_path.write_text(
        "\n".join(
            [
                'info face="BW" size={size} bold=0 italic=0 charset="" unicode=1 '
                "stretchH=100 smooth=0 aa=1 padding=0,0,0,0 spacing=1,1".format(size=cell_h),
                "common lineHeight={line} base={base} scaleW={width} scaleH={height} pages=1 packed=0".format(
                    line=cell_h, base=max(1, cell_h - 3), width=atlas.width, height=atlas.height
                ),
                'page id=0 file="bw_font.png"',
                f"chars count={len(char_lines)}",
                *char_lines,
                "kernings count=0",
                "",
            ]
        ),
        encoding="utf-8",
    )
    return {
        "path": "client/assets/bw/ui/bw_font.fnt",
        "source": f"{FONT_ARCHIVE}[{FONT_FILE}]",
        "glyphs": len(char_lines),
        "native_size": cell_h,
        "atlas": [atlas.width, atlas.height],
    }


def write_scaled_font(out_dir: Path, scale: int) -> dict:
    """Write a nearest-neighbour scaled copy of the BW bitmap font.

    Bitmap fonts are crisp only at their native size. The battle UI uses the
    2x copy so names and HP numbers stay pixel-perfect instead of being
    filtered from the 15 px atlas.
    """
    import re

    src_atlas = Image.open(out_dir / "bw_font.png").convert("RGBA")
    atlas = src_atlas.resize(
        (src_atlas.width * scale, src_atlas.height * scale), Image.NEAREST
    )
    png_name = f"bw_font_{scale}x.png"
    atlas.save(out_dir / png_name)

    char_pattern = re.compile(r"(x|y|width|height|xoffset|yoffset|xadvance)=(-?\d+)")
    lines: list[str] = []
    for line in (out_dir / "bw_font.fnt").read_text(encoding="utf-8").splitlines():
        if line.startswith("info "):
            line = re.sub(r"size=\d+", f"size={15 * scale}", line)
        elif line.startswith("common "):
            line = re.sub(r"lineHeight=\d+", f"lineHeight={15 * scale}", line)
            line = re.sub(r"base=\d+", f"base={12 * scale}", line)
            line = re.sub(r"scaleW=\d+", f"scaleW={atlas.width}", line)
            line = re.sub(r"scaleH=\d+", f"scaleH={atlas.height}", line)
        elif line.startswith("page "):
            line = re.sub(r'file="[^"]+"', f'file="{png_name}"', line)
        elif line.startswith("char "):
            line = char_pattern.sub(
                lambda match: f"{match.group(1)}={int(match.group(2)) * scale}", line
            )
        lines.append(line)
    fnt_name = f"bw_font_{scale}x.fnt"
    (out_dir / fnt_name).write_text("\n".join(lines) + "\n", encoding="utf-8")
    return {
        "path": f"client/assets/bw/ui/{fnt_name}",
        "atlas": [atlas.width, atlas.height],
        "native_size": 15 * scale,
    }


def find_rom(value: str) -> Path:
    path = Path(value)
    if path.is_file():
        return path
    candidates = sorted(path.glob("*.nds"))
    if not candidates:
        raise FileNotFoundError(f"no .nds file found in {path}")
    return candidates[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or a directory containing it")
    parser.add_argument("--out", default="client/assets/bw/ui", help="output directory")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    rom_path = find_rom(args.rom if Path(args.rom).is_absolute() else str((root / args.rom).resolve()))
    out_dir = (root / args.out).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))
    print(f"ROM:  {rom_path}")
    print(f"Out:  {out_dir}")
    frame = extract_window_frame(rom, out_dir)
    font = extract_font(rom, out_dir)
    font_2x = write_scaled_font(out_dir, 2)
    font_3x = write_scaled_font(out_dir, 3)
    item_icons = extract_item_icons(rom, out_dir)
    type_icons = extract_type_icons(rom, out_dir)
    manifest = {
        "source": "Pokemon Black/White ROM (local extraction)",
        "window_frame": frame,
        "font": font,
        "font_2x": font_2x,
        "font_3x": font_3x,
        "item_icons": item_icons,
        "type_icons": type_icons,
        "note": "Personal-use assets. client/assets/bw is gitignored.",
    }
    (out_dir / "ui_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"window frame: {frame['source']} -> {frame['path']}")
    print(f"font:         {font['source']} -> {font['path']} ({font['glyphs']} glyphs)")
    print(f"font 2x:      {font_2x['path']}")
    print(f"font 3x:      {font_3x['path']}")
    print(f"item icons:   {', '.join(item_icons.keys())}")
    print(f"type icons:   {len(type_icons)} types")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
