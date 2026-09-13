<!-- LOGO -->
<h1>
<p align="center">
<img src="icon.png" alt="Logo" width="128">
<br>Velocitty 
</h1>
  <p align="center">
    <br />
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License: MIT"></a>
    <a href="https://github.com/valvesky/velocitty"><img src="https://img.shields.io/github/languages/top/valvesky/velocitty?style=flat-square" alt="Language"></a>
    <img src="https://img.shields.io/badge/Linux-FCC624?style=flat-square&logo=linux&logoColor=black" alt="Linux">
    <!-- <img src="https://img.shields.io/badge/Windows-0078D4?style=flat-square&logo=windows&logoColor=white" alt="Windows"> -->
    <!-- <img src="https://img.shields.io/badge/macOS-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS"> -->
    <!-- <a href="https://github.com/valvesky/velocitty/commits/master"><img src="https://img.shields.io/github/last-commit/valvesky/velocitty?style=flat-square" alt="Last commit"></a> -->
    <!-- <a href="https://github.com/valvesky/velocitty/stargazers"><img src="https://img.shields.io/github/stars/valvesky/velocitty?style=flat-square" alt="Stars"></a> -->
    <!-- <br /> -->
    <!-- <br /> -->
    <!-- <a href="#features">Features</a> -->
    <!-- · -->
    <!-- <a href="#install">Install</a> -->
    <!-- · -->
    <!-- <a href="#build">Build</a> -->
    <!-- · -->
    <!-- <a href="#shoutouts">Shoutouts</a> -->
  </p>
</p>

Velocitty is a lightning-fast cross-platform terminal.

## Features
- Lightning fast (literally bottlenecked by the kernel)
- `cat` large files.
- Cross-platform.
- CPU rendered.
- Image support (kitty protocol)
- Extensive unicode support.
- Simple config file.
- No external dependencies.
- Omarchy color palette change and font change (live reloaded).

## Anti-Features
- No kitty style CTL.
- No multiplexing.
- No GPU.

## Install

### Releases

See [releases](https://github.com/valvesky/velocitty/releases) tab.
Unzip then copy to `/usr/bin`

### By Building From Master

Just clone the repo and run:
```
git clone https://github.com/valvesky/velocitty
cd velocitty
zig build install-usr
```

## Config

Config file is `~/.config/velocitty/config.toml` and will be overwritten by omarchy color scheme.

See `example.config.toml` for an example config file.
It's purposefully similar to `alacritty` in many ways.


## Supported Platforms 
- [x] Linux (Wayland)
- [ ] Linux (X11)
- [ ] macOS
- [ ] Windows

## Shoutouts
- [st](https://st.suckless.org) --- how to suck less
- [refterm](https://github.com/cmuratori/refterm) --- how to black magic
- [kitty](https://sw.kovidgoyal.net/kitty/) — how to meow
- [ghostty](https://ghostty.org) --- how to render glyph good
- [foot](https://codeberg.org/dnkl/foot) --- how to vt parsing good

---

