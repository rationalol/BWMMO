#!/usr/bin/env python3
"""Axis-aligned bounds of a GLB model, in ROM units.

Indoor collision comes from the ROM permission grid, which only marks the
floor and the walls: furniture that the original game collides against is a
prop mesh with its own collision data. Reading each prop's AABB lets the map
builder stamp the tiles a piece of furniture actually covers.

The GLB that Apicula writes keeps the ROM's units (16 per tile), so the bounds
can be compared with prop placements and the permission grid directly.
"""

from __future__ import annotations

import json
import struct
from pathlib import Path

GLB_MAGIC = 0x46546C67  # "glTF"
JSON_CHUNK = 0x4E4F534A

Bounds = tuple[tuple[float, float, float], tuple[float, float, float]]

_CACHE: dict[str, Bounds | None] = {}


def _json_chunk(path: Path) -> dict | None:
    try:
        data = path.read_bytes()
    except OSError:
        return None
    if len(data) < 12:
        return None
    magic, _version, length = struct.unpack_from("<III", data, 0)
    if magic != GLB_MAGIC:
        return None
    offset = 12
    while offset + 8 <= min(length, len(data)):
        chunk_length, chunk_type = struct.unpack_from("<II", data, offset)
        offset += 8
        if chunk_type == JSON_CHUNK:
            try:
                return json.loads(data[offset : offset + chunk_length].decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                return None
        offset += chunk_length
    return None


def _mat_identity() -> list[float]:
    return [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]


def _mat_mul(a: list[float], b: list[float]) -> list[float]:
    """Column-major 4x4 multiply, the layout glTF stores."""
    out = [0.0] * 16
    for column in range(4):
        for row in range(4):
            out[column * 4 + row] = sum(
                a[k * 4 + row] * b[column * 4 + k] for k in range(4)
            )
    return out


def _node_matrix(node: dict) -> list[float]:
    matrix = node.get("matrix")
    if isinstance(matrix, list) and len(matrix) == 16:
        return [float(value) for value in matrix]
    tx, ty, tz = (float(value) for value in node.get("translation", (0, 0, 0)))
    qx, qy, qz, qw = (float(value) for value in node.get("rotation", (0, 0, 0, 1)))
    sx, sy, sz = (float(value) for value in node.get("scale", (1, 1, 1)))
    xx, yy, zz = qx * qx, qy * qy, qz * qz
    xy, xz, yz = qx * qy, qx * qz, qy * qz
    wx, wy, wz = qw * qx, qw * qy, qw * qz
    return [
        (1 - 2 * (yy + zz)) * sx, 2 * (xy + wz) * sx, 2 * (xz - wy) * sx, 0.0,
        2 * (xy - wz) * sy, (1 - 2 * (xx + zz)) * sy, 2 * (yz + wx) * sy, 0.0,
        2 * (xz + wy) * sz, 2 * (yz - wx) * sz, (1 - 2 * (xx + yy)) * sz, 0.0,
        tx, ty, tz, 1.0,
    ]


def _transform(matrix: list[float], point: tuple[float, float, float]) -> tuple[float, float, float]:
    x, y, z = point
    return (
        matrix[0] * x + matrix[4] * y + matrix[8] * z + matrix[12],
        matrix[1] * x + matrix[5] * y + matrix[9] * z + matrix[13],
        matrix[2] * x + matrix[6] * y + matrix[10] * z + matrix[14],
    )


def bounds(path: str | Path) -> Bounds | None:
    """World-space AABB of a GLB scene, or None when it cannot be read."""
    key = str(path)
    if key in _CACHE:
        return _CACHE[key]
    result = _compute(key)
    _CACHE[key] = result
    return result


def _compute(key: str) -> Bounds | None:
    document = _json_chunk(Path(key))
    if not document:
        return None
    nodes = document.get("nodes") or []
    meshes = document.get("meshes") or []
    accessors = document.get("accessors") or []
    if not nodes or not meshes or not accessors:
        return None
    scenes = document.get("scenes") or []
    scene_index = document.get("scene", 0)
    roots = (
        scenes[scene_index].get("nodes", [])
        if 0 <= scene_index < len(scenes) and isinstance(scenes[scene_index], dict)
        else []
    )
    if not roots:
        referenced = {
            child
            for node in nodes
            for child in (node.get("children") or [])
        }
        roots = [index for index in range(len(nodes)) if index not in referenced]

    low = [float("inf")] * 3
    high = [float("-inf")] * 3
    seen: set[int] = set()

    def visit(index: int, parent: list[float]) -> None:
        if index in seen or not (0 <= index < len(nodes)):
            return
        seen.add(index)
        node = nodes[index]
        matrix = _mat_mul(parent, _node_matrix(node))
        mesh_index = node.get("mesh")
        if isinstance(mesh_index, int) and 0 <= mesh_index < len(meshes):
            for primitive in meshes[mesh_index].get("primitives") or []:
                attribute = (primitive.get("attributes") or {}).get("POSITION")
                if not isinstance(attribute, int) or not (0 <= attribute < len(accessors)):
                    continue
                accessor = accessors[attribute]
                minimum = accessor.get("min")
                maximum = accessor.get("max")
                if not minimum or not maximum:
                    continue
                for corner_x in (minimum[0], maximum[0]):
                    for corner_y in (minimum[1], maximum[1]):
                        for corner_z in (minimum[2], maximum[2]):
                            point = _transform(matrix, (corner_x, corner_y, corner_z))
                            for axis in range(3):
                                low[axis] = min(low[axis], point[axis])
                                high[axis] = max(high[axis], point[axis])
        for child in node.get("children") or []:
            if isinstance(child, int):
                visit(child, matrix)

    identity = _mat_identity()
    for root in roots:
        if isinstance(root, int):
            visit(root, identity)
    if low[0] == float("inf"):
        return None
    return (tuple(low), tuple(high))  # type: ignore[return-value]


def clear_cache() -> None:
    _CACHE.clear()
