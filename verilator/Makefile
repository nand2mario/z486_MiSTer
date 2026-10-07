VERILATOR = verilator
.DEFAULT_GOAL := all
VERILATOR_BUILD_JOBS ?= 8
SIM_OPT_LEVEL ?= -O2
SIM_CLOCK_HZ ?= 20000000
ENABLE_X87 ?= 1
OBJ_DIR ?= obj_dir
EXTRA_SOURCES ?=
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
VERILATOR_FLAGS = +1800-2017ext+sv --trace-fst --trace-structs --savable --top-module z486_mister_sim --Mdir $(OBJ_DIR) -GCLOCK_RATE_HZ=$(SIM_CLOCK_HZ) -GENABLE_X87=$(ENABLE_X87) --cc --exe $(VERILATOR_X_FLAGS) -CFLAGS "$(SDL_CFLAGS) $(PNG_CFLAGS) $(SIM_OPT_LEVEL) $(SIM_ARCH_FLAGS) -DSIM_SYSTEM_CLOCK_HZ=$(SIM_CLOCK_HZ) -std=c++17 -pthread" -LDFLAGS "$(SDL_LIBS) $(PNG_LIBS) -pthread $(abspath $(COSIM_LIB)) -lm" -Wno-WIDTH -Wno-PINMISSING -Wno-COMBDLY -Wno-TIMESCALEMOD -Wno-IMPLICITSTATIC -Wno-CASEOVERLAP -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-REALCVT -Wno-ASCRANGE -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKANDNBLK -DZ486_ALTERA_ALU=1
VERILATOR_INCLUDE = -I../src -I../src/z486 -I../src/z486/x87

D=../src
DZ=../src/z486

SOURCES = $(EXTRA_SOURCES) \
		  ../z486_mister_sim.sv \
		  $(D)/system.sv \
		  $(DZ)/z486_pkg.sv $(DZ)/ucode_rom.sv $(DZ)/microsequencer.sv $(DZ)/event_control.sv $(DZ)/hardwired_control.sv $(DZ)/data_access.sv $(DZ)/z486.sv \
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
		  $(D)/memory/main_memory.sv $(D)/memory/split_sdram_backend.sv $(DZ)/memory.sv $(DZ)/bus_unit.sv $(DZ)/cache_unit.sv $(DZ)/l1_cache.sv $(DZ)/l1_icache.sv $(D)/memory/sdram_sim.v \
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

CPP_SOURCES = main.cpp ide_hps.cpp control_server.cpp cosim_host.cpp snapshot.cpp

# 86Box CPU core as the --cosim reference (C, built in its own directory from
# an 86Box checkout at $(COSIM_DIR)/86Box). Without the checkout the sim links
# a stub and --cosim reports that the reference is missing.
COSIM_DIR = cosim
COSIM_CPU = $(COSIM_DIR)/86Box/src/cpu
ifneq ($(wildcard $(COSIM_CPU)/x86seg.c),)
COSIM_LIB = $(COSIM_DIR)/libcosim86.a
else
COSIM_LIB = $(COSIM_DIR)/libcosim86_stub.a
$(info No 86Box checkout at $(COSIM_DIR)/86Box: building without --cosim)
endif

ZSST ?= ../src/zsst
VOODOO_SOURCES = \
	$(ZSST)/sst1_pkg.sv \
	$(ZSST)/generated/sst1_regs_pkg.sv \
	$(ZSST)/generated/sst1_tmu_tables_pkg.sv \
	$(ZSST)/frontend/sst1_addr_decode.sv \
	$(ZSST)/frontend/sst1_float_to_fixed.sv \
	$(ZSST)/frontend/sst1_pci_fifo.sv \
	$(ZSST)/frontend/sst1_regfile.sv \
	$(ZSST)/frontend/sst1_frontend.sv \
	$(ZSST)/tmu/sst1_texture_layout.sv \
	$(ZSST)/tmu/sst1_tmu_front_staged.sv \
	$(ZSST)/tmu/sst1_texture_cache_ram.sv \
	$(ZSST)/tmu/sst1_texture_cache.sv \
	$(ZSST)/tmu/sst1_texture_address.sv \
	$(ZSST)/tmu/sst1_texel_decode.sv \
	$(ZSST)/tmu/sst1_texture_combine.sv \
	$(ZSST)/tmu/sst1_tmu.sv \
	$(ZSST)/fbi/sst1_pixel_pipeline.sv \
	$(ZSST)/fbi/sst1_fb_write_combine.sv \
	$(ZSST)/fbi/sst1_fb_read_cache.sv \
	$(ZSST)/fbi/sst1_fbi.sv \
	$(ZSST)/video/sst1_video_control.sv \
	$(ZSST)/sst1_perf_counters.sv \
	$(ZSST)/sst1_core.sv \
	$(ZSST)/sst1_device.sv \
	$(ZSST)/sim/models/sst1_ddr_model.sv \
	../src/voodoo/zsst_pci_config.sv

all: $(OBJ_DIR)/Vz486_mister_sim

$(COSIM_LIB): $(wildcard $(COSIM_DIR)/*.c $(COSIM_DIR)/*.h $(COSIM_CPU)/*.c $(COSIM_CPU)/*.h)
	$(MAKE) -C $(COSIM_DIR) $(notdir $(COSIM_LIB))

$(OBJ_DIR)/Vz486_mister_sim: $(SOURCES) $(CPP_SOURCES) cosim_host.h snapshot.h zfile.h ide_hps.h gen_state_table.py $(COSIM_LIB) ../src/z486/ucode.hex \
		../src/z486/pla_entry_rom.hex ../src/z486/pla_group_entry.hex Makefile
	@# Verilator's own makefile does not see libcosim86.a: relink explicitly.
	rm -f $@
	ln -sf ../src/z486/ucode.hex .
	ln -sf ../src/z486/pla_entry_rom.hex .
	ln -sf ../src/z486/pla_group_entry.hex .
	@# Verilate, list the model's state for portable snapshots, then compile.
	$(VERILATOR) $(VERILATOR_FLAGS) $(VERILATOR_INCLUDE) $(SOURCES) $(CPP_SOURCES) $(abspath $(OBJ_DIR))/state_table.cpp
	python3 gen_state_table.py $(OBJ_DIR) Vz486_mister_sim $(OBJ_DIR)/state_table.cpp
	$(MAKE) -C $(OBJ_DIR) -f Vz486_mister_sim.mk -j $(VERILATOR_BUILD_JOBS) OPT_FAST=$(SIM_OPT_LEVEL) OPT_GLOBAL=$(SIM_OPT_LEVEL)

run: $(OBJ_DIR)/Vz486_mister_sim
	./$(OBJ_DIR)/Vz486_mister_sim --enter-at 10000000

trace: $(OBJ_DIR)/Vz486_mister_sim
	./$(OBJ_DIR)/Vz486_mister_sim --trace

sim85:
	$(MAKE) OBJ_DIR=obj_dir_85 SIM_CLOCK_HZ=85000000 all

x87: all

no_x87:
	$(MAKE) OBJ_DIR=obj_dir_no_x87 ENABLE_X87=0 all

x87-50:
	$(MAKE) OBJ_DIR=obj_dir_x87_50 SIM_CLOCK_HZ=50000000 ENABLE_X87=1 all

# Complete x86 PC plus SST-1 programming/render path. The dedicated object
# directory leaves the normal MiSTer simulator untouched.
voodoo:
	$(MAKE) OBJ_DIR=obj_dir_voodoo \
		VERILATOR_X_FLAGS="$(VERILATOR_X_FLAGS) -DZ486_VOODOO=1" \
		EXTRA_SOURCES="$(VOODOO_SOURCES)" all

clean:
	rm -rf $(OBJ_DIR) obj_dir_trace
	rm -f ucode.hex pla_entry_rom.hex pla_group_entry.hex waveform.fst

.PHONY: all run trace sim85 x87 no_x87 x87-50 voodoo clean
