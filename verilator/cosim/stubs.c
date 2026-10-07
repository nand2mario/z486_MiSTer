/*
 * stubs.c - Standalone memory, IO, and platform stubs for the 86Box CPU core
 *
 * Provides flat 16MB memory model and no-op IO for running 86Box's
 * 386 CPU core as a standalone instruction-level test generator.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "cpu.h"
#include "x86.h"
#include "x86seg_common.h"
#include "x86_flags.h"
#include <86box/pic.h>

/* ============================================================
 * Memory - 16MB flat array
 * ============================================================ */

#include <86box/mem.h>
static uint8_t ram_backing[RAM_SIZE];
uint8_t *ram = ram_backing;
uint32_t mem_size = RAM_SIZE;
uint32_t rammask = RAM_SIZE - 1;

/* Memory access tracking for test delta computation */
#define MAX_MEM_LOG 4096

typedef struct {
    uint32_t addr;
    uint8_t  old_val;
    uint8_t  new_val;
} mem_write_t;

static mem_write_t mem_write_log[MAX_MEM_LOG];
static int mem_write_count = 0;

void mem_log_reset(void) {
    mem_write_count = 0;
}

int mem_log_get_count(void) {
    return mem_write_count;
}

mem_write_t *mem_log_get(int i) {
    return &mem_write_log[i];
}

static void mem_log_write(uint32_t addr, uint8_t old_val, uint8_t new_val) {
    if (old_val == new_val) return;
    if (mem_write_count < MAX_MEM_LOG) {
        mem_write_log[mem_write_count].addr = addr;
        mem_write_log[mem_write_count].old_val = old_val;
        mem_write_log[mem_write_count].new_val = new_val;
        mem_write_count++;
    }
}

void mem_log_add(uint32_t addr, uint8_t new_val) {
    if (mem_write_count < MAX_MEM_LOG) {
        mem_write_log[mem_write_count].addr = addr;
        mem_write_log[mem_write_count].old_val = 0;
        mem_write_log[mem_write_count].new_val = new_val;
        mem_write_count++;
    }
}

/* IO access tracking */
#define MAX_IO_LOG 256

typedef struct {
    uint16_t port;
    uint32_t val;
    int      size; /* 1=byte, 2=word, 4=dword */
    int      is_write;
} io_access_t;

static io_access_t io_log[MAX_IO_LOG];
static int io_log_count = 0;

void io_log_reset(void) {
    io_log_count = 0;
}

int io_log_get_count(void) {
    return io_log_count;
}

io_access_t *io_log_get(int i) {
    return &io_log[i];
}

/* ---- Memory read/write ----
 * Flat by default. The co-simulation sets iss_xlate to translate linear to
 * physical one byte at a time (so an access crossing a page faults on the
 * page it reaches); a translation fault sets cpu_state.abrt. Writes
 * translate every byte before storing any, so a faulting write changes
 * nothing, unless iss_split_write_first is set: then a write split across
 * pages stores its first page's bytes before the second page is translated,
 * as z486's paging unit sends the first bus cycle of a split access before
 * translating the second. Those bytes are kept in iss_partial_* so the
 * caller can keep them when it undoes the faulting instruction. */
uint32_t (*iss_xlate)(uint32_t lin, int write) = NULL;
int iss_code_fetch = 0;     /* set while translating an instruction fetch */
int iss_ss_chain = 1;
int iss_sel_push32 = 0;
int iss_split_write_first = 0;
int iss_partial_n = 0;
uint32_t iss_partial_pa[4];
uint8_t iss_partial_val[4];

/* Full-system hooks (cosim86.c). With iss_phys_hooks set, translation
 * yields the bus physical address; the read hook supplies device bytes and
 * the write hook sees every byte the CPU writes (returning 1 when it is not
 * stored in RAM). I/O goes to the in/out hooks. */
int iss_phys_hooks = 0;
int (*iss_phys_read_hook)(uint32_t phys, uint8_t *val) = NULL;
int (*iss_phys_write_hook)(uint32_t phys, uint8_t val) = NULL;
uint32_t (*iss_io_in_hook)(uint16_t port, int size) = NULL;
void (*iss_io_out_hook)(uint16_t port, int size, uint32_t val) = NULL;

static int xl(uint32_t *addr, int write) {
    if (iss_xlate) {
        /* A fault is pending: the first one wins (some ops read twice
         * before checking, e.g. BOUND), so do not translate again. */
        if (cpu_state.abrt)
            return 0;
        uint32_t p = iss_xlate(*addr, write);
        if (cpu_state.abrt)
            return 0;
        *addr = p;
    }
    if (!iss_phys_hooks)
        *addr &= rammask;
    return 1;
}

static uint32_t read_n(uint32_t addr, int n) {
    uint32_t v = 0;
    for (int i = 0; i < n; i++) {
        uint32_t a = addr + i;
        if (!xl(&a, 0))
            return 0xFFFFFFFF;
        uint8_t b;
        if (!(iss_phys_read_hook && iss_phys_read_hook(a, &b)))
            b = ram[a & rammask];
        v |= (uint32_t)b << (8 * i);
    }
    return v;
}

static void store_byte(uint32_t pa, uint8_t b) {
    if (iss_phys_write_hook && iss_phys_write_hook(pa, b))
        return;
    uint32_t r = pa & rammask;
    mem_log_write(r, ram[r], b);
    ram[r] = b;
}

static void write_n(uint32_t addr, uint32_t val, int n) {
    uint32_t pa[4];
    for (int i = 0; i < n; i++) {
        pa[i] = addr + i;
        if (!xl(&pa[i], 1)) {
            /* A fault on the second page of a split write. */
            if (iss_split_write_first && i > 0 && ((addr + i) & 0xFFF) == 0) {
                for (int j = 0; j < i && iss_partial_n < 4; j++) {
                    uint8_t b = (val >> (8 * j)) & 0xFF;
                    store_byte(pa[j], b);
                    iss_partial_pa[iss_partial_n] = pa[j];
                    iss_partial_val[iss_partial_n++] = b;
                }
            }
            return;
        }
    }
    for (int i = 0; i < n; i++)
        store_byte(pa[i], (val >> (8 * i)) & 0xFF);
}

uint8_t readmembl_2386(uint32_t addr) { return read_n(addr, 1); }
uint16_t readmemwl_2386(uint32_t addr) { return read_n(addr, 2); }
uint32_t readmemll_2386(uint32_t addr) { return read_n(addr, 4); }

uint64_t readmemql_2386(uint32_t addr) {
    uint32_t lo = readmemll_2386(addr);
    uint32_t hi = readmemll_2386(addr + 4);
    return (uint64_t)lo | ((uint64_t)hi << 32);
}

void writemembl_2386(uint32_t addr, uint8_t val) { write_n(addr, val, 1); }
void writememwl_2386(uint32_t addr, uint16_t val) { write_n(addr, val, 2); }
void writememll_2386(uint32_t addr, uint32_t val) { write_n(addr, val, 4); }

void writememql_2386(uint32_t addr, uint64_t val) {
    writememll_2386(addr, (uint32_t)val);
    if (!cpu_state.abrt)
        writememll_2386(addr + 4, (uint32_t)(val >> 32));
}

/* ---- No-MMU variants (just call flat versions) ---- */

uint8_t readmembl_no_mmut_2386(uint32_t addr, uint32_t a64) {
    (void)a64;
    return readmembl_2386(addr);
}

void writemembl_no_mmut_2386(uint32_t addr, uint32_t a64, uint8_t val) {
    (void)a64;
    writemembl_2386(addr, val);
}

uint16_t readmemwl_no_mmut_2386(uint32_t addr, uint32_t *a64) {
    (void)a64;
    return readmemwl_2386(addr);
}

void writememwl_no_mmut_2386(uint32_t addr, uint32_t *a64, uint16_t val) {
    (void)a64;
    writememwl_2386(addr, val);
}

uint32_t readmemll_no_mmut_2386(uint32_t addr, uint32_t *a64) {
    (void)a64;
    return readmemll_2386(addr);
}

void writememll_no_mmut_2386(uint32_t addr, uint32_t *a64, uint32_t val) {
    (void)a64;
    writememll_2386(addr, val);
}

uint32_t do_mmutranslate_2386(uint32_t addr, uint32_t a64, int size, int write) {
    (void)a64; (void)size; (void)write;
    return addr; /* identity mapping */
}

/* ---- Code fetch cache (pccache) ---- */

uint32_t pccache = 0xFFFFFFFF;
uint8_t *pccache2 = NULL;

uint8_t *getpccache(uint32_t a) {
    /* Return pointer such that pccache2[addr] gives the byte at linear addr
     * within a's page. */
    if (!iss_xlate)
        return ram;
    uint32_t page = a & ~0xFFFu, p = page;
    iss_code_fetch = 1;
    int ok = xl(&p, 0);
    iss_code_fetch = 0;
    if (!ok)
        return ram;
    return ram + (intptr_t)(p & rammask) - (intptr_t)page;
}

/* ============================================================
 * IO - Return 0xFF for reads, log writes
 * ============================================================ */

uint8_t inb(uint16_t port) {
    if (iss_io_in_hook)
        return (uint8_t)iss_io_in_hook(port, 1);
    if (io_log_count < MAX_IO_LOG) {
        io_log[io_log_count].port = port;
        io_log[io_log_count].val = 0xFF;
        io_log[io_log_count].size = 1;
        io_log[io_log_count].is_write = 0;
        io_log_count++;
    }
    return 0xFF;
}

uint16_t inw(uint16_t port) {
    if (iss_io_in_hook)
        return (uint16_t)iss_io_in_hook(port, 2);
    if (io_log_count < MAX_IO_LOG) {
        io_log[io_log_count].port = port;
        io_log[io_log_count].val = 0xFFFF;
        io_log[io_log_count].size = 2;
        io_log[io_log_count].is_write = 0;
        io_log_count++;
    }
    return 0xFFFF;
}

uint32_t inl(uint16_t port) {
    if (iss_io_in_hook)
        return (uint32_t)iss_io_in_hook(port, 4);
    if (io_log_count < MAX_IO_LOG) {
        io_log[io_log_count].port = port;
        io_log[io_log_count].val = 0xFFFFFFFF;
        io_log[io_log_count].size = 4;
        io_log[io_log_count].is_write = 0;
        io_log_count++;
    }
    return 0xFFFFFFFF;
}

void outb(uint16_t port, uint8_t val) {
    if (iss_io_out_hook) {
        iss_io_out_hook(port, 1, val);
        return;
    }
    if (io_log_count < MAX_IO_LOG) {
        io_log[io_log_count].port = port;
        io_log[io_log_count].val = val;
        io_log[io_log_count].size = 1;
        io_log[io_log_count].is_write = 1;
        io_log_count++;
    }
}

void outw(uint16_t port, uint16_t val) {
    if (iss_io_out_hook) {
        iss_io_out_hook(port, 2, val);
        return;
    }
    if (io_log_count < MAX_IO_LOG) {
        io_log[io_log_count].port = port;
        io_log[io_log_count].val = val;
        io_log[io_log_count].size = 2;
        io_log[io_log_count].is_write = 1;
        io_log_count++;
    }
}

void outl(uint16_t port, uint32_t val) {
    if (iss_io_out_hook) {
        iss_io_out_hook(port, 4, val);
        return;
    }
    if (io_log_count < MAX_IO_LOG) {
        io_log[io_log_count].port = port;
        io_log[io_log_count].val = val;
        io_log[io_log_count].size = 4;
        io_log[io_log_count].is_write = 1;
        io_log_count++;
    }
}

/* IO permission check - always allow */
__attribute__((weak)) int checkio(uint32_t port, int mask) {
    (void)port; (void)mask;
    return 0;  /* 0 = allowed */
}

/* ============================================================
 * Platform stubs - globals that 86Box code references
 * ============================================================ */

/* Timer */
uint64_t timer_target = 0xFFFFFFFFFFFFFFFFULL;
uint64_t tsc = 0;

/* PIC */
pic_t pic = { .int_pending = 0 };
pic_t pic2 = { .int_pending = 0 };

/* NMI */
int nmi = 0;
int nmi_auto_clear = 0;
int nmi_enable = 1;

/* read_type for fastread functions */
int read_type = 4;

/* CPU configuration */
int cpu_16bitbus = 0;
int cpu_prefetch_cycles = 0;
int cpu_flush_pending = 0;
int cpu_old_paging = 0;
int cpu_end_block_after_ins = 0;
int is386 = 1;
int cpu_init = 0;

/* Misc globals referenced by 86Box */
int alt_access = 0;
int cpl_override = 0;
int new_ne = 0;
int in_sys = 0;
int unmask_a20_in_smm = 0;
uint32_t old_rammask = 0xFFFFFFFF;
int soft_reset_mask = 0;
int smi_latched = 0;
int smm_in_hlt = 0;
int smi_block = 0;
int prefetch_prefixes = 0;
int rf_flag_no_clear = 0;
int tempc;
int timetolive = 0;

uint32_t oldds, oldss, olddslimit, oldsslimit, olddslimitw, oldsslimitw;
int high_page = 0;
int is_compare = 0;
uint32_t addr64a[8];
uint32_t oxpc;
uint32_t rmdat32;
uint32_t addr64, addr64_2;
x86seg _oldds;
uint8_t rep_op = 0;
uint8_t is_smint = 0;
uint16_t io_port = 0;
uint32_t io_val = 0;

/* x86.c globals */
uint8_t opcode;
uint8_t znptable8[256];
uint16_t znptable16[65536];
uint16_t zero = 0;
uint32_t easeg;
int x86_was_reset = 0;
int soft_reset_pci = 0;
int trap = 0;
int reset_on_hlt = 0;
int hlt_reset_pending = 0;
int fpu_cycles = 0;
int in_lock = 0;
int indump = 0;
uint64_t xt_cpu_multi = 1;

/* Codegen */
int codegen_flat_ss = 0;
int codegen_flat_ds = 0;
int codegen_flags_changed = 0;

/* FPU stubs */
#include "x87_sf.h"
int fpu_softfloat = 0;
fpu_state_t fpu_state;
uint32_t x87_pc_off = 0, x87_op_off = 0;
uint16_t x87_pc_seg = 0, x87_op_seg = 0;
uint16_t x87_gettag(void) { return 0xFFFF; }
void picint(uint32_t mask) { (void)mask; }

/* Non-_2386 memory functions (called directly by some 386_common.h code) */
void writememql(uint32_t addr, uint64_t val) { writememql_2386(addr, val); }
uint64_t readmemql(uint32_t addr) { return readmemql_2386(addr); }
void writemembl(uint32_t addr, uint8_t val) { writemembl_2386(addr, val); }
uint8_t readmembl(uint32_t addr) { return readmembl_2386(addr); }
void writememwl(uint32_t addr, uint16_t val) { writememwl_2386(addr, val); }
uint16_t readmemwl(uint32_t addr) { return readmemwl_2386(addr); }
void writememll(uint32_t addr, uint32_t val) { writememll_2386(addr, val); }
uint32_t readmemll(uint32_t addr) { return readmemll_2386(addr); }

/* flushmmucache_nopc (called from x86_ops_misc.h) */
void flushmmucache_nopc(void) { }

/* Mod1 addressing tables (declared in x86.h) */
uint16_t *mod1add[2][8];
uint32_t *mod1seg[8];

/* Prefetch stubs */
void prefetch_run(int instr_cycles, int bytes, int modrm,
                  int reads, int reads_l, int writes, int writes_l, int ea32) {
    (void)instr_cycles; (void)bytes; (void)modrm;
    (void)reads; (void)reads_l; (void)writes; (void)writes_l; (void)ea32;
}

void prefetch_flush(void) { }

/* cpu.c stubs */
void cpu_set_edx(void) { }
void softresetx86(void) { x86_was_reset = 1; }
int cpu_386_check_instruction_fault(void) { return 0; }

/* SMM stub */
void enter_smm_check(int in_hlt) { (void)in_hlt; }

/* ============================================================
 * Additional linker symbol stubs
 * ============================================================ */

/* cpu_state - THE global CPU state */
cpu_state_t cpu_state;

/* Descriptor tables */
x86seg gdt, idt, ldt, tr;
uint32_t cr2 = 0, cr3 = 0, cr4 = 0;
uint32_t dr[8] = {0};
uint32_t use32 = 0;
int stack32 = 0;
int oldcpl = 0;
int optype = 0;
int inttype = 0;
uint16_t oldcs = 0;
uint32_t rmdat = 0;
uint32_t abrt_error = 0;

/* Opcode tables */
int opcode_has_modrm[256] = {
    /*       0 1 2 3 4 5 6 7 8 9 a b c d e f */
    /*00*/   1,1,1,1,0,0,0,0,1,1,1,1,0,0,0,0,
    /*10*/   1,1,1,1,0,0,0,0,1,1,1,1,0,0,0,0,
    /*20*/   1,1,1,1,0,0,0,0,1,1,1,1,0,0,0,0,
    /*30*/   1,1,1,1,0,0,0,0,1,1,1,1,0,0,0,0,
    /*40*/   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    /*50*/   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    /*60*/   0,0,1,1,0,0,0,0,0,1,0,1,0,0,0,0,
    /*70*/   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    /*80*/   1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    /*90*/   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    /*a0*/   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    /*b0*/   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    /*c0*/   1,1,0,0,1,1,1,1,0,0,0,0,0,0,0,0,
    /*d0*/   1,1,1,1,0,0,0,0,1,1,1,1,1,1,1,1,
    /*e0*/   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    /*f0*/   0,0,0,0,0,0,1,1,0,0,0,0,0,0,1,1
};

/* Bytes an instruction fetch may take at a page edge (86Box's 386_common.c
 * table: an approximation here dropped displacements of page-crossing
 * instructions). */
int opcode_length[256] = { 3, 3, 3, 3, 3, 3, 1, 1, 3, 3, 3, 3, 3, 3, 1, 3,   /* 0x0x */
                           3, 3, 3, 3, 3, 3, 1, 1, 3, 3, 3, 3, 3, 3, 1, 1,   /* 0x1x */
                           3, 3, 3, 3, 3, 3, 1, 1, 3, 3, 3, 3, 3, 3, 1, 1,   /* 0x2x */
                           3, 3, 3, 3, 3, 3, 1, 1, 3, 3, 3, 3, 3, 3, 1, 1,   /* 0x3x */
                           1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,   /* 0x4x */
                           1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,   /* 0x5x */
                           1, 1, 3, 3, 1, 1, 1, 1, 3, 3, 2, 3, 1, 1, 1, 1,   /* 0x6x */
                           2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,   /* 0x7x */
                           3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,   /* 0x8x */
                           1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 1, 1, 1, 1, 1,   /* 0x9x */
                           3, 3, 3, 3, 1, 1, 1, 1, 2, 3, 1, 1, 1, 1, 1, 1,   /* 0xax */
                           2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3,   /* 0xbx */
                           3, 3, 3, 1, 3, 3, 3, 3, 3, 1, 3, 1, 1, 2, 1, 1,   /* 0xcx */
                           3, 3, 3, 3, 2, 2, 1, 1, 3, 3, 3, 3, 3, 3, 3, 3,   /* 0xdx */
                           2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 2, 1, 1, 1, 1,   /* 0xex */
                           1, 1, 1, 1, 1, 1, 3, 3, 1, 1, 1, 1, 1, 1, 3, 3 };

/* Weak: the including tool may supply the Intel486 LOCK rules. */
__attribute__((weak)) int is_lock_legal(uint32_t fetchdat) { (void)fetchdat; return 0; }

/* Timing constants - all set to generic values */
int timing_rr = 2, timing_rm = 6, timing_mr = 7;
int timing_mm = 6, timing_rml = 6, timing_mml = 7;
int timing_bt = 1, timing_bnt = 1;
int timing_int_rm = 37, timing_iret_rm = 22;
int timing_call_rm = 7, timing_retf_rm = 15;
int timing_jmp_rm = 7;
int timing_int_pm = 59, timing_int_pm_outer = 99;
int timing_iret_pm = 22, timing_iret_pm_outer = 38;
int timing_iret_v86 = 60;
int timing_call_pm = 20, timing_call_pm_gate = 35, timing_call_pm_gate_inner = 69;
int timing_retf_pm = 18, timing_retf_pm_outer = 32;
int timing_jmp_pm = 21, timing_jmp_pm_gate = 32;

/* EAL pointers */
uint32_t *eal_r = NULL, *eal_w = NULL;

/* CPU feature detection stubs */
int is286 = 0, is486 = 0, is586 = 0, is6117 = 0;
int isibm486 = 0, hascache = 0;
int cpu_iscyrix = 0, cpu_isintel = 0;
int cpu_inited = 0;
uint64_t cpu_CR4_mask = 0;
uint16_t cpu_cur_status = 0;
int CPUID = 0;
int cpu_cache_int_enabled = 0;
int cpu_cache_ext_enabled = 0;
uint32_t addr64a_2[8] = {0};
uint8_t _cache[2048] = {0};
uint32_t _tr[8] = {0};
uint32_t cache_index = 0;

/* CPU model stubs */
CPU cpu_s_dummy = {0};
CPU *cpu_s = &cpu_s_dummy;

/* mul/div helpers - from 386_common.c */
int divl(uint32_t val) {
    uint64_t num = ((uint64_t)EDX << 32) | EAX;
    uint64_t quo, rem;
    if (val == 0) { x86_int(0); return 1; }
    quo = num / val;
    rem = num % val;
    if (quo > 0xFFFFFFFF) { x86_int(0); return 1; }
    EAX = (uint32_t)quo;
    EDX = (uint32_t)rem;
    return 0;
}

int idivl(int32_t val) {
    int64_t num = ((int64_t)(int32_t)EDX << 32) | EAX;
    int64_t quo, rem;
    if (val == 0) { x86_int(0); return 1; }
    quo = num / val;
    rem = num % val;
    if (quo > 2147483647LL || quo < -2147483648LL) { x86_int(0); return 1; }
    EAX = (uint32_t)(int32_t)quo;
    EDX = (uint32_t)(int32_t)rem;
    return 0;
}

/* x86_int - software interrupt
 * Forward declaration of pmodeint_2386 since we don't include 386_common.h here */
extern void pmodeint_2386(int num, int soft);
extern void loadcs_2386(uint16_t seg);

static void deliver_int(int num) {
    /* In protected mode, call pmodeint */
    if (msw & 1) {
        pmodeint_2386(num, 1);
    } else {
        /* Real mode interrupt - simplified */
        uint32_t addr = (num << 2) + idt.base;
        uint32_t ss_base = cpu_state.seg_ds.base; /* Use SS base */
        writememwl_2386(ss_base + ((SP - 2) & 0xFFFF), cpu_state.flags);
        writememwl_2386(ss_base + ((SP - 4) & 0xFFFF), CS);
        writememwl_2386(ss_base + ((SP - 6) & 0xFFFF), cpu_state.pc);
        SP -= 6;
        cpu_state.flags &= ~I_FLAG;
        cpu_state.flags &= ~T_FLAG;
        cpu_state.pc = readmemwl_2386(0 + addr);
        loadcs_2386(readmemwl_2386(0 + addr + 2));
    }
}

/* A fault: the i486 PRM (9.3.3, 11.3.1.1) and the 386 microcode set RF in the
 * EFLAGS image pushed for every fault; the gate entry clears it again. */
__attribute__((weak)) void x86_int(int num) {
    cpu_state.eflags |= RF_FLAG;
    deliver_int(num);
    cpu_state.eflags &= ~RF_FLAG;
}

__attribute__((weak)) void x86_int_sw(int num) { deliver_int(num); }
__attribute__((weak)) int x86_int_sw_rm(int num) { deliver_int(num); return 0; }
__attribute__((weak)) void x86illegal(void) { x86_int(6); }

/* CPUID */
int cpu_has_feature(int feature) { (void)feature; return 0; }
void cpu_CPUID(void) { /* 386 doesn't have CPUID */ }
void cpu_RDMSR(void) { x86gpf(NULL, 0); }
void cpu_WRMSR(void) { x86gpf(NULL, 0); }
void cpu_update_waitstates(void) { }

/* Flags */
void cpu_386_flags_extract(void) {
    flags_extract();
}
void cpu_386_flags_rebuild(void) {
    flags_rebuild();
}

/* Memory physical access stubs */
uint32_t mem_readl_phys(uint32_t addr) { return readmemll_2386(addr); }
void mem_writel_phys(uint32_t addr, uint32_t val) { writememll_2386(addr, val); }

/* SMM */
void enter_smm(int in_hlt) { (void)in_hlt; }
void leave_smm(void) { }
void flushmmucache_write(uint32_t addr) { (void)addr; }

/* Opcode dispatch tables: defined by the OP_TABLE macros in 386_ops.h, included
 * through iss_glue.h */

/* ZNP table initialization */
void x86_init_znp_tables(void) {
    for (int i = 0; i < 256; i++) {
        int p = 0;
        for (int j = 0; j < 8; j++)
            if (i & (1 << j)) p++;
        znptable8[i] = (p & 1) ? 0 : 4; /* P_FLAG = 0x04 */
    }
    for (int i = 0; i < 65536; i++) {
        int p = 0;
        for (int j = 0; j < 8; j++)  /* only low 8 bits affect PF */
            if (i & (1 << j)) p++;
        znptable16[i] = (p & 1) ? 0 : 4;
    }
}

/* ============================================================
 * Upstream symbols the 386 build references but defines elsewhere
 * ============================================================ */
int io_waitstates = 0;
int reg_op_waitstates = 0;

/* From upstream x86seg.c, where it is built only without OPS_286_386
 * (86Box compiles x86seg.c twice; this build compiles the 386 variant). */
void
do_seg_load(x86seg *s, uint16_t *segdat)
{
    s->limit = segdat[0] | ((segdat[3] & 0x000f) << 16);
    if (segdat[3] & 0x0080)
        s->limit = (s->limit << 12) | 0xfff;
    s->base = segdat[1] | ((segdat[2] & 0x00ff) << 16);
    if (is386)
        s->base |= ((segdat[3] >> 8) << 24);
    s->access  = segdat[2] >> 8;
    s->ar_high = segdat[3] & 0xff;

    if (((segdat[2] & 0x1800) != 0x1000) || !(segdat[2] & (1 << 10))) {
        /* Expand-down */
        s->limit_high = s->limit;
        s->limit_low  = 0;
    } else {
        s->limit_high = (segdat[3] & 0x40) ? 0xffffffff : 0xffff;
        s->limit_low  = s->limit + 1;
    }

    if (s == &cpu_state.seg_ds) {
        if ((s->base == 0) && (s->limit_low == 0) && (s->limit_high == 0xffffffff))
            cpu_cur_status &= ~CPU_STATUS_NOTFLATDS;
        else
            cpu_cur_status |= CPU_STATUS_NOTFLATDS;
    }
    if (s == &cpu_state.seg_ss) {
        if ((s->base == 0) && (s->limit_low == 0) && (s->limit_high == 0xffffffff))
            cpu_cur_status &= ~CPU_STATUS_NOTFLATSS;
        else
            cpu_cur_status |= CPU_STATUS_NOTFLATSS;
    }
}
