            .module vdp

	    ; video driver
	    .globl scroll_up
	    .globl scroll_down
	    .globl plot_char
	    .globl clear_lines
	    .globl clear_across
	    .globl cursor_on
	    .globl cursor_off
	    .globl cursorpos

	    .globl _vdpport

	    .globl vdpinit
	    .globl platform_interrupt_all

	    .area _CODE

;
;	FIXME: table.. and move into init RAM
;
vdpinit:    ld de, #0x8000		; M4 }
	    call vdpout 		;    }	40x25 mode
	    ld de, #0x81F0		; M1 }  screen on, virq on hirq off
					; F0 ????
	    call vdpout
	    ld de, #0x8200		; characters at VRAM 0
	    call vdpout
	    ld de, #0x8300		; blink is unused
	    call vdpout
	    ld de, #0x8400 + VRAM_CH	; font at 0x0800
	    call vdpout
	    ld de, #0x87F5		; white text on black
;	Fall through...
;
;	Register write value E to register A
;
vdpout:	    ld bc, (_vdpport)
	    out (c), e			; Write the data
	    out (c), d			; and then the register | 0x80
	    ret

;
;	FIXME: need to IRQ protect the pairs of writes
;


videopos:	; turn E=Y D=X into HL = addr
	        ; pass B = 0x40 if writing
	        ; preserves C
	    ld a, e			; 0-24 Y
	    add a, a
	    add a, a
	    add a, a			; x 8
	    ld l, a
	    ld h, #0
	    push hl
	    add hl, hl			; x 16
	    add hl, hl			; x 32
	    ld a, d
	    pop de
	    add hl, de			; x 40
	    ld e, a
	    ld d, b			; 0 for read 0x40 for write
	    add hl, de			; + X
	    ret
;
;	Eww.. wonder if VT should provide a hint that its the 'next char'
;
		.if VDP_DIRECT
_plot_char:
		.endif
plot_char:  pop hl
	    pop de			; D = x E = y
	    pop bc
	    push bc
	    push de
	    push hl
plotit:
	    ld b, #0x40			; writing
	    call videopos
	    ld a, c
plotit2:
	    ld bc, (_vdpport)
	    out (c), l			; address
	    out (c), h			; address | 0x40
	    dec c
	    out (c), a			; character
	    ret

;
;	FIXME: on the VDP9958 we can set R25 bit 6 and use the GPU
;	operations
;
;
;	Painful
;
	    .area	_DATA

scrollbuf:   .ds		40

	    .area	_CODE
;
;	We don't yet use attributes...
;
		.if VDP_DIRECT
_scroll_down:
		.endif
scroll_down:
	    ret
	    ld b, #23
	    ld de, #0x3C0	; start of bottom line
upline:
	    push bc
	    ld bc, (_vdpport)	; vdpport + 1 always holds #80
	    ld hl, #scrollbuf
	    out (c), e		; our position
	    out (c), d
	    dec c
	    inir		; safe on MSX2 but not MSX1? - FIXME 
	    inc c
	    ld hl, #0x4028	; go down one line and into write mode
	    add hl, de		; relative to our position
	    out (c), l
	    out (c), h
	    ld b, #0x28
	    ld hl, #scrollbuf
	    dec c
	    otir		; video ptr is to the line below so keep going
	    pop bc		; recover line counter
	    ld hl, #0xffd8
	    add hl, de		; up 40 bytes
	    ex de, hl		; and back into DE
	    djnz upline
	    ret

		.if VDP_DIRECT
_scroll_up:
		.endif
scroll_up:
	    ld b, #23
	    ld de, #40		; start of second line
downline:   push bc
	    ld bc, (_vdpport)
	    ld hl, #scrollbuf
	    out (c), e
	    out (c), d
	    dec c
	    inir		; MSX1 fixme ?
	    inc c
	    ld hl, #0x3FD8	; up 40 bytes in the low 12 bits, add 0x40
				; for write ( we will carry one into the top
				; nybble)
	    add hl, de
	    out (c), l
	    out (c), h
	    dec c
	    ld hl, #scrollbuf
	    ld b, #0x40
	    otir		; FIXME: is otir ok for MSX 1 ???
	    pop bc
	    ld hl, #40
	    add hl, de
	    ex de, hl
	    djnz downline
	    ret

		.if VDP_DIRECT
_clear_lines:
		.endif
clear_lines:
	    pop hl
	    pop de	; E = line, D = count
	    push de
	    push hl
	    ld c, d
	    ld d, #0
	    ld b, #0x40
	    call videopos
	    ld e, c
	    ld bc, (_vdpport)
	    out (c), l
	    out (c), h
				; Safe on MSX 2 to loop the data with IRQ on
				; but *not* on MSX 1
            ld a, #' '
	    dec c
l2:	    ld b, #40   	
l1:	    out (c), a		; Inner loop clears a line, outer counts
				; need 20 clocks between writes. DJNZ is 13,
				; out is 11
            djnz l1
	    dec e
	    jr nz, l2
	    ret

		.if VDP_DIRECT
_clear_across:
		.endif
clear_across:
	    pop hl
	    pop de	; DE = coords
	    pop bc	; C = count
	    push bc
	    push de
	    push hl
	    ld b, #0x40
	    call videopos
	    ld a, c
	    ld bc, (_vdpport)
	    out (c), l
	    out (c), h
	    ld b, a
            ld a, #' '
	    dec c
l3:	    out (c), a
            djnz l1
	    ret

;
;	FIXME: should use attribute blink flag not a char
;
		.if VDP_DIRECT
_cursor_on:
		.endif
cursor_on:
	    pop hl
	    pop de
	    push de
	    push hl
	    ld (cursorpos), de
	    ld b, #0x00			; reading
	    call videopos
	    ld a, c
	    ld bc, (_vdpport)
	    out (c), l			; address
	    out (c), h			; address
	    dec c
	    in a, (c)			; character
	    ld (cursorpeek), a		; save it away
	    set 6, h			; make it a write command
	    ld a, #'_'			; write the cursor
	    jp plotit2

		.if VDP_DIRECT
_cursor_off:
		.endif
cursor_off:
	    ld de, (cursorpos)
	    ld a, (cursorpeek)
	    ld c, a
	    call plotit
	    ret
;
;	This must be in data or common not code
;
	    .area _DATA
cursorpos:  .dw 0
cursorpeek: .db 0

