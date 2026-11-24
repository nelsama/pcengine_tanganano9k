; vdctest.s : graphics test HuCard (8 KB). Scrolling background with a raster
; split, 20 sprites of all sizes and flips, VRAM read back, VRAM DMA, SATB DMA.
; Pad: left / right = scroll speed, button I = 256 / 336 / 512 dots.
; PSG port $0801 = frame counter (for the test bench); $0802 = 1 if the VRAM
; read back failed (the border is red then).
.setcpu "huc6280"
.zeropage
frame:  .res 1
scroll: .res 2
speed:  .res 1
pad:    .res 1
old:    .res 1
mode:   .res 1
tmp:    .res 2
cnt:    .res 1
bad:    .res 1
half:   .res 1
.segment "CODE"
.macro vreg n, v
    st0 #n
    st1 #<(v)
    st2 #>(v)
.endmacro
reset:
    sei
    csh
    cld
    lda #$FF
    tam #$01
    lda #$F8
    tam #$02
    ldx #$FF
    txs
    lda #7
    sta $1402
    stz $2000
    tii $2000, $2001, $1FFF
    lda a:$0000              ; clear the VDC flags
    vreg 5, $0000
    vreg 9, $0010          ; map 64 x 32
    vreg 6, 0
    vreg 7, 0
    vreg 8, 0
    stz mode
    jsr setmode

; palette: background palette p colour c = grb from p and c
    stz $0402
    stz $0403
    ldy #0                 ; 256 entries of background, then 256 of sprites
pal0:
    tya
    and #$0F
    asl a
    asl a
    asl a
    asl a                  ; colour in G and R
    sta tmp
    tya
    lsr a
    lsr a
    lsr a
    lsr a
    ora tmp
    sta $0404
    tya
    lsr a
    lsr a
    lsr a
    and #1
    sta $0405
    iny
    bne pal0
pal1:
    tya
    eor #$FF
    sta $0404
    tya
    and #1
    sta $0405
    iny
    bne pal1
    stz $0402              ; backdrop: dark blue
    stz $0403
    lda #$02
    sta $0404
    stz $0405
    stz $0402              ; border: grey
    lda #1
    sta $0403
    lda #$92
    sta $0404
    stz $0405

; BAT: tile = $100 + (x + y) and 15, palette = y / 2
    vreg 0, $0000
    st0 #2
    ldy #0
bat: ldx #0
batx:
    sxy
    stx tmp                ; tmp = row (x and y exchanged)
    tya
    sxy
    clc
    adc tmp
    and #15
    sta a:$0002
    tya
    lsr a
    asl a
    asl a
    asl a
    asl a
    ora #1
    sta a:$0003
    inx
    cpx #64
    bne batx
    iny
    cpy #32
    bne bat

; tiles $100..$10F at VRAM $1000: 16 words each, plane patterns from the index
    vreg 0, $1000
    st0 #2
    ldx #0                 ; tile
til: ldy #0
til1: tya                  ; planes 0 / 1
    and #7
    phx
    tax
    lda shape,x
    plx
    sta a:$0002
    txa
    and #4
    beq :+
    lda #$FF
:   sta a:$0003
    iny
    cpy #8
    bne til1
til2: tya                  ; planes 2 / 3
    and #7
    phx
    tax
    lda shape2,x
    plx
    sta a:$0002
    txa
    and #8
    beq :+
    lda #$0F
:   sta a:$0003
    iny
    cpy #16
    bne til2
    inx
    cpx #16
    bne til

; sprite cells at VRAM $2000 (pattern $100): 8 cells, 64 words each
    vreg 0, $2000
    st0 #2
    stz tmp
spr: ldy #0
spr1: tya
    and #15
    asl a
    tax
    lda ball,x
    sta a:$0002
    lda ball+1,x
    sta a:$0003
    iny
    cpy #16
    bne spr1
spr2: tya                  ; plane 1: diagonal, shows the flips
    and #15
    asl a
    tax
    lda diag,x
    sta a:$0002
    lda diag+1,x
    sta a:$0003
    iny
    cpy #32
    bne spr2
    ldx #16                ; planes 2 and 3 from the cell number
spr3: lda tmp
    and #1
    beq :+
    lda #$F0
:   sta a:$0002
    stz a:$0003
    dex
    bne spr3
    ldx #16
spr4: lda tmp
    and #2
    beq :+
    lda #$0F
:   stz a:$0002
    sta a:$0003
    dex
    bne spr4
    inc tmp
    lda tmp
    cmp #8
    bne spr

; read back: the first 256 words of the BAT
    vreg 1, $0000
    st0 #2
    ldy #0
    stz tmp
    stz bad
rb: tya
    and #63
    sta cnt
    tya
    asl a
    rol tmp                ; not used further: row = y / 64 (0..3)
    tya
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    lsr a
    sta tmp
    clc
    adc cnt
    and #15
    cmp a:$0002
    beq :+
    inc bad
:   lda tmp
    lsr a
    asl a
    asl a
    asl a
    asl a
    ora #1
    cmp a:$0003
    beq :+
    inc bad
:   iny
    bne rb
; VRAM DMA: copy tiles $100-$10F to $110; then the BAT's last row uses them
    vreg 15, $0000
    vreg 16, $1000
    vreg 17, $1100
    vreg 18, 255
dm: lda a:$0000              ; no flag enabled: just wait with a loop
    ldx #0
dml: dex
    bne dml
    ldy cnt
    inc cnt
    lda cnt
    cmp #90
    bne dm
    vreg 1, $1180          ; tile 8 of the copy: word 0 = shape[0] and (8 and 4)
    st0 #2
    lda a:$0002
    cmp shape
    beq :+
    inc bad
:   lda a:$0003
    cmp #0
    beq :+
    inc bad
:   lda bad
    sta $0802
    beq ok
    stz $0402
    lda #1
    sta $0403
    lda #$38               ; red border
    sta $0404
    stz $0405
ok:
    vreg 0, $0780          ; row 30: tiles of the copy
    st0 #2
    ldx #64
:   txa
    and #15
    ora #$10
    sta a:$0002
    lda #$31
    sta a:$0003
    dex
    bne :-

    vreg 19, $7F00         ; SATB address
    vreg 15, $0010         ; repeat
    lda #1
    sta speed
    vreg 5, $00CC          ; BG, sprites, vblank, raster
    lda #5                 ; IRQ1 only
    sta $1402
    lda a:$0000
    cli

main:
    lda frame
:   cmp frame
    beq :-
    jsr sprites
    jsr joypad
    lda frame
    sta $0801
    bra main

; SATB of 20 sprites in VRAM $7F00 (the rest has Y = 0: not shown)
sprites:
    vreg 0, $7F00
    st0 #2
    ldx #0
sp1: txa                   ; Y = 64 + 20 + (x * 9) + (frame & 31)
    asl a
    asl a
    asl a
    sta tmp
    txa
    clc
    adc tmp
    sta tmp
    lda frame
    and #31
    clc
    adc tmp
    stz tmp+1
    adc #84
    bcc :+
    inc tmp+1
:   sta a:$0002
    lda tmp+1
    sta a:$0003
    txa                    ; X = 32 + (x * 13) + frame
    asl a
    asl a
    sta tmp
    asl a
    clc
    adc tmp
    sta tmp
    txa
    clc
    adc tmp
    clc
    adc frame
    sta a:$0002
    lda #0
    adc #0
    and #1
    sta a:$0003
    lda #$00               ; cell $80 -> value $100
    sta a:$0002
    lda #$01
    sta a:$0003
    txa                    ; palette, priority
    and #15
    ora #$80
    cpx #3
    bne :+
    and #$7F               ; sprite 3 goes behind the background
:   sta a:$0002
    lda attr,x
    sta a:$0003
    inx
    cpx #20
    bne sp1
    rts

joypad:
    lda #1                 ; SEL = 1: directions, CLR pulse
    sta $1000
    lda #3
    sta $1000
    lda #1
    sta $1000
    nop
    nop
    lda $1000              ; left down right up (3..0)
    and #15
    sta tmp
    stz $1000
    nop
    nop
    lda $1000              ; run sel II I
    and #15
    sta pad
    bbs3 tmp, :+           ; left
    inc speed
:   bbs1 tmp, :+           ; right
    dec speed
:   lda pad
    tax
    eor old
    and #1
    beq :+                 ; I changed
    bbs0 pad, :+
    inc mode
    lda mode
    cmp #3
    bne np
    stz mode
np: jsr setmode
:   stx old
    rts

setmode:
    lda mode
    beq m0
    cmp #1
    beq m1
    lda #2                 ; 512
    sta $0400
    vreg 10, $0B02
    vreg 11, $043F
    bra mv
m1: lda #1                 ; 336
    sta $0400
    vreg 10, $0303
    vreg 11, $0629
    bra mv
m0: lda #0
    sta $0400
    vreg 10, $0202
    vreg 11, $041F
mv: vreg 12, $1702         ; 224 lines
    vreg 13, $00DF
    vreg 14, $000C
    rts

vdcirq:
    pha
    lda a:$0000
    sta half
    bbr2 half, novr        ; raster: lower half scrolls the other way
    st0 #7
    lda scroll
    eor #$FF
    sta a:$0002
    st2 #0
novr:
    bbr5 half, novb
    inc frame
    lda scroll
    clc
    adc speed
    sta scroll
    st0 #7
    sta a:$0002
    st2 #0
    st0 #8
    lda frame
    lsr a
    sta a:$0002
    st2 #0
    vreg 6, 64+112
novb:
    st0 #2
    pla
    rti
none: rti

shape:  .byte $FF,$81,$BD,$A5,$A5,$BD,$81,$FF
shape2: .byte $00,$7E,$42,$5A,$5A,$42,$7E,$00
ball:   .word $07E0,$1FF8,$3FFC,$7FFE,$7FFE,$FFFF,$FFFF,$FFFF
        .word $FFFF,$FFFF,$FFFF,$7FFE,$7FFE,$3FFC,$1FF8,$07E0
diag:   .word $8000,$C000,$E000,$F000,$F800,$FC00,$FE00,$FF00
        .word $0000,$0000,$0000,$0000,$00F0,$00F0,$0000,$0000
attr:   .byte $00,$01,$10,$11,$30,$31,$08,$80,$09,$81
        .byte $18,$90,$38,$B0,$39,$B1,$88,$19,$99,$B9
.segment "VEC"
    .word none, vdcirq, none, none, reset
