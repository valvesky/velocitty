# Bencharking (Implementation Agents)
- Before changes run `cp bench last_bench`
- After changes run `zig build bench -Doptimize=ReleaseFast > bench`

# ZT
- Read README.md for a specification of how the program works.
- Do not change the README.md
- Keep AGENTS.md up-to-date.
- Cross-platform terminal multiplexor. Executable is `src/main.zig`.
- Pipeline: `circbuffer` (line split + runs) → `vt` → `draw`.

# Code Base
- `circbuffer.zig` — mirrored firehose buffer; SIMD line split + run split
- `vt.zig` — minimal-state emulator; `feedRuns` routes C0/C1/ESC/CSI/OSC/kitty
- `grid.zig` — cell buffer, cursor, scroll region, insert/delete
- `c0.zig` / `c1.zig` — C0/C1 dispatch
- `esc.zig` — ESC parse + charset / RIS / index
- `csi.zig` — CSI parse + apply (SGR, CUP, modes, edit)
- `osc.zig` — OSC 8 hyperlinks
- `draw.zig` — CPU framebuffer; line-dirty fill + SIMD glyph blit
- `type.zig` — TrueType rasterizer, atlas, glyph LRU; `type/eastasian.zig` cell width
- `scheme.zig` — TOML config (colors, hz, whitelist) — still imports missing `term.zig`
- `loop.zig` — stub (no xev)
- `events.zig` — empty
- `select.zig` — cell-stream selection — still imports missing `term.zig`
- `kitty.zig` — kitty graphics
- `platform/` — window / PTY (Linux/X11)
- `main.zig` — window + PTY shell; does not yet ingest PTY or paint cells

# Rendering tests
- Cell dumps: `VtState.dumpAlloc` / `dumpCellsAlloc`; fixtures in `tests/vt/*.in` (first line `cols rows`).
- PNG goldens: `tests/golden/`; mismatch writes `zig-out/screenshots/<name>` and `<name>.diff.png`.
- Bless dumps and PNGs with `ZT_UPDATE_GOLDEN=1 zig build test`.
- Dirty vs full: `tests/render.zig` (32 iters). Long run: `zig build fuzz-render -- 10000`.
