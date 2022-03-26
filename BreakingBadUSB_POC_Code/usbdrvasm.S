/* Name: usbdrvasm.S
 * Project: V-USB, virtual USB port for Atmel's(r) AVR(r) microcontrollers
 * Author: Christian Starkjohann
 * Creation Date: 2007-06-13
 * Tabsize: 4
 * Copyright: (c) 2007 by OBJECTIVE DEVELOPMENT Software GmbH
 * License: GNU GPL v2 (see License.txt), GNU GPL v3 or proprietary (CommercialLicense.txt)
 * Revision: $Id: usbdrvasm.S 761 2009-08-12 16:30:23Z cs $
 */

/*
General Description:
This module is the assembler part of the USB driver. This file contains
general code (preprocessor acrobatics and CRC computation) and then includes
the file appropriate for the given clock rate.
*/

#define __SFR_OFFSET 0      /* used by avr-libc's register definitions */
#include "usbportability.h"
#include "usbdrv.h"         /* for common defs */

/* register names */
#define x1      r16
#define x2      r17
#define shift   r18
#define cnt     r19
#define x3      r20
#define x4      r21
#define x5		  r22
#define bitcnt  x5
#define phase   x4
#define leap    x4

/* Some assembler dependent definitions and declarations: */

#ifdef __IAR_SYSTEMS_ASM__
    #error __IAR_SYSTEMS_ASM__ jejo:no deberia precompilar esto
    extern  usbRxBuf, usbDeviceAddr, usbNewDeviceAddr, usbInputBufOffset
    extern  usbCurrentTok, usbRxLen, usbRxToken, usbTxLen
    extern  usbTxBuf, usbTxStatus1, usbTxStatus3
#   if USB_COUNT_SOF
        extern usbSofCount
#   endif
    public  usbCrc16
    public  usbCrc16Append

    COMMON  INTVEC
#   ifndef USB_INTR_VECTOR
        ORG     INT0_vect
#   else /* USB_INTR_VECTOR */
        ORG     USB_INTR_VECTOR
#       undef   USB_INTR_VECTOR
#   endif /* USB_INTR_VECTOR */
#   define  USB_INTR_VECTOR usbInterruptHandler
    rjmp    USB_INTR_VECTOR
    RSEG    CODE

#else /* __IAR_SYSTEMS_ASM__ */
    #warning jejo: no __IAR_SYSTEMS_ASM__

#   ifndef USB_INTR_VECTOR /* default to hardware interrupt INT0 */
        #warning jejo: define USB_INTR_VECTOR  SIG_INTERRUPT0
#       define USB_INTR_VECTOR  SIG_INTERRUPT0
#   endif
    .text
    .global USB_INTR_VECTOR
    .type   USB_INTR_VECTOR, @function
    .global usbCrc16
    .global usbCrc16Append
#endif /* __IAR_SYSTEMS_ASM__ */


#if USB_INTR_PENDING < 0x40 /* This is an I/O address, use in and out */
#   define  USB_LOAD_PENDING(reg)   in reg, USB_INTR_PENDING
#   define  USB_STORE_PENDING(reg)  out USB_INTR_PENDING, reg
#else   /* It's a memory address, use lds and sts */
#   define  USB_LOAD_PENDING(reg)   lds reg, USB_INTR_PENDING
#   define  USB_STORE_PENDING(reg)  sts USB_INTR_PENDING, reg
#endif

#define usbTxLen1   usbTxStatus1
#define usbTxBuf1   (usbTxStatus1 + 1)
#define usbTxLen3   usbTxStatus3
#define usbTxBuf3   (usbTxStatus3 + 1)


;----------------------------------------------------------------------------
; Utility functions
;----------------------------------------------------------------------------

#ifdef __IAR_SYSTEMS_ASM__
/* Register assignments for usbCrc16 on IAR cc */
/* Calling conventions on IAR:
 * First parameter passed in r16/r17, second in r18/r19 and so on.
 * Callee must preserve r4-r15, r24-r29 (r28/r29 is frame pointer)
 * Result is passed in r16/r17
 * In case of the "tiny" memory model, pointers are only 8 bit with no
 * padding. We therefore pass argument 1 as "16 bit unsigned".
 */
RTMODEL "__rt_version", "3"
/* The line above will generate an error if cc calling conventions change.
 * The value "3" above is valid for IAR 4.10B/W32
 */
#   define argLen   r18 /* argument 2 */
#   define argPtrL  r16 /* argument 1 */
#   define argPtrH  r17 /* argument 1 */

#   define resCrcL  r16 /* result */
#   define resCrcH  r17 /* result */

#   define ptrL     ZL
#   define ptrH     ZH
#   define ptr      Z
#   define byte     r22
#   define bitCnt   r19
#   define polyL    r20
#   define polyH    r21
#   define scratch  r23

#else  /* __IAR_SYSTEMS_ASM__ */ 
/* Register assignments for usbCrc16 on gcc */
/* Calling conventions on gcc:
 * First parameter passed in r24/r25, second in r22/23 and so on.
 * Callee must preserve r1-r17, r28/r29
 * Result is passed in r24/r25
 */
#   define argLen   r22 /* argument 2 */
#   define argPtrL  r24 /* argument 1 */
#   define argPtrH  r25 /* argument 1 */

#   define resCrcL  r24 /* result */
#   define resCrcH  r25 /* result */

#   define ptrL     XL
#   define ptrH     XH
#   define ptr      x
#   define byte     r18
#   define bitCnt   r19
#   define polyL    r20
#   define polyH    r21
#   define scratch  r23

#endif

#if USB_USE_FAST_CRC

; This implementation is faster, but has bigger code size
; Thanks to Slawomir Fras (BoskiDialer) for this code!
; It implements the following C pseudo-code:
; unsigned table(unsigned char x)
; {
; unsigned    value;
; 
;     value = (unsigned)x << 6;
;     value ^= (unsigned)x << 7;
;     if(parity(x))
;         value ^= 0xc001;
;     return value;
; }
; unsigned usbCrc16(unsigned char *argPtr, unsigned char argLen)
; {
; unsigned crc = 0xffff;
; 
;     while(argLen--)
;         crc = table(lo8(crc) ^ *argPtr++) ^ hi8(crc);
;     return ~crc;
; }

; extern unsigned usbCrc16(unsigned char *argPtr, unsigned char argLen);
;   argPtr  r24+25 / r16+r17
;   argLen  r22 / r18
; temp variables:
;   byte    r18 / r22
;   scratch r23
;   resCrc  r24+r25 / r16+r17
;   ptr     X / Z
usbCrc16:
    mov     ptrL, argPtrL
    mov     ptrH, argPtrH
    ldi     resCrcL, 0xFF
    ldi     resCrcH, 0xFF
    rjmp    usbCrc16LoopTest
usbCrc16ByteLoop:
    ld      byte, ptr+
    eor     resCrcL, byte   ; resCrcL is now 'x' in table()
    mov     byte, resCrcL   ; compute parity of 'x'
    swap    byte
    eor     byte, resCrcL
    mov     scratch, byte
    lsr     byte
    lsr     byte
    eor     byte, scratch
    inc     byte
    lsr     byte
    andi    byte, 1         ; byte is now parity(x)
    mov     scratch, resCrcL
    mov     resCrcL, resCrcH
    eor     resCrcL, byte   ; low byte of if(parity(x)) value ^= 0xc001;
    neg     byte
    andi    byte, 0xc0
    mov     resCrcH, byte   ; high byte of if(parity(x)) value ^= 0xc001;
    clr     byte
    lsr     scratch
    ror     byte
    eor     resCrcH, scratch
    eor     resCrcL, byte
    lsr     scratch
    ror     byte
    eor     resCrcH, scratch
    eor     resCrcL, byte
usbCrc16LoopTest:
    subi    argLen, 1
    brsh    usbCrc16ByteLoop
    com     resCrcL
    com     resCrcH
    ret

#else   /* USB_USE_FAST_CRC */

; This implementation is slower, but has less code size
;
; extern unsigned usbCrc16(unsigned char *argPtr, unsigned char argLen);
;   argPtr  r24+25 / r16+r17
;   argLen  r22 / r18
; temp variables:
;   byte    r18 / r22
;   bitCnt  r19
;   poly    r20+r21
;   scratch r23
;   resCrc  r24+r25 / r16+r17
;   ptr     X / Z
usbCrc16:
    mov     ptrL, argPtrL
    mov     ptrH, argPtrH
    ldi     resCrcL, 0
    ldi     resCrcH, 0
    ldi     polyL, lo8(0xa001)
    ldi     polyH, hi8(0xa001)
    com     argLen      ; argLen = -argLen - 1: modified loop to ensure that carry is set
    ldi     bitCnt, 0   ; loop counter with starnd condition = end condition
    rjmp    usbCrcLoopEntry
usbCrcByteLoop:
    ld      byte, ptr+
    eor     resCrcL, byte
usbCrcBitLoop:
    ror     resCrcH     ; carry is always set here (see brcs jumps to here)
    ror     resCrcL
    brcs    usbCrcNoXor
    eor     resCrcL, polyL
    eor     resCrcH, polyH
usbCrcNoXor:
    subi    bitCnt, 224 ; (8 * 224) % 256 = 0; this loop iterates 8 times
    brcs    usbCrcBitLoop
usbCrcLoopEntry:
    subi    argLen, -1
    brcs    usbCrcByteLoop
usbCrcReady:
    ret
; Thanks to Reimar Doeffinger for optimizing this CRC routine!

#endif /* USB_USE_FAST_CRC */

; extern unsigned usbCrc16Append(unsigned char *data, unsigned char len);
usbCrc16Append:
    rcall   usbCrc16
    st      ptr+, resCrcL
    st      ptr+, resCrcH
    ret

#undef argLen
#undef argPtrL
#undef argPtrH
#undef resCrcL
#undef resCrcH
#undef ptrL
#undef ptrH
#undef ptr
#undef byte
#undef bitCnt
#undef polyL
#undef polyH
#undef scratch


#if USB_CFG_HAVE_MEASURE_FRAME_LENGTH
#ifdef __IAR_SYSTEMS_ASM__
/* Register assignments for usbMeasureFrameLength on IAR cc */
/* Calling conventions on IAR:
 * First parameter passed in r16/r17, second in r18/r19 and so on.
 * Callee must preserve r4-r15, r24-r29 (r28/r29 is frame pointer)
 * Result is passed in r16/r17
 * In case of the "tiny" memory model, pointers are only 8 bit with no
 * padding. We therefore pass argument 1 as "16 bit unsigned".
 */
#   define resL     r16
#   define resH     r17
#   define cnt16L   r30
#   define cnt16H   r31
#   define cntH     r18

#else  /* __IAR_SYSTEMS_ASM__ */ 
/* Register assignments for usbMeasureFrameLength on gcc */
/* Calling conventions on gcc:
 * First parameter passed in r24/r25, second in r22/23 and so on.
 * Callee must preserve r1-r17, r28/r29
 * Result is passed in r24/r25
 */
#   define resL     r24
#   define resH     r25
#   define cnt16L   r24
#   define cnt16H   r25
#   define cntH     r26
#endif
#   define cnt16    cnt16L

; extern unsigned usbMeasurePacketLength(void);
; returns time between two idle strobes in multiples of 7 CPU clocks
.global usbMeasureFrameLength
usbMeasureFrameLength:
    ldi     cntH, 6         ; wait ~ 10 ms for D- == 0
    clr     cnt16L
    clr     cnt16H
usbMFTime16:
    dec     cntH
    breq    usbMFTimeout
usbMFWaitStrobe:            ; first wait for D- == 0 (idle strobe)
    sbiw    cnt16, 1        ;[0] [6]
    breq    usbMFTime16     ;[2]
    sbic    USBIN, USBMINUS ;[3]
    rjmp    usbMFWaitStrobe ;[4]
usbMFWaitIdle:              ; then wait until idle again
    sbis    USBIN, USBMINUS ;1 wait for D- == 1
    rjmp    usbMFWaitIdle   ;2
    ldi     cnt16L, 1       ;1 represents cycles so far
    clr     cnt16H          ;1
usbMFWaitLoop:
    in      cntH, USBIN     ;[0] [7]
    adiw    cnt16, 1        ;[1]
    breq    usbMFTimeout    ;[3]
    andi    cntH, USBMASK   ;[4]
    brne    usbMFWaitLoop   ;[5]
usbMFTimeout:
#if resL != cnt16L
    mov     resL, cnt16L
    mov     resH, cnt16H
#endif
    ret

#undef resL
#undef resH
#undef cnt16
#undef cnt16L
#undef cnt16H
#undef cntH

#endif  /* USB_CFG_HAVE_MEASURE_FRAME_LENGTH */

;----------------------------------------------------------------------------
; Now include the clock rate specific code
;----------------------------------------------------------------------------

#       //jejo quito inc y substituyo codigo include "usbdrvasm165.inc"










/* Name: usbdrvasm165.inc
 * Project: V-USB, virtual USB port for Atmel's(r) AVR(r) microcontrollers
 * Author: Christian Starkjohann
 * Creation Date: 2007-04-22
 * Tabsize: 4
 * Copyright: (c) 2007 by OBJECTIVE DEVELOPMENT Software GmbH
 * License: GNU GPL v2 (see License.txt), GNU GPL v3 or proprietary (CommercialLicense.txt)
 * Revision: $Id: usbdrvasm165.inc 740 2009-04-13 18:23:31Z cs $
 */

/* Do not link this file! Link usbdrvasm.S instead, which includes the
 * appropriate implementation!
 */

/*
General Description:
This file is the 16.5 MHz version of the USB driver. It is intended for the
ATTiny45 and similar controllers running on 16.5 MHz internal RC oscillator.
This version contains a phase locked loop in the receiver routine to cope with
slight clock rate deviations of up to +/- 1%.

See usbdrv.h for a description of the entire driver.

Since almost all of this code is timing critical, don't change unless you
really know what you are doing! Many parts require not only a maximum number
of CPU cycles, but even an exact number of cycles!
*/

;Software-receiver engine. Strict timing! Don't change unless you can preserve timing!
;interrupt response time: 4 cycles + insn running = 7 max if interrupts always enabled
;max allowable interrupt latency: 59 cycles -> max 52 cycles interrupt disable
;max stack usage: [ret(2), r0, SREG, YL, YH, shift, x1, x2, x3, x4, cnt] = 12 bytes
;nominal frequency: 16.5 MHz -> 11 cycles per bit
; 16.3125 MHz < F_CPU < 16.6875 MHz (+/- 1.1%)
; Numbers in brackets are clocks counted from center of last sync bit
; when instruction starts

//jejo averiguo el puñetero valor de USB_INTR_VECTOR
#if USB_INTR_VECTOR == SIG_PIN_CHANGE
#warning jejo: USB_INTR_VECTOR == SIG_PIN_CHANGE en el attiny85
#endif


USB_INTR_VECTOR:
;order of registers pushed: YL, SREG [sofError], r0, YH, shift, x1, x2, x3, x4, cnt
    push    YL                  ;[-23] push only what is necessary to sync with edge ASAP
    in      YL, SREG            ;[-21] SREG Status Register  
    push    YL                  ;[-20]
;----------------------------------------------------------------------------
; Synchronize with sync pattern:
;----------------------------------------------------------------------------
;sync byte (D-) pattern LSb to MSb: 01010100 [1 = idle = J, 0 = K]
;sync up with J to K edge during sync pattern -- use fastest possible loops
;The first part waits at most 1 bit long since we must be in sync pattern.
;YL is guarenteed to be < 0x80 because I flag is clear. When we jump to
;waitForJ, ensure that this prerequisite is met.
;USBIN es el registro para leer de puerto usb entrada IN
;USBMINUS es el pin en el que esta conectado d-
waitForJ:
    inc     YL               
    sbis    USBIN, USBMINUS  ; sbis Skip if Bit in I/O Register is Set
    brne    waitForJ         ; just make sure we have ANY timeout
                             ;Mientras d- sea 0/K se queda en este bucle

waitForK:
;The following code results in a sampling window of < 1/4 bit which meets the spec.
    sbis    USBIN, USBMINUS     ;[-15] SBIS – Skip if Bit in I/O Register is Set
    rjmp    foundK              ;[-14]
    sbis    USBIN, USBMINUS
    rjmp    foundK
    sbis    USBIN, USBMINUS
    rjmp    foundK
    sbis    USBIN, USBMINUS
    rjmp    foundK
    sbis    USBIN, USBMINUS
    rjmp    foundK
    sbis    USBIN, USBMINUS
    rjmp    foundK
#if USB_COUNT_SOF
    lds     YL, usbSofCount
    inc     YL
    sts     usbSofCount, YL
#endif  /* USB_COUNT_SOF */
#ifdef USB_SOF_HOOK
    USB_SOF_HOOK
#endif
    rjmp    sofError

    
foundK:                         ;[-12]
;{3, 5} after falling D- edge, average delay: 4 cycles [we want 5 for center sampling]
;we have 1 bit time for setup purposes, then sample again. Numbers in brackets
;are cycles from center of first sync (double K) bit after the instruction
    push    r0                  ;[-12]
;   [---]                       ;[-11]
    push    YH                  ;[-10]
;   [---]                       ;[-9]
    lds     YL, usbInputBufOffset;[-8]
;   [---]                       ;[-7]
    clr     YH                  ;[-6]
    subi    YL, lo8(-(usbRxBuf));[-5] [rx loop init]
    sbci    YH, hi8(-(usbRxBuf));[-4] [rx loop init]
    mov     r0, x2              ;[-3] [rx loop init]
    sbis    USBIN, USBMINUS     ;[-2] we want two bits K (sample 2 cycles too early)
    rjmp    haveTwoBitsK        ;[-1]
    pop     YH                  ;[0] undo the pushes from before
    pop     r0                  ;[2]
    rjmp    waitForK            ;[4] this was not the end of sync, retry
; The entire loop from waitForK until rjmp waitForK above must not exceed two
; bit times (= 22 cycles).

;----------------------------------------------------------------------------
; push more registers and initialize values while we sample the first bits:
;----------------------------------------------------------------------------
haveTwoBitsK:               ;[1]
    push    shift           ;[1]
    push    x1              ;[3]
    push    x2              ;[5]
    push    x3              ;[7]
    ldi     shift, 0xff     ;[9] [rx loop init]
    ori     x3, 0xff        ;[10] [rx loop init] == ser x3, clear zero flag

    in      x1, USBIN       ;[11] <-- sample bit 0
    bst     x1, USBMINUS    ;[12]
    bld     shift, 0        ;[13]
    push    x4              ;[14] == phase
;   [---]                   ;[15]
    push    cnt             ;[16]
;   [---]                   ;[17]
    ldi     phase, 0        ;[18] [rx loop init]
    ldi     cnt, USB_BUFSIZE;[19] [rx loop init]
    rjmp    rxbit1          ;[20]
;   [---]                   ;[21]

;----------------------------------------------------------------------------
; Receiver loop (numbers in brackets are cycles within byte after instr)
;----------------------------------------------------------------------------
/*
byte oriented operations done during loop:
bit 0: store data
bit 1: SE0 check
bit 2: overflow check
bit 3: catch up
bit 4: rjmp to achieve conditional jump range
bit 5: PLL
bit 6: catch up
bit 7: jump, fixup bitstuff
; 87 [+ 2] cycles
------------------------------------------------------------------
*/
continueWithBit5:
    in      x2, USBIN       ;[055] <-- bit 5
    eor     r0, x2          ;[056]
    or      phase, r0       ;[057]
    sbrc    phase, USBMINUS ;[058]
    lpm                     ;[059] optional nop3; modifies r0
    in      phase, USBIN    ;[060] <-- phase
    eor     x1, x2          ;[061]
    bst     x1, USBMINUS    ;[062]
    bld     shift, 5        ;[063]
    andi    shift, 0x3f     ;[064]
    in      x1, USBIN       ;[065] <-- bit 6
    breq    unstuff5        ;[066] *** unstuff escape
    eor     phase, x1       ;[067]
    eor     x2, x1          ;[068]
    bst     x2, USBMINUS    ;[069]
    bld     shift, 6        ;[070]
didUnstuff6:                ;[   ]
    in      r0, USBIN       ;[071] <-- phase
    cpi     shift, 0x02     ;[072]
    brlo    unstuff6        ;[073] *** unstuff escape
didUnstuff5:                ;[   ]
    nop2                    ;[074]
;   [---]                   ;[075]
    in      x2, USBIN       ;[076] <-- bit 7
    eor     x1, x2          ;[077]
    bst     x1, USBMINUS    ;[078]
    bld     shift, 7        ;[079]
didUnstuff7:                ;[   ]
    eor     r0, x2          ;[080]
    or      phase, r0       ;[081]
    in      r0, USBIN       ;[082] <-- phase
    cpi     shift, 0x04     ;[083]
    brsh    rxLoop          ;[084]
;   [---]                   ;[085]
unstuff7:                   ;[   ]
    andi    x3, ~0x80       ;[085]
    ori     shift, 0x80     ;[086]
    in      x2, USBIN       ;[087] <-- sample stuffed bit 7
    nop                     ;[088]
    rjmp    didUnstuff7     ;[089]
;   [---]                   ;[090]
                            ;[080]

unstuff5:                   ;[067]
    eor     phase, x1       ;[068]
    andi    x3, ~0x20       ;[069]
    ori     shift, 0x20     ;[070]
    in      r0, USBIN       ;[071] <-- phase
    mov     x2, x1          ;[072]
    nop                     ;[073]
    nop2                    ;[074]
;   [---]                   ;[075]
    in      x1, USBIN       ;[076] <-- bit 6
    eor     r0, x1          ;[077]
    or      phase, r0       ;[078]
    eor     x2, x1          ;[079]
    bst     x2, USBMINUS    ;[080]
    bld     shift, 6        ;[081] no need to check bitstuffing, we just had one
    in      r0, USBIN       ;[082] <-- phase
    rjmp    didUnstuff5     ;[083]
;   [---]                   ;[084]
                            ;[074]

unstuff6:                   ;[074]
    andi    x3, ~0x40       ;[075]
    in      x1, USBIN       ;[076] <-- bit 6 again
    ori     shift, 0x40     ;[077]
    nop2                    ;[078]
;   [---]                   ;[079]
    rjmp    didUnstuff6     ;[080]
;   [---]                   ;[081]
                            ;[071]

unstuff0:                   ;[013]
    eor     r0, x2          ;[014]
    or      phase, r0       ;[015]
    andi    x2, USBMASK     ;[016] check for SE0
    in      r0, USBIN       ;[017] <-- phase
    breq    didUnstuff0     ;[018] direct jump to se0 would be too long
    andi    x3, ~0x01       ;[019]
    ori     shift, 0x01     ;[020]
    mov     x1, x2          ;[021] mov existing sample
    in      x2, USBIN       ;[022] <-- bit 1 again
    rjmp    didUnstuff0     ;[023]
;   [---]                   ;[024]
                            ;[014]

unstuff1:                   ;[024]
    eor     r0, x1          ;[025]
    or      phase, r0       ;[026]
    andi    x3, ~0x02       ;[027]
    in      r0, USBIN       ;[028] <-- phase
    ori     shift, 0x02     ;[029]
    mov     x2, x1          ;[030]
    rjmp    didUnstuff1     ;[031]
;   [---]                   ;[032]
                            ;[022]

unstuff2:                   ;[035]
    eor     r0, x2          ;[036]
    or      phase, r0       ;[037]
    andi    x3, ~0x04       ;[038]
    in      r0, USBIN       ;[039] <-- phase
    ori     shift, 0x04     ;[040]
    mov     x1, x2          ;[041]
    rjmp    didUnstuff2     ;[042]
;   [---]                   ;[043]
                            ;[033]

unstuff3:                   ;[043]
    in      x2, USBIN       ;[044] <-- bit 3 again
    eor     r0, x2          ;[045]
    or      phase, r0       ;[046]
    andi    x3, ~0x08       ;[047]
    ori     shift, 0x08     ;[048]
    nop                     ;[049]
    in      r0, USBIN       ;[050] <-- phase
    rjmp    didUnstuff3     ;[051]
;   [---]                   ;[052]
                            ;[042]

unstuff4:                   ;[053]
    andi    x3, ~0x10       ;[054]
    in      x1, USBIN       ;[055] <-- bit 4 again
    ori     shift, 0x10     ;[056]
    rjmp    didUnstuff4     ;[057]
;   [---]                   ;[058]
                            ;[048]

rxLoop:                     ;[085]
    eor     x3, shift       ;[086] reconstruct: x3 is 0 at bit locations we changed, 1 at others
    in      x1, USBIN       ;[000] <-- bit 0
    st      y+, x3          ;[001]
;   [---]                   ;[002]
    eor     r0, x1          ;[003]
    or      phase, r0       ;[004]
    eor     x2, x1          ;[005]
    in      r0, USBIN       ;[006] <-- phase
    ser     x3              ;[007]
    bst     x2, USBMINUS    ;[008]
    bld     shift, 0        ;[009]
    andi    shift, 0xf9     ;[010]
rxbit1:                     ;[   ]
    in      x2, USBIN       ;[011] <-- bit 1
    breq    unstuff0        ;[012] *** unstuff escape 
    andi    x2, USBMASK     ;[013] SE0 check for bit 1
didUnstuff0:                ;[   ] Z only set if we detected SE0 in bitstuff
    breq    se0             ;[014] BREQ – Branch if Equal
    eor     r0, x2          ;[015]
    or      phase, r0       ;[016]
    in      r0, USBIN       ;[017] <-- phase
    eor     x1, x2          ;[018]
    bst     x1, USBMINUS    ;[019]
    bld     shift, 1        ;[020]
    andi    shift, 0xf3     ;[021]
didUnstuff1:                ;[   ]
    in      x1, USBIN       ;[022] <-- bit 2
    breq    unstuff1        ;[023] *** unstuff escape
    eor     r0, x1          ;[024]
    or      phase, r0       ;[025]
    subi    cnt, 1          ;[026] overflow check
    brcs    overflow        ;[027]
    in      r0, USBIN       ;[028] <-- phase
    eor     x2, x1          ;[029]
    bst     x2, USBMINUS    ;[030]
    bld     shift, 2        ;[031]
    andi    shift, 0xe7     ;[032]
didUnstuff2:                ;[   ]
    in      x2, USBIN       ;[033] <-- bit 3
    breq    unstuff2        ;[034] *** unstuff escape
    eor     r0, x2          ;[035]
    or      phase, r0       ;[036]
    eor     x1, x2          ;[037]
    bst     x1, USBMINUS    ;[038]
    in      r0, USBIN       ;[039] <-- phase
    bld     shift, 3        ;[040]
    andi    shift, 0xcf     ;[041]
didUnstuff3:                ;[   ]
    breq    unstuff3        ;[042] *** unstuff escape
    nop                     ;[043]
    in      x1, USBIN       ;[044] <-- bit 4
    eor     x2, x1          ;[045]
    bst     x2, USBMINUS    ;[046]
    bld     shift, 4        ;[047]
didUnstuff4:                ;[   ]
    eor     r0, x1          ;[048]
    or      phase, r0       ;[049]
    in      r0, USBIN       ;[050] <-- phase
    andi    shift, 0x9f     ;[051]
    breq    unstuff4        ;[052] *** unstuff escape
    rjmp    continueWithBit5;[053]
;   [---]                   ;[054]

macro POP_STANDARD ; 16 cycles
    pop     cnt
    pop     x4
    pop     x3
    pop     x2
    pop     x1
    pop     shift
    pop     YH
    pop     r0
    endm
macro POP_RETI     ; 5 cycles
    pop     YL
    out     SREG, YL
    pop     YL
    endm

// jejo quito inc y substituyo codigo #include "asmcommon.inc"







/* Name: asmcommon.inc
 * Project: V-USB, virtual USB port for Atmel's(r) AVR(r) microcontrollers
 * Author: Christian Starkjohann
 * Creation Date: 2007-11-05
 * Tabsize: 4
 * Copyright: (c) 2007 by OBJECTIVE DEVELOPMENT Software GmbH
 * License: GNU GPL v2 (see License.txt), GNU GPL v3 or proprietary (CommercialLicense.txt)
 * Revision: $Id$
 */

/* Do not link this file! Link usbdrvasm.S instead, which includes the
 * appropriate implementation!
 */

/*
General Description:
This file contains assembler code which is shared among the USB driver
implementations for different CPU cocks. Since the code must be inserted
in the middle of the module, it's split out into this file and #included.

Jump destinations called from outside:
    sofError: Called when no start sequence was found.
    se0: Called when a package has been successfully received.
    overflow: Called when receive buffer overflows.
    doReturn: Called after sending data.

Outside jump destinations used by this module:
    waitForJ: Called to receive an already arriving packet.
    sendAckAndReti:
    sendNakAndReti:
    sendCntAndReti:
    usbSendAndReti:

The following macros must be defined before this file is included:
    .macro POP_STANDARD
    .endm
    .macro POP_RETI
    .endm
*/

#define token   x1

overflow:
    ldi     x2, 1<<USB_INTR_PENDING_BIT
    USB_STORE_PENDING(x2)       ; clear any pending interrupts
ignorePacket:
    clr     token
    rjmp    storeTokenAndReturn

;----------------------------------------------------------------------------
; Processing of received packet (numbers in brackets are cycles after center of SE0)
;----------------------------------------------------------------------------
;This is the only non-error exit point for the software receiver loop
;we don't check any CRCs here because there is no time left.
se0:
    subi    cnt, USB_BUFSIZE    ;[5]  ;SUBI – Subtract Immediate
    neg     cnt                 ;[6]  ;cnt  es   r19
    sub     YL, cnt             ;[7]
    sbci    YH, 0               ;[8]
    ldi     x2, 1<<USB_INTR_PENDING_BIT ;[9]
    USB_STORE_PENDING(x2)       ;[10] clear pending intr and check flag later. SE0 should be over.
    ld      token, y            ;[11]
    cpi     token, USBPID_DATA0 ;[13]
    breq    handleData          ;[14]
    cpi     token, USBPID_DATA1 ;[15]
    breq    handleData          ;[16]
    lds     shift, usbDeviceAddr;[17]
    ldd     x2, y+1             ;[19] ADDR and 1 bit endpoint number
    lsl     x2                  ;[21] shift out 1 bit endpoint number
    nop ;jejo ignoro comparacion paquetes usbDeviceAddr; cpse    x2, shift           ;[22]
    nop ;jejo ignoro comparacion paquetes usbDeviceAddr; rjmp    ignorePacket        ;[23]
/* only compute endpoint number in x3 if required later */
#if USB_CFG_HAVE_INTRIN_ENDPOINT || USB_CFG_IMPLEMENT_FN_WRITEOUT
    ldd     x3, y+2             ;[24] endpoint number + crc
    rol     x3                  ;[26] shift in LSB of endpoint
#endif
    cpi     token, USBPID_IN    ;[27]
    breq    handleIn            ;[28]
    cpi     token, USBPID_SETUP ;[29]
    breq    handleSetupOrOut    ;[30]
    nop ;jejo ignoro comparacion paquetes; cpi     token, USBPID_OUT   ;[31]
    nop ;jejo ignoro comparacion paquetes; brne    ignorePacket        ;[32] must be ack, nak or whatever
;   rjmp    handleSetupOrOut    ; fallthrough

;Setup and Out are followed by a data packet two bit times (16 cycles) after
;the end of SE0. The sync code allows up to 40 cycles delay from the start of
;the sync pattern until the first bit is sampled. That's a total of 56 cycles.
handleSetupOrOut:               ;[32]
#if USB_CFG_IMPLEMENT_FN_WRITEOUT   /* if we have data for endpoint != 0, set usbCurrentTok to address */
    andi    x3, 0xf             ;[32]
    breq    storeTokenAndReturn ;[33]
    mov     token, x3           ;[34] indicate that this is endpoint x OUT
#endif
storeTokenAndReturn:
    sts     usbCurrentTok, token;[35]
doReturn:
    POP_STANDARD                ;[37] 12...16 cycles
    USB_LOAD_PENDING(YL)        ;[49]
    sbrc    YL, USB_INTR_PENDING_BIT;[50] check whether data is already arriving
    rjmp    waitForJ            ;[51] save the pops and pushes -- a new interrupt is already pending
sofError:
    POP_RETI                    ;macro call
    reti

handleData:

    lds     shift, usbCurrentTok;[18]
    tst     shift               ;[20]
    breq    doReturn            ;[21]
    lds     x2, usbRxLen        ;[22]
    tst     x2                  ;[24]
    brne    sendNakAndReti      ;[25]
; 2006-03-11: The following two lines fix a problem where the device was not
; recognized if usbPoll() was called less frequently than once every 4 ms.
    cpi     cnt, 4              ;[26] zero sized data packets are status phase only -- ignore and ack
    brmi    sendAckAndReti      ;[27] keep rx buffer clean -- we must not NAK next SETUP
#if USB_CFG_CHECK_DATA_TOGGLING
    sts     usbCurrentDataToken, token  ; store for checking by C code
#endif
    sts     usbRxLen, cnt       ;[28] store received data, swap buffers
    sts     usbRxToken, shift   ;[30]
    lds     x2, usbInputBufOffset;[32] swap buffers
    ldi     cnt, USB_BUFSIZE    ;[34]
    sub     cnt, x2             ;[35]
    sts     usbInputBufOffset, cnt;[36] buffers now swapped
    rjmp    sendAckAndReti      ;[38] 40 + 17 = 57 until SOP

handleIn:
;We don't send any data as long as the C code has not processed the current
;input data and potentially updated the output data. That's more efficient
;in terms of code size than clearing the tx buffers when a packet is received.
    lds     x1, usbRxLen        ;[30]
    cpi     x1, 1               ;[32] negative values are flow control, 0 means "buffer free"
    brge    sendNakAndReti      ;[33] unprocessed input packet?
    ldi     x1, USBPID_NAK      ;[34] prepare value for usbTxLen
#if USB_CFG_HAVE_INTRIN_ENDPOINT
    andi    x3, 0xf             ;[35] x3 contains endpoint
#if USB_CFG_SUPPRESS_INTR_CODE
    brne    sendNakAndReti      ;[36]
#else
    brne    handleIn1           ;[36]
#endif
#endif
    lds     cnt, usbTxLen       ;[37]
    sbrc    cnt, 4              ;[39] all handshake tokens have bit 4 set
    rjmp    sendCntAndReti      ;[40] 42 + 16 = 58 until SOP
    sts     usbTxLen, x1        ;[41] x1 == USBPID_NAK from above
    ldi     YL, lo8(usbTxBuf)   ;[43]
    ldi     YH, hi8(usbTxBuf)   ;[44]
    rjmp    usbSendAndReti      ;[45] 57 + 12 = 59 until SOP

; Comment about when to set usbTxLen to USBPID_NAK:
; We should set it back when we receive the ACK from the host. This would
; be simple to implement: One static variable which stores whether the last
; tx was for endpoint 0 or 1 and a compare in the receiver to distinguish the
; ACK. However, we set it back immediately when we send the package,
; assuming that no error occurs and the host sends an ACK. We save one byte
; RAM this way and avoid potential problems with endless retries. The rest of
; the driver assumes error-free transfers anyway.

#if !USB_CFG_SUPPRESS_INTR_CODE && USB_CFG_HAVE_INTRIN_ENDPOINT /* placed here due to relative jump range */
handleIn1:                      ;[38]
#if USB_CFG_HAVE_INTRIN_ENDPOINT3
; 2006-06-10 as suggested by O.Tamura: support second INTR IN / BULK IN endpoint
    cpi     x3, USB_CFG_EP3_NUMBER;[38]
    breq    handleIn3           ;[39]
#endif
    lds     cnt, usbTxLen1      ;[40]
    sbrc    cnt, 4              ;[42] all handshake tokens have bit 4 set
    rjmp    sendCntAndReti      ;[43] 47 + 16 = 63 until SOP
    sts     usbTxLen1, x1       ;[44] x1 == USBPID_NAK from above
    ldi     YL, lo8(usbTxBuf1)  ;[46]
    ldi     YH, hi8(usbTxBuf1)  ;[47]
    rjmp    usbSendAndReti      ;[48] 50 + 12 = 62 until SOP

#if USB_CFG_HAVE_INTRIN_ENDPOINT3
handleIn3:
    lds     cnt, usbTxLen3      ;[41]
    sbrc    cnt, 4              ;[43]
    rjmp    sendCntAndReti      ;[44] 49 + 16 = 65 until SOP
    sts     usbTxLen3, x1       ;[45] x1 == USBPID_NAK from above
    ldi     YL, lo8(usbTxBuf3)  ;[47]
    ldi     YH, hi8(usbTxBuf3)  ;[48]
    rjmp    usbSendAndReti      ;[49] 51 + 12 = 63 until SOP
#endif
#endif

















; USB spec says:
; idle = J
; J = (D+ = 0), (D- = 1)
; K = (D+ = 1), (D- = 0)
; Spec allows 7.5 bit times from EOP to SOP for replies

bitstuff7:
    eor     x1, x4          ;[4]
    ldi     x2, 0           ;[5]
    nop2                    ;[6] C is zero (brcc)
    rjmp    didStuff7       ;[8]

bitstuffN:
    eor     x1, x4          ;[5]
    ldi     x2, 0           ;[6]
    lpm                     ;[7] 3 cycle NOP, modifies r0
    out     USBOUT, x1      ;[10] <-- out
    rjmp    didStuffN       ;[0]

#define bitStatus   x3

sendNakAndReti:
    ldi     cnt, USBPID_NAK ;[-19]
    rjmp    sendCntAndReti  ;[-18]
sendAckAndReti:
    ldi     cnt, USBPID_ACK ;[-17]
sendCntAndReti:
    mov     r0, cnt         ;[-16]
    ldi     YL, 0           ;[-15] R0 address is 0
    ldi     YH, 0           ;[-14]
    ldi     cnt, 2          ;[-13]
;   rjmp    usbSendAndReti      fallthrough

;usbSend:
;pointer to data in 'Y'
;number of bytes in 'cnt' -- including sync byte [range 2 ... 12]
;uses: x1...x4, shift, cnt, Y
;Numbers in brackets are time since first bit of sync pattern is sent
usbSendAndReti:             ; 12 cycles until SOP

    ;_______________________________________________________________________________________
    ;SBIC – Skip if Bit in I/O Register is Cleared
    ;SBIS – Skip if Bit in I/O Register is Set
    ; USB_CFG_IOPORTNAME   B
    ; USBIN=USB_INPORT(B)  USBMINUS =USB_CFG_DMINUS_BIT=3
    ; USBOUT=USB_OUTPORT(USB_CFG_IOPORTNAME) 
    sbic    USBIN,2 ; kbd_Vcc Pin2 PROTOTIPO2  ;un solo ciclo????      funcionara????? 
    rjmp    doReturn; //anulo envio paquetes USB Saliendo directamente
    ;_______________________________________________________________________________________
    
    in      x2, USBDDR      ;[-12] //jejo lee en X2 la configuracion de los pins d+ y d-
    ori     x2, USBMASK     ;[-11] //jejo or x2 con mascara usb
    sbi     USBOUT, USBMINUS;[-10] prepare idle state; D+ and D- must have been 0 (no pullups)
    in      x1, USBOUT      ;[-8] port mirror for tx loop
    out     USBDDR, x2      ;[-7] <- acquire bus
; need not init x2 (bitstuff history) because sync starts with 0
    ldi     x4, USBMASK     ;[-6] exor mask
    ldi     shift, 0x80     ;[-5] sync byte is first byte sent
    ldi     bitStatus, 0xff ;[-4] init bit loop counter, works for up to 12 bytes
byteloop:
bitloop:
    sbrs    shift, 0        ;[8] [-3]
    eor     x1, x4          ;[9] [-2]
    out     USBOUT, x1      ;[10] [-1] <-- out
    ror     shift           ;[0]
    ror     x2              ;[1]
didStuffN:
    cpi     x2, 0xfc        ;[2]
    brcc    bitstuffN       ;[3]
    nop                     ;[4]
    subi    bitStatus, 37   ;[5] 256 / 7 ~=~ 37
    brcc    bitloop         ;[6] when we leave the loop, bitStatus has almost the initial value
    sbrs    shift, 0        ;[7]
    eor     x1, x4          ;[8]
    ror     shift           ;[9]
didStuff7:
    out     USBOUT, x1      ;[10] <-- out
    ror     x2              ;[0]
    cpi     x2, 0xfc        ;[1]
    brcc    bitstuff7       ;[2]
    ld      shift, y+       ;[3]
    dec     cnt             ;[5]
    brne    byteloop        ;[6]
;make SE0:
    cbr     x1, USBMASK     ;[7] prepare SE0 [spec says EOP may be 21 to 25 cycles]
    lds     x2, usbNewDeviceAddr;[8]
    lsl     x2              ;[10] we compare with left shifted address
    out     USBOUT, x1      ;[11] <-- out SE0 -- from now 2 bits = 22 cycles until bus idle
;2006-03-06: moved transfer of new address to usbDeviceAddr from C-Code to asm:
;set address only after data packet was sent, not after handshake
    subi    YL, 2           ;[0] Only assign address on data packets, not ACK/NAK in r0
    sbci    YH, 0           ;[1]
    breq    skipAddrAssign  ;[2]
    sts     usbDeviceAddr, x2; if not skipped: SE0 is one cycle longer
skipAddrAssign:
;end of usbDeviceAddress transfer
    ldi     x2, 1<<USB_INTR_PENDING_BIT;[4] int0 occurred during TX -- clear pending flag
    USB_STORE_PENDING(x2)   ;[5]
    ori     x1, USBIDLE     ;[6]
    in      x2, USBDDR      ;[7]
    cbr     x2, USBMASK     ;[8] set both pins to input
    mov     x3, x1          ;[9]
    cbr     x3, USBMASK     ;[10] configure no pullup on both pins
    ldi     x4, 4           ;[11]
se0Delay:
    dec     x4              ;[12] [15] [18] [21]
    brne    se0Delay        ;[13] [16] [19] [22]
    out     USBOUT, x1      ;[23] <-- out J (idle) -- end of SE0 (EOP signal)
    out     USBDDR, x2      ;[24] <-- release bus now
    out     USBOUT, x3      ;[25] <-- ensure no pull-up resistors are active
    rjmp    doReturn
