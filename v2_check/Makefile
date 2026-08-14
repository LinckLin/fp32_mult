#=============================================================================
# fp32_mult 6-stage (S3-split) variant functional check against golden oracles
#=============================================================================
VERILATOR ?= verilator
TOP       := fp32_mult
RTL       := rtl/fp32_mult.v rtl/fp32_rnd_inc.v
DEFS      := rtl/fp32_defs.vh
TB        := tb/fp32_mult_tb.cpp
OBJ       := obj_dir
CXXFLAGS  := -std=c++17 -O2 -frounding-math

.PHONY: all sim lint clean

all: sim

$(OBJ)/V$(TOP): $(RTL) $(DEFS) $(TB)
	$(VERILATOR) --cc --build --top-module $(TOP) --exe --trace \
	    -Wall -Wno-fatal -Irtl -CFLAGS "$(CXXFLAGS)" \
	    --Mdir $(OBJ) -o V$(TOP) $(RTL) $(TB)

tb/golden.txt: tb/gen_golden.py
	python3 tb/gen_golden.py

sim: $(OBJ)/V$(TOP) tb/golden.txt
	./$(OBJ)/V$(TOP) $(ARGS)

lint:
	$(VERILATOR) --lint-only -Wall -Wno-fatal -Irtl $(RTL)

clean:
	rm -rf $(OBJ) *.vcd
