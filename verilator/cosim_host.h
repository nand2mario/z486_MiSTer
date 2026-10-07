// Full-system co-simulation host: z486 in the MiSTer sim against the 86Box
// CPU core (cosim/cosim86.c), checked in program
// order: the EIP of every issued instruction, every memory and I/O write.
#pragma once
#include <cstddef>
#include <cstdint>
#include <string>

class Vz486_mister_sim;

// Enable before the first clock; ram_mb as the guest sees it.
void cosim_host_enable(Vz486_mister_sim* tb, unsigned ram_mb);
// Once per clock, after the falling-edge evaluation (the taps then show the
// transfers of the coming rising edge). Returns false after a divergence.
bool cosim_host_cycle(uint64_t sim_time);
void cosim_host_report();
// With the sim's checkpoints (--checkpoint-dir / --restore): the reference
// and the host's queues, in <checkpoint>/cosim.bin.
bool cosim_host_save(const char* path);
bool cosim_host_load(const char* path);

// Portable snapshots (snapshot.h). Ready at the start of a clock when the last
// one issued an instruction and nothing has moved since: no CPU bus cycle,
// every reference write matched, no interrupt shadow. The state is then that
// before the issued instruction, which a restored z486 issues again.
bool cosim_host_snapshot_ready();
// Reference RAM against the SDRAM model (outside A0000-BFFFF); returns the
// number of differing bytes and prints the first few.
size_t cosim_host_compare_ram();
// Snapshot: the reference in <dir>/cosim.bin.zst, its RAM as a keyframe in
// keydir plus the pages that differ (<dir>/ram.diff.zst); key_name is set to
// the keyframe used.
bool cosim_host_save_portable(const std::string& dir, const std::string& keydir, uint64_t cycle,
                              std::string& key_name);
// Restore: the reference, then SDRAM from its RAM and z486's architectural
// state from it (the CPU must be fresh from reset). Keyframes are looked up
// in <dir>/../keys.
bool cosim_host_load_portable(const std::string& dir);
