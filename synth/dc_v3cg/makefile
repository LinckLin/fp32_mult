# ============================ fp32_mult DC synthesis =========================== #
# Mirrors the newff reference flow: newff/backend/syn/dct/makefile +
# /home/public/eda_script/Frontend_makefile/{dc.tcl,dc_lib.tcl}
SHELL := /bin/bash

TOP = fp32_mult
FILE_LIST = ./inputs/file.list
SCAN = 0
FP_FILE = ./inputs/icc2dct.fp
RETIME ?= 0
CG ?= 1

DC_SHELL ?= $(shell command -v dc_shell-xg-t 2>/dev/null || command -v dc_shell 2>/dev/null || { test -x /home/public/app/synopsys/compat/bin/dc_shell && echo /home/public/app/synopsys/compat/bin/dc_shell; })

# Variables setting for dc scripts (same -x mechanism as reference)
CMD = -x "set TOP $(TOP); \
          set FILE_LIST $(FILE_LIST); \
          set SCAN $(SCAN); \
          set FP_FILE $(FP_FILE); \
          set RETIME $(RETIME); \
          set CG $(CG)"

# DC synthesis (compile_ultra + clock-period sweep, see script/dc_sweep.tcl)
dc:
	@test -n "$(DC_SHELL)" || { echo "ERROR: Cannot find dc_shell-xg-t or dc_shell"; exit 1; }
	@echo "Using DC_SHELL=$(DC_SHELL)"
	@set -o pipefail; $(DC_SHELL) -no_gui $(CMD) -f ./script/dc_sweep.tcl | tee dc.log

# Clean redundant files
clean:
	rm -rf .DC_log* command.log dc.log default.svf *.log MODULE_ALL.v lib \
		   reports/* outputs/* mw worklib crte* *.svf *.html *.log novas.* *.syn *.pvl *.mr \
		   clogBmBmNp *.csh *.ddc
