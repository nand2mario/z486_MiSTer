/*
 * iss_glue.h - 86Box CPU core glue for cosim86.c
 *
 * Includes, EA fetch, the opcode tables (386 one-byte, 486 0F), mod tables
 * and init_seg. The including file defines
 * iss_probe(), which the do_mmut_* overrides call.
 */
#ifndef ISS_GLUE_H
#define ISS_GLUE_H
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <wchar.h>
#include <math.h>
#include <time.h>
#include <getopt.h>
#include <sys/stat.h>

#ifndef INFINITY
#define INFINITY (__builtin_inff())
#endif

#define HAVE_STDARG_H
#include <86box/86box.h>
#include "cpu.h"
#include "x86.h"
#include "x86_ops.h"
#include "x86seg_common.h"
#include <86box/io.h>
#include <86box/nmi.h>
#include <86box/mem.h>
#include <86box/pic.h>
#include <86box/timer.h>
#include <86box/plat_fallthrough.h>
#include <86box/plat_unused.h>

#ifndef OPS_286_386
#define OPS_286_386
#endif

#include "x86seg.h"
#include "386_common.h"

/* Override do_mmut_* from 386_common.h: they translate an access before an
 * op changes any state (a REP element, a CMPS operand), so a fault is
 * caught first. Here they probe the page walk; the access itself
 * translates again through stubs.c's hook. */
static void iss_probe(uint32_t lin, int n, int write);
#undef do_mmut_rb
#undef do_mmut_rw
#undef do_mmut_rl
#undef do_mmut_rb2
#undef do_mmut_rw2
#undef do_mmut_rl2
#undef do_mmut_wb
#undef do_mmut_ww
#undef do_mmut_wl
#define do_mmut_rb(s, a, b)  iss_probe((s) + (a), 1, 0)
#define do_mmut_rw(s, a, b)  iss_probe((s) + (a), 2, 0)
#define do_mmut_rl(s, a, b)  iss_probe((s) + (a), 4, 0)
#define do_mmut_rb2(s, a, b) iss_probe((s) + (a), 1, 0)
#define do_mmut_rw2(s, a, b) iss_probe((s) + (a), 2, 0)
#define do_mmut_rl2(s, a, b) iss_probe((s) + (a), 4, 0)
#define do_mmut_wb(s, a, b)  iss_probe((s) + (a), 1, 1)
#define do_mmut_ww(s, a, b)  iss_probe((s) + (a), 2, 1)
#define do_mmut_wl(s, a, b)  iss_probe((s) + (a), 4, 1)

/* Additional globals referenced by 86Box op code */
extern int high_page;
extern uint32_t addr64a[8];
extern int cpu_use_dynarec;
int cpu_use_dynarec = 0;
extern int cpu_use_exec;
int cpu_use_exec = 0;
extern uintptr_t old_rl2;
uintptr_t old_rl2 = 0;
extern int uncached;
int uncached = 0;

/* WAIT/FWAIT (0x9B) with no FPU: #NM when CR0.TS and CR0.MP are both set. */
static int opWAIT(uint32_t fetchdat) {
    (void)fetchdat;
    if ((cpu_state.CR0.l & 0x0A) == 0x0A) { x86_int(7); return 1; }
    return 0;
}

/* ============================================================
 * Opcode tables - from 386.c / 386_ops.h
 * ============================================================ */

#undef CPU_BLOCK_END
#define CPU_BLOCK_END()

#define getbytef()          \
    ((uint8_t) (fetchdat)); \
    cpu_state.pc++
#define getwordf()           \
    ((uint16_t) (fetchdat)); \
    cpu_state.pc += 2
#define getbyte2f()              \
    ((uint8_t) (fetchdat >> 8)); \
    cpu_state.pc++
#define getword2f()               \
    ((uint16_t) (fetchdat >> 8)); \
    cpu_state.pc += 2

static __inline void
fetch_ea_32_long(uint32_t rmdat)
{
    easeg         = cpu_state.ea_seg->base;
    if (cpu_rm == 4) {
        uint8_t sib = rmdat >> 8;
        switch (cpu_mod) {
            case 0:
                cpu_state.eaaddr = cpu_state.regs[sib & 7].l;
                cpu_state.pc++;
                break;
            case 1:
                cpu_state.pc++;
                cpu_state.eaaddr = ((uint32_t) (int8_t) getbyte()) + cpu_state.regs[sib & 7].l;
                break;
            case 2:
                cpu_state.eaaddr = (fastreadl(cs + cpu_state.pc + 1)) + cpu_state.regs[sib & 7].l;
                cpu_state.pc += 5;
                break;
        }
        if ((sib & 7) == 5 && !cpu_mod)
            cpu_state.eaaddr = getlong();
        else if ((sib & 6) == 4 && !cpu_state.ssegs) {
            easeg            = ss;
            cpu_state.ea_seg = &cpu_state.seg_ss;
        }
        if (((sib >> 3) & 7) != 4)
            cpu_state.eaaddr += cpu_state.regs[(sib >> 3) & 7].l << (sib >> 6);
    } else {
        cpu_state.eaaddr = cpu_state.regs[cpu_rm].l;
        if (cpu_mod) {
            if (cpu_rm == 5 && !cpu_state.ssegs) {
                easeg            = ss;
                cpu_state.ea_seg = &cpu_state.seg_ss;
            }
            if (cpu_mod == 1) {
                cpu_state.eaaddr += ((uint32_t) (int8_t) (rmdat >> 8));
                cpu_state.pc++;
            } else {
                cpu_state.eaaddr += getlong();
            }
        } else if (cpu_rm == 5) {
            cpu_state.eaaddr = getlong();
        }
    }
}

static __inline void
fetch_ea_16_long(uint32_t rmdat)
{
    easeg         = cpu_state.ea_seg->base;
    if (!cpu_mod && cpu_rm == 6) {
        cpu_state.eaaddr = getword();
    } else {
        switch (cpu_mod) {
            case 0:
                cpu_state.eaaddr = 0;
                break;
            case 1:
                cpu_state.eaaddr = (uint16_t) (int8_t) (rmdat >> 8);
                cpu_state.pc++;
                break;
            case 2:
                cpu_state.eaaddr = getword();
                break;
        }
        cpu_state.eaaddr += (*mod1add[0][cpu_rm]) + (*mod1add[1][cpu_rm]);
        if (mod1seg[cpu_rm] == &ss && !cpu_state.ssegs) {
            easeg            = ss;
            cpu_state.ea_seg = &cpu_state.seg_ss;
        }
        cpu_state.eaaddr &= 0xFFFF;
    }
}

#define fetch_ea_16(rmdat)       \
    cpu_state.pc++;              \
    cpu_mod = (rmdat >> 6) & 3;  \
    cpu_reg = (rmdat >> 3) & 7;  \
    cpu_rm  = rmdat & 7;         \
    if (cpu_mod != 3) {          \
        fetch_ea_16_long(rmdat); \
        if (cpu_state.abrt)      \
            return 1;            \
    }
#define fetch_ea_32(rmdat)       \
    cpu_state.pc++;              \
    cpu_mod = (rmdat >> 6) & 3;  \
    cpu_reg = (rmdat >> 3) & 7;  \
    cpu_rm  = rmdat & 7;         \
    if (cpu_mod != 3) {          \
        fetch_ea_32_long(rmdat); \
    }                            \
    if (cpu_state.abrt)          \
    return 1

#include "x86_flags.h"

#define PREFETCH_RUN(instr_cycles, bytes, modrm, reads, reads_l, writes, writes_l, ea32) ((void)0)
#define PREFETCH_PREFIX()  ((void)0)
#define PREFETCH_FLUSH()   ((void)0)

#define OP_TABLE(name) ops_2386_##name
#define CLOCK_CYCLES(c)    cycles -= (c)
#define CLOCK_CYCLES_FPU(c)    cycles -= (c)
#define CONCURRENCY_CYCLES(c)  fpu_cycles = (c)
#define CLOCK_CYCLES_ALWAYS(c) cycles -= (c)

#define CHECK_READ_CS(size)                                                            \
    if (msw & 1 && !(cpu_state.eflags & VM_FLAG) && !(cpu_state.seg_cs.access & 0x80)) \
        x86np("Read from seg not present", cpu_state.seg_cs.seg & 0xfffc);             \
    else if ((cpu_state.pc < cpu_state.seg_cs.limit_low) ||                            \
        ((cpu_state.pc + size - 1) > cpu_state.seg_cs.limit_high))                     \
        x86gpf("Limit check (READ CS)", 0);

#include "386_ops.h"

/* Opcode dispatch table pointers - point to 386 tables defined above */
const OpFn *x86_2386_opcodes       = ops_2386_386;
const OpFn *x86_2386_opcodes_0f    = ops_2386_486_0f;
const OpFn *x86_2386_opcodes_REPE  = ops_2386_REPE;
const OpFn *x86_2386_opcodes_REPNE = ops_2386_REPNE;

/* FPU opcode table pointers - NULL since FPU is stubbed out */
const OpFn *x86_2386_opcodes_d8_a16 = NULL;
const OpFn *x86_2386_opcodes_d8_a32 = NULL;
const OpFn *x86_2386_opcodes_d9_a16 = NULL;
const OpFn *x86_2386_opcodes_d9_a32 = NULL;
const OpFn *x86_2386_opcodes_da_a16 = NULL;
const OpFn *x86_2386_opcodes_da_a32 = NULL;
const OpFn *x86_2386_opcodes_db_a16 = NULL;
const OpFn *x86_2386_opcodes_db_a32 = NULL;
const OpFn *x86_2386_opcodes_dc_a16 = NULL;
const OpFn *x86_2386_opcodes_dc_a32 = NULL;
const OpFn *x86_2386_opcodes_dd_a16 = NULL;
const OpFn *x86_2386_opcodes_dd_a32 = NULL;
const OpFn *x86_2386_opcodes_de_a16 = NULL;
const OpFn *x86_2386_opcodes_de_a32 = NULL;
const OpFn *x86_2386_opcodes_df_a16 = NULL;
const OpFn *x86_2386_opcodes_df_a32 = NULL;

/* ============================================================
 * External stubs from stubs.c
 * ============================================================ */
extern void mem_log_reset(void);
extern int  mem_log_get_count(void);
typedef struct { uint32_t addr; uint8_t old_val; uint8_t new_val; } mem_write_t;
extern mem_write_t *mem_log_get(int i);
extern void mem_log_add(uint32_t addr, uint8_t new_val);

extern void io_log_reset(void);
extern int  io_log_get_count(void);
typedef struct { uint16_t port; uint32_t val; int size; int is_write; } io_access_t;
extern io_access_t *io_log_get(int i);

extern void x86_init_znp_tables(void);
extern uint8_t *ram;


static void init_mod1_tables(void) {
    mod1add[0][0] = &BX;
    mod1add[0][1] = &BX;
    mod1add[0][2] = &BP;
    mod1add[0][3] = &BP;
    mod1add[0][4] = &SI;
    mod1add[0][5] = &DI;
    mod1add[0][6] = &BP;
    mod1add[0][7] = &BX;

    mod1add[1][0] = &SI;
    mod1add[1][1] = &DI;
    mod1add[1][2] = &SI;
    mod1add[1][3] = &DI;
    mod1add[1][4] = &zero;
    mod1add[1][5] = &zero;
    mod1add[1][6] = &zero;
    mod1add[1][7] = &zero;

    mod1seg[0] = &ds;
    mod1seg[1] = &ds;
    mod1seg[2] = &ss;
    mod1seg[3] = &ss;
    mod1seg[4] = &ds;
    mod1seg[5] = &ds;
    mod1seg[6] = &ss;
    mod1seg[7] = &ds;
}

static void init_seg(x86seg *s, uint16_t sel, uint32_t base, uint32_t limit_20bit,
                     uint8_t access, uint8_t ar_high) {
    s->seg = sel;
    s->base = base;
    s->access = access;
    s->ar_high = ar_high;
    /* Compute effective limit matching do_seg_load behavior:
     * s->limit holds EFFECTIVE limit (after G-bit expansion) */
    s->limit = limit_20bit;
    if (ar_high & 0x80) /* G bit set = 4K granularity */
        s->limit = (limit_20bit << 12) | 0xFFF;

    if (((access & 0x18) != 0x10) || !(access & 0x04)) {
        /* NOT expand-down (normal segment or code segment) */
        s->limit_high = s->limit;
        s->limit_low = 0;
    } else {
        /* Expand-down */
        s->limit_high = (ar_high & 0x40) ? 0xFFFFFFFF : 0xFFFF; /* B/D bit */
        s->limit_low = s->limit + 1;
    }
    s->checked = 1;
}

/* ============================================================
 * Instruction decode and flag effects (Intel486 PRM undefined flags)
 * ============================================================ */
#define F_C 0x001
#define F_P 0x004
#define F_A 0x010
#define F_Z 0x040
#define F_S 0x080
#define F_O 0x800
#define F_ARITH (F_C | F_P | F_A | F_Z | F_S | F_O)

typedef struct {
    int op32, a32, rep, nprefix;
    uint8_t op, op2;            /* op2 valid when op == 0x0F */
    int has_modrm, mod, reg, rm;
} insn_t;

static int modrm_1byte(uint8_t op) {
    if (op < 0x40) return (op & 7) < 4;
    if (op == 0x62 || op == 0x63 || op == 0x69 || op == 0x6B) return 1;
    if (op >= 0x80 && op <= 0x8F) return 1;
    if (op == 0xC0 || op == 0xC1 || (op >= 0xC4 && op <= 0xC7)) return 1;
    if (op >= 0xD0 && op <= 0xD3) return 1;
    if (op >= 0xD8 && op <= 0xDF) return 1;
    if (op == 0xF6 || op == 0xF7 || op == 0xFE || op == 0xFF) return 1;
    return 0;
}

static int modrm_0f(uint8_t op) {
    if (op <= 0x03) return 1;
    if (op >= 0x20 && op <= 0x23) return 1;
    if (op >= 0x90 && op <= 0x9F) return 1;
    switch (op) {
    case 0xA3: case 0xA4: case 0xA5: case 0xAB: case 0xAC: case 0xAD: case 0xAF:
    case 0xB0: case 0xB1: case 0xB2: case 0xB3: case 0xB4: case 0xB5: case 0xB6: case 0xB7:
    case 0xBA: case 0xBB: case 0xBC: case 0xBD: case 0xBE: case 0xBF:
    case 0xC0: case 0xC1:
        return 1;
    }
    return 0;
}

/* Prefixes, opcode and ModR/M fields of the instruction at lin; rd reads a
 * code byte, def32 is the code segment's default size. */
static void decode_with(uint8_t (*rd)(uint32_t), uint32_t lin, int def32, insn_t *d) {
    memset(d, 0, sizeof(*d));
    d->op32 = def32; d->a32 = def32;
    for (;;) {
        uint8_t b = rd(lin + d->nprefix);
        if (b == 0x66) d->op32 ^= 1;
        else if (b == 0x67) d->a32 ^= 1;
        else if (b == 0xF2 || b == 0xF3) d->rep = b;
        else if (b == 0xF0 || b == 0x26 || b == 0x2E || b == 0x36 || b == 0x3E || b == 0x64 || b == 0x65) ;
        else break;
        d->nprefix++;
    }
    uint32_t p = lin + d->nprefix;
    d->op = rd(p++);
    if (d->op == 0x0F) {
        d->op2 = rd(p++);
        d->has_modrm = modrm_0f(d->op2);
    } else {
        d->has_modrm = modrm_1byte(d->op);
    }
    if (d->has_modrm) {
        uint8_t m = rd(p);
        d->mod = m >> 6; d->reg = (m >> 3) & 7; d->rm = m & 7;
    }
}

static uint32_t cc_flags(int cc) {
    static const uint32_t t[8] = { F_O, F_C, F_Z, F_C | F_Z, F_S, F_P, F_S | F_O, F_Z | F_S | F_O };
    return t[(cc >> 1) & 7];
}

/* Flags written (wr), left undefined (ud) and read (rd) by one instruction. */
typedef struct { uint32_t wr, ud, rd; int dest_undef; int branch; } fx_t;

static fx_t flag_effect(const insn_t *d, uint32_t pre_ecx, uint32_t imm_last, int zf_after) {
    fx_t f = {0};
    uint8_t op = d->op;
    int width = d->op32 ? 32 : 16;
    if (op != 0x0F) {
        if (op < 0x40 && (op & 7) < 6) {
            int k = (op >> 3) & 7;
            f.wr = F_ARITH;
            if (k == 1 || k == 4 || k == 6) f.ud = F_A;
            if (k == 2 || k == 3) f.rd = F_C;
        } else if (op == 0x27 || op == 0x2F) { f.wr = F_ARITH; f.ud = F_O; f.rd = F_C | F_A; }
        else if (op == 0x37 || op == 0x3F) { f.wr = F_ARITH; f.ud = F_O | F_S | F_Z | F_P; f.rd = F_A; }
        else if (op >= 0x40 && op <= 0x4F) f.wr = F_O | F_S | F_Z | F_A | F_P;
        else if (op == 0x69 || op == 0x6B) { f.wr = F_ARITH; f.ud = F_S | F_Z | F_A | F_P; }
        else if (op >= 0x70 && op <= 0x7F) { f.rd = cc_flags(op & 0xF); f.branch = 1; }
        else if (op >= 0x80 && op <= 0x83) {
            int k = d->reg;
            f.wr = F_ARITH;
            if (k == 1 || k == 4 || k == 6) f.ud = F_A;
            if (k == 2 || k == 3) f.rd = F_C;
        } else if (op == 0x84 || op == 0x85 || op == 0xA8 || op == 0xA9) { f.wr = F_ARITH; f.ud = F_A; }
        else if (op == 0x9D) f.wr = F_ARITH;
        else if (op == 0x9E) f.wr = F_S | F_Z | F_A | F_P | F_C;
        else if (op == 0x9F) f.rd = F_S | F_Z | F_A | F_P | F_C;
        else if (op == 0xA6 || op == 0xA7 || op == 0xAE || op == 0xAF) {
            if (!(d->rep && pre_ecx == 0)) f.wr = F_ARITH;
        } else if (op == 0xC0 || op == 0xC1 || (op >= 0xD0 && op <= 0xD3)) {
            int cnt = (op == 0xD0 || op == 0xD1) ? 1 : (op == 0xD2 || op == 0xD3) ? (pre_ecx & 0xFF) : imm_last;
            int w = (op & 1) ? width : 8;
            cnt &= 31;
            if (cnt) {
                if (d->reg <= 3) {
                    f.wr = F_C | F_O;
                    if (cnt != 1) f.ud = F_O;
                    if (d->reg >= 2) f.rd = F_C;
                } else {
                    f.wr = F_ARITH;
                    f.ud = F_A | (cnt != 1 ? F_O : 0) | (cnt >= w ? F_C : 0);
                }
            }
        } else if (op == 0xD4 || op == 0xD5) { f.wr = F_ARITH; f.ud = F_O | F_A | F_C; }
        else if (op == 0xE0 || op == 0xE1) { f.rd = F_Z; f.branch = 1; }
        else if (op == 0xF5) { f.wr = F_C; f.rd = F_C; }
        else if (op == 0xF8 || op == 0xF9) f.wr = F_C;
        else if (op == 0xF6 || op == 0xF7) {
            switch (d->reg) {
            case 0: case 1: f.wr = F_ARITH; f.ud = F_A; break;
            case 3: f.wr = F_ARITH; break;
            case 4: case 5: f.wr = F_ARITH; f.ud = F_S | F_Z | F_A | F_P; break;
            case 6: case 7: f.wr = F_ARITH; f.ud = F_ARITH; break;
            }
        } else if ((op == 0xFE || op == 0xFF) && d->reg <= 1) f.wr = F_O | F_S | F_Z | F_A | F_P;
    } else {
        uint8_t o = d->op2;
        if (o >= 0x80 && o <= 0x8F) { f.rd = cc_flags(o & 0xF); f.branch = 1; }
        else if (o >= 0x90 && o <= 0x9F) f.rd = cc_flags(o & 0xF);
        else if (o == 0xA3 || o == 0xAB || o == 0xB3 || o == 0xBB || (o == 0xBA && d->reg >= 4)) {
            f.wr = F_C | F_O | F_S | F_A | F_P; f.ud = F_O | F_S | F_A | F_P;
        } else if (o == 0xA4 || o == 0xA5 || o == 0xAC || o == 0xAD) {
            int cnt = (o == 0xA4 || o == 0xAC) ? imm_last : (pre_ecx & 0xFF);
            cnt &= 31;
            if (cnt) {
                f.wr = F_ARITH;
                f.ud = F_A | (cnt != 1 ? F_O : 0);
                if (cnt > width) { f.ud = F_ARITH; f.dest_undef = 1; }
            }
        } else if (o == 0xAF) { f.wr = F_ARITH; f.ud = F_S | F_Z | F_A | F_P; }
        else if (o == 0xB0 || o == 0xB1 || o == 0xC0 || o == 0xC1) f.wr = F_ARITH;
        else if (o == 0xBC || o == 0xBD) {
            f.wr = F_ARITH; f.ud = F_C | F_O | F_S | F_A | F_P;
            if (zf_after) f.dest_undef = 1;
        } else if (o == 0x02 || o == 0x03 || (o == 0x00 && (d->reg == 4 || d->reg == 5))) f.wr = F_Z;
    }
    return f;
}


/* One instruction from CS:EIP; 1 if it raised an exception (cpu_state.abrt). */
static int exec_one(void) {
    uint32_t fetchdat_local;

    oldcs  = CS;
    oldcpl = CPL;
    cpu_state.oldpc = cpu_state.pc;
    cpu_state.op32  = use32;
    cpu_state.ea_seg = &cpu_state.seg_ds;
    cpu_state.ssegs  = 0;

    fetchdat_local = fastreadl_fetch(cs + cpu_state.pc);
    if (cpu_state.abrt)
        return 1;

    opcode = fetchdat_local & 0xFF;
    fetchdat_local >>= 8;
    rmdat = fetchdat_local;

    cpu_state.pc++;
    x86_2386_opcodes[(opcode | cpu_state.op32) & 0x3ff](fetchdat_local);

    if (!use32)
        cpu_state.pc &= 0xFFFF;

    return cpu_state.abrt ? 1 : 0;
}

#endif
