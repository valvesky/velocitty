#!/usr/bin/env python3
"""Build Linux tarballs, Windows ZIP/installers, and macOS app/DMG packages."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def copy(source, target, executable=False):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    target.chmod(0o755 if executable else 0o644)


def bundle(binary, destination, version, universal=None):
    app = destination / "Velocitty.app"
    contents = app / "Contents"
    executable = contents / "MacOS" / "velocitty"
    copy(binary, executable, True)
    if universal:
        subprocess.run(["lipo", "-create", str(binary), str(universal), "-output", str(executable)], check=True)
    copy(ROOT / "assets/icon.icns", contents / "Resources" / "velocitty.icns")
    copy(ROOT / "example.config.toml", contents / "Resources" / "example.config.toml")
    copy(ROOT / "LICENSE", contents / "Resources" / "LICENSE")
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump({
            "CFBundleName": "Velocitty",
            "CFBundleDisplayName": "Velocitty",
            "CFBundleIdentifier": "io.github.valvesky.velocitty",
            "CFBundleExecutable": "velocitty",
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "velocitty.icns",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "LSMinimumSystemVersion": "11.0",
            "LSApplicationCategoryType": "public.app-category.developer-tools",
            "NSHighResolutionCapable": True,
        }, stream)
    return app


def package(version, triple, binary, output, *, portable_only=False, app_only=False, universal=None):
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    binary = Path(binary).resolve()
    name = f"velocitty-{version}-{triple}"
    with tempfile.TemporaryDirectory(prefix="velocitty-package-") as temp:
        stage = Path(temp)
        root = stage / name
        root.mkdir()
        if "windows" in triple:
            copy(binary, root / "velocitty.exe", True)
            copy(ROOT / "LICENSE", root / "LICENSE")
            copy(ROOT / "example.config.toml", root / "example.config.toml")
            archive = output / f"{name}.zip"
            with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as stream:
                for file in sorted(root.rglob("*")):
                    if file.is_file():
                        stream.write(file, file.relative_to(stage))
            print(f"wrote {archive}")
            if not portable_only:
                iscc = shutil.which("ISCC") or shutil.which("iscc")
                if not iscc and os.name == "nt":
                    candidate = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "Inno Setup 6" / "ISCC.exe"
                    if candidate.is_file():
                        iscc = str(candidate)
                if not iscc:
                    raise RuntimeError("Inno Setup 6 is required for the Windows installer; use --portable-only for ZIP only")
                subprocess.run([
                    iscc, f"/DAppVersion={version}", f"/DSourceDir={root}",
                    f"/DOutputDir={output}", f"/DOutputName={name}-setup",
                    str(ROOT / "scripts" / "windows.iss"),
                ], check=True)
        elif "macos" in triple:
            app = bundle(binary, root, version, universal)
            if app_only:
                target = output / "Velocitty.app"
                if target.exists():
                    raise FileExistsError(target)
                shutil.copytree(app, target)
                return
            if sys.platform != "darwin":
                raise RuntimeError("DMG creation requires macOS; use --app-only to prepare an app bundle elsewhere")
            # An ad-hoc signature permits arm64 execution; this is not Developer ID signing.
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
            subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
            (root / "Applications").symlink_to("/Applications", target_is_directory=True)
            archive = output / f"{name}.dmg"
            subprocess.run([
                "hdiutil", "create", "-volname", "Velocitty", "-srcfolder", str(root),
                "-ov", "-format", "UDZO", str(archive),
            ], check=True)
            subprocess.run(["hdiutil", "verify", str(archive)], check=True)
            print(f"wrote {archive}")
        elif "linux" in triple:
            copy(binary, root / "bin" / "velocitty", True)
            copy(ROOT / "assets/velocitty.desktop", root / "share/applications/velocitty.desktop")
            copy(ROOT / "assets/icon.png", root / "share/icons/hicolor/512x512/apps/velocitty.png")
            copy(ROOT / "velocitty.1", root / "share/man/man1/velocitty.1")
            copy(ROOT / "LICENSE", root / "LICENSE")
            copy(ROOT / "example.config.toml", root / "example.config.toml")
            archive = output / f"{name}.tar.gz"
            with tarfile.open(archive, "w:gz") as stream:
                stream.add(root, arcname=name)
            print(f"wrote {archive}")
        else:
            raise ValueError(f"unsupported package target: {triple}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("triple")
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--portable-only", action="store_true")
    parser.add_argument("--app-only", action="store_true")
    parser.add_argument("--universal", type=Path, help="second architecture to combine into the Mac app")
    args = parser.parse_args()
    package(args.version, args.triple, args.binary, args.output,
            portable_only=args.portable_only, app_only=args.app_only, universal=args.universal)


if __name__ == "__main__":
    main()
