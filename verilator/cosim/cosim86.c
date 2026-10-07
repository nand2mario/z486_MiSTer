/*
 * cosim86.c - 86Box CPU core as the reference for full-system co-simulation
 *
 * See cosim86.h. The reference runs whole programs from CPU reset: its own
 * copy of RAM, the platform's physical map (A20, the reset-vector BIOS
 * alias, write-protected C0000-FFFFF, RAM size), device reads and I/O reads
 * supplied from z486's transactions, and every memory and I/O write it
 * performs queued for comparison with z486's, in program order.
 *
 * Program order between instructions is strict; within one instruction the
 * bytes may come in any order (z486 writes PUSHA's lowest slot first, 86Box
 * the highest). A step that needs device data z486 has not returned yet is
 * rolled back and retried (COSIM_STALL).
 */
#include "iss_glue.h"
#include "cosim86.h"

extern int iss_phys_hooks;
extern int (*iss_phys_read_hook)(uint32_t phys, uint8_t *val);
extern int (*iss_phys_write_hook)(uint32_t phys, uint8_t val);
extern uint32_t (*iss_io_in_hook)(uint16_t port, int size);
extern void (*iss_io_out_hook)(uint16_t port, int size, uint32_t val);
extern uint32_t (*iss_xlate)(uint32_t lin, int write);
extern int iss_code_fetch;
extern int iss_split_write_first;
extern int iss_partial_n;
extern uint32_t iss_partial_pa[4];
extern uint8_t iss_partial_val[4];
extern uint32_t mem_size;
extern void pmodeint_2386(int num, int soft);
extern void x86_doabrt_2386(int x86_abrt);
extern void loadcs_2386(uint16_t seg);

#define DEV_LO  0x000A0000u     /* device reads are supplied by z486 */
#define DEV_HI  0x000C0000u
#define BIOS_ALIAS 0xFFFC0000u  /* the reset-vector window maps to ... */
#define BIOS_MIRROR 0x00FC0000u /* ... this RAM copy of the BIOS */

static uint32_t ram_bytes;
static int a20_on = 1;
static char err[2048];
static uint64_t ninsn;
static int stall;               /* this step wanted data not yet supplied */
static int last_fault = -1;
static int was_hlt;
/* Arithmetic flags left undefined, taken from z486 at the next issue: bits
 * 15:0 by the last instruction, 31:16 by the one before and not written
 * since. z486's fast paths can commit flags after the next instruction
 * issues, so each set is adopted at two issues. */
static uint32_t udf;

/* ============================================================
 * Event queues
 * ============================================================ */
typedef struct { uint32_t addr; uint8_t val; uint8_t done; uint8_t silent; uint64_t grp; } ev_t;
typedef struct { ev_t *v; size_t head, tail, cap; } q_t;

static void q_push_ev(q_t *q, ev_t e);
static void q_push(q_t *q, uint32_t addr, uint8_t val, uint64_t grp) {
    q_push_ev(q, (ev_t){ addr, val, 0, 0, grp });
}
static void q_push_ev(q_t *q, ev_t e) {
    if (q->tail == q->cap) {
        if (q->head > 0) {                      /* compact */
            memmove(q->v, q->v + q->head, (q->tail - q->head) * sizeof(ev_t));
            q->tail -= q->head;
            q->head = 0;
        }
        if (q->tail == q->cap) {
            q->cap = q->cap ? q->cap * 2 : 4096;
            q->v = realloc(q->v, q->cap * sizeof(ev_t));
        }
    }
    q->v[q->tail++] = e;
}
static int q_empty(const q_t *q) { return q->head == q->tail; }

static q_t io_rd, dev_rd;       /* z486's read data, consumed by the reference */
static size_t io_cur, dev_cur;  /* tentative consumption in the current step */
static q_t exp_w, dut_w;        /* reference writes not yet matched; z486 writes ahead */
static q_t exp_io, dut_io;
static q_t stage_w, stage_io;   /* the current step's writes */

static void fail(const char *fmt, ...) {
    if (err[0]) return;                         /* keep the first error */
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, sizeof(err), fmt, ap);
    va_end(ap);
}

/* ============================================================
 * Instruction history for reports
 * ============================================================ */
#define HIST 64
typedef struct { uint64_t n; uint16_t sel; uint32_t eip; uint8_t bytes[8]; uint32_t regs[8]; } hist_t;
static hist_t hist[HIST];

static uint8_t peek_lin(uint32_t lin);

static void hist_add(uint16_t sel, uint32_t eip, uint32_t lin) {
    hist_t *h = &hist[ninsn % HIST];
    h->n = ninsn;
    h->sel = sel;
    h->eip = eip;
    for (int i = 0; i < 8; i++) h->bytes[i] = peek_lin(lin + i);
    for (int r = 0; r < 8; r++) h->regs[r] = cpu_state.regs[r].l;
}

/* COSIM_HIST=n (up to the 64 kept) prints more than the last 16. */
void cosim_dump_history(void) {
    const char *e = getenv("COSIM_HIST");
    unsigned n = e ? (unsigned)atoi(e) : 16;
    if (n > HIST) n = HIST;
    cosim_dump_history_from(ninsn > n ? ninsn - n : 0, n);
}

void cosim_dump_history_from(uint64_t first, unsigned count) {
    static const char *nm[8] = { "eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi" };
    for (uint64_t n = first; n < ninsn && n < first + count; n++) {
        hist_t *h = &hist[n % HIST];
        if (h->n != n) continue;
        printf("  #%llu %04x:%08x ", (unsigned long long)n, h->sel, h->eip);
        for (int i = 0; i < 8; i++) printf("%02x ", h->bytes[i]);
        printf(" |");
        for (int r = 0; r < 8; r++) printf(" %s=%08x", nm[r], h->regs[r]);
        printf("\n");
    }
}

static void advance_exp(void);

void cosim_dump_writes(void) {
    advance_exp();
    printf("  reference writes z486 has not matched:\n");
    int shown = 0;
    for (size_t i = exp_w.head; i < exp_w.tail && shown < 24; i++) {
        if (exp_w.v[i].done) continue;
        printf("    #%llu %08x=%02x\n", (unsigned long long)exp_w.v[i].grp, exp_w.v[i].addr,
               exp_w.v[i].val);
        shown++;
    }
    for (size_t i = exp_io.head; i < exp_io.tail && i < exp_io.head + 8; i++)
        printf("    #%llu out %04x=%02x\n", (unsigned long long)exp_io.v[i].grp, exp_io.v[i].addr,
               exp_io.v[i].val);
}

/* ============================================================
 * Physical map and paging
 * ============================================================ */
static uint32_t ram32(uint32_t a) {
    return ram[a & rammask] | ram[(a + 1) & rammask] << 8 | ram[(a + 2) & rammask] << 16 |
           (uint32_t)ram[(a + 3) & rammask] << 24;
}

static uint32_t platform_phys(uint32_t phys) {
    if (!a20_on) phys &= ~0x00100000u;
    if (phys >= BIOS_ALIAS) phys = BIOS_MIRROR + (phys & 0x3FFFFu);
    return phys;
}

/* Two-level page walk. The A/D updates are z486's (cosim_walker_write):
 * when a 486 sets them is implementation-specific, so the reference takes
 * z486's and sets none itself. */
static uint32_t walk(uint32_t lin, int write, int probe_only) {
    if (!(cr0 & 0x80000000u))
        return platform_phys(lin);
    int user = (CPL == 3) && !cpl_override;
    uint32_t err_code = (write ? 2 : 0) | (user ? 4 : 0);
    uint32_t pde = ram32((cr3 & ~0xFFFu) + ((lin >> 22) << 2));
    if (!(pde & 1)) goto fault;
    uint32_t pte = ram32((pde & ~0xFFFu) + (((lin >> 12) & 0x3FF) << 2));
    if (!(pte & 1)) goto fault;
    err_code |= 1;
    if (user && !((pde & pte) & 4)) goto fault;
    if (write && (user || (cr0 & 0x10000)) && !((pde & pte) & 2)) goto fault;
    return platform_phys((pte & ~0xFFFu) | (lin & 0xFFF));
fault:
    if (probe_only) return 0xFFFFFFFFu;
    /* An instruction fetch fault reports the 16-byte prefetch line on z486. */
    cr2 = (iss_code_fetch || read_type == 1) ? (lin & ~0xFu) : lin;
    abrt_error = err_code;
    cpu_state.abrt = ABRT_PF;
    return 0;
}

static uint32_t xlate(uint32_t lin, int write) { return walk(lin, write, 0); }

/* A write probe that faulted on the second page of a split access: the
 * first page's part (iss_split_write_first; see split_string_store). */
static uint32_t split_probe_lin;
static int split_probe_n;

static void iss_probe(uint32_t lin, int n, int write) {
    for (int i = 0; i < n && !cpu_state.abrt; i++) {
        walk(lin + i, write, 0);
        if (cpu_state.abrt && write && i > 0 && ((lin + i) & 0xFFF) == 0) {
            split_probe_lin = lin;
            split_probe_n = i;
        }
    }
}

/* A byte at a linear address with no side effects (history, decoding). */
static uint8_t peek_lin(uint32_t lin) {
    uint32_t p = walk(lin, 0, 1);
    if (p == 0xFFFFFFFFu || p >= ram_bytes) return 0xFF;
    return ram[p & rammask];
}

/* MOVS/STOS: 86Box probes an element's destination before it writes, so a
 * split element whose second page faults stores nothing; z486 stores the
 * first page's part first (iss_split_write_first). Store it: now for a REP
 * string (whose earlier elements stay), else through iss_partial, which
 * survives the undo of the faulting instruction. */
static int wr_hook(uint32_t phys, uint8_t v);

static void split_string_store(uint8_t op, int a32, int rep_string) {
    uint8_t data[4];
    if (op == 0xAB) {
        for (int i = 0; i < 4; i++) data[i] = (EAX >> (8 * i)) & 0xFF;
    } else {
        const uint32_t src = cpu_state.ea_seg->base + (a32 ? ESI : SI);
        for (int i = 0; i < 4; i++) data[i] = peek_lin(src + i);
    }
    for (int i = 0; i < split_probe_n && i < 4; i++) {
        const uint32_t pa = walk(split_probe_lin + i, 1, 1);
        if (pa == 0xFFFFFFFFu) return;
        if (rep_string) {
            if (!wr_hook(pa, data[i])) ram[pa & rammask] = data[i];
        } else if (iss_partial_n < 4) {
            iss_partial_pa[iss_partial_n] = pa;
            iss_partial_val[iss_partial_n++] = data[i];
        }
    }
}

/* After ENTER: z486's 386 microcode does ENTER's pushes, then probes the new
 * stack top (CW at the final ESP) before committing ESP, so a stack page that
 * is not present faults in ENTER, which restarts with its pushes already in
 * memory; 86Box faults in the push that follows. Probe the final ESP; 1 if
 * it faulted. */
static int enter_probe(int op32) {
    iss_probe(ss + (stack32 ? ESP : SP), op32 ? 4 : 2, 1);
    return cpu_state.abrt != 0;
}

/* The device byte the reference read last. z486 can read uncached device
 * memory again for one access (a micro-op replayed after a TLB miss walk);
 * such a repeat is skipped. Known z486 inefficiency. */
static uint32_t dev_last = 0xFFFFFFFFu;

static int rd_hook(uint32_t phys, uint8_t *v) {
    if (phys >= DEV_LO && phys < DEV_HI) {
        size_t i = dev_rd.head + dev_cur;
        while (i < dev_rd.tail && dev_rd.v[i].addr != phys && dev_rd.v[i].addr == dev_last) {
            dev_cur++;
            i++;
        }
        if (i >= dev_rd.tail) {                 /* not returned by z486 yet */
            stall = 1;
            *v = 0xFF;
            return 1;
        }
        dev_last = phys;
        if (dev_rd.v[i].addr != phys)
            fail("device read %08x: z486's next device read is %08x", phys, dev_rd.v[i].addr);
        *v = dev_rd.v[i].val;
        dev_cur++;
        return 1;
    }
    if (phys >= ram_bytes) {                    /* unmapped */
        *v = 0xFF;
        return 1;
    }
    return 0;
}

static int in_ram(uint32_t phys) {
    return phys < ram_bytes && !(phys >= DEV_LO && phys < DEV_HI) && (phys >> 18) != 3;
}

static int wr_hook(uint32_t phys, uint8_t v) {
    /* A write of the byte's current value is silent: z486 and 86Box differ
     * in which unchanged bytes they rewrite (z486 writes a descriptor's
     * Accessed bit with the whole high dword, 86Box with a word). */
    int silent = in_ram(phys) && ram[phys & rammask] == v;
    q_push_ev(&stage_w, (ev_t){ phys, v, 0, (uint8_t)silent, 0 });
    if (phys >= DEV_LO && phys < DEV_HI) return 1;          /* device */
    if ((phys >> 18) == 3) return 1;                        /* write-protected C0000-FFFFF */
    if (phys >= ram_bytes) return 1;                        /* unmapped */
    return 0;
}

static uint32_t io_in(uint16_t port, int size) {
    uint32_t val = 0;
    for (int b = 0; b < size; b++) {
        size_t i = io_rd.head + io_cur;
        if (i >= io_rd.tail) {
            stall = 1;
            return 0xFFFFFFFFu;
        }
        if (io_rd.v[i].addr != (uint16_t)(port + b))
            fail("in port %04x: z486's next I/O read is port %04x", (uint16_t)(port + b),
                 io_rd.v[i].addr);
        val |= (uint32_t)io_rd.v[i].val << (8 * b);
        io_cur++;
    }
    return val;
}

static void io_out(uint16_t port, int size, uint32_t val) {
    for (int b = 0; b < size; b++)
        q_push(&stage_io, (uint16_t)(port + b), (val >> (8 * b)) & 0xFF, 0);
}

/* ============================================================
 * Interrupts (86Box's 386_common.c, interpreter path)
 * ============================================================ */
static void real_mode_int(int num) {
    uint32_t addr = (num << 2) + idt.base;
    if (stack32) {
        writememw(ss, ESP - 2, cpu_state.flags);
        writememw(ss, ESP - 4, CS);
        writememw(ss, ESP - 6, cpu_state.pc);
        ESP -= 6;
    } else {
        writememw(ss, ((SP - 2) & 0xFFFF), cpu_state.flags);
        writememw(ss, ((SP - 4) & 0xFFFF), CS);
        writememw(ss, ((SP - 6) & 0xFFFF), cpu_state.pc);
        SP -= 6;
    }
    cpu_state.flags &= ~(I_FLAG | T_FLAG);
    cpu_state.pc = readmemw(0, addr);
    loadcs_2386(readmemw(0, addr + 2));
}

/* A fault pushes EFLAGS with RF set: the 386 microcode's FAULT path (893-899)
 * sets it for every fault outside a TSS access, and the gate entry clears it
 * in EFLAGS again (8D5, 632). 86Box does neither. x86_int carries the faults
 * raised by ops (#DE, #UD, #NM); hardware interrupts use cosim_interrupt. */
void x86_int(int num) {
    flags_rebuild();
    cpu_state.pc = cpu_state.oldpc;
    cpu_state.eflags |= RF_FLAG;
    if (msw & 1) {
        pmodeint_2386(num, 0);
    } else if ((num << 2UL) + 3UL > idt.limit) {
        if (idt.limit < 35) fail("triple fault in real mode (vector %d)", num);
        else x86_int(8);
    } else {
        real_mode_int(num);
    }
    cpu_state.eflags &= ~RF_FLAG;
}

void x86_int_sw(int num) {
    flags_rebuild();
    if (msw & 1) {
        pmodeint_2386(num, 1);
    } else if ((num << 2UL) + 3UL > idt.limit) {
        x86_int(0x0d);
    } else {
        real_mode_int(num);
    }
    trap &= ~1;
}

int x86_int_sw_rm(int num) {
    x86_int_sw(num);
    return cpu_state.abrt ? 1 : 0;
}

void x86illegal(void) { x86_int(6); }

/* ============================================================
 * State snapshot for rollback
 * ============================================================ */
typedef struct {
    cpu_state_t s;
    uint32_t cr2, cr3, cr4, dr[8];
    x86seg gdt, ldt, idt, tr;
    uint32_t use32, abrt_error;
    int stack32, trap, oldcpl, cpl_override;
    uint16_t oldcs;
} snap_t;

static void snap_save(snap_t *p) {
    p->s = cpu_state;
    p->cr2 = cr2; p->cr3 = cr3; p->cr4 = cr4;
    memcpy(p->dr, dr, sizeof(dr));
    p->gdt = gdt; p->ldt = ldt; p->idt = idt; p->tr = tr;
    p->use32 = use32; p->abrt_error = abrt_error;
    p->stack32 = stack32; p->trap = trap; p->oldcpl = oldcpl; p->cpl_override = cpl_override;
    p->oldcs = oldcs;
}

static void snap_restore(const snap_t *p) {
    cpu_state = p->s;
    cr2 = p->cr2; cr3 = p->cr3; cr4 = p->cr4;
    memcpy(dr, p->dr, sizeof(dr));
    gdt = p->gdt; ldt = p->ldt; idt = p->idt; tr = p->tr;
    use32 = p->use32; abrt_error = p->abrt_error;
    stack32 = p->stack32; trap = p->trap; oldcpl = p->oldcpl; cpl_override = p->cpl_override;
    oldcs = p->oldcs;
}

static void undo_ram(void) {
    for (int k = mem_log_get_count() - 1; k >= 0; k--) {
        mem_write_t *w = mem_log_get(k);
        ram[w->addr & rammask] = w->old_val;
    }
}

/* ============================================================
 * Write matching
 * ============================================================ */
static void advance_exp(void) {
    while (!q_empty(&exp_w) && exp_w.v[exp_w.head].done) exp_w.head++;
}

/* One z486 write against the oldest outstanding reference instruction.
 * Changed bytes must match in program order; silent writes (the byte's
 * current value) may appear on one side only. */
static int match_write(uint32_t phys, uint8_t val) {
    for (;;) {
        advance_exp();
        if (q_empty(&exp_w)) {
            q_push(&dut_w, phys, val, 0);
            return COSIM_OK;
        }
        uint64_t grp = exp_w.v[exp_w.head].grp;
        /* Search the oldest instruction's writes from the first unmatched
         * one, stopping at the match: a REP string is one instruction with
         * up to millions of writes, which z486 does in order. */
        size_t end = exp_w.head;
        for (; end < exp_w.tail && exp_w.v[end].grp == grp; end++) {
            ev_t *e = &exp_w.v[end];
            if (e->done || e->addr != phys) continue;
            if (e->val != val) {
                fail("write %08x: z486 %02x, reference %02x (instruction #%llu)", phys, val, e->val,
                     (unsigned long long)grp);
                return COSIM_ERROR;
            }
            e->done = 1;
            advance_exp();
            return COSIM_OK;
        }
        /* z486 rewrote a byte with its value: no effect. */
        if (in_ram(phys) && ram[phys & rammask] == val)
            return COSIM_OK;
        /* The oldest instruction has only silent writes left, which z486
         * did not do: it is complete. */
        int only_silent = 1;
        for (size_t i = exp_w.head; i < end; i++)
            if (!exp_w.v[i].done && !exp_w.v[i].silent) only_silent = 0;
        if (only_silent) {
            for (size_t i = exp_w.head; i < end; i++) exp_w.v[i].done = 1;
            continue;
        }
        ev_t *e = &exp_w.v[exp_w.head];
        for (size_t i = exp_w.head; i < end; i++)
            if (!exp_w.v[i].done && !exp_w.v[i].silent) { e = &exp_w.v[i]; break; }
        fail("z486 wrote %08x=%02x; the reference's next write is %08x=%02x (instruction #%llu)",
             phys, val, e->addr, e->val, (unsigned long long)grp);
        return COSIM_ERROR;
    }
}

static int match_io(uint16_t port, uint8_t val) {
    if (q_empty(&exp_io)) {
        q_push(&dut_io, port, val, 0);
        return COSIM_OK;
    }
    ev_t *e = &exp_io.v[exp_io.head];
    if (e->addr != port || e->val != val) {
        fail("out %04x=%02x by z486; the reference's next is %04x=%02x (instruction #%llu)",
             port, val, e->addr, e->val, (unsigned long long)e->grp);
        return COSIM_ERROR;
    }
    exp_io.head++;
    return COSIM_OK;
}

/* The step's writes join the expected streams; z486 writes that arrived
 * first are matched now. */
static int commit_writes(void) {
    for (size_t i = stage_w.head; i < stage_w.tail; i++) {
        ev_t e = stage_w.v[i];
        e.grp = ninsn;
        q_push_ev(&exp_w, e);
    }
    for (size_t i = stage_io.head; i < stage_io.tail; i++)
        q_push(&exp_io, stage_io.v[i].addr, stage_io.v[i].val, ninsn);
    stage_w.head = stage_w.tail = 0;
    stage_io.head = stage_io.tail = 0;
    io_rd.head += io_cur; io_cur = 0;
    dev_rd.head += dev_cur; dev_cur = 0;
    q_t pend = dut_w;
    dut_w = (q_t){ 0 };
    for (size_t i = pend.head; i < pend.tail; i++)
        if (match_write(pend.v[i].addr, pend.v[i].val) != COSIM_OK) break;
    free(pend.v);
    q_t pio = dut_io;
    dut_io = (q_t){ 0 };
    for (size_t i = pio.head; i < pio.tail; i++)
        if (match_io(pio.v[i].addr, pio.v[i].val) != COSIM_OK) break;
    free(pio.v);
    return err[0] ? COSIM_ERROR : COSIM_OK;
}

static void drop_step(void) {
    stage_w.head = stage_w.tail = 0;
    stage_io.head = stage_io.tail = 0;
    io_cur = dev_cur = 0;
}

/* ============================================================
 * API
 * ============================================================ */
void cosim_init(uint32_t bytes) {
    uint32_t pow2 = 1;
    while (pow2 < bytes) pow2 <<= 1;
    ram = calloc(pow2, 1);
    ram_bytes = bytes;
    mem_size = bytes;
    rammask = pow2 - 1;
    iss_phys_hooks = 1;
    iss_phys_read_hook = rd_hook;
    iss_phys_write_hook = wr_hook;
    iss_io_in_hook = io_in;
    iss_io_out_hook = io_out;
    iss_xlate = xlate;
    iss_ss_chain = 0;               /* z486 issues the shadowed instruction itself */
    iss_sel_push32 = 1;             /* frames hold zero-extended selectors, as z486 */
    iss_split_write_first = 1;      /* a split write's first page is stored first, as z486 */
    x86_init_znp_tables();
    init_mod1_tables();
    cpu_isintel = 1;
    is486 = 1;
    cosim_reset();
}

uint8_t *cosim_ram(void) { return ram; }
void cosim_set_a20(int enable) { a20_on = enable; }

void cosim_reset(void) {
    /* Writes and reads in flight at a reset are dropped with it. */
    q_t *qs[] = { &io_rd, &dev_rd, &exp_w, &dut_w, &exp_io, &dut_io, &stage_w, &stage_io };
    for (size_t i = 0; i < sizeof(qs) / sizeof(qs[0]); i++) qs[i]->head = qs[i]->tail = 0;
    io_cur = dev_cur = 0;
    last_fault = -1;
    udf = 0;
    memset(&cpu_state, 0, sizeof(cpu_state));
    cr0 = 0x00000010;       /* z486's reset value: ET */
    cr2 = cr3 = cr4 = 0;
    memset(dr, 0, sizeof(dr));
    init_seg(&cpu_state.seg_cs, 0xF000, 0xFFFF0000u, 0xFFFF, 0x93, 0x00);
    init_seg(&cpu_state.seg_ds, 0, 0, 0xFFFF, 0x93, 0x00);
    init_seg(&cpu_state.seg_es, 0, 0, 0xFFFF, 0x93, 0x00);
    init_seg(&cpu_state.seg_ss, 0, 0, 0xFFFF, 0x93, 0x00);
    init_seg(&cpu_state.seg_fs, 0, 0, 0xFFFF, 0x93, 0x00);
    init_seg(&cpu_state.seg_gs, 0, 0, 0xFFFF, 0x93, 0x00);
    memset(&gdt, 0, sizeof(gdt));
    memset(&ldt, 0, sizeof(ldt));
    memset(&tr, 0, sizeof(tr));
    memset(&idt, 0, sizeof(idt));
    idt.limit = 0x3FF;
    use32 = 0;
    stack32 = 0;
    trap = 0;
    cpu_state.flags = 0x0002;
    cpu_state.eflags = 0;
    cpu_state.flags_op = FLAGS_UNKNOWN;
    cpu_state.pc = 0xFFF0;
    EDX = 0x0303;           /* z486 runs the 386 microcode: BOOTUP's signature */
    was_hlt = 0;
}

uint32_t cosim_eip(void) { return cpu_state.pc; }
uint16_t cosim_cs(void) { return CS; }
uint32_t cosim_reg(int r) { return cpu_state.regs[r & 7].l; }
uint32_t cosim_eflags(void) { flags_rebuild(); return cpu_state.flags | (cpu_state.eflags << 16); }
int cosim_halted(void) { return was_hlt; }
int cosim_last_fault(void) { return last_fault; }
uint64_t cosim_instructions(void) { return ninsn; }
const char *cosim_error(void) { return err; }
int cosim_writes_pending(void) {
    advance_exp();
    return !q_empty(&exp_w) || !q_empty(&exp_io);
}

/* The hidden part of a segment register as z486 holds it:
 * {A, G, D/B, P, DPL, S, type, raw limit[19:0]}. */
static uint32_t seg_attr(const x86seg *s, int is_cs, int nullable) {
    const int pm = (msw & 1) && !(cpu_state.eflags & VM_FLAG);
    uint8_t access = s->access;
    if (pm && nullable && !(s->seg & 0xfffc))
        return (1u << 27) | 0xFFFFF;            /* z486's null descriptor: P, limit FFFFF */
    if (!pm && access == 0xe2)                  /* 86Box's marker for a real-mode load */
        access = (cpu_state.eflags & VM_FLAG ? 0xE0 : 0x80) | 0x10 | (is_cs ? 0xB : 0x3);
    /* A limit that needs more than 20 bits is page-granular even where 86Box
     * left G clear (a real-mode segment keeping a 4 GB unreal-mode limit). */
    const uint32_t g = ((s->ar_high >> 7) & 1) | (s->limit > 0xFFFFF), db = (s->ar_high >> 6) & 1;
    const uint32_t raw = (g ? s->limit >> 12 : s->limit) & 0xFFFFF;
    return ((uint32_t)(access & 1) << 30) | (g << 29) | (db << 28) | ((uint32_t)(access >> 7) << 27) |
           ((uint32_t)((access >> 5) & 3) << 25) | ((uint32_t)((access >> 4) & 1) << 24) |
           ((uint32_t)(access & 0xF) << 20) | raw;
}

void cosim_arch(uint32_t *w) {
    flags_rebuild();
    for (int r = 0; r < 8; r++) w[r] = cpu_state.regs[r].l;
    w[8] = cpu_state.pc;
    w[9] = ((cpu_state.flags | (cpu_state.eflags << 16)) & 0x77fd5) | 2;
    w[10] = cr0;
    w[11] = cr2;
    w[12] = cr3;
    w[13] = dr[6];
    w[14] = dr[7];
    w[15] = gdt.base;
    w[16] = gdt.limit;
    w[17] = idt.base;
    w[18] = idt.limit;
    const x86seg *segs[8] = { &cpu_state.seg_es, &cpu_state.seg_cs, &cpu_state.seg_ss, &cpu_state.seg_ds,
                              &cpu_state.seg_fs, &cpu_state.seg_gs, &tr, &ldt };
    for (int i = 0; i < 8; i++) {
        w[19 + 3 * i] = segs[i]->seg;
        w[20 + 3 * i] = segs[i]->base;
        w[21 + 3 * i] = seg_attr(segs[i], i == 1, i == 0 || i >= 3);
    }
}

int cosim_snapshot_ok(void) {
    advance_exp();
    if (!q_empty(&exp_w) || !q_empty(&exp_io) || !q_empty(&dut_w) || !q_empty(&dut_io) ||
        !q_empty(&stage_w) || !q_empty(&stage_io) || was_hlt || ninsn == 0)
        return 0;
    const hist_t *h = &hist[(ninsn - 1) % HIST];
    for (int i = 0; i < 8; i++) {
        switch (h->bytes[i]) {
            case 0x26: case 0x2E: case 0x36: case 0x3E: case 0x64: case 0x65:
            case 0x66: case 0x67: case 0xF0: case 0xF2: case 0xF3: continue;
            case 0xFB: case 0x17: return 0;                         /* STI, POP SS */
            case 0x8E: return i + 1 < 8 && ((h->bytes[i + 1] >> 3) & 7) != 2;   /* MOV SS */
            default: return 1;
        }
    }
    return 0;
}

/* Opcode at CS:EIP after its prefixes; *rep set when F2/F3 is present. */
static uint8_t peek_opcode(int *rep) {
    *rep = 0;
    for (int i = 0; i < 15; i++) {
        uint8_t b = peek_lin(cs + ((cpu_state.pc + i) & (use32 ? 0xFFFFFFFFu : 0xFFFFu)));
        switch (b) {
            case 0xF2: case 0xF3: *rep = 1; break;
            case 0x26: case 0x2E: case 0x36: case 0x3E: case 0x64: case 0x65:
            case 0x66: case 0x67: case 0xF0: break;
            default: return b;
        }
    }
    return 0x90;
}

static int is_string_op(uint8_t op) {
    return (op >= 0xA4 && op <= 0xA7) || (op >= 0xAA && op <= 0xAF) || (op >= 0x6C && op <= 0x6F);
}

int cosim_at_rep_string(void) {
    int rep;
    uint8_t op = peek_opcode(&rep);
    return rep && is_string_op(op);
}

static int is_logic_op(const insn_t *d) {
    uint8_t op = d->op;
    if (op < 0x40 && (op & 7) < 6) {
        int k = (op >> 3) & 7;
        return k == 1 || k == 4 || k == 6;
    }
    if (op >= 0x80 && op <= 0x83) return d->reg == 1 || d->reg == 4 || d->reg == 6;
    if (op == 0x84 || op == 0x85 || op == 0xA8 || op == 0xA9) return 1;
    if (op == 0xF6 || op == 0xF7) return d->reg == 0 || d->reg == 1;
    return 0;
}

/* Run an instruction; rep_left >= 0 stops a REP string at that count. */
static int run(long rep_left) {
    if (err[0]) return COSIM_ERROR;
    snap_t snap;
    snap_save(&snap);
    mem_log_reset();
    drop_step();
    stall = 0;
    last_fault = -1;
    was_hlt = 0;
    iss_partial_n = 0;
    split_probe_n = 0;
    int enter_cw = 0;

    int rep;
    uint8_t op = peek_opcode(&rep);
    int rep_string = rep && is_string_op(op);
    uint32_t pre_pc = cpu_state.pc;
    insn_t d;
    decode_with(peek_lin, cs + pre_pc, use32 != 0, &d);
    uint32_t pre_ecx = ECX;
    uint32_t pre_udf = udf;
    hist_add(CS, pre_pc, cs + pre_pc);

    flags_rebuild();
    pccache = 0xFFFFFFFF;
    cpu_state.abrt = 0;
    oldcs = CS;
    oldcpl = CPL;
    cpu_state.oldpc = cpu_state.pc;
    int faulted;
    /* The count register is CX or ECX by the address size. */
    int a32 = 0;
    for (int i = 0; rep_string && i < 15; i++) {
        uint8_t b = peek_lin(cs + ((pre_pc + i) & (use32 ? 0xFFFFFFFFu : 0xFFFFu)));
        if (b == 0x67) a32 = 1;
        else if (b != 0xF2 && b != 0xF3 && b != 0x26 && b != 0x2E && b != 0x36 &&
                 b != 0x3E && b != 0x64 && b != 0x65 && b != 0x66 && b != 0xF0) break;
    }
    int ecx_count = (use32 != 0) ^ a32;
    /* A count of 0 left means z486 finished the string (or it had nothing to
     * do): the instruction completes, it is not cut. */
    if (rep_string && rep_left >= 0 && (ecx_count ? (uint32_t)rep_left : (rep_left & 0xFFFF)) == 0)
        rep_left = -1;
    if (rep_string && rep_left >= 0) {
        int saved_trap = trap;
        trap = 1;                       /* 86Box ends a REP after one element */
        faulted = 0;
        for (;;) {
            uint32_t left = ecx_count ? ECX : CX;
            uint32_t stop = ecx_count ? (uint32_t)rep_left : ((uint32_t)rep_left & 0xFFFF);
            if (left <= stop || stall) break;
            cycles = 1000000;
            cpu_state.oldpc = pre_pc;
            faulted = exec_one();
            if (cpu_state.pc != pre_pc) break;
        }
        trap = saved_trap;
    } else if (op == 0xC8) {
        cycles = 1000000;
        faulted = exec_one();
        enter_cw = !faulted && enter_probe(d.op32);
        faulted |= enter_cw;
    } else {
        cycles = 1000000;
        faulted = exec_one();
        /* 86Box runs a REP string in chunks, leaving EIP on it to resume. */
        while (!faulted && !stall && rep_string && cpu_state.pc == pre_pc) {
            cycles = 1000000;
            faulted = exec_one();
        }
    }

    if (stall) {
        undo_ram();
        snap_restore(&snap);
        drop_step();
        return COSIM_STALL;
    }
    if (faulted) {
        int vec = cpu_state.abrt & ABRT_MASK;
        uint32_t fault_cr2 = cr2, fault_err = abrt_error;
        if (vec == 14 && split_probe_n && (op == 0xA5 || op == 0xAB))
            split_string_store(op, d.a32, rep_string);
        if (!rep_string) {
            /* Precise: the faulting instruction leaves no trace, except the
             * pushes of an ENTER whose stack probe faulted. */
            if (!enter_cw) undo_ram();
            snap_restore(&snap);
            cr2 = fault_cr2;
            abrt_error = fault_err;
            /* The snapshot predates this instruction's own oldpc. */
            cpu_state.oldpc = pre_pc;
            oldcs = CS;
            oldcpl = CPL;
            if (!enter_cw) stage_w.head = stage_w.tail = 0;
            stage_io.head = stage_io.tail = 0;
            /* Except the first page's part of a split write that faulted
             * on the second (iss_split_write_first): it reached memory. */
            for (int k = 0; k < iss_partial_n; k++) {
                uint32_t pa = iss_partial_pa[k];
                uint8_t b = iss_partial_val[k];
                if (!wr_hook(pa, b)) ram[pa & rammask] = b;
            }
        }
        cpu_state.abrt = 0;
        flags_rebuild();                /* x86_doabrt pushes cpu_state.flags as is */
        if (vec != 1) cpu_state.eflags |= RF_FLAG;     /* see x86_int */
        x86_doabrt_2386(vec);
        cpu_state.eflags &= ~RF_FLAG;
        if (cpu_state.abrt) {
            fail("fault %d at %04x:%08x could not be delivered (fault %d)", vec, CS, pre_pc,
                 cpu_state.abrt & ABRT_MASK);
            return COSIM_ERROR;
        }
        last_fault = vec;
        udf = pre_udf;
        flags_rebuild();
    } else if (op == 0xF4) {
        /* HLT: 86Box keeps EIP on it; the next interrupt returns past it. */
        cpu_state.pc = pre_pc + 1;
        was_hlt = 1;
    }
    if (!faulted) {
        /* RF clears when an instruction completes, except IRET and POPF
         * (i486 PRM 11.3.1.1; z486's clear_rf). 86Box never clears it. */
        if (op != 0xCF && op != 0x9D) cpu_state.eflags &= ~RF_FLAG;
        uint8_t imm_last = peek_lin(cs + cpu_state.pc - 1);
        fx_t f = flag_effect(&d, pre_ecx, imm_last, (cpu_state.flags & F_Z) != 0);
        /* A shift or rotate of memory by 0: z486's 386 microcode still writes
         * the operand back unchanged (read-modify-write); 86Box writes
         * nothing. Record the same bytes as silent writes. */
        if ((op == 0xC0 || op == 0xC1 || op == 0xD2 || op == 0xD3) && d.mod != 3 &&
            (((op <= 0xC1) ? imm_last : pre_ecx) & 31) == 0) {
            const int n = (op & 1) ? (d.op32 ? 4 : 2) : 1;
            const uint32_t lin = cpu_state.ea_seg->base + cpu_state.eaaddr;
            for (int i = 0; i < n; i++) {
                const uint32_t pa = walk(lin + i, 1, 1);
                if (pa != 0xFFFFFFFFu && in_ram(pa)) wr_hook(pa, ram[pa & rammask]);
            }
        }
        if (is_logic_op(&d)) {
            /* AND/OR/XOR/TEST: AF is undefined; z486 clears it (as Intel
             * parts do), and its fast paths commit flags after the next
             * instruction issues, too late for z486_adopt_flags. */
            flags_rebuild();
            cpu_state.flags &= ~F_A;
            cpu_state.flags_op = FLAGS_UNKNOWN;
            f.ud &= ~F_A;
        }
        udf = (udf & ~(f.wr | (f.wr << 16))) | f.ud;
    }
    ninsn++;
    int r = commit_writes();
    if (faulted) {
        /* z486 can read before it finds the fault (a REP MOVS element
         * whose write faults: 86Box checks the write first). Those reads
         * are squashed work; the handler's come after this point. */
        dev_rd.head = dev_rd.tail;
        io_rd.head = io_rd.tail;
    }
    return r;
}

int cosim_step(void) { return run(-1); }
int cosim_step_rep_to(uint32_t count_left) { return run((long)count_left); }

int cosim_interrupt(int vector) {
    if (err[0]) return COSIM_ERROR;
    mem_log_reset();
    drop_step();
    /* Reads z486 made for work the interrupt squashed (the next element of
     * a REP string it cut, read again after the IRET) are not the
     * reference's; the handler's own reads come after this point. */
    dev_rd.head = dev_rd.tail;
    io_rd.head = io_rd.tail;
    flags_rebuild();
    cpu_state.abrt = 0;
    cpu_state.oldpc = cpu_state.pc;
    oldcs = CS;
    oldcpl = CPL;
    pccache = 0xFFFFFFFF;
    if (msw & 1)
        pmodeint_2386(vector, 0);
    else
        real_mode_int(vector);
    if (cpu_state.abrt) {
        fail("interrupt %02x could not be delivered (fault %d)", vector, cpu_state.abrt & ABRT_MASK);
        return COSIM_ERROR;
    }
    flags_rebuild();
    ninsn++;
    return commit_writes();
}

/* z486's flags after the last instruction: take the bits it left undefined. */
void cosim_adopt_flags(uint32_t dut_eflags) {
    const uint32_t m = (udf | (udf >> 16)) & F_ARITH;
    udf = (udf & 0xFFFF) << 16;
    if (!m) return;
    flags_rebuild();
    cpu_state.flags = (cpu_state.flags & ~m) | (dut_eflags & m);
    cpu_state.flags_op = FLAGS_UNKNOWN;
}

void cosim_dut_io_read(uint16_t port, uint8_t val) { q_push(&io_rd, port, val, 0); }
void cosim_dut_dev_read(uint32_t phys, uint8_t val) { q_push(&dev_rd, phys, val, 0); }
int cosim_dut_write(uint32_t phys, uint8_t val) { return match_write(platform_phys(phys), val); }
int cosim_dut_io_write(uint16_t port, uint8_t val) { return match_io(port, val); }

void cosim_dma_write(uint32_t phys, uint8_t val) {
    if (phys < ram_bytes) ram[phys & rammask] = val;
}

void cosim_walker_write(uint32_t phys, uint8_t val) {
    phys = platform_phys(phys);
    if (phys < ram_bytes) ram[phys & rammask] = val;
}

/* ============================================================
 * Checkpoints
 * ============================================================ */
#define COSIM_CKPT_MAGIC 0x43534D38u    /* CSM8: with RAM */
#define COSIM_CKPT_NORAM 0x43534D39u    /* CSM9: without */

static int wr(FILE *f, const void *p, size_t n) { return fwrite(p, 1, n, f) == n ? 0 : -1; }
static int rd(FILE *f, void *p, size_t n) { return fread(p, 1, n, f) == n ? 0 : -1; }

static int save_q(FILE *f, const q_t *q) {
    uint64_t n = q->tail - q->head;
    if (wr(f, &n, sizeof(n))) return -1;
    return n ? wr(f, q->v + q->head, n * sizeof(ev_t)) : 0;
}

static int load_q(FILE *f, q_t *q) {
    uint64_t n;
    if (rd(f, &n, sizeof(n))) return -1;
    q->head = q->tail = 0;
    for (uint64_t i = 0; i < n; i++) {
        ev_t e;
        if (rd(f, &e, sizeof(e))) return -1;
        q_push_ev(q, e);
    }
    return 0;
}

static int save_ex(FILE *f, int with_ram);
static int load_ex(FILE *f, int with_ram);
int cosim_save(void *file) { return save_ex(file, 1); }
int cosim_load(void *file) { return load_ex(file, 1); }
int cosim_save_noram(void *file) { return save_ex(file, 0); }
int cosim_load_noram(void *file) { return load_ex(file, 0); }

static int save_ex(FILE *f, int with_ram) {
    uint32_t magic = with_ram ? COSIM_CKPT_MAGIC : COSIM_CKPT_NORAM;
    snap_t s;
    snap_save(&s);
    if (wr(f, &magic, sizeof(magic)) || wr(f, &s, sizeof(s)) || wr(f, &ram_bytes, sizeof(ram_bytes)) ||
        wr(f, &a20_on, sizeof(a20_on)) || wr(f, &ninsn, sizeof(ninsn)) ||
        wr(f, &last_fault, sizeof(last_fault)) || wr(f, &was_hlt, sizeof(was_hlt)) ||
        wr(f, &udf, sizeof(udf)) || wr(f, err, sizeof(err)) || wr(f, hist, sizeof(hist)) ||
        (with_ram && wr(f, ram, ram_bytes)))
        return -1;
    const q_t *qs[] = { &io_rd, &dev_rd, &exp_w, &dut_w, &exp_io, &dut_io };
    for (size_t i = 0; i < sizeof(qs) / sizeof(qs[0]); i++)
        if (save_q(f, qs[i])) return -1;
    return 0;
}

static int load_ex(FILE *f, int with_ram) {
    uint32_t magic, bytes;
    snap_t s;
    if (rd(f, &magic, sizeof(magic)) || magic != (with_ram ? COSIM_CKPT_MAGIC : COSIM_CKPT_NORAM))
        return -1;
    if (rd(f, &s, sizeof(s)) || rd(f, &bytes, sizeof(bytes)) || bytes != ram_bytes) return -1;
    if (rd(f, &a20_on, sizeof(a20_on)) || rd(f, &ninsn, sizeof(ninsn)) ||
        rd(f, &last_fault, sizeof(last_fault)) || rd(f, &was_hlt, sizeof(was_hlt)) ||
        rd(f, &udf, sizeof(udf)) || rd(f, err, sizeof(err)) || rd(f, hist, sizeof(hist)) ||
        (with_ram && rd(f, ram, ram_bytes)))
        return -1;
    snap_restore(&s);
    pccache = 0xFFFFFFFF;
    q_t *qs[] = { &io_rd, &dev_rd, &exp_w, &dut_w, &exp_io, &dut_io };
    for (size_t i = 0; i < sizeof(qs) / sizeof(qs[0]); i++)
        if (load_q(f, qs[i])) return -1;
    io_cur = dev_cur = 0;
    stage_w.head = stage_w.tail = stage_io.head = stage_io.tail = 0;
    return 0;
}

