# Architecture / Design

Velocitty is a greedy single-threaded software-rasterized terminal for Omarchy.

It was originally meant to be a 1-to-1 [refterm](https://github.com/cmuratori/refterm) implementation
but many of the optimizations it showcases for  are not entirely possible without workarounds.

To properly truncate input without losing sync means at least acknowledging / tagging any possible
state-altering ANSI code. 

# 1. IO and PREPARSING:

IO is dumped to a page-size ringbuffer.
We preparse once the ringbuffer is full, 1/hz has passed or EOF is received (EAGAIN is ignored).
Vectorized preparsing splits input into runs:
- Split the lines that fit on the screen into "runs".
- Runs will be split into C0 (<0x1b), (>=DEL) C1, Esc (0x1b), EscKitty, EscSixel, Plain, UTF-8, possibly more in the future.
- If a state-alterning run is about to be scrolled off the ringbuffer, we must parse it.

# 2. Tagging and Parsing
- As branchless as possible.
- Feed **only the runs necessary** into the optimized minimal-state terminal emulator to get the final screen.
- The final terminal cells and lines will be added to the buffer of cells and get indexed allowing for 
- The minimal state terminal should also use vectorization when possible.
- ADVANCED UNICODE PARSING:
    - While producing the final screen we must also check for glyphs that might ocupy multiple cells and leave details for the renderer.
    - UTS 11 - character width
    - UTS 24 - script property
    - UTS 29 - text segmentation (grapheme cluster, word boundary)
    - UTS 51 - Emoji
# 3. DRAW THE SCREEN:
    - The font is prebaked an atlas and has an LRU cache for quick access and eviction of least recently used glyphs.
