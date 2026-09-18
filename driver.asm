;-----------------------------------------------------------------------------
;
; SDMapper V1 disk driver for Nextor 3
;
; Nextor 3 driver for SDMapper V1.
; Query interface follows the Nextor 3.0 Driver Development Guide
;
; Hardware I/O based on the Nextor 2 SD Mapper/Megaram driver
; by Fabio Belavenuto and FRS:
;   https://github.com/fbelavenuto/msxsdmapper
;
; Target hardware: SDMapper V1 (ASCII16 MegaROM, two SD slots).
; Work area: none in page 3 (WORK_AREA_SIZE = 0). Per-slot state lives in
; SLTWRK only. ROM disk is not implemented (the cartridge has no usable
; non-volatile storage for it).
;
; Technical info (SDMapper V1):
;   4000h~47FFh : SPI data transfer window (read/write)
;   4800h       : Interface status and card select register (read/write)
;     b0 : 0 = SD card present on slot 0
;     b1 : 0 = SD card present on slot 1
;     b2 : write-protect for slot 0 (1 = protected, as used by the original driver)
;     b3 : write-protect for slot 1 (1 = protected)
;     b4 : SW0. 0 = RAM disabled, 1 = RAM enabled (original driver polarity)
;     b5 : SW1. 0 = MegaRAM, 1 = Memory Mapper
;     b6 : reserved (mask out)
;     b7 : 1 = SPI transfer busy
;     Write b0 : slot 0 chip-select (0 = selected)
;     Write b1 : slot 1 chip-select (0 = selected)
;   6000h       : ASCII16 bank select (Nextor kernel)
;   6001h       : Mode configuration register (write only)
;     b0 : 0 = ROM mode (SPI disabled), 1 = SPI enabled
;   SPI shifter clock: on-cartridge 25 MHz (16 clocks/byte, 640 ns).
;
; Code that runs with SPI enabled must live at 4900h+; 4000h~48FFh become
; the SPI window while SPI is on.
;-----------------------------------------------------------------------------

	.RELAB

;---------------------------------------------------------------------------
; MACROS
;---------------------------------------------------------------------------

; Extra T-states between back-to-back SPI window accesses.
; The shifter runs from the cartridge's 25 MHz clock (16 clocks/byte,
; 640 ns). Consecutive ld a,(PORTSPI) is 14 T, about 3.9 us at 3.58 MHz,
; which already covers one byte, so SPI_GAP_NOPS is 0.
; The macro remains the single knob. Expansion of 0..3 bytes (nops, or a
; CALL if a wait is ever required) keeps jr spans that cross these gaps
; inside -128..+127.
SPI_GAP_NOPS	equ	0

SPI_GAP	macro
	REPT	SPI_GAP_NOPS
	nop
	ENDM
	ENDM

;-----------------------------------------------------------------------------
; Constants
;-----------------------------------------------------------------------------

WORK_AREA_SIZE	equ	0	; No page-3 RAM; SLTWRK only

	ifndef	NUM_SLOTS
	.fatal	NUM_SLOTS constant required with a value of 1 or 2
	else
	if	(NUM_SLOTS NE 1) and (NUM_SLOTS NE 2)
	.fatal	The value of NUM_SLOTS must be either 1 or 2, got {NUM_SLOTS}
	endif
	endif

; SLTWRK: 8 bytes per slot (expanded-slot safe). Mapper-off puts the
; cartridge in a host expander, so only the 8-byte subslot window is ours.
; GETWRK returns IX = window + SD-slot (0 or 1):
; +0     NOP
; +1..+3 R800: LDIR+RET / Z80: JP transfer_z80
; +4     STATUS0
; +5     STATUS1
; +6..+7 free
; Slot 0: jp (ix) hits the NOP then the trampoline; slot 1 skips the NOP.
; STATUS is (ix+4) in both cases.
STATUS	equ	4	; Offset from GETWRK's IX to this SD slot's STATUS

BIT_SLOT1	equ	0	; 1 = this STATUS byte is SD slot 1 (ReselectSD)
BIT_SDHC	equ	1	; 0 = SDSC (byte addressed), 1 = SDHC/SDXC (block addressed)
BIT_SD_CHG	equ	2	; 1 = InitSD succeeded since GET_STATUS last consumed it
; ACMD41/CMD1 polls before giving up (~a few seconds at 3.58 MHz).
INIT_POLL	equ	4096

; Turbo R main-ROM BIOS (not in the Nextor SDK headers)
MSXVER	equ	002Dh

; Card types (printed at init)
CARD_MMC	equ	0
CARD_SD1X	equ	1
CARD_SD2X	equ	2
CARD_SDHC	equ	3
CARD_SDXC	equ	4

; SPI / mapper ports
PORTSPI	equ	#4000	; SPI data window (any address in 4000h-47FFh)
PORTCFG	equ	#4800	; Status / chip-select
SPI_MODE	equ	#6001	; 0 = ROM, 1 = SPI

; Executable SD-layer origin (must be past the SPI window)
SPI_CODE	equ	#4900

;This is a 2 byte buffer to store the address of code to be executed.
;It is used by some of the kernel page 0 routines.
CODE_ADD:	equ	0F2EDh

	INCLUDE	asm/constants/msx_bios.inc
	INCLUDE	asm/constants/msx_workarea.inc

; SD tokens
DATA_TOKEN	equ	#FE
MUL_DAT_TKN_STA	equ	#FC
MUL_DAT_TKN_END	equ	#FD

; SPI command byte is CMD+index (start bit 0, direction bit 1).
; CRC is ignored in SPI except CMD0 and CMD8; the end bit must still be 1.
CMD	equ	#40
CRC_DUMMY	equ	#95

; Driver version
VER_MAIN	equ	1
VER_SEC	equ	0
VER_REV	equ	0

; This driver defines several `.local:` labels, so a bare `.NAME` reference
; inside those scopes would be parsed as `<parent_label>.NAME`.
; To force absolute (file-scope) lookup for the DOS error codes we prefix
; the references with ":"; see the Nestor80 LanguageReference
; ("Relative labels") for the exact rule.

	INCLUDE	asm/constants/dos_errors.inc

	INCLUDE	asm/constants/driver_result_codes.inc

	module	DRIVER_QUERY
	INCLUDE	asm/constants/driver_driver_queries.inc
	endmod

	module	DEVICE_QUERY
	INCLUDE	asm/constants/driver_device_queries.inc
	ifndef	READ_BEFORE_INIT
	const	READ_BEFORE_INIT,8	;Read sectors before the driver is initialized
	endif
	endmod

	INCLUDE	asm/constants/rom_bank_header.inc

;-----------------------------------------------------------------------------
; Start
;-----------------------------------------------------------------------------

	org	#4000

	ds	256,0	; Dummy bytes. Will be overwritten by Page 0 code

DRV_START:

;-----------------------------------------------------------------------------

	;Driver signature

	db	"NEXTORv3_DRIVER",0

	;Jump table

	jp	TIMER_INT
	jp	OEMSTAT
	jp	BASDEV
	jp	DRV_EXTBIO
	jp	DRIVER_QUERY
	jp	DEVICE_QUERY
	jp	CUSTOM_DRIVER_QUERY
	jp	CUSTOM_DEVICE_QUERY
	jp	READ_WRITE

	; RESERVED_0/1/2 + DIRECT_0..4
	ds	8*3,0C9h


; Driver name (also used as hardware name)

DRV_NAME:
	db	"SDMapper V1",0

; Contact for this published driver, not a claim of original authorship.
; Nextor 3 structure: Manuel Pazos. Hardware I/O: Fabio Belavenuto, FRS.
; Their rights remain in the file header and LICENSE.
STR_DRIVER_AUTHOR:
	db	"uniabis",0

STR_HARDWARE_AUTHOR:
	db	"Fabio Belavenuto",0


;-----------------------------------------------------------------------------
; DRIVER_QUERY (411Ch)
; Input:  A = Query index
; Output: A = RESULT_OK / RESULT_NOT_IMPLEMENTED / ...
;-----------------------------------------------------------------------------
DRIVER_QUERY:
	cp	:DRIVER_QUERY.GET_VERSION
	jr	z,DRVQ_GET_VERSION
	cp	:DRIVER_QUERY.GET_STRING
	jr	z,DRVQ_GET_STRING
	cp	:DRIVER_QUERY.GET_INIT_PARAMS_ROM
	jr	z,DRVQ_GET_INIT_PARAMS
	cp	:DRIVER_QUERY.INIT_ROM
	jp	z,DRV_INIT
	cp	:DRIVER_QUERY.GET_MAX_DEVICE
	jr	z,DRVQ_GET_MAX_DEVICE
	; INIT_RAM / SHUTDOWN_RAM: ROM driver, not implemented
	ld	a,RESULT_NOT_IMPLEMENTED
	ret

; Query 1: version in B.C.D
DRVQ_GET_VERSION:
	ld	b,VER_MAIN
	ld	c,VER_SEC
	ld	d,VER_REV
	xor	a
	ret

; Query 2: B = string index, D = buffer size, HL = buffer
DRVQ_GET_STRING:
	ld	a,b
	ld	b,d
	ex	de,hl
	cp	:DRIVER_QUERY.STR_DRIVER_NAME
	ld	hl,DRV_NAME
	jp	z,OUTPUT_STRING
	cp	:DRIVER_QUERY.STR_DRIVER_AUTHOR
	ld	hl,STR_DRIVER_AUTHOR
	jp	z,OUTPUT_STRING
	cp	:DRIVER_QUERY.STR_HARDWARE_NAME
	ld	hl,DRV_NAME
	jp	z,OUTPUT_STRING
	cp	:DRIVER_QUERY.STR_HARDWARE_AUTHOR
	ld	hl,STR_HARDWARE_AUTHOR
	jp	z,OUTPUT_STRING
	ld	a,RESULT_NOT_IMPLEMENTED
	ret

; Query 3: no timer/EXTBIO hook, no page-3 work area
DRVQ_GET_INIT_PARAMS:
	xor	a
	ld	b,a
	if WORK_AREA_SIZE eq 0
	ld	h,a
	ld	l,a
	else
	ld	hl,WORK_AREA_SIZE
	endif
	ret

; Query 5
DRVQ_GET_MAX_DEVICE:
	ld	b,NUM_SLOTS
	xor	a
	ret

; CHPUT callback from the kernel (address in IY). May modify AF only.
DO_CHPUT:
	jp	(iy)


;-----------------------------------------------------------------------------
; DEVICE_QUERY (411Fh)
; Input:  A = Query index, C = Device number
; The device number is validated before looking at the query index.
;-----------------------------------------------------------------------------
DEVICE_QUERY:
	push	af
	ld	a,c
	or	a
	jr	z,DEVQ_INVALID_DEVICE
	cp	NUM_SLOTS+1
	jr	nc,DEVQ_INVALID_DEVICE
	pop	af

	cp	:DEVICE_QUERY.GET_STRING
	jr	z,DEVQ_GET_STRING
	cp	:DEVICE_QUERY.GET_PARAMS
	jp	z,DEVQ_GET_PARAMS
	cp	:DEVICE_QUERY.GET_STATUS
	jp	z,DEVQ_GET_STATUS
	cp	:DEVICE_QUERY.GET_AVAILABILITY
	jp	z,DEVQ_GET_AVAILABILITY
	cp	:DEVICE_QUERY.READ_BEFORE_INIT
	jp	z,DEVQ_READ_BEFORE_INIT
	; GET_FORMAT_CHOICES / DO_FORMAT / STOP_MOTOR: not a floppy
	ld	a,RESULT_NOT_IMPLEMENTED
	ret

DEVQ_INVALID_DEVICE:
	pop	af
RETURN_INVALID_DEVICE:
	ld	a,RESULT_INVALID_DEVICE
	ret

; Query 1: B = string index, D = buffer size, HL = buffer
DEVQ_GET_STRING:
	ld	a,b
	or	a
	jr	z,RETURN_NOT_IMP ; b=0
	cp	:DEVICE_QUERY.STR_DEVICE_NAME
	jr	z,DEVQ_GET_DEV_NAME ; b=4
	jr	nc,RETURN_NOT_IMP	; b>4
	jp	DEVQ_GET_CID_STRING ; b=1,2,3

; String 4: driver-provided device name (available even with no card)
DEVQ_GET_DEV_NAME:
	ld	b,d
	ex	de,hl

	ld	hl,SDSLOT_1_S

	if	NUM_SLOTS NE 1

	ld	a,c
	dec	a
	jp	z,OUTPUT_STRING
	ld	hl,SDSLOT_2_S

	endif

	jp	OUTPUT_STRING

CUSTOM_DEVICE_QUERY:
	ld	a,c
	or	a
	jr	z,RETURN_INVALID_DEVICE
	cp	NUM_SLOTS+1
	jr	nc,RETURN_INVALID_DEVICE
CUSTOM_DRIVER_QUERY:
RETURN_NOT_IMP:
	ld	a,RESULT_NOT_IMPLEMENTED
	ret

;-----------------------------------------------------------------------------
; OEMSTAT (4113h) — BASIC expanded statement ("CALL") handler.
;-----------------------------------------------------------------------------
OEMSTAT:
;-----------------------------------------------------------------------------
; BASDEV (4116h) — BASIC expanded device handler.
;-----------------------------------------------------------------------------
BASDEV:
	scf
;-----------------------------------------------------------------------------
; TIMER_INT (4110h) — not hooked (GET_INIT_PARAMS returns B=0).
;-----------------------------------------------------------------------------
TIMER_INT:
;-----------------------------------------------------------------------------
; EXTBIO (4119h) — not hooked (GET_INIT_PARAMS returns B=0).
;-----------------------------------------------------------------------------
DRV_EXTBIO:
	ret


;-----------------------------------------------------------------------------
; Read-only strings used only while SPI is off (init print, name queries).
; Safe in 4000h-48FFh; that range is the SPI window once SPI is enabled.
; Manufacturers stays at SPI_CODE+ because GetManufacName runs mid-CID.
;-----------------------------------------------------------------------------
VERSION_STRING	macro v_main,v_sub
	db	"Version &v_main&.&v_sub&",13,10
	endm

TXT_INFO:
	db	"SDMapper V1 driver",13,10
	VERSION_STRING	%VER_MAIN,%VER_SEC
	db	"Nextor 3",13,10
TXT_EMPTY:
	db	13,10,0

TXT_INIT:
	db	"SD Card slot ",0

TXT_EMPTY_CARD:
	db	" (empty)",13,10,0
TXT_UNKNOWN:
	db	" (unknown)",13,10,0

TXT_MMC:
	db	" MMC",13,10,0
TXT_SD1x:
	db	" SDSC 1.x",13,10,0
TXT_SD2x:
	db	" SDSC 2.x",13,10,0
TXT_SDHC:
	db	" SDHC",13,10,0
TXT_SDXC:
	db	" SDXC",13,10,0

TXT_MR_OFF:
	db	"Slot expander/Mapper/MegaRAM disabled",13,10,0
TXT_MAPPER:
	db	"Slot expanded and Memory Mapper enabled",13,10,0
TXT_MEGARAM:
	db	"Slot expander and MegaRAM enabled",13,10,0

SDSLOT_1_S:
	db	"SD card slot 1",0

	if	NUM_SLOTS NE 1

SDSLOT_2_S:
	db	"SD card slot 2",0

	endif

IDX_TYPE:
	dw	TXT_MMC
	dw	TXT_SD1x
	dw	TXT_SD2x
	dw	TXT_SDHC
	dw	TXT_SDXC


;-----------------------------------------------------------------------------
; Code below may run with SPI on and must live at 4900h+.
;-----------------------------------------------------------------------------
	ds	SPI_CODE-$,#FF


;-----------------------------------------------------------------------------
; DRIVER_QUERY 4: Initialize driver
; Input:  DE = CHPUT callback (may modify AF only)
; Output: A  = RESULT_OK
;-----------------------------------------------------------------------------
DRV_INIT:
	push	de
	pop	iy	; IY = print-character callback

	call	InstallXfer

	ld	de,TXT_INFO
	call	PRINT

	call	PrintMapperStatus

	ld	b,NUM_SLOTS
.loop:
	push	bc

	ld	a,NUM_SLOTS
	sub	b	; A = SD slot (0 or 1)
	ld	c,a

	ld	de,TXT_INIT
	call	PRINT
	ld	a,c
	add	a,'1'
	call	DO_CHPUT
	ld	a,':'
	call	DO_CHPUT

	ld	a,c
	call	GETWRK
	ld	(ix+STATUS),a	; bit 0 = SD slot
	call	DI_SD_ON
	call	SelectSD

	inc	c	; C = 1 or 2, PORTCFG present bits
	ld	a,(PORTCFG)
	and	c
	jr	nz,.empty	; bit set = no card

	call	InitSD
	call	DESEL_SD_OFF_EI
	jr	c,.notCard
	jr	nz,.notCard

	ld	a,b	; B = card type on success
	add	a,a	; type * 2
	add	a,LOW IDX_TYPE
	ld	l,a
	adc	a,HIGH IDX_TYPE
	sub	l
	ld	h,a
	ld	e,(hl)
	inc	hl
	ld	d,(hl)
	call	PRINT
	jr	.next

.empty:
	call	DESEL_SD_OFF_EI
	ld	de,TXT_EMPTY_CARD
	call	PRINT
	jr	.next

.notCard:
	ld	de,TXT_UNKNOWN
	call	PRINT
.next:
	pop	bc
	djnz	.loop

	ld	de,TXT_EMPTY
	call	PRINT
	xor	a	; RESULT_OK
	ret

;-----------------------------------------------------------------------------
; Build the SLTWRK transfer trampoline at +0..+3. Called from
; READ_BEFORE_INIT (before GET_INIT_PARAMS / INIT_ROM) and again
; from DRV_INIT. SLTWRK is uninitialized until we write it, so
; jp (ix) is unsafe earlier. STATUS is not touched here.
; Default is NOP + JP transfer_z80. On Turbo R (MSXVER>=3)
; that JP is replaced with LDIR+RET. Z80 mode on a Turbo R still uses LDIR.
;-----------------------------------------------------------------------------
InstallXfer:
	xor	a
	call	GETWRK	; IX = window base
	ld	(ix+0),0	; NOP
	ld	(ix+1),#C3	; JP transfer_z80
	ld	(ix+2),LOW transfer_z80
	ld	(ix+3),HIGH transfer_z80

	ld	a,(MSXVER)
	cp	3
	ret	c

	ld	(ix+1),#ED	; LDIR
	ld	(ix+2),#B0
	ld	(ix+3),#C9	; RET
	ret

;-----------------------------------------------------------------------------
; READ_WRITE (4128h)
; Input:  Cy=0 read, 1 write
;         A = Device number
;         B = Number of sectors
;         C = Media descriptor (floppy only; ignored)
;         HL = Transfer address
;         DE = Pointer to 4-byte sector number
; Output: A = MSX-DOS error code
;         B = Sectors actually transferred
;-----------------------------------------------------------------------------
READ_WRITE:
	push	af	; F=Cy (R/W), A=device

	or	a
	jr	z,.error
	cp	NUM_SLOTS+1
	jr	nc,.error

	ld	c,a	; C = device 1/2 (media descriptor unused)
	dec	a	; 0 for slot 1, 1 for slot 2

	call	GETWRK
	call	DI_SD_ON
	call	SelectSD

	; Present? PORTCFG bits 0/1 are 0 when a card is inserted
	ld	a,(PORTCFG)
	and	c
	jr	nz,.notready

	pop	af	; Cy = write
	jr	c,.write

	call	ReadSD
	call	DESEL_SD_OFF_EI
	jr	c,.fail

.ok:
	; Leave BIT_SD_CHG set. GET_STATUS is what consumes it, so a
	; re-init inside this read/write is still visible afterwards.
	xor	a	; B = requested count (all transferred)
	ret

.write:
	push	bc	; B = count, C = 1 or 2
	ld	a,c
	add	a,a
	add	a,a	; WP mask: 4 or 8
	ld	c,a
	ld	a,(PORTCFG)
	and	c
	jr	nz,.wprot

	call	WriteSD
	call	DESEL_SD_OFF_EI
	pop	bc
	jr	nc,.ok

	ld	a,:.WRERR
.fail:
	ld	b,0
	ret

.wprot:
	pop	bc
	ld	b,0
	ld	a,:.WPROT
	jp	DESEL_SD_OFF_EI

.notready:
	pop	af
	ld	b,0
	ld	a,:.NRDY
	jp	DESEL_SD_OFF_EI

.error:
	pop	af
	ld	b,0
	ld	a,:.IDEVN
	ret


;-----------------------------------------------------------------------------
; DEVICE_QUERY 8: Read sectors before the driver is initialized.
; Same inputs as a READ_WRITE read. SLTWRK is uninitialized: install
; the trampoline here (not only in DRV_INIT) and write STATUS the same
; way DRV_INIT does. Do not read STATUS first — it is garbage until
; then, so BIT_SD_CHG cannot mean "already InitSD'd". No printing.
; .IDEVN / .NRDY → kernel tries the next device; anything else stops.
;-----------------------------------------------------------------------------
DEVQ_READ_BEFORE_INIT:
	call	InstallXfer

	push	bc	; B = requested count
	push	hl	; dest

	ld	a,c
	dec	a	; 0 for slot 1, 1 for slot 2
	call	GETWRK
	ld	(ix+STATUS),a	; bit 0 = SD slot
	call	DI_SD_ON
	call	SelectSD

	ld	a,(PORTCFG)
	and	c	; C = 1 or 2, PORTCFG present bits
	jr	nz,.nrdy

	call	InitSD
	jr	c,.nrdy
	jr	nz,.nrdy
	pop	hl
	pop	bc
	call	ReadSD
	call	DESEL_SD_OFF_EI
	jr	c,.fail
	xor	a
	ret

.fail:
	ld	b,0
	ret

.nrdy:
	pop	hl
	pop	bc
	ld	b,0
	ld	a,:.NRDY
	jp	DESEL_SD_OFF_EI


;-----------------------------------------------------------------------------
; DEVICE_QUERY 1, strings 1-3: manufacturer / medium name / serial from CID
; Input:  B = 1..3, C = device, D = buffer size, HL = buffer
;-----------------------------------------------------------------------------
DEVQ_GET_CID_STRING:
	ld	a,c
	dec	a	; slot 0/1
	ld	e,b	; E = string index, D = buffer size

	call	GETWRK
	call	DI_SD_ON
	call	SelectSD

	ld	a,(PORTCFG)
	and	c	; C = device 1/2, PORTCFG present bits
	jr	nz,.badcid

	ld	a,d
	or	a
	jr	z,.truncated	; D=0 and string exists

	push	de
	ex	de,hl	; DE = buffer (GetCID preserves DE)
	call	GetCID
	pop	bc	; B = buffer size, C = string index
	jr	c,.badcid

	dec	c
	jr	nz,.medium

	; 1: Manufacturer name
	ld	a,(PORTSPI)
	ld	c,a	; C = MID
	push	bc	; B = buffer size
	ld	b,15 + 2
	call	SkipBytes
	call	GetManufacName
	pop	bc
	push	bc
	call	OUTPUT_STRING
	pop	bc	; B = buffer size, C = MID
	or	a
	jp	nz,DESEL_SD_OFF_EI

	ld	a,b
	cp	20
	jr	c,.ok
	ld	a," "
	ld	(de),a
	inc	de
	ld	a,"["
	ld	(de),a
	inc	de
	ld	a,c
	call	Num2Hex.hi
	ld	a,c
	call	Num2Hex.lo
	ld	a,"]"
	ld	(de),a
	inc	de
	xor	a
	ld	(de),a
.ok:
	xor	a
	jp	DESEL_SD_OFF_EI

.truncated:
	ld	a,RESULT_TRUNCATED_STRING
	jp	DESEL_SD_OFF_EI

.badcid:
	ld	a,RESULT_NOT_IMPLEMENTED
	jp	DESEL_SD_OFF_EI

.medium:
	dec	c
	jr	nz,.serial

	; 2: Medium name (product name from the card)
	ld	a,b
	cp	6+1
	ld	c,5
	ld	a,RESULT_OK
	jr	nc,.medium_oklen
	ld	c,b
	dec	c
	ld	a,RESULT_TRUNCATED_STRING
.medium_oklen:
	push	af
	ld	a,(PORTSPI)
	SPI_GAP
	ld	a,(PORTSPI)
	ld	hl,PORTSPI
	ld	a,(PORTSPI)
	ld	b,0
	ldir
	xor	a
	ld	(de),a
	ld	b,8 + 2
	call	SkipBytes
	pop	af
	jp	DESEL_SD_OFF_EI

.serial:
	; 3: Serial number (8 hex digits + NUL)
	ld	a,b
	cp	9
	ld	c,8
	ld	a,RESULT_OK
	jr	nc,.serial_len
	ld	c,b
	dec	c		; reserve the terminating NUL
	ld	a,RESULT_TRUNCATED_STRING
.serial_len:
	push	af
	ld	b,9
	call	SkipBytes
	call	.hex2
	call	.hex2
	ld	b,3 + 2
	call	SkipBytes
	xor	a
	ld	(de),a
	pop	af
	jp	DESEL_SD_OFF_EI
.hex2:
	ld	a,(PORTSPI)
	ld	h,a
	ld	a,(PORTSPI)
	ld	l,a
	ld	a,h
	call	.nibpair
	ld	a,l
.nibpair:
	push	af
	rrca
	rrca
	rrca
	rrca
	call	.nib
	pop	af
.nib:
	ld	b,a
	ld	a,c
	or	a
	ld	a,b
	ret	z		; no room left; SPI byte already consumed
	dec	c
	or	#F0
	daa
	add	a,#A0
	adc	a,#40
	ld	(de),a
	inc	de
	ret


;------------------------------------------------------------------------------
; Input: HL = number to convert, DE = location of ASCII string
; Output: ASCII string at (DE)
;------------------------------------------------------------------------------
Num2Hex:
	ld	a,h
	call	.hi
	ld	a,h
	call	.lo
	ld	a,l
	call	.hi
	ld	a,l
	jr	.lo

.hi:
	rra
	rra
	rra
	rra
.lo:
	or	#F0
	daa
	add	a,#A0
	adc	a,#40

	ld	(de),a
	inc	de
	ret

;-----------------------------------------------------------------------------
; Get manufacturer name
; In:	A = ID
; Out:	HL = String
;-----------------------------------------------------------------------------
GetManufacName:
	ld	c,a
	ld	hl,Manufacturers
.loop:
	ld	a,(hl)
	inc	hl
	cp	c
	jr	z,.found

	or	a
	jr	z,.found

	push	bc
	call	.found
	add	hl,bc
	inc	hl
	pop	bc
	jr	.loop
.found:
	xor	a
	ld	c,a
	push	hl
.cont:
	inc	c
	inc	hl
	cp	(hl)
	jr	nz,.cont
.end:
	pop	hl
	ld	b,0
	ret

; CID MID. SD-3C does not publish an official list; names below are
; from observed cards (hardinfo/sdcard.ids, Camera Memory Speed,
; Matt Cole's survey). OEM ASCII is in the comment.
Manufacturers:
	db	#01,"Panasonic",0	; 5041:PA
	db	#02,"Kioxia",0	; 544D:TM (formerly Toshiba)
	db	#03,"SanDisk",0	; 5344:SD, 5054:PT (also WD)
	db	#06,"Ritek",0	; 524B:RK
	db	#09,"ATP",0	; 4150:AP
	db	#12,"Patriot",0	; 3456:4V (also Gigastone)
	db	#13,"KingMax",0	; 4B47:KG
	db	#18,"Infineon",0	; 4946:IF
	db	#19,"Dynacard",0	; 4459:DY
	db	#1A,"PQI",0	; 5051:PQ
	db	#1B,"Samsung",0	; 534D:SM (also ProGrade)
	db	#1C,"Transcend",0	; 5356:SV (older Silicon Valley)
	db	#1D,"ADATA",0	; 4144:AD
	db	#27,"Phison",0	; 5048:PH (many rebrands)
	db	#28,"Lexar",0	; 4245:BE (Barun Electronics)
	db	#31,"Silicon Power",0	; 5350:SP
	db	#41,"Kingston",0	; 3432:42
	db	#45,"TEAMGROUP",0	; 2D42:-B
	db	#51,"STEC",0	; 5360:S`
	db	#58,"Delkin",0	; 4444:DD
	db	#5D,"Swissbit",0	; 5342:SB
	db	#61,"Netlist",0	; 4E4C:NL
	db	#63,"Cactus",0	; 435A:CZ, 4360:C`
	db	#74,"Transcend",0	; 4A45:JE, 4A60:J` (Jiaelec)
	db	#76,"Patriot",0
	db	#82,"Sony",0	; 4A54:JT (Jiang Tay)
	db	#83,"Netcom",0	; 4E43:NC
	db	#84,"Strontium",0	; 5446:TF
	db	#89,"Netac",0	; (also ORICO)
	db	#9C,"Angelbird",0	; 534F:SO, 4245:BE (also Hoodman)
	db	#9F,"Taishin",0	; 5449:TI
	db	#AA,"openMSX",0	; 6F70:op (emulator)
	db	#AD,"Longsys",0	; 4C53:LS (Lexar, RPi, Amazon)
	db	#00,"(unknown)",0

;-----------------------------------------------------------------------------
; DEVICE_QUERY 3: Get device status
; Output: A = RESULT_OK, B = 0/1/2 (unavailable / unchanged / changed)
; Consumes the media-change flag.
;-----------------------------------------------------------------------------
DEVQ_GET_STATUS:
	ld	a,c
	dec	a	; 0 for slot 1, 1 for slot 2
	call	GETWRK
	call	DI_SD_ON
	call	SelectSD

	ld	a,(PORTCFG)
	and	c	; C = device 1/2, PORTCFG present bits
	jr	nz,.nopresent

	call	TestCard
	call	DESEL_SD_OFF_EI
	jr	c,.unavailable

	bit	BIT_SD_CHG,(ix+STATUS)
	jr	nz,.changed
	ld	b,1	; unchanged
	xor	a
	ret

.changed:
	res	BIT_SD_CHG,(ix+STATUS)
	ld	b,2
	xor	a
	ret

.nopresent:
	call	DESEL_SD_OFF_EI
.unavailable:
	xor	a
	ld	b,a
	ret


;-----------------------------------------------------------------------------
; DEVICE_QUERY 4: Get device availability
; Output: A = RESULT_OK, B = 0 (unavailable) or 1 (available)
; Must not consume the media-change flag.
;-----------------------------------------------------------------------------
DEVQ_GET_AVAILABILITY:
	call	DI_SD_ON
	ld	a,(PORTCFG)
	and	c	; C = device 1/2, PORTCFG present bits
	ld	b,1
	jr	z,.ok	; bit clear = card present
	dec	b
.ok:
	xor	a
	jp	SD_OFF_EI


;-----------------------------------------------------------------------------
; DEVICE_QUERY 2: Get device parameters
; Input:  C = device, HL = 12-byte buffer (0 = validate only)
; Output: A = RESULT_OK
;-----------------------------------------------------------------------------
DEVQ_GET_PARAMS:
	ld	a,h
	or	l
	ret	z	; no buffer: device id already checked

	ld	a,c
	dec	a	; slot 0/1
	push	hl
	call	GETWRK
	call	DI_SD_ON
	call	SelectSD

	ld	a,(PORTCFG)
	and	c	; C = device 1/2, PORTCFG present bits
	jr	nz,.defaults

	call	GetSectNum
	call	nc,WaitBusy
	call	DESEL_SD_OFF_EI

	ld	b,h
	ld	c,l	; DEBC = available sectors
	pop	hl
	jr	c,.fill_defaults

	xor	a
	ld	(hl),a	; +0: Block device
	inc	hl
	ld	(hl),a	; +1: Sector size = 512
	inc	hl
	ld	(hl),2
	inc	hl
	ld	(hl),c	; +3: Total sectors
	inc	hl
	ld	(hl),b
	inc	hl
	ld	(hl),e
	inc	hl
	ld	(hl),d
	inc	hl
	ld	(hl),1	; +7: removable (PARAMF_NO_PSTOR clear)
	inc	hl
	ld	(hl),a	; +8 Cylinders
	inc	hl
	ld	(hl),a
	inc	hl
	ld	(hl),a	; +10: Heads
	inc	hl
	ld	(hl),a	; +11: Sectors per track
	ret	; A=0 = RESULT_OK

.defaults:
	call	DESEL_SD_OFF_EI
	pop	hl
.fill_defaults:
	xor	a
	ld	(hl),a	; block device
	inc	hl
	ld	(hl),a	; sector size 512
	inc	hl
	ld	(hl),2
	inc	hl
	ld	(hl),a	; 0 sectors (no medium)
	inc	hl
	ld	(hl),a
	inc	hl
	ld	(hl),a
	inc	hl
	ld	(hl),a
	inc	hl
	ld	(hl),1	; removable
	inc	hl
	ld	(hl),a
	inc	hl
	ld	(hl),a
	inc	hl
	ld	(hl),a
	inc	hl
	ld	(hl),a
	xor	a
	ret


;-----------------------------------------------------------------------------
; Obtain the 8-byte SLTWRK window for this cartridge.
; In: A = 0 Slot 1, A = 1 slot 2
; Output: IX = window + A (trampoline at +0 / STATUS at +4)
; A is preserved
;
; SLTWRK is 8 bytes × 16 (primary × subslot). Offset is
; primary*32, plus subslot*8 when the slot is expanded. Mapper-off
; SDMapper V1 can sit in a host expander, so we never assume the
; unused 24 bytes of a non-expanded primary are ours.
;-----------------------------------------------------------------------------
GETWRK:
	push	af
	push	bc
	push	hl

	; A = FxxxSSPP (expanded flag, subslot, primary)
	in	a,(#a8)
	rrca
	rrca
	and	3
	ld	c,a
	add	a,LOW EXPTBL	; FCC1h; +3 / +4 stay in page
	ld	l,a
	ld	h,HIGH EXPTBL
	ld	a,(hl)
	and	80h
	or	c
	ld	c,a
	inc	l
	inc	l
	inc	l
	inc	l
	ld	a,(hl)
	and	0Ch
	or	c
	ld	c,a
	rrca
	rrca
	rrca
	and	%01100000	; primary * 32
	ld	b,a
	bit	7,c
	jr	z,.base
	ld	a,c
	and	%00001100	; SS00
	add	a,a	; subslot * 8
	add	a,b
	ld	b,a
.base:
	ld	c,b
	ld	b,0
	ld	ix,SLTWRK
	add	ix,bc

	pop	hl
	pop	bc
	pop	af
	or	a
	ret	z	; Slot 1
	inc	ix	; Slot 2
	ret

;-----------------------------------------------------------------------------
; SPI enable / disable. Code after DI_SD_ON must live at SPI_CODE+
;-----------------------------------------------------------------------------
DI_SD_ON:
	push	af
	di
	ld	a,1
	ld	(SPI_MODE),a
	pop	af
	ret

DESEL_SD_OFF_EI:
	call	DeselectSD
SD_OFF_EI:
	push	af
	xor	a
	ld	(SPI_MODE),a
	pop	af
	ei
	ret

;-----------------------------------------------------------------------------
; Select the SD slot in A (0 or 1).
; Preserves AF, BC, DE, HL, IX
;-----------------------------------------------------------------------------
SelectSD:
	push	af
	push	bc
	cpl	; 0/1 → #FF/#FE
	ld	c,a
	jr	DoSelectDec

; Re-assert CS for the slot recorded in BIT_SLOT1 of (ix+STATUS).
; IX must be GETWRK for the current SD slot. Preserves AF, BC, DE, HL, IX
ReselectSD:
	push	af
	push	bc
	ld	c,#FE
	bit	BIT_SLOT1,(ix+STATUS)
	jr	z,DoSelect
DoSelectDec:
	dec	c
DoSelect:
	ld	a,(PORTSPI)	; dummy
	ld	a,c
	ld	(PORTCFG),a
	pop	bc
	pop	af
	ret

DeselectSD:
	push	af
	ld	a,#FF	; all /CS high
	ld	(PORTCFG),a
	pop	af
	ret

;-----------------------------------------------------------------------------
; SD initialize: set to SPI mode
; Out: Cy = Timeout
;      NZ = Error
;       Z = Ok
;             B = 0 MMC
;             B = 1 SDSC 1.x
;             B = 2 SDSC 2.0 or higher
;             B = 3 SDHC 2.0 or higher
;             B = 4 SDXC
;-----------------------------------------------------------------------------
InitSD:
	res	BIT_SDHC,(ix+STATUS)

	call	.start
	ret	c
	ret	nz

	set	BIT_SD_CHG,(ix+STATUS)
	xor	a
	ret

.start:
	call	DeselectSD
	ld	b,10	; Dummy cycle > 76 clocks, CS high
.dummy:
	ld	a,#FF
	ld	(PORTSPI),a
	djnz	.dummy

	call	SD_CMD
	db	CMD+0,0,0,0,0,#95	; CMD0: Reset

	ret	c
	and	0f3h
	cp	01h
	ret	nz

.v2:
	call	SD_CMD
	db	CMD+8,0,0,#01,#aa,#87	; CMD8
	ret	c
	cp	1
	jr	nz,.v1	; SD V1.X or MMC

	ld	a,(PORTSPI)
	SPI_GAP
	ld	a,(PORTSPI)
	SPI_GAP
	ld	a,(PORTSPI)
	and	#f
	cp	1
	ret	nz
	ld	a,(PORTSPI)
	cp	#aa
	ret	nz	; Wrong voltage range

	ld	hl,INIT_POLL
.acmd41:
	call	SD_CMD
	db	CMD+55,0,0,0,0,#65	; CMD55
	ret	c

	cp	1
	ret	nz

	call	SD_CMD
	db	CMD+41,#40,0,0,0,#77	; ACMD41 (HCS = 1)

	ret	c

	and	1
	cp	1
	jr	nz,.cmd58

	call	.polltick
	ret	c
	jr	.acmd41

.cmd58:

	call	SD_CMD
	db	CMD+58,#00,0,0,0,#fd	; CMD58

	ret	c

	ld	a,(PORTSPI)	; OCR 32 bits
	ld	b,a
	ld	a,(PORTSPI)
	bit	6,b	; CCS
	ld	a,(PORTSPI)
	ld	b,CARD_SD2X
	ld	a,(PORTSPI)

	jr	z,.end

	set	BIT_SDHC,(ix+STATUS)

	; Distinguish SDHC vs SDXC via C_SIZE

	push	de
	ld	d,b ; d:any value less than 4+1 to report SDHC on error
	call	GetSectNum
	call	nc,WaitBusy

	ld	a,4
	sub	d	; Min. SDXC size > Max. SDHC size(32GB)

	pop	de

	ld	b,CARD_SDHC
	jr	nc,.end

	inc	b
.end:
	xor	a
	ret

.v1:
	ld	hl,INIT_POLL
.v1poll:
	call	SD_CMD
	db	CMD+55,#00,0,0,0,#65	; CMD55
	ret	c

	bit	2,a
	jr	nz,.mmc

	cp	1
	ret	nz

	call	SD_CMD
	db	CMD+41,#00,0,0,0,#e5	; ACMD41 (HCS = 0)
	ret	c

	bit	2,a
	jr	nz,.mmc

	bit	0,a
	jr	z,.v1ok

	call	.polltick
	ret	c
	jr	.v1poll

.v1ok:
	xor	a
	ld	b,CARD_SD1X
	ret

.mmc:
	call	SD_CMD
	db	CMD+1,#00,0,0,0,#f9	; CMD1
	ret	c

	cp	01h
	jr	nz,.mmcok

	call	.polltick
	ret	c
	jr	.v1poll

.mmcok:
	ld	b,CARD_MMC
	or	a
	ret

; HL = polls left. Cy when exhausted.
.polltick:
	dec	hl
	ld	a,h
	or	l
	ret	nz
	scf
	ret

;-----------------------------------------------------------------------------
; In:
;	(DE) = Sector number, 4 bytes
; Out:
;	BCDE  = Sector number (in the currently selected register set)
;-----------------------------------------------------------------------------
GetSector:
	push	de
	exx
	pop	hl

	bit	BIT_SDHC,(ix+STATUS)
	jr	z,.sdsc

	ld	e,(hl)
	inc	hl
	ld	d,(hl)
	inc	hl
	ld	c,(hl)
	inc	hl
	ld	b,(hl)
	ret

.sdsc:
	; Convert sector number to byte offset (sector * 512)
	ld	e,0
	ld	d,(hl)
	inc	hl
	ld	c,(hl)
	inc	hl
	ld	b,(hl)

	sla	d
	rl	c
	rl	b
	ret

;-----------------------------------------------------------------------------
; SD / MMC Access routine
; Input:
;	A	= Command
;	BCDE	= Access address
;
; Output:	Cy = 0 successful (A = R1)
;		Cy = 1 timeout
;-----------------------------------------------------------------------------
MMCCMD:
	call	ReselectSD
	ex	af,af'
	ld	a,(PORTSPI)	; dummy cycle
	ex	af,af'
	ld	(PORTSPI),a	; command
	ld	a,b
	ld	(PORTSPI),a
	ld	a,c
	ld	(PORTSPI),a
	ld	a,d
	ld	(PORTSPI),a
	ld	a,e
	ld	(PORTSPI),a
	ld	a,CRC_DUMMY	; CRC
	ld	(PORTSPI),a

	ld	b,0
.wait:
	ld	a,(PORTSPI)
	cp	#FF
	ccf
	ret	nc

	djnz	.wait

	scf
	ret


;-----------------------------------------------------------------------------
; Sends a command to SD card (6 inline bytes after CALL).
; Each SPI write is ld (PORTSPI),a so no command buffer is needed.
; On success A = R1
;-----------------------------------------------------------------------------
SD_CMD:
	ex	(sp),hl
	call	ReselectSD
	ld	a,(PORTSPI)	; dummy cycle
	ld	b,6
.send:
	ld	a,(hl)
	inc	hl
	ld	(PORTSPI),a
	djnz	.send

	ex	(sp),hl
.wait:
	ld	a,(PORTSPI)
	cp	#FF
	ccf
	ret	nc

	djnz	.wait

	scf
	ret


;-----------------------------------------------------------------------------
; Read sectors
;	B    = Number of sectors to read
;	(DE) = First sector number to read
;	HL   = destination address for the transfer
;	IX   = GETWRK (window + SD slot)
;-----------------------------------------------------------------------------
ReadSD:
	ld	c,2
.retry:
	push	bc	; B = count, C = retries left
	call	GetSector

	ld	a,CMD+18	; CMD18: READ_MULTIPLE_BLOCK
	call	MMCCMD
	exx
	jr	c,.timeout

	or	a
	jr	nz,.timeout

	ex	de,hl	;DE = Destination address
	ld	l,b
.loop:
	ld	a,DATA_TOKEN	; every sector, not the previous CRC byte
	ld	h,PORTSPI/256
	ld	bc,0
.wait:
	cp	(hl)
	jr	z,.got
	dec	bc
	ld	a,b
	or	c
	ld	a,DATA_TOKEN
	jr	nz,.wait
	jr	.error	; token timeout: stop the multi-block read
.got:
	call	transfer

	ld	a,(PORTSPI)	; CRC (dummy)
	dec	l
	ld	a,(PORTSPI)
	jr	nz,.loop

	ld	a,CMD+12	;CMD12
	call	MMCCMD

	ex	de,hl
	pop	bc
	xor	a
	ret

.error:
	pop	bc
.stop:
	ld	a,CMD+12
	call	MMCCMD
	scf
.nrdy:
	ld	a,:.NRDY
	ret

.timeout:
	push	hl
	call	InitSD
	pop	hl
	pop	bc	; B = count, C = retries left
	jr	nz,.stop
	jr	c,.nrdy

	dec	c
	jr	nz,.retry

	ld	a,:.DISK
	scf
	ret


;-----------------------------------------------------------------------------
; Write sectors
;	B    = Number of sectors to write
;	(DE) = First sector number to write
;	HL   = source address for the transfer
; Out:
;	Cy   : 1 = Error
;-----------------------------------------------------------------------------

WriteSD:
	call	GetSector	;BCDE = Sector number (EXX set)
	exx
	ld	c,2		; attempts left (caller's C is saved around this call)
.try:
	ld	a,b
	dec	a
	jr	z,WriteSingle

	exx
	ld	a,CMD+25	; CMD25: WRITE_MULTIPLE_BLOCK
	call	MMCCMD
	exx
	jr	c,.timeout

	or	a
	ld	a,2
	jr	nz,.exit

	ld	a,(PORTSPI)	; dummy

.loop:
	ld	a,MUL_DAT_TKN_STA
	ld	(PORTSPI),a

	push	bc
	ld	de,PORTSPI
	call	transfer
	pop	bc

	call	WriteResp
	jr	c,.cancel

	djnz	.loop

	ld	a,(PORTSPI)
	SPI_GAP
	ld	a,(PORTSPI)

	ld	a,MUL_DAT_TKN_END
	ld	(PORTSPI),a
	SPI_GAP
	ld	a,(PORTSPI)
	SPI_GAP
	ld	a,(PORTSPI)

	jr	WaitBusy


.cancel:
	call	WaitBusy

	ld	a,(PORTSPI)
	SPI_GAP
	ld	a,(PORTSPI)

	ld	a,MUL_DAT_TKN_END
	ld	(PORTSPI),a
	SPI_GAP
	ld	a,(PORTSPI)
	SPI_GAP
	ld	a,(PORTSPI)

	call	WaitBusy
.exit:
	scf
	ret

.timeout:
	push	bc
	push	hl
	call	InitSD
	pop	hl
	pop	bc

	jr	nz,.giveup
	jr	c,.giveup
	dec	c
	jr	nz,.try
.giveup:
	ld	a,1
	scf
	ret

;
; Write a single sector
;
WriteSingle:
	exx
	ld	a,CMD+24	; CMD24: WRITE BLOCK
	call	MMCCMD
	exx
	jr	c,.timeout
	or	a
	jr	nz,.exit

	ld	a,(PORTSPI)
	ld	a,DATA_TOKEN
	ld	(PORTSPI),a

	ld	de,PORTSPI
	call	transfer

	call	WriteResp
	ret	c

	xor	a
	ret

.timeout:
	push	bc
	push	hl
	call	InitSD
	pop	hl
	pop	bc

	jr	nz,.exit
	ret	c
	dec	c
	jr	nz,WriteSingle

.exit:
	scf
	ret

;-----------------------------------------------------------------------------
; Clock the two dummy CRC bytes, then wait for the data-response token.
; The token is not a fixed number of bytes after the payload: the card
; may send one or more FFh bytes first, and the next byte is already
; the busy token (00h). Reading a fixed offset therefore samples 00h
; and reports a write error after the card has accepted the block.
; On accept, wait until programming finishes (MISO leaves 00h).
; Out: Cy = 0 accepted and not busy, 1 = rejected or timeout
;      BC, HL preserved
;-----------------------------------------------------------------------------
WriteResp:
	ld	a,(PORTSPI)	; CRC (dummy)
	push	bc
	ld	a,(PORTSPI)
	ld	b,0		; 256 polls
.poll:
	ld	a,(PORTSPI)
	cp	#FF
	jr	nz,.tok
	djnz	.poll
.bad:
	scf
	pop	bc
	ret
.tok:
	and	#1F
	cp	#05
	jr	nz,.bad
	pop	bc

;-----------------------------------------------------------------------------
; Wait until card is not busy
;-----------------------------------------------------------------------------
WaitBusy:
	push	bc

	ld	bc,#8000
.loop:
	ld	a,(PORTSPI)
	or	a
	jr	nz,.end

	dec	bc
	ld	a,b
	or	c
	jr	nz,.loop
	scf
.end:
	pop	bc
	ret


;-----------------------------------------------------------------------------
; Copy 512 bytes. HL/DE must already point at source/destination (one of
; them in the SPI window). IX = GETWRK result (window + SD slot).
; BC is clobbered; L is preserved (HL += 512), which ReadSD relies on
; as its remaining-sector counter.
;
; jp (ix) enters the SLTWRK trampoline (page-3 RAM):
;   R800: NOP?; LDIR; RET
;   Z80:  NOP?; JP transfer_z80 (512 LDI, then RET)
; Z80 overhead is ld bc,512 + jp (ix) and, on SD slot 0 only, the NOP.
;-----------------------------------------------------------------------------
transfer:
	ld	bc,512
	jp	(ix)

transfer_z80:
	REPT	512
	ldi
	ENDM
	ret

TestCard:
	ld	b,2
.retry:
	push	bc
	call	SD_CMD
	db	CMD+16,0,0,2,0,#15	; CMD16: SET_BLOCKLEN 512
	jr	c,.reinit
	pop	bc
	ret

.reinit:
	call	InitSD
	pop	bc
	ret	c
	scf
	ret	nz
	djnz	.retry
	scf
	ret


;-----------------------------------------------------------------------------
; Read CID register
; Out:
;	Cy   : 1 = Error 0 = Ok
;-----------------------------------------------------------------------------
GetCID:
	ld	b,2
.retry:
	push	bc
	call	SD_CMD
	db	CMD+10,0,0,0,0,#1b	; CMD10: SEND_CID

	jr	c,.reinit

	pop	bc
	ld	bc,DATA_TOKEN
.wait:
	ld	a,(PORTSPI)
	cp	c
	ret	z
	djnz	.wait

	scf
	ret

.reinit:
	call	InitSD
	pop	bc
	ret	c
	scf
	ret	nz
	djnz	.retry
	scf
	ret

;-----------------------------------------------------------------------------
; Get number of available sectors in the card
; Out:
;	DEHL = Number of sectors
;	Cy   : 1 = Error 0 = Ok
;-----------------------------------------------------------------------------
GetSectNum:
	call	SD_CMD
	db	CMD+9,#00,0,0,0,#af	;CMD9: SEND_CSD
	ret	c

	ld	bc,DATA_TOKEN
.wait:
	ld	a,(PORTSPI)
	cp	c
	jr	z,.got
	djnz	.wait

	scf
	ret

.got:
	bit	BIT_SDHC,(ix+STATUS)
	jr	nz,.hc

	ld	b,5
	call	SkipBytes
	ld	a,(PORTSPI)
	and	%1111	; READ_BL_LEN
	ld	c,a

	ld	a,(PORTSPI)
	and	%11	; C_SIZE 11-10
	ld	d,a
	ld	a,(PORTSPI)
	ld	e,a
	ld	a,(PORTSPI)
	sla	a
	rl	e
	rl	d
	sla	a
	rl	e
	rl	d

	ld	a,(PORTSPI)
	and	%11	; C_SIZE_MULT 2-1
	ld	b,a
	ld	a,(PORTSPI)
	sla	a
	ld	a,b
	rl	a

	add	a,c
	sub	7	; 512 = Sector size
	call	GetExp	; HL = Factor

	ld	b,h
	ld	c,l

	inc	de	; C_SIZE + 1

	call	Mul16	; DEHL = number of sectors

	ld	b,7		; tail + 2-byte CRC
	call	SkipBytes

	or	a
	ret

.hc:
	ld	b,7
	call	SkipBytes
	ld	a,(PORTSPI)
	and	%00111111
	ld	c,a	; C_SIZE 21-16

	ld	a,(PORTSPI)
	ld	d,a
	ld	a,(PORTSPI)
	ld	e,a

	ld	b,8		; tail + 2-byte CRC
	call	SkipBytes

	inc	de		; C_SIZE+1; INC DE does not affect flags
	ld	a,d
	or	e
	jr	nz,.hc_sized
	inc	c		; low 16 bits wrapped
.hc_sized:
	ld	h,c
	ld	l,d
	ld	d,e
	ld	e,0

	sla	d
	rl	l
	rl	h

	sla	d
	rl	l
	rl	h

	ex	de,hl
	or	a
	ret

;-----------------------------------------------------------------------------
; Skip B bytes from SD response
;-----------------------------------------------------------------------------
SkipBytes:
	push	af
.loop:
	ld	a,(PORTSPI)
	djnz	.loop
	pop	af
	ret

;-----------------------------------------------------------------------------
; 2^A
;-----------------------------------------------------------------------------
GetExp:
	ld	hl,1
	or	a
	ret	z
.loop:
	add	hl,hl
	dec	a
	jr	nz,.loop
	ret

;-----------------------------------------------------------------------------
; Multiplication 16 bits
; DEHL = BC * DE
;-----------------------------------------------------------------------------
Mul16:
	ld	hl,0
	ld	a,16
.loop:
	add	hl,hl
	rl	e
	rl	d
	jr	nc,.next

	add	hl,bc
	jr	nc,.next

	inc	de
.next:
	dec	a
	jr	nz,.loop
	ret

;-----------------------------------------------------------------------------
; Print Mapper / MegaRAM / disabled status from PORTCFG.
;-----------------------------------------------------------------------------
PrintMapperStatus:
	call	DI_SD_ON
	ld	a,(PORTCFG)
	ld	c,a
	call	SD_OFF_EI

	ld	de,TXT_MR_OFF
	ld	a,c
	and	#10
	jr	z,PRINT		; bit4=0: RAM disabled
	ld	de,TXT_MAPPER
	ld	a,c
	and	#20
	jr	nz,PRINT	; bit5=1: Memory Mapper
	ld	de,TXT_MEGARAM

;-----------------------------------------------------------------------------
; Print a zero-terminated string on screen
; Input: DE = String address
;-----------------------------------------------------------------------------
PRINT:
	ld	a,(de)
	or	a
	ret	z

	call	DO_CHPUT
	inc	de
	jr	PRINT

	INCLUDE	asm/code/output_string.asm

;-----------------------------------------------------------------------------
; End of the driver code
;-----------------------------------------------------------------------------
DRV_END:

	end
