#!/usr/bin/env python3
"""Send key events to a VM via QMP input-send-event (bypasses HMP sendkey).

Usage: python3 qmpkey.py <vmid> <qcode> [<qcode> ...]
       python3 qmpkey.py <vmid> --text "literal string"
"""
import json
import socket
import sys
import time

PAIRS = {
    ' ': 'spc', '\t': 'tab', '\n': 'ret',
    '-': 'minus', '_': 'shift-minus',
    '=': 'equal', '+': 'shift-equal',
    ';': 'semicolon', ':': 'shift-semicolon',
    "'": 'apostrophe', '"': 'shift-apostrophe',
    ',': 'comma', '.': 'dot',
    '/': 'slash', '?': 'shift-slash',
    '\\': 'backslash', '|': 'shift-backslash',
    '!': 'shift-1', '@': 'shift-2', '#': 'shift-3', '$': 'shift-4',
    '%': 'shift-5', '^': 'shift-6', '&': 'shift-7', '*': 'shift-8',
    '(': 'shift-9', ')': 'shift-0',
}


def qcodes_for_char(ch):
    if ch in PAIRS:
        return [PAIRS[ch]]
    if 'a' <= ch <= 'z' or '0' <= ch <= '9':
        return [ch]
    if 'A' <= ch <= 'Z':
        return ['shift-' + ch.lower()]
    raise ValueError('no mapping for %r' % ch)


def key_event(code, down):
    return {'type': 'key', 'data': {'key': {'type': 'qcode', 'data': code}, 'down': down}}


def expand_combo(combo):
    """'shift-f10' -> key events with modifiers held around the main key."""
    parts = combo.split('-')
    mods, main = parts[:-1], parts[-1]
    events = [key_event(m, True) for m in mods]
    events.append(key_event(main, True))
    events.append(key_event(main, False))
    events.extend(key_event(m, False) for m in reversed(mods))
    return events


def main():
    vmid = sys.argv[1]
    rest = sys.argv[2:]
    if rest and rest[0] == '--text':
        combos = []
        for ch in ' '.join(rest[1:]):
            combos.extend(qcodes_for_char(ch))
    else:
        combos = rest

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect('/var/run/qemu-server/%s.qmp' % vmid)
    f = sock.makefile('rw')
    f.readline()
    f.write(json.dumps({'execute': 'qmp_capabilities'}) + '\n')
    f.flush()
    f.readline()

    for combo in combos:
        events = expand_combo(combo)
        downs = [e for e in events if e['data']['down']]
        ups = [e for e in events if not e['data']['down']]
        for e in downs:
            f.write(json.dumps({'execute': 'input-send-event', 'arguments': {'events': [e]}}) + '\n')
            f.flush()
            f.readline()
        time.sleep(0.35)
        for e in ups:
            f.write(json.dumps({'execute': 'input-send-event', 'arguments': {'events': [e]}}) + '\n')
            f.flush()
            f.readline()
        time.sleep(0.12)
    print('sent %d combos' % len(combos))


if __name__ == '__main__':
    main()
