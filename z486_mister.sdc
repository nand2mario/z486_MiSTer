derive_pll_clocks
derive_clock_uncertainty

# Reset/control-release paths are intentionally asynchronous.
# Cut them so TimeQuest reports real datapaths.
set_false_path -from [get_registers {*cpu_reset_n*}]
set_false_path -from [get_registers {*reset_sync_r*}]
set_false_path -from [get_registers {*boot_done*}]

# The segmentation adder (seg_linear) reaches the early-read accept
# (early_rd_present) only through the mem_linear_addr mux's complex/microcode
# leg, but early_rd_present requires the NON-complex demand leg (linear_early).
# Those are mutually exclusive (complex vs !complex), so seg_linear ->
# early_rd_present is a false path -- yet it otherwise dominates the worst
# cones across most sweep seeds.  Cut it so STA ranks on real datapaths.
set_false_path -through [get_nets {*seg_unit|Add0*}] \
               -through [get_nets {*early_rd_present*}]
