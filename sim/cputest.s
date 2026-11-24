; cputest.s : test ROM (64 KB) for cpu_sys; results go out through the PSG port:
; $0800 = test number, $0801 = value. Expected values are in tb_cpusys.vhd.
.setcpu "huc6280"
.segment "CODE"            ; bank 0 at $E000
reset:
    sei
    csh
    cld
    lda #$FF
    tam #$01               ; I/O at $0000
    lda #$F8
    tam #$02               ; RAM at $2000
    ldx #$FF
    txs
    lda #7
    sta $1402
; 1: 16-bit sum of banks 1..7 (cold data reads), through MPR2 ($4000)
    stz $10
    stz $11
    lda #1
    sta $12
bank:
    lda $12
    tam #$04
    stz $14
    lda #$40
    sta $15
    ldy #0
sum: clc
    lda ($14),y
    adc $10
    sta $10
    bcc nc
    inc $11
nc: iny
    bne sum
    inc $15
    bbr5 $15, sum          ; until $6000
    inc $12
    lda $12
    cmp #8
    bne bank
    lda #1
    sta $0800
    lda $10
    sta $0801
    lda $11
    sta $0801
; 2: block copy ROM -> RAM, run it there
    tii ramcode, $2300, ramend-ramcode
    jsr $2300
    lda #2
    sta $0800
    stx $0801
; 3: ROM -> VDC port with TIA (the VDC penalty makes it slower)
    lda #1
    tam #$04
    st0 #$55
    tia $4000, $0002, 256
; 4: timer: count interrupts of 1024 cycles while looping
    stz $20
    lda #3
    sta $1402              ; only the timer
    stz $0C00              ; reload 0
    lda #1
    sta $0C01
    cli
    ldx #0
    ldy #0
w:  dex                    ; 256 * 16 iterations of 6 cycles = 24576 cycles
    bne w
    iny
    cpy #16
    bne w
    sei
    stz $0C01
    lda #4
    sta $0800
    lda $20
    sta $0801
; 5: cold code: 4 KB of NOP in bank 2, run twice (second time conflicts too)
    lda #2
    tam #$08               ; $6000
    lda #5
    sta $0800
    lda #1
    sta $0801              ; start mark
    jsr $6000
    lda #2
    sta $0801              ; end mark
    jsr $6000
    lda #3
    sta $0801
    lda #6
    sta $0800
    lda #$0D
    sta $0801              ; done
stop: bra stop

ramcode:
    ldx #0
:   inx
    cpx #77
    bne :-
    rts
ramend:

timer_irq:
    inc $20
    stz $1403
    rti
none:
    rti
.segment "VEC"
    .word none, none, timer_irq, none, reset
