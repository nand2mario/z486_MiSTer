/*
 * cosim86.h - 86Box CPU core as the reference for full-system co-simulation
 *
 * The host (the MiSTer Verilator sim) steps the reference once per z486
 * instruction and feeds it what the system supplies: I/O read data, device
 * (A0000-BFFFF) read data, hardware interrupt vectors, DMA writes and the
 * page walker's A/D updates. The reference's memory and I/O writes are
 * checked against z486's in program order.
 */
#ifndef COSIM86_H
#define COSIM86_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

enum {
    COSIM_OK = 0,
    COSIM_STALL = 1,    /* needs device read data z486 has not returned yet */
    COSIM_ERROR = 2,    /* see cosim_error() */
};

void cosim_init(uint32_t ram_bytes);
uint8_t *cosim_ram(void);
void cosim_reset(void);             /* CPU reset; RAM is kept */
void cosim_set_a20(int enable);

/* Execute the instruction at the current CS:EIP (with its fault, if any). */
int cosim_step(void);
/* A REP string that z486 interrupted: run it until (E)CX == count_left. */
int cosim_step_rep_to(uint32_t count_left);
/* A hardware interrupt at this instruction boundary. */
int cosim_interrupt(int vector);
/* z486's EFLAGS before the next instruction: adopt the bits the Intel486 PRM
 * leaves undefined after the last one (z486 and 86Box differ there). */
void cosim_adopt_flags(uint32_t dut_eflags);

uint32_t cosim_eip(void);
uint16_t cosim_cs(void);
uint32_t cosim_reg(int r);          /* 0..7: EAX ECX EDX EBX ESP EBP ESI EDI */
uint32_t cosim_eflags(void);
int cosim_at_rep_string(void);      /* the instruction at CS:EIP is a REP string op */
int cosim_halted(void);             /* the last instruction was HLT */
int cosim_last_fault(void);         /* vector the last step delivered, or -1 */
uint64_t cosim_instructions(void);

/* z486 events, in the order z486 performs them. */
void cosim_dut_io_read(uint16_t port, uint8_t val);
void cosim_dut_dev_read(uint32_t phys, uint8_t val);
int  cosim_dut_write(uint32_t phys, uint8_t val);       /* COSIM_OK or COSIM_ERROR */
int  cosim_dut_io_write(uint16_t port, uint8_t val);
void cosim_dma_write(uint32_t phys, uint8_t val);       /* a bus master's write */
void cosim_walker_write(uint32_t phys, uint8_t val);    /* z486's A/D update */
int  cosim_writes_pending(void);    /* reference writes z486 has not done yet */

/* Portable snapshots: the architectural state z486 is restored to, as the
 * words of z486_mister_sim.sv's cosim_load_arch (COSIM_ARCH_WORDS of them). */
#define COSIM_ARCH_WORDS 43
void cosim_arch(uint32_t *w);
/* A snapshot may be taken before the next instruction: every write matched,
 * no HLT, and no interrupt shadow (STI, MOV SS, POP SS just ran). */
int cosim_snapshot_ok(void);

/* Checkpoints: the whole reference (CPU, RAM, queues) between clocks. */
int cosim_save(void *file);         /* a FILE *; 0 on success */
int cosim_load(void *file);
/* The same without RAM, which the caller saves and restores by cosim_ram(). */
int cosim_save_noram(void *file);
int cosim_load_noram(void *file);

const char *cosim_error(void);
void cosim_dump_history(void);      /* recent instructions, to stdout */
/* Instructions from #first, those still in the history (the last 64). */
void cosim_dump_history_from(uint64_t first, unsigned count);
void cosim_dump_writes(void);       /* the reference's outstanding writes */

#ifdef __cplusplus
}
#endif
#endif
