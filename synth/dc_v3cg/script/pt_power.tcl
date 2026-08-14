# =============================================================================
# pt_power.tcl : PrimeTime PX gate-level power analysis
#   usage: export SYNOPSYS_LC_ROOT=/home/public/app/synopsys/lc/O-2018.06-SP1
#          SAIF_FILE=<path> pt_shell -no_init -f script/pt_power.tcl
#   - reads the DC gate netlist (outputs/fp32_mult.v) + SMIC28 liberty
#   - reads the DC-written SDC, then re-constrains the clock to 1.0 ns
#   - annotates VCS switching activity (SAIF) and reports average power
# =============================================================================
set TOP fp32_mult
set power_enable_analysis true

# PrimeTime needs the Library Compiler to read .db (PT-063)
set library_compiler_executable /home/public/app/synopsys/compat/bin/lc_shell

set SMIC28_LIB_ROOT "/home/public/PDK/SMIC28/STDcell/SCC28NHKCP_HDC35P140_RVT_V0p2"
set DB              "${SMIC28_LIB_ROOT}/liberty/0.8v/scc28nhkcp_hdc35p140_rvt_tt_v0p8_25c_basic.db"

if {![file exists $DB]} {
    puts "ERROR: liberty not found: $DB"
    exit 1
}

set search_path   [list . inputs script]
set link_library  [list * $DB]
set target_library [list $DB]

read_verilog outputs/${TOP}.v
link_design ${TOP}

# constraints: take the DC SDC but normalize the clock period to 1.0 ns
if {[file exists outputs/${TOP}.func.sdc]} {
    read_sdc outputs/${TOP}.func.sdc
}
set clks [get_clocks *]
if {[sizeof_collection $clks] > 0} { remove_clock $clks }
create_clock -name clk -period 1.0 [get_ports clk]

# operating condition
set_operating_conditions tt_v0p8_25c

# switching activity (VCS SAIF, scope iv_tb/dut)
read_saif $env(SAIF_FILE) -strip_path iv_tb/dut

check_power > reports/pt_checkpower.rpt
update_power
report_power -hierarchy -levels 2 > reports/pt_power.rpt
report_power -nosplit > reports/pt_power_nosplit.rpt
report_switching_activity -list_not_annotated > reports/pt_unannotated.rpt

exit
