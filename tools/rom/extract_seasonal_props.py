#!/usr/bin/env python3
"""Extract the ROM's seasonal blossom props (r01_a/b spring..winter).

The original game swaps prop models 295-302 by season rather than recoloring
the spring model. This tool extracts all eight models and writes
`client/assets/bw/unova_outdoor/seasonal_props.json` so the client can resolve
the current season's model at runtime.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ndspy.rom

from extract_nuvema import (
    find_apicula,
    find_rom,
    prop_bundle_models,
    read_narc,
    run_apicula,
)

SEASON_IDS = {
    "spring": (295, 296),
    "summer": (297, 298),
    "autumn": (299, 300),
    "winter": (301, 302),
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rom", default=".", help="ROM file or directory")
    parser.add_argument(
        "--assets",
        default="client/assets/bw/unova_outdoor",
        help="outdoor asset directory",
    )
    parser.add_argument("--apicula", default=None, help="Apicula executable")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    rom_path = find_rom(
        (root / args.rom).resolve() if not Path(args.rom).is_absolute() else Path(args.rom)
    )
    asset_dir = (root / args.assets).resolve()
    apicula = find_apicula(root, args.apicula)
    if apicula is None:
        print("Apicula not found; put it in .tools/apicula or pass --apicula.", file=sys.stderr)
        return 1

    rom = ndspy.rom.NintendoDSRom.fromFile(str(rom_path))
    bundles = read_narc(rom, "a/2/2/9")
    textures = read_narc(rom, "a/1/7/6")
    models = prop_bundle_models(bundles[0])
    raw_dir = asset_dir / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)
    prop_tex = raw_dir / "prop_tex_0.nsbtx"
    prop_tex.write_bytes(textures[0])

    wanted = {rid for ids in SEASON_IDS.values() for rid in ids}
    by_id = {}
    for rid in sorted(wanted):
        if rid not in models:
            print(f"Missing seasonal prop {rid}", file=sys.stderr)
            return 1
        name, bmd = models[rid]
        by_id[rid] = name
        bmd_path = raw_dir / f"seasonal_{rid}_{name}.nsbmd"
        bmd_path.write_bytes(bmd)
        out_dir = asset_dir / "props" / "b0" / f"p{rid}_{name}"
        print(f"  prop {rid}: {name} -> {out_dir.relative_to(root)}")
        run_apicula(apicula, [bmd_path, prop_tex], out_dir)

    mapping: dict[str, dict[str, str]] = {}
    for season, ids in SEASON_IDS.items():
        for rid in ids:
            name = by_id[rid]
            base = name.rsplit("_", 1)[0]
            mapping.setdefault(base, {})[season] = (
                f"unova_outdoor/props/b0/p{rid}_{name}/{name}.glb"
            )
    out = asset_dir / "seasonal_props.json"
    out.write_text(json.dumps(mapping, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {out} ({len(mapping)} families)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
