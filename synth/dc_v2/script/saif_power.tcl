# load compiled design, annotate SAIF switching activity, report power
set TOP fp32_mult
source script/dc_lib.tcl
read_ddc outputs/$TOP.ddc
current_design $TOP
link
read_saif -input $env(SAIF_FILE) -instance_name iv_tb/dut -verbose
report_power -hier -hier_level 2 -analysis_effort medium > reports/power_saif.rpt
exit
