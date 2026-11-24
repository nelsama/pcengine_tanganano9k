#ifndef FAT_H
#define FAT_H
#ifdef HOST
#include <stdint.h>
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32;
#else
typedef unsigned char u8; typedef unsigned int u16; typedef unsigned long u32;
#endif
#define LIST_N 16
#define NAME_N 28
enum { E_OK, E_SD, E_READ, E_FAT, E_SIZE, E_FULL, E_DIR };
typedef struct { u32 cl, size; u8 isdir; char sn[8]; char name[NAME_N]; } entry_t;
#ifdef HOST
extern u8 buf[512];
extern entry_t list[LIST_N];
#else
extern u8 buf[512];
extern entry_t list[LIST_N];
#endif
extern u16 list_page;
extern u8 fat_err, list_len, list_more;
extern u8 rom_flip;                   // bytes of the file have their bits reversed
extern u32 rom_size;                  // without the 512 byte header
u8 fat_mount(void);
u8 fat_list(u32 dir, u16 page);       // dir 0 = root; list_page = page shown
u8 fat_load(u32 cl, u32 size);
// save files: <short name of the game>.SAV, next to the game; 2 KB
#define SAV_SECTORS 4
extern u32 fat_serial;                // volume serial number
u8 fat_load_sav(u32 dir, const char *sn);   // to the backup RAM; 1 = ok or no file
u8 fat_save(u32 dir, const char *sn);       // overwrites or creates the file
// provided by the platform
u8 sd_write(u32 lba);                 // buf -> sector
void bram_read(u8 k);                 // backup RAM, 512 k.. -> buf
void bram_write(u8 k);                // buf -> backup RAM
u8 sd_read(u32 lba);                  // sector -> buf
u8 sd_dma(u32 lba, u8 die, u32 addr); // sector -> PSRAM
void progress(u16 k, u16 total);
#endif
