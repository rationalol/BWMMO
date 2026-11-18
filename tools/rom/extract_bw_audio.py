#!/usr/bin/env python3
"""Render the original Black/White BGM and sound effects for the client.

Reads ``wb_sound_data.sdat`` straight out of the local ROM, resolves the
sequence names through the SDAT SYMB table, renders the sequences with the
ROM's own SWAV samples (tools/rom/audio, vendored from aletheia's MIT asset
lane), and writes OGG/WAV files plus a manifest under
``client/assets/bw/audio``.

The map -> BGM table is derived from the ROM itself: every outdoor cell in
``client/assets/bw/unova_outdoor/library.json`` names a zone, each zone
header carries four seasonal BGM sequence ids, and
``server/content/rom/outdoor_locations.json`` supplies the matching location
name per cell. The autumn slot is used because the client's world starts in
autumn. Indoor themes (Pokémon Center / Juniper's lab / houses) come from
the indoor zone headers.

Run from the repository root:

    python tools/rom/extract_bw_audio.py
    python tools/rom/extract_bw_audio.py --only SEQ_BGM_T_01,SEQ_BGM_R_A
    python tools/rom/extract_bw_audio.py --force

Requires: ndspy, numpy is not needed, ffmpeg on PATH for OGG encoding.
The rendered audio is copyrighted game audio: output stays in the gitignored
``client/assets/bw/`` tree and must not be redistributed.
"""

from __future__ import annotations

import argparse
import json
import shutil
import struct
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
AUDIO_DIR = Path(__file__).resolve().parent / "audio"
sys.path.insert(0, str(AUDIO_DIR))

import sdat as sdat_mod  # noqa: E402
import sseqsynth  # noqa: E402

ROM_DEFAULT = "Pokemon - White Version (USA, Europe) (NDSi Enhanced).nds"
OUT_ROOT = ROOT / "client" / "assets" / "bw" / "audio"
RENDER_ROOT = ROOT / ".tools" / "audio" / "render"
SAMPLE_RATE = sseqsynth.SAMPLE_RATE

# Zone header: map_type, room_type, area, matrix, script, text, ...
# The four u16 at index 7..10 are spring/summer/autumn/winter BGM sequence ids.
ZONE_HEADER = struct.Struct("<BBHHHHH4HHHHHHHHHiii")
AUTUMN_SLOT = 9 - 7  # h[7] is spring, h[9] is autumn

BGM_EXTRAS = [
    "SEQ_BGM_TITLE",
    "SEQ_BGM_POKECEN",
    "SEQ_BGM_LABO",
    "SEQ_BGM_VS_NORAPOKE",
    "SEQ_BGM_VS_TRAINER",
    "SEQ_BGM_WIN1",
]

# Client key -> SEQ name. These are the effects the online client actually
# triggers (menus, dialogue, warps, battle beats, jingles).
SFX_SEQS = [
    ("message", "SEQ_SE_MESSAGE"),
    ("select", "SEQ_SE_SELECT1"),
    ("decide", "SEQ_SE_DECIDE1"),
    ("cancel", "SEQ_SE_CANCEL1"),
    ("open", "SEQ_SE_OPEN1"),
    ("close", "SEQ_SE_CLOSE1"),
    ("wall", "SEQ_SE_WALL_HIT"),
    ("door", "SEQ_SE_KAIDAN"),
    ("pc", "SEQ_SE_PC_ON"),
    ("heal", "SEQ_SE_RECOVERY"),
    ("exp", "SEQ_SE_EXP"),
    ("hit", "SEQ_SE_KON"),
    ("faint", "SEQ_SE_DEAD"),
    ("throw", "SEQ_SE_NAGERU"),
    ("poof", "SEQ_SE_BOWA1"),
    ("levelup", "SEQ_ME_LVUP"),
    ("item", "SEQ_ME_ITEM"),
    ("capture", "SEQ_ME_POKEGET"),
    ("badge", "SEQ_ME_BADGE"),
]

INDOOR_BGM = {"center": "SEQ_BGM_POKECEN", "lab": "SEQ_BGM_LABO"}


def find_rom(explicit: str | None) -> Path:
    if explicit:
        path = Path(explicit)
        if not path.exists():
            raise SystemExit(f"ROM not found: {path}")
        return path
    path = ROOT / ROM_DEFAULT
    if path.exists():
        return path
    matches = sorted(ROOT.glob("*.nds"))
    if matches:
        return matches[0]
    raise SystemExit(f"ROM not found: {ROM_DEFAULT}")


def load_rom_files(rom_path: Path):
    import ndspy.narc
    import ndspy.rom

    lit_rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))
    sdat_bytes = bytes(lit_rom.getFileByName("wb_sound_data.sdat"))
    zone_bytes = bytes(ndspy.narc.NARC(lit_rom.getFileByName("a/0/1/2")).files[0])
    matrix_bytes = bytes(ndspy.narc.NARC(lit_rom.getFileByName("a/0/0/9")).files[0])
    return sdat_bytes, zone_bytes, matrix_bytes


def load_locations() -> dict[str, list[str]] | None:
    locations_path = ROOT / "server" / "content" / "rom" / "outdoor_locations.json"
    if not locations_path.exists():
        return None
    data = json.loads(locations_path.read_text(encoding="utf-8"))
    return data.get("grid")


def load_cells() -> list[dict] | None:
    library_path = ROOT / "client" / "assets" / "bw" / "unova_outdoor" / "library.json"
    if not library_path.exists():
        return None
    data = json.loads(library_path.read_text(encoding="utf-8"))
    return data.get("cells")


def seq_names(sdat_obj) -> list[str | None]:
    return sdat_obj.names_for("SEQ")


def name_to_index(names: list[str | None]) -> dict[str, int]:
    return {name: index for index, name in enumerate(names) if name}


def zone_bgm_name(sdat_obj, zone_bytes: bytes, zone_id: int) -> str | None:
    offset = zone_id * ZONE_HEADER.size
    if offset + ZONE_HEADER.size > len(zone_bytes):
        return None
    header = ZONE_HEADER.unpack_from(zone_bytes, offset)
    seq_id = header[7 + AUTUMN_SLOT]
    names = seq_names(sdat_obj)
    if 0 <= seq_id < len(names):
        return names[seq_id]
    return None


def build_location_bgm(sdat_obj, zone_bytes, locations, cells) -> dict[str, str]:
    """location name -> SEQ name, chosen by the ROM zone under each cell."""
    if not locations or not cells:
        return {}
    votes: dict[str, Counter] = defaultdict(Counter)
    for cell in cells:
        x, y = int(cell.get("x", -1)), int(cell.get("y", -1))
        if y < 0 or y >= len(locations) or x < 0 or x >= len(locations[y]):
            continue
        location = locations[y][x]
        if not location:
            continue
        name = zone_bgm_name(sdat_obj, zone_bytes, int(cell["zone"]))
        if name:
            votes[location][name] += 1
    return {location: counter.most_common(1)[0][0] for location, counter in votes.items()}


def build_location_grid(sdat_obj, zone_bytes, matrix_bytes) -> dict:
    """Full overworld matrix: one BGM key per 32x32-tile cell.

    The client walks on grid tiles, so cell = (x // tileSize, y // tileSize).
    This is locale-independent: the ROM zone, not the translated place name,
    decides the track.
    """
    has_zones, _, width, height = struct.unpack_from("<HHHH", matrix_bytes)
    if not has_zones:
        return {}
    zone_grid = struct.unpack_from(f"<{width * height}I", matrix_bytes,
                                   8 + 4 * width * height)
    rows: list[list[str]] = []
    for y in range(height):
        row: list[str] = []
        for x in range(width):
            zone_id = zone_grid[y * width + x]
            if zone_id == 0xFFFFFFFF:
                row.append("")
                continue
            name = zone_bgm_name(sdat_obj, zone_bytes, zone_id)
            row.append(name if name else "")
        rows.append(row)
    return {"width": width, "height": height, "tileSize": 32, "grid": rows}


def build_indoor_bgm(sdat_obj, zone_bytes) -> dict[str, str]:
    """Map id (unova_in_*) -> SEQ name from each indoor map's ROM zone."""
    found: dict[str, str] = {}
    maps_dir = ROOT / "server" / "content" / "maps"
    for path in sorted(maps_dir.glob("unova_in_*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        zone = data.get("zone")
        if not isinstance(zone, int):
            continue
        name = zone_bgm_name(sdat_obj, zone_bytes, zone)
        if name:
            found[str(data.get("id") or path.stem)] = name
    return found


def trim_stereo_pcm(pcm: bytes, end_seconds: float | None,
                    fade_out_seconds: float = 0.012) -> bytes:
    """Cut a 32 kHz stereo s16 buffer and apply a short click-free fade."""
    if end_seconds is None:
        end_seconds = len(pcm) / 4 / SAMPLE_RATE
    end_samples = max(1, int(end_seconds * SAMPLE_RATE))
    end_samples = min(end_samples, len(pcm) // 4)
    out = bytearray(pcm[: end_samples * 4])
    fade = min(end_samples, max(1, int(fade_out_seconds * SAMPLE_RATE)))
    for i in range(fade):
        index = end_samples - fade + i
        gain = 1.0 - (i / fade)
        left, right = struct.unpack_from("<hh", out, index * 4)
        struct.pack_into("<hh", out, index * 4,
                         int(left * gain), int(right * gain))
    return bytes(out)


def write_wav_file(path: Path, pcm: bytes) -> None:
    import wave

    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(2)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(pcm)


def ogg_duration(path: Path) -> float | None:
    ffprobe = shutil.which("ffprobe")
    if not ffprobe or not path.exists():
        return None
    try:
        output = subprocess.check_output(
            [ffprobe, "-v", "error", "-show_entries", "format=duration",
             "-of", "csv=p=0", str(path)],
            text=True,
        ).strip()
        return float(output)
    except (subprocess.CalledProcessError, ValueError):
        return None


def encode_ogg(wav_path: Path, ogg_path: Path) -> None:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("ffmpeg is required to encode BGM to OGG")
    ogg_path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [ffmpeg, "-y", "-loglevel", "error", "-i", str(wav_path),
         "-c:a", "libvorbis", "-q:a", "4", str(ogg_path)],
        check=True,
    )


def render_bgm(sdat_obj, seq_index: int, key: str, force: bool) -> dict:
    ogg_path = OUT_ROOT / "bgm" / f"{key}.ogg"
    meta_path = RENDER_ROOT / f"{key}.json"
    if not force and ogg_path.exists() and meta_path.exists():
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        actual = ogg_duration(ogg_path)
        expected = float(meta.get("length", 0.0))
        # A loop longer than the old fixed render cap was silently cut short;
        # re-render anything whose file is shorter than its metadata claims.
        if actual is None or actual + 0.75 >= expected:
            print(f"[bgm] cached {key} ({actual or expected:.2f}s)")
            return meta
        print(f"[bgm] cached {key} is truncated "
              f"({actual:.1f}s < {expected:.1f}s); re-rendering")

    print(f"[bgm] rendering {key} ...", flush=True)
    probe = sseqsynth.probe_seq(sdat_obj, seq_index)
    loop_end = probe.get("loop_end_seconds")
    # Size the buffer from the actual loop so a long track is never clipped.
    limit = (loop_end + 1.0) if loop_end else 30.0
    pcm, stats = sseqsynth.render_seq(
        sdat_obj, seq_index, max_seconds=limit, fade=False, one_loop=True
    )
    loop_end = stats.get("loop_end_seconds")
    loop_start = stats.get("loop_start_seconds")
    loop = loop_end is not None and loop_end > 0.5
    if loop:
        pcm = trim_stereo_pcm(pcm, loop_end)
        length = loop_end
        loop_offset = loop_start or 0.0
    else:
        pcm = trim_stereo_pcm(pcm, None, fade_out_seconds=0.04)
        length = len(pcm) / 4 / SAMPLE_RATE
        loop_offset = 0.0

    wav_path = RENDER_ROOT / f"{key}.wav"
    write_wav_file(wav_path, pcm)
    encode_ogg(wav_path, ogg_path)
    wav_path.unlink(missing_ok=True)

    meta = {
        "file": f"bgm/{key}.ogg",
        "loop": loop,
        "loopOffset": round(loop_offset, 3),
        "length": round(length, 3),
        "seqName": sdat_obj.names_for("SEQ")[seq_index],
        "notes": stats["notes_rendered"],
        "bpm": stats["master_bpm"],
    }
    meta_path.parent.mkdir(parents=True, exist_ok=True)
    meta_path.write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(f"[bgm] wrote {ogg_path.name} {length:.1f}s loop={loop} "
          f"offset={loop_offset:.2f}s in={stats['notes_rendered']} notes")
    return meta


def trim_trailing_silence(pcm: bytes, threshold: int = 256,
                          keep_seconds: float = 0.12) -> bytes:
    """Drop the renderer's silent tail (it pads 1.5 s past the last note)."""
    frames = len(pcm) // 4
    keep = max(1, int(keep_seconds * SAMPLE_RATE))
    last = 0
    for index in range(frames - 1, -1, -1):
        left, right = struct.unpack_from("<hh", pcm, index * 4)
        if abs(left) > threshold or abs(right) > threshold:
            last = index
            break
    end = min(frames, last + keep)
    return pcm[: end * 4]


def render_sfx(sdat_obj, seq_index: int, key: str, force: bool) -> str:
    out_path = OUT_ROOT / "sfx" / f"{key}.wav"
    if not force and out_path.exists():
        print(f"[sfx] cached {key}")
        return f"sfx/{key}.wav"
    print(f"[sfx] rendering {key} ...", flush=True)
    pcm, stats = sseqsynth.render_seq(sdat_obj, seq_index, max_seconds=14.0, fade=False)
    pcm = trim_trailing_silence(pcm)
    pcm = trim_stereo_pcm(pcm, None, fade_out_seconds=0.03)
    write_wav_file(out_path, pcm)
    print(f"[sfx] wrote {out_path.name} {len(pcm) / 4 / SAMPLE_RATE:.2f}s")
    return f"sfx/{key}.wav"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--rom", help="path to the Black/White ROM")
    ap.add_argument("--only", help="comma-separated SEQ names to render")
    ap.add_argument("--force", action="store_true", help="re-render cached output")
    ap.add_argument("--list", action="store_true", help="print the mapping and exit")
    args = ap.parse_args(argv)

    rom_path = find_rom(args.rom)
    print(f"[rom] {rom_path.name}")
    sdat_bytes, zone_bytes, matrix_bytes = load_rom_files(rom_path)
    sdat_obj = sdat_mod.Sdat(sdat_bytes, path=str(rom_path))
    names = seq_names(sdat_obj)
    lookup = name_to_index(names)

    locations = load_locations()
    cells = load_cells()
    location_bgm = build_location_bgm(sdat_obj, zone_bytes, locations, cells)
    indoor_bgm = build_indoor_bgm(sdat_obj, zone_bytes)
    location_grid = build_location_grid(sdat_obj, zone_bytes, matrix_bytes)
    if not location_bgm:
        print("[warn] no outdoor cell/library data; using Nuvema/Route 1 only")
        location_bgm = {"Nuvema Town": "SEQ_BGM_T_01", "Route 1": "SEQ_BGM_R_A"}

    wanted = list(BGM_EXTRAS) + sorted(set(location_bgm.values()))
    wanted += sorted(set(indoor_bgm.values()))
    if location_grid:
        wanted += sorted({
            key for row in location_grid["grid"] for key in row if key
        })
    if args.only:
        selected = {name.strip() for name in args.only.split(",") if name.strip()}
        wanted = [name for name in wanted if name in selected] + [
            name for name in selected if name not in wanted
        ]
    wanted = [name for name in dict.fromkeys(wanted) if name in lookup]

    print(f"[map] {len(location_bgm)} locations -> {len(set(location_bgm.values()))} tracks")
    for location in sorted(location_bgm):
        print(f"  {location:20s} {location_bgm[location]}")
    print(f"[indoor] {len(indoor_bgm)} maps -> {len(set(indoor_bgm.values()))} tracks")
    if location_grid:
        print(f"[grid] {location_grid['width']}x{location_grid['height']} cells")
    if args.list:
        return 0

    OUT_ROOT.mkdir(parents=True, exist_ok=True)
    RENDER_ROOT.mkdir(parents=True, exist_ok=True)

    bgm_manifest: dict[str, dict] = {}
    for name in wanted:
        key = name.lower()
        try:
            bgm_manifest[key] = render_bgm(sdat_obj, lookup[name], key, args.force)
        except Exception as error:  # noqa: BLE001 - report which track failed
            print(f"[error] {name}: {error}", file=sys.stderr)

    sfx_manifest: dict[str, str] = {}
    for key, name in SFX_SEQS:
        if name not in lookup:
            print(f"[warn] SFX missing from SDAT: {name}")
            continue
        try:
            sfx_manifest[key] = render_sfx(sdat_obj, lookup[name], key, args.force)
        except Exception as error:  # noqa: BLE001
            print(f"[error] {name}: {error}", file=sys.stderr)

    def bgm_key(name: str) -> str:
        return name.lower()

    grid_manifest = {}
    if location_grid:
        grid_manifest = {
            "width": location_grid["width"],
            "height": location_grid["height"],
            "tileSize": location_grid["tileSize"],
            "grid": [
                [bgm_key(name) if name else "" for name in row]
                for row in location_grid["grid"]
            ],
        }

    manifest = {
        "version": 1,
        "source": "wb_sound_data.sdat (local ROM render)",
        "sampleRate": SAMPLE_RATE,
        "bgm": bgm_manifest,
        "sfx": sfx_manifest,
        "locations": {
            location: bgm_key(name)
            for location, name in sorted(location_bgm.items())
        },
        "indoorMaps": {
            map_id: bgm_key(name)
            for map_id, name in sorted(indoor_bgm.items())
        },
        "locationGrid": grid_manifest,
        "indoor": {kind: bgm_key(name) for kind, name in INDOOR_BGM.items()},
        "battle": {
            "wild": "seq_bgm_vs_norapoke",
            "trainer": "seq_bgm_vs_trainer",
        },
        "victory": "seq_bgm_win1",
        "title": "seq_bgm_title",
    }
    manifest_path = OUT_ROOT / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"[done] {len(bgm_manifest)} BGM, {len(sfx_manifest)} SFX -> {OUT_ROOT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
