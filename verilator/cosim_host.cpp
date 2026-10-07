// Full-system co-simulation host (see cosim_host.h).
//
// Each clock, before the rising edge, the z486 taps are read in this order:
// CPU reset, DMA writes, the data-request port (writes are compared, reads
// are queued until they complete), completions (I/O and device data, INTA
// vectors), direct stores, then the issue of an instruction. The reference
// runs instruction k when z486 issues k+1, so k's reads have normally
// returned; when one has not, the step is retried on a later clock.
#include "cosim_host.h"

#include "Vz486_mister_sim.h"
#include "Vz486_mister_sim__Syms.h"
#include "Vz486_mister_sim_z486_mister_sim.h"
#include "Vz486_mister_sim__Dpi.h"
#include "svdpi.h"
#include "zfile.h"
#include "cosim/cosim86.h"

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>
#include <cstdlib>
#include <deque>
#include <vector>

namespace {

enum { K_IO = 1, K_INTA = 2, K_X87 = 4, K_DEV = 8, K_WALK = 16 };

struct IssueEv { uint32_t eip; uint32_t ecx; uint32_t eflags; uint64_t t; uint32_t gpr[8]; };
struct ReadReq { uint32_t addr; uint8_t be; uint8_t kind; };

Vz486_mister_sim* g_tb = nullptr;
unsigned g_ram_mb = 0;
bool g_trace = false;          // COSIM_TRACE=1: log interrupts and vectors
bool g_running = false;         // the CPU is out of reset and the reference follows it
bool g_failed = false;
bool g_have_cur = false;        // z486 issued an instruction the reference has not run
bool g_squash_ok = false;       // the last step faulted: one younger issue may be squashed
bool g_ram_copied = true;        // the reference has z486's RAM since the last reset
bool g_snap_candidate = false;  // this clock issued an instruction with no other transfer
uint32_t g_arch[COSIM_ARCH_WORDS];
std::deque<IssueEv> g_issues;
std::deque<ReadReq> g_reads;
std::deque<uint8_t> g_vectors;
struct WriteLog { uint64_t t; uint32_t addr; uint8_t val; char port; };
WriteLog g_wlog[16];
unsigned g_wlog_n = 0;

void log_write(uint64_t t, uint32_t addr, uint8_t val, char port) {
    g_wlog[g_wlog_n++ % 16] = { t, addr, val, port };
}
uint64_t g_issued = 0, g_irqs = 0, g_stalls = 0, g_squashed = 0, g_resets = 0;
uint64_t g_cycles = 0, g_reset_cycles = 0, g_issue_raw = 0;

void diverge(const char* what, uint64_t t) {
    printf("%llu: COSIM DIVERGENCE: %s\n", (unsigned long long)t, what);
    printf("  reference at %04x:%08x after %llu instructions; z486 issued %llu\n",
           cosim_cs(), cosim_eip(), (unsigned long long)cosim_instructions(),
           (unsigned long long)g_issued);
    printf("  recent reference instructions (state before each):\n");
    cosim_dump_history();
    cosim_dump_writes();
    printf("  z486's last writes (d = data request, f = direct store, i = I/O):\n");
    for (unsigned k = g_wlog_n > 16 ? g_wlog_n - 16 : 0; k < g_wlog_n; k++) {
        const WriteLog& w = g_wlog[k % 16];
        printf("    %llu %c %08x=%02x\n", (unsigned long long)w.t, w.port, w.addr, w.val);
    }
    fflush(stdout);
    g_failed = true;
}

void copy_ram() {
    auto& mem = g_tb->z486_mister_sim->simulated_de10_guest_memory__DOT__memory__DOT__mem;
    uint8_t* r = cosim_ram();
    const size_t n = size_t(g_ram_mb) << 20;
    for (size_t a = 0; a < n; a += 2) {
        uint16_t w = mem[a >> 1];
        r[a] = w & 0xFF;
        r[a + 1] = w >> 8;
    }
}

// General registers at each issue against the reference's state before that
// instruction. z486's view can trail by a load still in flight, so only a
// register that differs at kRegPersist consecutive issues is a divergence.
constexpr unsigned kRegPersist = 64;
unsigned g_reg_miss[8];
uint64_t g_reg_first[8];
const char* const kRegName[8] = { "EAX", "ECX", "EDX", "EBX", "ESP", "EBP", "ESI", "EDI" };

bool check_registers(const IssueEv& ev) {
    for (int r = 0; r < 8; r++) {
        const uint32_t ref = cosim_reg(r);
        if (ev.gpr[r] == ref) {
            g_reg_miss[r] = 0;
            continue;
        }
        if (g_reg_miss[r]++ == 0) g_reg_first[r] = cosim_instructions();
        if (g_reg_miss[r] >= kRegPersist) {
            char msg[200];
            snprintf(msg, sizeof(msg), "%s: z486 %08x, reference %08x, differing since instruction #%llu",
                     kRegName[r], ev.gpr[r], ref, (unsigned long long)g_reg_first[r]);
            diverge(msg, ev.t);
            printf("  the reference around the first difference:\n");
            cosim_dump_history_from(g_reg_first[r] > 6 ? g_reg_first[r] - 6 : 0, 10);
            return false;
        }
    }
    return true;
}

bool process_issues() {
    while (!g_issues.empty()) {
        const IssueEv ev = g_issues.front();
        if (g_have_cur) {
            // An IRQ acknowledged since this instruction issued may have cut a
            // REP string short: z486's count at the handler says where.
            int r = (!g_vectors.empty() && cosim_at_rep_string()) ? cosim_step_rep_to(ev.ecx)
                                                                   : cosim_step();
            if (r == COSIM_STALL) {
                g_stalls++;
                return true;
            }
            if (r == COSIM_ERROR) {
                diverge(cosim_error(), ev.t);
                return false;
            }
            g_have_cur = false;
            g_squash_ok = cosim_last_fault() >= 0;
            cosim_adopt_flags(ev.eflags);
        }
        // z486 took a hardware interrupt at this boundary.
        if (cosim_eip() != ev.eip && !g_vectors.empty()) {
            int v = g_vectors.front();
            g_vectors.pop_front();
            g_irqs++;
            if (g_trace)
                printf("%llu: cosim irq %02x at %04x:%08x -> z486 %08x\n", (unsigned long long)ev.t, v,
                       cosim_cs(), cosim_eip(), ev.eip);
            if (cosim_interrupt(v) != COSIM_OK) {
                diverge(cosim_error(), ev.t);
                return false;
            }
        }
        if (cosim_eip() != ev.eip && g_squash_ok) {
            // A younger instruction z486 issued before an older one's fault
            // was delivered; the next issue is the handler.
            g_squash_ok = false;
            g_squashed++;
            g_issues.pop_front();
            continue;
        }
        if (cosim_eip() != ev.eip) {
            // An instruction fetch fault: z486 enters the handler without
            // issuing the faulting instruction, which the reference still runs.
            int r = cosim_step();
            if (r == COSIM_ERROR || cosim_last_fault() < 0 || cosim_eip() != ev.eip) {
                char msg[256];
                snprintf(msg, sizeof(msg), "z486 issued EIP %08x; the reference is at %08x",
                         ev.eip, cosim_eip());
                diverge(r == COSIM_ERROR ? cosim_error() : msg, ev.t);
                return false;
            }
        }
        g_squash_ok = false;
        g_have_cur = true;
        if (!check_registers(ev)) return false;
        g_issues.pop_front();
    }
    return true;
}

}  // namespace

void cosim_host_enable(Vz486_mister_sim* tb, unsigned ram_mb) {
    g_tb = tb;
    g_ram_mb = ram_mb;
    g_trace = getenv("COSIM_TRACE") != nullptr;
    cosim_init(ram_mb << 20);
    printf("cosim: 86Box reference, %u MB, checking issue EIPs and memory/I/O writes\n", ram_mb);
}

bool cosim_host_cycle(uint64_t t) {
    if (!g_tb || g_failed) return !g_failed;
    Vz486_mister_sim& tb = *g_tb;
    g_cycles++;
    if (tb.cosim_issue) g_issue_raw++;
    if (!tb.cosim_cpu_reset_n) g_reset_cycles++;

    if (!tb.cosim_cpu_reset_n) {
        if (g_running) g_resets++;
        g_running = false;
        return true;
    }
    if (!g_running) {
        // Out of reset (after the BIOS copy, or a warm reset): the reference
        // starts at the reset vector with z486's RAM, copied at the first
        // issue (the copier's last write lands after reset ends).
        g_ram_copied = false;
        cosim_reset();
        g_issues.clear();
        g_reads.clear();
        g_vectors.clear();
        g_have_cur = false;
        g_squash_ok = false;
        g_running = true;
    }
    cosim_set_a20(tb.cosim_a20);

    if (tb.cosim_dma_wr) {
        for (int i = 0; i < 4; i++)
            if (tb.cosim_dma_be & (1 << i))
                cosim_dma_write((tb.cosim_dma_addr & ~3u) + i, (tb.cosim_dma_wdata >> (8 * i)) & 0xFF);
    }

    if (tb.cosim_dreq_acc) {
        const uint8_t kind = tb.cosim_dreq_kind;
        const uint32_t base = tb.cosim_dreq_addr & ~3u;
        if (tb.cosim_dreq_write) {
            const uint32_t data = (kind & K_IO) ? tb.cosim_dreq_wdata_direct : tb.cosim_dreq_wdata;
            for (int i = 0; i < 4; i++) {
                if (!(tb.cosim_dreq_be & (1 << i))) continue;
                const uint8_t b = (data >> (8 * i)) & 0xFF;
                if (kind & K_WALK) {
                    cosim_walker_write(base + i, b);
                } else if (kind & K_X87) {
                    // x87 port cycles: none with the FPU off.
                } else if (kind & K_IO) {
                    log_write(t, base + i, b, 'i');
                    if (g_trace)
                        printf("%llu: cosim io write %08x = %02x (issue %llu)\n", (unsigned long long)t,
                               base + i, b, (unsigned long long)g_issued);
                    if (cosim_dut_io_write(uint16_t(base + i), b) != COSIM_OK) {
                        diverge(cosim_error(), t);
                        return false;
                    }
                } else if (log_write(t, base + i, b, 'd'), cosim_dut_write(base + i, b) != COSIM_OK) {
                    diverge(cosim_error(), t);
                    return false;
                }
            }
        } else {
            g_reads.push_back({ tb.cosim_dreq_addr, uint8_t(tb.cosim_dreq_be), kind });
        }
    }

    if (tb.cosim_drd_done) {
        if (g_reads.empty()) {
            diverge("a data read completed with none outstanding", t);
            return false;
        }
        const ReadReq rq = g_reads.front();
        g_reads.pop_front();
        const uint32_t base = rq.addr & ~3u;
        const uint32_t data = tb.cosim_drd_data;
        if (rq.kind & K_INTA) {
            // Two acknowledge cycles per interrupt, as a 486: the vector comes
            // with the second (address 0); the first (address 4) carries none.
            if (!(rq.addr & 4)) g_vectors.push_back(data & 0xFF);
            if (g_trace)
                printf("%llu: cosim inta %08x (addr %08x)\n", (unsigned long long)t, data, rq.addr);
        } else if (!(rq.kind & (K_WALK | K_X87))) {
            for (int i = 0; i < 4; i++) {
                if (!(rq.be & (1 << i))) continue;
                const uint8_t b = (data >> (8 * i)) & 0xFF;
                if (rq.kind & K_IO) cosim_dut_io_read(uint16_t(base + i), b);
                else if (rq.kind & K_DEV) cosim_dut_dev_read(base + i, b);
                if (g_trace && (rq.kind & (K_IO | K_DEV)))
                    printf("%llu: cosim %s read %08x = %02x (issue %llu)\n", (unsigned long long)t,
                           (rq.kind & K_IO) ? "io" : "dev", base + i, b, (unsigned long long)g_issued);
            }
        }
    }

    if (tb.cosim_fst_acc) {
        const uint32_t base = tb.cosim_fst_addr & ~3u;
        for (int i = 0; i < 4; i++) {
            if (!(tb.cosim_fst_be & (1 << i))) continue;
            const uint8_t b = (tb.cosim_fst_wdata >> (8 * i)) & 0xFF;
            log_write(t, base + i, b, 'f');
            if (cosim_dut_write(base + i, b) != COSIM_OK) {
                diverge(cosim_error(), t);
                return false;
            }
        }
    }

    if (tb.cosim_issue) {
        if (!g_ram_copied) {
            copy_ram();
            g_ram_copied = true;
        }
        IssueEv ev = { tb.cosim_issue_eip, tb.cosim_ecx, tb.cosim_eflags, t, {} };
        for (int r = 0; r < 8; r++) ev.gpr[r] = tb.cosim_gprs[r];
        g_issues.push_back(ev);
        g_issued++;
    }
    if (!g_issues.empty() && !process_issues()) return false;
    g_snap_candidate = tb.cosim_issue && !tb.cosim_dreq_acc && !tb.cosim_fst_acc &&
                       !tb.cosim_drd_done && !tb.cosim_dma_wr && g_have_cur && g_issues.empty() &&
                       g_reads.empty() && g_vectors.empty();
    return true;
}

extern uint64_t g_snap_polls, g_snap_cand, g_snap_quiet, g_snap_idle;
void cosim_host_report() {
    if (!g_tb) return;
    printf("cosim: %s; z486 issued %llu, reference ran %llu (irqs %llu, squashed %llu, "
           "stalls %llu, resets %llu)\n",
           g_failed ? "DIVERGED" : "no divergence", (unsigned long long)g_issued,
           (unsigned long long)cosim_instructions(), (unsigned long long)g_irqs,
           (unsigned long long)g_squashed, (unsigned long long)g_stalls,
           (unsigned long long)g_resets);
    if (g_snap_polls)
        printf("cosim: snapshot polls %llu, candidates %llu, bus quiet %llu, idle %llu\n",
               (unsigned long long)g_snap_polls, (unsigned long long)g_snap_cand,
               (unsigned long long)g_snap_quiet, (unsigned long long)g_snap_idle);
    printf("cosim: %llu clocks, %llu in CPU reset, %llu issue pulses\n",
           (unsigned long long)g_cycles, (unsigned long long)g_reset_cycles,
           (unsigned long long)g_issue_raw);
}

namespace {
template <typename T> bool put(FILE* f, const T& v) { return fwrite(&v, sizeof(v), 1, f) == 1; }
template <typename T> bool get(FILE* f, T& v) { return fread(&v, sizeof(v), 1, f) == 1; }
template <typename T> bool put_dq(FILE* f, const std::deque<T>& d) {
    uint64_t n = d.size();
    if (!put(f, n)) return false;
    for (const T& v : d) if (!put(f, v)) return false;
    return true;
}
template <typename T> bool get_dq(FILE* f, std::deque<T>& d) {
    uint64_t n;
    if (!get(f, n)) return false;
    d.clear();
    for (uint64_t i = 0; i < n; i++) {
        T v;
        if (!get(f, v)) return false;
        d.push_back(v);
    }
    return true;
}
}  // namespace

namespace {
bool host_write(FILE* f, bool with_ram) {
    return (with_ram ? cosim_save(f) : cosim_save_noram(f)) == 0 && put(f, g_running) && put(f, g_failed) && put(f, g_have_cur) &&
              put(f, g_squash_ok) && put_dq(f, g_issues) && put_dq(f, g_reads) &&
              put_dq(f, g_vectors) && put(f, g_issued) && put(f, g_irqs) && put(f, g_stalls) &&
              put(f, g_squashed) && put(f, g_resets) && put(f, g_wlog) && put(f, g_wlog_n);
}

bool host_read(FILE* f, bool with_ram) {
    return (with_ram ? cosim_load(f) : cosim_load_noram(f)) == 0 && get(f, g_running) && get(f, g_failed) && get(f, g_have_cur) &&
              get(f, g_squash_ok) && get_dq(f, g_issues) && get_dq(f, g_reads) &&
              get_dq(f, g_vectors) && get(f, g_issued) && get(f, g_irqs) && get(f, g_stalls) &&
              get(f, g_squashed) && get(f, g_resets) && get(f, g_wlog) && get(f, g_wlog_n);
}
}  // namespace

bool cosim_host_save(const char* path) {
    FILE* f = fopen(path, "wb");
    if (!f) return false;
    const bool ok = host_write(f, true);
    return (fclose(f) == 0) && ok;
}

bool cosim_host_load(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return false;
    const bool ok = host_read(f, true);
    fclose(f);
    if (ok) printf("cosim: restored at instruction %llu\n", (unsigned long long)cosim_instructions());
    return ok;
}

// The words of z486_mister_sim.sv's cosim_load_arch.
extern "C" unsigned int cosim_arch_word(int idx) {
    return idx >= 0 && idx < COSIM_ARCH_WORDS ? g_arch[idx] : 0;
}

uint64_t g_snap_polls = 0, g_snap_cand = 0, g_snap_quiet = 0, g_snap_idle = 0;

bool cosim_host_snapshot_ready() {
    g_snap_polls++;
    if (!g_tb || !g_running || g_failed || !g_snap_candidate) return false;
    g_snap_cand++;
    const Vz486_mister_sim& tb = *g_tb;
    if (!tb.cosim_cpu_reset_n || !tb.cosim_bus_quiet) return false;
    g_snap_quiet++;
    if (tb.cosim_issue || tb.cosim_dreq_acc || tb.cosim_fst_acc || tb.cosim_drd_done || tb.cosim_dma_wr)
        return false;
    g_snap_idle++;
    return cosim_snapshot_ok();
}

size_t cosim_host_compare_ram() {
    auto& mem = g_tb->z486_mister_sim->simulated_de10_guest_memory__DOT__memory__DOT__mem;
    const uint8_t* r = cosim_ram();
    const size_t n = size_t(g_ram_mb) << 20;
    size_t diffs = 0;
    for (size_t a = 0; a < n; a += 2) {
        if (a >= 0xA0000 && a < 0xC0000) continue;
        const uint16_t w = mem[a >> 1];
        for (int i = 0; i < 2; i++) {
            const uint8_t m = (w >> (8 * i)) & 0xFF;
            if (m != r[a + i] && diffs++ < 8)
                printf("cosim: RAM %08zx: reference %02x, SDRAM %02x\n", a + i, r[a + i], m);
        }
    }
    return diffs;
}

// Snapshot RAM: a keyframe (the whole RAM) in <snapshots>/keys, and in each
// snapshot the 4 KB pages that differ from it. A new keyframe when a quarter
// of the pages differ or after 32 snapshots.
namespace {
constexpr uint32_t kRamDiffMagic = 0x46445241;  // ARDF
constexpr size_t kPage = 4096;
std::vector<uint8_t> g_key_ram;
std::string g_key_name;
unsigned g_key_uses = 0;

void ram_to_sdram() {
    // The reference RAM is architectural: z486's caches and buffers are
    // empty after a restore, so SDRAM takes this copy (A0000-BFFFF is the
    // VGA's and stays as it is).
    auto& mem = g_tb->z486_mister_sim->simulated_de10_guest_memory__DOT__memory__DOT__mem;
    const uint8_t* r = cosim_ram();
    const size_t n = size_t(g_ram_mb) << 20;
    for (size_t a = 0; a < n; a += 2) {
        if (a >= 0xA0000 && a < 0xC0000) continue;
        mem[a >> 1] = uint16_t(r[a] | (r[a + 1] << 8));
    }
}
}  // namespace

bool cosim_host_save_portable(const std::string& dir, const std::string& keydir, uint64_t cycle,
                              std::string& key_name) {
    const std::string cpath = dir + "/cosim.bin.zst";
    FILE* f = zfile_open_write(cpath);
    if (!f) return false;
    bool ok = host_write(f, false);
    ok = zfile_close(f, cpath) && ok;

    const uint8_t* ram = cosim_ram();
    const size_t bytes = size_t(g_ram_mb) << 20, pages = bytes / kPage;
    std::vector<uint32_t> diff;
    if (g_key_ram.size() == bytes) {
        for (size_t p = 0; p < pages; p++)
            if (memcmp(ram + p * kPage, g_key_ram.data() + p * kPage, kPage)) diff.push_back(uint32_t(p));
    }
    if (g_key_ram.size() != bytes || diff.size() > pages / 4 || g_key_uses >= 32) {
        char name[64];
        snprintf(name, sizeof(name), "key_%016llu.ram.zst", (unsigned long long)cycle);
        std::filesystem::create_directories(keydir);
        const std::string kpath = keydir + "/" + name;
        FILE* k = zfile_open_write(kpath);
        if (!k) return false;
        ok = fwrite(ram, 1, bytes, k) == bytes && ok;
        ok = zfile_close(k, kpath) && ok;
        g_key_ram.assign(ram, ram + bytes);
        g_key_name = name;
        g_key_uses = 0;
        diff.clear();
    }
    g_key_uses++;
    key_name = g_key_name;

    const std::string dpath = dir + "/ram.diff.zst";
    FILE* d = zfile_open_write(dpath);
    if (!d) return false;
    const uint32_t n = uint32_t(diff.size()), len = uint32_t(g_key_name.size());
    ok = put(d, kRamDiffMagic) && put(d, uint64_t(bytes)) && put(d, len) &&
         fwrite(g_key_name.data(), 1, len, d) == len && put(d, n) && ok;
    for (uint32_t p : diff)
        ok = put(d, p) && fwrite(ram + size_t(p) * kPage, 1, kPage, d) == kPage && ok;
    ok = zfile_close(d, dpath) && ok;
    printf("cosim: snapshot RAM = %s + %u pages\n", g_key_name.c_str(), n);
    return ok;
}

bool cosim_host_load_portable(const std::string& dir) {
    namespace fs = std::filesystem;
    if (fs::exists(dir + "/cosim.bin.zst")) {
        const std::string cpath = dir + "/cosim.bin.zst";
        FILE* f = zfile_open_read(cpath);
        if (!f) return false;
        const bool ok = host_read(f, false);
        zfile_close(f, cpath);
        if (!ok) return false;
        const std::string dpath = dir + "/ram.diff.zst";
        FILE* d = zfile_open_read(dpath);
        if (!d) return false;
        uint32_t magic = 0, len = 0, n = 0;
        uint64_t bytes = 0;
        std::string key;
        bool rok = get(d, magic) && magic == kRamDiffMagic && get(d, bytes) &&
                   bytes == (uint64_t(g_ram_mb) << 20) && get(d, len);
        if (rok) {
            key.resize(len);
            rok = fread(&key[0], 1, len, d) == len && get(d, n);
        }
        const std::string kpath = (fs::path(dir).parent_path() / "keys" / key).string();
        FILE* k = rok ? zfile_open_read(kpath) : nullptr;
        rok = k && fread(cosim_ram(), 1, bytes, k) == bytes && rok;
        if (k) zfile_close(k, kpath);
        for (uint32_t i = 0; rok && i < n; i++) {
            uint32_t p = 0;
            rok = get(d, p) && size_t(p) * kPage < bytes &&
                  fread(cosim_ram() + size_t(p) * kPage, 1, kPage, d) == kPage;
        }
        zfile_close(d, dpath);
        if (!rok) {
            printf("cosim: cannot rebuild RAM from %s and %s\n", dpath.c_str(), kpath.c_str());
            return false;
        }
        printf("cosim: restored at instruction %llu (RAM %s + %u pages)\n",
               (unsigned long long)cosim_instructions(), key.c_str(), n);
    } else if (!cosim_host_load((dir + "/cosim.bin").c_str())) {
        return false;
    }
    ram_to_sdram();
    // z486 restarts at the instruction it had just issued.
    g_issues.clear();
    g_reads.clear();
    g_vectors.clear();
    g_have_cur = false;
    g_squash_ok = false;
    g_snap_candidate = false;
    for (unsigned& m : g_reg_miss) m = 0;
    g_running = true;
    g_failed = false;
    cosim_arch(g_arch);
    svSetScope(svGetScopeFromName("TOP.z486_mister_sim"));
    cosim_load_arch();
    printf("cosim: z486 restored at %04x:%08x (CR0 %08x CR3 %08x EFLAGS %08x)\n", g_arch[22], g_arch[8],
           g_arch[10], g_arch[12], g_arch[9]);
    return true;
}

