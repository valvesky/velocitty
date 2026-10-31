<!-- <p align="center"> -->
<!--   <picture> -->
<!--     <source srcset="assets/wordmark.svg" media="(prefers-reduced-motion: reduce)"> -->
<!--     <img src="assets/velocitty.gif" alt="Velocitty" width="960"> -->
<!--   </picture> -->
<!-- </p> -->

<p align="center">
  <img src="icon.png" alt="Velocitty icon" width="128">
</p>

<p align="center">
    <br />
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License: MIT"></a>
    <a href="https://github.com/valvesky/velocitty"><img src="https://img.shields.io/github/languages/top/valvesky/velocitty?style=flat-square" alt="Language"></a>
    <a href="https://github.com/valvesky/velocitty/releases/latest"><img src="https://img.shields.io/github/v/release/valvesky/velocitty?style=flat-square" alt="Latest release"></a>
    <a href="https://github.com/valvesky/velocitty/actions/workflows/release.yml"><img src="https://img.shields.io/github/actions/workflow/status/valvesky/velocitty/release.yml?branch=main&style=flat-square" alt="Build"></a>
    <img src="https://img.shields.io/badge/Linux-FCC624?style=flat-square&logo=linux&logoColor=black" alt="Linux">
    <img src="https://img.shields.io/badge/Windows-0078D6?style=flat-square&logo=windows&logoColor=white" alt="Windows">
    <img src="https://img.shields.io/badge/macOS-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS">
    <a href="https://github.com/valvesky/velocitty/commits/main"><img src="https://img.shields.io/github/last-commit/valvesky/velocitty?style=flat-square" alt="Last commit"></a>
    <a href="https://github.com/valvesky/velocitty/stargazers"><img src="https://img.shields.io/github/stars/valvesky/velocitty?style=flat-square" alt="Stars"></a>
    <br />
    <a href="#features">Features</a>
    ·
    <a href="#install">Install</a>
    ·
    <a href="#build">Build</a>
    ·
    <a href="#config">Config</a>
    ·
    <a href="#shoutouts">Shoutouts</a>
</p>

Velocitty is a lightning-fast terminal for Omarchy. 

Releases for Windows and MacOS are available.



It's a streamlined version of my GPU-accelerated terminal multiplexer [VT](https://github.com/valvesky/vt).

## Features
- Lightning fast (literally bottlenecked by the kernel)
- `cat` large files.
- Cross-platform through Peak: Linux (Wayland/X11), Windows (ConPTY), and macOS (AppKit).
- CPU rendered.
- Image support (sixel)
- Extensive unicode support.
- Simple config file.
- Uses native system libraries and fonts.
- Omarchy color palette change and font change (live reloaded).

## Anti-Features
- No kitty style CTL.
- No multiplexing.
- No GPU.

## Install

Download from [releases](https://github.com/valvesky/velocitty/releases).

- **Linux:** GNU and musl tarballs for x86_64 and aarch64. Extract the archive and install the binary, desktop entry, icon, and man page under your preferred prefix.
- **Windows 10 1903+:** run the per-user installer `.exe`, or extract the portable `.zip` and launch `velocitty.exe`.
- **macOS 11+:** open the universal `.dmg` and drag `Velocitty.app` into Applications. It supports Intel and Apple Silicon.

Windows and macOS packages are unsigned.
If Windows shows SmartScreen, use **More info > Run anyway**.
On macOS, allow Velocitty in **System Settings -> Privacy & Security** after the first launch attempt.

Musl packages use dynamic linking: install them on a musl system such as Alpine, with its musl loader and native Wayland/X11 libraries. GNU packages are for glibc systems such as Omarchy. `SHA256SUMS` accompanies the release downloads.

## Build

Requires Zig 0.17 or newer.
Linux builds need X11/Wayland development headers; the terminal loads the desktop libraries at runtime and uses `fc-match` for font discovery. macOS builds need Xcode Command Line Tools. Windows builds use Zig's bundled toolchain and system libraries.

```
git clone --recursive https://github.com/valvesky/velocitty
cd velocitty
zig build -Doptimize=ReleaseFast
```

The executable is installed in `zig-out/bin/`. On Omarchy, `zig build install-usr` installs the terminal and app-menu entry under `/usr`.

`zig build test` runs inline and portable Peak regressions. `zig build check` compiles the app and tests without running them, useful for cross-compilation. Release/package builds can be restricted with `-Drelease-os=linux`, `windows`, or `macos`; Windows installers need Inno Setup 6, and DMG creation runs on macOS.

## Config

| Platform | Default config file |
| --- | --- |
| Linux | `~/.config/velocitty/config.toml` |
| Windows | `%APPDATA%/velocitty/config.toml` |
| macOS | `~/Library/Application Support/velocitty/config.toml` |

`$XDG_CONFIG_HOME/velocitty/config.toml` overrides these locations when set. A `config.toml` in the working directory overlays the user file. On Linux, Omarchy theme colors overlay the configured palette without rewriting the file.

See [example.config.toml](example.config.toml). The TOML subset is similar to Alacritty. Font families use fontconfig on Linux, GDI on Windows, and Core Text on macOS; `monospace` selects the desktop/default monospace font. Installed fallback families can be listed in priority order. Config changes reload automatically; Linux/macOS also accept SIGUSR1 or SIGUSR2.

Desktop notifications and kitty file/temporary-file image transfers currently use the Linux implementation. Streamed kitty graphics and sixel work across platforms; use `icat --transfer-mode=stream` on Windows/macOS.


## Special Thanks
- Mitchell Hashimoto 
    1. https://x.com/mitchellh/status/2115292243443519571
    2. 

## Shoutouts

- [refterm](https://github.com/cmuratori/refterm) --- Most of the
- [kitty](https://sw.kovidgoyal.net/kitty/) --- how to meow
- [ghostty](https://ghostty.org) --- how to render glyph good
- [foot](https://codeberg.org/dnkl/foot) --- Profile optimized glyph parsing.
- [vt](https://github.com/valvesky/vt) --- My previous shot at a terminal.
