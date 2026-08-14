# load compiled design, annotate SAIF switching activity, report power
set TOP fp32_mult
source script/dc_lib.tcl
read_ddc outputs/$TOP.ddc
current_design $TOP
link
read_saif $env(SAIF_FILE) -strip_path "iv_tb/dut" -verbose
report_power -hier -hier_level 2 -analysis_effort medium > reports/power_saif.rpt
exit
