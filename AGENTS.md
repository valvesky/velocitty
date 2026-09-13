# Velocitty
- Read DESIGN.md for a specification of how the program works.
- Do not change the README.md
- Keep AGENTS.md up-to-date.
- Cross-platform terminal multiplexor. Executable is `src/main.zig`.
- Pipeline: `circbuffer` (line split + runs) → `vt` → `draw`.

# Release
- `zig build release` builds ReleaseFast for host-linkable Linux triples only (same arch/abi, needs X11).
- `zig build package` runs `release` and writes `packages/velocitty-<version>-<triple>.tar.gz` (binary, desktop, icon).

# Install
- `zig build` / `zig build install` is Zig's prefix install (default `zig-out/`: binary, `velocitty.desktop`, icon).
- `zig build install-usr` builds ReleaseFast for the host and installs `/usr/bin/velocitty`, `/usr/share/applications/velocitty.desktop`, and the hicolor icon so it appears in the Omarchy app menu. Uses `sudo` when stdin is a TTY, otherwise `pkexec`.

# Code Base
- Read files only when necessary. Use `grep` or `rg` if you only need a specific function.
- `simd.zig` — SIMD utilities.
- `circbuffer.zig` — mirrored firehose buffer; `readPTY` (EOF or EAGAIN + 1/hz); SIMD line split + run split
- `vt.zig` — minimal-state emulator; `feedRuns` routes C0/C1/ESC/CSI/OSC/DCS/kitty
- `grid.zig` — cell buffer, cursor, scroll region, insert/delete
- `c0.zig` / `c1.zig` — C0/C1 dispatch (BS reverse-wrap)
- `esc.zig` — ESC parse + charset G0–G3 / RIS / HTS / DECALN / SS2/SS3
- `csi.zig` — CSI parse (`;` params, `:` subparams, packed privates) + apply (foot ctlseqs: SGR, CUP, DECSET, DECRQM, rectangular, kitty kbd, window ops, color stack)
- `osc.zig` — OSC 0/2 title, 4/10–12/104/110–112 colors, OSC 8 hyperlinks
- `dcs.zig` — DCS DECRQSS (DECSTBM/SGR/DECSCUSR) + iTerm sync
- `draw.zig` — CPU framebuffer; line-dirty fill + SIMD glyph blit
- `type.zig` — TrueType rasterizer, atlas, glyph LRU; `type/eastasian.zig` cell width
- `scheme.zig` — TOML config (colors, font, hz, whitelist, pad); loads Omarchy current theme; font size from Alacritty, family from fontconfig `monospace` (`omarchy font`)
- SIGUSR1/SIGUSR2 or Omarchy theme/font file change reloads colors and font in `main.zig` (`fc-match` needs process environ so HOME/fonts.conf apply)
- `loop.zig` — stub (no xev)
- `select.zig` — cell-stream selection over `vt.VtState`
- `kitty.zig` — kitty graphics (APC G: stream + file/temp, `a=q` OK replies for icat)
- `platform/` — window / PTY (Linux/X11 + XInput2); `XSetClassHint` from `--class`; PTY child is `$SHELL` or `-e` argv (`execvpe`); child env `TERM=xterm-kitty`, `KITTY_WINDOW_ID`, `COLORTERM=truecolor`; wheel from Button4/5 and XI2 scroll valuators (XWayland trackpads)
- `main.zig` — window + PTY + fonts; `circbuffer` → `vt` → `draw` → present; each tick `readPTY` (EOF or EAGAIN+1/hz) while pumping X so keys are not deferred until after the echo; drain the Xlib queue (no 32-event bail); wheel → mouse report (1000/1002/1003), alt-screen arrows, or primary history view; Ctrl+Shift+V / Shift+Insert / middle-click paste (bracketed if DECSET 2004); inner pad from `[general] pad` (default 14), scaled by Wayland output scale; font/pad/cells use CSS 96 DPI × Hyprland/`GDK_SCALE` multiplier (not X11 mm-DPI) and re-apply on focus/resize; CLI `-e`/`--` command, `--class=`, `--title=`, `--working-directory=` (xdg-terminal-exec)

# Bench
- `zig build bench` — `src/bench.zig`, ReleaseFast firehose truncate + last-N vs all-ring parse/VT timings.

# Rendering tests
- Cell dumps: `VtState.dumpAlloc` / `dumpCellsAlloc`; fixtures in `tests/vt/*.in` (first line `cols rows`).
- PNG goldens: `tests/golden/`; mismatch writes `zig-out/screenshots/<name>` and `<name>.diff.png`.
- Bless dumps and PNGs with `ZT_UPDATE_GOLDEN=1 zig build test`.
- Dirty vs full: `tests/render.zig` (32 iters). Long run: `zig build fuzz-render -- 10000`.
