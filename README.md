```
 ▄█    █▄     ▄████████  ▄█        ▄██████▄   ▄████████  ▄█      ███         ███     ▄██   ▄   
███    ███   ███    ███ ███       ███    ███ ███    ███ ███  ▀█████████▄ ▀█████████▄ ███   ██▄ 
███    ███   ███    █▀  ███       ███    ███ ███    █▀  ███▌    ▀███▀▀██    ▀███▀▀██ ███▄▄▄███ 
███    ███  ▄███▄▄▄     ███       ███    ███ ███        ███▌     ███   ▀     ███   ▀ ▀▀▀▀▀▀███ 
███    ███ ▀▀███▀▀▀     ███       ███    ███ ███        ███▌     ███         ███     ▄██   ███ 
███    ███   ███    █▄  ███       ███    ███ ███    █▄  ███      ███         ███     ███   ███ 
███    ███   ███    ███ ███▌    ▄ ███    ███ ███    ███ ███      ███         ███     ███   ███ 
 ▀██████▀    ██████████ █████▄▄██  ▀██████▀  ████████▀  █▀      ▄████▀      ▄████▀    ▀█████▀  
                        ▀
```

<p align="center">
    <br />
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License: MIT"></a>
    <a href="https://github.com/valvesky/velocitty"><img src="https://img.shields.io/github/languages/top/valvesky/velocitty?style=flat-square" alt="Language"></a>
    <img src="https://img.shields.io/badge/Linux-FCC624?style=flat-square&logo=linux&logoColor=black" alt="Linux">
    <a href="https://github.com/valvesky/velocitty/commits/master"><img src="https://img.shields.io/github/last-commit/valvesky/velocitty?style=flat-square" alt="Last commit"></a>
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

Velocitty is a lightning-fast terminal for omarchy.

It's a streamlined version of my GPU-accelerated terminal multiplexer [VT](https://github.com/valvesky/velocitty).

## Features
- Lightning fast (literally bottlenecked by the kernel)
- `cat` large files.
- Cross-platform.
- CPU rendered.
- Image support (sixel)
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

## Shoutouts
- [vt](https://github.com/valvesky/vt) --- older brother
- [st](https://st.suckless.org) --- how to suck less
- [refterm](https://github.com/cmuratori/refterm) --- how to black magic
- [kitty](https://sw.kovidgoyal.net/kitty/) --- how to meow
- [ghostty](https://ghostty.org) --- how to render glyph good
- [foot](https://codeberg.org/dnkl/foot) --- how to vt parsing good
