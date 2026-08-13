#include <cstdlib>
#include "Vz386_mister_sim.h"
#include "Vz386_mister_sim__Syms.h"
#include "Vz386_mister_sim_z386_mister_sim.h"
#include "verilated.h"
#include "verilated_fst_c.h"
#include <SDL.h>
#include <png.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <cstdint>
#include <ctime>
#include <deque>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include "verilated_save.h"

#include "ide_hps.h"
#include "control_server.h"
#include "wav_writer.h"

using std::cerr;
using std::cout;
using std::deque;
using std::ifstream;
using std::ios;
using std::map;
using std::pair;
using std::string;
using std::vector;
namespace fs = std::filesystem;

#include "scancode.h"

static constexpr int H_RES = 1600;
static constexpr int V_RES = 900;
#ifdef __APPLE__
static constexpr int INITIAL_WINDOW_SCALE = 1;
#else
static constexpr int INITIAL_WINDOW_SCALE = 2;
#endif

struct Pixel {
	uint8_t a;
	uint8_t b;
	uint8_t g;
	uint8_t r;
};

static Vz386_mister_sim tb;
static VerilatedFstC* trace = nullptr;
static vluint64_t sim_time = 0;
uint64_t g_ide_time = 0;
static bool posedge = false;
static bool trace_toggle = false;
static bool trace_loop_started = false;
static uint64_t trace_start_cycle = 0;
static std::string trace_file_name = "waveform.fst";
static uint64_t current_cycle = 0;

// SB audio dropout (flatline) detector / auto-trace arming.
static bool     arm_trace_on_flatline = false;
static uint64_t force_stop_cycle = 0;          // 0 = no forced stop
static uint64_t flatline_trace_window = 8000000;
static const uint64_t FLATLINE_HOLD_THRESHOLD = 150000; // posedges of frozen output

static string disk_path = "../../sdcard/freedos.img";
static string floppy_path;
static string boot0_path = "boot0.rom";
static string boot1_path = "boot1.rom";
static std::array<bool, 256> boot_pages_seen{};
static constexpr uint32_t DDR_SHMEM_BASE = 0x30000000;
static constexpr size_t DDR_SIZE = 16 * 1024 * 1024;
static std::vector<uint8_t> ddram_mem(DDR_SIZE);
static bool ddram_resp_valid = false;
static uint64_t ddram_resp_data = 0;
// SVGA framebuffer capture: the RTL writes the linear FB to DDR3 byte 0x3F800000+
// (= FB_BASE {4'h3,6'b111110,...}), far above the 16MB ddram_mem, so capture it in a
// dedicated buffer to render the image the HPS scaler would display.
static constexpr uint64_t FB_BASE_BYTE = 0x3F800000ull;
static constexpr size_t   FB_MEM_SIZE  = 4 * 1024 * 1024;   // 64 banks * 64KB
static std::vector<uint8_t> fb_mem(FB_MEM_SIZE, 0);
static std::array<Pixel, 256> fb_palette = [] {
	std::array<Pixel, 256> palette{};
	palette.fill(Pixel{0xff, 0x00, 0x00, 0x00});
	return palette;
}();

static uint8_t expand_dac_color(uint8_t value) {
	return static_cast<uint8_t>((value << 2) | (value >> 4));
}

static bool render_svga8_frame(Pixel* pixels, int& width, int& height) {
	const uint8_t flags = tb.fb_flags;
	if (tb.fb_off || (flags & 0x04) || (flags & 0x03) != 0x01) return false;

	const size_t base = static_cast<size_t>(tb.fb_start_addr) << 2;
	const size_t stride = static_cast<size_t>(tb.fb_stride) << 3;
	const int fb_width = std::min<int>(static_cast<int>(tb.fb_width) << 3, H_RES);
	const int fb_height = std::min<int>(
		(flags & 0x08) ? static_cast<int>(tb.fb_height) / 2
		               : static_cast<int>(tb.fb_height),
		V_RES);
	if (fb_width <= 0 || fb_height <= 0 || stride == 0 || base >= fb_mem.size())
		return false;
	const size_t last_row = base + static_cast<size_t>(fb_height - 1) * stride;
	if (last_row >= fb_mem.size() || static_cast<size_t>(fb_width) > fb_mem.size() - last_row)
		return false;

	for (int y = 0; y < fb_height; ++y) {
		const size_t row = base + static_cast<size_t>(y) * stride;
		for (int x = 0; x < fb_width; ++x)
			pixels[y * H_RES + x] = fb_palette[fb_mem[row + x]];
	}
	width = fb_width;
	height = fb_height;
	return true;
}

struct ScheduledPs2Bytes {
	uint64_t cycle;
	std::vector<uint8_t> bytes;
};

static std::vector<ScheduledPs2Bytes> ps2_events;
static size_t next_ps2_event = 0;
static std::vector<ScheduledPs2Bytes> mouse_events;
static size_t next_mouse_event = 0;
static deque<uint8_t> kbd_scancode_queue;
static deque<uint8_t> mouse_byte_queue;
static uint64_t last_kbd_byte_time = 0;
static uint64_t last_mouse_byte_time = 0;
static uint8_t ps2_kbd_scan_set = 2;
static uint8_t ps2_mouse_buttons = 0;
static uint8_t pending_kbd_cmd = 0;
static bool pending_kbd_arg = false;
static bool kbd_host_busy = false;
static bool kbd_host_clear_pending = false;
static std::vector<uint64_t> screen_check_cycles;
static size_t next_screen_check = 0;
static bool g_headless = false;
static bool g_ide_debug = true;
static bool record_audio = false;
static Pixel screenbuffer[H_RES * V_RES]{};
static Pixel presentbuffer[H_RES * V_RES]{};

static WAVWriter* wav_writer = nullptr;
static uint32_t audio_sample_accum = 0;
static uint32_t audio_clock_accum = 0;
static constexpr uint32_t AUDIO_SAMPLE_RATE = 48000;
#ifndef SIM_SYSTEM_CLOCK_HZ
#define SIM_SYSTEM_CLOCK_HZ 20000000
#endif
static constexpr uint32_t SIM_SYS_CLOCK_HZ = SIM_SYSTEM_CLOCK_HZ;
static constexpr uint32_t AUDIO_CLOCK_HZ = 24576000;

template <typename T>
static void write_pod(std::ostream& out, const T& value) {
	out.write(reinterpret_cast<const char*>(&value), sizeof(value));
}

template <typename T>
static void read_pod(std::istream& in, T& value) {
	in.read(reinterpret_cast<char*>(&value), sizeof(value));
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

static void write_vector_u64(std::ostream& out, const std::vector<uint64_t>& value) {
	uint64_t size = static_cast<uint64_t>(value.size());
	write_pod(out, size);
	for (uint64_t item : value) write_pod(out, item);
}

static void read_vector_u64(std::istream& in, std::vector<uint64_t>& value) {
	uint64_t size = 0;
	read_pod(in, size);
	value.resize(static_cast<size_t>(size));
	for (uint64_t& item : value) read_pod(in, item);
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

static void write_deque_u8(std::ostream& out, const deque<uint8_t>& value) {
	uint64_t size = static_cast<uint64_t>(value.size());
	write_pod(out, size);
	for (uint8_t byte : value) write_pod(out, byte);
}

static void read_deque_u8(std::istream& in, deque<uint8_t>& value) {
	uint64_t size = 0;
	read_pod(in, size);
	value.clear();
	for (uint64_t i = 0; i < size; ++i) {
		uint8_t byte = 0;
		read_pod(in, byte);
		value.push_back(byte);
	}
}

static void write_scheduled_events(std::ostream& out, const std::vector<ScheduledPs2Bytes>& value) {
	uint64_t size = static_cast<uint64_t>(value.size());
	write_pod(out, size);
	for (const auto& event : value) {
		write_pod(out, event.cycle);
		write_vector_u8(out, event.bytes);
	}
}

static void read_scheduled_events(std::istream& in, std::vector<ScheduledPs2Bytes>& value) {
	uint64_t size = 0;
	read_pod(in, size);
	value.resize(static_cast<size_t>(size));
	for (auto& event : value) {
		read_pod(in, event.cycle);
		read_vector_u8(in, event.bytes);
	}
}

static constexpr std::array<uint32_t, 16> kVgaPalette = {{
	0x000000, 0x0000AA, 0x00AA00, 0x00AAAA,
	0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
	0x555555, 0x5555FF, 0x55FF55, 0x55FFFF,
	0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF,
}};

static inline Pixel palette_pixel(uint8_t idx) {
	uint32_t rgb = kVgaPalette[idx & 0x0f];
	return Pixel{
		0xff,
		static_cast<uint8_t>(rgb & 0xff),
		static_cast<uint8_t>((rgb >> 8) & 0xff),
		static_cast<uint8_t>((rgb >> 16) & 0xff),
	};
}

static vector<uint8_t> read_file(const string& path) {
	ifstream f(path, ios::binary);
	if (!f) throw std::runtime_error("failed to open " + path);
	f.seekg(0, ios::end);
	size_t size = static_cast<size_t>(f.tellg());
	f.seekg(0, ios::beg);
	vector<uint8_t> data(size);
	f.read(reinterpret_cast<char*>(data.data()), static_cast<std::streamsize>(size));
	if (!f) throw std::runtime_error("failed to read " + path);
	return data;
}

struct FloppyGeometry {
	uint8_t cylinders = 80;
	uint8_t sectors_per_track = 18;
	uint16_t total_sectors = 2880;
	uint8_t heads = 2;
	uint8_t cmos_type = 4; // 1.44 MB 3.5"
};

static FloppyGeometry infer_floppy_geometry(size_t image_size) {
	const uint32_t sectors = static_cast<uint32_t>(image_size / 512);
	FloppyGeometry geo{};
	geo.total_sectors = static_cast<uint16_t>(std::min<uint32_t>(sectors, 0xFFFF));

	switch (sectors) {
	case 320:  geo = {40,  8,  320, 1, 1}; break; // 160 KB
	case 360:  geo = {40,  9,  360, 1, 1}; break; // 180 KB
	case 640:  geo = {40,  8,  640, 2, 1}; break; // 320 KB
	case 720:  geo = {40,  9,  720, 2, 1}; break; // 360 KB
	case 1440: geo = {80,  9, 1440, 2, 3}; break; // 720 KB
	case 2400: geo = {80, 15, 2400, 2, 2}; break; // 1.2 MB
	case 2880: geo = {80, 18, 2880, 2, 4}; break; // 1.44 MB
	case 5760: geo = {80, 36, 5760, 2, 5}; break; // 2.88 MB
	default:
		geo.cylinders = (sectors <= 720) ? 40 : 80;
		geo.heads = (sectors <= 360) ? 1 : 2;
		geo.sectors_per_track = static_cast<uint8_t>(
			std::max<uint32_t>(1, sectors / (geo.cylinders * geo.heads)));
		break;
	}
	return geo;
}

class HpsFloppy {
public:
	bool open(const string& path) {
		image_ = read_file(path);
		if (image_.empty() || (image_.size() % 512) != 0)
			throw std::runtime_error("floppy image must be a non-empty whole-sector image: " + path);
		image_name_ = fs::path(path).filename().string();
		geo_ = infer_floppy_geometry(image_.size());
		present_ = true;
		cout << "Mounted floppy A: " << image_name_
		     << " sectors=" << geo_.total_sectors
		     << " cyl=" << static_cast<int>(geo_.cylinders)
		     << " heads=" << static_cast<int>(geo_.heads)
		     << " spt=" << static_cast<int>(geo_.sectors_per_track)
		     << "\n";
		return true;
	}

	bool present() const { return present_; }
	const FloppyGeometry& geometry() const { return geo_; }

	void tick(Vz386_mister_sim& tb) {
		if (tb.reset) {
			state_ = IDLE;
			cnt_ = 0;
			return;
		}

		switch (state_) {
		case IDLE:
			if (!present_) return;
			if (tb.fdd_request & 1) {
				pulse_read(tb, 0xF200);
				state_ = READ_GET_SECTOR;
			} else if (tb.fdd_request & 2) {
				pulse_read(tb, 0xF200);
				state_ = WRITE_GET_SECTOR;
			}
			break;

		case READ_GET_SECTOR:
			selected_drive_ = (tb.mgmt_readdata >> 15) & 1;
			sector_ = tb.mgmt_readdata & 0x7FFF;
			cnt_ = 0;
			if (selected_drive_ != 0)
				cout << "FDD: unsupported drive B read request\n";
			else
				cout << "FDD: READ sector=" << sector_ << "\n";
			state_ = READ_SEND;
			break;

		case READ_SEND:
			if (cnt_ < 512) {
				pulse_write(tb, 0xF20F, read_byte(sector_, cnt_));
				cnt_++;
			} else {
				state_ = IDLE;
			}
			break;

		case WRITE_GET_SECTOR:
			selected_drive_ = (tb.mgmt_readdata >> 15) & 1;
			sector_ = tb.mgmt_readdata & 0x7FFF;
			cnt_ = 0;
			if (selected_drive_ != 0)
				cout << "FDD: unsupported drive B write request\n";
			else
				cout << "FDD: WRITE sector=" << sector_ << "\n";
			pulse_read(tb, 0xF20F);
			state_ = WRITE_RECV;
			break;

		case WRITE_RECV:
			if (cnt_ > 0)
				write_byte(sector_, cnt_ - 1, tb.mgmt_readdata);
			if (cnt_ < 512) {
				pulse_read(tb, 0xF20F);
				cnt_++;
			} else {
				state_ = IDLE;
			}
			break;
		}
	}

private:
	enum State {
		IDLE,
		READ_GET_SECTOR,
		READ_SEND,
		WRITE_GET_SECTOR,
		WRITE_RECV
	};

	static void pulse_read(Vz386_mister_sim& tb, uint16_t addr) {
		tb.mgmt_address = addr;
		tb.mgmt_read = 1;
		tb.mgmt_write = 0;
	}

	static void pulse_write(Vz386_mister_sim& tb, uint16_t addr, uint16_t data) {
		tb.mgmt_address = addr;
		tb.mgmt_writedata = data;
		tb.mgmt_write = 1;
		tb.mgmt_read = 0;
	}

	uint8_t read_byte(uint32_t sector, int byte_index) const {
		if (selected_drive_ != 0) return 0;
		size_t offset = static_cast<size_t>(sector) * 512u + static_cast<size_t>(byte_index);
		if (offset >= image_.size()) return 0;
		return image_[offset];
	}

	void write_byte(uint32_t sector, int byte_index, uint16_t data) {
		if (selected_drive_ != 0) return;
		size_t offset = static_cast<size_t>(sector) * 512u + static_cast<size_t>(byte_index);
		if (offset >= image_.size()) return;
		image_[offset] = static_cast<uint8_t>(data);
	}

	State state_ = IDLE;
	bool present_ = false;
	FloppyGeometry geo_{};
	vector<uint8_t> image_;
	string image_name_;
	uint32_t sector_ = 0;
	int cnt_ = 0;
	uint8_t selected_drive_ = 0;
};

static void queue_ps2_bytes(const std::vector<uint8_t>& bytes) {
	kbd_scancode_queue.insert(kbd_scancode_queue.end(), bytes.begin(), bytes.end());
}

static inline uint32_t get_ticks_ms() {
	if (!g_headless) return SDL_GetTicks();
	return 0;
}

static void set_trace(bool toggle) {
	printf("Tracing %s\n", toggle ? "on" : "off");
	if (toggle && !trace) {
		trace = new VerilatedFstC();
		tb.trace(trace, 5);
		Verilated::traceEverOn(true);
		trace->open(trace_file_name.c_str());
	}
	trace_toggle = toggle;
}

static void queue_sdl_key(SDL_Keycode key, bool pressed) {
	auto it = ps2scancodes.find(key);
	if (it == ps2scancodes.end()) return;
	const auto& seq = pressed ? it->second.first : it->second.second;
	if (seq.empty()) return;
	queue_ps2_bytes(seq);
}

static std::vector<uint8_t> encode_mouse_packets(int dx, int dy, uint8_t buttons) {
	std::vector<uint8_t> bytes;
	bool first = true;
	while (first || dx != 0 || dy != 0) {
		first = false;
		int step_x = std::clamp(dx, -127, 127);
		int step_y = std::clamp(dy, -127, 127);
		uint8_t flags = 0x08 | (buttons & 0x07);
		if (step_x < 0) flags |= 0x10;
		if (step_y < 0) flags |= 0x20;
		bytes.push_back(flags);
		bytes.push_back(static_cast<uint8_t>(static_cast<int8_t>(step_x)));
		bytes.push_back(static_cast<uint8_t>(static_cast<int8_t>(step_y)));
		dx -= step_x;
		dy -= step_y;
	}
	return bytes;
}

static void queue_mouse_packet(int dx, int dy, uint8_t buttons) {
	auto bytes = encode_mouse_packets(dx, dy, buttons);
	mouse_byte_queue.insert(mouse_byte_queue.end(), bytes.begin(), bytes.end());
}

static bool parse_named_key(string name, SDL_Keycode& key) {
	std::transform(name.begin(), name.end(), name.begin(),
		[](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
	static const std::map<string, SDL_Keycode> keys = {
		{"up", SDLK_UP}, {"down", SDLK_DOWN}, {"left", SDLK_LEFT}, {"right", SDLK_RIGHT},
		{"enter", SDLK_RETURN}, {"return", SDLK_RETURN}, {"escape", SDLK_ESCAPE},
		{"esc", SDLK_ESCAPE}, {"space", SDLK_SPACE}, {"tab", SDLK_TAB},
		{"backspace", SDLK_BACKSPACE}, {"delete", SDLK_DELETE}, {"insert", SDLK_INSERT},
		{"home", SDLK_HOME}, {"end", SDLK_END}, {"pageup", SDLK_PAGEUP},
		{"pagedown", SDLK_PAGEDOWN}, {"ctrl", SDLK_LCTRL}, {"shift", SDLK_LSHIFT},
		{"alt", SDLK_LALT}, {"f1", SDLK_F1}, {"f2", SDLK_F2}, {"f3", SDLK_F3},
		{"f4", SDLK_F4}, {"f5", SDLK_F5}, {"f6", SDLK_F6}, {"f7", SDLK_F7},
		{"f8", SDLK_F8}, {"f9", SDLK_F9}, {"f10", SDLK_F10}, {"f11", SDLK_F11},
		{"f12", SDLK_F12},
	};
	auto it = keys.find(name);
	if (it != keys.end()) {
		key = it->second;
		return true;
	}
	if (name.size() == 1) {
		unsigned char ch = static_cast<unsigned char>(name[0]);
		if (std::isalnum(ch)) {
			key = static_cast<SDL_Keycode>(ch);
			return true;
		}
	}
	return false;
}

static void handle_kbd_host_cmd(uint8_t cmd) {
	auto reply = [](uint8_t code) {
		kbd_scancode_queue.push_back(code);
	};

	if (!pending_kbd_arg) {
		pending_kbd_cmd = cmd;
		switch (cmd) {
		case 0xFF:
			ps2_kbd_scan_set = 2;
			reply(0xFA);
			reply(0xAA);
			pending_kbd_cmd = 0;
			break;
		case 0xF2:
			reply(0xFA);
			reply(0xAB);
			reply(0x83);
			pending_kbd_cmd = 0;
			break;
		case 0xF0:
		case 0xF3:
		case 0xED:
			reply(0xFA);
			pending_kbd_arg = true;
			break;
		case 0xF6:
			ps2_kbd_scan_set = 2;
			reply(0xFA);
			pending_kbd_cmd = 0;
			break;
		case 0xF4:
		case 0xF5:
		case 0xFA:
			reply(0xFA);
			pending_kbd_cmd = 0;
			break;
		case 0xEE:
			reply(0xEE);
			pending_kbd_cmd = 0;
			break;
		default:
			reply(0xFE);
			pending_kbd_cmd = 0;
			break;
		}
	} else {
		switch (pending_kbd_cmd) {
		case 0xED:
			reply(0xFA);
			break;
		case 0xF0:
			if (cmd <= 3) {
				reply(0xFA);
				if (cmd == 0) reply(ps2_kbd_scan_set);
				else ps2_kbd_scan_set = cmd;
			} else {
				reply(0xFE);
			}
			break;
		case 0xF3:
			reply(0xFA);
			break;
		default:
			break;
		}
		pending_kbd_cmd = 0;
		pending_kbd_arg = false;
	}
}

static std::string current_text_screen() {
	auto* sys = tb.z386_mister_sim->system_i;
	std::string text;
	text.reserve(25 * 81);
	uint16_t start = static_cast<uint16_t>(sys->__PVT__vga_inst__DOT__crtc_address_start);
	uint16_t byte_panning = static_cast<uint16_t>(sys->__PVT__vga_inst__DOT__crtc_address_byte_panning);
	uint16_t stride = static_cast<uint16_t>(sys->__PVT__vga_inst__DOT__crtc_address_offset) << 2;
	uint16_t cols = static_cast<uint16_t>(sys->__PVT__vga_inst__DOT__crtc_horizontal_display_size) + 1;
	if (cols == 0 || cols > 80) cols = 80;
	if (stride == 0 || stride > 4096) stride = cols << 1;
	uint16_t row_addr = start + byte_panning;
	for (int row = 0; row < 25; ++row) {
		for (uint16_t col = 0; col < cols; ++col) {
			uint8_t ch = sys->__PVT__vga_inst__DOT__plane_ram_0__DOT__mem[static_cast<uint16_t>(row_addr + (col << 1))];
			if (ch < 0x20 || ch > 0x7e) ch = ' ';
			text.push_back(static_cast<char>(ch));
		}
		text.push_back('\n');
		row_addr = static_cast<uint16_t>(row_addr + stride);
	}
	return text;
}

static std::string row_for_match(const std::string& screen, const std::string& needle) {
	size_t pos = screen.find(needle);
	if (pos == std::string::npos) return {};
	size_t line_start = screen.rfind('\n', pos);
	if (line_start == std::string::npos) line_start = 0;
	else line_start += 1;
	size_t line_end = screen.find('\n', pos);
	if (line_end == std::string::npos) line_end = screen.size();
	return screen.substr(line_start, line_end - line_start);
}

static void dump_nonempty_rows(const std::string& screen) {
	size_t line_start = 0;
	unsigned row = 0;
	while (line_start < screen.size()) {
		size_t line_end = screen.find('\n', line_start);
		if (line_end == std::string::npos) line_end = screen.size();
		std::string row_text = screen.substr(line_start, line_end - line_start);
		size_t first = row_text.find_first_not_of(' ');
		if (first != std::string::npos) {
			size_t last = row_text.find_last_not_of(' ');
			cout << "screen row " << row << ": [" << row_text.substr(first, last - first + 1) << "]\n";
		}
		if (line_end == screen.size()) break;
		line_start = line_end + 1;
		row++;
	}
}

static void step() {
	tb.ddram_busy = 0;
	tb.ddram_dout_ready = ddram_resp_valid ? 1 : 0;
	tb.ddram_dout = ddram_resp_data;

	tb.clk_sys = !tb.clk_sys;
	posedge = tb.clk_sys;
	tb.eval();

	// clk_audio is an independent 24.576 MHz board clock. Each step is one
	// half-period of the 20 MHz simulated system clock, so advance a fractional
	// clock scheduler and evaluate every resulting audio edge.
	audio_clock_accum += 2 * AUDIO_CLOCK_HZ;
	while (audio_clock_accum >= 2 * SIM_SYS_CLOCK_HZ) {
		audio_clock_accum -= 2 * SIM_SYS_CLOCK_HZ;
		tb.clk_audio = !tb.clk_audio;
		tb.eval();
		if (tb.clk_audio && wav_writer) {
			audio_sample_accum += AUDIO_SAMPLE_RATE;
			if (audio_sample_accum >= AUDIO_CLOCK_HZ) {
				audio_sample_accum -= AUDIO_CLOCK_HZ;
				wav_writer->write_sample(static_cast<int16_t>(tb.audio_l),
				                         static_cast<int16_t>(tb.audio_r));
			}
		}
	}
	if (posedge) {
		static bool have_syscfg = false;
		static uint8_t last_syscfg = 0;
		if (!have_syscfg || tb.dbg_syscfg != last_syscfg) {
			last_syscfg = tb.dbg_syscfg;
			have_syscfg = true;
			fprintf(stderr, "%llu: SYSCTL cfg=%02X source=%s speed=%u\n",
			        (unsigned long long)sim_time,
			        static_cast<unsigned>(last_syscfg),
			        (last_syscfg & 0x80) ? "DOS" : "OSD",
			        static_cast<unsigned>(last_syscfg & 0x03));
		}

		// Audio-dropout detector: a frozen SB output sample = DMA underrun.
		static int16_t fl_last = 0;
		static uint64_t fl_hold = 0, fl_start = 0;
		int16_t v = static_cast<int16_t>(tb.sample_sb_l);
		// The dropout freezes the output at -32768 (DMA byte 0x00); true silence
		// (byte 0x80) maps to 0 and boot is also 0 -> only arm on a non-zero hold.
		if (v == fl_last) {
			fl_hold++;
			if (arm_trace_on_flatline && fl_last != 0 && fl_hold == FLATLINE_HOLD_THRESHOLD && force_stop_cycle == 0) {
				trace_start_cycle = current_cycle;          // begin dumping from here
				force_stop_cycle  = current_cycle + flatline_trace_window;
				fprintf(stderr, "FLATLINE @cycle %llu held=%d; arming trace until %llu\n",
				        (unsigned long long)fl_start, (int)fl_last,
				        (unsigned long long)force_stop_cycle);
			}
		} else {
			if (fl_hold > FLATLINE_HOLD_THRESHOLD && fl_last != 0)
				fprintf(stderr, "FLATLINE @cycle %llu held=%d for %llu posedges\n",
				        (unsigned long long)fl_start, (int)fl_last,
				        (unsigned long long)fl_hold);
			fl_last = v; fl_hold = 0; fl_start = current_cycle;
		}
	}
	if (posedge) {
		bool read_accepted = tb.ddram_rd && !tb.ddram_busy;
		if (read_accepted) {
			uint64_t byte_addr = static_cast<uint64_t>(tb.ddram_addr) << 3;
			uint64_t data = 0;
			const uint8_t* memory = nullptr;
			size_t memory_size = 0;
			uint64_t offset = 0;
			if (byte_addr >= FB_BASE_BYTE && byte_addr < FB_BASE_BYTE + FB_MEM_SIZE) {
				memory = fb_mem.data();
				memory_size = fb_mem.size();
				offset = byte_addr - FB_BASE_BYTE;
			} else if (byte_addr >= DDR_SHMEM_BASE &&
			           byte_addr < DDR_SHMEM_BASE + ddram_mem.size()) {
				memory = ddram_mem.data();
				memory_size = ddram_mem.size();
				offset = byte_addr - DDR_SHMEM_BASE;
			}
			if (memory) {
				for (int i = 0; i < 8; i++) {
					if (offset + static_cast<uint64_t>(i) < memory_size)
						data |= static_cast<uint64_t>(memory[offset + i]) << (8 * i);
				}
			}
			ddram_resp_data = data;
			ddram_resp_valid = true;
		} else if (ddram_resp_valid) {
			ddram_resp_valid = false;
		}
		// DDR3 write (SVGA framebuffer + any other ddram writes), byte-enabled
		if (tb.ddram_we && !tb.ddram_busy) {
			uint64_t byte_addr = static_cast<uint64_t>(tb.ddram_addr) << 3;
			for (int i = 0; i < 8; i++) {
				if (!((tb.ddram_be >> i) & 1)) continue;
				uint8_t b = static_cast<uint8_t>((tb.ddram_din >> (8 * i)) & 0xFF);
				uint64_t a = byte_addr + static_cast<uint64_t>(i);
				if (a >= FB_BASE_BYTE && a < FB_BASE_BYTE + FB_MEM_SIZE) {
					fb_mem[a - FB_BASE_BYTE] = b;
				} else if (a >= DDR_SHMEM_BASE && (a - DDR_SHMEM_BASE) < ddram_mem.size()) {
					ddram_mem[a - DDR_SHMEM_BASE] = b;
				}
			}
		}
		if (tb.fb_pal_wr) {
			const uint32_t data = tb.fb_pal_data;
			Pixel& pixel = fb_palette[tb.fb_pal_addr];
			pixel.a = 0xff;
			pixel.r = expand_dac_color((data >> 12) & 0x3f);
			pixel.g = expand_dac_color((data >> 6) & 0x3f);
			pixel.b = expand_dac_color(data & 0x3f);
		}
	}
	if (trace && trace_toggle && trace_loop_started && current_cycle >= trace_start_cycle) trace->dump(sim_time);
	sim_time++;
}

static void full_step() {
	step();
	step();
}

static void pulse_mgmt_write(uint16_t addr, uint16_t data) {
	tb.mgmt_address = addr;
	tb.mgmt_writedata = data;
	tb.mgmt_write = 1;
	tb.mgmt_read = 0;
	full_step();
	tb.mgmt_write = 0;
	full_step();
}

static void ddr_write(uint32_t offset, const vector<uint8_t>& data) {
	if (offset >= ddram_mem.size()) return;
	size_t count = std::min(data.size(), ddram_mem.size() - static_cast<size_t>(offset));
	std::copy_n(data.begin(), count, ddram_mem.begin() + offset);
}

static void stage_roms_to_ddr(const vector<uint8_t>& boot0, const vector<uint8_t>& boot1) {
	uint32_t boot0_offset = (boot0.size() > 65536) ? 0xE0000 : 0xF0000;

	std::fill(ddram_mem.begin(), ddram_mem.end(), 0);
	std::fill(ddram_mem.begin() + 0xA0000, ddram_mem.begin() + 0x100000, 0xFF);
	std::fill(ddram_mem.begin() + 0xA0000, ddram_mem.begin() + 0xC0000, 0x00);
	std::fill(ddram_mem.begin() + 0xCE000, ddram_mem.begin() + 0xD0000, 0x00);
	ddr_write(0xC0000, boot1);
	ddr_write(boot0_offset, boot0);
	cout << "Staged ROMs in DDR: boot1 @ 0xC0000, boot0 @ 0x"
	     << std::hex << boot0_offset << std::dec << "\n";
}

static uint8_t bin2bcd(unsigned val) {
	return static_cast<uint8_t>(((val / 10) << 4) | (val % 10));
}

static void configure_floppy_slot(unsigned slot, bool present, const FloppyGeometry& geo = FloppyGeometry{}) {
	uint16_t base = static_cast<uint16_t>(0xF200 + (slot << 7));
	pulse_mgmt_write(base + 0x0, present ? 1 : 0);
	pulse_mgmt_write(base + 0x1, 1);
	pulse_mgmt_write(base + 0x2, present ? geo.cylinders : 0);
	pulse_mgmt_write(base + 0x3, present ? geo.sectors_per_track : 0);
	pulse_mgmt_write(base + 0x4, present ? geo.total_sectors : 0);
	pulse_mgmt_write(base + 0x5, present ? geo.heads : 0);
	pulse_mgmt_write(base + 0xC, 0);
}

static void configure_cmos(bool hdd0_present, bool floppy0_present, const FloppyGeometry& floppy0_geo,
                           bool boot_from_floppy = false) {
	// RTC seed: fixed 2024-01-01 00:00:00 UTC, matching ao486-sim's CMOS seed.
	// Must NOT use the host wall-clock — otherwise every run is non-deterministic
	// AND diverges from ao486-sim (whose clock starts at 00:00:00), contaminating
	// every INT 1Ah time read in the z386<->ao486 CS:EIP diff. gmtime_r keeps it
	// timezone-independent.
	std::time_t now = (std::time_t)1704067200;  // 2024-01-01 00:00:00 UTC
	std::tm tm{};
	gmtime_r(&now, &tm);

	uint8_t cmos[128] = {};

	// 16MB total, so 15MB extended.
	const uint16_t ext_mem_kb = 15 * 1024;

	cmos[0x00] = bin2bcd(tm.tm_sec);
	cmos[0x02] = bin2bcd(tm.tm_min);
	cmos[0x04] = bin2bcd(tm.tm_hour);
	cmos[0x05] = 0x12;
	cmos[0x06] = static_cast<uint8_t>(tm.tm_wday + 1);
	cmos[0x07] = bin2bcd(tm.tm_mday);
	cmos[0x08] = bin2bcd(tm.tm_mon + 1);
	cmos[0x09] = bin2bcd((tm.tm_year < 117) ? 17 : tm.tm_year - 100);
	cmos[0x0A] = 0x26;
	cmos[0x0B] = 0x02;
	cmos[0x0D] = 0x80;

	cmos[0x10] = static_cast<uint8_t>(floppy0_present ? (floppy0_geo.cmos_type << 4) : 0x00);
	cmos[0x12] = static_cast<uint8_t>((hdd0_present ? 0xF : 0x0) << 4);
	cmos[0x14] = 0x4D;
	cmos[0x15] = 0x80;
	cmos[0x16] = 0x02;
	cmos[0x17] = ext_mem_kb & 0xFF;
	cmos[0x18] = ext_mem_kb >> 8;
	cmos[0x19] = static_cast<uint8_t>(hdd0_present ? 0x2F : 0x00);

	cmos[0x2D] = static_cast<uint8_t>((floppy0_present && boot_from_floppy) ? 0x20 : 0x00);
	cmos[0x30] = ext_mem_kb & 0xFF;
	cmos[0x31] = ext_mem_kb >> 8;
	cmos[0x32] = 0x20;
	cmos[0x34] = 0x00;
	cmos[0x35] = 0x00;
	cmos[0x37] = 0x20;
	cmos[0x39] = 0x02;

	unsigned short sum = 0;
	for (int i = 0x10; i <= 0x2D; ++i) sum += cmos[i];
	cmos[0x2E] = sum >> 8;
	cmos[0x2F] = sum & 0xFF;

	for (unsigned i = 0; i < sizeof(cmos); ++i) {
		pulse_mgmt_write(static_cast<uint16_t>(0xF400 + i), cmos[i]);
	}
}

static void configure_x86_management(bool hdd0_present, const HpsFloppy& floppy0, bool boot_from_floppy) {
	configure_floppy_slot(0, floppy0.present(), floppy0.geometry());
	configure_floppy_slot(1, false);
	configure_cmos(hdd0_present, floppy0.present(), floppy0.geometry(), boot_from_floppy);
}

static bool dump_screen_png(const fs::path& path, int width, int height) {
	FILE* file = fopen(path.c_str(), "wb");
	if (!file) return false;
	png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
	png_infop info = png ? png_create_info_struct(png) : nullptr;
	vector<uint8_t> row(static_cast<size_t>(width) * 3);
	if (!png || !info || setjmp(png_jmpbuf(png))) {
		if (png) png_destroy_write_struct(&png, info ? &info : nullptr);
		fclose(file);
		return false;
	}
	png_init_io(png, file);
	png_set_IHDR(png, info, width, height, 8, PNG_COLOR_TYPE_RGB,
	             PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT,
	             PNG_FILTER_TYPE_DEFAULT);
	png_write_info(png, info);
	for (int y = 0; y < height; ++y) {
		for (int x = 0; x < width; ++x) {
			const Pixel& pixel = presentbuffer[y * H_RES + x];
			row[x * 3 + 0] = pixel.r;
			row[x * 3 + 1] = pixel.g;
			row[x * 3 + 2] = pixel.b;
		}
		png_write_row(png, row.data());
	}
	png_write_end(png, nullptr);
	png_destroy_write_struct(&png, &info);
	fclose(file);
	return true;
}

static void usage() {
	cout << "Usage: Vz386_mister_sim [--trace] [--trace-start sim_time] [--trace-file path] [--headless] [--end sim_time] [--disk path] [--floppy path] [--boot0 path] [--boot1 path] [--ram-mb 16|32|64|128] [--cpu-speed full|56|30|15] [--cpu-speed-at sim_time:full|56|30|15] [--opl2|--opl3] [--vga-border|--no-vga-border] [--enter-at sim_time] [--key-at sim_time:key] [--key-down-at sim_time:key] [--key-up-at sim_time:key] [--key-on-text substring:key] [--mouse-at sim_time:dx:dy[:buttons]] [--control-port N] [--control-bind IPv4] [--ctrl-alt-del-at sim_time] [--screen-at sim_time] [--log-eip CS:EIP] [--screenshot-dir path] [--screenshot-interval sim_time] [--stop-on-text substring] [--no-ide] [--record] [--checkpoint-dir path] [--checkpoint-interval-sec N] [--checkpoint-keep N] [--restore path]  (all times are sim_time = 2*cycle; mouse buttons are bits L/R/M)\n";
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	setvbuf(stdout, nullptr, _IOLBF, 0);
	setvbuf(stderr, nullptr, _IONBF, 0);

	bool enable_trace = false;
	uint64_t max_cycles = std::numeric_limits<uint64_t>::max();
	string checkpoint_dir;
	uint64_t checkpoint_interval_sec = 0;
	size_t checkpoint_keep = 6;
	string restore_path;
	vector<uint64_t> enter_cycles;
	vector<std::pair<uint64_t, SDL_Keycode>> key_events;
	vector<std::tuple<uint64_t, SDL_Keycode, bool>> key_edge_events;
	vector<std::pair<string, SDL_Keycode>> text_key_events;
	vector<std::tuple<uint64_t, int, int, uint8_t>> mouse_packet_events;
	vector<std::pair<uint64_t, unsigned>> cpu_speed_events;
	vector<uint64_t> ctrl_alt_del_cycles;
	bool log_eip_enabled = false;
	uint16_t log_eip_cs = 0;
	uint32_t log_eip_offset = 0;
	string screenshot_dir;
	uint64_t screenshot_interval_cycles = 0;
	uint64_t next_screenshot_cycle = 0;
	string stop_on_text;
	unsigned ram_mb = 16;
	bool ram_mb_explicit = false;
	unsigned cpu_speed_status = 0;
	bool opl3_mode = true;
	bool opl_mode_explicit = false;
	bool vga_border = true;
	bool vga_border_explicit = false;
	unsigned control_port = 0;
	string control_bind = "127.0.0.1";
	auto parse_cpu_speed = [](const string& speed) -> unsigned {
		if (speed == "full") return 0;
		if (speed == "56") return 1;
		if (speed == "30") return 2;
		if (speed == "15") return 3;
		throw std::invalid_argument("CPU speed must be full, 56, 30, or 15");
	};

	for (int i = 1; i < argc; ++i) {
		string arg = argv[i];
		if (arg == "--trace") {
			enable_trace = true;
		} else if (arg == "--trace-start" && i + 1 < argc) {
			// All CLI time values are sim_time (unified with ao486-sim, and with
			// the fst/IDE/FRAME logs). Internal counters are cycles; sim_time = 2*cycle.
			trace_start_cycle = std::stoull(argv[++i]) / 2;
			enable_trace = true;
		} else if (arg == "--trace-file" && i + 1 < argc) {
			trace_file_name = argv[++i];
			enable_trace = true;
		} else if (arg == "--headless") {
			g_headless = true;
		} else if (arg == "--end" && i + 1 < argc) {
			max_cycles = std::stoull(argv[++i]) / 2;   // sim_time -> cycles
		} else if (arg == "--disk" && i + 1 < argc) {
			disk_path = argv[++i];
		} else if (arg == "--jitter" && i + 1 < argc) {
			hps_ide_set_jitter(true, (uint32_t)std::stoul(argv[++i]));
		} else if (arg == "--floppy" && i + 1 < argc) {
			floppy_path = argv[++i];
		} else if (arg == "--boot0" && i + 1 < argc) {
			boot0_path = argv[++i];
		} else if (arg == "--boot1" && i + 1 < argc) {
			boot1_path = argv[++i];
		} else if (arg == "--ram-mb" && i + 1 < argc) {
			ram_mb = static_cast<unsigned>(std::stoul(argv[++i]));
			ram_mb_explicit = true;
			if (ram_mb != 16 && ram_mb != 32 && ram_mb != 64 && ram_mb != 128) {
				cerr << "--ram-mb must be 16, 32, 64, or 128\n";
				return 1;
			}
			} else if (arg == "--cpu-speed" && i + 1 < argc) {
				try {
					cpu_speed_status = parse_cpu_speed(argv[++i]);
				} catch (const std::invalid_argument& e) {
					cerr << e.what() << "\n";
					return 1;
				}
			} else if (arg == "--cpu-speed-at" && i + 1 < argc) {
				const string event = argv[++i];
				const size_t separator = event.find(':');
				if (separator == string::npos) {
					cerr << "--cpu-speed-at requires sim_time:speed\n";
					return 1;
				}
				try {
					cpu_speed_events.push_back({std::stoull(event.substr(0, separator)) / 2,
					                            parse_cpu_speed(event.substr(separator + 1))});
				} catch (const std::invalid_argument& e) {
					cerr << e.what() << "\n";
					return 1;
				}
		} else if (arg == "--opl2") {
			opl3_mode = false;
			opl_mode_explicit = true;
		} else if (arg == "--opl3") {
			opl3_mode = true;
			opl_mode_explicit = true;
		} else if (arg == "--vga-border") {
			vga_border = true;
			vga_border_explicit = true;
		} else if (arg == "--no-vga-border") {
			vga_border = false;
			vga_border_explicit = true;
		} else if (arg == "--enter-at" && i + 1 < argc) {
			enter_cycles.push_back(std::stoull(argv[++i]) / 2);   // sim_time -> cycles
		} else if (arg == "--key-at" && i + 1 < argc) {
			string event = argv[++i];
			size_t separator = event.find(':');
			if (separator == string::npos) {
				cerr << "--key-at requires sim_time:key\n";
				return 1;
			}
			static const std::map<string, SDL_Keycode> keys = {
				{"up", SDLK_UP}, {"down", SDLK_DOWN},
				{"left", SDLK_LEFT}, {"right", SDLK_RIGHT},
				{"enter", SDLK_RETURN}, {"escape", SDLK_ESCAPE},
				{"space", SDLK_SPACE}, {"tab", SDLK_TAB},
				{"alt", SDLK_LALT}, {"f4", SDLK_F4},
				{"i", SDLK_i}, {"n", SDLK_n}, {"o", SDLK_o}, {"w", SDLK_w},
			};
			auto key = keys.find(event.substr(separator + 1));
			if (key == keys.end()) {
				cerr << "unsupported --key-at key: " << event.substr(separator + 1) << "\n";
				return 1;
			}
			key_events.push_back({std::stoull(event.substr(0, separator)) / 2, key->second});
		} else if ((arg == "--key-down-at" || arg == "--key-up-at") && i + 1 < argc) {
			string event = argv[++i];
			size_t separator = event.find(':');
			if (separator == string::npos) {
				cerr << arg << " requires sim_time:key\n";
				return 1;
			}
			static const std::map<string, SDL_Keycode> keys = {
				{"up", SDLK_UP}, {"down", SDLK_DOWN},
				{"left", SDLK_LEFT}, {"right", SDLK_RIGHT},
				{"enter", SDLK_RETURN}, {"escape", SDLK_ESCAPE},
				{"space", SDLK_SPACE}, {"tab", SDLK_TAB},
				{"alt", SDLK_LALT}, {"f4", SDLK_F4},
				{"i", SDLK_i}, {"n", SDLK_n}, {"o", SDLK_o}, {"w", SDLK_w},
			};
			auto key = keys.find(event.substr(separator + 1));
			if (key == keys.end()) {
				cerr << "unsupported " << arg << " key: " << event.substr(separator + 1) << "\n";
				return 1;
			}
			key_edge_events.push_back({std::stoull(event.substr(0, separator)) / 2,
			                           key->second, arg == "--key-down-at"});
		} else if (arg == "--key-on-text" && i + 1 < argc) {
			string event = argv[++i];
			size_t separator = event.rfind(':');
			if (separator == string::npos || separator == 0) {
				cerr << "--key-on-text requires substring:key\n";
				return 1;
			}
			static const std::map<string, SDL_Keycode> keys = {
				{"up", SDLK_UP}, {"down", SDLK_DOWN},
				{"left", SDLK_LEFT}, {"right", SDLK_RIGHT},
				{"enter", SDLK_RETURN}, {"escape", SDLK_ESCAPE},
				{"space", SDLK_SPACE}, {"tab", SDLK_TAB},
				{"alt", SDLK_LALT}, {"f4", SDLK_F4},
				{"i", SDLK_i}, {"n", SDLK_n}, {"o", SDLK_o}, {"w", SDLK_w},
			};
			auto key = keys.find(event.substr(separator + 1));
			if (key == keys.end()) {
				cerr << "unsupported --key-on-text key: " << event.substr(separator + 1) << "\n";
				return 1;
			}
			text_key_events.push_back({event.substr(0, separator), key->second});
		} else if (arg == "--mouse-at" && i + 1 < argc) {
			string event = argv[++i];
			vector<string> fields;
			size_t start = 0;
			while (true) {
				size_t separator = event.find(':', start);
				fields.push_back(event.substr(start, separator - start));
				if (separator == string::npos) break;
				start = separator + 1;
			}
			if (fields.size() != 3 && fields.size() != 4) {
				cerr << "--mouse-at requires sim_time:dx:dy[:buttons]\n";
				return 1;
			}
			int dx = std::stoi(fields[1], nullptr, 0);
			int dy = std::stoi(fields[2], nullptr, 0);
			unsigned buttons = fields.size() == 4 ? std::stoul(fields[3], nullptr, 0) : 0;
			if (buttons > 7) {
				cerr << "--mouse-at buttons must be a 3-bit L/R/M mask\n";
				return 1;
			}
			mouse_packet_events.push_back({std::stoull(fields[0]) / 2, dx, dy,
			                               static_cast<uint8_t>(buttons)});
		} else if (arg == "--control-port" && i + 1 < argc) {
			control_port = std::stoul(argv[++i]);
			if (control_port == 0 || control_port > 65535) {
				cerr << "--control-port must be between 1 and 65535\n";
				return 1;
			}
		} else if (arg == "--control-bind" && i + 1 < argc) {
			control_bind = argv[++i];
		} else if (arg == "--ctrl-alt-del-at" && i + 1 < argc) {
			ctrl_alt_del_cycles.push_back(std::stoull(argv[++i]) / 2);   // sim_time -> cycles
		} else if (arg == "--screen-at" && i + 1 < argc) {
			screen_check_cycles.push_back(std::stoull(argv[++i]) / 2);   // sim_time -> cycles
		} else if (arg == "--log-eip" && i + 1 < argc) {
			string marker = argv[++i];
			size_t separator = marker.find(':');
			if (separator == string::npos) {
				cerr << "--log-eip requires hexadecimal CS:EIP\n";
				return 1;
			}
			log_eip_cs = static_cast<uint16_t>(std::stoul(marker.substr(0, separator), nullptr, 16));
			log_eip_offset = static_cast<uint32_t>(std::stoul(marker.substr(separator + 1), nullptr, 16));
			log_eip_enabled = true;
		} else if (arg == "--screenshot-dir" && i + 1 < argc) {
			screenshot_dir = argv[++i];
		} else if (arg == "--screenshot-interval" && i + 1 < argc) {
			screenshot_interval_cycles = std::stoull(argv[++i]) / 2;
		} else if (arg == "--stop-on-text" && i + 1 < argc) {
			stop_on_text = argv[++i];
		} else if (arg == "--ide") {
			g_ide_debug = true;
		} else if (arg == "--no-ide") {
			g_ide_debug = false;
		} else if (arg == "--record") {
			record_audio = true;
		} else if (arg == "--trace-on-flatline") {
			arm_trace_on_flatline = true;
			enable_trace = true;
			trace_start_cycle = std::numeric_limits<uint64_t>::max(); // until detector arms
		} else if (arg == "--flatline-window" && i + 1 < argc) {
			flatline_trace_window = std::stoull(argv[++i]) / 2;   // sim_time -> cycles
		} else if (arg == "--checkpoint-dir" && i + 1 < argc) {
			checkpoint_dir = argv[++i];
		} else if (arg == "--checkpoint-interval-sec" && i + 1 < argc) {
			checkpoint_interval_sec = std::stoull(argv[++i]);
		} else if (arg == "--checkpoint-keep" && i + 1 < argc) {
			checkpoint_keep = static_cast<size_t>(std::stoull(argv[++i]));
		} else if (arg == "--restore" && i + 1 < argc) {
			restore_path = argv[++i];
		} else if (!arg.empty() && arg[0] == '+') {
			// Verilator plusargs are consumed by Verilated::commandArgs() and
			// may be used by RTL diagnostics via $test$plusargs.
		} else {
			usage();
			return 1;
		}
	}

	if (!checkpoint_dir.empty() && checkpoint_interval_sec == 0) {
		checkpoint_interval_sec = 600;
	}
	if (!screenshot_dir.empty()) {
		if (screenshot_interval_cycles == 0) screenshot_interval_cycles = 12500000;
		fs::create_directories(screenshot_dir);
		next_screenshot_cycle = screenshot_interval_cycles;
	}
	ControlServer control_server;
	if (control_port != 0) {
		string error;
		if (!control_server.start(control_bind, static_cast<uint16_t>(control_port), error)) {
			cerr << "control server failed: " << error << "\n";
			return 1;
		}
		cout << "Control socket listening on " << control_bind << ":" << control_port << "\n";
	}

	for (uint64_t cycle : enter_cycles) {
		auto it = ps2scancodes.find(SDLK_RETURN);
		if (it != ps2scancodes.end()) {
			std::vector<uint8_t> bytes;
			bytes.insert(bytes.end(), it->second.first.begin(), it->second.first.end());
			bytes.insert(bytes.end(), it->second.second.begin(), it->second.second.end());
			ps2_events.push_back({cycle, bytes});
		}
	}
	for (const auto& [cycle, key] : key_events) {
		auto it = ps2scancodes.find(key);
		if (it != ps2scancodes.end()) {
			std::vector<uint8_t> bytes;
			bytes.insert(bytes.end(), it->second.first.begin(), it->second.first.end());
			bytes.insert(bytes.end(), it->second.second.begin(), it->second.second.end());
			ps2_events.push_back({cycle, bytes});
		}
	}
	for (const auto& [cycle, key, pressed] : key_edge_events) {
		auto it = ps2scancodes.find(key);
		if (it != ps2scancodes.end()) {
			const auto& bytes = pressed ? it->second.first : it->second.second;
			ps2_events.push_back({cycle, {bytes.begin(), bytes.end()}});
		}
	}
	for (uint64_t cycle : ctrl_alt_del_cycles) {
		std::vector<uint8_t> bytes;
		for (SDL_Keycode key : {SDLK_LCTRL, SDLK_LALT, SDLK_DELETE}) {
			auto it = ps2scancodes.find(key);
			if (it != ps2scancodes.end())
				bytes.insert(bytes.end(), it->second.first.begin(), it->second.first.end());
		}
		for (SDL_Keycode key : {SDLK_DELETE, SDLK_LALT, SDLK_LCTRL}) {
			auto it = ps2scancodes.find(key);
			if (it != ps2scancodes.end())
				bytes.insert(bytes.end(), it->second.second.begin(), it->second.second.end());
		}
		ps2_events.push_back({cycle, bytes});
	}
	std::sort(ps2_events.begin(), ps2_events.end(),
		[](const ScheduledPs2Bytes& a, const ScheduledPs2Bytes& b) { return a.cycle < b.cycle; });
	const std::vector<ScheduledPs2Bytes> command_line_ps2_events = ps2_events;
	for (const auto& [cycle, dx, dy, buttons] : mouse_packet_events) {
		mouse_events.push_back({cycle, encode_mouse_packets(dx, dy, buttons)});
	}
	std::sort(mouse_events.begin(), mouse_events.end(),
		[](const ScheduledPs2Bytes& a, const ScheduledPs2Bytes& b) { return a.cycle < b.cycle; });
	const std::vector<ScheduledPs2Bytes> command_line_mouse_events = mouse_events;
	std::sort(screen_check_cycles.begin(), screen_check_cycles.end());

	vector<uint8_t> boot0;
	vector<uint8_t> boot1;
	if (restore_path.empty()) {
		try {
			boot0 = read_file(boot0_path);
			boot1 = read_file(boot1_path);
		} catch (const std::exception& e) {
			cerr << e.what() << "\n";
			return 1;
		}
	}

	HpsIde ide0(0, 0xF000);
	HpsIde ide1(1, 0xF100);
	HpsFloppy floppy0;
	ide0.set_debug(g_ide_debug);
	ide1.set_debug(g_ide_debug);
	if (restore_path.empty() && !ide0.open(disk_path)) {
		cerr << "failed to open disk image " << disk_path << "\n";
		return 1;
	}
	if (restore_path.empty() && !floppy_path.empty()) {
		try {
			floppy0.open(floppy_path);
		} catch (const std::exception& e) {
			cerr << e.what() << "\n";
			return 1;
		}
	}

	SDL_Window* sdl_window = nullptr;
	SDL_Renderer* sdl_renderer = nullptr;
	SDL_Texture* sdl_texture = nullptr;
	uint32_t last_render_ms = 0;
	uint32_t last_title_ms = 0;
	vluint64_t last_title_sim_time = 0;
	bool present_dirty = true;
	int resolution_x = 720;
	int resolution_y = 400;
	int scan_x = 0;
	int scan_y = 0;
	int frame_pix_cnt = 0;
	int frame_x_max = 0;
	int frame_line_max = 0;
	uint64_t next_console_text_check = 0;
	std::string last_console_text;
	size_t next_text_key_event = 0;
	deque<fs::path> control_screenshot_requests;

	if (!g_headless) {
		if (SDL_Init(SDL_INIT_VIDEO) < 0) {
			cerr << "SDL init failed: " << SDL_GetError() << "\n";
			return 1;
		}
		sdl_window = SDL_CreateWindow("z386 MiSTer sim", SDL_WINDOWPOS_CENTERED,
			SDL_WINDOWPOS_CENTERED, resolution_x * INITIAL_WINDOW_SCALE,
			resolution_y * INITIAL_WINDOW_SCALE,
			SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE);
		if (!sdl_window) {
			cerr << "SDL window creation failed: " << SDL_GetError() << "\n";
			SDL_Quit();
			return 1;
		}
		SDL_SetWindowMinimumSize(sdl_window, resolution_x, resolution_y);
		sdl_renderer = SDL_CreateRenderer(sdl_window, -1, SDL_RENDERER_ACCELERATED);
		if (!sdl_renderer) sdl_renderer = SDL_CreateRenderer(sdl_window, -1, SDL_RENDERER_SOFTWARE);
		if (!sdl_renderer) {
			cerr << "SDL renderer creation failed: " << SDL_GetError() << "\n";
			SDL_DestroyWindow(sdl_window);
			SDL_Quit();
			return 1;
		}
		SDL_RenderSetLogicalSize(sdl_renderer, resolution_x, resolution_y);
		sdl_texture = SDL_CreateTexture(sdl_renderer, SDL_PIXELFORMAT_RGBA8888,
			SDL_TEXTUREACCESS_STREAMING, H_RES, V_RES);
		if (!sdl_texture) {
			cerr << "SDL texture creation failed: " << SDL_GetError() << "\n";
			SDL_DestroyRenderer(sdl_renderer);
			SDL_DestroyWindow(sdl_window);
			SDL_Quit();
			return 1;
		}
		SDL_StopTextInput();
	}

	tb.clk_sys = 0;
	tb.clk_audio = 0;
	tb.reset = 1;
	unsigned ram_size_code = (ram_mb == 16) ? 0 :
	                         (ram_mb == 32) ? 1 :
	                         (ram_mb == 64) ? 2 : 3;
	tb.status = (uint64_t{cpu_speed_status} << 8) |
	            (uint64_t{ram_size_code} << 29) |
	            (uint64_t{!vga_border} << 54) |
	            (uint64_t{!opl3_mode} << 57);
	tb.ioctl_download = 0;
	tb.ioctl_index = 0;
	tb.ioctl_wr = 0;
	tb.ioctl_addr = 0;
	tb.ioctl_dout = 0;
	tb.ddram_busy = 0;
	tb.ddram_dout = 0;
	tb.ddram_dout_ready = 0;
	tb.mgmt_address = 0;
	tb.mgmt_read = 0;
	tb.mgmt_write = 0;
	tb.mgmt_writedata = 0;

	if (record_audio) {
		wav_writer = new WAVWriter("dsp.wav", AUDIO_SAMPLE_RATE, 2, 16);
		cout << "Recording mixed audio to dsp.wav at " << AUDIO_SAMPLE_RATE << " Hz\n";
	}

	if (restore_path.empty()) {
		stage_roms_to_ddr(boot0, boot1);
		full_step();
		tb.reset = 0;
		full_step();
		configure_x86_management(ide0.present(), floppy0, floppy0.present());
	}
	trace_loop_started = true;

	bool saw_first_instruction = false;
	bool saw_post = false;
	bool saw_video_sync = false;
	bool saw_boot_sector = false;
	bool saw_post_boot_exec = false;
	bool saw_boot_menu_text = false;
	bool saw_nonblack_pixel = false;
	unsigned boot_page_logs = 0;
	bool prev_vs = false;
	bool prev_hs = false;
	bool prev_de = false;
	bool bios_dbg_wr_prev = false;
	bool log_eip_prev = false;
	int sim_soft_reset_cycles = 0;
	bool gui_r_soft_reset_active = false;
	bool gui_c_checkpoint_active = false;
	bool mouse_captured = false;
	uint8_t last_post = 0;
	bool have_post = false;
	bool running = true;
	uint64_t loop_start_cycle = 0;
	auto next_checkpoint_at = std::chrono::steady_clock::now() +
		std::chrono::seconds(checkpoint_interval_sec ? checkpoint_interval_sec : 1);
	auto* core = tb.z386_mister_sim;
	auto* sys = core->system_i;

	tb.sim_kbd_data = 0;
	tb.sim_kbd_data_valid = 0;
	tb.sim_kbd_host_data_clear = 0;
	tb.sim_mouse_data = 0;
	tb.sim_mouse_data_valid = 0;
	tb.sim_soft_reset = 0;

	auto set_mouse_capture = [&](bool capture) {
		if (mouse_captured == capture) return;
		mouse_captured = capture;
		SDL_CaptureMouse(capture ? SDL_TRUE : SDL_FALSE);
		SDL_SetRelativeMouseMode(capture ? SDL_TRUE : SDL_FALSE);
		SDL_ShowCursor(capture ? SDL_DISABLE : SDL_ENABLE);
		last_title_ms = 0;
	};

	auto keyboard_send_pre = [&](uint64_t cycle) {
		tb.sim_kbd_host_data_clear = kbd_host_clear_pending;

		while (next_ps2_event < ps2_events.size() && ps2_events[next_ps2_event].cycle <= cycle) {
			queue_ps2_bytes(ps2_events[next_ps2_event].bytes);
			next_ps2_event++;
		}

		if (!kbd_host_busy && cycle - last_kbd_byte_time > 100000 && !kbd_scancode_queue.empty()) {
			uint8_t byte = kbd_scancode_queue.front();
			kbd_scancode_queue.pop_front();
			tb.sim_kbd_data = byte;
			tb.sim_kbd_data_valid = 1;
			last_kbd_byte_time = cycle;
			printf("%8llu: Sending scancode 0x%02X\n",
			       (unsigned long long)sim_time, byte);
		} else {
			tb.sim_kbd_data_valid = 0;
		}
	};

	auto keyboard_observe_post = [&](uint64_t cycle) {
		if (!posedge) return;

		uint16_t kbd_host_data = tb.sim_kbd_host_data;
		bool kbd_host_valid = (kbd_host_data & 0x100) != 0;
		if (kbd_host_valid && !kbd_host_busy) {
			uint8_t cmd = static_cast<uint8_t>(kbd_host_data & 0xFF);
			printf("%8llu: Received keyboard command 0x%02X\n",
			       (unsigned long long)sim_time, cmd);
			handle_kbd_host_cmd(cmd);
			kbd_host_busy = true;
			kbd_host_clear_pending = true;
		} else if (!kbd_host_valid && kbd_host_busy) {
			kbd_host_busy = false;
			kbd_host_clear_pending = false;
		}
		tb.sim_kbd_data_valid = 0;
	};

	auto mouse_send_pre = [&](uint64_t cycle) {
		while (next_mouse_event < mouse_events.size() && mouse_events[next_mouse_event].cycle <= cycle) {
			const auto& bytes = mouse_events[next_mouse_event].bytes;
			mouse_byte_queue.insert(mouse_byte_queue.end(), bytes.begin(), bytes.end());
			next_mouse_event++;
		}
		if (cycle - last_mouse_byte_time > 20000 && !mouse_byte_queue.empty()) {
			tb.sim_mouse_data = mouse_byte_queue.front();
			mouse_byte_queue.pop_front();
			tb.sim_mouse_data_valid = 1;
			last_mouse_byte_time = cycle;
		} else {
			tb.sim_mouse_data_valid = 0;
		}
	};

	auto update_mouse_button = [](uint8_t& buttons, uint8_t sdl_button, bool pressed) {
		uint8_t mask = 0;
		if (sdl_button == SDL_BUTTON_LEFT) mask = 0x01;
		else if (sdl_button == SDL_BUTTON_RIGHT) mask = 0x02;
		else if (sdl_button == SDL_BUTTON_MIDDLE) mask = 0x04;
		if (mask == 0) return;
		if (pressed) buttons |= mask;
		else buttons &= ~mask;
	};

	auto consume_video = [&](uint64_t cycle) {
		if (!posedge) return;

		if (tb.video_vs && !prev_vs) {
			scan_x = 0;
			scan_y = 0;
		}

		if (tb.ce_pixel) {
			if (tb.video_de && !prev_de) {
				scan_x = 0;
				if (frame_line_max != 0 && scan_y + 1 < V_RES) scan_y++;
				if (scan_y + 1 > frame_line_max) frame_line_max = scan_y + 1;
			}
			if (tb.video_de) {
				if (scan_x < H_RES && scan_y < V_RES) {
					Pixel* p = &screenbuffer[scan_y * H_RES + scan_x];
					p->a = 0xff;
					p->r = tb.video_r;
					p->g = tb.video_g;
					p->b = tb.video_b;
					if (p->r || p->g || p->b) frame_pix_cnt++;
					if (!saw_nonblack_pixel && (p->r || p->g || p->b)) {
						saw_nonblack_pixel = true;
						cout << sim_time << ": first non-black VGA pixel at x=" << scan_x
						     << " y=" << scan_y << "\n";
					}
				}
				scan_x++;
				if (scan_x > frame_x_max) frame_x_max = scan_x;
			}
		}

		if (tb.video_vs && !prev_vs) {
			saw_video_sync = true;
			const bool svga_frame = render_svga8_frame(
				presentbuffer, resolution_x, resolution_y);
			if (!svga_frame) {
				if (frame_x_max >= 640) resolution_x = std::min(frame_x_max, H_RES);
				if (frame_line_max >= 300) resolution_y = std::min(frame_line_max, V_RES);
				std::copy(std::begin(screenbuffer), std::end(screenbuffer),
				          std::begin(presentbuffer));
			}
			present_dirty = true;
			cout << sim_time << ": FRAME: PE=" << static_cast<int>(tb.dbg_pe)
			     << " VM=" << static_cast<int>(tb.dbg_vm)
			     << " CS:EIP=" << std::hex << tb.dbg_cs << ":" << tb.dbg_eip
			     << std::dec << " pix=" << frame_pix_cnt
			     << " lines=" << frame_line_max
			     << " xmax=" << frame_x_max;
			if (svga_frame)
				cout << " fb=" << resolution_x << "x" << resolution_y;
			cout << "\n";
			if (!screenshot_dir.empty() && cycle >= next_screenshot_cycle) {
				fs::path path = fs::path(screenshot_dir) /
				                ("screen_" + std::to_string(sim_time) + ".png");
				if (dump_screen_png(path, resolution_x, resolution_y))
					cout << sim_time << ": screenshot " << path.string() << "\n";
				while (next_screenshot_cycle <= cycle)
					next_screenshot_cycle += screenshot_interval_cycles;
			}
			while (!control_screenshot_requests.empty()) {
				const fs::path path = control_screenshot_requests.front();
				control_screenshot_requests.pop_front();
				if (dump_screen_png(path, resolution_x, resolution_y))
					cout << sim_time << ": control screenshot " << path << "\n";
				else
					cerr << "control screenshot failed: " << path << "\n";
			}
			std::fill(std::begin(screenbuffer), std::end(screenbuffer), Pixel{0xff, 0x00, 0x00, 0x00});
			frame_pix_cnt = 0;
			frame_x_max = 0;
			frame_line_max = 0;
			if (saw_post_boot_exec && cycle >= next_console_text_check) {
				std::string screen = current_text_screen();
				if (screen != last_console_text) {
					cout << sim_time << ": VGA text update\n";
					dump_nonempty_rows(screen);
					last_console_text = screen;
				}
				if (!stop_on_text.empty() && screen.find(stop_on_text) != std::string::npos) {
					cout << sim_time << ": stop-on-text matched [" << stop_on_text << "]\n";
					running = false;
				}
				if (next_text_key_event < text_key_events.size()) {
					const auto& [needle, key] = text_key_events[next_text_key_event];
					if (screen.find(needle) != std::string::npos) {
						cout << sim_time << ": key-on-text matched [" << needle << "]\n";
						queue_sdl_key(key, true);
						queue_sdl_key(key, false);
						next_text_key_event++;
					}
				}
				next_console_text_check = cycle + 1000000ull;
			}
			if (!saw_boot_menu_text && saw_boot_sector &&
			    next_screen_check < screen_check_cycles.size() &&
			    cycle >= screen_check_cycles[next_screen_check]) {
				std::string screen = current_text_screen();
				std::string row = row_for_match(screen, "Press ESC for boot menu");
				cout << sim_time << ": screen checkpoint\n";
				if (!row.empty()) {
					saw_boot_menu_text = true;
					cout << sim_time << ": boot menu text: [" << row << "]\n";
				} else {
					dump_nonempty_rows(screen);
				}
				next_screen_check++;
			}
		}
		prev_vs = tb.video_vs;
		prev_hs = tb.video_hs;
		prev_de = tb.video_de;
	};

	auto resolve_restore_path = [](const string& path) -> fs::path {
		fs::path p(path);
		fs::path latest = p / "latest.txt";
		if (!fs::exists(p / "model.vlt") && fs::exists(latest)) {
			std::ifstream in(latest);
			string line;
			std::getline(in, line);
			if (!line.empty()) return fs::path(line);
		}
		return p;
	};

	auto prune_checkpoints = [&]() {
		if (checkpoint_dir.empty() || checkpoint_keep == 0) return;

		std::vector<fs::path> entries;
		for (const auto& entry : fs::directory_iterator(checkpoint_dir)) {
			if (!entry.is_directory()) continue;
			string name = entry.path().filename().string();
			if (name.rfind("ckpt_", 0) == 0 && name.find(".tmp") == string::npos) {
				entries.push_back(entry.path());
			}
		}

		std::sort(entries.begin(), entries.end());
		while (entries.size() > checkpoint_keep) {
			fs::remove_all(entries.front());
			entries.erase(entries.begin());
		}
	};

	auto save_checkpoint = [&](uint64_t cycle) {
		if (checkpoint_dir.empty()) return;

		fs::create_directories(checkpoint_dir);
		std::ostringstream name;
		name << "ckpt_" << std::setw(16) << std::setfill('0') << cycle;
		fs::path final_dir = fs::path(checkpoint_dir) / name.str();
		fs::path tmp_dir = fs::path(checkpoint_dir) / (name.str() + ".tmp");

		fs::remove_all(tmp_dir);
		fs::create_directories(tmp_dir);

		{
			VerilatedSave save;
			save.open((tmp_dir / "model.vlt").string());
			save << tb;
			save.close();
		}

		{
			std::ofstream out(tmp_dir / "harness.bin", ios::binary);
			const uint32_t magic = 0x5A434B50; // ZCKP
			const uint32_t version = 5;
			write_pod(out, magic);
			write_pod(out, version);
			write_pod(out, sim_time);
			write_pod(out, current_cycle);
			write_pod(out, posedge);
			write_pod(out, audio_clock_accum);
			write_pod(out, audio_sample_accum);
			write_vector_u8(out, ddram_mem);
			write_pod(out, ddram_resp_valid);
			write_pod(out, ddram_resp_data);
			write_vector_u8(out, fb_mem);
			write_pod(out, fb_palette);
			write_scheduled_events(out, ps2_events);
			write_pod(out, next_ps2_event);
			write_scheduled_events(out, mouse_events);
			write_pod(out, next_mouse_event);
			write_deque_u8(out, kbd_scancode_queue);
			write_deque_u8(out, mouse_byte_queue);
			write_pod(out, last_kbd_byte_time);
			write_pod(out, last_mouse_byte_time);
			write_pod(out, ps2_kbd_scan_set);
			write_pod(out, ps2_mouse_buttons);
			write_pod(out, pending_kbd_cmd);
			write_pod(out, pending_kbd_arg);
			write_pod(out, kbd_host_busy);
			write_pod(out, kbd_host_clear_pending);
			write_vector_u64(out, screen_check_cycles);
			write_pod(out, next_screen_check);
			for (bool seen : boot_pages_seen) {
				uint8_t value = seen ? 1 : 0;
				write_pod(out, value);
			}
			write_pod(out, saw_first_instruction);
			write_pod(out, saw_post);
			write_pod(out, saw_video_sync);
			write_pod(out, saw_boot_sector);
			write_pod(out, saw_post_boot_exec);
			write_pod(out, saw_boot_menu_text);
			write_pod(out, saw_nonblack_pixel);
			write_pod(out, boot_page_logs);
			write_pod(out, prev_vs);
			write_pod(out, prev_hs);
			write_pod(out, prev_de);
			write_pod(out, bios_dbg_wr_prev);
			write_pod(out, last_post);
			write_pod(out, have_post);
			write_pod(out, mouse_captured);
			write_pod(out, last_title_sim_time);
			write_pod(out, resolution_x);
			write_pod(out, resolution_y);
			write_pod(out, next_console_text_check);
			write_string(out, last_console_text);
			ide0.save(out);
			ide1.save(out);
		}

		{
			std::ofstream meta(tmp_dir / "meta.txt");
			meta << "cycle " << cycle << "\n";
			meta << "sim_time " << sim_time << "\n";
			meta << "disk " << disk_path << "\n";
			meta << "boot0 " << boot0_path << "\n";
			meta << "boot1 " << boot1_path << "\n";
		}

		fs::remove_all(final_dir);
		fs::rename(tmp_dir, final_dir);
		{
			std::ofstream latest(fs::path(checkpoint_dir) / "latest.txt");
			latest << final_dir.string() << "\n";
		}
		prune_checkpoints();
		cout << sim_time << ": checkpoint saved to " << final_dir << "\n";
	};

	auto restore_checkpoint = [&]() {
		if (restore_path.empty()) return;

		fs::path dir = resolve_restore_path(restore_path);
		{
			VerilatedRestore restore;
			restore.open((dir / "model.vlt").string());
			restore >> tb;
			restore.close();
		}

		{
			std::ifstream in(dir / "harness.bin", ios::binary);
			uint32_t magic = 0;
			uint32_t version = 0;
			read_pod(in, magic);
			read_pod(in, version);
			if (magic != 0x5A434B50 || (version < 1 || version > 5)) {
				throw std::runtime_error("bad simulator checkpoint");
			}
			read_pod(in, sim_time);
			read_pod(in, current_cycle);
			read_pod(in, posedge);
			if (version >= 4) {
				read_pod(in, audio_clock_accum);
				read_pod(in, audio_sample_accum);
			} else {
				audio_clock_accum = 0;
				audio_sample_accum = 0;
			}
			read_vector_u8(in, ddram_mem);
			read_pod(in, ddram_resp_valid);
			read_pod(in, ddram_resp_data);
			if (version >= 5) {
				read_vector_u8(in, fb_mem);
				read_pod(in, fb_palette);
			}
			read_scheduled_events(in, ps2_events);
			read_pod(in, next_ps2_event);
			if (version >= 3) {
				read_scheduled_events(in, mouse_events);
				read_pod(in, next_mouse_event);
			}
			read_deque_u8(in, kbd_scancode_queue);
			if (version >= 2) read_deque_u8(in, mouse_byte_queue);
			read_pod(in, last_kbd_byte_time);
			if (version >= 2) read_pod(in, last_mouse_byte_time);
			read_pod(in, ps2_kbd_scan_set);
			if (version >= 2) read_pod(in, ps2_mouse_buttons);
			read_pod(in, pending_kbd_cmd);
			read_pod(in, pending_kbd_arg);
			read_pod(in, kbd_host_busy);
			read_pod(in, kbd_host_clear_pending);
			read_vector_u64(in, screen_check_cycles);
			read_pod(in, next_screen_check);
			for (auto& seen : boot_pages_seen) {
				uint8_t value = 0;
				read_pod(in, value);
				seen = value != 0;
			}
			read_pod(in, saw_first_instruction);
			read_pod(in, saw_post);
			read_pod(in, saw_video_sync);
			read_pod(in, saw_boot_sector);
			read_pod(in, saw_post_boot_exec);
			read_pod(in, saw_boot_menu_text);
			read_pod(in, saw_nonblack_pixel);
			read_pod(in, boot_page_logs);
			read_pod(in, prev_vs);
			read_pod(in, prev_hs);
			read_pod(in, prev_de);
			read_pod(in, bios_dbg_wr_prev);
			read_pod(in, last_post);
			read_pod(in, have_post);
			if (version >= 2) read_pod(in, mouse_captured);
			read_pod(in, last_title_sim_time);
			read_pod(in, resolution_x);
			read_pod(in, resolution_y);
			read_pod(in, next_console_text_check);
			read_string(in, last_console_text);
			ide0.load(in);
			ide1.load(in);
		}

		std::vector<ScheduledPs2Bytes> pending_events;
		pending_events.insert(pending_events.end(), ps2_events.begin() + next_ps2_event,
		                      ps2_events.end());
		for (const auto& event : command_line_ps2_events) {
			if (event.cycle > current_cycle) pending_events.push_back(event);
		}
		std::sort(pending_events.begin(), pending_events.end(),
			[](const ScheduledPs2Bytes& a, const ScheduledPs2Bytes& b) {
				return a.cycle < b.cycle;
			});
		ps2_events = std::move(pending_events);
		next_ps2_event = 0;

		std::vector<ScheduledPs2Bytes> pending_mouse_events;
		pending_mouse_events.insert(pending_mouse_events.end(),
		                            mouse_events.begin() + next_mouse_event,
		                            mouse_events.end());
		for (const auto& event : command_line_mouse_events) {
			if (event.cycle > current_cycle) pending_mouse_events.push_back(event);
		}
		std::sort(pending_mouse_events.begin(), pending_mouse_events.end(),
			[](const ScheduledPs2Bytes& a, const ScheduledPs2Bytes& b) {
				return a.cycle < b.cycle;
			});
		mouse_events = std::move(pending_mouse_events);
		next_mouse_event = 0;

		loop_start_cycle = current_cycle + 1;
		next_checkpoint_at = std::chrono::steady_clock::now() +
			std::chrono::seconds(checkpoint_interval_sec ? checkpoint_interval_sec : 1);
		if (!g_headless) {
			bool restored_mouse_capture = mouse_captured;
			mouse_captured = false;
			set_mouse_capture(restored_mouse_capture);
		}
		cout << "restored checkpoint " << dir << " at sim_time " << sim_time << " (cycle " << current_cycle << ")\n";
	};

	try {
		restore_checkpoint();
	} catch (const std::exception& e) {
		cerr << e.what() << "\n";
		return 1;
	}
	// VerilatedRestore replaces the model's serialized tracing state. Attach
	// the FST writer only after restore so checkpoint replays remain traceable.
	if (enable_trace) set_trace(true);
	// Checkpoints preserve MiSTer status. Override only hardware selections that
	// were explicitly supplied for this replay.
	if (ram_mb_explicit)
		tb.status = (tb.status & ~(uint64_t{3} << 29)) |
		            (uint64_t{ram_size_code} << 29);
	if (opl_mode_explicit)
		tb.status = (tb.status & ~(uint64_t{1} << 57)) |
		            (uint64_t{!opl3_mode} << 57);
	if (vga_border_explicit)
		tb.status = (tb.status & ~(uint64_t{1} << 54)) |
		            (uint64_t{!vga_border} << 54);
	tb.eval();

	auto process_control_commands = [&]() {
		control_server.update_status(sim_time, resolution_x, resolution_y, ps2_mouse_buttons);
		for (const string& line : control_server.drain_commands()) {
			std::istringstream command(line);
			string operation;
			command >> operation;
			if (operation == "mouse") {
				int dx = 0;
				int dy = 0;
				unsigned buttons = ps2_mouse_buttons;
				if (!(command >> dx >> dy)) {
					cerr << "control: mouse requires <dx> <dy> [buttons]\n";
					continue;
				}
				if (command >> buttons) {
					if (buttons > 7) {
						cerr << "control: mouse buttons must be a 3-bit L/R/M mask\n";
						continue;
					}
				}
				ps2_mouse_buttons = static_cast<uint8_t>(buttons);
				queue_mouse_packet(dx, dy, ps2_mouse_buttons);
				cout << sim_time << ": control mouse dx=" << dx << " dy=" << dy
				     << " buttons=" << buttons << "\n";
			} else if (operation == "key") {
				string name;
				string action = "press";
				command >> name;
				if (name.empty()) {
					cerr << "control: key requires <name> [press|down|up]\n";
					continue;
				}
				command >> action;
				SDL_Keycode key = SDLK_UNKNOWN;
				if (!parse_named_key(name, key) || ps2scancodes.find(key) == ps2scancodes.end()) {
					cerr << "control: unsupported key: " << name << "\n";
					continue;
				}
				if (action == "press") {
					queue_sdl_key(key, true);
					queue_sdl_key(key, false);
				} else if (action == "down") {
					queue_sdl_key(key, true);
				} else if (action == "up") {
					queue_sdl_key(key, false);
				} else {
					cerr << "control: key action must be press, down, or up\n";
					continue;
				}
				cout << sim_time << ": control key " << name << " " << action << "\n";
			} else if (operation == "checkpoint") {
				if (checkpoint_dir.empty()) checkpoint_dir = "checkpoints";
				try {
					save_checkpoint(current_cycle);
				} catch (const std::exception& e) {
					cerr << "control checkpoint failed: " << e.what() << "\n";
				}
			} else if (operation == "screenshot") {
				string requested_path;
				command >> requested_path;
				fs::path path;
				if (!requested_path.empty()) {
					path = requested_path;
				} else if (!screenshot_dir.empty()) {
					path = fs::path(screenshot_dir) /
					       ("control_" + std::to_string(sim_time) + ".png");
				} else {
					path = "control_" + std::to_string(sim_time) + ".png";
				}
				if (!path.parent_path().empty()) fs::create_directories(path.parent_path());
				control_screenshot_requests.push_back(path);
				cout << sim_time << ": control screenshot queued for next frame " << path << "\n";
			} else if (operation == "quit") {
				cout << sim_time << ": control quit\n";
				running = false;
			} else {
				cerr << "control: unsupported command: " << line << "\n";
			}
		}
	};

	static constexpr uint64_t GUI_POLL_CYCLES = 2048;
	static constexpr uint64_t CONTROL_POLL_CYCLES = 2048;
	uint64_t next_gui_poll_cycle = loop_start_cycle;
	uint64_t next_control_poll_cycle = loop_start_cycle;
	size_t next_cpu_speed_event = 0;
	while (next_cpu_speed_event < cpu_speed_events.size() &&
	       cpu_speed_events[next_cpu_speed_event].first < loop_start_cycle)
		next_cpu_speed_event++;

	for (uint64_t cycle = loop_start_cycle; cycle < max_cycles && running && (force_stop_cycle == 0 || cycle < force_stop_cycle); ++cycle) {
		current_cycle = cycle;
		while (next_cpu_speed_event < cpu_speed_events.size() &&
		       cpu_speed_events[next_cpu_speed_event].first == cycle) {
			const unsigned speed = cpu_speed_events[next_cpu_speed_event].second;
			tb.status = (tb.status & ~(uint64_t{3} << 8)) | (uint64_t{speed} << 8);
			cout << sim_time << ": CPU speed status=" << speed << "\n";
			next_cpu_speed_event++;
		}
		if (control_port != 0 && cycle >= next_control_poll_cycle) {
			next_control_poll_cycle = cycle + CONTROL_POLL_CYCLES;
			process_control_commands();
			if (!running) break;
		}
		tb.sim_soft_reset = (sim_soft_reset_cycles > 0) ? 1 : 0;
		if (sim_soft_reset_cycles > 0) sim_soft_reset_cycles--;
		tb.mgmt_read = 0;
		tb.mgmt_write = 0;
		g_ide_time = sim_time;
		ide0.tick(tb);
		if (!tb.mgmt_read && !tb.mgmt_write) ide1.tick(tb);
		if (!tb.mgmt_read && !tb.mgmt_write) floppy0.tick(tb);

		if (!tb.clk_sys) {
			keyboard_send_pre(cycle);
			mouse_send_pre(cycle);
		}
		step();
		keyboard_observe_post(cycle);
		consume_video(cycle);

		if (!tb.clk_sys) {
			keyboard_send_pre(cycle);
			mouse_send_pre(cycle);
		}
		step();
		keyboard_observe_post(cycle);
		consume_video(cycle);

		// --- VGA attribute-controller PELWIDTH debug (mode-101 issue #5) ---
		// {
		// 	auto* vsys = tb.z386_mister_sim->system_i;
		// 	static uint8_t prev_aiw = 0, prev_pelw = 0xFF, prev_gsm = 0xFF;
		// 	uint8_t aiw  = vsys->__PVT__vga_inst__DOT__attrib_io_write;
		// 	uint8_t aidx = vsys->__PVT__vga_inst__DOT__attrib_io_index;
		// 	uint8_t pelw = vsys->__PVT__vga_inst__DOT__attrib_pelclock_div2;
		// 	uint8_t ff   = vsys->__PVT__vga_inst__DOT__attrib_flip_flop;
		// 	uint8_t gsm  = vsys->__PVT__vga_inst__DOT__graph_shift_mode;
		// 	if (aiw && !prev_aiw)
		// 		printf("%llu: ATTR-WR reg=0x%02x ff=%d pelw=%d\n",
		// 		       (unsigned long long)cycle, aidx, ff, prev_pelw);
		// 	if (pelw != prev_pelw)
		// 		printf("%llu: >>> attrib_pelclock_div2 %d -> %d\n",
		// 		       (unsigned long long)cycle, prev_pelw, pelw);
		// 	if (gsm != prev_gsm)
		// 		printf("%llu: graph_shift_mode -> %d\n",
		// 		       (unsigned long long)cycle, gsm);
		// 	prev_aiw = aiw; prev_pelw = pelw; prev_gsm = gsm;
		// }

		bool bios_dbg_wr = tb.dbg_uart_we;
		if (bios_dbg_wr && !bios_dbg_wr_prev) {
			uint8_t ch = tb.dbg_uart_byte;
			printf("\033[33m");
			putchar(ch);
			printf("\033[0m");
			fflush(stdout);
		}
		bios_dbg_wr_prev = bios_dbg_wr;

		if (!checkpoint_dir.empty() && checkpoint_interval_sec != 0 &&
		    std::chrono::steady_clock::now() >= next_checkpoint_at) {
			try {
				save_checkpoint(cycle);
			} catch (const std::exception& e) {
				cerr << "checkpoint failed: " << e.what() << "\n";
				running = false;
			}
			next_checkpoint_at = std::chrono::steady_clock::now() +
				std::chrono::seconds(checkpoint_interval_sec);
		}

		if (!g_headless && cycle >= next_gui_poll_cycle) {
			next_gui_poll_cycle = cycle + GUI_POLL_CYCLES;
			uint32_t now = get_ticks_ms();
			SDL_Event e;
			while (SDL_PollEvent(&e)) {
				if (e.type == SDL_QUIT) running = false;
				else if (e.type == SDL_WINDOWEVENT &&
				         e.window.windowID == SDL_GetWindowID(sdl_window)) {
					if (e.window.event == SDL_WINDOWEVENT_CLOSE) {
						running = false;
					} else if (e.window.event == SDL_WINDOWEVENT_FOCUS_LOST && mouse_captured) {
						set_mouse_capture(false);
					} else if (e.window.event == SDL_WINDOWEVENT_EXPOSED ||
					           e.window.event == SDL_WINDOWEVENT_RESIZED ||
					           e.window.event == SDL_WINDOWEVENT_SIZE_CHANGED) {
						present_dirty = true;
					}
				}
				else if (e.type == SDL_KEYDOWN && !e.key.repeat) {
					SDL_Keymod mods = SDL_GetModState();
					bool mouse_release_hotkey =
						mouse_captured &&
						(e.key.keysym.scancode == SDL_SCANCODE_ESCAPE);
					bool trace_hotkey =
						(e.key.keysym.scancode == SDL_SCANCODE_T) &&
						(mods & (KMOD_GUI | KMOD_CTRL));
					bool soft_reset_hotkey =
						(e.key.keysym.scancode == SDL_SCANCODE_R) &&
						(mods & KMOD_GUI);
					bool checkpoint_hotkey =
						(e.key.keysym.scancode == SDL_SCANCODE_C) &&
						(mods & KMOD_GUI);
					if (mouse_release_hotkey) {
						set_mouse_capture(false);
					} else if (trace_hotkey) {
						set_trace(!trace_toggle);
					} else if (soft_reset_hotkey) {
						gui_r_soft_reset_active = true;
						sim_soft_reset_cycles = 8;
						cout << sim_time << ": GUI-R soft reset\n";
					} else if (checkpoint_hotkey) {
						gui_c_checkpoint_active = true;
						if (checkpoint_dir.empty()) checkpoint_dir = "checkpoints";
						try {
							save_checkpoint(cycle);
						} catch (const std::exception& e) {
							cerr << "checkpoint failed: " << e.what() << "\n";
						}
					} else {
						queue_sdl_key(e.key.keysym.sym, true);
					}
				} else if (e.type == SDL_KEYUP) {
					SDL_Keymod mods = SDL_GetModState();
					bool trace_hotkey =
						(e.key.keysym.scancode == SDL_SCANCODE_T) &&
						(mods & (KMOD_GUI | KMOD_CTRL));
					bool soft_reset_release =
						gui_r_soft_reset_active &&
						(e.key.keysym.scancode == SDL_SCANCODE_R);
					bool checkpoint_release =
						gui_c_checkpoint_active &&
						(e.key.keysym.scancode == SDL_SCANCODE_C);
					if (soft_reset_release) {
						gui_r_soft_reset_active = false;
					} else if (checkpoint_release) {
						gui_c_checkpoint_active = false;
					} else if (!trace_hotkey) {
						queue_sdl_key(e.key.keysym.sym, false);
					}
				} else if (e.type == SDL_MOUSEBUTTONDOWN &&
				           e.button.windowID == SDL_GetWindowID(sdl_window)) {
					if (!mouse_captured) set_mouse_capture(true);
					update_mouse_button(ps2_mouse_buttons, e.button.button, true);
					queue_mouse_packet(0, 0, ps2_mouse_buttons);
				} else if (e.type == SDL_MOUSEBUTTONUP && mouse_captured) {
					update_mouse_button(ps2_mouse_buttons, e.button.button, false);
					queue_mouse_packet(0, 0, ps2_mouse_buttons);
				} else if (e.type == SDL_MOUSEMOTION && mouse_captured) {
					if (e.motion.xrel || e.motion.yrel) {
						queue_mouse_packet(e.motion.xrel, -e.motion.yrel, ps2_mouse_buttons);
					}
				}
			}

			if (present_dirty && now - last_render_ms >= 33) {
				static int logical_width = 0;
				static int logical_height = 0;
				if (resolution_x != logical_width || resolution_y != logical_height) {
					SDL_RenderSetLogicalSize(sdl_renderer, resolution_x, resolution_y);
					logical_width = resolution_x;
					logical_height = resolution_y;
				}
				const SDL_Rect src_rect = {0, 0, resolution_x, resolution_y};
				SDL_UpdateTexture(sdl_texture, &src_rect, presentbuffer, H_RES * sizeof(Pixel));
				SDL_RenderClear(sdl_renderer);
				SDL_RenderCopy(sdl_renderer, sdl_texture, &src_rect, nullptr);
				SDL_RenderPresent(sdl_renderer);
				last_render_ms = now;
				present_dirty = false;
			}

			if (now - last_title_ms >= 1000) {
				uint64_t delta_cycles = (sim_time - last_title_sim_time) / 2;
				double elapsed_ms = (double)(now - last_title_ms);
				bool trace_active = trace_toggle && trace_loop_started && current_cycle >= trace_start_cycle;
				char title[192];
				snprintf(title, sizeof(title), "z386 MiSTer - %.2f MHz%s%s",
					delta_cycles / (elapsed_ms * 1000.0),
					trace_active ? " [TRACE]" : "",
					mouse_captured ? " [MOUSE CAPTURED - ESC/GUI-ESC to release]" : "");
				SDL_SetWindowTitle(sdl_window, title);
				last_title_ms = now;
				last_title_sim_time = sim_time;
			}
		}

		uint32_t linear_ip = tb.dbg_cs_base + tb.dbg_eip;
		bool log_eip_now = log_eip_enabled && tb.dbg_cs == log_eip_cs &&
		                    tb.dbg_eip == log_eip_offset;
		if (log_eip_now && !log_eip_prev) {
			cout << sim_time << ": EIP_MARKER " << std::hex << tb.dbg_cs << ":"
			     << tb.dbg_eip << std::dec << "\n";
		}
		log_eip_prev = log_eip_now;
		if (!saw_boot_sector && linear_ip >= 0x7C00 && linear_ip < 0x7E00) {
			saw_boot_sector = true;
			cout << sim_time << ": boot sector execution at " << std::hex
			     << tb.dbg_cs << ":" << tb.dbg_eip
			     << " linear=0x" << linear_ip << std::dec << "\n";
		}
		if (saw_boot_sector && !saw_post_boot_exec &&
		    linear_ip < 0xA0000 &&
		    !(linear_ip >= 0x7C00 && linear_ip < 0x7E00)) {
			saw_post_boot_exec = true;
			cout << sim_time << ": post-boot execution at " << std::hex
			     << tb.dbg_cs << ":" << tb.dbg_eip
			     << " linear=0x" << linear_ip << std::dec << "\n";
		}
		if (saw_boot_sector && linear_ip < 0x100000) {
			uint32_t page = linear_ip >> 12;
			if (page < boot_pages_seen.size() && !boot_pages_seen[page]) {
				boot_pages_seen[page] = true;
				if (boot_page_logs < 32) {
					boot_page_logs++;
					cout << sim_time << ": exec page 0x" << std::hex << page
					     << " CS:EIP=" << tb.dbg_cs << ":" << tb.dbg_eip
					     << " linear=0x" << linear_ip
					     << " PE=" << static_cast<int>(tb.dbg_pe)
					     << std::dec << "\n";
				}
			}
		}

		if (!have_post || tb.dbg_post_code != last_post) {
			if (tb.dbg_post_code != 0) {
				last_post = tb.dbg_post_code;
				have_post = true;
				saw_post = true;
				cout << sim_time << ": POST " << std::hex << static_cast<int>(last_post)
				     << " CS:EIP=" << tb.dbg_cs << ":" << tb.dbg_eip << std::dec << "\n";
			}
		}

		if (tb.active && !saw_first_instruction) {
			saw_first_instruction = true;
			cout << sim_time << ": core active at " << std::hex << tb.dbg_cs << ":" << tb.dbg_eip << std::dec << "\n";
		}
	}

	control_server.stop();
	if (trace) {
		trace->close();
		delete trace;
		trace = nullptr;
	}
	if (wav_writer) {
		delete wav_writer;
		wav_writer = nullptr;
	}
	if (!g_headless && mouse_captured) set_mouse_capture(false);
	if (sdl_texture) SDL_DestroyTexture(sdl_texture);
	if (sdl_renderer) SDL_DestroyRenderer(sdl_renderer);
	if (sdl_window) SDL_DestroyWindow(sdl_window);
	if (!g_headless) SDL_Quit();

	if (!saw_first_instruction || !saw_post || !saw_video_sync) {
		cerr << "wrapper boot milestone not reached"
		     << " first_instruction=" << saw_first_instruction
		     << " post=" << saw_post
		     << " video_sync=" << saw_video_sync << "\n";
		return 2;
	}

	cout << "MiSTer wrapper harness reached POST " << std::hex
	     << static_cast<int>(last_post) << std::dec
	     << " with active video sync";
	if (saw_boot_menu_text) cout << " and boot menu text";
	if (saw_boot_sector) cout << " and boot sector fetch";
	if (saw_post_boot_exec) cout << " and post-boot execution";
	cout << "\n";
	if (saw_post_boot_exec && !saw_boot_menu_text) {
		dump_nonempty_rows(current_text_screen());
	}
	return 0;
}
