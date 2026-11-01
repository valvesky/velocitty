"""Verify release payload names, app metadata, icons and executable permissions."""
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("package", ROOT / "scripts/package.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class Packages(unittest.TestCase):
    def test_linux_layout_and_executable(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            binary = temp / "binary"
            binary.write_bytes(b"ELF fixture")
            packager.package("1.2.0", "x86_64-linux-musl", binary, temp / "out")
            with tarfile.open(next((temp / "out").glob("*.tar.gz"))) as archive:
                files = {item.name: item for item in archive.getmembers()}
                root = "velocitty-1.2.0-x86_64-linux-musl"
                self.assertEqual(files[f"{root}/bin/velocitty"].mode, 0o755)
                self.assertIn(f"{root}/share/applications/velocitty.desktop", files)
                self.assertIn(f"{root}/share/man/man1/velocitty.1", files)
                self.assertIn(f"{root}/example.config.toml", files)
                self.assertIn(f"{root}/Makefile", files)
                archive.extractall(temp / "extracted", filter="data")
            package = temp / "extracted" / root
            dest = temp / "dest"
            args = ["make", "PREFIX=/opt/velocitty", f"DESTDIR={dest}"]
            subprocess.run(args + ["install"], cwd=package, check=True)
            prefix = dest / "opt/velocitty"
            for path in ("bin/velocitty", "share/applications/velocitty.desktop",
                         "share/icons/hicolor/512x512/apps/velocitty.png", "share/man/man1/velocitty.1"):
                self.assertTrue((prefix / path).is_file(), path)
            self.assertEqual((prefix / "bin/velocitty").stat().st_mode & 0o777, 0o755)
            subprocess.run(args + ["uninstall"], cwd=package, check=True)
            self.assertFalse((prefix / "bin/velocitty").exists())
            self.assertFalse((prefix / "share/applications/velocitty.desktop").exists())
            self.assertFalse((prefix / "share/icons/hicolor/512x512/apps/velocitty.png").exists())
            self.assertFalse((prefix / "share/man/man1/velocitty.1").exists())

    def test_windows_retains_exe_suffix_and_no_linux_desktop(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            binary = temp / "fixture.exe"
            binary.write_bytes(b"MZ fixture")
            packager.package("1.2.0", "x86_64-windows-gnu", binary, temp / "out", portable_only=True)
            with zipfile.ZipFile(next((temp / "out").glob("*.zip"))) as archive:
                self.assertEqual(archive.read("velocitty-1.2.0-x86_64-windows-gnu/velocitty.exe"), b"MZ fixture")
                self.assertFalse(any(name.endswith(".desktop") for name in archive.namelist()))

    def test_mac_bundle_metadata_and_icon(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            binary = temp / "binary"
            binary.write_bytes(b"Mach-O fixture")
            packager.package("1.2.0", "universal-macos", binary, temp / "out", app_only=True)
            app = temp / "out/Velocitty.app/Contents"
            info = plistlib.loads((app / "Info.plist").read_bytes())
            self.assertEqual(info["CFBundleExecutable"], "velocitty")
            self.assertEqual(info["CFBundleShortVersionString"], "1.2.0")
            self.assertTrue((app / "Resources/velocitty.icns").read_bytes().startswith(b"icns"))
            self.assertEqual((app / "MacOS/velocitty").stat().st_mode & 0o777, 0o755)


if __name__ == "__main__":
    unittest.main()
