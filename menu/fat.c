// fat.c : FAT32: directories, HuCard (.pce) loader and save files of the menu. Also built with gcc for
// the host test (HOST).
#include "fat.h"

u8 buf[512];
entry_t list[LIST_N];
u8 fat_err;
static u32 buf_lba;
// where each page of the current directory starts
typedef struct { u32 cl; u8 sec, off; } page_t;
#define PAGES 360
static page_t pages[PAGES];
static u32 pg_dir;
static u16 pg_known;
u16 list_page;
static u32 fat_lba, data_lba, root_cl, part_lba, fat_len, max_cl;
static u16 fsinfo;
static u8 spc, nfats, mirror;
u32 fat_serial;

#ifdef HOST
static u16 rd16(u16 o) { return buf[o] | (buf[o + 1] << 8); }
static u32 rd32(u16 o) { return rd16(o) | ((u32)rd16(o + 2) << 16); }
#else
#define rd16(o) (*(u16 *)(buf + (o)))
#define rd32(o) (*(u32 *)(buf + (o)))
#endif

static u8 sector(u32 lba) {
  if (buf_lba == lba) return 1;
  buf_lba = 0xFFFFFFFFUL;
  if (!sd_read(lba)) { fat_err = E_READ; return 0; }
  buf_lba = lba;
  return 1;
}

static u8 is_fat32(void) {
  return buf[510] == 0x55 && buf[511] == 0xAA && rd16(11) == 512 &&
         rd16(17) == 0 && rd16(22) == 0 && rd32(36) != 0 && buf[13] != 0;
}

u8 fat_mount(void) {
  buf_lba = 0xFFFFFFFFUL;
  pg_known = 0;
  fat_err = E_FAT;
  part_lba = 0;
  if (!sector(0)) return 0;
  if (!is_fat32()) {
    part_lba = rd32(454);            // first MBR partition
    if (part_lba == 0 || !sector(part_lba)) return 0;
    if (!is_fat32()) return 0;
  }
  spc = buf[13];
  fat_lba = part_lba + rd16(14);
  nfats = buf[16];
  fat_len = rd32(36);
  data_lba = fat_lba + fat_len * nfats;
  root_cl = rd32(44);
  fsinfo = rd16(48);
  mirror = !(buf[40] & 0x80);
  fat_serial = rd32(67);
  // clusters 2 .. max_cl - 1, as many as the volume and the FAT hold
  max_cl = (rd32(32) - (data_lba - part_lba)) / spc + 2;
  if (max_cl > (fat_len << 7)) max_cl = fat_len << 7;
  fat_err = 0;
  return 1;
}

static u32 next_cluster(u32 cl) {
  if (!sector(fat_lba + (cl >> 7))) return 0;
  cl = rd32(((u16)cl & 127) << 2) & 0x0FFFFFFFUL;
  if (cl < 2 || cl >= 0x0FFFFFF7UL) return 0;
  return cl;
}

// --- sequential reader ------------------------------------------------------
static u32 cur_cl, cur_lba;
static u8 cur_sec;
static void seek0(u32 cl) {
  cur_cl = cl ? cl : root_cl;
  cur_sec = 0;
  cur_lba = data_lba + (cur_cl - 2) * spc;
}
static u8 advance(void) {
  if (++cur_sec == spc) {
    cur_cl = next_cluster(cur_cl);
    if (!cur_cl) return 0;
    seek0(cur_cl);
  } else ++cur_lba;
  return 1;
}

// --- directory ----------------------------------------------------------------
u8 list_len, list_more;
static char lfn[NAME_N];
static u8 lfn_ok;
static const u8 lfn_pos[13] = {1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30};


// shows page `page` (or the last one if there are fewer)
u8 fat_list(u32 dir, u16 page) {
  u16 o, pg;
  u8 i, j, n, c, attr, isdir, *p;
  entry_t *e;
  page_t *q;
  if (page >= PAGES - 1) page = PAGES - 2;
  if (!pg_known || pg_dir != dir) {
    seek0(dir);
    pg_dir = dir;
    pg_known = 1;
    pages[0].cl = cur_cl; pages[0].sec = 0; pages[0].off = 0;
  }
restart:
  list_len = 0;
  list_more = 0;
  lfn_ok = 0;
  pg = page < pg_known ? page : pg_known - 1;
  q = &pages[pg];
  seek0(q->cl);
  cur_sec = q->sec;
  cur_lba += cur_sec;
  o = (u16)q->off << 5;
  n = 0;                                     // entries found in page pg
  for (;;) {
    if (!sector(cur_lba)) return 0;
    for (; o < 512; o += 32) {
      p = buf + o;
      if (p[0] == 0) goto end;
      if (p[0] == 0xE5) { lfn_ok = 0; continue; }
      attr = p[11];
      if ((attr & 0x3F) == 0x0F) {
        if (pg != page) continue;            // only skipping
        if (p[0] & 0x40) {
          for (i = 0; i < NAME_N; ++i) lfn[i] = 0;
          lfn_ok = 1;
        }
        j = ((p[0] & 0x1F) - 1) * 13;
        for (i = 0; i < 13; ++i, ++j) {
          if (j >= NAME_N - 1) break;
          c = p[lfn_pos[i]];
          if (p[lfn_pos[i] + 1]) c = (c == 0xFF) ? 0 : '?';
          lfn[j] = (c < 128) ? c : '?';
        }
        continue;
      }
      isdir = (attr & 0x10) != 0;
      // hidden, system, volume label, "." (".." is kept)
      if ((attr & 0x0E) || (p[0] == '.' && p[1] != '.') ||
          (!isdir && (p[8] != 'P' || p[9] != 'C' || p[10] != 'E'))) { lfn_ok = 0; continue; }
      if (n == LIST_N) {                     // first entry of the next page
        if (pg == page) { list_more = 1; list_page = pg; return 1; }
        ++pg;
        n = 0;
        if (pg == page) goto restart;        // go back for its long name
      }
      ++n;
      if (n == LIST_N && pg + 1 == pg_known) {
        q = &pages[pg_known];
        ++pg_known;
        q->cl = cur_cl; q->sec = cur_sec; q->off = (u8)(o >> 5) + 1;
      }
      if (pg != page) continue;
      e = &list[list_len];
      ++list_len;
      e->isdir = isdir;
      for (i = 0; i < 8; ++i) e->sn[i] = p[i];
      e->cl = ((u32)rd16(o + 20) << 16) | rd16(o + 26);
      e->size = ((u32)rd16(o + 30) << 16) | rd16(o + 28);
      if (lfn_ok) {
        for (i = 0; i < NAME_N; ++i) e->name[i] = lfn[i];
      } else {
        j = 0;
        for (i = 0; i < 11; ++i) {
          c = p[i];
          if (i == 8 && c != ' ') e->name[j++] = '.';
          if (c != ' ') e->name[j++] = c < 128 ? c : '?';
        }
        while (j < NAME_N) e->name[j++] = 0;
      }
      lfn_ok = 0;
    }
    if (!advance()) { if (fat_err) return 0; break; }
    o = 0;
  }
end:
  if (pg != page || (n == 0 && pg)) {        // past the end: show the last page
    page = n ? pg : pg - 1;
    goto restart;
  }
  list_page = pg;
  return 1;
}

#ifdef HOST
void pg_test(void) { pg_known = 0; }         // forget the page table
#endif

// --- loader -----------------------------------------------------------------
u32 rom_size;
u8 rom_flip;

// loads the file to PSRAM die 0; returns 1 when the game can be started
u8 fat_load(u32 cl, u32 size) {
  u16 k, total;
  u32 addr = 0;
  u8 skip = ((u16)size & 0x3FF) == 512;        // copier header
  fat_err = E_SIZE;
  rom_size = skip ? size - 512 : size;
  if (!cl || rom_size < 8192 || rom_size > 0x280000UL) return 0;
  fat_err = 0;
  // the high byte of the reset vector (offset $1FFF) is $E0-$FF unless the
  // bits are reversed (TurboGrafx-16 dumps)
  seek0(cl);
  for (k = skip ? 16 : 15; k; --k) if (!advance()) goto eof;
  if (!sector(cur_lba)) return 0;
  rom_flip = buf[511] < 0xE0;
  seek0(cl);
  total = (u16)((rom_size + 511) >> 9);
  if (skip && !advance()) goto eof;
  for (k = 0; ; ) {
    if (!sd_dma(cur_lba, 0, addr)) { fat_err = E_READ; return 0; }
    addr += 512;
    if (!(k & 15)) progress(k, total);
    if (++k == total) return 1;
    if (!advance()) goto eof;
  }
eof:
  if (!fat_err) fat_err = E_SIZE;
  return 0;
}

// --- save files -----------------------------------------------------------------
static u32 fnd_cl, fnd_size;               // the file found, or
static u32 slot_lba;                       // a free directory entry (0 = none)
static u16 slot_off;

// 1 = found, 0 = not found (or fat_err)
static u8 find_sav(u32 dir, const char *sn) {
  u16 o;
  u8 i, *p;
  fat_err = 0;
  slot_lba = 0;
  seek0(dir);
  for (;;) {
    if (!sector(cur_lba)) return 0;
    for (o = 0; o < 512; o += 32) {
      p = buf + o;
      if (p[0] == 0 || p[0] == 0xE5) {
        if (!slot_lba) { slot_lba = cur_lba; slot_off = o; }
        if (p[0] == 0) return 0;
        continue;
      }
      if (p[11] & 0x18) continue;          // long name, label, directory
      for (i = 0; i < 8 && p[i] == (u8)sn[i]; ++i) ;
      if (i < 8 || p[8] != 'S' || p[9] != 'A' || p[10] != 'V') continue;
      fnd_cl = ((u32)rd16(o + 20) << 16) | rd16(o + 26);
      fnd_size = ((u32)rd16(o + 30) << 16) | rd16(o + 28);
      return 1;
    }
    if (!advance()) return 0;
  }
}

static u8 sav_sectors(void) {
  if (fnd_cl < 2) return 0;
  if (fnd_size >= SAV_SECTORS * 512UL) return SAV_SECTORS;
  return (u8)(fnd_size >> 9);
}

u8 fat_load_sav(u32 dir, const char *sn) {
  u8 k, n;
  if (!find_sav(dir, sn)) return !fat_err;
  n = sav_sectors();
  if (!n) return 1;
  seek0(fnd_cl);
  for (k = 0; ; ) {
    if (!sector(cur_lba)) return 0;
    bram_write(k);
    if (++k == n) return 1;
    if (!advance()) return !fat_err;
  }
}

static u8 wr_buf(u32 lba) {
  buf_lba = 0xFFFFFFFFUL;
  if (!sd_write(lba)) { fat_err = E_READ; return 0; }
  return 1;
}

static void put32(u16 o, u32 v) {
  buf[o] = (u8)v; buf[o + 1] = (u8)(v >> 8); buf[o + 2] = (u8)(v >> 16); buf[o + 3] = (u8)(v >> 24);
}

static u32 newcl[SAV_SECTORS];

// cluster chain newcl[0..n-1], written from its end
static u8 write_chain(u8 n) {
  u8 i, f;
  u16 o;
  u32 s, v;
  i = n;
  while (i) {
    s = newcl[i - 1] >> 7;
    if (!sector(fat_lba + s)) return 0;
    while (i && (newcl[i - 1] >> 7) == s) {
      --i;
      o = ((u16)newcl[i] & 127) << 2;
      if (rd32(o) & 0x0FFFFFFFUL) { fat_err = E_FULL; return 0; }  // not free?!
      v = i + 1 < n ? newcl[i + 1] : 0x0FFFFFFFUL;
      put32(o, v | (rd32(o) & 0xF0000000UL));
    }
    for (f = 0; f < nfats; ++f) if (!wr_buf(fat_lba + fat_len * f + s)) return 0;
  }
  return 1;
}

static u8 find_free(u8 n) {
  u32 cl, left;
  u8 k = 0;
  cl = 2;
  if (fsinfo && sector(part_lba + fsinfo) && rd32(0) == 0x41615252UL && rd32(484) == 0x61417272UL) {
    cl = rd32(492);
    if (cl < 2 || cl >= max_cl) cl = 2;
  }
  for (left = max_cl - 2; left; --left) {
    if (!sector(fat_lba + (cl >> 7))) return 0;
    if ((rd32(((u16)cl & 127) << 2) & 0x0FFFFFFFUL) == 0) {
      newcl[k] = cl;
      if (++k == n) return 1;
    }
    if (++cl == max_cl) cl = 2;
  }
  fat_err = E_FULL;
  return 0;
}

u8 fat_save(u32 dir, const char *sn) {
  u8 k, n, i;
  u16 o;
  if (find_sav(dir, sn)) {
    n = sav_sectors();
    if (!n) { fat_err = E_SIZE; return 0; }
    seek0(fnd_cl);
    for (k = 0; ; ) {
      bram_read(k);
      if (!wr_buf(cur_lba)) return 0;
      if (++k == n) return 1;
      if (!advance()) { if (!fat_err) fat_err = E_SIZE; return 0; }
    }
  }
  if (fat_err) return 0;
  if (!slot_lba || !mirror) { fat_err = E_DIR; return 0; }
  n = spc >= SAV_SECTORS ? 1 : SAV_SECTORS / spc;
  if (!find_free(n)) return 0;
  // data, FAT, directory entry: a power cut only loses free clusters
  for (k = 0; k < SAV_SECTORS; ++k) {
    bram_read(k);
    i = k / spc;
    if (!wr_buf(data_lba + (newcl[i] - 2) * spc + (u8)(k - i * spc))) return 0;
  }
  if (!write_chain(n)) return 0;
  if (fsinfo && sector(part_lba + fsinfo) && rd32(0) == 0x41615252UL && rd32(484) == 0x61417272UL) {
    put32(488, 0xFFFFFFFFUL);              // free count: unknown
    if (!wr_buf(part_lba + fsinfo)) return 0;
  }
  if (!sector(slot_lba)) return 0;
  o = slot_off;
  if (buf[o] == 0 && o < 480) buf[o + 32] = 0;
  for (i = 0; i < 32; ++i) buf[o + i] = 0;
  for (i = 0; i < 8; ++i) buf[o + i] = sn[i];
  buf[o + 8] = 'S'; buf[o + 9] = 'A'; buf[o + 10] = 'V';
  buf[o + 11] = 0x20;
  buf[o + 16] = buf[o + 18] = buf[o + 24] = 0x21; // 1980-01-01
  buf[o + 20] = (u8)(newcl[0] >> 16); buf[o + 21] = (u8)(newcl[0] >> 24);
  buf[o + 26] = (u8)newcl[0]; buf[o + 27] = (u8)(newcl[0] >> 8);
  put32(o + 28, SAV_SECTORS * 512UL);
  return wr_buf(slot_lba);
}
