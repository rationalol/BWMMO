#!/usr/bin/env python3
"""Fetch Gen 5 animated battle sprites and build client sheets.

Source: Pokemon Showdown's gen5ani / gen5ani-back GIFs (front/back, normal
palette). The project runs locally only; generated assets stay in
client/assets/bw, which is gitignored.

Output:
  client/assets/bw/pokemon_anim/<id>_front.png   horizontal frame sheet
  client/assets/bw/pokemon_anim/<id>_back.png
  client/assets/bw/pokemon_anim/manifest.json

Each manifest entry stores frame width/height, frame count and per-frame
durations in milliseconds. Missing downloads simply leave the static ROM
sprite as the client fallback.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from PIL import Image, ImageSequence

BASE_URL = "https://play.pokemonshowdown.com/sprites"
SIDES = {"front": "gen5ani", "back": "gen5ani-back"}
USER_AGENT = "BWMMO-local-prototype/0.1"


def download(url: str, target: Path, retries: int = 3) -> bool:
    if target.exists() and target.stat().st_size > 0:
        return True
    target.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(retries):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(request, timeout=25) as response:
                data = response.read()
            if not data:
                raise ValueError("empty response")
            target.write_bytes(data)
            return True
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            if attempt + 1 == retries:
                print(f"  failed {url}: {error}", file=sys.stderr)
            else:
                time.sleep(0.4 * (attempt + 1))
    return False


def idle_frame_count(frames: list[Image.Image]) -> int:
    """Cut the idle loop before the large jump/attack frames in the GIF."""
    if len(frames) <= 2:
        return len(frames)
    base = frames[0].getbbox()
    if base is None:
        return len(frames)
    base_w, base_h = base[2] - base[0], base[3] - base[1]
    base_cx, base_cy = (base[0] + base[2]) / 2, (base[1] + base[3]) / 2
    for index, frame in enumerate(frames[1:], start=1):
        box = frame.getbbox()
        if box is None:
            continue
        width, height = box[2] - box[0], box[3] - box[1]
        cx, cy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
        moved = abs(cx - base_cx) > 3 or abs(cy - base_cy) > 3
        resized = abs(width - base_w) > max(4, base_w * 0.25) or abs(height - base_h) > max(4, base_h * 0.25)
        if moved or resized:
            return max(1, index)
        if index >= 30:
            return index
    return min(len(frames), 30)


def build_sheet(gif_path: Path, sheet_path: Path) -> dict | None:
    try:
        image = Image.open(gif_path)
        frames = []
        durations = []
        for frame in ImageSequence.Iterator(image):
            frame = frame.convert("RGBA")
            frames.append(frame)
            durations.append(max(20, min(1000, int(frame.info.get("duration", 100) or 100))))
        if not frames:
            return None
        keep = idle_frame_count(frames)
        frames = frames[:keep]
        durations = durations[:keep]
        width = max(frame.width for frame in frames)
        height = max(frame.height for frame in frames)
        if width <= 0 or height <= 0:
            return None
        sheet = Image.new("RGBA", (width * len(frames), height), (0, 0, 0, 0))
        for index, frame in enumerate(frames):
            left = index * width + (width - frame.width) // 2
            top = height - frame.height
            sheet.alpha_composite(frame, (left, top))
        sheet.save(sheet_path)
        return {
            "sheet": sheet_path.name,
            "frameWidth": width,
            "frameHeight": height,
            "frames": len(frames),
            "durations": durations
        }
    except Exception as error:
        print(f"  failed to decode {gif_path}: {error}", file=sys.stderr)
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", default="server/content/game.json")
    parser.add_argument("--out", default="client/assets/bw/pokemon_anim")
    parser.add_argument("--cache", default=".tools/showdown_sprites")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--limit", type=int, default=0, help="only fetch the first N species")
    parser.add_argument("--check", action="store_true", help="only report existing manifest")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    game = json.loads((root / args.game).read_text(encoding="utf-8"))
    species = list(game.get("species", {}).keys())
    if args.limit:
        species = species[: args.limit]
    cache = (root / args.cache).resolve()
    out = (root / args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)

    if args.check:
        manifest_path = out / "manifest.json"
        if not manifest_path.exists():
            print("no manifest")
            return 1
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        entries = manifest.get("species", {})
        print(f"animated sprites: {len(entries)} species")
        return 0 if entries else 1

    jobs = []
    for species_id in species:
        for side, directory in SIDES.items():
            url = f"{BASE_URL}/{directory}/{species_id}.gif"
            target = cache / directory / f"{species_id}.gif"
            jobs.append((species_id, side, url, target))

    print(f"Downloading {len(jobs)} GIFs with {args.workers} workers...")
    downloaded = 0
    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as executor:
        futures = {
            executor.submit(download, url, target): (species_id, side)
            for species_id, side, url, target in jobs
        }
        for future in as_completed(futures):
            if future.result():
                downloaded += 1
    print(f"Downloaded/cached {downloaded}/{len(jobs)}")

    entries: dict[str, dict] = {}
    for species_id in species:
        sides = {}
        for side, directory in SIDES.items():
            gif_path = cache / directory / f"{species_id}.gif"
            if not gif_path.exists():
                continue
            sheet_path = out / f"{species_id}_{side}.png"
            meta = build_sheet(gif_path, sheet_path)
            if meta:
                sides[side] = meta
        if sides:
            entries[species_id] = sides

    manifest = {
        "source": "Pokemon Showdown gen5ani / gen5ani-back (local cache)",
        "species": entries
    }
    manifest_path = out / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {manifest_path}: {len(entries)} species with animations")
    return 0 if entries else 1


if __name__ == "__main__":
    raise SystemExit(main())
