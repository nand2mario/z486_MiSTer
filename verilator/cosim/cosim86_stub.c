/*
 * cosim86_stub.c - the co-simulation API without a reference CPU
 *
 * Linked into the MiSTer sim when no 86Box checkout is present (see the
 * Makefile): the simulator builds and runs, and --cosim stops with a message.
 * Only cosim_init is reached; the rest exist for the linker.
 */
#include <stdio.h>
#include <stdlib.h>
#include "cosim86.h"

void cosim_init(uint32_t ram_bytes) {
    (void)ram_bytes;
    fprintf(stderr, "--cosim: this simulator was built without the 86Box reference "
                    "(22.z486_MiSTer/verilator/cosim/86Box is missing)\n");
    exit(1);
}

uint8_t *cosim_ram(void) { return NULL; }
void cosim_reset(void) {}
void cosim_set_a20(int enable) { (void)enable; }
int cosim_step(void) { return COSIM_ERROR; }
int cosim_step_rep_to(uint32_t count_left) { (void)count_left; return COSIM_ERROR; }
int cosim_interrupt(int vector) { (void)vector; return COSIM_ERROR; }
void cosim_adopt_flags(uint32_t dut_eflags) { (void)dut_eflags; }
uint32_t cosim_eip(void) { return 0; }
uint16_t cosim_cs(void) { return 0; }
uint32_t cosim_reg(int r) { (void)r; return 0; }
uint32_t cosim_eflags(void) { return 0; }
int cosim_at_rep_string(void) { return 0; }
int cosim_halted(void) { return 0; }
int cosim_last_fault(void) { return -1; }
uint64_t cosim_instructions(void) { return 0; }
void cosim_dut_io_read(uint16_t port, uint8_t val) { (void)port; (void)val; }
void cosim_dut_dev_read(uint32_t phys, uint8_t val) { (void)phys; (void)val; }
int cosim_dut_write(uint32_t phys, uint8_t val) { (void)phys; (void)val; return COSIM_ERROR; }
int cosim_dut_io_write(uint16_t port, uint8_t val) { (void)port; (void)val; return COSIM_ERROR; }
void cosim_dma_write(uint32_t phys, uint8_t val) { (void)phys; (void)val; }
void cosim_walker_write(uint32_t phys, uint8_t val) { (void)phys; (void)val; }
int cosim_writes_pending(void) { return 0; }
void cosim_arch(uint32_t *w) { (void)w; }
int cosim_snapshot_ok(void) { return 0; }
int cosim_save(void *file) { (void)file; return -1; }
int cosim_load(void *file) { (void)file; return -1; }
int cosim_save_noram(void *file) { (void)file; return -1; }
int cosim_load_noram(void *file) { (void)file; return -1; }
const char *cosim_error(void) { return "built without the co-simulation reference"; }
void cosim_dump_history(void) {}
void cosim_dump_history_from(uint64_t first, unsigned count) { (void)first; (void)count; }
void cosim_dump_writes(void) {}
