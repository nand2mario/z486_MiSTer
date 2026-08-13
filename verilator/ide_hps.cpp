#include "ide_hps.h"

#include <algorithm>
#include <cstring>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>

using std::cout;
using std::ifstream;
using std::ios;
using std::string;
extern uint64_t g_ide_time;  // = sim_time (main.cpp), for IDE log timestamps

template <typename T>
static void write_pod(std::ostream& out, const T& value) {
    out.write(reinterpret_cast<const char*>(&value), sizeof(value));
}

template <typename T>
static void read_pod(std::istream& in, T& value) {
    in.read(reinterpret_cast<char*>(&value), sizeof(value));
}

static void write_string(std::ostream& out, const std::string& value) {
    uint32_t size = static_cast<uint32_t>(value.size());
    write_pod(out, size);
    out.write(value.data(), size);
}

static void read_string(std::istream& in, std::string& value) {
    uint32_t size = 0;
    read_pod(in, size);
    value.resize(size);
    in.read(value.data(), size);
}

static void write_vector_u8(std::ostream& out, const std::vector<uint8_t>& value) {
    uint64_t size = static_cast<uint64_t>(value.size());
    write_pod(out, size);
    if (size) out.write(reinterpret_cast<const char*>(value.data()), static_cast<std::streamsize>(size));
}

static void read_vector_u8(std::istream& in, std::vector<uint8_t>& value) {
    uint64_t size = 0;
    read_pod(in, size);
    value.resize(static_cast<size_t>(size));
    if (size) in.read(reinterpret_cast<char*>(value.data()), static_cast<std::streamsize>(size));
}

static void write_regs(std::ostream& out, const HpsIdeRegs& regs) {
    write_pod(out, regs.io_size);
    write_pod(out, regs.error);
    write_pod(out, regs.sector_count);
    write_pod(out, regs.sector);
    write_pod(out, regs.cylinder);
    write_pod(out, regs.head);
    write_pod(out, regs.drv);
    write_pod(out, regs.lba);
    write_pod(out, regs.cmd);
    write_pod(out, regs.pkt_io_size);
    write_pod(out, regs.status);
}

static void read_regs(std::istream& in, HpsIdeRegs& regs) {
    read_pod(in, regs.io_size);
    read_pod(in, regs.error);
    read_pod(in, regs.sector_count);
    read_pod(in, regs.sector);
    read_pod(in, regs.cylinder);
    read_pod(in, regs.head);
    read_pod(in, regs.drv);
    read_pod(in, regs.lba);
    read_pod(in, regs.cmd);
    read_pod(in, regs.pkt_io_size);
    read_pod(in, regs.status);
}

static void write_drive(std::ostream& out, const HpsIdeDrive& drive) {
    write_pod(out, drive.present);
    write_pod(out, drive.cylinders);
    write_pod(out, drive.heads);
    write_pod(out, drive.spt);
    write_pod(out, drive.total_sectors);
    write_pod(out, drive.spb);
    for (uint16_t word : drive.id) write_pod(out, word);
}

static void read_drive(std::istream& in, HpsIdeDrive& drive) {
    read_pod(in, drive.present);
    read_pod(in, drive.cylinders);
    read_pod(in, drive.heads);
    read_pod(in, drive.spt);
    read_pod(in, drive.total_sectors);
    read_pod(in, drive.spb);
    for (uint16_t& word : drive.id) read_pod(in, word);
}

static uint16_t be_word(char hi, char lo) {
    return (static_cast<uint16_t>(hi) << 8) | static_cast<uint8_t>(lo);
}

static void set_ident_string(uint16_t* id, int word_base, int word_count, const std::string& text) {
    std::string padded = text;
    padded.resize(static_cast<size_t>(word_count) * 2, ' ');
    for (int i = 0; i < word_count; ++i) {
        id[word_base + i] = be_word(padded[i * 2], padded[i * 2 + 1]);
    }
}

HpsIde::HpsIde(uint8_t id, uint16_t base_addr) : id_(id), base_(base_addr) {}

void HpsIde::save(std::ostream& out) const {
    const uint32_t magic = 0x48494445; // HIDE
    const uint32_t version = 1;
    uint32_t state = static_cast<uint32_t>(state_);
    uint32_t next_state = static_cast<uint32_t>(next_state_);
    uint64_t sector_words_offset = std::numeric_limits<uint64_t>::max();

    if (sector_words_ && !image_.empty()) {
        const auto* image_begin = reinterpret_cast<const uint8_t*>(image_.data());
        const auto* ptr = reinterpret_cast<const uint8_t*>(sector_words_);
        if (ptr >= image_begin && ptr < image_begin + image_.size()) {
            sector_words_offset = static_cast<uint64_t>(ptr - image_begin);
        }
    }

    write_pod(out, magic);
    write_pod(out, version);
    write_pod(out, id_);
    write_pod(out, base_);
    write_pod(out, state);
    write_pod(out, next_state);
    write_regs(out, regs_);
    write_drive(out, drive_);
    write_vector_u8(out, image_);
    write_string(out, image_name_);
    write_pod(out, sector_words_offset);
    write_pod(out, sector_);
    write_pod(out, sector_count_);
    write_pod(out, cylinder_);
    write_pod(out, drv_addr_);
    write_pod(out, cmd_);
    out.write(reinterpret_cast<const char*>(buf_), sizeof(buf_));
    write_pod(out, cnt_);
    write_pod(out, irq_pending_);
    write_pod(out, bus_cooldown_);
    write_pod(out, debug_);
}

void HpsIde::load(std::istream& in) {
    uint32_t magic = 0;
    uint32_t version = 0;
    uint32_t state = 0;
    uint32_t next_state = 0;
    uint64_t sector_words_offset = std::numeric_limits<uint64_t>::max();

    read_pod(in, magic);
    read_pod(in, version);
    if (magic != 0x48494445 || version != 1) {
        throw std::runtime_error("bad HpsIde checkpoint");
    }

    read_pod(in, id_);
    read_pod(in, base_);
    read_pod(in, state);
    read_pod(in, next_state);
    state_ = static_cast<State>(state);
    next_state_ = static_cast<State>(next_state);
    read_regs(in, regs_);
    read_drive(in, drive_);
    read_vector_u8(in, image_);
    read_string(in, image_name_);
    read_pod(in, sector_words_offset);
    read_pod(in, sector_);
    read_pod(in, sector_count_);
    read_pod(in, cylinder_);
    read_pod(in, drv_addr_);
    read_pod(in, cmd_);
    in.read(reinterpret_cast<char*>(buf_), sizeof(buf_));
    read_pod(in, cnt_);
    read_pod(in, irq_pending_);
    read_pod(in, bus_cooldown_);
    read_pod(in, debug_);

    if (sector_words_offset != std::numeric_limits<uint64_t>::max() &&
        sector_words_offset + 512 <= image_.size()) {
        sector_words_ = reinterpret_cast<uint16_t*>(image_.data() + sector_words_offset);
    } else {
        sector_words_ = nullptr;
    }
}

bool HpsIde::open(const string& path) {
    ifstream f(path, ios::binary);
    if (!f) return false;

    f.seekg(0, ios::end);
    size_t size = static_cast<size_t>(f.tellg());
    f.seekg(0, ios::beg);

    image_.resize(size);
    f.read(reinterpret_cast<char*>(image_.data()), static_cast<std::streamsize>(size));
    if (!f) return false;

    drive_.present = true;
    drive_.total_sectors = static_cast<uint32_t>(size / 512);
    size_t slash = path.find_last_of("/\\");
    image_name_ = (slash == string::npos) ? path : path.substr(slash + 1);
    set_geometry(63, 16);
    return true;
}

void HpsIde::set_geometry(uint16_t sectors, uint16_t heads) {
    drive_.heads = heads ? heads : 16;
    drive_.spt = sectors ? sectors : 63;
    uint32_t cylinders = drive_.total_sectors / (drive_.heads * drive_.spt);
    if (cylinders > 65535) cylinders = 65535;
    drive_.cylinders = static_cast<uint16_t>(cylinders);
    update_identify();
}

void HpsIde::update_identify() {
    std::memset(drive_.id, 0, sizeof(drive_.id));
    drive_.id[0] = 0x0040;
    drive_.id[1] = drive_.cylinders;
    drive_.id[2] = 0x0000;
    drive_.id[3] = drive_.heads;
    drive_.id[4] = static_cast<uint16_t>(512 * drive_.spt);
    drive_.id[5] = 512;
    drive_.id[6] = drive_.spt;
    set_ident_string(drive_.id, 10, 10, "AOHD0000");
    drive_.id[20] = 3;
    drive_.id[21] = 512;
    drive_.id[22] = 4;
    set_ident_string(drive_.id, 23, 4, "");
    set_ident_string(drive_.id, 27, 20, "");
    drive_.id[47] = 0x8020;
    drive_.id[48] = 0x0001;
    drive_.id[49] = 1 << 9;
    drive_.id[50] = 0x4001;
    drive_.id[51] = 0x0200;
    drive_.id[52] = 0x0200;
    drive_.id[53] = 0x0007;
    drive_.id[54] = drive_.cylinders;
    drive_.id[55] = drive_.heads;
    drive_.id[56] = drive_.spt;
    drive_.id[57] = static_cast<uint16_t>(drive_.total_sectors & 0xFFFF);
    drive_.id[58] = static_cast<uint16_t>(drive_.total_sectors >> 16);
    drive_.id[59] = 0x0110;
    drive_.id[60] = static_cast<uint16_t>(drive_.total_sectors & 0xFFFF);
    drive_.id[61] = static_cast<uint16_t>(drive_.total_sectors >> 16);
    drive_.id[62] = 0x0000;
    drive_.id[63] = 0x0000;
    drive_.id[64] = 0x0000;
    drive_.id[65] = 120;
    drive_.id[66] = 120;
    drive_.id[67] = 120;
    drive_.id[68] = 120;
    drive_.id[80] = 0x007E;
    drive_.id[81] = 0x0000;
    drive_.id[82] = (1 << 14) | (1 << 9);
    drive_.id[83] = (1 << 14) | (1 << 13) | (1 << 12);
    drive_.id[84] = 1 << 14;
    drive_.id[85] = (1 << 14) | (1 << 9);
    drive_.id[86] = (1 << 14) | (1 << 13) | (1 << 12);
    drive_.id[87] = 1 << 14;
    drive_.id[93] = (1 << 14) | (1 << 13) | (1 << 9) | (1 << 8) |
                    (1 << 3) | (1 << 1) | (1 << 0);
    drive_.id[100] = static_cast<uint16_t>(drive_.total_sectors & 0xFFFF);
    drive_.id[101] = static_cast<uint16_t>(drive_.total_sectors >> 16);
    drive_.id[102] = 0;
    drive_.id[103] = 0;

    if (!image_name_.empty()) {
        std::string model = image_name_;
        if (model.size() > 40) model.resize(40);
        set_ident_string(drive_.id, 27, 20, model);
    }
}

void HpsIde::pulse_read(Vz486_mister_sim& tb, uint16_t addr) {
    tb.mgmt_address = addr;
    tb.mgmt_read = 1;
    tb.mgmt_write = 0;
}

void HpsIde::pulse_write(Vz486_mister_sim& tb, uint16_t addr, uint16_t data) {
    tb.mgmt_address = addr;
    tb.mgmt_writedata = data;
    tb.mgmt_write = 1;
    tb.mgmt_read = 0;
}

void HpsIde::clear_bus(Vz486_mister_sim& tb) {
    tb.mgmt_read = 0;
    tb.mgmt_write = 0;
}

uint32_t HpsIde::get_lba() const {
    if (regs_.lba) {
        return (regs_.sector & 0x00FFu) |
               (static_cast<uint32_t>(regs_.cylinder & 0xFFFFu) << 8) |
               (static_cast<uint32_t>(regs_.head & 0x0Fu) << 24);
    }

    uint32_t lba = regs_.cylinder;
    lba *= drive_.heads;
    lba += regs_.head;
    lba *= drive_.spt;
    lba += regs_.sector - 1;
    return lba;
}

void HpsIde::put_lba(uint32_t lba) {
    if (regs_.lba) {
        regs_.sector = static_cast<uint16_t>(lba & 0x00FFu);
        lba >>= 8;
        regs_.cylinder = static_cast<uint32_t>(lba & 0xFFFFu);
        lba >>= 16;
        regs_.head = static_cast<uint8_t>(lba & 0x0F);
    } else {
        uint32_t hspt = drive_.heads * drive_.spt;
        regs_.cylinder = lba / hspt;
        lba %= hspt;
        regs_.head = lba / drive_.spt;
        lba %= drive_.spt;
        regs_.sector = lba + 1;
    }
}

void HpsIde::handle_cmd() {
    if (!drive_.present || regs_.drv != 0) {
        if (debug_) {
            cout << "IDE" << static_cast<int>(id_) << ": "
                 << "reject cmd=0x" << std::hex << static_cast<int>(cmd_)
                 << " drv=" << static_cast<int>(regs_.drv)
                 << " present=" << static_cast<int>(drive_.present)
                 << std::dec << "\n";
        }
        regs_.error = 0x04;
        regs_.status = ATA_STATUS_RDY | ATA_STATUS_ERR | ATA_STATUS_IRQ;
        state_ = SET_REGS;
        next_state_ = IDLE;
        return;
    }

    // The Main_MiSTer x86 path only consumes the legacy 28-bit taskfile bytes
    // for the commands we currently emulate here. Upper HOB bytes can retain
    // stale values between commands, so mask them off before decoding.
    regs_.sector_count &= 0x00FFu;
    regs_.sector &= 0x00FFu;
    regs_.cylinder &= 0x0000FFFFu;

    switch (cmd_) {
    case 0x20:
    case 0x21:
    case 0x30:
    case 0x31:
    case 0xC4:
    case 0xC5:
        if (regs_.sector_count == 0) regs_.sector_count = 256;
        break;
    default:
        break;
    }

    if (debug_) {
        cout << "IDE" << static_cast<int>(id_) << ": "
             << "cmd=0x" << std::hex << static_cast<int>(cmd_)
             << " drv_addr=0x" << static_cast<int>(drv_addr_)
             << " count=" << std::dec << regs_.sector_count
             << " lba=" << get_lba()
             << " cyl=" << regs_.cylinder
             << " head=" << static_cast<int>(regs_.head)
             << " sector=" << regs_.sector
             << (regs_.lba ? " LBA" : " CHS")
             << "\n";
    }

    switch (cmd_) {
    case 0xEC:
        {
            uint8_t drv = regs_.drv;
            regs_ = HpsIdeRegs{};
            regs_.drv = drv;
        }
        regs_.io_size = 1;
        regs_.status = ATA_STATUS_RDY | ATA_STATUS_DRQ | ATA_STATUS_IRQ | ATA_STATUS_END;
        state_ = SEND_ID;
        cnt_ = 0;
        if (debug_) {
            cout << "IDE" << static_cast<int>(id_) << ": IDENTIFY model="
                 << image_name_ << " sectors=" << drive_.total_sectors << "\n";
        }
        break;

    case 0x20:
    case 0x21:
        state_ = READ;
        break;

    case 0x30:
    case 0x31:
        state_ = WRITE;
        break;

    case 0x91:
        set_geometry(regs_.sector_count, regs_.head + 1);
        regs_.status = ATA_STATUS_RDY | ATA_STATUS_IRQ;
        state_ = SET_REGS;
        next_state_ = IDLE;
        break;

    case 0x10 ... 0x1F:
        regs_.status = ATA_STATUS_RDY | ATA_STATUS_IRQ;
        regs_.cylinder = 0;
        state_ = SET_REGS;
        next_state_ = IDLE;
        break;

    case 0x40:
        regs_.status = ATA_STATUS_RDY | ATA_STATUS_IRQ;
        state_ = SET_REGS;
        next_state_ = IDLE;
        break;

    default:
        if (debug_) {
            cout << "IDE" << static_cast<int>(id_) << ": unsupported command 0x"
                 << std::hex << static_cast<int>(cmd_) << std::dec << "\n";
        }
        regs_.error = 0x04;
        regs_.status = ATA_STATUS_RDY | ATA_STATUS_ERR | ATA_STATUS_IRQ;
        state_ = SET_REGS;
        next_state_ = IDLE;
        break;
    }
}

// --- deterministic HPS disk-latency jitter ---------------------------------
// Vary the cycles between IDE bus ops (and thus data-ready / IRQ timing) like
// the real HPS, to expose timing-dependent races in the core's disk handshake.
static bool     g_jitter_en    = false;
static uint32_t g_jitter_state = 1;
void hps_ide_set_jitter(bool en, uint32_t seed) {
    g_jitter_en = en;
    g_jitter_state = seed ? seed : 1u;
}
static int jitter_next() {                 // xorshift32 -> 0..63 extra idle cycles
    uint32_t x = g_jitter_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    g_jitter_state = x;
    return (int)(x & 0x3F);
}

void HpsIde::tick(Vz486_mister_sim& tb) {
    clear_bus(tb);

    if (tb.reset) {
        state_ = INITIAL;
        regs_ = HpsIdeRegs{};
        regs_.status = ATA_STATUS_RDY;
        bus_cooldown_ = false;
        jitter_delay_ = 0;
        next_state_ = IDLE;
        return;
    }

    if (bus_cooldown_) {
        bus_cooldown_ = false;
        return;
    }

    if (jitter_delay_ > 0) {               // hold the HPS idle for a variable spell
        jitter_delay_--;
        return;
    }

    switch (state_) {
    case INITIAL:
        pulse_write(tb, base_ + 6, drive_.present ? 0x0009 : 0x0008);
        state_ = IDLE;
        break;

    case IDLE: {
        uint8_t req = id_ ? tb.ide1_request : tb.ide0_request;

        if (req == 4) {
            pulse_read(tb, base_ + 1);
            state_ = GET_CMD;
        } else if (req == 6) {
            pulse_read(tb, base_ + 5);
            state_ = GET_RESET_DRIVE;
        }
        break;
    }

    case GET_RESET_DRIVE: {
        drv_addr_ = tb.mgmt_readdata & 0xFF;
        regs_.drv = (drv_addr_ >> 4) & 0x1;
        regs_.lba = (drv_addr_ >> 6) & 0x1;
        regs_.head = 0;
        regs_.error = 0;
        regs_.sector = 1;
        regs_.sector_count = 1;
        regs_.cylinder = (drive_.present && regs_.drv == 0) ? 0x0000 : 0xFFFF;
        regs_.status = ATA_STATUS_RDY;
        state_ = SET_REGS;
        next_state_ = RESET_SET;
        break;
    }

    case RESET_SET:
        state_ = IDLE;
        break;

    case GET_CMD:
        switch (tb.mgmt_address & 0xF) {
        case 1:
            sector_count_ = tb.mgmt_readdata & 0xFF;
            sector_ = tb.mgmt_readdata >> 8;
            pulse_read(tb, tb.mgmt_address + 1);
            break;
        case 2:
            cylinder_ = tb.mgmt_readdata;
            pulse_read(tb, tb.mgmt_address + 1);
            break;
        case 3:
            sector_ += tb.mgmt_readdata & 0xFF00;
            sector_count_ += (tb.mgmt_readdata & 0x00FF) << 8;
            pulse_read(tb, tb.mgmt_address + 1);
            break;
        case 4:
            cylinder_ += static_cast<uint32_t>(tb.mgmt_readdata) << 16;
            pulse_read(tb, tb.mgmt_address + 1);
            break;
        case 5:
            drv_addr_ = tb.mgmt_readdata & 0xFF;
            cmd_ = tb.mgmt_readdata >> 8;
            regs_.sector_count = static_cast<uint16_t>(sector_count_);
            regs_.sector = static_cast<uint16_t>(sector_);
            regs_.cylinder = cylinder_;
            regs_.head = drv_addr_ & 0x0F;
            regs_.drv = (drv_addr_ >> 4) & 0x1;
            regs_.lba = (drv_addr_ >> 6) & 0x1;
            state_ = DO_CMD;
            break;
        default:
            state_ = IDLE;
            break;
        }
        break;

    case DO_CMD:
        handle_cmd();
        break;

    case SEND_ID:
        if (cnt_ < 256) {
            pulse_write(tb, base_ + 255, drive_.id[cnt_]);
            cnt_++;
        } else {
            state_ = SET_REGS;
            next_state_ = IDLE;
        }
        break;

    case SET_REGS: {
        if (!(regs_.status & ATA_STATUS_DRQ)) regs_.status |= ATA_STATUS_DSC;

        buf_[0] = regs_.io_size;
        buf_[1] = regs_.error;
        buf_[2] = regs_.sector_count;
        buf_[3] = regs_.sector;
        buf_[4] = regs_.cylinder;
        buf_[5] = regs_.cylinder >> 8;
        buf_[6] = regs_.cylinder >> 16;
        buf_[7] = regs_.cylinder >> 24;
        buf_[8] = regs_.pkt_io_size;
        buf_[9] = regs_.pkt_io_size >> 8;
        buf_[10] = static_cast<uint8_t>((regs_.lba ? 0xE0 : 0xA0) | (regs_.drv ? 0x10 : 0x00) | regs_.head);
        buf_[11] = regs_.status;

        cnt_ = 0;
        state_ = SET_REGS_SEND;
        break;
    }

    case SET_REGS_SEND:
        if (cnt_ < 6) {
            const auto* words = reinterpret_cast<const uint16_t*>(buf_);
            pulse_write(tb, base_ + cnt_, words[cnt_]);
            cnt_++;
        } else {
            cnt_ = 0;
            state_ = next_state_;
        }
        break;

    case READ: {
        state_ = READ_REGS;
        break;
    }

    case READ_REGS: {
        uint32_t lba = get_lba();
        if (debug_) {
            cout << g_ide_time << ": IDE" << static_cast<int>(id_) << ": READ lba=" << lba
                 << " remaining=" << regs_.sector_count << "\n";
        }
        if ((static_cast<uint64_t>(lba) + 1ull) * 512ull > image_.size()) {
            if (debug_) {
                cout << "IDE" << static_cast<int>(id_) << ": READ out of range\n";
            }
            std::fill(std::begin(buf_), std::end(buf_), 0);
            sector_words_ = nullptr;
        } else {
            sector_words_ = reinterpret_cast<uint16_t*>(image_.data() + static_cast<size_t>(lba) * 512u);
        }
        put_lba(get_lba() + 1);
        regs_.sector_count--;
        regs_.io_size = 1;
        regs_.status = ATA_STATUS_RDY | ATA_STATUS_DRQ | ATA_STATUS_IRQ;
        if (!regs_.sector_count) regs_.status |= ATA_STATUS_END;
        cnt_ = 0;
        state_ = READ_SEND;
        break;
    }

    case READ_SEND:
        if (cnt_ < 256) {
            uint16_t data = sector_words_ ? sector_words_[cnt_] : 0;
            pulse_write(tb, base_ + 255, data);
            cnt_++;
        } else {
            cnt_ = 0;
            state_ = SET_REGS;
            next_state_ = regs_.sector_count ? READ_WAIT_REQ : IDLE;
        }
        break;

    case READ_WAIT_REQ: {
        uint8_t req = id_ ? tb.ide1_request : tb.ide0_request;
        if (req == 5) {
            state_ = READ_REGS;
        } else if (req != 0) {
            state_ = IDLE;
        }
        break;
    }

    case WRITE: {
        irq_pending_ = 0;
        state_ = WRITE_REGS;
        break;
    }

    case WRITE_REGS: {
        uint32_t lba = get_lba();
        if (debug_) {
            cout << g_ide_time << ": IDE" << static_cast<int>(id_) << ": WRITE lba=" << lba
                 << " remaining=" << regs_.sector_count << "\n";
        }
        if ((static_cast<uint64_t>(lba) + 1ull) * 512ull <= image_.size()) {
            sector_words_ = reinterpret_cast<uint16_t*>(image_.data() + static_cast<size_t>(lba) * 512u);
        } else {
            if (debug_) {
                cout << "IDE" << static_cast<int>(id_) << ": WRITE out of range\n";
            }
            sector_words_ = nullptr;
        }
        regs_.status = ATA_STATUS_RDY | ATA_STATUS_DRQ | irq_pending_;
        irq_pending_ = ATA_STATUS_IRQ;
        regs_.io_size = 1;
        state_ = SET_REGS;
        next_state_ = WRITE_WAIT_REQ;
        break;
    }

    case WRITE_WAIT_REQ: {
        uint8_t req = id_ ? tb.ide1_request : tb.ide0_request;
        if (req == 5) {
            cnt_ = 0;
            state_ = WRITE_RECV;
        } else if (req != 0) {
            state_ = IDLE;
        }
        break;
    }

    case WRITE_RECV:
        if (cnt_ > 0 && sector_words_) sector_words_[cnt_ - 1] = tb.mgmt_readdata;
        if (cnt_ < 256) {
            pulse_read(tb, base_ + 255);
            cnt_++;
        } else {
            cnt_ = 0;
            put_lba(get_lba() + 1);
            if (--regs_.sector_count) {
                state_ = WRITE_REGS;
            } else {
                regs_.status = ATA_STATUS_RDY | ATA_STATUS_IRQ;
                state_ = SET_REGS;
                next_state_ = IDLE;
            }
        }
        break;
    }

    if (tb.mgmt_read || tb.mgmt_write) {
        bus_cooldown_ = true;
        if (g_jitter_en) jitter_delay_ = jitter_next();
    }
}
