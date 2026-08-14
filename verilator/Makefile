VERILATOR = verilator
VERILATOR_BUILD_JOBS ?= 8
SIM_OPT_LEVEL ?= -O2
SIM_CLOCK_HZ ?= 20000000
ENABLE_X87 ?= 0
OBJ_DIR ?= obj_dir
ifeq ($(shell uname -s),Darwin)
SIM_ARCH_FLAGS ?= -mcpu=native
else
SIM_ARCH_FLAGS ?= -march=native
endif
SDL_CFLAGS=$(shell sdl2-config --cflags)
SDL_LIBS=$(shell sdl2-config --libs)
PNG_CFLAGS=$(shell pkg-config --cflags libpng)
PNG_LIBS=$(shell pkg-config --libs libpng)
VERILATOR_X_FLAGS ?=
VERILATOR_FLAGS = +1800-2017ext+sv --trace-fst --trace-structs --savable --top-module z486_mister_sim --Mdir $(OBJ_DIR) -GCLOCK_RATE_HZ=$(SIM_CLOCK_HZ) -GENABLE_X87=$(ENABLE_X87) --cc --exe --build -j $(VERILATOR_BUILD_JOBS) $(VERILATOR_X_FLAGS) -CFLAGS "$(SDL_CFLAGS) $(PNG_CFLAGS) $(SIM_OPT_LEVEL) $(SIM_ARCH_FLAGS) -DSIM_SYSTEM_CLOCK_HZ=$(SIM_CLOCK_HZ) -std=c++17 -pthread" -LDFLAGS "$(SDL_LIBS) $(PNG_LIBS) -pthread" -MAKEFLAGS "OPT_FAST=$(SIM_OPT_LEVEL) OPT_GLOBAL=$(SIM_OPT_LEVEL)" -Wno-WIDTH -Wno-PINMISSING -Wno-COMBDLY -Wno-TIMESCALEMOD -Wno-IMPLICITSTATIC -Wno-CASEOVERLAP -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-REALCVT -Wno-ASCRANGE -Wno-MULTIDRIVEN -Wno-LATCH -DZ486_ALTERA_ALU=1
VERILATOR_INCLUDE = -I../src -I../src/z486 -I../src/z486/x87

D=../src
DZ=../src/z486

SOURCES = ../z486_mister_sim.sv \
		  $(D)/system.sv \
		  $(DZ)/z486_pkg.sv $(DZ)/ucode_rom.sv $(DZ)/microsequencer.sv $(DZ)/hardwired_control.sv $(DZ)/z486.sv \
		  $(DZ)/cpu_throttle.sv $(DZ)/interrupt_controller.sv \
		  $(DZ)/data_unit.sv $(DZ)/address_unit.sv $(DZ)/shifter.sv $(DZ)/mul_div.sv $(DZ)/decoder.sv \
		  $(DZ)/alu.sv $(DZ)/alu_alt.sv $(DZ)/prefetch.sv $(DZ)/segmentation_unit.sv \
		  $(DZ)/paging_unit.sv $(DZ)/paging_tlb.sv $(DZ)/paging_walker.sv \
		  $(DZ)/x87/x87_pkg.sv $(DZ)/x87/x87_ucode_pkg.sv \
		  $(DZ)/x87/x87_bridge.sv $(DZ)/x87/x87_cordic_rom.sv \
		  $(DZ)/x87/x87_cordic_scratch.sv \
		  $(DZ)/x87/x87_ucode_rom.sv \
		  $(DZ)/x87/x87_sequencer.sv $(DZ)/x87/x87_executor.sv \
		  $(DZ)/x87/x87_transfer_fifo.sv $(DZ)/x87/x87_stack_mem.sv \
		  $(DZ)/x87/x87_command_rom.sv \
		  $(DZ)/x87/x87_control.sv $(DZ)/x87/x87_unit.sv \
		  $(DZ)/dsp_mul.sv $(DZ)/protection.sv \
		  $(D)/iobus_adapter.sv $(D)/pic_inta_bridge.sv \
		  $(D)/memory/main_memory.sv $(DZ)/memory.sv $(DZ)/l1_cache.sv $(DZ)/l1_icache.sv $(D)/memory/sdram_sim.v \
		  $(D)/soc/dma.v $(D)/soc/cdda.v $(D)/soc/floppy.v $(D)/soc/ide.v $(D)/soc/pic.v $(D)/soc/pit_counter.v $(D)/soc/joystick.v \
		  $(D)/soc/pit.v $(D)/soc/ps2.v $(D)/soc/rtc.v $(D)/soc/vga.v \
		  $(D)/common/dpram.v $(D)/common/simple_ram.v $(D)/common/simple_fifo.v $(D)/common/async_fifo.v \
		  $(D)/common/ps2_device.v $(D)/common/simple_mult.v $(D)/common/uart_tx_V2.v $(D)/common/synchronizer.sv \
		  $(D)/common/cdc_vector_handshake_continuous.sv \
		  $(D)/soc/sound/sound.v $(D)/soc/sound/sound_dsp.v $(D)/soc/sound/saa1099.sv \
		  $(D)/soc/sound/opl3/afifo.v $(D)/soc/sound/opl3/opl3_pkg.sv \
		  $(D)/soc/sound/opl3/phase_generator.sv $(D)/soc/sound/opl3/mem_simple_dual_port.sv $(D)/soc/sound/opl3/calc_envelope_shift.sv \
		  $(D)/soc/sound/opl3/operator.sv $(D)/soc/sound/opl3/calc_phase_inc.sv $(D)/soc/sound/opl3/opl3_exp_lut.sv \
		  $(D)/soc/sound/opl3/calc_rhythm_phase.sv $(D)/soc/sound/opl3/opl3_log_sine_lut.sv $(D)/soc/sound/opl3/channels.sv \
		  $(D)/soc/sound/opl3/clk_div.sv $(D)/soc/sound/opl3/control_operators.sv $(D)/soc/sound/opl3/dac_prep.sv \
		  $(D)/soc/sound/opl3/edge_detector.sv $(D)/soc/sound/opl3/envelope_generator.sv $(D)/soc/sound/opl3/host_if.sv \
		  $(D)/soc/sound/opl3/ksl_add_rom.sv $(D)/soc/sound/opl3/leds.sv $(D)/soc/sound/opl3/mem_multi_bank_reset.sv \
		  $(D)/soc/sound/opl3/mem_multi_bank.sv $(D)/soc/sound/opl3/mem_simple_dual_port_async_read.sv \
		  $(D)/soc/sound/opl3/pipeline_sr.sv $(D)/soc/sound/opl3/reset_sync.sv $(D)/soc/sound/opl3/timer.sv \
		  $(D)/soc/sound/opl3/timers.sv $(D)/soc/sound/opl3/tremolo.sv $(D)/soc/sound/opl3/trick_sw_detection.sv \
		  $(D)/soc/sound/opl3/vibrato.sv $(D)/soc/sound/opl3/opl3.sv

CPP_SOURCES = main.cpp ide_hps.cpp control_server.cpp

all: $(OBJ_DIR)/Vz486_mister_sim

$(OBJ_DIR)/Vz486_mister_sim: $(SOURCES) $(CPP_SOURCES) ../src/z486/ucode.hex
	ln -sf ../src/z486/ucode.hex .
	$(VERILATOR) $(VERILATOR_FLAGS) $(VERILATOR_INCLUDE) $(SOURCES) $(CPP_SOURCES)

run: $(OBJ_DIR)/Vz486_mister_sim
	./$(OBJ_DIR)/Vz486_mister_sim --enter-at 10000000

trace: $(OBJ_DIR)/Vz486_mister_sim
	./$(OBJ_DIR)/Vz486_mister_sim --trace

sim85:
	$(MAKE) OBJ_DIR=obj_dir_85 SIM_CLOCK_HZ=85000000 all

x87:
	$(MAKE) OBJ_DIR=obj_dir_x87 ENABLE_X87=1 all

x87-50:
	$(MAKE) OBJ_DIR=obj_dir_x87_50 SIM_CLOCK_HZ=50000000 ENABLE_X87=1 all

clean:
	rm -rf $(OBJ_DIR) obj_dir_trace
	rm -f ucode.hex waveform.fst

.PHONY: all run trace sim85 x87 x87-50 clean
