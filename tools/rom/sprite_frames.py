"""Read extracted walk-sheet PNGs and tell which way a frame faces.

Both the sprite extractor and ``audit_assets.py`` need this: the extractor uses
it to refuse to write a sheet whose left/right frames are swapped, and the
audit uses it to check sheets that are already on disk. Keeping one copy means
the build-time check and the audit cannot disagree.

Stdlib only (``zlib`` + ``struct``), so it runs anywhere.
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def read_png_rgba(path: str | Path) -> tuple[int, int, bytes]:
    """Decode an 8-bit RGBA, non-interlaced PNG into ``(width, height, rgba)``.

    That is exactly what ``nsbmd.write_png_rgba8`` writes for the extracted
    frames; anything else raises instead of producing garbage pixels.
    """
    data = Path(path).read_bytes()
    if data[:8] != PNG_SIGNATURE:
        raise ValueError(f"{path}: not a PNG")
    width = height = 0
    color_type = interlace = bit_depth = -1
    idat = bytearray()
    pos = 8
    while pos + 8 <= len(data):
        length = struct.unpack_from(">I", data, pos)[0]
        kind = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + length]
        if kind == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", body
            )
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        pos += length + 12
    if bit_depth != 8 or color_type != 6 or interlace != 0:
        raise ValueError(
            f"{path}: expected 8-bit RGBA without interlacing "
            f"(got depth {bit_depth}, colour type {color_type}, interlace {interlace})"
        )
    raw = zlib.decompress(bytes(idat))
    stride = width * 4
    out = bytearray(stride * height)
    previous = bytearray(stride)
    pos = 0
    for row in range(height):
        filter_type = raw[pos]
        pos += 1
        line = bytearray(raw[pos : pos + stride])
        pos += stride
        if filter_type == 1:  # Sub
            for index in range(4, stride):
                line[index] = (line[index] + line[index - 4]) & 0xFF
        elif filter_type == 2:  # Up
            for index in range(stride):
                line[index] = (line[index] + previous[index]) & 0xFF
        elif filter_type == 3:  # Average
            for index in range(stride):
                left = line[index - 4] if index >= 4 else 0
                line[index] = (line[index] + ((left + previous[index]) >> 1)) & 0xFF
        elif filter_type == 4:  # Paeth
            for index in range(stride):
                left = line[index - 4] if index >= 4 else 0
                up = previous[index]
                upper_left = previous[index - 4] if index >= 4 else 0
                pa = abs(up - upper_left)
                pb = abs(left - upper_left)
                pc = abs(left + up - 2 * upper_left)
                if pa <= pb and pa <= pc:
                    predictor = left
                elif pb <= pc:
                    predictor = up
                else:
                    predictor = upper_left
                line[index] = (line[index] + predictor) & 0xFF
        elif filter_type != 0:
            raise ValueError(f"{path}: unknown PNG filter {filter_type}")
        out[row * stride : (row + 1) * stride] = line
        previous = line
    return width, height, bytes(out)


def face_offset(rgba: bytes, width: int, height: int) -> float | None:
    """Horizontal offset of the skin pixels, as a fraction of half the width.

    Negative means the face sits left of centre (the sprite faces left). Returns
    None when the sheet has no skin pixels at all — Pokémon and object sprites —
    so callers can skip those instead of guessing.

    This is how the left/right mix-up was caught: frames labelled ``right`` had
    negative offsets on every human sheet.
    """
    total = 0.0
    count = 0
    for pixel in range(width * height):
        r, g, b, a = rgba[pixel * 4 : pixel * 4 + 4]
        if a > 128 and r > 200 and 150 < g < 215 and 120 < b < 190 and r >= g >= b:
            total += pixel % width
            count += 1
    if count < 8:
        return None
    return (total / count - (width - 1) / 2) / (width / 2)


def skin_pixels(rgba: bytes, width: int, height: int) -> int:
    """How many skin pixels the frame has; 0 means it is a back view or a prop."""
    count = 0
    for pixel in range(width * height):
        r, g, b, a = rgba[pixel * 4 : pixel * 4 + 4]
        if a > 128 and r > 200 and 150 < g < 215 and 120 < b < 190 and r >= g >= b:
            count += 1
    return count
