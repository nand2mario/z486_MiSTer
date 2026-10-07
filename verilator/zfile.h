// zstd-compressed files through the zstd command (no library headers here).
// A path ending in ".zst" is compressed; any other path is a plain file.
#pragma once
#include <cstdio>
#include <string>

inline bool zfile_is_zst(const std::string& path) {
    return path.size() > 4 && path.compare(path.size() - 4, 4, ".zst") == 0;
}

inline std::string zfile_quote(const std::string& s) {
    std::string q = "'";
    for (char c : s) q += (c == '\'') ? std::string("'\\''") : std::string(1, c);
    return q + "'";
}

inline FILE* zfile_open_write(const std::string& path) {
    if (!zfile_is_zst(path)) return fopen(path.c_str(), "wb");
    return popen(("zstd -q -1 -T0 -f -o " + zfile_quote(path)).c_str(), "w");
}

inline FILE* zfile_open_read(const std::string& path) {
    if (!zfile_is_zst(path)) return fopen(path.c_str(), "rb");
    return popen(("zstd -q -dc " + zfile_quote(path)).c_str(), "r");
}

// True when everything reached the file.
inline bool zfile_close(FILE* f, const std::string& path) {
    if (!f) return false;
    return zfile_is_zst(path) ? pclose(f) == 0 : fclose(f) == 0;
}
