# Velocitty

## Font policy
- Select the primary family from configuration; when unset, resolve the system `monospace` default. Never hardcode Iosevka or another user family/path as the preferred or emergency default.
- Load fallback fonts only when a requested glyph is missing. Preserve configured fallback order and Unicode/CJK/emoji coverage; do not eagerly load every coverage font.
- Use fontconfig on Linux and native font resolution elsewhere. Verify requested fallback-family matches while preserving primary-pattern substitution.
- Parser-only benchmarks load no fonts. Rendering benchmarks follow application font selection unless explicitly overridden.

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
- Whenever updating the vs-Ghostty benchmark or its chart, regenerate the chart and refresh `docs/velocitty-vs-ghostty.png`, the image referenced by `docs/design-1.3.html`.

## Common checks
- `zig build check`: compile portable tests; `zig build test`: run them and native Peak checks.
- `python3 tests/package_test.py`: package layout checks.
- Linux inline checks (musl avoids host GNU CRT `.sframe` issues):
  ```sh
  zig test src/main.zig src/type/stb_truetype.c src/stb_image.c src/platform/font.c -Ilib -lc -target x86_64-linux-musl
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
