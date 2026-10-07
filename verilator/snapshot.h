// Portable snapshots: the simulated system outside the CPU, saved and restored
// by hierarchical name (the table is generated from the verilated model by
// gen_state_table.py), so a snapshot taken with one build restores into
// another as long as the peripherals' state keeps its names and sizes. The
// CPU's architectural state comes from the co-simulation reference
// (cosim_host); its microarchitecture starts from reset.
#pragma once
#include <cstddef>
#include <string>
#include <vector>

class Vz486_mister_sim;

struct SnapshotField {
    const char* name;
    void* ptr;
    size_t size;
};

// Generated (obj_dir/state_table.cpp).
void snapshot_state_table(Vz486_mister_sim* tb, std::vector<SnapshotField>& out);

// Fields whose name contains one of `skip` are left out (state restored
// another way, such as guest RAM from the co-simulation reference). A path
// ending in .zst is compressed.
bool snapshot_save_state(Vz486_mister_sim* tb, const std::string& path,
                         const std::vector<std::string>& skip = {});
// Copies back every saved field whose name and size match this model, and
// reports the rest. False only when the file can't be read.
bool snapshot_load_state(Vz486_mister_sim* tb, const std::string& path);
