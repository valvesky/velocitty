# Velocitty
- Read DESIGN.md for a specification of how the program works.
- Do not change the README.md
- Keep AGENTS.md up-to-date.
- Cross-platform terminal multiplexor. Executable is `src/main.zig`.
- Pipeline: `circbuffer` (line split + runs) → `vt` → `draw`.

# Release
- `zig build release` builds ReleaseFast for host-linkable Linux triples only (same arch/abi, needs X11).

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
- `scheme.zig` — TOML config (colors, font, hz, whitelist); loads Omarchy current theme; font size from Alacritty, family from fontconfig `monospace` (`omarchy font`)
- SIGUSR1/SIGUSR2 or Omarchy theme/font file change reloads colors and font in `main.zig` (`fc-match` needs process environ so HOME/fonts.conf apply)
- `loop.zig` — stub (no xev)
- `select.zig` — cell-stream selection over `vt.VtState`
- `kitty.zig` — kitty graphics
- `platform/` — window / PTY (Linux/X11)
- `main.zig` — window + PTY + fonts; `circbuffer` → `vt` → `draw` → present; event loop polls X `dpy` fd + PTY at the monitor refresh rate

# Rendering tests
- Cell dumps: `VtState.dumpAlloc` / `dumpCellsAlloc`; fixtures in `tests/vt/*.in` (first line `cols rows`).
- PNG goldens: `tests/golden/`; mismatch writes `zig-out/screenshots/<name>` and `<name>.diff.png`.
- Bless dumps and PNGs with `ZT_UPDATE_GOLDEN=1 zig build test`.
- Dirty vs full: `tests/render.zig` (32 iters). Long run: `zig build fuzz-render -- 10000`.
