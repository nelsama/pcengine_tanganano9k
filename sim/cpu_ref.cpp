// cpu_ref.cpp : HuC6280 instruction-level reference model running random code.
//   mem.bin   2 MB initial memory
//   trace.txt "I pc a x y p s cycles" per instruction (state before it),
//             "K addr data 0 0 0 0 0" = poke before the next instruction
//   wr.txt    every memory write: addr data
// Cycle counts without the extra VDC / VCE cycle. usage: cpu_ref seed instructions
#include "cpu_core.h"

static uint64_t rs;
static u32 rnd() { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs >> 24; }
static bool blk(int b) { return b == 0x73 || b == 0xc3 || b == 0xd3 || b == 0xe3 || b == 0xf3; }
static u8 rbyte() { int b; do b = rnd() & 255; while (blk(b)); return b; }
static void poke(u16 a, u8 d) { u32 p = ph(a); mem[p] = d; fprintf(ft, "K %x %x 0 0 0 0 0\n", p, d); }

int main(int argc, char **argv) {
  rs = strtoull(argv[1], 0, 0) * 0x9e3779b97f4a7c15ull + 1;
  int n = atoi(argv[2]);
  for (auto &b : mem) b = rbyte();
  FILE *f = fopen("mem.bin", "wb"); fwrite(mem, 1, sizeof mem, f); fclose(f);
  ft = fopen("trace.txt", "w"); fw = fopen("wr.txt", "w");
  for (auto &b : mpr) b = 0xff;
  mpr[7] = 0; I = 1;
  PC = mem[0x1ffe] | mem[0x1fff] << 8;
  static int cov[256];
  for (int i = 0; i < n; i++) {
    if (i % 8 == 0) {
      static const u8 b1[] = {0x73, 0xc3, 0xd3, 0xe3, 0xf3, 0x53, 0xf8, 0xd8};
      static const u8 b2[] = {0x65, 0x69, 0x05, 0x29, 0x51, 0x7d, 0x72, 0x19};
      int op = rnd() & 255;
      if (i % 64 == 0) op = b1[rnd() & 7];
      if (i % 64 == 8) { poke(PC, 0xf4); poke(PC + 1, b2[rnd() & 7]); poke(PC + 2, rbyte()); }
      else { poke(PC, op); for (int k = 1; k < 7; k++) poke(PC + k, rbyte()); }
    }
    if (blk(rd(PC))) { poke(PC + 5, 1 + (rnd() & 31)); poke(PC + 6, 0); }
    if (blk(rd(PC)) && (rd(PC + 5) == 0 || rd(PC + 6) != 0)) { printf("aliased block length, stop at %d\n", i); break; }
    cov[rd(PC)]++;
    int pc = PC, a = A, x = X, y = Y, p = getp(), s = S;
    int c = step();
    fprintf(ft, "I %x %x %x %x %x %x %d\n", pc, a, x, y, p, s, c);
  }
  int z = 0;
  for (int c : cov) z += c == 0;
  printf("opcodes not executed: %d\n", z);
}
