set SMIC28_STDCELL_ROOT "/home/public/PDK/SMIC28/STDcell/SCC28NHKCP_HDC35P140_RVT_V0p2"
set SMIC28_LIB_DIR      "${SMIC28_STDCELL_ROOT}/liberty/0.8v"
set SMIC28_SYMBOL_DIR   "${SMIC28_STDCELL_ROOT}/symbol"
set SMIC28_MW_LIB       "${SMIC28_STDCELL_ROOT}/astro/milkyway/scc28nhkcp_hd_1p10m_8ic_1tmc_1mttc_alpa1/scc28nhkcp_hdc35p140_rvt"

set TARGET_DB           "${SMIC28_LIB_DIR}/scc28nhkcp_hdc35p140_rvt_tt_v0p8_25c_basic.db"
set TARGET_LIB_NAME     "scc28nhkcp_hdc35p140_rvt_tt_v0p8_25c_basic"
set SYMBOL_DB           "${SMIC28_SYMBOL_DIR}/scc28nhkcp_hdc35p140_rvt.sdb"

if {![file exists $TARGET_DB]} {
    puts "ERROR: target library not found: $TARGET_DB"
    exit 1
}

if {![info exists search_path]} {
    set search_path ""
}
set search_path [concat $search_path $SMIC28_LIB_DIR $SMIC28_SYMBOL_DIR]

set target_library [list $TARGET_DB]
set synthetic_library "dw_foundation.sldb"
set link_library [concat "*" $target_library $synthetic_library]

if {[file exists $SYMBOL_DB]} {
    set symbol_library [list $SYMBOL_DB]
} else {
    set symbol_library ""
}

set MAX_COND "tt_v0p8_25c"
set MAX_LIB  $TARGET_LIB_NAME
set MIN_COND "tt_v0p8_25c"
set MIN_LIB  $TARGET_LIB_NAME

set TECH_FILE ""
set TLUPLUS_MAP ""
set TLUPLUS_CMAX ""
set TLUPLUS_CMIN ""

if {[file isdirectory $SMIC28_MW_LIB]} {
    set MW_REFERENCE_LIB_DIRS [list $SMIC28_MW_LIB]
} else {
    set MW_REFERENCE_LIB_DIRS ""
}

set MW_DESIGN_LIBRARY "./mw/${TOP}_rtl_LIB"
