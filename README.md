# ⚡⚡ Velocitty ⚡⚡

Velocitty is a lightning-fast cross-platform terminal multiplexor.

## Features
- Lightning fast (multiple GiB/s per second)
- `cat` large files. 
- Cross-platform.
- CPU rendered.
- Image support (kitty protocol)
- Extensive unicode support.

## Anti-Features
- No CTL.
- No multiplexing.

## Architecture / Design
1. IO:
    - Truncates firehose input through a mirrored circular buffer allowing users to cat large files.
    - EAGAIN: We only consume on EAGAIN if 1/hz time has passed and we need to refresh the screen.
    - Otherwise we keep reading until EOF.
2. VECTORIZED PREPARSING:
    - After truncating input, input is split into lines via AVX2 accelerated preparsing.
    - For correctness we detect escape sequences and newlines. 
    - Escape sequences may contain payloads with newlines that effect correct line splitting.
    - While splitting new lines we must account for:
        - Payload bearing escape sequences that may contain newline bytes that dont shift to the newline.
        - Escape sequences that change the end graphical result or update the cursor.
        - Therefore we will need a smaller pre-parse only parser that accepts whitelisted escape sequences. 
        - Non whitelisted escape sequences will return us to vectorized parsing.
3. VECTORIZED SPLITTING INTO RUNS:
    - Now that we have a correct cursor and input split by lines, we will fetch **only the lines that fit on the screen.**
    - Split the lines that fit on the screen into "runs".
    - Runs will be split into C0 (<0x1b), (>=DEL) C1, Esc (0x1b), EscKitty, EscSixel, Plain, UTF-8, possibly more in the future.
4. MINIMAL STATE TERMINAL EMULATOR:
    - Feed the runs into the optimized minimal-state terminal emulator to get the final screen.
    - The final terminal cells and lines will be added to the buffer of cells and get indexed allowing for 
    - The minimal state terminal should also use vectorization when possible.
    - ADVANCED UNICODE PARSING:
        - While producing the final screen we must also check for glyphs that might ocupy multiple cells and leave details for the renderer.
        - UTS 11 - character width
        - UTS 24 - script property
        - UTS 29 - text segmentation (grapheme cluster, word boundary)
        - UTS 51 - Emoji
5. DRAW THE SCREEN:
    - The font is prebaked an atlas and has an LRU cache for quick access and eviction of least recently used glyphs.
