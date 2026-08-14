#=============================================================================
# fp32_mult gate-level (DC netlist) functional smoke check
#=============================================================================
override VERILATOR := /home/lzl/.local/lib/python3.10/site-packages/verilator/bin/verilator
TOP       := fp32_mult
RTL       := rtl/fp32_mult_net.v rtl/scc28nhkcp_hdc35p140_rvt.v
TB        := tb/fp32_mult_tb.cpp
OBJ       := obj_dir
CXXFLAGS  := -std=c++17 -O2 -frounding-math

.PHONY: all sim lint clean

all: sim

# two-step build: pip-verilator's verilated.mk needs CFG_CXXFLAGS_PCH_I=-include
$(OBJ)/V$(TOP): $(RTL) $(TB)
	$(VERILATOR) --cc --top-module $(TOP) --exe --trace \
	    -Wno-fatal -Wno-UNUSED -Wno-DECLFILENAME -Wno-UNOPTFLAT -Wno-WIDTH \
	    -Wno-IMPLICIT +define+functional \
	    -Irtl -CFLAGS "$(CXXFLAGS)" \
	    --Mdir $(OBJ) -o V$(TOP) $(RTL) $(TB)
	$(MAKE) -C $(OBJ) -f V$(TOP).mk -j 4 CFG_CXXFLAGS_PCH_I=-include

sim: $(OBJ)/V$(TOP) tb/golden.txt
	./$(OBJ)/V$(TOP) $(ARGS)

clean:
	rm -rf $(OBJ) *.vcd
