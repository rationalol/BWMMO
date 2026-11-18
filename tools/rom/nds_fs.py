"""Minimal read-only Nintendo DS ROM and NARC archive reader.

The dialog extractor normally depends on ndspy, which is not available in
every environment. This module covers the small part of ndspy that the
extractor needs: iterating the ROM file allocation table and reading NARC
members. It is not a general purpose NDS toolkit.

This ROM *does* ship a file name table: `a/0/5/7`, `a/0/1/2`, `a/2/2/9` and
friends all resolve through ``NintendoDSRom.named_files``. Two things are worth
knowing before trusting a path:

- The names stop before every archive that matters. The indoor prop archive is
  the unnamed FAT 472 right after the named outdoor one (`a/2/2/9` = FAT 471);
  `a/2/2/8` is a different, tiny archive (6 bundles), not the furniture set.
- Some archives are only reachable by content. ``magic_archives`` and
  ``detect_script_archive`` stay for those.
"""

from __future__ import annotations

import struct
from pathlib import Path

# Zone header record: script file id at index 4, text file id at index 6.
ZONE_HEADER = struct.Struct("<BBHHHHH4HHHHHHHHHiii")
SCRIPT_TERMINATOR = 0xFD13


class NARC:
    """A Nitro archive (.narc) as found inside a DS ROM."""

    def __init__(self, data: bytes):
        if data[:4] != b"NARC":
            raise ValueError("not a NARC archive")
        header_size, section_count = struct.unpack_from("<HH", data, 0x0C)
        self.files: list[bytes] = []
        fat: tuple[int, int] | None = None
        image: tuple[int, int] | None = None
        offset = header_size
        for _ in range(section_count):
            magic, size = struct.unpack_from("<4sI", data, offset)
            if magic == b"BTAF":
                count = struct.unpack_from("<H", data, offset + 8)[0]
                entries = [
                    struct.unpack_from("<II", data, offset + 12 + index * 8)
                    for index in range(count)
                ]
                fat = (offset + 12, count)
                self._entries = entries
            elif magic == b"GMIF":
                image = (offset + 8, size - 8)
            offset += size
            if size <= 0:
                break
        if fat is None or image is None:
            raise ValueError("NARC has no file data")
        image_start = image[0]
        for start, end in self._entries:
            self.files.append(bytes(data[image_start + start:image_start + end]))


class NintendoDSRom:
    """Read files from a decrypted .nds image by FAT index."""

    def __init__(self, data: bytes):
        self.data = data
        self.fat_offset, self.fat_size = struct.unpack_from("<II", data, 0x48)
        self._fat = [
            struct.unpack_from("<II", data, self.fat_offset + index * 8)
            for index in range(self.fat_size // 8)
        ]

    @classmethod
    def open(cls, path: str | Path) -> "NintendoDSRom":
        return cls(Path(path).read_bytes())

    def __len__(self) -> int:
        return len(self._fat)

    def file(self, index: int) -> bytes:
        start, end = self._fat[index]
        return self.data[start:end]

    def nitro_files(self) -> list[tuple[int, bytes]]:
        """Return (fat index, bytes) for every entry that is a NARC."""
        found = []
        for index in range(len(self._fat)):
            start, end = self._fat[index]
            if end > start and self.data[start:start + 4] == b"NARC":
                found.append((index, self.data[start:end]))
        return found

    def every_file(self) -> list[tuple[int, bytes]]:
        """Return (fat index, bytes) for every non-empty file in the image."""
        found = []
        for index in range(len(self._fat)):
            start, end = self._fat[index]
            if end > start:
                found.append((index, self.data[start:end]))
        return found

    def named_files(self) -> dict[str, int]:
        """Map every path in the file name table to its FAT index.

        Each directory is an 8-byte header (subtable offset, first file id,
        parent id) followed by a list of entries: one length byte (bit 7 marks
        a subdirectory), the name, then a u16 directory id for directories.
        File ids are handed out sequentially down the tree, so the walk itself
        assigns them; an entry's own id field only exists for directories.
        """
        fnt_offset, fnt_size = struct.unpack_from("<II", self.data, 0x40)
        if fnt_size < 8:
            return {}
        fnt = self.data[fnt_offset : fnt_offset + fnt_size]
        directory_count = struct.unpack_from("<H", fnt, 6)[0]
        names: dict[str, int] = {}

        def walk(directory: int, prefix: str, first_id: int) -> None:
            base = directory * 8
            if base + 8 > len(fnt):
                return
            subtable = struct.unpack_from("<I", fnt, base)[0]
            file_id = struct.unpack_from("<H", fnt, base + 4)[0]
            if subtable >= len(fnt):
                return
            pos = subtable
            while pos < len(fnt):
                length = fnt[pos]
                pos += 1
                if length == 0:
                    return
                is_directory = bool(length & 0x80)
                name_length = length & 0x7F
                if not name_length:
                    return
                name = fnt[pos : pos + name_length].decode("ascii", "replace")
                pos += name_length
                if is_directory:
                    if pos + 2 > len(fnt):
                        return
                    child = struct.unpack_from("<H", fnt, pos)[0] & 0x0FFF
                    pos += 2
                    walk(child, f"{prefix}{name}/", 0)
                else:
                    names[prefix + name] = file_id
                    file_id += 1

        walk(0, "", 0)
        if directory_count == 0:
            names.clear()
        return names


def magic_archives(
    files: list[tuple[int, bytes]], magic: bytes, minimum: int = 4
) -> list[tuple[int, list[bytes]]]:
    """Find NARC archives whose *every* member starts with ``magic``.

    The prop archives cannot be found by path: the retail ROM ships a stripped
    file name table, and the two archives that matter (overworld props and
    indoor furniture) differ only in member count. Matching on the member
    magic is exact — a NARC of AB bundles contains nothing but AB bundles — so
    this is the only reliable identifier.
    """
    found: list[tuple[int, list[bytes]]] = []
    for index, data in files:
        if data[:4] != b"NARC":
            continue
        try:
            archive = NARC(data)
        except ValueError:
            continue
        members = archive.files
        if len(members) < minimum:
            continue
        if all(member[: len(magic)] == magic for member in members):
            found.append((index, members))
    return found


def find_rom(explicit: str | None = None) -> Path:
    """Locate the BW ROM the way the other tools/rom scripts do."""
    if explicit:
        return Path(explicit)
    root = Path(__file__).resolve().parents[2]
    candidates = sorted(root.glob("*.nds"))
    if not candidates:
        raise FileNotFoundError("no .nds ROM found in the project root")
    return candidates[0]


def script_entry_count(data: bytes) -> int | None:
    """Return the number of scripts if ``data`` is a field script file.

    A script file is a table of u32 relative offsets terminated by the u16
    ``SCRIPT_TERMINATOR``. Offsets are relative to the position right after
    the entry, so they always point past the end of the table.
    """
    offsets = []
    pos = 0
    while pos + 2 <= len(data):
        if struct.unpack_from("<H", data, pos)[0] == SCRIPT_TERMINATOR:
            break
        if pos + 4 > len(data):
            return None
        value = struct.unpack_from("<I", data, pos)[0]
        pos += 4
        offsets.append(pos + value)
        if len(offsets) > 4000:
            return None
    else:
        return None
    if not offsets:
        return None
    if any(offset <= pos or offset > len(data) for offset in offsets):
        return None
    if offsets != sorted(offsets) or len(set(offsets)) != len(offsets):
        return None
    return len(offsets)


def iter_narcs(rom: "NintendoDSRom"):
    """Yield ``(fat_index, NARC)`` for every archive in the ROM."""
    for index in range(len(rom._fat)):
        start, end = rom._fat[index]
        if end > start and rom.data[start:start + 4] == b"NARC":
            try:
                yield index, NARC(rom.data[start:end])
            except (ValueError, struct.error):
                continue


def detect_script_archive(rom: "NintendoDSRom") -> tuple[int, NARC]:
    """Find the field script archive (a/0/5/7) by content.

    The archive whose members are almost all valid script files wins. Texture
    archives can contain the terminator by chance, so the score is the share
    of members that parse as a complete, monotonically ordered offset table.
    """
    best = None
    for index, narc in iter_narcs(rom):
        if not len(narc.files):
            continue
        valid = sum(1 for data in narc.files if script_entry_count(data) is not None)
        score = valid / len(narc.files)
        if valid >= 50 and (best is None or score > best[0]):
            best = (score, index, narc)
    if best is None:
        raise LookupError("no field script archive found in the ROM")
    return best[1], best[2]


def detect_zone_header_archive(rom: "NintendoDSRom", zone_count: int,
                               script_count: int, text_count: int) -> tuple[int, bytes]:
    """Find the zone header archive (a/0/1/2) by content.

    It is a single-member NARC of 48-byte records whose script/text file ids
    stay inside the two archives above for almost every record.
    """
    best = None
    for index, narc in iter_narcs(rom):
        if len(narc.files) != 1:
            continue
        data = narc.files[0]
        if len(data) % ZONE_HEADER.size or len(data) // ZONE_HEADER.size < zone_count:
            continue
        good = 0
        total = min(len(data) // ZONE_HEADER.size, 500)
        for zone_id in range(1, total):
            header = ZONE_HEADER.unpack_from(data, zone_id * ZONE_HEADER.size)
            if header[4] < script_count and header[6] < text_count and (header[4] or header[6]):
                good += 1
        score = good / max(total - 1, 1)
        if best is None or score > best[0]:
            best = (score, index, data)
    if best is None or best[0] < 0.9:
        raise LookupError("no zone header archive found in the ROM")
    return best[1], best[2]
