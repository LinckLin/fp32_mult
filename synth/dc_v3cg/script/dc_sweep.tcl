# =============================================================================
# dc_sweep.tcl : fp32_mult DC synthesis + clock-period sweep (Fmax exploration)
# -----------------------------------------------------------------------------
# Flow is the same as the newff reference flow (/home/public/eda_script/
# Frontend_makefile/dc.tcl driven by newff/backend/syn/dct/makefile):
#   analyze/elaborate -> link -> uniquify -> source SDC -> group_path ->
#   compile_ultra -no_autoungroup (+ -incremental)
# After the first compile the clock period is tightened round by round
# (apply_clk + compile_ultra -incremental) to locate the theoretical Fmax.
# =============================================================================
sh date
sh rm -rf mw
sh mkdir mw
remove_design -all
set OUTPUT      outputs
set REPORTS_DIR reports
sh rm -rf ${OUTPUT}
sh mkdir ${OUTPUT}
sh rm -rf ${REPORTS_DIR}
sh mkdir ${REPORTS_DIR}

###############################################################################
# multi core
###############################################################################
set_host_options -max_cores 4

###############################################################################
# rules (same as reference)
###############################################################################
set enable_page_mode false
set enable_recovery_removal_arcs true
set timing_enable_multiple_clocks_per_reg true
set power_perserve_rtl_hier_names true
set bus_naming_style {%s[%d]}
set hdlin_enable_rtldrc_info true

###############################################################################
# libraries (same as reference)
###############################################################################
source script/dc_lib.tcl

###############################################################################
# svf / html log
###############################################################################
set_svf  $OUTPUT/$TOP.svf
set_app_var html_log_enable true
set_app_var html_log_filename ${TOP}.html

proc add_rtl_search_path {path} {
    global search_path
    set dir [file normalize $path]
    if {![info exists search_path]} {
        set search_path ""
    }
    if {[lsearch -exact $search_path $dir] < 0} {
        set search_path [concat $search_path [list $dir]]
    }
}

proc collect_rtl_from_filelist {filelist} {
    set sources {}
    set fp [open $filelist r]
    while {[gets $fp line] >= 0} {
        set line [string trim $line]
        if {$line eq "" || [string match "#*" $line] || [string match "//*" $line]} {
            continue
        }
        if {[string match "+incdir+*" $line]} {
            add_rtl_search_path [string range $line 8 end]
            continue
        }
        if {[string match "-*" $line]} {
            puts "WARNING: Ignore unsupported filelist option: $line"
            continue
        }
        set path [file normalize $line]
        if {![file exists $path]} {
            puts "ERROR: RTL file not found in $filelist: $line"
            exit 1
        }
        add_rtl_search_path [file dirname $path]
        set ext [string tolower [file extension $path]]
        if {$ext eq ".vh" || $ext eq ".svh"} {
            continue
        }
        if {$ext eq ".v" || $ext eq ".sv"} {
            lappend sources $path
        } else {
            puts "WARNING: Ignore unsupported RTL file extension: $path"
        }
    }
    close $fp
    return $sources
}

###############################################################################
# read RTL (same as reference)
###############################################################################
if {[info exists FILE_LIST] && $FILE_LIST ne "" && [file exists $FILE_LIST]} {
    set RTL_FILES [collect_rtl_from_filelist $FILE_LIST]
    if {[llength $RTL_FILES] == 0} {
        puts "ERROR: No RTL source files found in $FILE_LIST"
        exit 1
    }
    # NOTE: analyzed as sverilog (deviation from reference flow): the RTL uses
    # Verilog-2001 size casts like 8'(...) / 24'(...), which PRESTO's strict
    # "verilog" frontend rejects (VER-720); sverilog mode parses the same
    # V2K-style RTL unchanged.
    set ALL_FILES {}
    foreach rtl_file $RTL_FILES {
        puts "INFO: Analyze RTL: $rtl_file"
        lappend ALL_FILES $rtl_file
    }
    if {[llength $ALL_FILES] > 0} {
        analyze -format sverilog $ALL_FILES
    }
} else {
    puts "WARNING: FILE_LIST is missing; fallback to inputs/${TOP}.v"
    analyze -format sverilog inputs/${TOP}.v
}

elaborate      ${TOP}
current_design ${TOP}
link

###############################################################################
# operating conditions (same as reference)
###############################################################################
if {[info exists MAX_COND] && $MAX_COND ne "" && [info exists MIN_COND] && $MIN_COND ne ""} {
    set_operating_conditions -max $MAX_COND \
                             -max_library $MAX_LIB \
                             -min $MIN_COND \
                             -min_library $MIN_LIB
} else {
    puts "INFO: Operating condition names are not configured; use library defaults."
}

###############################################################################
uniquify

###############################################################################
# naming (same as reference: verilog rules before compile)
###############################################################################
change_names -rules verilog -hierarchy

###############################################################################
define_design_lib worklib -path ./worklib

###############################################################################
# default path groups (same as reference)
###############################################################################
set ports_clock_root [filter_collection [get_attribute [get_clocks] sources] object_class==port]
group_path -name in2out  -weight 2  -from [remove_from_collection [all_inputs] $ports_clock_root] -to [all_outputs]
group_path -name reg2out -weight 3  -from [all_registers -clock_pins] -to [all_outputs]
group_path -name in2reg  -weight 3  -from [remove_from_collection [all_inputs] $ports_clock_root] -to [all_registers -data_pins]
group_path -name reg2reg -weight 5  -from [all_registers -clock_pins] -to [all_registers -data_pins]

###############################################################################
# check design
###############################################################################
check_design > $REPORTS_DIR/chkdesign_$TOP.rpt
check_timing > $REPORTS_DIR/chktiming_$TOP.rpt

###############################################################################
# optimization options (same as reference)
###############################################################################
set_structure true -boolean true -timing true
set_fix_multiple_port_nets -all -buffer_constants
set_cost_priority -delay

###############################################################################
# constraints
###############################################################################
source inputs/${TOP}.func.sdc
source inputs/io.sdc

# re-apply clock + clock-bound constraints for one sweep round
proc apply_clk {p} {
    set clks [get_clocks *]
    if {[sizeof_collection $clks] > 0} { remove_clock $clks }
    create_clock -name clk -period $p [get_ports clk]
    set_clock_uncertainty -setup 0.05 [get_clocks clk]
    set_clock_uncertainty -hold  0.03 [get_clocks clk]
    set_clock_transition 0.05 [get_clocks clk]
    set_input_delay 0.05 -clock [get_clocks clk] [remove_from_collection [all_inputs] [get_ports clk]]
    set_output_delay 0.05 -clock [get_clocks clk] [all_outputs]
}

proc snap_reports {p tag} {
    global TOP REPORTS_DIR
    set fp [open $REPORTS_DIR/sweep_summary.txt a]
    # worst slack across all path groups (one worst path per group)
    set wns_list [get_attribute [get_timing_paths -delay_type max -nworst 1] slack]
    set wns [lindex [lsort -real $wns_list] 0]
    set area [get_attribute [current_design] area]
    puts $fp "PERIOD $p  WNS $wns  AREA $area"
    close $fp
    report_qor        >  $REPORTS_DIR/qor_${tag}.rpt
    report_timing -delay max -sort_by slack -path full -nworst 5 -max_paths 30 > $REPORTS_DIR/timing_${tag}.rpt
    report_timing -delay max -path_type end -sort_by slack -max_paths 300 > $REPORTS_DIR/endpoints_${tag}.rpt
    report_area -hier >  $REPORTS_DIR/area_${tag}.rpt
    if {$tag == "p1000"} {
        report_power -hier -hier_level 2 -analysis_effort medium > $REPORTS_DIR/power_${tag}.rpt
    }
    return $wns
}

###############################################################################
# optional register retiming (experiment: auto-rebalance the 5 stages)
###############################################################################
if {[info exists RETIME] && $RETIME == 1} {
    set_optimize_registers true
    puts "INFO: register retiming ENABLED"
}

# optional clock gating (power experiment)
if {[info exists CG] && $CG == 1} {
    set_clock_gating_style -sequential_cell latch -positive_edge_logic {integrated} -minimum_bitwidth 3
    set_power_cg_all_registers true
    puts "INFO: clock gating ENABLED"
}

###############################################################################
# initial compile at the SDC period (1.0 ns)
###############################################################################
compile_ultra -no_autoungroup
set wns0 [snap_reports 1.00 "p1000"]

# CG experiment: power-focused run, skip the Fmax sweep
if {[info exists CG] && $CG == 1} {
    report_power -hier -hier_level 2 -analysis_effort medium > $REPORTS_DIR/power_cg.rpt
    set svf -off
    exit
}

###############################################################################
# clock sweep: tighten period round by round, stop when WNS < -0.5 ns
###############################################################################
set periods {0.80 0.65 0.55 0.48 0.42 0.38 0.34 0.30 0.27 0.25}
foreach p $periods {
    set tag "p[regsub -all {\.} $p {}]"
    apply_clk $p
    compile_ultra -no_autoungroup -incremental
    set wns [snap_reports $p $tag]
    if {$wns < -0.5} {
        puts "SWEEP STOP: period $p WNS $wns"
        break
    }
}

###############################################################################
# final netlist / reports at the last (tightest passing) period
###############################################################################
set verilogout_no_tri TRUE
define_name_rules cds_rules -allowed "A-Z a-z 0-9 _"
change_names -rules cds_rules
change_names -rules verilog -verbose -hierarchy
write -f ddc -hierarchy     -output $OUTPUT/$TOP.ddc
write -f verilog -hierarchy -output $OUTPUT/$TOP.v
write_sdc  -version latest          $OUTPUT/$TOP.func.sdc
write_sdf                           $OUTPUT/$TOP.sdf
write_script -output                $OUTPUT/$TOP.tcl

report_resource -hierarchy > $OUTPUT/$TOP.res
report_constraint -all_violators -max_transition -max_capacitance -max_fanout -max_area > $REPORTS_DIR/all_vios_$TOP.rpt
report_timing -delay max -sort_by slack -path full -nworst 10 -max_paths 100 > $REPORTS_DIR/timing_final_$TOP.rpt
report_timing -delay min -sort_by slack -path full -nworst 10 -max_paths 100 >> $REPORTS_DIR/timing_final_$TOP.rpt
report_power -hier -hier_level 2 -verbose -analysis_effort medium > $REPORTS_DIR/power_$TOP.rpt

set svf -off
exit
