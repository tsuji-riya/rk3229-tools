#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Pack images for the Rockchip RK322x vendor loader (verified against the
MX10 firmware dump: rebuilding the original images is byte-identical).

  rk-pack.py kernel   zImage kernel.img [--size BYTES]
  rk-pack.py resource orig-resource.img new-resource.img NAME=FILE [NAME=FILE ...]
  rk-pack.py unpack   resource.img outdir
  rk-pack.py loader   payload.bin out.img --addr ADDR [--magic LOADER|TOS] [--size BYTES]
  rk-pack.py loader-info image.img

`loader` builds the "LOADER"/"TOS" images that the Rockchip miniloader reads
from the uboot/trust partitions: a 2 KiB header (magic, load address, size,
CRC, SHA-256) followed by the payload, repeated 4 times at 1 MiB intervals.
Rebuilding the original uboot.img / trust.img from their payloads is
byte-identical.
"""
import struct, sys, os, hashlib

def _tab():
    t = []
    for i in range(256):
        c = i << 24
        for _ in range(8):
            c = ((c << 1) ^ 0x04c10db7) & 0xffffffff if c & 0x80000000 else (c << 1) & 0xffffffff
        t.append(c)
    return t
_T = _tab()

def rkcrc(data, crc=0):
    for b in data:
        crc = ((crc << 8) & 0xffffffff) ^ _T[(crc >> 24) ^ b]
    return crc

def pad(b, n):
    return b + b'\0' * (-len(b) % n)

def cmd_kernel(argv):
    src, dst = argv[0], argv[1]
    size = int(argv[argv.index('--size') + 1], 0) if '--size' in argv else 0
    z = open(src, 'rb').read()
    out = b'KRNL' + struct.pack('<I', len(z)) + z + struct.pack('<I', rkcrc(z))
    if size:
        assert len(out) <= size, 'kernel too big for partition'
        out = out.ljust(size, b'\0')
    open(dst, 'wb').write(out)
    print('kernel image: payload %d bytes -> %s' % (len(z), dst))

def parse_res(d):
    assert d[:4] == b'RSCE'
    hdr = d[:16]
    n = struct.unpack_from('<I', d, 12)[0]
    ents = []
    for i in range(n):
        b = d[512 * (1 + i):512 * (2 + i)]
        assert b[:4] == b'ENTR'
        name = b[4:260].split(b'\0')[0].decode()
        off, size = struct.unpack_from('<II', b, 260)
        ents.append((name, d[off * 512:off * 512 + size]))
    return hdr, ents

def build_res(hdr, ents):
    n = len(ents)
    blocks = [hdr.ljust(512, b'\0')]
    off = 1 + n
    tbl, data = [], []
    for name, blob in ents:
        e = b'ENTR' + name.encode().ljust(256, b'\0') + struct.pack('<II', off, len(blob))
        tbl.append(e.ljust(512, b'\0'))
        pb = pad(blob, 512)
        data.append(pb)
        off += len(pb) // 512
    return b''.join(blocks + tbl + data)

def cmd_resource(argv):
    orig, dst, repl = argv[0], argv[1], argv[2:]
    raw = open(orig, 'rb').read()
    hdr, ents = parse_res(raw)
    rep = dict(r.split('=', 1) for r in repl)
    ents = [(n, open(rep.pop(n), 'rb').read() if n in rep else b) for n, b in ents]
    assert not rep, 'unknown entries: %s' % list(rep)
    out = build_res(hdr, ents)
    if len(out) < len(raw):
        out = out.ljust(len(raw), b'\0')
    open(dst, 'wb').write(out)
    print('resource image: %d entries -> %s (%d bytes)' % (len(ents), dst, len(out)))

def cmd_unpack(argv):
    hdr, ents = parse_res(open(argv[0], 'rb').read())
    os.makedirs(argv[1], exist_ok=True)
    for n, b in ents:
        open(os.path.join(argv[1], n), 'wb').write(b)
        print(n, len(b))

LOADER_SLOT = 0x100000   # copies are 1 MiB apart
LOADER_COPIES = 4
LOADER_HDR = 0x800

def loader_header(magic, addr, payload):
    size = len(payload)
    h = magic.encode().ljust(8, b' ') + struct.pack('<6I', 0, 0, addr, size, rkcrc(payload), 32)
    h += hashlib.sha256(payload + struct.pack('<III', addr, size, 32)).digest()
    return h.ljust(LOADER_HDR, b'\0')

def cmd_loader(argv):
    src, dst = argv[0], argv[1]
    def opt(name, default=None):
        return argv[argv.index(name) + 1] if name in argv else default
    addr = int(opt('--addr'), 0)
    magic = opt('--magic', 'LOADER')
    total = int(opt('--size', str(LOADER_SLOT * LOADER_COPIES)), 0)
    payload = pad(open(src, 'rb').read(), 4)
    assert LOADER_HDR + len(payload) <= LOADER_SLOT, \
        'payload too big for a 1 MiB slot (%d bytes)' % len(payload)
    one = (loader_header(magic, addr, payload) + payload).ljust(LOADER_SLOT, b'\0')
    out = (one * LOADER_COPIES).ljust(total, b'\0')
    open(dst, 'wb').write(out)
    print('%s image: payload %d bytes @ %#x -> %s (%d bytes)' % (magic, len(payload), addr, dst, len(out)))

def cmd_loader_info(argv):
    d = open(argv[0], 'rb').read()
    ok = True
    for i in range(LOADER_COPIES):
        c = d[i * LOADER_SLOT:(i + 1) * LOADER_SLOT]
        if c[:8] not in (b'LOADER  ', b'TOS     '):
            print('copy %d: no header' % i)
            ok = False
            continue
        ver, res, addr, size, crc, hlen = struct.unpack_from('<6I', c, 8)
        pay = c[LOADER_HDR:LOADER_HDR + size]
        good = (rkcrc(pay) == crc and
                hashlib.sha256(pay + struct.pack('<III', addr, size, hlen)).digest() == c[0x20:0x20 + hlen])
        print('copy %d: %s addr=%#x size=%d crc=%#010x %s' % (
            i, c[:8].decode().strip(), addr, size, crc, 'OK' if good else 'BAD'))
        ok = ok and good
    sys.exit(0 if ok else 1)

if __name__ == '__main__':
    c = {'kernel': cmd_kernel, 'resource': cmd_resource, 'unpack': cmd_unpack,
         'loader': cmd_loader, 'loader-info': cmd_loader_info}.get(sys.argv[1] if len(sys.argv) > 1 else '')
    if not c:
        sys.exit(__doc__)
    c(sys.argv[2:])
