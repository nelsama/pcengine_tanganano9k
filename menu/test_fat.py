"""Host test of fat.c: builds a FAT32 image (MBR or not, LFN, subdirectory,
fragmented files), lists it and checks what the loader writes to the PSRAM."""
import os, random, struct, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__))
B = os.path.join(here, '..', 'build', 'menu'); os.makedirs(B, exist_ok=True)
random.seed(1)

def rom(size, hdr=False):
    b = bytearray(random.randbytes(size))
    if size > 8191: b[8191] = random.choice((0x05, 0xE0, 0xFF, 0x77))
    return (b'H' * 512 if hdr else b'') + bytes(b)

class Img:
    def __init__(s, part, spc):
        s.part, s.spc = part, spc; s.hint = 0xFFFFFFFF; s.res, s.fsz = 32, 600
        s.data = part + s.res + 2 * s.fsz
        s.tot = s.data - part + 7000 * spc
        s.sec = {}; s.fat = {0: 0x0FFFFFF8, 1: 0x0FFFFFFF}
        s.free = list(range(3, 6000));
    def alloc(s, data, frag=False, first=None):
        n = max(1, -(-len(data) // (s.spc * 512)))
        cl = [s.free.pop(random.randrange(3000) if frag else 0) for _ in range(n)]
        if first: s.free.append(cl[0]); cl[0] = first
        for a, b in zip(cl, cl[1:] + [0x0FFFFFFF]): s.fat[a] = b
        for i, c in enumerate(cl):
            for k in range(s.spc):
                o = (i * s.spc + k) * 512
                s.sec[s.data + (c - 2) * s.spc + k] = data[o:o + 512].ljust(512, b'\0')
        return cl[0]
    def write(s, path):
        b = bytearray(512); b[11:13] = struct.pack('<H', 512); b[13] = s.spc
        b[14:16] = struct.pack('<H', s.res); b[16] = 2; b[32:36] = struct.pack('<I', s.tot); b[48:50] = struct.pack('<H', 1); b[67:71] = b'ABCD'
        i = bytearray(512); i[0:4] = b'RRaA'; i[484:488] = b'rrAa'; i[488:492] = struct.pack('<I', 999); i[492:496] = struct.pack('<I', s.hint)
        s.sec[s.part + 1] = bytes(i)
        b[36:40] = struct.pack('<I', s.fsz); b[44:48] = struct.pack('<I', 2); b[510:512] = b'\x55\xaa'
        s.sec[s.part] = bytes(b)
        if s.part:
            m = bytearray(512); m[446 + 4] = 12; m[454:458] = struct.pack('<I', s.part); m[510:512] = b'\x55\xaa'
            s.sec[0] = bytes(m)
        ft = bytearray(s.fsz * 512)
        for c, v in s.fat.items(): ft[c * 4:c * 4 + 4] = struct.pack('<I', v)
        for k in range(s.fsz): s.sec[s.part + s.res + k] = s.sec[s.part + s.res + s.fsz + k] = bytes(ft[k * 512:k * 512 + 512])
        with open(path, 'wb') as f:
            for k, v in s.sec.items(): f.seek(k * 512); f.write(v)

cnt = [0]
def dirent(name, cl, size, isdir=False, attr=None):
    cnt[0] += 1
    short = (b'F%06d ' % cnt[0]) + (b'   ' if isdir else b'PCE')
    if name == '..': short = b'..         ';
    out = b''
    if name != '..':
        u = name.encode('utf-16le') + b'\0\0'
        while len(u) % 26: u += b'\xff\xff'
        ch = [u[i:i + 26] for i in range(0, len(u), 26)]
        for i in reversed(range(len(ch))):
            c = ch[i]
            out += bytes([(i + 1) | (0x40 if i == len(ch) - 1 else 0)]) + c[:10] + b'\x0f\0\0' + c[10:22] + b'\0\0' + c[22:]
    e = bytearray(32); e[:11] = short; e[11] = attr if attr is not None else (0x10 if isdir else 0x20)
    e[20:22] = struct.pack('<H', cl >> 16); e[26:28] = struct.pack('<H', cl & 0xFFFF); e[28:32] = struct.pack('<I', size)
    return out + bytes(e)

HOST = r'''
#include "fat.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static FILE *f; static u8 mem[2][1<<22];
static int rd(u32 l,u8*d){memset(d,0,512);fseek(f,(long)l*512,0);fread(d,1,512,f);return 1;}
u8 sd_read(u32 l){return rd(l,buf);}
u8 sd_dma(u32 l,u8 die,u32 a){u8 t[512];rd(l,t);for(int i=0;i<512;i++)mem[die][(a+i)&0x3FFFFF]=t[i];return 1;}
u8 sd_write(u32 l){FILE*g=f;fseek(g,(long)l*512,0);if(fwrite(buf,1,512,g)!=512){printf("WERR");exit(1);}fflush(g);return 1;}
void bram_read(u8 k){for(int i=0;i<512;i++)buf[i]=mem[1][k*512+i];}
void bram_write(u8 k){for(int i=0;i<512;i++)mem[1][k*512+i]=buf[i];}
void progress(u16 k,u16 t){}
void pg_test(void);
static void dump(u32 dir,int lv){for(u16 sk=0;;sk++){if(!fat_list(dir,sk)){printf("ERR %d\n",fat_err);return;}
 static entry_t l[4][LIST_N];int n=list_len,m=list_more;memcpy(l[lv],list,sizeof list);
 for(int i=0;i<n;i++){printf("%d %d %u %s\n",lv,l[lv][i].isdir,l[lv][i].cl,l[lv][i].name);
  if(l[lv][i].isdir&&l[lv][i].name[0]!='.')dump(l[lv][i].cl,lv+1);}
 if(!m){static entry_t a[LIST_N];fat_list(dir,sk);memcpy(a,list,sizeof a);int x=list_len;
  pg_test();fat_list(dir,sk);if(x!=list_len||memcmp(a,list,sizeof(entry_t)*x))printf("SEEK DIFF\n");
  pg_test();fat_list(dir,sk+9);if(list_page!=sk||x!=list_len||memcmp(a,list,sizeof(entry_t)*x))printf("END DIFF %d %d\n",list_page,sk);
  return;}}}
int main(int c,char**v){f=fopen(v[1],"rb+");if(!fat_mount()){printf("MOUNT %d\n",fat_err);return 0;}
 if(c==2){dump(0,0);return 0;}
 if(v[2][0]=='s'||v[2][0]=='l'){u32 d=strtoul(v[3],0,10);char sn[9];sprintf(sn,"%-8s",v[4]);FILE*g;
  if(v[2][0]=='s'){g=fopen(v[5],"rb");fread(mem[1],1,2048,g);fclose(g);printf("%d",fat_save(d,sn));printf(" %d\n",fat_err);}
  else{printf("%d",fat_load_sav(d,sn));printf(" %d\n",fat_err);g=fopen(v[5],"wb");fwrite(mem[1],1,2048,g);fclose(g);}return 0;}
 int r=fat_load(strtoul(v[2],0,10),strtoul(v[4],0,10));printf("%d %d %u %d\n",r,fat_err,rom_size,rom_flip);
 f=fopen(v[3],"wb");fwrite(mem,1,sizeof mem,f);fclose(f);}
'''
open(os.path.join(B, 'host.c'), 'w').write(HOST)
exe = os.path.join(B, 'host.exe')
subprocess.check_call(['gcc', '-DHOST', '-O1', '-I', here, '-o', exe, os.path.join(B, 'host.c'), os.path.join(here, 'fat.c')])
run = lambda *a: subprocess.check_output([exe] + list(a), text=True)
ok = True
def check(c, m):
    global ok
    if not c: ok = False; print('FAIL', m)
for part, spc in ((0, 1), (2048, 8), (2048, 64)):
    im = Img(part, spc); files = {}
    for name, r, frag in (('Small game.pce', rom(8192), True), ('Thirty two k.pce', rom(32768), False),
            ('A very long file name that does not fit (U).pce', rom(262144), True),
            ('header.pce', rom(131072, True), True), ('big.pce', rom(1 << 20), False),
            ('odd.pce', rom(50000), True), ('tiny.pce', rom(7000), False)):
        files[name] = (r, im.alloc(r, frag))
    d = b''.join(dirent(n, c, len(r)) for n, (r, c) in files.items())
    sub = dirent('..', 0, 0, True) + b''.join(dirent('file %02d.pce' % i, files['big.pce'][1], 9) for i in range(48))
    subc = im.alloc(sub, True)
    root = dirent('VOL', 0, 0, attr=8) + dirent('Games', subc, 0, True) + d
    root += b'\xe5' + dirent('deleted.pce', 5, 0)[1:32] + b'\xe5' + dirent('x.pce', 5, 0)[33:]
    im.alloc(root, True, first=2)
    im.hint = 6995 if spc == 8 else 0xFFFFFFFF
    p = os.path.join(B, 't.img'); im.write(p)
    L = run(p).splitlines()
    names = [x.split(' ', 3)[3] for x in L]
    check(names == ['Games', '..'] + ['file %02d.pce' % i for i in range(48)] + [n[:27] for n in files], 'list %s' % L)
    for n, (r, c) in files.items():
        out = run(p, str(c), os.path.join(B, 'm.bin'), str(len(r))).split()
        if n == 'tiny.pce':
            check(out[0] == '0', n); continue
        m = open(os.path.join(B, 'm.bin'), 'rb').read()
        want = r[512:] if n == 'header.pce' else r
        check(out[0] == '1' and m[:len(want)] == want and int(out[2]) == len(want) and int(out[3]) == (want[8191] < 0xE0), n + ' %s' % out)
    trunc = run(p, str(files['Small game.pce'][1]), os.path.join(B, 'm.bin'), '900000').split()
    check(trunc[0] == '0', 'truncated')
    # --- save files, checked with an independent reader ---
    def vol():
        D = open(p, 'rb').read(); base = im.part * 512
        F = [struct.unpack('<%dI' % (im.fsz * 128), D[base + (im.res + k * im.fsz) * 512:][:im.fsz * 512]) for k in (0, 1)]
        check(F[0] == F[1], 'FAT copies')
        def chain(c):
            o = []
            while 2 <= c < 0x0FFFFFF7: o.append(c); c = F[0][c] & 0x0FFFFFFF; check(len(o) < 90000, 'loop')
            return o
        def data(c): return b''.join(D[(im.data + (x - 2) * spc) * 512:(im.data + (x - 1) * spc) * 512] for x in chain(c))
        used, res = {}, {}
        def walk(c, path):
            d = data(c)
            for x in chain(c): check(x not in used or path == '/Games/', 'cross link'); used[x] = path
            for i in range(0, len(d), 32):
                e = d[i:i + 32]
                if e[0] == 0: break
                if e[0] == 0xE5 or e[11] & 8 or e[:1] == b'.': continue
                cl = struct.unpack('<H', e[20:22])[0] << 16 | struct.unpack('<H', e[26:28])[0]
                n = path + e[:11].decode()
                if e[11] & 16: walk(cl, n + '/'); continue
                sz = struct.unpack('<I', e[28:32])[0]
                res[n] = data(cl)[:sz]
                if 'SAV' in n:
                    for x in chain(cl): check(x not in used, 'cross link ' + n); used[x] = n
                    check(len(chain(cl)) == -(-sz // (spc * 512)), 'chain length ' + n)
        walk(2, '/')
        return res
    sv = os.path.join(B, 's.bin'); so = os.path.join(B, 'so.bin')
    before = vol(); want = dict(before)
    for rnd, (d, sn) in enumerate(((2, 'GAMEONE'), (2, 'GAMEONE'), (subc, 'GAME2'), (2, 'ABCDEFG'), (subc, 'GAME2'))):
        blob = random.randbytes(2048); open(sv, 'wb').write(blob)
        if rnd == 0:
            check(run(p, 'l', str(d), sn, so) == '1 0\n' and open(so, 'rb').read() == bytes(2048), 'no save yet')
        check(run(p, 's', str(d if d != 2 else 0), sn, sv) == '1 0\n', 'save %d' % rnd)
        check(run(p, 'l', str(d if d != 2 else 0), sn, so) == '1 0\n' and open(so, 'rb').read() == blob, 'reload %d' % rnd)
        got = vol()
        key = [k for k in got if k.endswith('%-8sSAV' % sn)]
        check(len(key) == 1 and got[key[0]] == blob, 'saved data %s' % key)
        want[key[0]] = blob
        check(got == want, 'other files changed')
    # full volume: nothing may change
    im2 = open(p, 'rb').read(); ft = bytearray(im2)
    for k in (0, 1):
        b0 = (im.part + im.res + k * im.fsz) * 512
        for c in range(2, im.fsz * 128):
            if ft[b0 + c * 4:b0 + c * 4 + 4] == bytes(4): ft[b0 + c * 4:b0 + c * 4 + 4] = b'\xff\xff\xff\x0f'
    open(p, 'wb').write(ft)
    check(run(p, 's', '0', 'NOROOM', sv) == '0 5\n' and open(p, 'rb').read() == bytes(ft), 'full volume')
print('OK' if ok else 'FAILED')
