#!/usr/bin/env python3
"""Render the README block wordmark with Omarchy's actual Rust ttfx effects.
Requires ttfx, rsvg-convert and ImageMagick. Does not change desktop settings.
"""
from pathlib import Path
import sys
import re
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
BG = '#0d1117'
BLOCKS = {'█': (0, 0, 1, 1), '▀': (0, 0, 1, .5), '▄': (0, .5, 1, .5),
          '▌': (0, 0, .5, 1), '▐': (.5, 0, .5, 1), '▂': (0, .75, 1, .25),
          '▁': (0, .875, 1, .125), '▍': (0, 0, .375, 1), '▎': (0, 0, .25, 1),
          '▏': (0, 0, .125, 1), '_': (0, .95, 1, .05),
          '▘': (0, 0, .5, .5), '▝': (.5, 0, .5, .5), '▖': (0, .5, .5, .5), '▗': (.5, .5, .5, .5)}
# Multi-rectangle quadrant glyphs, drawn as their single-quadrant parts.
QUADS = {'▚': '▘▗', '▞': '▝▖', '▛': '▀▖', '▜': '▀▗', '▙': '▄▘', '▟': '▄▝'}
ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]|\x1b[78]')


def rectangles(lines, cw, ch, ox, oy, color='#8de3d9'):
    parts = []
    for y, line in enumerate(lines):
        x = 0
        i = 0
        fg = color
        while i < len(line):
            match = ANSI.match(line, i)
            if match:
                seq = match.group()
                if seq.endswith('m'):
                    codes = seq[2:-1].split(';')
                    if len(codes) == 5 and codes[:2] == ['38', '2']:
                        fg = '#%02x%02x%02x' % tuple(map(int, codes[2:]))
                    elif codes == ['0']:
                        fg = color
                i = match.end()
                continue
            char = line[i]
            if char in BLOCKS or char in QUADS:
                for piece in QUADS.get(char, char):
                    dx, dy, w, h = BLOCKS[piece]
                    parts.append(f'<rect x="{ox+(x+dx)*cw:g}" y="{oy+(y+dy)*ch:g}" width="{w*cw:g}" height="{h*ch:g}" fill="{fg}"/>')
            elif char != ' ':
                raise ValueError(f'unexpected wordmark glyph: {char!r}')
            x += 1
            i += 1
    return ''.join(parts)


def svg(body, width, height, radius=0):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}"><rect width="{width}" height="{height}" rx="{radius}" fill="{BG}"/>{body}</svg>\n'


def render(source, destination, size=None):
    command = ['rsvg-convert', str(source), '-o', str(destination)]
    if size:
        command += ['-w', str(size), '-h', str(size)]
    subprocess.run(command, check=True)


def main():
    art = (ROOT / 'assets/wordmark.txt').read_text().splitlines()
    icon_svg = ROOT / 'assets/icon.svg'
    render(icon_svg, ROOT / 'assets/icon.png', 512)
    subprocess.run(['magick', str(ROOT/'assets/icon.png'), '-define', 'icon:auto-resize=256,128,64,48,32,16', str(ROOT/'assets/icon.ico')], check=True)
    with tempfile.TemporaryDirectory(prefix='velocitty-branding-') as temp:
        temp = Path(temp)
        entries = []
        for kind, size in [('ic07',128),('ic08',256),('ic09',512),('ic10',1024)]:
            png = temp / f'icon-{size}.png'
            render(icon_svg, png, size)
            data = png.read_bytes()
            entries.append(kind.encode()+struct.pack('>I',8+len(data))+data)
        payload = b''.join(entries)
        (ROOT/'assets/icon.icns').write_bytes(b'icns'+struct.pack('>I',8+len(payload))+payload)
        if '--icon-only' in sys.argv:
            return
        command = ['ttfx','-i',str(ROOT/'assets/wordmark.txt'),'--frame-rate','10000',
                   '--canvas-width','100','--canvas-height','13','--anchor-text','c',
                   '--anchor-canvas','c','--ignore-terminal-dimensions','--seed','42',
                   'highlight','--final-gradient-stops','65d6ce','c1fff7',
                   '--final-gradient-direction','horizontal','--highlight-brightness','1.6','--highlight-width','8']
        output = subprocess.run(command, stdout=subprocess.PIPE, check=True, timeout=30).stdout.decode()
        frames = output.split('\x1b[13A')[1:]
        for i, frame in enumerate(frames):
            image = svg(rectangles(frame.splitlines()[:13], 12, 24, 40, 36), 1280, 384)
            source = temp/f'{i:04}.svg'
            source.write_text(image)
            render(source, temp/f'{i:04}.png')
            if i == 0:
                (ROOT/'assets/wordmark.svg').write_text(image)
        subprocess.run(['magick','-delay','4','-loop','0',*[str(temp/f'{i:04}.png') for i in range(len(frames))],
                        '-set','delay','4','-layers','Optimize',str(ROOT/'assets/velocitty.gif')], check=True)
        # Contact sheet for review. This is deliberately outside the repository.
        picks = [temp/f'{i:04}.png' for i in [0,len(frames)//4,len(frames)//2,len(frames)*3//4,len(frames)-1]]
        subprocess.run(['magick','montage',*map(str,picks),'-thumbnail','768x','-tile','1x','-geometry','+0+12','-background',BG,'/tmp/velocitty-branding-review.png'],check=True)
        print(f'Wrote {len(frames)} ttfx frames, PNG/ICO/ICNS icons, and SVG sources.')


if __name__ == '__main__':
    main()
