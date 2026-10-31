#!/usr/bin/env python3
"""Generate src/type/grapheme_table.zig from the Unicode Character Database.

Usage: scripts/gen_grapheme.py UCD_DIR [OUT]

UCD_DIR is a Unicode 18 `ucd/` directory (the uucode package ships one:
zig-pkg/uucode-0.2.0-*/ucd/). Reads:
  auxiliary/GraphemeBreakProperty.txt   Grapheme_Cluster_Break
  auxiliary/GraphemeBreakTest.txt       test vectors (emitted for the tests)
  DerivedCoreProperties.txt             Indic_Conjunct_Break, Default_Ignorable_Code_Point
  extracted/DerivedGeneralCategory.txt  Mn, Me, Zl, Zp, Cs
  emoji/emoji-data.txt                  Extended_Pictographic, Emoji_Modifier
  emoji/emoji-variation-sequences.txt   bases of VS15/VS16 sequences
and the cell widths of src/type/eastasian.zig (`wide_ranges`, `emoji_ranges`),
so one lookup gives what `EastAsian.cellWidth` gives plus the break class.

Each code point gets one byte: bits 0-1 cell width (0: zero width, joins the
previous cell; 1; 2), bits 2-6 the break class (`Class` in grapheme.zig),
bit 7 "VS15/VS16 base". Two-stage table: stage1[cp >> shift] picks a block of
stage2; stage1 covers all of u21 (no range check). Standard library only.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Order matters: these are the `Class` enum values in src/type/grapheme.zig.
CLASSES = [
    "other", "control", "cr", "lf", "prepend", "spacing_mark", "l", "v", "t", "lv", "lvt",
    "regional_indicator", "ext_pict", "zwj", "extend", "extend_incb", "extend_linker",
    "consonant", "linker_other", "linker_spacing",
]
CLASS = {n: i for i, n in enumerate(CLASSES)}
MAXCP = 0x110000


def parse_ranges(path, want=None):
    """Yield (lo, hi, fields) for each data line."""
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = [p.strip() for p in line.split(";")]
            r = parts[0]
            if ".." in r:
                lo, hi = (int(x, 16) for x in r.split(".."))
            else:
                lo = hi = int(r, 16)
            if want is not None and parts[1] != want:
                continue
            yield lo, hi, parts[1:]


def fill(arr, lo, hi, value):
    for cp in range(lo, hi + 1):
        arr[cp] = value


def zig_ranges(src, name):
    m = re.search(r"const %s = \[_\]Range\{(.*?)\n\};" % name, src, re.S)
    if not m:
        sys.exit("eastasian.zig: %s not found" % name)
    return [(int(a, 16), int(b, 16)) for a, b in re.findall(r"\.lo = 0x([0-9A-Fa-f]+), \.hi = 0x([0-9A-Fa-f]+)", m.group(1))]


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    ucd = sys.argv[1]
    out_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "src/type/grapheme_table.zig")

    gbp = ["Other"] * MAXCP
    for lo, hi, f in parse_ranges(os.path.join(ucd, "auxiliary/GraphemeBreakProperty.txt")):
        fill(gbp, lo, hi, f[0])
    incb = ["None"] * MAXCP
    di = bytearray(MAXCP)
    for lo, hi, f in parse_ranges(os.path.join(ucd, "DerivedCoreProperties.txt")):
        if f[0] == "InCB":
            fill(incb, lo, hi, f[1])
        elif f[0] == "Default_Ignorable_Code_Point":
            for cp in range(lo, hi + 1):
                di[cp] = 1
    gc = [""] * MAXCP
    for lo, hi, f in parse_ranges(os.path.join(ucd, "extracted/DerivedGeneralCategory.txt")):
        fill(gc, lo, hi, f[0])
    pict = bytearray(MAXCP)
    modifier = bytearray(MAXCP)
    for lo, hi, f in parse_ranges(os.path.join(ucd, "emoji/emoji-data.txt")):
        if f[0] == "Extended_Pictographic":
            for cp in range(lo, hi + 1):
                pict[cp] = 1
        elif f[0] == "Emoji_Modifier":
            for cp in range(lo, hi + 1):
                modifier[cp] = 1
    vs_base = bytearray(MAXCP)
    with open(os.path.join(ucd, "emoji/emoji-variation-sequences.txt"), encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            seq = line.split(";")[0].split()
            vs_base[int(seq[0], 16)] = 1
    # grapheme.zig hardcodes the emoji modifiers as U+1F3FB..U+1F3FF.
    if [cp for cp in range(MAXCP) if modifier[cp]] != list(range(0x1F3FB, 0x1F400)):
        sys.exit("Emoji_Modifier is no longer U+1F3FB..U+1F3FF")

    with open(os.path.join(ROOT, "src/type/eastasian.zig"), encoding="utf-8") as f:
        ea = f.read()
    wide = bytearray(MAXCP)
    for lo, hi in zig_ranges(ea, "wide_ranges"):
        for cp in range(lo, hi + 1):
            wide[cp] = 1
    # `cellWidth`: emoji ranges are wide below U+20000 only.
    for lo, hi in zig_ranges(ea, "emoji_ranges"):
        for cp in range(lo, min(hi, 0x1FFFF) + 1):
            wide[cp] = 1

    props = bytearray(MAXCP)
    for cp in range(MAXCP):
        g = gbp[cp]
        i = incb[cp]
        if pict[cp]:
            if g != "Other" or i != "None":
                sys.exit("U+%04X: Extended_Pictographic with GCB=%s InCB=%s" % (cp, g, i))
            cls = "ext_pict"
        elif g == "Extend":
            cls = {"None": "extend", "Extend": "extend_incb", "Linker": "extend_linker"}.get(i)
        elif g == "ZWJ":
            cls = "zwj" if i in ("None", "Extend") else None
        elif i == "Consonant":
            cls = "consonant" if g == "Other" else None
        elif i == "Linker":
            cls = {"Other": "linker_other", "SpacingMark": "linker_spacing"}.get(g)
        elif i == "Extend":
            cls = None
        else:
            cls = {
                "Other": "other", "Control": "control", "CR": "cr", "LF": "lf", "Prepend": "prepend",
                "SpacingMark": "spacing_mark", "L": "l", "V": "v", "T": "t", "LV": "lv", "LVT": "lvt",
                "Regional_Indicator": "regional_indicator",
            }.get(g)
        if cls is None:
            sys.exit("U+%04X: no class for GCB=%s InCB=%s" % (cp, g, i))
        # Zero width as Ghostty's `width` table has it: default ignorables
        # (not SOFT HYPHEN), nonspacing/enclosing marks, separators,
        # surrogates and Hangul V/T jamo; emoji modifiers and Prepend keep
        # their own width (they show alone).
        zero = (di[cp] and cp != 0xAD) or gc[cp] in ("Mn", "Me", "Zl", "Zp", "Cs") or g in ("V", "T")
        if modifier[cp] or g == "Prepend":
            zero = False
        width = 0 if zero else (2 if wide[cp] else 1)
        props[cp] = width | (CLASS[cls] << 2) | (vs_base[cp] << 7)

    # Two-stage table; pick the block size that minimises the bytes.
    best = None
    for shift in (6, 7, 8, 9):
        size = 1 << shift
        blocks = {}
        stage1 = []
        for b in range(MAXCP >> shift):
            blk = bytes(props[b << shift:(b + 1) << shift])
            if blk not in blocks:
                blocks[blk] = len(blocks)
            stage1.append(blocks[blk])
        s1_bytes = len(stage1) * (1 if len(blocks) <= 256 else 2)
        total = s1_bytes + len(blocks) * size
        if best is None or total < best[0]:
            best = (total, shift, stage1, list(blocks.keys()))
    _, shift, stage1, blocks = best
    # Cover every u21 so a lookup needs no range check: values past
    # U+10FFFF (never decoded) read the block of U+10FF80..U+10FFFF
    # (noncharacters/private use: width 1, Other).
    stage1 += [stage1[-1]] * ((1 << (21 - shift)) - len(stage1))
    s1_type = "u8" if len(blocks) <= 256 else "u16"

    vectors = []
    with open(os.path.join(ucd, "auxiliary/GraphemeBreakTest.txt"), encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            toks = line.split()
            # ÷ cp (÷|×) cp ... ÷ ; a set bit 31 means "break before".
            case = []
            brk = True
            for t in toks[1:-1]:
                if t == "÷":
                    brk = True
                elif t == "×":
                    brk = False
                else:
                    case.append(int(t, 16) | (0x80000000 if brk else 0))
            vectors.append(case)

    with open(out_path, "w", encoding="utf-8") as o:
        o.write("//! Generated by scripts/gen_grapheme.py from the Unicode 18 UCD and the\n")
        o.write("//! widths in src/type/eastasian.zig. Do not edit. Regenerate with:\n")
        o.write("//!   python3 scripts/gen_grapheme.py /path/to/zig-pkg/uucode-0.2.0-*/ucd\n")
        o.write("//! (src/type/grapheme.zig reads it; its tests check it against eastasian.zig.)\n\n")
        o.write("/// `props(cp) = stage2[@as(u32, stage1[cp >> shift]) << shift | (cp & mask)]`.\n")
        o.write("pub const shift = %d;\n" % shift)
        o.write("/// Class names, in `Class` order.\n")
        o.write("pub const class_names = [_][]const u8{ %s };\n\n" % ", ".join('"%s"' % c for c in CLASSES))
        o.write("pub const stage1 = [%d]%s{\n" % (len(stage1), s1_type))
        for k in range(0, len(stage1), 24):
            o.write("    " + ", ".join(str(v) for v in stage1[k:k + 24]) + ",\n")
        o.write("};\n\n")
        o.write("pub const stage2 = [%d]u8{\n" % (len(blocks) << shift))
        flat = b"".join(blocks)
        for k in range(0, len(flat), 32):
            o.write("    " + ", ".join(str(v) for v in flat[k:k + 32]) + ",\n")
        o.write("};\n\n")
        o.write("/// GraphemeBreakTest.txt: code points; bit 31 set = break before it.\n")
        o.write("pub const break_tests = [_][]const u32{\n")
        for case in vectors:
            o.write("    &.{ " + ", ".join("0x%X" % v for v in case) + " },\n")
        o.write("};\n")
    print("wrote %s: shift %d, %d blocks, %d bytes, %d test cases" % (out_path, shift, len(blocks), best[0], len(vectors)))


if __name__ == "__main__":
    main()
