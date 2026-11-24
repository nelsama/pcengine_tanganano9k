create_clock -name clk27    -period 37.037 -waveform {0 18.518} [get_ports {clk27}]
create_clock -name memclk   -period 11.574 -waveform {0 5.787}     [get_nets {memclk}]
create_clock -name memclk_p -period 11.574 -waveform {2.894 8.681} [get_nets {memclk_p}]
create_clock -name clk      -period 46.296 -waveform {0 23.148}    [get_nets {clk}]
set_clock_groups -asynchronous -group [get_clocks {clk27}] -group [get_clocks {memclk memclk_p clk}]
set_false_path -from [get_ports {btn_s1_n}]
// the CPU registers change only with ce, every 3 clk or more
set_multicycle_path -from [get_regs {u_c/u_huc/*}] -to [get_regs {u_c/u_huc/*}] -setup -end 3
set_multicycle_path -from [get_regs {u_c/u_huc/*}] -to [get_regs {u_c/u_huc/*}] -hold -end 2
