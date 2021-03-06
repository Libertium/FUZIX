;
;	    NC100 hardware support
;

            .module nc100

            ; exported symbols
            .globl init_early
            .globl init_hardware
            .globl interrupt_handler
            .globl _program_vectors
	    .globl map_kernel
	    .globl map_process
	    .globl map_process_always
	    .globl map_save
	    .globl map_restore
	    .globl _kernel_flag

	    ; for the PCMCIA disc driver
	    .globl _rd_memcpy

	    ; video driver
	    .globl _scroll_up
	    .globl _scroll_down
	    .globl _plot_char
	    .globl _clear_lines
	    .globl _clear_across
	    .globl _cursor_on
	    .globl _cursor_off
	    .globl _cursorpos
	    ; need the font
	    .globl _font4x6
	    .globl _vtinit
	    .globl platform_interrupt_all
	    .globl _video_setpixel
	    .globl _video_cmd
	    .globl _video_attr
	    .globl _video_op

            ; exported debugging tools
            .globl _trap_monitor
            .globl outchar

            ; imported symbols
            .globl _ramsize
            .globl _procmem
            .globl _tty_inproc
            .globl unix_syscall_entry
            .globl trap_illegal
	    .globl nmi_handler
	    .globl null_handler

	     ; debug symbols
            .globl outcharhex
            .globl outhl, outde, outbc
            .globl outnewline
            .globl outstring
            .globl outstringhex

            .include "kernel.def"
            .include "../kernel.def"
	    .include "nc100.def"

; -----------------------------------------------------------------------------
; COMMON MEMORY BANK (0xF000 upwards)
; -----------------------------------------------------------------------------
            .area _COMMONMEM

_trap_monitor:
	    di
	    halt
	    jr _trap_monitor

_trap_reboot:
	    xor a
	    out (0x70), a

platform_interrupt_all:
            ret

; -----------------------------------------------------------------------------
; KERNEL MEMORY BANK (below 0xF000, only accessible when the kernel is mapped)
; -----------------------------------------------------------------------------
            .area _CODE

init_early:
            ret

init_hardware:
            ; set system RAM size
            ld hl, #256
            ld (_ramsize), hl
            ld hl, #(256-64)		; 64K for kernel
            ld (_procmem), hl

	    ; 100Hz timer on

            ; set up interrupt vectors for the kernel (also sets up common memory in page 0x000F which is unused)
            ld hl, #0
            push hl
            call _program_vectors
            pop hl

	    ld a, #0x08			; keyboard IRQ only
	    out (0x60), a		; set up
	    xor a
	    out (0x90), a
            im 1 ; set CPU interrupt mode
            in a, (0xB9)
	    call _vtinit		; init the console video
            ret


;------------------------------------------------------------------------------
; COMMON MEMORY PROCEDURES FOLLOW

            .area _COMMONMEM

_program_vectors:
	    ;
	    ; Note: we must install an NMI handler on the NC100 FIXME
	    ;

            ; we are called, with interrupts disabled, by both newproc() and crt0
	    ; will exit with interrupts off
            di ; just to be sure
            pop de ; temporarily store return address
            pop hl ; function argument -- base page number
            push hl ; put stack back as it was
            push de

	    ; At this point the common block has already been copied
	    call map_process

            ; write zeroes across all vectors
            ld hl, #0
            ld de, #1
            ld bc, #0x007f ; program first 0x80 bytes only
            ld (hl), #0x00
            ldir

            ; now install the interrupt vector at 0x0038
            ld a, #0xC3 ; JP instruction
            ld (0x0038), a
            ld hl, #interrupt_handler
            ld (0x0039), hl

            ; set restart vector for UZI system calls
            ld (0x0030), a   ;  (rst 30h is unix function call vector)
            ld hl, #unix_syscall_entry
            ld (0x0031), hl

            ld (0x0000), a   
            ld hl, #null_handler   ;   to Our Trap Handler
            ld (0x0001), hl

            ld (0x0066), a  ; Set vector for NMI
            ld hl, #nmi_handler
            ld (0x0067), hl
	    jr map_kernel

;
;	Userspace mapping pages 7+  kernel mapping pages 3-5, first common 6
;
;
;	All registers preserved
;
map_process_always:
	    push hl
	    push af
	    ld hl, #U_DATA__U_PAGE
	    call map_process_2
	    pop af
	    pop hl
	    ret
;
;	HL is the page table to use, A is eaten, HL is eaten
;
map_process:
	    ld a, h
	    or l
	    jr nz, map_process_2
;
;	Map in the kernel below the current common, all registers preserved
;
map_kernel:
	    push af
	    ; kernel is in banks 3/4/5, common starts at 6 but then gets
	    ; copied into each task
	    ld a, #0x83
	    out (0x10), a
	    inc a
	    out (0x11), a
	    inc a
	    out (0x12), a
	    pop af
            ret
map_process_2:
	    ld a, (hl)
	    out (0x10), a
	    inc hl
	    ld a, (hl)
	    out (0x11), a
	    inc hl
	    ld a, (hl)
	    out (0x12), a
            ret
;
;	Restore a saved mapping. We are guaranteed that we won't switch
;	common copy between save and restore. Preserve all registers
;
map_restore:
	    push hl
	    push af
	    ld hl,#map_savearea
	    call map_process_2
	    pop af
	    pop hl
	    ret
;
;	Save the current mapping.
;
map_save:
	    push hl
	    push af
	    ld hl, #map_savearea
	    in a, (0x10)
	    ld (hl), a
	    inc hl
	    in a, (0x11)
	    ld (hl), a
	    inc hl
	    in a, (0x12)
	    ld (hl), a
	    inc hl
	    in a, (0x13)
	    ld (hl), a
	    pop af
	    pop hl
	    ret

map_savearea:
	    .db 0,0,0,0

;
; has to live in common
;
_kernel_flag:
	   .db 1

; outchar: Wait for UART TX idle, then print the char in A
; destroys: AF
outchar:
	    push af
outcharw:
            in a, (0xC1)
	    bit 0, a
	    jr z, outcharw
	    pop af
	    out (0xC0), a
            ret

;
; Disk helper
;
_rd_memcpy:  push ix
	    ld ix, #0
	    add ix, sp
	    ; 4(ix) = is_read, 5(ix) = dptr page 6-7(ix) = dptr, 8-9(ix) = block
            ld l, 6(ix)
	    ld h, 7(ix)
	    ld c, 5(ix)
            ld e, 8(ix)
            ld d, 9(ix)
            ld a, h
            and #0x3F		; Remove bank bits from H
            or #0x80            ; Will be at 0x8000
            ld h, a		; HL is now ready
	    ; DE is the block, but we need to work out where that block
	    ; lives in terms of 16K chunks
	    sla e               ; e = e * 2 (will be 512 in a bit)
	    rl d		; this is OK we won't overflow on a 1MB device
            ld a, e		; save a copy
	    sla e
            rl d
	    sla e
            rl d		; D now holds the bank
            push af
            ld a, d
	    add #0x80
            di
            out (0x11), a	; 0x4000 is now the ramdisc bank
	    pop af
	    and #0x3F		; Mask bank
	    or #0x40		; bank is at 0x4000
	    ld d, a		; e = e * 256 (so now in byte terms)
            ld e, #0		; always aligned

	    ld a, c
            out (0x12), a	; bank 0x8000 is now the user/kernel buffer
	    bit 0, 4(ix)	; read or write ?
	    jr z, rd_write

	    ex de, hl
	    ;
	    ;	All mapped, and then its simple
	    ;
rd_write:   ld bc, #512
	    ldir
            call map_kernel	; map the kernel and return
	    ei
	    pop ix
            ret            

;
;	FIXME: should be safe to drop the di/ei on these
;
_scroll_up:
	    ld a, i
	    push af
	    di
	    in a, (0x11)
	    push af
	    ld a, #0x43		; main memory, bank 3 (video etc)
	    out (0x11), a
	    ld hl, #VIDEO_BASE + 384
	    ld de, #VIDEO_BASE
	    ld bc, #VIDEO_SIZE - 384 - 1
	    ldir
	    jr vtdone

_scroll_down:
	    ld a, i
	    push af
	    di
	    in a, (0x11)
	    push af
	    ld a, #0x43		; main memory, bank 3 (video etc)
	    out (0x11), a
	    ld hl, #VIDEO_BASE + 0xFFF
	    ld de, #VIDEO_BASE + 0xFFF - 384
	    ld bc, #VIDEO_SIZE - 384 - 1
	    lddr
vtdone:	    pop af
	    out (0x11), a
	    pop af
	    ret po
	    ei
	    ret

;
;	Turn a co-ordinate pair in DE into an address in DE and map the
; video. Return B = 1 if this is the right hand char of the pair
; preserves H, L, C
;
addr_de:
	    ld a, #0x43
	    out (0x11), a

	    ld a, d	; X
	    and #1
	    ld b, a	; save the low bit so we know how to write the char
	    ld a, e	; turn Y into a pixel row
	    add a
	    ld e, a
	    add a
            add e	; E * 6 to get E = pixel row
	    sla d	; we want 2bits shifted into d but only 1 lost
	    srl a	; multiple by 64 A into DE
	    rr  d	; roll two bits into D
	    srl a
	    rr  d
	    add #VIDEO_BASEH	; screen start (0x7000 or 0x6000 for NC200)
	    ld  e, d
	    ld  d, a
	    ret
;
;	We rely upon the font data ending up above 0x8000. On the current
; size that should never be a problem.
;
_plot_char:
	    pop hl
	    pop de	; d, e = co-ords
	    pop bc	; c = char
	    push bc
	    push de
	    push hl
	    ld a, i
	    push af
	    di
	    in a, (0x11)
	    push af
	    call addr_de
	    push de	; save while we sort the char out
	    ld  a, c
	    ld  h, #0
	    and #0x7f
	    ld l, a
	    add hl, hl  ; x 2
	    push hl
	    add hl, hl  ; x 4
	    pop de
	    add hl, de  ; x 6
	    ld de, #_font4x6
	    add hl, de  ; font base
	    pop de

noneg:	    ex de, hl
			; DE is the source, HL is the dest, B is the mask C
			; the char
	    bit 0, b	; What side are we doing ?
	    jr nz, right

	    ld b, #6
left:	    push bc
	    ld a, (de)
	    inc de
	    bit 7, c
	    jr nz, leftright
	    ; left left
	    and #0xf0
	    jr writeit
leftright:  and #0x0f
	    rlca
	    rlca
	    rlca
	    rlca
writeit:    ld b, a		; stash symbol bits

	    ld a, (hl)
	    and #0x0f		; wipe the left
	    or b		; add our symbol
	    ld (hl), a
	    push de		; bump HL on by 64
	    ld de, #64
	    add hl, de
	    pop de
	    pop bc		; recover count and char
	    djnz left
	    jr vtdone
right:
	    ld b, #6
rightloop:  push bc
	    ld a, (de)
	    inc de
	    bit 7, c
	    jr nz, rightright
	    ; right left
	    and #0xf0
	    rrca
	    rrca
	    rrca
	    rrca
	    jr writeitr
rightright: and #0x0f
writeitr:   ld b, a		; stash symbol bits

	    ld a, (hl)
	    and #0xf0		; wipe the right
	    or b		; add our symbol
	    ld (hl), a
	    push de		; bump HL on by 64
	    ld de, #64
	    add hl, de
	    pop de
	    pop bc		; recover count and char
	    djnz rightloop
	    jp vtdone

_clear_lines:
	    pop hl
	    pop de		; E = y, D = count
	    push de
	    push hl
	    ld a, i
	    push af
	    di
	    in a, (0x11)
	    push af
	    ld c, d
	    ld d, #0
	    call addr_de
	    ld a, c		; lines
	    or a
	    jp z, vtdone
lines:
	    ld h, d
	    ld l, e
	    ld (hl), #0x0
	    inc de
	    ld bc, #383
	    ldir
            dec a
	    jr nz, lines
	    jp vtdone

_clear_across:
	    pop hl
	    pop de		; E = y, D = x
	    pop bc		; C = count
	    push bc
	    push de
	    push hl
	    ld a, i
	    push af
	    di
	    in a, (0x11)
	    push af
	    call addr_de
	    ex de, hl
	    ld hl, #64
	    bit 0, b		; half char ?
	    jr z, nohalf
	    push hl
	    ld b, #6
halfwipe:
	    ld a, (hl)
	    and #0xF0
	    ld (hl), a
	    add hl, de
	    djnz halfwipe
	    pop hl
	    inc hl
	    dec c
nohalf:	    xor a
	    cp c
	    jp z, vtdone
	    ld a, #6
lwipe2:	    push hl
lwipe:	    ld b, c
	    ld (hl), #0
	    inc hl
	    djnz lwipe
	    pop hl
	    add hl, de
	    dec a
	    jr nz, lwipe2
	    jp vtdone
	
_cursor_on:
	    pop hl
	    pop de
	    push de
	    push hl
cursor_do:
	    ld a, i
	    push af
            di
	    in a, (0x11)
	    push af
	    ld (_cursorpos), de
	    call addr_de
	    ld c, #0xF0
	    bit 0, b
            jr z, cleft
	    ld c, #0x0f
cleft:	    ex de, hl
	    ld de, #64
	    ld b, #6
cursorlines:ld a, (hl)
	    xor c
	    ld (hl), a
	    add hl, de
	    djnz cursorlines
	    jp vtdone

_cursor_off:
	    ld de, (_cursorpos)
	    jr cursor_do

;
;	Entered with HL pointing to the co-ordinates
;	Returns with HL pointing to the byte address of the pixel
;	A holding the pixel mask
;	C holding the bit number
;	DE holding the screen byte address
;
coords:
	    ld a, (hl)		; low bits of X
	    and #7		; pixel
	    ld c, a
	    ld a, (hl)
	    ld de, #0		; clear D - and keep D at zero
	    rra
	    rra
	    rra			; A is the byte offset
	    inc hl
	    bit 0, (hl)
	    jr z, xonleft
	    set 5,a		; right hand side
xonleft:
	    inc hl
	    ld a, (hl)		; y low (no y high needed) 0-63 or 0-127 */
	    add a		; x 2
	    ld l, a
	    ld h, d		; zero
	    add hl, hl		; x 4
	    add hl, hl		; x 8
	    add hl, hl		; x 16
	    add hl, hl		; x 32
	    add hl, hl		; x 64	lines into bytes offset
	    add hl, de		; pixel in this byte
	    ex de, hl
	    ld hl, #setpixel_bittab
	    ld b, d		; zero
	    add hl, bc
	    ld a, (hl)		; our pixel mask
	    ex de, hl
	    ret

setpixel_optab:
	    nop				;
	    or (hl)			; COPY
	    nop
	    or (hl)			; SET
	    cpl				; complement pixel mask
	    and (hl)			; CLEAR by anding with mask
	    nop
	    xor (hl)			; INVERT
setpixel_bittab:
	    .db 128,64,32,16,8,4,2,1

_video_setpixel:
	    in a, (0x11)
	    push af
	    ld a, #0x43			; Map the display
	    out (0x11), a
	    call video_setpixel
	    pop af
	    out (0x11), a
	    ret

video_setpixel:
	    ld a, (_video_attr + 2)	; mode
	    or a			; copy ?
	    jr nz, setpixel_notdraw
	    ld a, (_video_attr)		; ink
	    or a			; white ?
	    jr nz, setpixel_notdraw	; a = 1 = set so good
	    ld a, #2			; clear
setpixel_notdraw:
	    ld e, a
	    ld d, #0
	    ld hl, #setpixel_optab
	    add hl, de
	    ld a, (hl)
	    ld (setpixel_opcode), a	; Self modifying
	    inc hl
	    ld a, (hl)
	    ld (setpixel_opcode+1), a	; Self modifying
	    ld bc, (_video_op)	; B is the count
	    ld a, b
	    and #0x1f		; max 31 pixels per op
	    ret z
	    push bc
	    ld hl, #_video_op + 2	; co-ordinate pairs
setpixel_loop:
	    push hl
	    call coords
setpixel_opcode:
	    nop			; nop or cpl
	    ld a, (hl)		; screen
	    ld (hl), a		; store back to display
	    pop hl
	    inc hl
	    inc hl
	    inc hl
	    inc hl
	    pop bc
	    djnz setpixel_loop
	    ret

;
;	Need different logic for NC200 ?
;
_video_cmd:
	    in a, (0x11)
	    push af
	    ld a, #0x43			; Map the display
	    out (0x11), a
	    call video_cmd
	    pop af
	    out (0x11), a
	    ret

video_cmd:
	    ld hl, #_video_op
	    ld e, (hl)		; offset
	    inc hl
	    ld a, (hl)
	    cp #0x10
	    ret nc		; over end
	    ld d, a
	    inc hl
	    ld a, (hl)		; count
	    cp #124		; 2 bytes offset, 2 bytes length, 124 data
	    ret nc
	    ld c, a
	    inc hl
	    ld a, (hl)
	    or a
	    ret nz		; too big
	    ld b, a
	    push hl
	    ld l, e
	    ld h, d
	    add hl, bc		; end offset
	    ld a, h
	    cp #0x10
	    jr c, cmd_over	; doesn't fit
	    ld hl, #VIDEO_BASE
	    add hl, de		; offset
	    ex de, hl
	    pop hl		; input buffer
	    ldir
	    ret
cmd_over:   pop hl
	    ret

;
;	Needed here so they don't vanish when we map the screen
;
_video_op:
	    .ds 128
_video_attr:
	    .ds 4
