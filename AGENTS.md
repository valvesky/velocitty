# Velocitty
- Read DESIGN.md for a specification of how the program works.
- Do not change the README.md
- Keep AGENTS.md up-to-date.
- Linux-only, Omarchy-first terminal. Executable is `src/main.zig`.
- Do not add Windows, macOS, or other-OS paths. Target Linux via Peak (Wayland, then X11). Omarchy (Hyprland, themes, fonts, app menu) is the primary desktop.
- Pipeline: `circbuffer` (line split + runs) → `vt` → `draw`.

# Release
- `zig build release` builds ReleaseFast for Linux gnu and musl (x86_64 and aarch64). The binary links libc (and libdl/libpthread/libutil on gnu). Peak compiles against host X11 and Wayland headers (`-idirafter /usr/include`) and dlopens Wayland, X11, Pulse, and xkbcommon at runtime.
- `zig build package` runs `release` and writes `packages/velocitty-<version>-<triple>.tar.gz` (binary, desktop, icon, manpage).

# Install
- `zig build` / `zig build install` is Zig's prefix install (default `zig-out/`: binary, `velocitty.desktop`, icon, manpage).
- `zig build install-usr` builds ReleaseFast for the host and installs `/usr/bin/velocitty`, `/usr/share/applications/velocitty.desktop`, the hicolor icon, and `/usr/share/man/man1/velocitty.1` so it appears in the Omarchy app menu. Uses `sudo` when stdin is a TTY, otherwise `pkexec`.

# Code Base
- Read files only when necessary. Use `grep` or `rg` if you only need a specific function.
- `simd.zig` — SIMD utilities.
- `debug.zig` — Debug-mode log + visual overlay (OSC 556 / CSI ? 556; ignored in Release). HUD: cursor, flags, dirty count `D`, last OSC `o`, `SYNC`/`NTF`
- `circbuffer.zig` — mirrored firehose buffer; `readPTY` (EOF or EAGAIN + 1/hz, never poll 0ms); SIMD line split + run split; space is plain (0x20..0x7E); consecutive UTF-8 is one run; incomplete ESC/CSI/OSC/UTF-8 at a read boundary is held (UTF-8 holds only the tail sequence)
- `vt.zig` — minimal-state emulator; `feedRuns` routes C0/C1/ESC/CSI/OSC/DCS/kitty; bulk ASCII `printPlain` when insert/DEC special/SS are off
- `grid.zig` — cell buffer, cursor, last-column flag (`wrap_pending`), scroll region, insert/delete; primary reflow on column resize (soft-wrap flags)
- `c0.zig` / `c1.zig` — C0/C1 dispatch (BEL ignored; HT writes tab+spaces; BS reverse-wrap; LF/VT/FF are index only so terminfo `cud1` stays in column; NEL is CR+LF; cooked NL becomes CR NL via PTY `OPOST|ONLCR`; LCF delayed DECAWM wrap)
- `esc.zig` — ESC parse + charset G0–G3 / RIS / HTS / DECALN / SS2/SS3
- `csi.zig` — CSI parse (`;` params, `:` subparams, packed privates) + apply (foot ctlseqs: SGR, CUP, DECSET, DECRQM, rectangular, kitty kbd, window ops, color stack, XTSMGRAPHICS); debug-only CSI `? 556` overlay
- `osc.zig` — OSC 0/2 title, 4/10–12/104/110–112 colors, OSC 8 hyperlinks, 7 cwd, 9/99/777 notify (OSC 9;4 ConEmu progress and 9;9 cwd are not notify; OSC 777 only `notify;`; kitty OSC 99 `d=2` closes), 11 alpha, 17/19 selection, 22 cursor, 52 clipboard, 66 text, 133 marks, 176 app-id, debug-only 556 overlay (`all`/`off`/`grid,wrap,lcf,cursor,dirty,region,wide,hud`)
- `dcs.zig` — DCS DECRQSS (DECSTBM/SGR/DECSCUSR) + iTerm sync + XTGETTCAP + sixel (`sixel.zig`)
- `draw.zig` — CPU framebuffer; line-dirty fill + SIMD glyph blit; color-emoji RGBA blit; cell-span dirty when a prev snapshot exists; DECSCNM reverse; styled/colored underlines; C0 cells are not rasterized; Debug overlay (grid, wrap, LCF, dirty, region, wide, HUD)
- `type.zig` — TrueType rasterizer, coverage + RGBA atlas, glyph LRU; bold/italic faces; CBDT/CBLC color emoji (`type/cbdt.zig`); `type/eastasian.zig` cell width
- `scheme.zig` — TOML config (colors, font, hz, whitelist, pad); loads Omarchy current theme; font size from Alacritty, family from fontconfig `monospace` (`omarchy font`)
- SIGUSR1/SIGUSR2 or Omarchy theme/font file change reloads colors and font in `main.zig` (`fc-match` needs process environ so HOME/fonts.conf apply)
- `loop.zig` — stub (no xev)
- `select.zig` — cell-stream selection over `vt.VtState` (drag, double-click word, triple-click line)
- `key.zig` — PTY key encoding: Shift+Tab CSI Z, modified arrows CSI 1;mod A, xterm modifyOtherKeys `CSI 27;mod;key~`, kitty keyboard protocol CSI u when flags are pushed; Delete is CSI 3~ (not DEL 0x7F, which the tty treats as backspace)
- `kitty.zig` — kitty graphics (APC G: stream + file/temp, `a=q` OK replies for icat); sixel bitmaps placed through the same store
- `sixel.zig` — DCS q decoder (palette, repeats, raster attrs) → RGBA
- `platform/` — Peak backend. `peak.zig` declares the `godstack/Peak` calls the terminal uses; `build.zig` compiles `peak.c`. Window + backbuffer present, focus/expose, WM_CLASS / xdg app-id (`--class` / OSC 176), opacity (X11 `_NET_WM_WINDOW_OPACITY`; Wayland `wp_alpha_modifier_v1`, else buffer alpha), clipboard CLIPBOARD plus primary (`zwp_primary_selection_v1` on Wayland). Wayland backbuffer is logical size × fractional scale (`wp_fractional_scale_v1` + `wp_viewport`; integer `wl_output` scale if those are absent) and pointer coordinates are in that buffer. Each commit sets `xdg_surface.set_window_geometry` and `wl_surface.set_input_region` to the logical size so a scaled buffer cannot take clicks outside the tile. The configure ack commits that clip immediately, without waiting for the next present, and pointer events outside the logical window are dropped (strict half-open bounds, rechecked for clicks/wheel after resize; extra mouse buttons are ignored rather than mapped to left-click). Temporary input regions are destroyed on the server after use. Pointer events follow the entered surface; leave releases held buttons instead of extending the selection. Wheel is `wl_pointer` `axis_value120` / discrete, one click per detent. Cursor shape (OSC 22) is `wp_cursor_shape_v1` (text, hand, wait, crosshair, not-allowed, help) and hide uses `wl_pointer.set_cursor`. Motion is always delivered. PTY is `peak_pty_spawn` (`$SHELL` or `-e`); slave keeps `OPOST|ONLCR`; child env `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=velocitty`, `KITTY_WINDOW_ID`, `COLUMNS`, `LINES` is set around the spawn and restored in the parent; `TIOCSWINSZ` + `SIGWINCH` to the slave fg pgroup. Wayland compose is Peak's xkbcommon path; X11 text is `XLookupString` (no Multi_key compose). A key or paste while scrolled calls `viewBottom`
- `main.zig` — window + PTY + fonts (regular/bold/italic via fc-match, Noto Color Emoji fallback); `circbuffer` → `vt` → `draw` → Peak present (skip if frame not damaged); each tick `readPTY` (EOF or EAGAIN+1/hz) while pumping the Peak fd so keys are not deferred until after the echo; DECSET 2026 / iTerm DCS `=1s` defers present until sync ends (timeout 1s); mouse reports (1000/1002/1003 + SGR/urxvt/pixels) for buttons/motion/wheel, else alt-screen arrows or primary history view; Shift+Tab sends CSI Z (CSI 9;2u with kitty kbd); modified keys and kitty CSI u via `key.zig`; left-drag selects (Shift+drag when mouse reporting is on); double-click word / triple-click line (click chains and held/drag state reset on focus changes); mouse-up copies PRIMARY; Ctrl+Shift+C copies CLIPBOARD; Ctrl+Shift+V / Shift+Insert paste CLIPBOARD, middle-click pastes PRIMARY (bracketed if DECSET 2004); focus CSI I/O (1004) and visibility 2033; theme-change 2031 on palette reload (watchStamp throttled); inner pad from `[general] pad` (default 14), scaled by Wayland output scale; font/pad/cells use CSS 96 DPI × Hyprland/`GDK_SCALE` multiplier (not X11 mm-DPI) and re-apply on focus/resize only when scale/grid actually change; resize updates the grid, PTY winsize (SIGWINCH), real window pixel geometry (CSI 14/15/16), and flushes VT replies (in-band 2048 if enabled); CLI `-e`/`--` command, `--class=`, `--title=`, `--working-directory=` (xdg-terminal-exec)

# Bench
- `zig build bench` — `src/bench.zig`, ReleaseFast pipeline in MiB/s: IO (firehose truncate), line/run preparse (last-N vs all-ring), VT `feedRuns`, draw fill + glyph blit, glyph LRU (ascii table vs non-ascii cache), atlas pack. Large 220x60 and ~4K frames. Each run writes `bench/<UTC ISO>-<git12>[-dirty].txt` and copies `last_bench` (gitignored). Timestamp is the run id; hash is which tree.

# Peak input regression tests
- Velocitty builds Peak with `PEAK_NO_GAMEPAD`: no direct `/dev/input/js*` polling. Gaming mice can expose joystick interfaces; converting their global button events into pointer events caused clicks at (0,0) in every terminal, bypassing compositor routing.
- Headless joystick-disabled regression: `cc -Igodstack/Peak tests/peak_no_gamepad.c -o /tmp/velocitty-peak-no-gamepad -ldl -lpthread -lm && /tmp/velocitty-peak-no-gamepad`.
- Headless Wayland hit-region, resize/click, extra-button, wheel, and leave tests: `cc -Igodstack/Peak tests/peak_pointer.c -o /tmp/velocitty-peak-pointer -ldl -lpthread -lm && /tmp/velocitty-peak-pointer`.

# Rendering tests
- Cell dumps: `VtState.dumpAlloc` / `dumpCellsAlloc`; fixtures in `tests/vt/*.in` (first line `cols rows`).
- PNG goldens: `tests/golden/`; mismatch writes `zig-out/screenshots/<name>` and `<name>.diff.png`.
- Bless dumps and PNGs with `ZT_UPDATE_GOLDEN=1 zig build test`.
- Dirty vs full: `tests/render.zig` (32 iters). Long run: `zig build fuzz-render -- 10000`.
