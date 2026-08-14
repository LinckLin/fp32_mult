# Functional constraints for fp32_mult (reference: newff/backend/sdc/topfile.func.sdc)
# Initial clock period 1.0ns; the sweep in dc_sweep.tcl overrides it per round.
set_max_fanout 32 [current_design]
set_max_transition 0.4 [current_design]

create_clock -name clk -period 1.0 [get_ports clk]

set_clock_uncertainty -setup 0.05 [get_clocks clk]
set_clock_uncertainty -hold  0.03 [get_clocks clk]
set_clock_transition 0.05 [get_clocks clk]

# small I/O budgets so reg2reg datapath limits Fmax
set_input_delay 0.05 -clock [get_clocks clk] [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 0.05 -clock [get_clocks clk] [all_outputs]

set_false_path -from [get_ports rst_n]
set_dont_touch_network [get_ports rst_n]
