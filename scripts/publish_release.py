#!/usr/bin/env python3
"""Publish a complete, tested cross-platform release from GitHub Actions."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True).strip()


WINDOWS_UNSIGNED = "packages-windows"
WINDOWS_SIGNED = "packages-windows-signed"
OTHER_RELEASE_ARTIFACTS = ("packages-linux", "packages-macos")


def windows_artifact_name(root):
    signed = Path(root) / WINDOWS_SIGNED
    if signed.is_dir() and any(path.is_file() for path in signed.rglob("*")):
        return WINDOWS_SIGNED
    return WINDOWS_UNSIGNED


def select_release_files(root, expected):
    """Choose the files to publish from a `gh run download` directory.

    Windows packages come from packages-windows-signed when that artifact
    exists, and from packages-windows otherwise. Other artifact directories,
    including the unsigned PE files uploaded only as SignPath inputs, are ignored.
    """
    root = Path(root)
    chosen = {}
    for name in (*OTHER_RELEASE_ARTIFACTS, windows_artifact_name(root)):
        directory = root / name
        if not directory.is_dir():
            continue
        for file in directory.rglob("*"):
            if not file.is_file():
                continue
            if file.name in chosen:
                raise RuntimeError(f"duplicate package: {file.name}")
            chosen[file.name] = file
    actual = set(chosen)
    if actual != expected:
        raise RuntimeError(f"release package mismatch: missing={expected - actual}, extra={actual - expected}")
    return chosen


def main():
    version = re.search(r'\.version = "([^"]+)"', Path("build.zig.zon").read_text())[1]
    tag = f"v{version}"
    commit = os.environ["RELEASE_COMMIT"]
    repo = os.environ["GH_REPO"]
    with tempfile.TemporaryDirectory(prefix="velocitty-release-") as temp:
        temp = Path(temp)
        subprocess.run(["gh", "run", "download", os.environ["GITHUB_RUN_ID"], "--repo", repo, "--dir", str(temp)], check=True)
        dist = Path("dist")
        dist.mkdir(exist_ok=True)
        expected = {
            f"velocitty-{version}-{arch}-linux-{abi}.tar.gz"
            for arch in ("x86_64", "aarch64") for abi in ("gnu", "musl")
        } | {
            f"velocitty-{version}-x86_64-windows-gnu.zip",
            f"velocitty-{version}-x86_64-windows-gnu-setup.exe",
            f"velocitty-{version}-universal-macos.dmg",
        }
        for name, file in select_release_files(temp, expected).items():
            shutil.copyfile(file, dist / name)
        sums = []
        for name in sorted(expected):
            file = dist / name
            if file.stat().st_size == 0:
                raise RuntimeError(f"empty package: {name}")
            sums.append(f"{hashlib.sha256(file.read_bytes()).hexdigest()}  {name}\n")
        (dist / "SHA256SUMS").write_text("".join(sums))
        found = subprocess.run(["gh", "release", "view", tag, "--repo", repo, "--json", "isDraft,targetCommitish"], capture_output=True, text=True)
        if found.returncode == 0:
            release = json.loads(found.stdout)
            if not release["isDraft"] or release["targetCommitish"] != commit:
                raise RuntimeError(f"{tag} already exists; refusing to overwrite a published or unrelated release")
        else:
            subprocess.run(["gh", "release", "create", tag, "--repo", repo, "--draft",
                            "--title", f"Velocitty {version}", "--notes-file", "RELEASE_NOTES.md",
                            "--target", commit], check=True)
        subprocess.run(["gh", "release", "upload", tag, "--repo", repo, "--clobber",
                        *map(str, sorted(dist.iterdir()))], check=True)
        uploaded = json.loads(gh("release", "view", tag, "--repo", repo, "--json", "assets"))
        if {asset["name"] for asset in uploaded["assets"]} != expected | {"SHA256SUMS"}:
            raise RuntimeError("uploaded assets do not match the complete release")
        subprocess.run(["gh", "release", "edit", tag, "--repo", repo, "--draft=false", "--latest"], check=True)
        print(gh("release", "view", tag, "--repo", repo, "--json", "url,isDraft,assets"))


if __name__ == "__main__":
    main()
