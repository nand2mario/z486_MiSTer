VERILATOR ?= verilator
OBJ_DIR := obj_dir

.PHONY: test clean

.PHONY: test-misterfs
test-misterfs: $(OBJ_DIR)/Vtb_misterfs_mailbox
	./$(OBJ_DIR)/Vtb_misterfs_mailbox

test: test-misterfs

$(OBJ_DIR)/Vtb_misterfs_mailbox: tb_main_memory_svga.sv ../src/memory/main_memory.sv | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/misterfs_mailbox \
		--top-module tb_main_memory_svga -GENABLE_SHARED_MAILBOX=1 $^ -o ../Vtb_misterfs_mailbox

.PHONY: test-uart
test-uart: $(OBJ_DIR)/Vtb_uart16550
	./$(OBJ_DIR)/Vtb_uart16550

test: test-uart

$(OBJ_DIR)/Vtb_uart16550: tb_uart16550.sv ../src/soc/uart16550.sv | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/uart16550 		--top-module tb_uart16550 $^ -o ../Vtb_uart16550

.PHONY: test-speed
test-speed: $(OBJ_DIR)/Vtb_cpu_throttle $(OBJ_DIR)/Vtb_sysctl_io
	./$(OBJ_DIR)/Vtb_cpu_throttle
	./$(OBJ_DIR)/Vtb_sysctl_io

test: test-speed

$(OBJ_DIR)/Vtb_cpu_throttle: tb_cpu_throttle.sv ../src/z486/cpu_throttle.sv | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/cpu_throttle \
		--top-module tb_cpu_throttle $^ -o ../Vtb_cpu_throttle

$(OBJ_DIR)/Vtb_sysctl_io: tb_sysctl_io.sv ../src/iobus_adapter.sv ../src/soc/sysctl.sv | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/sysctl_io \
		--top-module tb_sysctl_io $^ -o ../Vtb_sysctl_io

$(OBJ_DIR)/sysctl_probe.img: programs/sysctl_probe.asm | $(OBJ_DIR)
	nasm -f bin $< -o $@

test: $(OBJ_DIR)/Vtb_iobus_adapter $(OBJ_DIR)/Vtb_floppy_io $(OBJ_DIR)/Vtb_pit_io $(OBJ_DIR)/Vtb_rtc_ram_size $(OBJ_DIR)/Vtb_sdram_size $(OBJ_DIR)/Vtb_sdram_partial $(OBJ_DIR)/Vtb_main_memory_svga $(OBJ_DIR)/Vtb_vga_fb_dimensions $(OBJ_DIR)/Vtb_vga_ondemand_mode13 $(OBJ_DIR)/Vtb_vga_dword_write $(OBJ_DIR)/Vtb_vga_plane_ram $(OBJ_DIR)/Vtb_mt32pi
	./$(OBJ_DIR)/Vtb_opl_host_if
	./$(OBJ_DIR)/Vtb_opl3_sbpro
	./$(OBJ_DIR)/Vtb_sdram_dma_hw
	./$(OBJ_DIR)/Vtb_sdram_dma_sim
	./$(OBJ_DIR)/Vtb_iobus_adapter
	./$(OBJ_DIR)/Vtb_floppy_io
	./$(OBJ_DIR)/Vtb_pit_io
	./$(OBJ_DIR)/Vtb_rtc_ram_size
	./$(OBJ_DIR)/Vtb_sdram_size
	./$(OBJ_DIR)/Vtb_sdram_partial
	./$(OBJ_DIR)/Vtb_main_memory_svga
	./$(OBJ_DIR)/Vtb_vga_fb_dimensions
	./$(OBJ_DIR)/Vtb_vga_ondemand_mode13
	./$(OBJ_DIR)/Vtb_vga_dword_write
	./$(OBJ_DIR)/Vtb_vga_plane_ram
	./$(OBJ_DIR)/Vtb_mt32pi

test: $(OBJ_DIR)/Vtb_opl_host_if $(OBJ_DIR)/Vtb_opl3_sbpro

test: $(OBJ_DIR)/Vtb_sdram_dma_hw $(OBJ_DIR)/Vtb_sdram_dma_sim

.PHONY: test-sdram-dma
test-sdram-dma: $(OBJ_DIR)/Vtb_sdram_dma_hw $(OBJ_DIR)/Vtb_sdram_dma_sim
	./$(OBJ_DIR)/Vtb_sdram_dma_hw
	./$(OBJ_DIR)/Vtb_sdram_dma_sim

$(OBJ_DIR)/Vtb_sdram_dma_hw: tb_sdram_dma_priority.sv ../src/memory/sdram.v | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/sdram_dma_hw \
		--top-module tb_sdram_dma_priority $^ -o ../Vtb_sdram_dma_hw

$(OBJ_DIR)/Vtb_sdram_dma_sim: tb_sdram_dma_priority.sv ../src/memory/sdram_sim.v | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/sdram_dma_sim \
		--top-module tb_sdram_dma_priority $^ -o ../Vtb_sdram_dma_sim

OPL_DIR := ../src/soc/sound/opl3
OPL_SOURCES := $(OPL_DIR)/opl3_pkg.sv $(filter-out $(OPL_DIR)/opl3_pkg.sv,$(wildcard $(OPL_DIR)/*.sv)) $(OPL_DIR)/afifo.v ../src/common/synchronizer.sv

$(OBJ_DIR)/Vtb_opl3_sbpro: tb_opl3_sbpro.sv $(OPL_SOURCES) | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/opl3_sbpro \
		--top-module tb_opl3_sbpro $(OPL_SOURCES) $< -o ../Vtb_opl3_sbpro

$(OBJ_DIR)/Vtb_opl_host_if: ../src/soc/sound/opl3/opl3_pkg.sv tb_opl_host_if.sv ../src/soc/sound/opl3/host_if.sv ../src/soc/sound/opl3/trick_sw_detection.sv ../src/soc/sound/opl3/afifo.v ../src/common/synchronizer.sv | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/opl_host_if \
		--top-module tb_opl_host_if $^ -o ../Vtb_opl_host_if

$(OBJ_DIR)/Vtb_mt32pi: tb_mt32pi.sv ../sys/mt32pi.sv | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/mt32pi \
		--top-module tb_mt32pi $^ -o ../Vtb_mt32pi

$(OBJ_DIR)/Vtb_floppy_io: tb_floppy_io.sv ../src/iobus_adapter.sv ../src/soc/floppy.v ../src/common/simple_fifo.v | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/floppy_io \
		--top-module tb_floppy_io $^ -o ../Vtb_floppy_io

$(OBJ_DIR)/Vtb_vga_fb_dimensions: tb_vga_fb_dimensions.sv ../src/soc/vga.v ../src/common/dpram.v | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/vga_fb_dimensions \
		--top-module tb_vga_fb_dimensions $^ -o ../Vtb_vga_fb_dimensions

$(OBJ_DIR)/Vtb_vga_dword_write: tb_vga_dword_write.sv ../src/soc/vga.v ../src/common/dpram.v | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/vga_dword_write \
		--top-module tb_vga_dword_write $^ -o ../Vtb_vga_dword_write

$(OBJ_DIR)/Vtb_vga_ondemand_mode13: tb_vga_ondemand_mode13.sv ../src/soc/vga.v ../src/common/dpram.v | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/vga_ondemand_mode13 \
		--top-module tb_vga_ondemand_mode13 $^ -o ../Vtb_vga_ondemand_mode13

$(OBJ_DIR)/Vtb_vga_plane_ram: tb_vga_plane_ram.sv ../src/soc/vga.v ../src/common/dpram.v | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/vga_plane_ram \
		--top-module tb_vga_plane_ram $^ -o ../Vtb_vga_plane_ram

$(OBJ_DIR):
	mkdir -p $@

$(OBJ_DIR)/Vtb_main_memory_svga: tb_main_memory_svga.sv ../src/memory/main_memory.sv | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/main_memory_svga \
		--top-module tb_main_memory_svga $^ -o ../Vtb_main_memory_svga

$(OBJ_DIR)/Vtb_pit_io: tb_pit_io.sv ../src/iobus_adapter.sv ../src/soc/pit.v ../src/soc/pit_counter.v | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/pit \
		--top-module tb_pit_io $^ -o ../Vtb_pit_io

$(OBJ_DIR)/Vtb_iobus_adapter: tb_iobus_adapter.sv ../src/iobus_adapter.sv | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/iobus \
		--top-module tb_iobus_adapter $^ -o ../Vtb_iobus_adapter

$(OBJ_DIR)/Vtb_rtc_ram_size: tb_rtc_ram_size.sv ../src/soc/rtc.v ../src/common/simple_ram.v | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR) \
		--top-module tb_rtc_ram_size $^ -o Vtb_rtc_ram_size

$(OBJ_DIR)/Vtb_sdram_partial: tb_sdram_partial.sv ../src/memory/sdram.v | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/sdram_partial \
		--top-module tb_sdram_partial $^ -o ../Vtb_sdram_partial

$(OBJ_DIR)/Vtb_sdram_size: tb_sdram_size.sv ../src/memory/sdram.v | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/sdram \
		--top-module tb_sdram_size $^ -o ../Vtb_sdram_size

clean:
	rm -rf $(OBJ_DIR)

.PHONY: test-ne2000
test-ne2000: $(OBJ_DIR)/Vtb_ne2000
	./$(OBJ_DIR)/Vtb_ne2000

test: test-ne2000

$(OBJ_DIR)/Vtb_ne2000: tb_ne2000.sv ../src/soc/ne2000.sv ../src/common/dpram.v | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/ne2000 		--top-module tb_ne2000 $^ -o ../Vtb_ne2000
