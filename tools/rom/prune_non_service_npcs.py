#!/usr/bin/env python3
"""Remove placeholder/story NPCs, keeping only functional services.

The current content was decoded from the ROM and contains ~1500 Residents and
story characters that have dialogue but no gameplay yet. Keep the healer, shop
and PC NPCs so the core loop still works; story NPCs can be restored from the
ROM generators when the event scripts are implemented.
"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAPS = ROOT / "server" / "content" / "maps"
SERVICE_KINDS = {"healer", "shop", "pc"}


def main() -> None:
    removed = 0
    kept = 0
    changed_files = 0
    for path in sorted(MAPS.glob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        npcs = data.get("npcs")
        if not isinstance(npcs, list) or not npcs:
            continue
        kept_npcs = [npc for npc in npcs if npc.get("kind") in SERVICE_KINDS]
        if len(kept_npcs) == len(npcs):
            continue
        data["npcs"] = kept_npcs
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        removed += len(npcs) - len(kept_npcs)
        kept += len(kept_npcs)
        changed_files += 1
    print(f"changed {changed_files} maps; removed {removed} NPCs; kept {kept} service NPCs")


if __name__ == "__main__":
    main()
