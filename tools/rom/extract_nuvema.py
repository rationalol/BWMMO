#!/usr/bin/env python3
"""Extract Nuvema Town (Pokemon Black/White) and build a Godot-ready 3D scene.

This reconstructs the starting town from the user's own ROM:

- overworld map matrix (a/0/0/9) -> Nuvema Town cell
- terrain chunk model (a/0/0/8) -> BMD0
- house/lab/sign/plant props (a/2/2/9) -> BMD0 per resource id
- terrain textures (a/0/1/4) and prop textures (a/1/7/6)
- prop placements from the chunk's prop section
- glTF/PNG conversion through Apicula

Output: client/assets/bw/nuvema/ (gitignored, personal use only).

Requires: ndspy, Pillow, and an Apicula executable.
    pip install ndspy pillow
    apicula extract ...  # or pass --apicula path to this script
"""

from __future__ import annotations

import argparse
import json
import shutil
import struct
import subprocess
import sys
from pathlib import Path

try:
    import ndspy.model
    import ndspy.narc
    import ndspy.rom
    from PIL import Image
except ImportError:
    print("Missing dependency: pip install ndspy pillow", file=sys.stderr)
    raise

NUVEMA_CELL = (24, 23)
NUVEMA_FLY = (782, 0, 750)
ZONE_HEADER = struct.Struct("<BBHHHHH4HHHHHHHHHiii")
AREA_RECORD = struct.Struct("<HHBBBBBB")
NONE = 0xFFFFFFFF

# The terrain height data of a WB/GC chunk. Every 8-byte permission entry is
# also a MapHeightTile:
#   u16 shape:2 | slope:14, u16 offset, u32 tileType:31 | diagonal:1
# A shape-0 tile is one plane; a shape-2 tile is two planes (MapHeightSplit,
# 8 bytes: slope0, slope1, offset0, offset1) cut along a diagonal. The slope
# and offset fields index two global tables in the field overlay. In BW1 USA/
# Europe that overlay starts with this exact pair of flat normals, 329 fx16
# normals later the fx32 plane-offset table starts 0x7B8 bytes after it.
HEIGHT_SLOPE_SIGNATURE = struct.pack("<6h", 0, 0xFFE, 0, -0xB4F, 0xB4F, 0)
HEIGHT_OFFSET_GAP = 0x7B8
HEIGHT_SLOPE_ENTRIES = 329
HEIGHT_OFFSET_ENTRIES = 1400


def u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def lz11_decompress(data: bytes) -> bytes:
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
                    b2, b3 = data[pos], data[pos + 1]
                    pos += 2
                    length = (((b1 & 0xF) << 4) | (b2 >> 4)) + 0x11
                    disp = (((b2 & 0xF) << 8) | b3) + 1
                elif (b1 >> 4) == 1:
                    b2, b3, b4 = data[pos], data[pos + 1], data[pos + 2]
                    pos += 3
                    length = (((b1 & 0xF) << 12) | (b2 << 4) | (b3 >> 4)) + 0x111
                    disp = (((b3 & 0xF) << 8) | b4) + 1
                else:
                    b2 = data[pos]
                    pos += 1
                    length = (b1 >> 4) + 1
                    disp = (((b1 & 0xF) << 8) | b2) + 1
                start = len(out) - disp
                for i in range(length):
                    out.append(out[start + i])
            else:
                out.append(data[pos])
                pos += 1
    return bytes(out[:out_size])


def read_narc(rom: ndspy.rom.NintendoDSRom, path: str) -> list[bytes]:
    return [bytes(entry) for entry in ndspy.narc.NARC(rom.getFileByName(path)).files]


def model_name(bmd: bytes) -> str:
    block = u32(bmd, 16)
    name = bmd[block + 32:block + 48].split(b"\0")[0]
    return name.decode("ascii", "replace")


def extract_chunk(chunk: bytes) -> tuple[bytes, list[dict]]:
    if chunk[:2] not in (b"WB", b"GC", b"NG", b"RD"):
        raise ValueError("unknown map chunk magic")
    offset = u32(chunk, 4)
    if chunk[offset:offset + 4] != b"BMD0":
        raise ValueError("map chunk has no BMD0")
    bmd = chunk[offset:offset + u32(chunk, offset + 8)]

    prop_offset_fields = {b"WB": (12, 16), b"GC": (16, 20), b"NG": (8, 12), b"RD": (12, 16)}
    offset_field, _ = prop_offset_fields[chunk[:2]]
    prop_offset = u32(chunk, offset_field)
    count = u32(chunk, prop_offset)
    placements = []
    for index in range(count):
        x, y, z, rotation, high, low = struct.unpack_from(
            "<iiiHBB", chunk, prop_offset + 4 + 16 * index
        )
        placements.append({
            "x": x / 4096,
            "y": y / 4096,
            "z": -z / 4096,
            "rotation": rotation * 360 / 65536,
            "prop": (high << 8) | low,
        })
    return bmd, placements


def chunk_permissions(chunk: bytes) -> tuple[int, int, bytes] | None:
    """Return the map chunk's permission grid (width, height, raw entries).

    WB and GC chunks carry one 32x32 (usually) grid of 8-byte entries. NG chunks
    have no collision grid and RD chunks store permission data externally.
    """
    magic = chunk[:2]
    if magic in (b"NG", b"RD"):
        return None
    if magic not in (b"WB", b"GC"):
        raise ValueError("unknown map chunk magic")
    offset = u32(chunk, 8)
    if offset + 4 > len(chunk):
        return None
    width, height = struct.unpack_from("<HH", chunk, offset)
    size = width * height * 8
    if offset + 4 + size > len(chunk):
        return None
    return width, height, chunk[offset + 4:offset + 4 + size]


def permission_tile(entry: bytes) -> tuple[str, int, int]:
    """Classify one 8-byte permission entry as a server map character.

    A tile is solid when behavior 1 is combined with the collision flag, when it
    is an unconditional collision tile (0xFF), or when it is a directional wall.
    Wild-encounter and surf flags become grass/water tiles.
    """
    _, _, behavior, flags = struct.unpack_from("<HHHH", entry)
    if behavior == 0xFF or 0x51 <= behavior <= 0x58:
        return "#", behavior, flags
    if behavior == 1 and flags & 1:
        return "#", behavior, flags
    if flags & 0x0004:
        return "g", behavior, flags
    if flags & 0x0002:
        return "~", behavior, flags
    return ".", behavior, flags


def permission_rows(chunk: bytes, width: int, height: int, cell: int,
                    scale: bool = False) -> list[str] | None:
    """Convert a permission grid into `cell` x `cell` tile rows.

    Most chunks are 32x32. A few use 64x64; those are sampled down when
    `scale` is true (outdoor cells) and clipped otherwise (single-cell rooms).
    """
    grid = chunk_permissions(chunk)
    if grid is None:
        return None
    grid_width, grid_height, raw = grid
    rows = []
    for local_y in range(cell):
        row = []
        for local_x in range(cell):
            if scale and (grid_width != cell or grid_height != cell):
                gx = min(grid_width - 1, local_x * grid_width // cell)
                gy = min(grid_height - 1, local_y * grid_height // cell)
            else:
                if local_x >= grid_width or local_y >= grid_height:
                    row.append("#")
                    continue
                gx, gy = local_x, local_y
            offset = (gy * grid_width + gx) * 8
            char, _, _ = permission_tile(raw[offset:offset + 8])
            row.append(char)
        rows.append("".join(row))
    return rows


def find_height_tables(rom: ndspy.rom.NintendoDSRom) -> tuple[tuple[int, ...], tuple[int, ...]]:
    """Locate the global fx16 terrain normal and fx32 plane-offset tables.

    Both live in the field overlay (overlay 21 in BW1 USA/Europe). They are
    found by the two flat normals that start the normal table rather than by
    a hard-coded overlay address, so another BW1 build with a different
    overlay layout still works as long as the table itself is unchanged.
    """
    expected = 0x1000 * 0x1000
    for overlay in rom.loadArm9Overlays().values():
        data = overlay.data
        pos = data.find(HEIGHT_SLOPE_SIGNATURE)
        while pos >= 0:
            offset_pos = pos + HEIGHT_OFFSET_GAP
            if offset_pos + 16 <= len(data):
                slopes = struct.unpack_from(
                    "<%dh" % (HEIGHT_SLOPE_ENTRIES * 3), data, pos
                )
                count = min(HEIGHT_OFFSET_ENTRIES, (len(data) - offset_pos) // 4)
                offsets = struct.unpack_from("<%di" % count, data, offset_pos)
                valid_normals = all(
                    abs(slopes[i] ** 2 + slopes[i + 1] ** 2 + slopes[i + 2] ** 2 - expected) < 0x30000
                    for i in range(0, 30, 3)
                )
                if offsets and offsets[0] == 0 and valid_normals:
                    return slopes, offsets
            pos = data.find(HEIGHT_SLOPE_SIGNATURE, pos + 1)
    raise RuntimeError(
        "BW terrain height tables not found; expected a Black/White USA/Europe ROM "
        "(the tables live in the field overlay)"
    )


def chunk_terrain_heights(chunk: bytes, slopes: tuple[int, ...], offsets: tuple[int, ...],
                          cell: int = 32, scale: bool = False,
                          layer: int = 0) -> list[list[float]] | None:
    """Decode a chunk's walkable terrain heights, in world units.

    The height at any point of a tile is the plane
        normal . (x, y, z) + offset = 0
    where x and z are relative to the chunk centre and y is up:
        height = -(offset + normal.x * x + normal.z * z) / normal.y
    Heights are sampled at tile centres, which is where actors stand. A
    split tile (shape 2) uses its second plane at the centre because the
    engine's strict comparisons pick plane 1 exactly on the diagonal.

    Rows are `cell` x `cell`, sampled the same way as permission_rows.
    Returns None for NG/RD chunks, which have no terrain section here.
    """
    magic = chunk[:2]
    if magic == b"WB":
        fields = (8,)
    elif magic == b"GC":
        fields = (8, 12)
    else:
        return None
    if layer >= len(fields):
        return None
    offset = u32(chunk, fields[layer])
    if offset + 4 > len(chunk):
        return None
    grid_width, grid_height = struct.unpack_from("<HH", chunk, offset)
    if not (0 < grid_width <= 64 and 0 < grid_height <= 64):
        return None
    tiles = offset + 4
    count = grid_width * grid_height
    splits = tiles + count * 8
    if splits > len(chunk):
        return None
    slope_count = len(slopes) // 3
    rows = []
    for local_y in range(cell):
        row = []
        for local_x in range(cell):
            if scale and (grid_width != cell or grid_height != cell):
                gx = min(grid_width - 1, local_x * grid_width // cell)
                gy = min(grid_height - 1, local_y * grid_height // cell)
            else:
                if local_x >= grid_width or local_y >= grid_height:
                    row.append(0.0)
                    continue
                gx, gy = local_x, local_y
            shape_slope, offset_id, tile_type = struct.unpack_from(
                "<HHI", chunk, tiles + (gy * grid_width + gx) * 8
            )
            shape = shape_slope & 3
            if shape == 0:
                slope = shape_slope >> 2
                plane_offset = offset_id
            elif shape == 2:
                rec = splits + offset_id * 8
                if rec + 8 > len(chunk):
                    row.append(0.0)
                    continue
                # Plane 1 for both diagonals at the exact centre.
                _, slope, _, plane_offset = struct.unpack_from("<4H", chunk, rec)
            else:
                row.append(0.0)
                continue
            if slope >= slope_count or plane_offset >= len(offsets):
                row.append(0.0)
                continue
            nx = slopes[slope * 3]
            ny = slopes[slope * 3 + 1]
            nz = -slopes[slope * 3 + 2]
            if ny == 0:
                row.append(0.0)
                continue
            x = -grid_width * 8 + 16 * gx + 8
            z = -grid_height * 8 + 16 * gy + 8
            row.append(-(offsets[plane_offset] + nx * x + nz * z) / ny)
        rows.append(row)
    return rows


def prop_bundle_models(bundle: bytes) -> dict[int, tuple[str, bytes]]:
    if bundle[:2] != b"AB":
        raise ValueError("not an AB prop bundle")
    count = bundle[2] >> 1
    offsets = [u32(bundle, 4 + 4 * index) for index in range(2 * count)]
    result = {}
    for index in range(count):
        res_id = u16(bundle, offsets[index])
        start = offsets[count + index]
        end = offsets[count + index + 1] if index + 1 < count else len(bundle)
        bmd = bundle[start:end]
        if bmd[:4] != b"BMD0":
            continue
        result[res_id] = (model_name(bmd), bmd)
    return result


def find_rom(path: Path) -> Path:
    if path.is_file():
        return path
    candidates = sorted(path.glob("*.nds"))
    if not candidates:
        raise FileNotFoundError(f"no .nds file found in {path}")
    return candidates[0]


def find_apicula(root: Path, value: str | None) -> Path | None:
    if value:
        candidate = Path(value)
        if candidate.is_file():
            return candidate
        raise FileNotFoundError(value)
    candidate = root / ".tools" / "apicula" / "apicula.exe"
    if candidate.is_file():
        return candidate
    found = shutil.which("apicula")
    return Path(found) if found else None


def render_texture(tex, palette) -> Image.Image:
    """Render one 4bpp NSBMD texture with a 16-color palette."""
    width, height = tex.size
    data = tex.data1
    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    pixels = image.load()
    for y in range(height):
        for x in range(width):
            index = y * width + x
            byte = data[index // 2]
            color_index = (byte & 0xF) if index % 2 == 0 else (byte >> 4)
            if color_index == 0:
                continue
            color = palette.colors[color_index]
            r = color[0] << 3 | color[0] >> 2
            g = color[1] << 3 | color[1] >> 2
            b = color[2] << 3 | color[2] >> 2
            pixels[x, y] = (r, g, b, 255)
    return image


ACTOR_MODELS = [
    ("hero", "fmdl_hero"),
    ("heroine", "fmdl_heroine"),
    ("boy4", "fmdl_boy4"),
    ("girl2", "fmdl_girl2"),
]

ACTOR_ANIMATIONS = {
    # Each field actor is a 32x32 billboard card. Frames are grouped by
    # direction and animation: the first 12 frames walk, the next 12 run,
    # the remaining 8 are unused. Walk and run cycles share the same shape:
    # neutral, step, neutral, opposite step. The run sheets only carry one
    # aerial/passing frame per direction, so it is repeated between the two
    # footfalls; listing the two strides back to back makes the step rhythm
    # lopsided (one stride is preceded by the airborne frame, the other is not).
    "hero": {
        "idle_down": [4],
        "walk_down": [4, 5, 4, 6],
        "idle_up": [1],
        "walk_up": [1, 2, 1, 3],
        "idle_left": [7],
        "walk_left": [7, 8, 7, 9],
        "idle_right": [10],
        "walk_right": [10, 11, 10, 12],
        "run_down": [16, 17, 16, 18],
        "run_up": [13, 14, 13, 15],
        "run_left": [19, 20, 19, 21],
        "run_right": [22, 23, 22, 24],
    },
    "heroine": {
        "idle_down": [4],
        "walk_down": [4, 5, 4, 6],
        "idle_up": [1],
        "walk_up": [1, 2, 1, 3],
        "idle_left": [7],
        "walk_left": [7, 8, 7, 9],
        "idle_right": [10],
        "walk_right": [10, 11, 10, 12],
        "run_down": [16, 17, 16, 18],
        "run_up": [13, 14, 13, 15],
        "run_left": [19, 20, 19, 21],
        "run_right": [22, 23, 22, 24],
    },
    # Secondary actors only ship the walking set.
    "boy4": {
        "idle_down": [4],
        "walk_down": [4, 5, 4, 6],
        "idle_up": [1],
        "walk_up": [1, 2, 1, 3],
        "idle_left": [7],
        "walk_left": [7, 8, 7, 9],
        "idle_right": [10],
        "walk_right": [10, 11, 10, 12],
    },
    "girl2": {
        "idle_down": [3],
        "walk_down": [3, 4],
        "idle_up": [1],
        "walk_up": [1, 2],
        "idle_left": [5],
        "walk_left": [5, 6],
        "idle_right": [7],
        "walk_right": [7],
    },
}


def extract_actor_frames(
    rom: ndspy.rom.NintendoDSRom, out: Path, key: str, model_name: str
) -> int:
    """Extract one field actor's embedded textures and its animation map."""
    actors = read_narc(rom, "a/1/6/0")
    bmd = None
    for entry in actors:
        if entry[:4] != b"BMD0":
            continue
        try:
            block = u32(entry, 16)
            name = entry[block + 32:block + 48].split(bytes([0]))[0].decode("ascii", "replace")
        except Exception:
            continue
        if name == model_name:
            bmd = entry
            break
    if bmd is None:
        print(f"Warning: {model_name} not found", file=sys.stderr)
        return 0

    model = ndspy.model.NSBMD(bmd)
    palette = model.palettes[0][1]
    frames_dir = out / "actors" / key / "frames"
    frames_dir.mkdir(parents=True, exist_ok=True)
    for old in frames_dir.glob("*.png"):
        old.unlink()
    for index, (_, texture) in enumerate(model.textures, start=1):
        image = render_texture(texture, palette)
        image.save(frames_dir / f"frame_{index:02d}.png")

    available = len(model.textures)
    animations = {}
    for animation_name, frames in ACTOR_ANIMATIONS[key].items():
        usable = [frame for frame in frames if frame <= available]
        if usable:
            animations[animation_name] = usable
    actor = {
        "source": f"{model_name} (a/1/6/0)",
        "key": key,
        "frameSize": 32,
        "animations": animations,
    }
    (out / "actors" / key / "actor.json").write_text(
        json.dumps(actor, indent=2), encoding="utf-8"
    )
    print(f"Extracted {available} {key} frames -> {frames_dir}")
    return available


def extract_actors(rom: ndspy.rom.NintendoDSRom, out: Path) -> None:
    for key, model_name in ACTOR_MODELS:
        extract_actor_frames(rom, out, key, model_name)


def run_apicula(apicula: Path, inputs: list[Path], output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    command = [str(apicula), "convert", *[str(path) for path in inputs],
               "-o", str(output), "-f=glb", "--more-textures", "--overwrite"]
    result = subprocess.run(command, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"Apicula failed with exit code {result.returncode}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument("--out", default="client/assets/bw/nuvema", help="output directory")
    parser.add_argument("--apicula", default=None, help="Apicula executable")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    rom_path = find_rom((root / args.rom).resolve() if not Path(args.rom).is_absolute() else Path(args.rom))
    out = (root / args.out).resolve()
    map_out = out / "map"
    props_out = out / "props"
    map_out.mkdir(parents=True, exist_ok=True)
    props_out.mkdir(parents=True, exist_ok=True)

    print(f"ROM:   {rom_path}")
    print(f"Output:{out}")
    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))
    if bytes(rom.idCode).decode("ascii", "replace") not in {"IRAO", "IRAP"}:
        print("Warning: this extractor expects Pokemon Black/White (IRAO/IRAP).", file=sys.stderr)

    # Overworld matrix: file 0 of a/0/0/9.
    matrices = read_narc(rom, "a/0/0/9")
    overworld = matrices[0]
    has_zones, _, width, height = struct.unpack_from("<HHHH", overworld)
    if not has_zones:
        raise SystemExit("overworld matrix has no zone grid")
    cells = struct.unpack_from(f"<{width * height}I", overworld, 8)
    zone_grid = struct.unpack_from(f"<{width * height}I", overworld, 8 + 4 * width * height)
    x, y = NUVEMA_CELL
    model_id = cells[y * width + x]
    zone_id = zone_grid[y * width + x]
    if model_id == NONE or zone_id == NONE:
        raise SystemExit(f"no map model/zone at Nuvema cell {NUVEMA_CELL}")

    # Zone header and area.
    zone_data = read_narc(rom, "a/0/1/2")[0]
    header = ZONE_HEADER.unpack_from(zone_data, zone_id * ZONE_HEADER.size)
    (map_type, _, area_id, matrix_id, *rest) = header
    fly = (rest[-3], rest[-2], rest[-1])
    if map_type != 0 or matrix_id != 0:
        raise SystemExit(f"zone {zone_id} is not an outdoor overworld zone: {map_type=} {matrix_id=}")
    print(f"Nuvema zone: id={zone_id}, area={area_id}, model={model_id}, fly={fly}")
    if tuple(fly) != NUVEMA_FLY:
        print(f"Warning: expected fly {NUVEMA_FLY}, got {fly}; continuing with cell {NUVEMA_CELL}")

    area_data = bytes(rom.getFileByName("a/0/1/3"))
    area = AREA_RECORD.unpack_from(area_data, area_id * AREA_RECORD.size)
    prop_bundle_id, map_texture_set = area[0], area[1]
    print(f"Area: prop bundle={prop_bundle_id}, map texture set={map_texture_set}")

    # Terrain chunk and prop placements.
    chunks = read_narc(rom, "a/0/0/8")
    chunk = lz11_decompress(chunks[model_id])
    bmd, placements = extract_chunk(chunk)
    (out / "raw").mkdir(exist_ok=True)
    map_nsbmd = out / "raw" / f"{model_name(bmd)}.nsbmd"
    map_nsbmd.write_bytes(bmd)
    print(f"Map model: {model_name(bmd)} ({len(bmd)} bytes), {len(placements)} props")

    # Prop bundle models.
    bundles = read_narc(rom, "a/2/2/9")
    if prop_bundle_id >= len(bundles):
        raise SystemExit("prop bundle index is out of range")
    bundle_models = prop_bundle_models(bundles[prop_bundle_id])
    used_ids = sorted({placement["prop"] for placement in placements})
    prop_inputs = []
    prop_files = {}
    for res_id in used_ids:
        if res_id not in bundle_models:
            print(f"Warning: prop res_id {res_id} not found in bundle {prop_bundle_id}", file=sys.stderr)
            continue
        name, model = bundle_models[res_id]
        path = out / "raw" / f"prop_{res_id}_{name}.nsbmd"
        path.write_bytes(model)
        prop_inputs.append(path)
        prop_files[res_id] = f"{name}.glb"
        print(f"  prop {res_id}: {name}")

    # Texture sets.
    map_textures = read_narc(rom, "a/0/1/4")
    if map_texture_set >= len(map_textures):
        raise SystemExit("map texture set is out of range")
    map_tex = out / "raw" / "map_textures.nsbtx"
    map_tex.write_bytes(map_textures[map_texture_set])
    prop_textures = read_narc(rom, "a/1/7/6")
    if prop_bundle_id >= len(prop_textures):
        raise SystemExit("prop texture set is out of range")
    prop_tex = out / "raw" / "prop_textures.nsbtx"
    prop_tex.write_bytes(prop_textures[prop_bundle_id])

    apicula = find_apicula(root, args.apicula)
    if apicula is None:
        print(
            "Apicula was not found. Raw NSBMD/NSBTX files are in "
            f"{out / 'raw'}; download Apicula into .tools/apicula or pass --apicula.",
            file=sys.stderr,
        )
        return 1

    print(f"Converting with {apicula}")
    for old in map_out.glob("*"):
        if old.is_file():
            old.unlink()
    for old in props_out.glob("*"):
        if old.is_file():
            old.unlink()
    run_apicula(apicula, [map_nsbmd, map_tex], map_out)
    if prop_inputs:
        run_apicula(apicula, prop_inputs + [prop_tex], props_out)

    # Client manifest and player portrait.
    manifest = {
        "source": "Pokemon Black/White ROM (local extraction)",
        "cell": list(NUVEMA_CELL),
        "zone": zone_id,
        "mapFile": f"map/{model_name(bmd)}.glb",
        "props": placements,
        "propFiles": prop_files,
    }
    (out / "placements.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    extract_actors(rom, out)

    trainer = root / "client" / "assets" / "bw" / "trainers" / "0.png"
    if trainer.is_file():
        shutil.copyfile(trainer, out / "player.png")
        print("Copied trainer portrait 0.png -> nuvema/player.png")
    else:
        print("Trainer portrait missing; run tools/rom/extract_bw_assets.py first.", file=sys.stderr)

    print(f"Done. Nuvema assets -> {out}")
    print("Run:  run-nuvema.cmd")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
