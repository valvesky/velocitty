#!/usr/bin/env python3
"""Extract and repackage the Windows executable around SignPath signing."""
import argparse
import importlib.util
from pathlib import Path
import re
import zipfile


ROOT = Path(__file__).resolve().parent.parent


def _packager():
    spec = importlib.util.spec_from_file_location("velocitty_package", ROOT / "scripts" / "package.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _windows_zip(package_dir):
    package_dir = Path(package_dir)
    zips = sorted(path for path in package_dir.glob("*.zip") if path.is_file())
    if len(zips) != 1:
        names = [path.name for path in zips]
        raise RuntimeError(f"expected one Windows zip in {package_dir}, found {names}")
    return zips[0]


def _exe_entry(archive):
    matches = []
    for info in archive.infolist():
        if info.is_dir():
            continue
        name = info.filename.replace("\\", "/")
        if name.endswith("/velocitty.exe"):
            matches.append(info)
    return matches


def extract_exe(package_dir, dest):
    archive_path = _windows_zip(package_dir)
    with zipfile.ZipFile(archive_path) as archive:
        matches = _exe_entry(archive)
        if len(matches) != 1:
            found = [info.filename for info in matches]
            raise RuntimeError(f"expected one velocitty.exe in {archive_path.name}, found {found}")
        dest = Path(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(archive.read(matches[0]))
    return dest


def assert_exe_bytes(package_dir, exe):
    expected = Path(exe).read_bytes()
    if not expected:
        raise RuntimeError(f"empty executable: {exe}")
    archive_path = _windows_zip(package_dir)
    with zipfile.ZipFile(archive_path) as archive:
        matches = _exe_entry(archive)
        if len(matches) != 1:
            found = [info.filename for info in matches]
            raise RuntimeError(f"expected one velocitty.exe in {archive_path.name}, found {found}")
        actual = archive.read(matches[0])
    if actual != expected:
        raise RuntimeError("portable zip does not contain the signed executable")


def package_signed(exe, output):
    version = re.search(r'\.version = "([^"]+)"', (ROOT / "build.zig.zon").read_text())[1]
    _packager().package(version, "x86_64-windows-gnu", exe, output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    extract = commands.add_parser("extract-exe")
    extract.add_argument("packages", type=Path)
    extract.add_argument("dest", type=Path)
    check = commands.add_parser("assert-exe")
    check.add_argument("packages", type=Path)
    check.add_argument("exe", type=Path)
    pack = commands.add_parser("package-signed")
    pack.add_argument("exe", type=Path)
    pack.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.command == "extract-exe":
        extract_exe(args.packages, args.dest)
    elif args.command == "assert-exe":
        assert_exe_bytes(args.packages, args.exe)
    else:
        package_signed(args.exe, args.output)


if __name__ == "__main__":
    main()
