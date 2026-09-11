# Bencharking (Implementation Agents)
- Before changes run `cp bench last_bench`
- After changes run `zig build bench -Doptimize=ReleaseFast > bench`

# ZT
- Read README.md for a specification of how the program works.
- Do not change the README.md
- Keep AGENTS.md up-to-date.
- Cross-platform terminal multiplexor. Public API is `src/root.zig`. Executable is `src/main.zig`.
- Pipeline: `circbuffer` → `preparse` → visible lines → `runs` → `term` → `draw`.

# Code Base
- `circbuffer.zig` — mirrored firehose buffer (default 256 KiB / 64 pages, same as vt; drain on consume)
- `preparse.zig` — vector line split + optional whitelist ESC (off by default) + SIMD high-bit UTF-8 skip
- `runs.zig` — visible-line run splitter (UTF-8 is a high-bit run, not per-cp decode)
- `term.zig` — minimal-state emulator; `feedUtf8` bulk-writes like `feedPlain`
- `draw.zig` — CPU framebuffer; line-dirty fill + uniform strip memset + SIMD glyph blit; `peekGlyph` on the blit
- `type.zig` — TrueType rasterizer, atlas, glyph LRU (codepoint → cmap → LRU, not UTF-8 bytes); ASCII 32..126 warmed into ascii slots on size change and clearAtlas; `peekGlyph` / `ensureGlyph`
- `engine.zig` — ingest / EAGAIN refresh; `Preparse.consume` → `lastLines` → `runs.split` → `term.feed`; drain parsed only; `fed` clamped to ring; `rewindInput`. Plain firehose memcpy+truncate only; queries/preparse/paint run on EAGAIN if 1/hz has passed (not per chunk, not when the ring is full). Live TUI (alt screen) feeds every parsed line, flushes the ring into the grid before overflow so in-place frames (ncmpcpp-style visualizer) are not truncated, and paints at hz while still readable. `whitelist` (default off) skips payload-bearing ESC interior newlines during consume. `selection` is a cell-stream on the visible grid; `redraw` paints it.
- `scheme.zig` — TOML config: colors + `[general] refreshrate` (hz), `whitelist` (bool, default false)
- `loop.zig` — libxev loop, 1/hz timer
- `events.zig` — input events; `encodePaste` / `filterPaste` (bracket 2004, LF→CR, strip 201~)
- `select.zig` — cell-stream selection, word/line expand, copy from visible grid
- `kitty.zig` — kitty graphics
- `daemon.zig` — JSONL protocol / TCP server
- `mux.zig` — tiling panes
- `platform.zig` — window open / close

# Rendering tests
- Cell dumps: `Term.Screen.dumpAlloc` / `dumpCellsAlloc`; fixtures in `tests/vt/*.in` (first line `cols rows`).
- PNG goldens: `tests/golden/`; mismatch writes `zig-out/screenshots/<name>` and `<name>.diff.png`.
- Bless dumps and PNGs with `ZT_UPDATE_GOLDEN=1 zig build test`.
- Dirty vs full: `tests/render.zig` (32 iters). Long run: `zig build fuzz-render -- 10000`.
- Long-running in-place updates: visualizer frames in `engine.zig` + `tests/render.zig` (CUP/ED on extra lines, ring smaller than a frame, many refreshes).
