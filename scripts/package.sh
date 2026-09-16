#!/usr/bin/env bash
# Stage a release tree and write packages/velocitty-<version>-<triple>.tar.gz
set -euo pipefail

if [[ $# -ne 7 ]]; then
    echo "usage: $0 <version> <triple> <velocitty-bin> <desktop> <icon.png> <manpage> <out-dir>" >&2
    exit 2
fi

version=$1
triple=$2
bin=$(realpath "$3")
desktop=$(realpath "$4")
icon=$(realpath "$5")
manpage=$(realpath "$6")
out_dir=$(realpath -m "$7")

name="velocitty-${version}-${triple}"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/$name/bin" \
    "$stage/$name/share/applications" \
    "$stage/$name/share/icons/hicolor/512x512/apps" \
    "$stage/$name/share/man/man1"

install -Dm755 "$bin" "$stage/$name/bin/velocitty"
install -Dm644 "$desktop" "$stage/$name/share/applications/velocitty.desktop"
install -Dm644 "$icon" "$stage/$name/share/icons/hicolor/512x512/apps/velocitty.png"
install -Dm644 "$manpage" "$stage/$name/share/man/man1/velocitty.1"

mkdir -p "$out_dir"
tar -C "$stage" -czf "$out_dir/${name}.tar.gz" "$name"
echo "wrote $out_dir/${name}.tar.gz"
