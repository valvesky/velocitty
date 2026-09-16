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
- `debug.zig` — Debug-mode log + visual overlay (OSC 556 / CSI ? 556; ignored in Release). HUD: cursor, flags, dirty count `D`, last OSC `o`, `SYNC`/`NTF`
- `circbuffer.zig` — mirrored firehose buffer; `readPTY` (EOF or EAGAIN + 1/hz, never poll 0ms); SIMD line split + run split; incomplete ESC/CSI/OSC/UTF-8 at a read boundary is held until the rest arrives
- `vt.zig` — minimal-state emulator; `feedRuns` routes C0/C1/ESC/CSI/OSC/DCS/kitty
- `grid.zig` — cell buffer, cursor, last-column flag (`wrap_pending`), scroll region, insert/delete; primary reflow on column resize (soft-wrap flags)
- `c0.zig` / `c1.zig` — C0/C1 dispatch (BEL ignored; HT writes tab+spaces; BS reverse-wrap; LCF delayed DECAWM wrap)
- `esc.zig` — ESC parse + charset G0–G3 / RIS / HTS / DECALN / SS2/SS3
- `csi.zig` — CSI parse (`;` params, `:` subparams, packed privates) + apply (foot ctlseqs: SGR, CUP, DECSET, DECRQM, rectangular, kitty kbd, window ops, color stack, XTSMGRAPHICS); debug-only CSI `? 556` overlay
- `osc.zig` — OSC 0/2 title, 4/10–12/104/110–112 colors, OSC 8 hyperlinks, 7 cwd, 9/99/777 notify (OSC 9;4 ConEmu progress and 9;9 cwd are not notify; OSC 777 only `notify;`; kitty OSC 99 `d=2` closes), 11 alpha, 17/19 selection, 22 cursor, 52 clipboard, 66 text, 133 marks, 176 app-id, debug-only 556 overlay (`all`/`off`/`grid,wrap,lcf,cursor,dirty,region,wide,hud`)
- `dcs.zig` — DCS DECRQSS (DECSTBM/SGR/DECSCUSR) + iTerm sync + XTGETTCAP + sixel (`sixel.zig`)
- `draw.zig` — CPU framebuffer; line-dirty fill + SIMD glyph blit; DECSCNM reverse; styled/colored underlines; C0 cells are not rasterized; Debug overlay (grid, wrap, LCF, dirty, region, wide, HUD)
- `type.zig` — TrueType rasterizer, atlas, glyph LRU; `type/eastasian.zig` cell width
- `scheme.zig` — TOML config (colors, font, hz, whitelist, pad); loads Omarchy current theme; font size from Alacritty, family from fontconfig `monospace` (`omarchy font`)
- SIGUSR1/SIGUSR2 or Omarchy theme/font file change reloads colors and font in `main.zig` (`fc-match` needs process environ so HOME/fonts.conf apply)
- `loop.zig` — stub (no xev)
- `select.zig` — cell-stream selection over `vt.VtState` (drag, double-click word, triple-click line)
- `kitty.zig` — kitty graphics (APC G: stream + file/temp, `a=q` OK replies for icat); sixel bitmaps placed through the same store
- `sixel.zig` — DCS q decoder (palette, repeats, raster attrs) → RGBA
- `platform/` — window / PTY (Linux/X11 + XInput2); `XSetClassHint` from `--class` / OSC 176; PTY child is `$SHELL` or `-e` argv (`execvpe`); child env `TERM=xterm-256color` (SSH-safe), `KITTY_WINDOW_ID`, `COLORTERM=truecolor`; `TIOCSWINSZ` + `SIGWINCH` to the slave fg pgroup; wheel from Button4/5 and XI2 scroll valuators on scroll-slave devices only (not XIAllMasterDevices); PointerMotionMask only for DECSET 1003; ICCCM CLIPBOARD + PRIMARY (UTF8_STRING) + OSC 52; OSC 22 font cursors; `_NET_WM_WINDOW_OPACITY` from OSC 11 alpha
- `main.zig` — window + PTY + fonts; `circbuffer` → `vt` → `draw` → present; each tick `readPTY` (EOF or EAGAIN+1/hz) while pumping X so keys are not deferred until after the echo; drain the Xlib queue (no 32-event bail); DECSET 2026 / iTerm DCS `=1s` defers present until sync ends (timeout 1s); mouse reports (1000/1002/1003 + SGR/urxvt/pixels) for buttons/motion/wheel, else alt-screen arrows or primary history view; left-drag selects (Shift+drag when mouse reporting is on); double-click word / triple-click line; mouse-up copies PRIMARY; Ctrl+Shift+C copies CLIPBOARD; Ctrl+Shift+V / Shift+Insert paste CLIPBOARD, middle-click pastes PRIMARY (bracketed if DECSET 2004); focus CSI I/O (1004) and visibility 2033; theme-change 2031 on palette reload (watchStamp throttled); inner pad from `[general] pad` (default 14), scaled by Wayland output scale; font/pad/cells use CSS 96 DPI × Hyprland/`GDK_SCALE` multiplier (not X11 mm-DPI) and re-apply on focus/resize only when scale/grid actually change; resize updates the grid, PTY winsize (SIGWINCH), real window pixel geometry (CSI 14/15/16), and flushes VT replies (in-band 2048 if enabled); CLI `-e`/`--` command, `--class=`, `--title=`, `--working-directory=` (xdg-terminal-exec)

# Bench
- `zig build bench` — `src/bench.zig`, ReleaseFast firehose truncate + last-N vs all-ring parse/VT timings.

# Rendering tests
- Cell dumps: `VtState.dumpAlloc` / `dumpCellsAlloc`; fixtures in `tests/vt/*.in` (first line `cols rows`).
- PNG goldens: `tests/golden/`; mismatch writes `zig-out/screenshots/<name>` and `<name>.diff.png`.
- Bless dumps and PNGs with `ZT_UPDATE_GOLDEN=1 zig build test`.
- Dirty vs full: `tests/render.zig` (32 iters). Long run: `zig build fuzz-render -- 10000`.
