"""Resolve a map's prop ids to models using the ROM's AB prop bundles.

Without running the game, four measured facts decide this; ``audit_assets.py``
re-checks the ones it can on every run so a wrong assumption fails the build:

1. Within one AB archive a prop id names the same prop in every bundle: across
   the 64 bundles of the indoor archive, and separately across the 52 outdoor
   ones, no id has two names. A bundle is therefore not a private id space, it
   is *availability plus a texture variant*.
2. The two archives are different id spaces. 138 ids exist in both with a
   different name -- indoor 2 is ``tv01``, outdoor 2 is ``t2_house01``; outdoor
   6 is ``t1_labo_01``. Mixing them is the historical bug: resolving a room
   against the outdoor archive furnished it with buildings and gates.
3. Ids below 147 are prop-bundle furniture. Ids at 147 and above appear in no
   bundle at all -- they are map-object ids (trees, rocks) from the outdoor
   pipeline -- so a zone referencing them is not an interior, whatever its
   matrix looks like.
4. No single field of the area record picks the right bundle. ``area[1] // 4``
   (the map texture set) is correct for the Nuvema houses, but applied to every
   zone it leaves 178 of the 299 zones with props empty. The bundle is
   therefore chosen by coverage: the one that supplies the most of the scene's
   ids.
5. Coverage alone is ambiguous -- bundles share the common furniture, so most
   interiors are fully covered by several -- and the map texture set is the
   tie-break that picks the faithful textures.
6. The bundle is *not* the unit of availability. The same id carries a
   byte-identical model in every bundle that supplies it (144 ids indoors, 291
   outdoors, 0 with two different models), so the bundle is a texture group,
   not a private set. A room draws each id from the bundle it prefers and falls
   back to any other bundle that has it; picking one bundle per room and
   dropping the rest lost 1138 of 3355 placements, including whole multi-bundle
   rooms. Only ids absent from the whole archive are genuinely missing (46
   placements, all in zones whose ids are outdoor map objects).

The historical bug this replaces: resolving against ``area[0]``, the overworld
fallback (6 for Nuvema), which furnished the player's house with outdoor props
and dropped the staircase.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence

#: First id that is a map object rather than a prop-bundle resource.
PROP_ID_LIMIT = 147


def prop_tables(members: Sequence[bytes]) -> list[dict[int, tuple[str, bytes]]]:
    """One ``id -> (name, model)`` table per bundle of an AB archive."""
    from extract_nuvema import prop_bundle_models

    return [prop_bundle_models(member) for member in members]


def prop_ids(placements: Iterable[dict]) -> list[int]:
    """The prop-bundle ids in a chunk's placement list, sorted and unique."""
    return sorted({p["prop"] for p in placements if p["prop"] < PROP_ID_LIMIT})


def map_objects(placements: Iterable[dict]) -> int:
    """How many placements are map objects (ids ``>= PROP_ID_LIMIT``)."""
    return sum(1 for p in placements if p["prop"] >= PROP_ID_LIMIT)


def choose_bundle(ids: Sequence[int], tables: Sequence[dict], preferred: int) -> int | None:
    """The bundle covering the most of ``ids``, ties going to ``preferred``.

    This is the *primary* bundle -- the texture group most of the room shares --
    not the only one its props may come from (see ``sources``). None only when
    the archive is empty.
    """
    if not tables:
        return None
    best_bundle = 0
    best_covered = -1
    for index, table in enumerate(tables):
        covered = sum(1 for prop_id in ids if prop_id in table)
        if covered > best_covered or (covered == best_covered and index == preferred):
            best_bundle, best_covered = index, covered
    return best_bundle


def supply(tables: Sequence[dict]) -> dict[int, int]:
    """``id -> first bundle that supplies it`` for one archive.

    Safe because of fact 6: every supplier holds the same model bytes, so any
    of them renders the same prop; the first is just deterministic.
    """
    first: dict[int, int] = {}
    for index, table in enumerate(tables):
        for prop_id in table:
            first.setdefault(prop_id, index)
    return first


def sources(
    scene: dict, tables: Sequence[dict], primary: int | None = None
) -> dict[int, int]:
    """``id -> bundle to read it from`` for one scene.

    The primary (coverage-best) bundle is preferred so most of a room shares one
    texture group; ids it lacks come from any bundle that has them instead of
    being dropped.
    """
    if primary is None:
        primary = choose_bundle(scene["propIds"], tables, scene["texSet"] // 4)
    first = supply(tables)
    return {
        prop_id: (
            primary
            if primary is not None
            and 0 <= primary < len(tables)
            and prop_id in tables[primary]
            else first[prop_id]
        )
        for prop_id in scene["propIds"]
        if prop_id in first
    }


def unresolved(scene: dict, tables: Sequence[dict]) -> list[int]:
    """Ids of ``scene`` that no bundle of this archive supplies."""
    first = supply(tables)
    return [prop_id for prop_id in scene["propIds"] if prop_id not in first]


def assign(
    scenes: Iterable[dict], tables: Sequence[dict]
) -> dict[int, tuple[int | None, list[int]]]:
    """``zone -> (primary bundle, ids no bundle supplies)`` per scene."""
    return {
        scene["zone"]: (
            choose_bundle(scene["propIds"], tables, scene["texSet"] // 4),
            unresolved(scene, tables),
        )
        for scene in scenes
    }


def score(scenes: Iterable[dict], tables: Sequence[dict]) -> tuple[int, int]:
    """How well one archive *is the archive these scenes were authored for*.

    Counting raw id coverage picks the wrong archive: the outdoor one happens to
    contain more ids in total, so it "covers" more of the indoor scenes. What
    distinguishes them is whether the scene's own texture set names a bundle
    here -- ``area[1] // 4`` refers to a bundle of the right archive, so in the
    outdoor archive two thirds of the interiors point past the end of the table.

    Returns ``(scenes the preferred bundle fully covers, ids it covers)``.
    """
    complete = 0
    covered = 0
    for scene in scenes:
        preferred = scene["texSet"] // 4
        if preferred >= len(tables):
            continue
        hits = sum(1 for prop_id in scene["propIds"] if prop_id in tables[preferred])
        covered += hits
        complete += 1 if hits == len(scene["propIds"]) else 0
    return complete, covered


def name_conflicts(tables: Sequence[dict]) -> dict[int, set[str]]:
    """Ids that carry more than one name within one archive.

    Empty is what the whole rule rests on: if two bundles of the same archive
    disagreed about what id 4 is, picking a bundle by coverage would silently
    change the prop. Pass the tables of a *single* archive -- the two archives
    are different id spaces on purpose.
    """
    names: dict[int, set[str]] = {}
    for table in tables:
        for prop_id, (name, _) in table.items():
            names.setdefault(prop_id, set()).add(name)
    return {prop_id: found for prop_id, found in names.items() if len(found) > 1}
