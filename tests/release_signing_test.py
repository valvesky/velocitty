"""Release signing layout and the choice between unsigned and signed Windows packages."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile


ROOT = Path(__file__).resolve().parent.parent
NS = {"ac": "http://signpath.io/artifact-configuration/v1"}


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


publisher = load("publish_release", ROOT / "scripts/publish_release.py")
signer = load("windows_sign", ROOT / "scripts/windows_sign.py")
packager = load("package", ROOT / "scripts/package.py")


def expected(version="1.2.0"):
    names = {
        f"velocitty-{version}-{arch}-linux-{abi}.tar.gz"
        for arch in ("x86_64", "aarch64") for abi in ("gnu", "musl")
    }
    names.update({
        f"velocitty-{version}-x86_64-windows-gnu.zip",
        f"velocitty-{version}-x86_64-windows-gnu-setup.exe",
        f"velocitty-{version}-universal-macos.dmg",
    })
    return names


def write(root, relative, content):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    return path


class ArtifactConfiguration(unittest.TestCase):
    def test_github_artifact_zip_signs_one_pe_file(self):
        root = ET.parse(ROOT / ".signpath/artifact-configuration.xml").getroot()
        self.assertEqual(root.tag, "{http://signpath.io/artifact-configuration/v1}artifact-configuration")
        children = [child.tag for child in root]
        self.assertEqual(children, ["{http://signpath.io/artifact-configuration/v1}zip-file"])
        pe = root.find("ac:zip-file/ac:pe-file", NS)
        self.assertEqual(pe.get("path"), "*.exe")
        self.assertEqual(pe.get("min-matches"), "1")
        self.assertEqual(pe.get("max-matches"), "1")
        sign = pe.find("ac:authenticode-sign", NS)
        self.assertIsNotNone(sign)
        self.assertEqual(sign.get("description"), "Velocitty")
        self.assertEqual(sign.get("description-url"), "https://github.com/valvesky/velocitty")


class ReleaseSelection(unittest.TestCase):
    def fill(self, root, windows):
        version = "1.2.0"
        for arch in ("x86_64", "aarch64"):
            for abi in ("gnu", "musl"):
                write(root, f"packages-linux/velocitty-{version}-{arch}-linux-{abi}.tar.gz", b"linux")
        write(root, f"packages-macos/velocitty-{version}-universal-macos.dmg", b"mac")
        write(root, f"{windows}/velocitty-{version}-x86_64-windows-gnu.zip", b"zip-" + windows.encode())
        write(root, f"{windows}/velocitty-{version}-x86_64-windows-gnu-setup.exe", b"setup-" + windows.encode())

    def test_unsigned_windows_packages_are_used_when_nothing_was_signed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.fill(root, "packages-windows")
            write(root, "signpath-unsigned-setup/velocitty-1.2.0-x86_64-windows-gnu-setup.exe", b"input")
            chosen = publisher.select_release_files(root, expected())
            self.assertEqual(chosen["velocitty-1.2.0-x86_64-windows-gnu.zip"].read_bytes(), b"zip-packages-windows")
            self.assertEqual(
                chosen["velocitty-1.2.0-x86_64-windows-gnu-setup.exe"].read_bytes(),
                b"setup-packages-windows",
            )

    def test_signed_windows_packages_replace_unsigned_ones(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.fill(root, "packages-windows")
            self.fill(root, "packages-windows-signed")
            write(root, "signpath-unsigned-velocitty-exe/velocitty.exe", b"MZ unsigned")
            write(root, "signpath-unsigned-setup/velocitty-1.2.0-x86_64-windows-gnu-setup.exe", b"input")
            chosen = publisher.select_release_files(root, expected())
            self.assertEqual(chosen["velocitty-1.2.0-x86_64-windows-gnu.zip"].read_bytes(), b"zip-packages-windows-signed")
            self.assertEqual(
                chosen["velocitty-1.2.0-x86_64-windows-gnu-setup.exe"].read_bytes(),
                b"setup-packages-windows-signed",
            )
            self.assertTrue(all("signpath-unsigned" not in path.parts for path in chosen.values()))

    def test_incomplete_signed_artifact_is_not_mixed_with_unsigned_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.fill(root, "packages-windows")
            write(root, "packages-windows-signed/velocitty-1.2.0-x86_64-windows-gnu.zip", b"only-zip")
            with self.assertRaises(RuntimeError) as raised:
                publisher.select_release_files(root, expected())
            self.assertIn("velocitty-1.2.0-x86_64-windows-gnu-setup.exe", str(raised.exception))

    def test_duplicate_inside_one_artifact_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.fill(root, "packages-windows")
            write(root, "packages-linux/nested/velocitty-1.2.0-x86_64-linux-gnu.tar.gz", b"again")
            with self.assertRaisesRegex(RuntimeError, "duplicate package"):
                publisher.select_release_files(root, expected())


class WindowsSigningInputs(unittest.TestCase):
    def test_extracts_the_packaged_executable(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            binary = temp / "fixture.exe"
            binary.write_bytes(b"MZ fixture")
            packager.package("1.2.0", "x86_64-windows-gnu", binary, temp / "packages", portable_only=True)
            dest = temp / "unsigned-exe" / "velocitty.exe"
            signer.extract_exe(temp / "packages", dest)
            self.assertEqual(dest.read_bytes(), b"MZ fixture")
            signer.assert_exe_bytes(temp / "packages", dest)

    def test_rejects_a_zip_whose_executable_was_replaced(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            binary = temp / "fixture.exe"
            binary.write_bytes(b"MZ fixture")
            packager.package("1.2.0", "x86_64-windows-gnu", binary, temp / "packages", portable_only=True)
            other = temp / "other.exe"
            other.write_bytes(b"MZ signed")
            with self.assertRaisesRegex(RuntimeError, "does not contain the signed executable"):
                signer.assert_exe_bytes(temp / "packages", other)

    def test_backslashes_in_zip_entry_names_still_match(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            archive_path = temp / "velocitty-1.2.0-x86_64-windows-gnu.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("velocitty-1.2.0-x86_64-windows-gnu\\velocitty.exe", b"MZ windows")
            dest = temp / "velocitty.exe"
            signer.extract_exe(temp, dest)
            self.assertEqual(dest.read_bytes(), b"MZ windows")


if __name__ == "__main__":
    unittest.main()
