#!/usr/bin/env python3
"""Minimal MSZIP CAB extractor: lists .inf files and searches for a device id.

Usage: python3 cabscan.py <cab> [devid]
"""
import struct
import sys
import zlib


def main():
    path = sys.argv[1]
    needle = sys.argv[2] if len(sys.argv) > 2 else '0412'
    d = open(path, 'rb').read()
    assert d[:4] == b'MSCF', 'not a cabinet'
    coff_files, = struct.unpack_from('<I', d, 0x10)
    ver_min, ver_maj = d[0x18], d[0x19]
    cfolders, cfiles, flags = struct.unpack_from('<HHH', d, 0x1A)
    off = 0x24
    cb_cffolder, cb_cfdata = 8, 8
    if flags & 0x0004:
        cb_cfheader, cb_cffolder, cb_cfdata = struct.unpack_from('<HBB', d, off)
        off += 4 + cb_cfheader
    folders = []
    for _ in range(cfolders):
        coff, cblocks, ctype = struct.unpack_from('<IHH', d, off)
        folders.append((coff, cblocks, ctype))
        off += cb_cffolder
    files = []
    off = coff_files
    for _ in range(cfiles):
        cb_file, uoff, ifold, date, time, attr = struct.unpack_from('<IIHHHH', d, off)
        off += 16
        end = d.index(b'\0', off)
        name = d[off:end].decode('latin1')
        off = end + 1
        files.append((name, cb_file, uoff, ifold))

    for fi, (coff, cblocks, ctype) in enumerate(folders):
        print('folder', fi, 'typeCompress', ctype)
        if ctype & 0x000F not in (0, 1):
            print('UNSUPPORTED compression in folder', fi)
            continue
        pos = coff
        buf = b''
        for _ in range(cblocks):
            cb_data, cb_uncomp = struct.unpack_from('<HH', d, pos + 4)
            body = d[pos + 8:pos + 8 + cb_data]
            pos += 8 + cb_data
            if (ctype & 0x000F) == 1:
                assert body[:2] == b'CK', body[:2]
                buf += zlib.decompress(body[2:], -15)
            else:
                buf += body
        for name, cb_file, uoff, ifold in files:
            if ifold != fi:
                continue
            if name.lower().endswith('.inf'):
                txt = buf[uoff:uoff + cb_file].decode('latin1', errors='ignore')
                hit = needle.lower() in txt.lower()
                dv = ''
                for line in txt.splitlines():
                    if 'DriverVer' in line:
                        dv = line.strip()
                        break
                print(('HIT ' if hit else '    '), name, '|', dv[:80])
        del buf


if __name__ == '__main__':
    main()
