- [ ] Fuse fill+blit per dirty row — biggest 4K win, no API change.
- [ ] Dirty cell spans + XPutImage/blitFrame of dirty_y/h only — makes 60 Hz possible when the screen isn’t fully dirty, and cuts present which the bench doesn’t even
    count.
- [ ] Coalesce UTF-8 (and space-as-plain) runs — unlocks CJK parse + VT together.
- [ ] Bulk printCodepoint for plain ASCII — DESIGN’s “vectorize the emulator”; this is the 45 MiB/s ceiling.
- [ ] Glyph blit for real cell widths (pad to 16 / skip AA mix) — secondary to (1)+(2), still a slice of the 29 ms.
