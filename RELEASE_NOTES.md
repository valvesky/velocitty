# Velocitty 1.3.0

Velocitty 1.3 redesigns input handling around a mirrored 1 MiB ring buffer and a pre-parser. Under input pressure, it skips cell painting only when later input proves it obsolete, while preserving ordered terminal-state processing. Large control strings use separate stream storage rather than being limited to the input ring.

## Performance and output handling

- Bounded, reusable parser metadata and shared CSI parsing.
- Direct stream-buffer reads and image-buffer handoff to reduce copying for large transfers.
- SIMD UTF-8 decoding and bulk text-printing paths.
- Reduced terminal cells to 8 bytes using shared, interned styles.
- Style-table compaction and renderer invalidation when style IDs change.

The style-table idea came from Ghostty.

## Unicode and text

- Unicode 18 grapheme-break tables.
- Extended grapheme-cluster handling with mode 2027 support.
- Improved combining marks, variation selectors, emoji sequences, and cluster-width changes at line boundaries.
- Added combining-mark rendering and Hangul-jamo composition.
- Updated selection and copying to preserve complete grapheme clusters.
- Preserved clusters through insertion, deletion, erasure, and reflow.
- Preserved styled trailing spaces and active/saved cursor positions through wide-glyph reflow.

## Graphics

- Anchored kitty and sixel images to scrollback lines.
- Updated image placement handling for scrolling regions and history expiration.
- Deferred eligible image decoding until a placement becomes visible.
- Improved image-transfer ownership, cleanup, and retransmission handling.
- Added support for image strings larger than the input ring.
- Preserved anchors, blank-cell placements and the scrolled viewport through resize/reflow.
- Corrected natural/scaled cursor advancement, pending wrap and sixel double-scrolling.
- Retained named image data for re-placement after clears and lowercase deletion.
- Added bounded, decode-independent cache accounting and unplaced-first eviction.
- Refined visible/point/placement-ID deletion and cancellation of unfinished uploads.
- Kept anonymous/sixel image IDs distinct from existing named Kitty images, including ID wraparound.
- Bounded sixel RGB scaling and header counters, and corrected allocation-failure cleanup.

## Font loading

- Resolve the configured primary or system monospace font without hardcoded preferred paths.
- Load styled and fallback faces on demand, preserve fallback order, deduplicate data and cache failed lookups.
- Keep valid blank glyphs from triggering unnecessary fallback loads during ASCII warmup.
- Make rendering benchmarks follow application font selection and parser-only benchmarks font-free.
- Preserve selected font-collection members in primary loading, lazy fallback identity and rasterization.

## Correctness and input

- Hardened paste handling against escape/control injection; allocation failures no longer fall back to raw input.
- Fixed composed Unicode input under Kitty's all-keys reporting mode.
- Fixed no-button mouse-motion reporting and urxvt mouse-button encoding.
- Propagated resize allocation errors instead of silently publishing inconsistent dimensions.
- Reaped Linux notification child processes and protected notification arguments with `--`.
- Corrected raw C1-byte handling, reset behavior, and soft-wrap clearing during erasure.
- Preserved existing cells during tabulation and the live cursor content during height-only window shrinking.
- Retained rectangle-copy source cells during pressure parsing and honored updated extended palette entries.
- Corrected reverse-video repainting and selection highlights after framebuffer scroll reuse.

## Benchmarks and tests

- Added Ghostty-compatible headless `+terminal-stream` benchmarking.
- Added automated Ghostty throughput comparisons with raw samples and generated charts.
- Changed the chart to grouped horizontal bars with independent, zero-based linear scales.
- Added startup comparisons for Velocitty, foot, and Monstar.
- Expanded parsing, graphics, drain, firehose, and rendering benchmark workloads.
- Added configurable benchmark optimization and a `bench-install` target.
- Added differential firehose tests, split-input sweeps, seeded fuzzing, and Unicode/rendering regressions.
- Removed the obsolete standalone rendering/golden-test harness and older benchmark implementations.

## Packaging and documentation

- Consolidated icons, desktop metadata, and Windows resources under `assets/`.
- Updated icon generation to use the canonical SVG.
- Updated build, packaging, and installer asset paths.
- Added Linux package Makefile installation/uninstallation with PREFIX and DESTDIR support.
- Added design pages, benchmark imagery, storage diagrams and subsystem references.
- Updated README branding, feature descriptions, Linux installation instructions, and the man page.

## Downloads

Windows and macOS downloads are unsigned. Windows may show SmartScreen; macOS users can allow the app in System Settings → Privacy & Security after the first launch attempt.

Use SHA256SUMS to verify the downloaded packages.
