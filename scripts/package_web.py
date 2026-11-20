#!/usr/bin/env python3
"""Archive Kaka's existing web files and verify the resource index without building the app."""

import argparse
import hashlib
import json
import re
import stat
import tempfile
import zipfile
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
WEB_ROOT = PROJECT / "web/app"
ARCHIVE = PROJECT / "ios/Kaka/Kaka.zip"
INDEX = PROJECT / "ios/Kaka/KakaArchiveIndex.json"
PATH_SEGMENT = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*")
MAX_BYTES = 24 * 1024 * 1024
MAX_ENTRY_BYTES = 8 * 1024 * 1024
MAX_FILES = 256


def digest(data):
    return hashlib.sha256(data).hexdigest()


def web_files():
    files = {}
    casing = {}
    total = 0
    for source in sorted(WEB_ROOT.rglob("*")):
        relative = source.relative_to(WEB_ROOT)
        if relative.parts[:2] == ("assets", "previews"):
            continue
        if any(part.startswith(".") for part in relative.parts):
            continue
        if source.is_symlink():
            raise ValueError(f"Symbolic link in web resources: {relative}")
        if not source.is_file():
            continue
        name = relative.as_posix()
        if len(name) > 180 or len(relative.parts) > 6 or not all(
            PATH_SEGMENT.fullmatch(part) for part in relative.parts
        ):
            raise ValueError(f"Invalid web resource path: {name}")
        for length in range(1, len(relative.parts) + 1):
            path = "/".join(relative.parts[:length])
            if casing.setdefault(path.lower(), path) != path:
                raise ValueError(f"Case collision in web resource path: {name}")
        data = source.read_bytes()
        if not 1 <= len(data) <= MAX_ENTRY_BYTES:
            raise ValueError(f"Invalid size for {name}")
        files[name] = data
        total += len(data)
    required = {"index.html", "policies/terms.html", "policies/privacy.html"}
    if not required.issubset(files) or len(files) > MAX_FILES or total > MAX_BYTES:
        raise ValueError("Web resources are missing the entry page or exceed archive limits.")
    return files


def make_index(archive, files):
    return {
        "version": 4,
        "archiveSHA256": digest(archive.read_bytes()),
        "files": {name: {"bytes": len(content), "sha256": digest(content)} for name, content in files.items()},
    }


def archive_files(files):
    with tempfile.TemporaryDirectory(prefix=".kaka-web-", dir=ARCHIVE.parent) as directory:
        staging = Path(directory)
        packed = staging / ARCHIVE.name
        with zipfile.ZipFile(packed, "w") as archive:
            for name, content in files.items():
                entry = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
                entry.create_system = 3
                entry.external_attr = (stat.S_IFREG | 0o644) << 16
                compressed = Path(name).suffix in {".js", ".html", ".css", ".json"}
                method = zipfile.ZIP_DEFLATED if compressed else zipfile.ZIP_STORED
                archive.writestr(entry, content, compress_type=method)
        packed_index = staging / INDEX.name
        packed_index.write_text(json.dumps(make_index(packed, files), indent=2) + "\n", encoding="utf-8")
        verify(packed, packed_index, files)
        packed.replace(ARCHIVE)
        packed_index.replace(INDEX)


def verify(archive_path, index_path, files):
    if json.loads(index_path.read_text(encoding="utf-8")) != make_index(archive_path, files):
        raise ValueError("The legacy archive has drifted from the web sources. Run python3 scripts/package_web.py.")
    if archive_path.stat().st_size > MAX_BYTES:
        raise ValueError("Compressed archive exceeds the package limit.")
    with zipfile.ZipFile(archive_path) as archive:
        if sorted(archive.namelist()) != sorted(files):
            raise ValueError("ZIP entries do not match the source tree.")
        for entry in archive.infolist():
            name = entry.filename
            if (
                not stat.S_ISREG(entry.external_attr >> 16)
                or entry.file_size != len(files[name])
                or not entry.compress_size
                or entry.file_size > entry.compress_size * 150
                or archive.read(entry) != files[name]
            ):
                raise ValueError(f"Invalid ZIP entry: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Read and verify the packaged files.")
    args = parser.parse_args()
    files = web_files()
    if args.check:
        verify(ARCHIVE, INDEX, files)
    else:
        archive_files(files)
    expanded = sum(map(len, files.values()))
    print(f"{ARCHIVE.name}: {len(files)} files, {ARCHIVE.stat().st_size:,} archived bytes, {expanded:,} expanded bytes")


if __name__ == "__main__":
    main()
