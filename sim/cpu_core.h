// cpu_core.h : HuC6280 instruction-level reference model (registers, cycles).
// With CPU_BUS the includer provides rdp / wrp (physical read / write).
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32;
static u8 mem[1 << 21], A, X, Y, S, mpr[8];
static u16 PC;
static bool N, V, T, D, I, Z, C;
static FILE *ft, *fw;
#ifdef CPU_BUS
static u8 rdp(u32 a);
static void wrp(u32 a, u8 d);
#endif
static u32 ph(u16 a) { return mpr[a >> 13] << 13 | (a & 0x1fff); }
#ifndef CPU_BUS
static u8 rdp(u32 a) { return mem[a]; }
static void wrp(u32 a, u8 d) { mem[a] = d; fprintf(fw, "%x %x\n", a, d); }
#endif
static u8 rd(u16 a) { return rdp(ph(a)); }
static void wr(u16 a, u8 d) { wrp(ph(a), d); }
static u8 imm() { return rd(PC++); }
static u16 imm16() { u8 l = imm(); return l | imm() << 8; }
static void push(u8 d) { wr(0x2100 | S, d); S--; }
static u8 pull() { S++; return rd(0x2100 | S); }
static u8 zn(u8 v) { N = v >> 7; Z = v == 0; return v; }
static u8 getp() { return N << 7 | V << 6 | T << 5 | 16 | D << 3 | I << 2 | Z << 1 | C; }
static void setp(u8 p) { N = p >> 7 & 1; V = p >> 6 & 1; T = p >> 5 & 1; D = p >> 3 & 1; I = p >> 2 & 1; Z = p >> 1 & 1; C = p & 1; }
static u16 zpp(u8 z) { return rd(0x2000 | z) | rd(0x2000 | u8(z + 1)) << 8; }

static u8 adc(u8 a, u8 m) {
  int r;
  if (D) {
    int lo = (a & 15) + (m & 15) + C, hi = (a >> 4) + (m >> 4);
    if (lo > 9) { lo += 6; hi++; }
    if (hi > 9) hi += 6;
    C = hi > 15;
    r = (hi & 15) << 4 | (lo & 15);
  } else {
    r = a + m + C;
    V = (~(a ^ m) & (a ^ r) & 0x80) != 0;
    C = r > 255;
  }
  return zn(r);
}
static u8 sbc(u8 a, u8 m) {
  int b = !C, r = a - m - b;
  if (D) {
    int lo = (a & 15) - (m & 15) - b, hi = (a >> 4) - (m >> 4);
    if (lo < 0) { lo -= 6; hi--; }
    if (hi < 0) hi -= 6;
    C = r >= 0;
    r = (hi & 15) << 4 | (lo & 15);
  } else {
    V = ((a ^ m) & (a ^ r) & 0x80) != 0;
    C = r >= 0;
  }
  return zn(r);
}
static void cmp(u8 a, u8 m) { C = a >= m; zn(a - m); }
static u8 shift(int k, u8 v) {            // 0 ASL 1 ROL 2 LSR 3 ROR
  bool c = C;
  switch (k) {
    case 0: C = v >> 7; v = v << 1; break;
    case 1: C = v >> 7; v = v << 1 | c; break;
    case 2: C = v & 1; v = v >> 1; break;
    default: C = v & 1; v = v >> 1 | c << 7;
  }
  return zn(v);
}
static void bitf(u8 m, u8 a) { N = m >> 7; V = m >> 6 & 1; Z = (m & a) == 0; }
static int branch(bool c, int base) { int8_t o = imm(); if (c) { PC += o; base += 2; } return base; }

// effective address of the regular modes; *cy = cycles of a read / write
static u16 ea(int low5, bool y_index, int *cy) {
  u16 a;
  switch (low5) {
    case 0x01: *cy = 7; return zpp(imm() + X);
    case 0x04: case 0x05: case 0x06: *cy = 4; return 0x2000 | imm();
    case 0x0c: case 0x0d: case 0x0e: *cy = 5; return imm16();
    case 0x11: *cy = 7; a = zpp(imm()); return a + Y;
    case 0x12: *cy = 7; return zpp(imm());
    case 0x14: case 0x15: case 0x16: *cy = 4; return 0x2000 | u8(imm() + (y_index ? Y : X));
    case 0x19: *cy = 5; a = imm16(); return a + Y;
    default:   *cy = 5; a = imm16(); return a + (y_index ? Y : X);     // 1c 1d 1e
  }
}

static int step() {
  u8 op = imm();
  bool t = T; T = 0;
  int cy, l5 = op & 31, hi = op >> 5;
  u16 a; u8 m;
  // group 1
  if (((op & 3) == 1 || l5 == 0x12) && op != 0x89) {
    if (l5 == 9) { cy = 2; a = PC++; }
    else a = ea(l5, false, &cy);
    if (hi == 4) { wr(a, A); return cy; }
    m = rd(a);
    if (t && hi < 4) {
      u8 q = rd(0x2000 | X);
      switch (hi) { case 0: q = zn(q | m); break; case 1: q = zn(q & m); break;
                    case 2: q = zn(q ^ m); break; default: q = adc(q, m); }
      wr(0x2000 | X, q);
      return cy + 3 + (hi == 3 && D);
    }
    switch (hi) {
      case 0: A = zn(A | m); break;
      case 1: A = zn(A & m); break;
      case 2: A = zn(A ^ m); break;
      case 3: A = adc(A, m); cy += D; break;
      case 5: A = zn(m); break;
      case 6: cmp(A, m); break;
      case 7: A = sbc(A, m); cy += D; break;
    }
    return cy;
  }
  switch (op) {
    // loads, stores, compares
    case 0xa2: X = zn(imm()); return 2;
    case 0xa0: Y = zn(imm()); return 2;
    case 0xa6: case 0xae: X = zn(rd(ea(l5, 0, &cy))); return cy;
    case 0xb6: case 0xbe: X = zn(rd(ea(l5, 1, &cy))); return cy;
    case 0xa4: case 0xac: case 0xb4: case 0xbc: Y = zn(rd(ea(l5, 0, &cy))); return cy;
    case 0x86: case 0x8e: a = ea(l5, 0, &cy); wr(a, X); return cy;
    case 0x96: a = ea(l5, 1, &cy); wr(a, X); return cy;
    case 0x84: case 0x8c: case 0x94: a = ea(l5, 0, &cy); wr(a, Y); return cy;
    case 0x64: case 0x74: case 0x9e: a = ea(l5, 0, &cy); wr(a, 0); return cy;
    case 0x9c: a = imm16(); wr(a, 0); return 5;
    case 0xe0: cmp(X, imm()); return 2;
    case 0xc0: cmp(Y, imm()); return 2;
    case 0xe4: case 0xec: cmp(X, rd(ea(l5, 0, &cy))); return cy;
    case 0xc4: case 0xcc: cmp(Y, rd(ea(l5, 0, &cy))); return cy;
    case 0x89: bitf(imm(), A); return 2;
    case 0x24: case 0x2c: case 0x34: case 0x3c: bitf(rd(ea(l5, 0, &cy)), A); return cy;
    // read-modify-write
    case 0x06: case 0x0e: case 0x16: case 0x1e: case 0x26: case 0x2e: case 0x36: case 0x3e:
    case 0x46: case 0x4e: case 0x56: case 0x5e: case 0x66: case 0x6e: case 0x76: case 0x7e:
      a = ea(l5, 0, &cy); wr(a, shift(hi, rd(a))); return cy + 2;
    case 0xc6: case 0xce: case 0xd6: case 0xde: a = ea(l5, 0, &cy); wr(a, zn(rd(a) - 1)); return cy + 2;
    case 0xe6: case 0xee: case 0xf6: case 0xfe: a = ea(l5, 0, &cy); wr(a, zn(rd(a) + 1)); return cy + 2;
    case 0x04: case 0x0c: a = ea(l5, 0, &cy); m = rd(a); N = m >> 7; V = m >> 6 & 1; m |= A; Z = !m; wr(a, m); return cy + 2;
    case 0x14: a = 0x2000 | imm(); m = rd(a); N = m >> 7; V = m >> 6 & 1; m &= ~A; Z = !m; wr(a, m); return 6;
    case 0x1c: a = imm16(); m = rd(a); N = m >> 7; V = m >> 6 & 1; m &= ~A; Z = !m; wr(a, m); return 7;
    case 0x0a: case 0x2a: case 0x4a: case 0x6a: A = shift(hi, A); return 2;
    case 0x1a: A = zn(A + 1); return 2;
    case 0x3a: A = zn(A - 1); return 2;
    case 0x88: Y = zn(Y - 1); return 2;
    case 0xc8: Y = zn(Y + 1); return 2;
    case 0xca: X = zn(X - 1); return 2;
    case 0xe8: X = zn(X + 1); return 2;
    // transfers and flags
    case 0x8a: A = zn(X); return 2;
    case 0x98: A = zn(Y); return 2;
    case 0xaa: X = zn(A); return 2;
    case 0xa8: Y = zn(A); return 2;
    case 0x9a: S = X; return 2;
    case 0xba: X = zn(S); return 2;
    case 0x62: A = 0; return 2;
    case 0x82: X = 0; return 2;
    case 0xc2: Y = 0; return 2;
    case 0x02: m = X; X = Y; Y = m; return 3;
    case 0x22: m = X; X = A; A = m; return 3;
    case 0x42: m = Y; Y = A; A = m; return 3;
    case 0x18: C = 0; return 2;
    case 0x38: C = 1; return 2;
    case 0x58: I = 0; return 2;
    case 0x78: I = 1; return 2;
    case 0xb8: V = 0; return 2;
    case 0xd8: D = 0; return 2;
    case 0xf8: D = 1; return 2;
    case 0xf4: T = 1; return 2;
    case 0x54: case 0xd4: return 3;
    // stack
    case 0x08: push(getp()); return 3;
    case 0x48: push(A); return 3;
    case 0x5a: push(Y); return 3;
    case 0xda: push(X); return 3;
    case 0x28: setp(pull()); return 4;
    case 0x68: A = zn(pull()); return 4;
    case 0x7a: Y = zn(pull()); return 4;
    case 0xfa: X = zn(pull()); return 4;
    // control
    case 0x00: PC++; push(PC >> 8); push(PC); push(getp()); D = 0; I = 1; PC = rd(0xfff6) | rd(0xfff7) << 8; return 8;
    case 0x20: a = imm16(); PC--; push(PC >> 8); push(PC); PC = a; return 7;
    case 0x44: push(PC >> 8); push(PC); branch(true, 0); return 8;
    case 0x40: setp(pull()); a = pull(); PC = a | pull() << 8; return 7;
    case 0x60: a = pull(); PC = a | pull() << 8; PC++; return 7;
    case 0x4c: PC = imm16(); return 4;
    case 0x6c: a = imm16(); PC = rd(a) | rd(a + 1) << 8; return 7;
    case 0x7c: a = imm16() + X; PC = rd(a) | rd(a + 1) << 8; return 7;
    case 0x80: return branch(true, 2);
    case 0x10: return branch(!N, 2);
    case 0x30: return branch(N, 2);
    case 0x50: return branch(!V, 2);
    case 0x70: return branch(V, 2);
    case 0x90: return branch(!C, 2);
    case 0xb0: return branch(C, 2);
    case 0xd0: return branch(!Z, 2);
    case 0xf0: return branch(Z, 2);
    // HuC6280
    case 0x03: wrp(0x1fe000, imm()); return 4;
    case 0x13: wrp(0x1fe002, imm()); return 4;
    case 0x23: wrp(0x1fe003, imm()); return 4;
    case 0x43: m = imm(); for (int i = 0; i < 8; i++) if (m >> i & 1) A = mpr[i]; return 4;
    case 0x53: m = imm(); for (int i = 0; i < 8; i++) if (m >> i & 1) mpr[i] = A; return 5;
    case 0x83: m = imm(); a = 0x2000 | imm(); bitf(rd(a), m); return 7;
    case 0x93: m = imm(); a = imm16(); bitf(rd(a), m); return 8;
    case 0xa3: m = imm(); a = 0x2000 | u8(imm() + X); bitf(rd(a), m); return 7;
    case 0xb3: m = imm(); a = imm16() + X; bitf(rd(a), m); return 8;
    case 0x73: case 0xc3: case 0xd3: case 0xe3: case 0xf3: {
      u16 s = imm16(), d = imm16(), n = imm16();
      int c = 17, k = 0;
      do {
        wr(d, rd(s)); c += 6;
        switch (op) {
          case 0x73: s++; d++; break;
          case 0xc3: s--; d--; break;
          case 0xd3: s++; break;
          case 0xe3: s++; d += k ? -1 : 1; break;
          default:   d++; s += k ? -1 : 1;
        }
        k ^= 1;
      } while (--n);
      return c;
    }
  }
  if ((op & 7) == 7) {
    int b = op >> 4 & 7;
    a = 0x2000 | imm(); m = rd(a);
    if (op & 8) return branch((m >> b & 1) == (op >> 7), 6);
    wr(a, op & 0x80 ? m | 1 << b : m & ~(1 << b));
    return 7;
  }
  return 2;                                  // undefined: 2-cycle NOP
}

