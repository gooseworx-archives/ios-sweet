/*
 * sweet boot shim entry: arm64 Linux Image header so Qualcomm ABL treats
 * us like a kernel. ABL enters at EL1, MMU/D-cache off, x0 = DTB pointer.
 */
	.section .text.head, "ax"
	.globl _head
_head:
	b	_start			/* code0 */
	.long	0			/* code1 */
	.quad	0			/* text_offset */
	.quad	_end			/* image_size (linked at 0) */
	.quad	0xa			/* flags: LE, 4K pages, place anywhere */
	.quad	0			/* res2 */
	.quad	0			/* res3 */
	.quad	0			/* res4 */
	.ascii	"ARM\x64"		/* magic */
	.long	0			/* res5 (PE offset) */

	.text
	.globl _start
_start:
	msr	daifset, #0xf
	mov	x19, x0			/* Preserve DTB pointer from ABL */

	/* Check CurrentEL: Google Tensor ABL enters at EL2 */
	mrs	x0, CurrentEL
	cmp	x0, #(2 << 2)		/* 0x8 = EL2 */
	b.ne	.Lrunning_el1

	/* Set vectors for EL2 so any trap doesn't crash to ABL */
	adr	x1, vectors
	msr	vbar_el2, x1

	/* HCR_EL2: RW=1 (64-bit EL1), all traps disabled */
	mov	x0, #(1 << 31)
	msr	hcr_el2, x0

	/* CNTHCTL_EL2: allow EL1 access to timers */
	mov	x0, #0x3
	msr	cnthctl_el2, x0
	msr	cntvoff_el2, xzr

	/* CPTR_EL2: don't trap FP/SIMD to EL2 */
	msr	cptr_el2, xzr

	/* Enable GIC System Register Access at EL2 if available */
	mrs	x0, id_aa64pfr0_el1
	ubfx	x0, x0, #24, #4
	cbz	x0, 1f
	mov	x0, #0xf		/* SRE=1, DFB=1, DIB=1, Enable=1 */
	msr	icc_sre_el2, x0
1:
	/* Prepare SPSR_EL2 for ERET to EL1 with SP_EL1 (EL1h = 0b0101) */
	mov	x0, #0x3c5		/* D, A, I, F masked, mode EL1h */
	msr	spsr_el2, x0

	adr	x0, .Lrunning_el1
	msr	elr_el2, x0
	isb
	eret

.Lrunning_el1:
	msr	daifset, #0xf
	msr	spsel, #1
	adr	x1, _stack_top
	mov	sp, x1
	adr	x1, vectors
	msr	vbar_el1, x1
	isb

	/* zero .bss */
	adr	x1, _bss_start
	adr	x2, _bss_end
2:	cmp	x1, x2
	b.hs	3f
	str	xzr, [x1], #8
	b	2b
3:	mov	x0, x19
	bl	shim_main
4:	wfe
	b	4b

/* PSCI CPU_ON target. x0 = context id = cpu index (1..7). */
	.globl secondary_entry
secondary_entry:
	msr	daifset, #0xf
	mrs	x2, CurrentEL
	cmp	x2, #(2 << 2)
	b.ne	.Lsec_el1

	/* Drop secondary core from EL2 to EL1 */
	adr	x1, vectors
	msr	vbar_el2, x1
	mov	x2, #(1 << 31)
	msr	hcr_el2, x2
	mov	x2, #0x3
	msr	cnthctl_el2, x2
	msr	cntvoff_el2, xzr
	msr	cptr_el2, xzr
	mrs	x2, id_aa64pfr0_el1
	ubfx	x2, x2, #24, #4
	cbz	x2, 5f
	mov	x2, #0xf
	msr	icc_sre_el2, x2
5:
	mov	x2, #0x3c5
	msr	spsr_el2, x2
	adr	x2, .Lsec_el1
	msr	elr_el2, x2
	isb
	eret

.Lsec_el1:
	msr	daifset, #0xf
	msr	spsel, #1
	adr	x1, _sec_stacks
	add	x1, x1, x0, lsl #12
	add	x1, x1, #0x1000
	mov	sp, x1
	adr	x1, vectors
	msr	vbar_el1, x1
	isb
	bl	secondary_main
6:	wfe
	b	6b

/*
 * Exception vectors. Each slot stashes x29/x30, loads its slot number
 * and jumps to the common path, which saves x0-x28 and calls
 * exc_handler(slot, regs). IRQs return; everything else ends in the
 * on-screen panic.
 */
.macro vent slot
	.balign	0x80
	stp	x29, x30, [sp, #-16]!
	mov	x29, #\slot
	b	exc_common
.endm

	.balign	0x800
	.globl vectors
vectors:
	vent 0
	vent 1
	vent 2
	vent 3
	vent 4
	vent 5
	vent 6
	vent 7
	vent 8
	vent 9
	vent 10
	vent 11
	vent 12
	vent 13
	vent 14
	vent 15

exc_common:
	sub	sp, sp, #(30 * 8)
	stp	x0, x1, [sp, #0]
	stp	x2, x3, [sp, #16]
	stp	x4, x5, [sp, #32]
	stp	x6, x7, [sp, #48]
	stp	x8, x9, [sp, #64]
	stp	x10, x11, [sp, #80]
	stp	x12, x13, [sp, #96]
	stp	x14, x15, [sp, #112]
	stp	x16, x17, [sp, #128]
	stp	x18, x19, [sp, #144]
	stp	x20, x21, [sp, #160]
	stp	x22, x23, [sp, #176]
	stp	x24, x25, [sp, #192]
	stp	x26, x27, [sp, #208]
	str	x28, [sp, #224]
	mov	x0, x29
	mov	x1, sp
	bl	exc_handler
	ldp	x0, x1, [sp, #0]
	ldp	x2, x3, [sp, #16]
	ldp	x4, x5, [sp, #32]
	ldp	x6, x7, [sp, #48]
	ldp	x8, x9, [sp, #64]
	ldp	x10, x11, [sp, #80]
	ldp	x12, x13, [sp, #96]
	ldp	x14, x15, [sp, #112]
	ldp	x16, x17, [sp, #128]
	ldp	x18, x19, [sp, #144]
	ldp	x20, x21, [sp, #160]
	ldp	x22, x23, [sp, #176]
	ldp	x24, x25, [sp, #192]
	ldp	x26, x27, [sp, #208]
	ldr	x28, [sp, #224]
	add	sp, sp, #(30 * 8)
	ldp	x29, x30, [sp], #16
	eret
