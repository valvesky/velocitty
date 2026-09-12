# Escape Codes

## C0
- [ ] BEL (bell action)
- [ ] Last-column flag (LCF) wrap / BS
- [ ] HT writing a tab glyph + spaces to the next stop (we only move the cursor)

## CSI — SGR / cells
- [ ] Styled underlines drawn (double / curly / dotted / dashed); style is stored, render is single
- [ ] Underline color (SGR 58/59) on cells; pen only
- [ ] Reverse video (DECSCNM 5) applied at draw
- [ ] ED 3 erase scrollback
- [ ] Grapheme clustering (mode 2027)

## CSI — modes / reports
- [ ] X10 / hilite / UTF-8 mouse (9, 1001, 1005) — foot also skips these
- [ ] Mouse reports themselves (modes 1000/1002/1003/1006/1015/1016 are stored only)
- [ ] Focus in/out (`CSI I` / `CSI O`) when mode 1004 is on
- [ ] Theme-change reports (2031)
- [ ] Visibility-change reports (2033) after the initial reply
- [ ] In-band resize notifications (2048)
- [ ] IME (737769)
- [ ] Real pixel geometry for window ops 14/15/16 (we fake `cols*cell_px`)
- [ ] XTSMGRAPHICS (`CSI ? Pi ; Pa ; Pv S`)

## OSC
- [ ] 7 cwd
- [ ] 9 / 99 / 777 notifications
- [ ] 11 background alpha
- [ ] 17 / 19 / 117 / 119 selection colors
- [ ] 22 mouse cursor
- [ ] 52 clipboard
- [ ] 66 kitty text-size
- [ ] 133 shell-integration marks
- [ ] 176 app-id
- [ ] 555 flash

## DCS
- [ ] Sixel (`DCS q`)
- [ ] XTGETTCAP (`DCS + q`)
- [ ] Sixel-related private modes 80 / 1070 / 8452 (flags only)
