// menu.c : file browser of the flash cart (HuC6280, cc65, 16 KB at $C000)
#include "fat.h"
#define REG(a) (*(volatile u8 *)(a))
// I/O bank at $0000; mirrors above $00FF, ca65 would use zero page below
#define VST REG(0x0200)
#define VDL REG(0x0202)
#define VDH REG(0x0203)
#define VCE_CR REG(0x0400)
#define VCE_AL REG(0x0402)
#define VCE_AH REG(0x0403)
#define VCE_DL REG(0x0404)
#define VCE_DH REG(0x0405)
#define PADP REG(0x1000)
#define SPI REG(0x1800)
#define SPI_ST REG(0x1801)
#define ADR0 REG(0x1802)
#define ADR1 REG(0x1803)
#define ADR2 REG(0x1804)
#define DMA REG(0x1805)
#define ROMMODE REG(0x1806)
#define MASK REG(0x1807)
#define RUN REG(0x1808)
#define CLEAN REG(0x1809)
#define NOTE ((volatile u8 *)0x1810)
#define BRAM ((volatile u8 *)0x6000)

extern const u8 font[];
void read512(u8 *p);            // crt0.s
void write512(u8 *p);
static u8 sdhc;

// --- SD card ------------------------------------------------------------------
static u8 xfer(u8 b) {
  SPI = b;
  while (SPI_ST & 0x80) ;
  return SPI;
}
static u8 speed;          // 0 slow, 2 fast
static void deselect(void) { SPI_ST = speed | 1; xfer(0xFF); }
static u8 command(u8 c, u32 arg, u8 crc) {
  u8 i, r;
  deselect();
  SPI_ST = speed;
  xfer(0xFF);
  xfer(c | 0x40);
  xfer((u8)(arg >> 24)); xfer((u8)(arg >> 16)); xfer((u8)(arg >> 8)); xfer((u8)arg);
  xfer(crc);
  for (i = 0; i < 10; ++i) {
    r = xfer(0xFF);
    if (!(r & 0x80)) break;
  }
  return r;
}
static u8 sd_init(void) {
  u8 i, r, v2;
  u16 n;
  speed = 0;
  SPI_ST = 1;
  for (i = 0; i < 12; ++i) xfer(0xFF);
  for (n = 0; n < 50; ++n) if (command(0, 0, 0x95) == 1) break;
  if (n == 50) return 0;
  v2 = 0;
  if (command(8, 0x1AA, 0x87) == 1) {
    xfer(0xFF); xfer(0xFF); xfer(0xFF);
    if (xfer(0xFF) != 0xAA) return 0;
    v2 = 1;
  }
  r = 1;
  for (n = 0; n < 2000; ++n) {
    command(55, 0, 0xFF);
    r = command(41, v2 ? 0x40000000UL : 0, 0xFF);
    if (r == 0) break;
  }
  if (r) return 0;
  sdhc = 0;
  if (v2) {
    if (command(58, 0, 0xFF)) return 0;
    if (xfer(0xFF) & 0x40) sdhc = 1;
    xfer(0xFF); xfer(0xFF); xfer(0xFF);
  }
  if (!sdhc && command(16, 512, 0xFF)) return 0;
  speed = 2;
  deselect();
  return 1;
}
static u8 start_read(u32 lba) {
  u16 n;
  u8 r;
  if (!sdhc) lba <<= 9;
  if (command(17, lba, 0xFF)) return 0;
  for (n = 0; n < 20000; ++n) {
    r = xfer(0xFF);
    if (r == 0xFE) return 1;
    if (r != 0xFF) return 0;
  }
  return 0;
}
u8 sd_dma(u32 lba, u8 die, u32 addr) {
  if (!start_read(lba)) { deselect(); return 0; }
  ADR0 = (u8)addr;
  ADR1 = (u8)(addr >> 8);
  ADR2 = (u8)(addr >> 16);
  DMA = rom_flip;
  while (SPI_ST & 0x80) ;
  xfer(0xFF); xfer(0xFF);
  deselect();
  return 1;
}
u8 sd_read(u32 lba) {
  if (!start_read(lba)) { deselect(); return 0; }
  read512(buf);                 // leaves the first CRC byte on its way
  while (SPI_ST & 0x80) ;
  xfer(0xFF);
  deselect();
  return 1;
}

u8 sd_write(u32 lba) {
  u16 n;
  u8 r;
  if (!sdhc) lba <<= 9;
  if (command(24, lba, 0xFF)) { deselect(); return 0; }
  xfer(0xFF);
  xfer(0xFE);
  write512(buf);
  while (SPI_ST & 0x80) ;
  xfer(0xFF); xfer(0xFF);
  r = xfer(0xFF) & 0x1F;
  for (n = 60000U; n; --n) if (xfer(0xFF) == 0xFF) break;   // busy
  deselect();
  return n && r == 5;
}
void bram_read(u8 k) {
  u16 i;
  volatile u8 *p = BRAM + ((u16)k << 9);
  for (i = 0; i < 512; ++i) buf[i] = p[i];
}
void bram_write(u8 k) {
  u16 i;
  volatile u8 *p = BRAM + ((u16)k << 9);
  for (i = 0; i < 512; ++i) p[i] = buf[i];
}

// --- screen -------------------------------------------------------------------
static void vblank(void) { while (!(VST & 0x20)) ; }
static void reg(u8 n, u16 v) { VST = n; VDL = (u8)v; VDH = (u8)(v >> 8); }
static void cell(u8 x, u8 y) { reg(0, ((u16)y << 5) + x); VST = 2; }
static void put(u8 c, u8 at) { VDL = c; VDH = at; }   // at: palette << 4 | 1
#define NORMAL 0x01
#define INVERT 0x11
static void at(u8 x, u8 y, const char *s) {
  cell(x, y);
  while (*s) put(*s++, NORMAL);
}
static void cls(void) {
  u16 i;
  cell(0, 0);
  for (i = 0; i < 1024; ++i) put(' ', NORMAL);
}
static void mark(u8 row, u8 pal) {          // highlight a line of the list
  u8 i;
  const char *s = list[row].name;
  cell(1, row + 4);
  put(list[row].isdir ? '/' : ' ', pal);
  for (i = 0; i < 29; ++i) {
    put(*s ? *s : ' ', pal);
    if (*s) ++s;
  }
}
void progress(u16 k, u16 total) {
  static u8 done;
  u8 n = (u8)(((u32)k * 24) / total);
  if (k == 0) done = 0;
  while (done < n) { cell(4 + done, 14); put(' ', INVERT); ++done; }
}
static const char *const msgs[] = {"", "NO SD CARD", "SD READ ERROR", "NOT FAT32", "BAD SIZE", "SD FULL", "FOLDER FULL"};

static u8 pad_now, pad_new;                 // up right down left I II sel run
static void readpad(void) {
  u8 old = pad_now, d;
  PADP = 1;
  PADP = 3;
  PADP = 1;
  d = PADP;
  d = PADP & 15;
  PADP = 0;
  pad_now = PADP;
  pad_now = (u8)~((PADP << 4) | d);
  pad_new = pad_now & ~old;
}
#define UP 0x01
#define RIGHT 0x02
#define DOWN 0x04
#define LEFT 0x08
#define B_I 0x10
#define B_II 0x20
#define B_RUN 0x80
#define OPEN (B_I | B_RUN)

static u32 dir_stack[6];
static u16 page_stack[6];
static u8 depth, sel;
static u32 dir;
static u16 page;

static void title(void) { at(4, 1, "TANG NANO 9K  PC ENGINE"); }

static void fail(void) {
  cls();
  title();
  at(4, 10, msgs[fat_err]);
  at(4, 13, "PRESS I");
  do { vblank(); readpad(); } while (!(pad_new & OPEN));
}

static void draw(void) {
  u8 i;
  vblank();
  reg(5, 0x0008);                           // display off
  cls();
  title();
  if (!list_len) at(4, 10, "NO PCE FILES HERE");
  for (i = 0; i < list_len; ++i) mark(i, i == sel ? INVERT : NORMAL);
  if (page) at(2, 21, "< LEFT");
  if (list_more) at(23, 21, "RIGHT >");
  at(2, 23, "I OPEN   II BACK");
  reg(5, 0x0088);
}
static void move(u8 n) {
  mark(sel, NORMAL);
  sel = n;
  mark(sel, INVERT);
}

// --- saved games --------------------------------------------------------------
// NOTE: serial number of the card, directory, short name of the game
static void put_note(u8 o, u32 v) {
  NOTE[o] = (u8)v; NOTE[o + 1] = (u8)(v >> 8); NOTE[o + 2] = (u8)(v >> 16); NOTE[o + 3] = (u8)(v >> 24);
}
static u32 get_note(u8 o) {
  return ((u32)(NOTE[o + 2] | ((u16)NOTE[o + 3] << 8)) << 16) | (u16)(NOTE[o] | ((u16)NOTE[o + 1] << 8));
}
// back from a game: write its backup RAM if it changed. 1 = done
static u8 save_back(void) {
  u8 i;
  char sn[8];
  u32 d;
  if (!(SPI_ST & 1)) return 1;
  d = get_note(4);
  if (d == 0xFFFFFFFFUL) { CLEAN = 0; return 1; }
  for (i = 0; i < 8; ++i) sn[i] = NOTE[8 + i];
  at(4, 10, "SAVING...");
  if (get_note(0) != fat_serial) { fat_err = E_SD; return 0; }
  if (!fat_save(d, sn)) return 0;
  CLEAN = 0;
  return 1;
}
static void load_sav(const entry_t *e) {    // backup RAM = its file, or formatted
  static const u8 hdr[8] = {'H', 'U', 'B', 'M', 0x00, 0x88, 0x10, 0x80};
  u16 i;
  for (i = 0; i < 2048; ++i) BRAM[i] = 0;
  for (i = 0; i < 8; ++i) BRAM[i] = hdr[i];
  // without a readable file, never write it back
  put_note(4, fat_load_sav(dir, e->sn) ? dir : 0xFFFFFFFFUL);
  put_note(0, fat_serial);
  for (i = 0; i < 8; ++i) NOTE[8 + i] = e->sn[i];
  CLEAN = 0;
}

// --- start of a game ------------------------------------------------------------
static void start(void) {
  u16 banks = (u16)((rom_size + 8191) >> 13), m = 1;
  u8 mode = 0;
  while (m < banks) m <<= 1;
  if (banks > 128) { mode = 2; m = 128; }    // Street Fighter II mapper
  else if (banks == 48) mode = 1;            // 384 KB
  else if (banks == 96) mode = 3;            // 768 KB
  ROMMODE = mode;
  MASK = (u8)(m - 1);
  RUN = 1;
  for (;;) ;
}

static u8 rep;
static void browse(void) {
  u8 redraw;
  entry_t *e;
  depth = 0; dir = 0; page = 0; sel = 0;
  for (;;) {
    if (!fat_list(dir, page)) return;
    page = list_page;
    if (sel >= list_len) sel = list_len ? list_len - 1 : 0;
    draw();
    redraw = 0;
    while (!redraw) {
      vblank();
      readpad();
      if (pad_now & 0x0F) {                    // auto repeat
        if (++rep >= 14) { rep = 11; pad_new |= pad_now & 0x0F; }
      } else rep = 0;
      if ((pad_new & DOWN) && list_len) {
        if (sel + 1 < list_len) move(sel + 1);
        else if (list_more) { ++page; sel = 0; redraw = 1; }
        else if (page) { page = 0; sel = 0; redraw = 1; }
        else move(0);
      } else if ((pad_new & UP) && list_len) {
        if (sel) move(sel - 1);
        else if (page) { --page; sel = LIST_N - 1; redraw = 1; }
        else move(list_len - 1);
      } else if ((pad_new & RIGHT) && list_more) { ++page; sel = 0; redraw = 1; }
      else if ((pad_new & LEFT) && page) { --page; sel = 0; redraw = 1; }
      else if ((pad_new & B_II) && depth) {
        --depth; dir = dir_stack[depth]; page = page_stack[depth]; sel = 0; redraw = 1;
      } else if ((pad_new & OPEN) && list_len) {
        e = &list[sel];
        redraw = 1;
        if (e->isdir) {
          if (e->name[0] == '.' && e->name[1] == '.') {
            if (depth) { --depth; dir = dir_stack[depth]; page = page_stack[depth]; }
          } else if (depth < 6) {
            dir_stack[depth] = dir; page_stack[depth] = page; ++depth;
            dir = e->cl; page = 0;
          }
          sel = 0;
        } else {
          cls();
          title();
          at(4, 10, e->name);
          at(4, 12, "LOADING");
          if (fat_load(e->cl, e->size)) { load_sav(e); start(); }
          fail();
          fat_err = 0;
        }
      }
    }
  }
}

// 1 = try again, 0 = give up
static u8 save_fail(void) {
  cls();
  title();
  at(4, 8, "GAME NOT SAVED");
  at(4, 10, msgs[fat_err]);
  at(4, 13, "I RETRY   II DISCARD");
  for (;;) {
    vblank();
    readpad();
    if (pad_new & B_I) { cls(); title(); return 1; }
    if (pad_new & B_II) { CLEAN = 0; return 0; }
  }
}

static void color(u16 n, u16 c) {            // c = GRB, 3 bits each
  VCE_AL = (u8)n; VCE_AH = (u8)(n >> 8);
  VCE_DL = (u8)c; VCE_DH = (u8)(c >> 8);
}

void main(void) {
  static const u16 regs[] = {6, 0, 7, 0, 8, 0, 9, 0, 10, 0x0202, 11, 0x041F, 12, 0x1702,
                             13, 0x00DF, 14, 0x000C, 15, 0, 5, 0x0008};
  u16 i;
  u8 j;
  const u8 *f = font;
  VCE_CR = 0;
  j = VST;
  for (j = 0; j < sizeof(regs) / sizeof(u16); j += 2) reg((u8)regs[j], regs[j + 1]);
  color(0, 0x002);                          // dark blue, white text
  color(1, 0x1FF);
  color(16, 0x002);
  color(17, 0x002);                         // highlight: dark text ...
  color(18, 0x1C7);                         // ... on cyan (plane 1)
  color(19, 0x002);
  color(256, 0x002);
  reg(0, 0x1000);                           // font: tiles $100.., plane 0; plane 1 = all ones
  VST = 2;
  for (i = 0; i < 128; ++i) {
    for (j = 0; j < 8; ++j) { VDL = *f++; VDH = 0xFF; }
    for (j = 0; j < 8; ++j) { VDL = 0; VDH = 0; }
  }
  color(2, 0x002);                          // palette 0: 2 = background, 3 = text
  color(3, 0x1FF);
  cls();
  title();
  reg(5, 0x0088);
  for (;;) {
    fat_err = E_SD;
    if (sd_init() && fat_mount()) {
      if (save_back()) browse();
      else if (save_fail()) continue;
      else browse();
    } else if ((SPI_ST & 1) && save_fail()) continue;
    fail();
  }
}
