; savetest.s : backup RAM test HuCard. Border: green = the RAM holds the data of a
; previous run, blue = formatted and written now, red = no "HUBM" header.
.setcpu "huc6280"
.segment "CODE"
reset:
    sei
    csh
    cld
    lda #$FF
    tam #$01
    lda #$F8
    tam #$02
    lda #$F7
    tam #$04               ; backup RAM at $4000
    ldx #$FF
    txs
    lda #$80
    sta $1807              ; unlock
    ldx #$38               ; GRB: red
    ldy #$00
    lda $4000
    cmp #'H'
    bne show
    lda $4003
    cmp #'M'
    bne show
    ldx #$C0               ; green: $1C0
    ldy #$01
    lda $4010
    cmp #$5A
    beq show
    cly
wr: tya
    eor #$5A
    sta $4010,y
    iny
    bne wr
    lda $1803              ; lock: these writes must not arrive
    stz $4010
    ldx #$07               ; blue
    ldy #$00
show:
    stz $0402
    lda #1
    sta $0403
    stx $0404
    sty $0405
    bra *
none: rti
.segment "VEC"
    .word none, none, none, none, reset
