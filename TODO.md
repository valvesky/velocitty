# Bugs
- [X] Resize clears scrollback.
- [X] No line wrap.
- [X] When running a TUI like neovim, resizing breaks formatting. New portions of the screen are not drawn. Are we sending SIGWINCH ?
- [X] SSH to another terminal break certain applications due to term info. 
- [X] Line wrap will ocasionally repeat that line that wraps leading to duplicate text.
- [X] Random notifications are sent for example on neovim :w — nvim sends ConEmu progress `OSC 9;4;…`, which was treated as iTerm notify.

# Escape Codes

## C0
- [X] BEL ignored (no visual bell / XBell)
- [X] Last-column flag (LCF) wrap / BS
- [X] HT writing a tab glyph + spaces to the next stop (we only move the cursor)

## CSI - SGR / cells
- [X] Styled underlines drawn (double / curly / dotted / dashed); style is stored, render is single
- [X] Underline color (SGR 58/59) on cells; pen only
- [X] Reverse video (DECSCNM 5) applied at draw
- [X] ED 3 erase scrollback
- [X] Grapheme clustering (mode 2027)

## CSI - modes / reports
- [X] Mouse reports themselves (modes 1000/1002/1003/1006/1015/1016 are stored only)
- [X] Focus in/out (`CSI I` / `CSI O`) when mode 1004 is on
- [X] Theme-change reports (2031)
- [X] Visibility-change reports (2033) after the initial reply
- [X] In-band resize notifications (2048)
- [X] IME (737769)
- [X] Real pixel geometry for window ops 14/15/16 (we fake `cols*cell_px`)
- [X] XTSMGRAPHICS (`CSI ? Pi ; Pa ; Pv S`)

## OSC
- [X] 7 cwd
- [X] 9 / 99 / 777 notifications
- [X] 11 background alpha
- [X] 17 / 19 / 117 / 119 selection colors
- [X] 22 mouse cursor
- [X] 52 clipboard
- [X] 66 kitty text-size
- [X] 133 shell-integration marks
- [X] 176 app-id
- [X] 555 flash removed

## DCS
- [X] Sixel (`DCS q`)
- [X] XTGETTCAP (`DCS + q`)
- [X] Sixel-related private modes 80 / 1070 / 8452 (flags only)
