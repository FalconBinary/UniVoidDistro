#!/usr/bin/env python3
# mkinitrd.py DIR OUT.cpio.gz: a newc cpio archive of DIR, gzip-compressed, for -initrd
import gzip, os, stat, sys

def entry(name, mode, data, nlink=1, size=None):
    name_b = name.encode() + b'\0'
    if size is None:
        size = len(data)
    hdr = (b'070701' + b'%08X' * 13) % (
        0, mode, 0, 0, nlink, 0, size, 0, 0, 0, 0, len(name_b), 0)
    out = hdr + name_b
    out += b'\0' * ((4 - len(out) % 4) % 4)
    out += data
    out += b'\0' * ((4 - len(out) % 4) % 4)
    return out

root = sys.argv[1]
buf = b''
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort(); filenames.sort()
    rel = os.path.relpath(dirpath, root)
    if rel != '.':
        buf += entry(rel, stat.S_IFDIR | 0o755, b'', 2)
    for f in filenames:
        p = os.path.join(dirpath, f)
        n = f if rel == '.' else rel + '/' + f
        st = os.lstat(p)
        if stat.S_ISLNK(st.st_mode):
            buf += entry(n, stat.S_IFLNK | 0o777, os.readlink(p).encode())
        else:
            with open(p, 'rb') as fh:
                data = fh.read()
            buf += entry(n, stat.S_IFREG | (st.st_mode & 0o777), data)
buf += entry('TRAILER!!!', 0, b'')
with gzip.open(sys.argv[2], 'wb', compresslevel=6) as out:
    out.write(buf)
print('initrd', sys.argv[2], len(buf), 'bytes uncompressed')
