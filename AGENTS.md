# Velocitty

## Project rules
- Ask before changing or correcting any comment that starts with NOTE
- Do not change `README.md`.
- Keep this file concise and current: rules and critical invariants belong here; implementation details and command catalogs belong in the linked references.
- Omarchy-first terminal emulator, with Windows and macOS ports. Preserve technical terminal terminology and integration identifiers.
- Use Peak (`vendor/godstack/Peak`, wrapped by `src/platform/`) for windowing, input, clipboard, PTYs, and process I/O. Linux prefers Wayland, then X11.
- Read only relevant files; use `rg` to locate functions before loading large modules.

## Code map
- `src/main.zig`: executable and active event loop.
- Input pipeline: `circbuffer.zig` (owns `preparser.zig` run preparation) → `vt.zig` → `draw.zig` → Peak present.
- `grid.zig`: cells, interned styles, scrollback, and reflow.
- `c0.zig`, `esc.zig`, `csi.zig`, `osc.zig`, `dcs.zig`: protocol dispatch; `csiparse.zig`: shared CSI parser.
- `kitty.zig`, `sixel.zig`: image storage and graphics protocols.
- `type.zig`, `type/`, `simd.zig`: fonts, rasterization, and SIMD utilities.
- `scheme.zig`: theme/config loading; `key.zig` and `select.zig`: key encoding and selection.
- Desktop metadata, Windows resources, and all icon formats live in `assets/`; the manual Unicode rendering fixture is `tests/fixtures/unicode.txt`.
- `assets/icon.svg` is the canonical icon. Regenerate other formats with `python3 scripts/branding.py --icon-only` (omit the flag only when intentionally updating the wordmark/GIF).
- `docs/index.html` and `docs/design-1.3.html` share `docs/style.css`.

## Critical invariants
- The mirrored input ring is 1 MiB. Bound and reuse parser metadata independently of ring size; retain live lookahead under pressure. Never overwrite unconsumed bytes or poll PTY input with a 0 ms timeout.
- Firehose draining may omit paint/history for content no longer visible, not state changes. Visible cells, cursor, modes, replies, palette, and images must match an exact parse. Keep graphics and state-altering escapes in order; preserve incomplete sequences across reads.
- Styles are shared by both grids. Never retain a style id across a call that may intern/compact styles; register cell/tail roots after reallocations. Compaction/recolor invalidates renderer snapshots via `Styles.gen`.
- Image payload ownership must survive stream-buffer handoff and lazy decode. Free placed images when their last placement expires; keep never-placed transmissions until placement/delete within store limits.
- PTY writes queue on backpressure and flush in order without blocking. Output firehose tagging must never affect keyboard/paste delivery. Filter pasted control sequences; never fall back to raw paste on allocation failure.
- Build Peak with `PEAK_NO_GAMEPAD`; global joystick input must not become window pointer input. Wayland hit regions use logical bounds despite scaled buffers; input follows the entered surface.
- Keep PTY `OPOST|ONLCR`. Windows ConPTY children need invalid standard handles with `STARTF_USESTDHANDLES`; quote argv only when needed (cmd.exe ignores quoted switches).
- Resolve fonts through fontconfig without hardcoded user families. Verify custom/built-in fallback family matches; preserve primary-pattern substitution.

## Common checks
- `zig build check`: compile portable tests; `zig build test`: run them and native Peak checks.
- `python3 tests/package_test.py`: package layout checks.
- Linux inline checks (musl avoids host GNU CRT `.sframe` issues):
  ```sh
  zig test src/main.zig src/type/stb_truetype.c src/stb_image.c -Ilib -lc -target x86_64-linux-musl
  zig test src/firehose_test.zig src/stb_image.c -Ilib -lc -target x86_64-linux-musl
  ```
- Select targeted checks from the testing reference. Rendering regressions live inline in `src/draw.zig`; there is no standalone golden/render harness.
- Report checks actually run, observed outcomes, and skips; do not copy historical pass counts.

## Task-specific references
Read only what is relevant, before modifying the corresponding subsystem:
- [Codebase map and ownership details](docs/agents/map.md)
- [Regression tests and standalone Peak checks](docs/agents/testing.md)
- [Benchmark workloads and comparison methodology](docs/agents/benchmarks.md)
- [Release, packaging, CI, and installation](docs/agents/release.md)
