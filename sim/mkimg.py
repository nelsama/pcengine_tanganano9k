#!/usr/bin/env python3
"""mkimg.py out.img file.sms ... : FAT32 image for the simulation (SDIMG)."""
import os, sys, struct, random
here = os.path.dirname(os.path.abspath(__file__))
s = open(os.path.join(here, '..', 'menu', 'test_fat.py')).read()
exec(s[s.index('class Img'):s.index("HOST = r")])
im = Img(2048, 8)
root = b''
for p in sys.argv[2:]:
    d = open(p, 'rb').read()
    root += dirent(os.path.basename(p), im.alloc(d), len(d))
im.alloc(root, False, first=2)
im.write(sys.argv[1])
