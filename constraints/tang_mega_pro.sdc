create_clock -name board_clk -period 20 [get_ports {clk}]
create_generated_clock -name ddr_ref_clk -source [get_ports {clk}] -master_clock board_clk -divide_by 25 -multiply_by 32 [get_pins {memory/reference_pll/PLL_inst/CLKOUT0}]
create_generated_clock -name memory_clk -source [get_pins {memory/reference_pll/PLL_inst/CLKOUT0}] -master_clock ddr_ref_clk -divide_by 1 -multiply_by 5 [get_pins {memory/Gowin_PLL_inst/PLL_inst/CLKOUT2}]
create_generated_clock -name ui_clk -source [get_pins {memory/Gowin_PLL_inst/PLL_inst/CLKOUT2}] -master_clock memory_clk -divide_by 4 -multiply_by 1 [get_pins {memory/u_ddr3/gw3_top/u_ddr_phy_top/fclkdiv/CLKOUT}]
create_clock -name jtag_clk -period 1000 [get_ports {tck_pad_i}]
# The DDR PHY crosses these clocks through FIFOs and controls held during calibration.
# Clock groups follow Sipeed's Hynix_400MHz reference constraints.
set_clock_groups -asynchronous -group [get_clocks {board_clk ddr_ref_clk}] -group [get_clocks {memory_clk}] -group [get_clocks {ui_clk}]
set_clock_groups -asynchronous -group [get_clocks {jtag_clk}] -group [get_clocks {board_clk ddr_ref_clk memory_clk ui_clk}]
# Exclude the external reset path into the reset synchronizers and DDR IP.
set_false_path -from [get_ports {rst_n}]
# Report the clock-crossing exceptions applied by the tools.
report_exceptions -setup -max_paths 100
report_exceptions -hold -max_paths 100
