#!/usr/bin/env python3
"""Capture a VM's QEMU display to PNG (host QEMU lacks libpng screendump).

Usage: python3 shot.py <vmid> [outfile.png]
"""
import struct
import subprocess
import sys
import zlib

vmid = sys.argv[1]
out = sys.argv[2] if len(sys.argv) > 2 else '/tmp/shot.png'
ppm = '/tmp/shot.ppm'

subprocess.run(
    ['qm', 'monitor', vmid],
    input=('screendump %s\n' % ppm).encode(),
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
import time
time.sleep(1.2)

data = open(ppm, 'rb').read()
header = []
idx = 0
while len(header) < 4:
    while idx < len(data) and data[idx:idx + 1].isspace():
        idx += 1
    if data[idx:idx + 1] == b'#':
        while idx < len(data) and data[idx] != 0x0a:
            idx += 1
        continue
    start = idx
    while idx < len(data) and not data[idx:idx + 1].isspace():
        idx += 1
    header.append(data[start:idx])
idx += 1
if header[0] != b'P6':
    raise SystemExit('not a P6 ppm: %r' % header[:2])
w, h = int(header[1]), int(header[2])
rgb = data[idx:]
if len(rgb) < w * h * 3:
    raise SystemExit('short pixel data: %d < %d' % (len(rgb), w * h * 3))


def chunk(typ, dat):
    return (struct.pack('>I', len(dat)) + typ + dat +
            struct.pack('>I', zlib.crc32(typ + dat) & 0xffffffff))


raw = b''.join(b'\x00' + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))
png = (b'\x89PNG\r\n\x1a\n' +
       chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
       chunk(b'IDAT', zlib.compress(raw, 6)) +
       chunk(b'IEND', b''))
open(out, 'wb').write(png)
print('wrote %s %dx%d %d bytes' % (out, w, h, len(png)))
