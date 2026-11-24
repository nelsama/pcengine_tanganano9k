; startup of the menu: 16 KB, bank 0 at $E000 (MPR7), bank 1 at $C000 (MPR6)
.setcpu "huc6280"
.export _exit, __STARTUP__ : absolute = 1
.export _read512, _write512
.import _main, __STACKTOP__
.importzp c_sp, ptr1
.segment "STARTUP"
reset:
  sei
  csh
  cld
  lda #$FF
  tam #$01               ; I/O at $0000
  lda #$F8
  tam #$02               ; RAM at $2000
  lda #$01
  tam #$40               ; $C000
  lda #$F7
  tam #$08               ; backup RAM at $6000
  ldx #$FF
  txs
  lda #7
  sta $1402              ; no interrupts
  stz $0C01
  stz $2000
  tii $2000, $2001, $1FFF
  lda #<__STACKTOP__
  sta c_sp
  lda #>__STACKTOP__
  sta c_sp+1
  jsr _main
_exit:
  bra _exit
irq:
  rti
; void read512(u8 *p) : $180A = last SPI byte, and starts the next
_read512:
  sta ptr1
  stx ptr1+1
  lda $180A
  jsr @w
  ldx #2
  cly
@l:
  lda $180A
  sta (ptr1),y
  nop
  iny
  bne @l
  inc ptr1+1
  dex
  bne @l
  rts
@w:
  lda $1801
  bmi @w
  rts
; void write512(u8 *p) : the last byte is still on its way at the end
_write512:
  sta ptr1
  stx ptr1+1
  ldx #2
  cly
@m:
  lda (ptr1),y
  sta $1800
  nop
  iny
  bne @m
  inc ptr1+1
  dex
  bne @m
  rts
.segment "VECTORS"
  .word irq, irq, irq, irq, reset
