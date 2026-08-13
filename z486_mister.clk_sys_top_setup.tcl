project_open z486_mister -revision z486_mister
create_timing_netlist
read_sdc
update_timing_netlist
set clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
report_timing -setup -from_clock $clk -to_clock $clk -npaths 80 -detail full_path -file output_files/z486_mister.clk_sys_top_setup.rpt -panel_name {clk_sys Top Setup Paths}
project_close
