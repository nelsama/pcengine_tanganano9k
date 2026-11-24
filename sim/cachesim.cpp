// cachesim.cpp : runs a HuCard image on the reference core with a minimal VDC
// (registers, VRAM, vblank / raster flags) and prints the slow-down of several ROM caches.
// usage: cachesim rom.pce frames [run-frame]   run-frame: presses Run / I now and then
#define CPU_BUS
#include "cpu_core.h"
#include <vector>
static std::vector<u8> rom;
static u8 ram[8192], vreg_sel, vbuf_l, iobuf, irqmask, port_o, stat, tload, ten;
static u16 vreg[32], vram[65536], rbuf;
static int tcnt, line, frame, pad_cnt; static long long now; static bool tirq;
struct Cache { int size, line, ways, pre; std::vector<int> tag, lru; long long miss, pmiss; int clk; };
static std::vector<Cache> cs; static long long nread; static bool skip;
static int mapb(u32 a) {                     // HuCard mirroring
  u32 n = rom.size();
  if (n == 384 * 1024) return a < 0x80000 ? a & 0x3ffff : 0x40000 | (a & 0x1ffff);
  return a % n;
}
static bool look(Cache &c, int a, bool fill) {
  int l = a / c.line, sets = c.size / c.line / c.ways, s = l % sets;
  for (int w = 0; w < c.ways; w++) if (c.tag[s * c.ways + w] == l) { c.lru[s] = w; return true; }
  if (fill) { int w = c.ways == 2 ? !c.lru[s] : 0; c.tag[s * c.ways + w] = l; c.lru[s] = w; }
  return false;
}
static u8 rdp(u32 a) {
  if (a < 0x100000) {
    int o = mapb(a); nread++;
    for (auto &c : cs) if (!look(c, o, true)) c.miss++;
    return rom[o];
  }
  int b = a >> 13;
  if (b >= 0xf8 && b < 0xfc) return ram[a & 8191];
  if (b != 0xff) return 0xff;
  u32 o = a & 0x1fff;
  if (o < 0x400) switch (o & 3) {
    case 0: { u8 r = stat; stat = 0; return r; }
    case 2: return rbuf;
    case 3: { u8 r = rbuf >> 8; if (vreg_sel == 2) rbuf = vram[++vreg[1]]; return r; }
    default: return 0; }
  if (o >= 0xc00 && o < 0x1000) return tcnt >> 10 | 0;
  if (o >= 0x1000 && o < 0x1400) {
    int k = (frame / 20) % 4 == 1 ? 0xf6 : 0xff;  // Run + I now and then
    return (port_o & 1 ? (k >> 4) : k) & 15 & (port_o & 2 ? 0 : 15);
  }
  if (o >= 0x1400 && o < 0x1800) return (o & 3) == 2 ? irqmask : (o & 3) == 3 ? tirq << 2 | (stat != 0) << 1 : iobuf;
  return 0xff;
}
static void wrp(u32 a, u8 d) {
  int b = a >> 13;
  if (b >= 0xf8 && b < 0xfc) { ram[a & 8191] = d; return; }
  if (b != 0xff) return;
  u32 o = a & 0x1fff;
  if (o < 0x400) {
    static const int inc[4] = {1, 32, 64, 128};
    switch (o & 3) {
      case 0: vreg_sel = d & 31; break;
      case 2: vbuf_l = d; vreg[vreg_sel] = (vreg[vreg_sel] & 0xff00) | d; break;
      case 3: vreg[vreg_sel] = (vreg[vreg_sel] & 0xff) | d << 8;
        if (vreg_sel == 2) { vram[vreg[0]] = vreg[2]; vreg[0] += inc[vreg[5] >> 11 & 3]; }
        if (vreg_sel == 1) rbuf = vram[vreg[1]];
        if (vreg_sel == 18 && (vreg[15] & 2)) stat |= 16;
    } return;
  }
  if (o >= 0xc00 && o < 0x1000) { if (o & 1) { if ((d & 1) && !ten) tcnt = (tload + 1) << 10; ten = d & 1; } else tload = d & 127; }
  else if (o >= 0x1000 && o < 0x1400) port_o = d;
  else if (o >= 0x1400 && o < 0x1800) { if ((o & 3) == 2) irqmask = d & 7; if ((o & 3) == 3) tirq = 0; }
}
static void irq(int v) { push(PC >> 8); push(PC); push(getp() & ~16); D = 0; T = 0; I = 1; PC = rd(v) | rd(v + 1) << 8; }
int main(int c, char **v) {
  FILE *f = fopen(v[1], "rb"); int ch; while ((ch = fgetc(f)) >= 0) rom.push_back(ch); fclose(f);
  if (rom.size() % 8192 == 512) rom.erase(rom.begin(), rom.begin() + 512);
  int frames = atoi(v[2]);
  // miss cost in CPU cycles (7.2 MHz = 12 memclk): CDC 3 + read 10 + words, variable latency
  for (int sz : {2048, 4096, 8192}) for (int ln : {16, 32, 64}) for (int w : {1, 2}) {
    Cache k; k.size = sz; k.line = ln; k.ways = w; k.tag.assign(sz / ln, -1); k.lru.assign(sz / ln, 0); k.miss = 0; k.clk = 8 + 10 + ln / 2; cs.push_back(k); }
  for (auto &b : mpr) b = 0xff; mpr[7] = 0; I = 1; PC = rd(0xfffe) | rd(0xffff) << 8;
  long long cyc = 0; int lc = 0;
  while (frame < frames) {
    if (!I) {
      if (tirq && !(irqmask & 4)) { irq(0xfffa); cyc += 8; }
      else if (stat && !(irqmask & 2)) { irq(0xfff8); cyc += 8; }
    }
    int n = step(); cyc += n; lc += n;
    if (ten) { tcnt -= n; if (tcnt < 0) { tcnt += (tload + 1) << 10; tirq = 1; } }
    if (lc >= 455) { lc -= 455; line++;
      if (line + 64 - 14 == (vreg[6] & 0x3ff) && (vreg[5] & 4)) stat |= 4;
      if (line == 240 && (vreg[5] & 8)) stat |= 32;
      if (line == 263) { line = 0; frame++; } }
  }
  printf("frames %d, ROM reads %lld of %lld cycles, pc %04x\n size line ways   miss%%  slow-down%%\n", frames, nread, cyc, PC);
  for (auto &k : cs) printf("%5d %4d %3d  %7.3f  %6.2f\n", k.size, k.line, k.ways, 100.0 * k.miss / nread, 100.0 * k.miss * k.clk / 12 / cyc);
}
