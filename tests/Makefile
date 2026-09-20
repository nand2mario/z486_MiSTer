VERILATOR ?= verilator
OBJ_DIR := obj_dir

.PHONY: test clean

test: $(OBJ_DIR)/Vtb_iobus_adapter $(OBJ_DIR)/Vtb_pit_io $(OBJ_DIR)/Vtb_rtc_ram_size $(OBJ_DIR)/Vtb_sdram_size $(OBJ_DIR)/Vtb_main_memory_svga $(OBJ_DIR)/Vtb_vga_fb_mode_gate $(OBJ_DIR)/Vtb_vga_seq_index $(OBJ_DIR)/Vtb_vga_bank_outputs $(OBJ_DIR)/Vtb_vga_fb_dimensions $(OBJ_DIR)/Vtb_vga_ondemand_mode13 $(OBJ_DIR)/Vtb_vga_plane_ram $(OBJ_DIR)/Vtb_mt32pi
	./$(OBJ_DIR)/Vtb_iobus_adapter
	./$(OBJ_DIR)/Vtb_pit_io
	./$(OBJ_DIR)/Vtb_rtc_ram_size
	./$(OBJ_DIR)/Vtb_sdram_size
	./$(OBJ_DIR)/Vtb_main_memory_svga
	./$(OBJ_DIR)/Vtb_vga_fb_mode_gate
	./$(OBJ_DIR)/Vtb_vga_seq_index
	./$(OBJ_DIR)/Vtb_vga_bank_outputs
	./$(OBJ_DIR)/Vtb_vga_fb_dimensions
	./$(OBJ_DIR)/Vtb_vga_ondemand_mode13
	./$(OBJ_DIR)/Vtb_vga_plane_ram
	./$(OBJ_DIR)/Vtb_mt32pi

$(OBJ_DIR)/Vtb_mt32pi: tb_mt32pi.sv ../sys/mt32pi.sv | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/mt32pi \
		--top-module tb_mt32pi $^ -o ../Vtb_mt32pi

$(OBJ_DIR)/Vtb_vga_fb_mode_gate: tb_vga_fb_mode_gate.sv ../src/soc/vga.v ../src/common/dpram.v | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/vga_fb_mode_gate \
		--top-module tb_vga_fb_mode_gate $^ -o ../Vtb_vga_fb_mode_gate

$(OBJ_DIR)/Vtb_vga_seq_index: tb_vga_seq_index.sv ../src/soc/vga.v ../src/common/dpram.v | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/vga_seq_index \
		--top-module tb_vga_seq_index $^ -o ../Vtb_vga_seq_index

$(OBJ_DIR)/Vtb_vga_bank_outputs: tb_vga_bank_outputs.sv ../src/soc/vga.v ../src/common/dpram.v | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/vga_bank_outputs \
		--top-module tb_vga_bank_outputs $^ -o ../Vtb_vga_bank_outputs

$(OBJ_DIR)/Vtb_vga_fb_dimensions: tb_vga_fb_dimensions.sv ../src/soc/vga.v ../src/common/dpram.v | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/vga_fb_dimensions \
		--top-module tb_vga_fb_dimensions $^ -o ../Vtb_vga_fb_dimensions

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

$(OBJ_DIR)/Vtb_sdram_size: tb_sdram_size.sv ../src/memory/sdram.v | $(OBJ_DIR)
	$(VERILATOR) --binary --timing -Wno-fatal --Mdir $(OBJ_DIR)/sdram \
		--top-module tb_sdram_size $^ -o ../Vtb_sdram_size

clean:
	rm -rf $(OBJ_DIR)
