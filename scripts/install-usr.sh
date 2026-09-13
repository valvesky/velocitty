#!/usr/bin/env bash
# Copy the host ReleaseFast binary, desktop entry, and icon to /usr.
# Re-execs via sudo (TTY) or pkexec (no TTY) when not already root.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <velocitty-bin> <desktop> <icon.png>" >&2
    exit 2
fi

bin=$(realpath "$1")
desktop=$(realpath "$2")
icon=$(realpath "$3")
self=$(realpath "$0")

if [[ $(id -u) -ne 0 ]]; then
    if [[ -t 0 ]]; then
        exec sudo "$self" "$bin" "$desktop" "$icon"
    fi
    exec pkexec "$self" "$bin" "$desktop" "$icon"
fi

install -Dm755 "$bin" /usr/bin/velocitty
install -Dm644 "$desktop" /usr/share/applications/velocitty.desktop
install -Dm644 "$icon" /usr/share/icons/hicolor/512x512/apps/velocitty.png
gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
