#!/usr/bin/env python3
"""Replace the RGB of transparent texels with the nearest opaque color.

The ROM uses magenta (255, 0, 255) as its transparency key. Godot renders
these textures with linear filtering and alpha scissor, so bilinear taps that
straddle a transparent texel blend magenta into tree/window edges. Alpha is
left untouched; only the hidden RGB is bled from neighboring opaque pixels so
filtered edges stay green instead of turning purple.

Usage:
    python tools/rom/fix_alpha_textures.py --root client/assets/bw/unova_outdoor
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    import numpy as np
    from PIL import Image
    from scipy import ndimage
except ImportError as exc:  # pragma: no cover - dependency hint
    raise SystemExit(
        "fix_alpha_textures.py needs numpy, Pillow and scipy: %s" % exc
    )


def is_magenta_transparent(rgb: np.ndarray, alpha: np.ndarray) -> bool:
    transparent = alpha == 0
    if not transparent.any():
        return False
    return bool(
        (
            (rgb[:, :, 0] > 180)
            & (rgb[:, :, 2] > 180)
            & (rgb[:, :, 1] < 80)
            & transparent
        ).any()
    )


def fix_image(path: Path, dry_run: bool) -> int:
    with Image.open(path) as source:
        image = source.convert("RGBA")
    pixels = np.array(image)
    alpha = pixels[:, :, 3]
    if not is_magenta_transparent(pixels, alpha):
        return 0
    transparent = alpha == 0
    if transparent.all():
        return 0

    # For every transparent pixel, find the nearest opaque pixel and copy its
    # color. This is the same bleed a texture-paint tool would apply by hand.
    _, indices = ndimage.distance_transform_edt(transparent, return_indices=True)
    ys, xs = np.nonzero(transparent)
    pixels[ys, xs, :3] = pixels[indices[0][ys, xs], indices[1][ys, xs], :3]

    if not dry_run:
        Image.fromarray(pixels, "RGBA").save(path, compress_level=6)
    return len(xs)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default="client/assets/bw/unova_outdoor",
        help="directory to scan recursively for PNG textures",
    )
    parser.add_argument("--dry-run", action="store_true", help="report without writing")
    args = parser.parse_args()

    root = Path(args.root)
    if not root.is_dir():
        print(f"Not a directory: {root}", file=sys.stderr)
        return 1

    files = 0
    changed = 0
    texels = 0
    for path in sorted(root.rglob("*.png")):
        files += 1
        try:
            fixed = fix_image(path, args.dry_run)
        except Exception as exc:  # keep going on a corrupt texture
            print(f"skip {path}: {exc}", file=sys.stderr)
            continue
        if fixed:
            changed += 1
            texels += fixed

    action = "would fix" if args.dry_run else "fixed"
    print(f"{action} {changed}/{files} textures ({texels} transparent texels)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
