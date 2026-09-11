#!/usr/bin/env python3
"""Stage Wine's runtime PE files into Madeira's resource tree.

Wine's multiarch build leaves PE outputs in directories such as
``dlls/ntdll/i386-windows``.  This script intentionally only considers files
directly inside directories named ``<arch>-windows``; host objects and linker
outputs elsewhere in the build are not staging inputs.
"""

from __future__ import annotations

import argparse
import filecmp
import os
from pathlib import Path
import shutil
import struct
from typing import Iterable


RUNTIME_EXTENSIONS = frozenset({".dll", ".exe", ".drv", ".cpl"})
MACHINES = {"i386": 0x014C, "aarch64": 0xAA64}
REQUIRED_FILES = {
    "i386": frozenset({"ntdll.dll", "kernel32.dll", "kernelbase.dll"}),
    "aarch64": frozenset({"wow64.dll", "wow64win.dll"}),
}


class StageError(RuntimeError):
    """Raised when the build tree cannot satisfy the staging contract."""


def _iter_runtime_files(source_build: Path, arch: str) -> Iterable[Path]:
    """Yield runtime-extension files directly inside matching arch folders."""

    arch_directory = f"{arch}-windows"
    for root, directories, filenames in os.walk(source_build, followlinks=False):
        directories.sort(key=str.casefold)
        if Path(root).name.casefold() != arch_directory.casefold():
            continue

        for filename in sorted(filenames, key=str.casefold):
            path = Path(root) / filename
            if path.is_file() and path.suffix.casefold() in RUNTIME_EXTENSIONS:
                yield path


def read_pe_machine(path: Path | str) -> int:
    """Validate a PE header and return its COFF machine value.

    This is also the small public validator used by callers that need to
    inspect one PE outside the staging flow, such as a separately built FEX
    module.
    """

    path = Path(path)

    try:
        with path.open("rb") as stream:
            dos_header = stream.read(64)
            if len(dos_header) < 64 or dos_header[:2] != b"MZ":
                raise StageError(f"malformed PE (missing MZ header): {path}")

            pe_offset = struct.unpack_from("<I", dos_header, 0x3C)[0]
            stream.seek(pe_offset)
            pe_header = stream.read(6)
    except OSError as exc:
        raise StageError(f"cannot read runtime PE {path}: {exc}") from exc

    if len(pe_header) < 6 or pe_header[:4] != b"PE\0\0":
        raise StageError(f"malformed PE (missing PE signature): {path}")

    return struct.unpack_from("<H", pe_header, 4)[0]


def _validate_pe(path: Path, expected_machine: int) -> None:
    """Validate a PE's signatures and its expected COFF machine field."""

    machine = read_pe_machine(path)
    if machine != expected_machine:
        expected = f"0x{expected_machine:04x}"
        actual = f"0x{machine:04x}"
        raise StageError(
            f"wrong PE machine for {path}: found {actual}, expected {expected}"
        )


def _deduplicate(files: Iterable[Path]) -> list[Path]:
    """Keep identical duplicate basenames and reject conflicting ones."""

    by_name: dict[str, Path] = {}
    unique: list[Path] = []
    for path in files:
        key = path.name.casefold()
        previous = by_name.get(key)
        if previous is None:
            by_name[key] = path
            unique.append(path)
            continue

        if previous.stat().st_size != path.stat().st_size or not filecmp.cmp(
            previous, path, shallow=False
        ):
            raise StageError(
                "duplicate runtime basename with different content: "
                f"{previous} and {path}"
            )

    return unique


def stage_runtime_pe(source_build: Path | str, destination: Path | str, arch: str) -> list[Path]:
    """Stage validated Wine runtime PEs and return the files written.

    ``destination`` is the app resource root; files are written below its
    ``<arch>-windows`` child.  Existing files are overwritten only when they
    have the same staged basename.  Nothing is deleted, including README files
    and runtime files not present in the current build.
    """

    if arch not in MACHINES:
        raise StageError(f"unsupported architecture {arch!r}; use i386 or aarch64")

    source_root = Path(source_build)
    if not source_root.is_dir():
        raise StageError(f"source build directory does not exist: {source_root}")

    discovered = list(_iter_runtime_files(source_root, arch))
    if not discovered:
        raise StageError(
            f"no runtime PE files found under */{arch}-windows/* in {source_root}"
        )

    for path in discovered:
        _validate_pe(path, MACHINES[arch])

    unique = _deduplicate(discovered)
    required_names = REQUIRED_FILES[arch]
    available_names = {path.name.casefold() for path in unique}
    missing = sorted(required_names - available_names)
    if missing:
        raise StageError(
            f"missing required {arch} runtime files: {', '.join(missing)}"
        )

    if arch == "aarch64":
        stage_names = REQUIRED_FILES[arch]
        unique = [path for path in unique if path.name.casefold() in stage_names]

    destination_dir = Path(destination) / f"{arch}-windows"
    destination_dir.mkdir(parents=True, exist_ok=True)

    staged: list[Path] = []
    for source in unique:
        target = destination_dir / source.name
        shutil.copy2(source, target)
        staged.append(target)
    return staged


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Stage validated Wine multiarch runtime PE files."
    )
    parser.add_argument("source_build", type=Path, help="Wine build directory")
    parser.add_argument("destination", type=Path, help="app resource root")
    parser.add_argument("arch", choices=sorted(MACHINES), help="PE target architecture")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        staged = stage_runtime_pe(args.source_build, args.destination, args.arch)
    except (OSError, StageError) as exc:
        parser.error(str(exc))

    print(f"staged {len(staged)} {args.arch} runtime PE file(s) in {args.destination / (args.arch + '-windows')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
