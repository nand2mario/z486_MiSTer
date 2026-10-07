// Portable snapshots (see snapshot.h). state.bin: "ZSNP", version, field
// count, then per field the name, its size and its bytes.
#include "snapshot.h"
#include "zfile.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <unordered_map>

namespace {
constexpr uint32_t kMagic = 0x504E535A;  // ZSNP
constexpr uint32_t kVersion = 1;

template <typename T> bool put(FILE* f, const T& v) { return fwrite(&v, sizeof(v), 1, f) == 1; }
template <typename T> bool get(FILE* f, T& v) { return fread(&v, sizeof(v), 1, f) == 1; }
}  // namespace

bool snapshot_save_state(Vz486_mister_sim* tb, const std::string& path,
                         const std::vector<std::string>& skip) {
    std::vector<SnapshotField> all, fields;
    snapshot_state_table(tb, all);
    for (const SnapshotField& fd : all) {
        bool keep = true;
        for (const std::string& k : skip) keep = keep && !strstr(fd.name, k.c_str());
        if (keep) fields.push_back(fd);
    }
    FILE* f = zfile_open_write(path);
    if (!f) return false;
    bool ok = put(f, kMagic) && put(f, kVersion) && put(f, uint32_t(fields.size()));
    for (const SnapshotField& fd : fields) {
        if (!ok) break;
        const uint16_t len = uint16_t(strlen(fd.name));
        const uint64_t size = fd.size;
        ok = put(f, len) && fwrite(fd.name, 1, len, f) == len && put(f, size) &&
             fwrite(fd.ptr, 1, fd.size, f) == fd.size;
    }
    ok = zfile_close(f, path) && ok;
    return ok;
}

bool snapshot_load_state(Vz486_mister_sim* tb, const std::string& path) {
    std::vector<SnapshotField> fields;
    snapshot_state_table(tb, fields);
    std::unordered_map<std::string, const SnapshotField*> by_name;
    for (const SnapshotField& fd : fields) by_name[fd.name] = &fd;

    FILE* f = zfile_open_read(path);
    if (!f) return false;
    auto fail = [&]() { zfile_close(f, path); return false; };
    uint32_t magic = 0, version = 0, count = 0;
    if (!get(f, magic) || !get(f, version) || !get(f, count) || magic != kMagic || version != kVersion)
        return fail();
    size_t restored = 0, missing = 0, resized = 0;
    std::vector<char> name;
    std::vector<uint8_t> skip;
    for (uint32_t k = 0; k < count; k++) {
        uint16_t len = 0;
        uint64_t size = 0;
        if (!get(f, len)) return fail();
        name.resize(len);
        if (fread(name.data(), 1, len, f) != len || !get(f, size)) return fail();
        const std::string key(name.data(), len);
        auto it = by_name.find(key);
        if (it != by_name.end() && it->second->size == size) {
            if (fread(it->second->ptr, 1, size, f) != size) return fail();
            by_name.erase(it);
            restored++;
            continue;
        }
        if (it == by_name.end()) {
            if (missing++ < 8) printf("snapshot: %s is not in this model\n", key.c_str());
        } else {
            if (resized++ < 8)
                printf("snapshot: %s changed size (%llu -> %zu bytes), left at reset\n", key.c_str(),
                       (unsigned long long)size, it->second->size);
            by_name.erase(it);
        }
        skip.resize(size);
        if (fread(skip.data(), 1, size, f) != size) return fail();
    }
    zfile_close(f, path);
    size_t added = 0;
    for (const auto& kv : by_name)
        if (added++ < 8) printf("snapshot: %s is new, left at reset\n", kv.first.c_str());
    printf("snapshot: restored %zu fields (%zu gone, %zu resized, %zu new)\n", restored, missing,
           resized, by_name.size());
    return true;
}
