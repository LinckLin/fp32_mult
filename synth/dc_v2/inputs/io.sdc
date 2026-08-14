# IO constraints (reference: newff/backend/sdc/io.sdc)
set_max_area 1000000

set input_transition 0.1
set output_load 0.05

set_input_transition $input_transition [remove_from_collection [all_inputs] [get_ports clk]]
set_load $output_load [all_outputs]
set_max_transition 0.4 [current_design]
set_max_fanout 32 [current_design]
