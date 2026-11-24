# raw2png.py f000.raw ... : frames of tb_pce as PNG, 1152 x 480 (time-scaled, 2x high)
import sys, zlib, struct
for fn in sys.argv[1:]:
    d = open(fn, 'rb').read()
    W, H = 1152, 240
    img = bytearray(W * H * 3)
    for i in range(0, len(d) - 5, 6):
        ln = d[i] + (d[i+1] & 1) * 256
        div = d[i+1] >> 1
        k = 4 if div == 0 else 3 if div == 1 else 2
        x = d[i+2] + d[i+3] * 256
        c = d[i+4] + d[i+5] * 256
        y = ln - 19
        if not 0 <= y < H: continue
        rgb = bytes(v * 255 // 7 for v in (c >> 3 & 7, c >> 6, c & 7))
        for p in range(x * k, min(W, x * k + k)):
            o = (y * W + p) * 3
            img[o:o+3] = rgb
    raw = b''.join(b'\0' + bytes(img[y*W*3:(y+1)*W*3]) for y in range(H) for _ in (0, 1))
    def ch(t, b): return struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b))
    open(fn[:-4] + '.png', 'wb').write(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', W, H * 2, 8, 2, 0, 0, 0))
        + ch(b'IDAT', zlib.compress(raw)) + ch(b'IEND', b''))
