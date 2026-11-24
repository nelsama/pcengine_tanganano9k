#!/usr/bin/env bash
# sim/run_psram.sh : psram_burst + psram_tester against the HyperRAM model
set -euo pipefail
export PATH=/c/msys64/ucrt64/bin:$PATH
cd "$(dirname "$0")/.."; B=build/sim_psram; mkdir -p $B
F="--std=08 -frelaxed --workdir=$B"
for s in sim/gowin_ddr.vhd sim/hyperram_model.vhd src/memory/psram_burst.vhd test/psram/psram_tester.vhd sim/tb_psram.vhd; do ghdl -a $F $s; done
ghdl -e $F -o $B/tb.exe tb_psram
run() { echo "== $*"; $B/tb.exe "$@" --ieee-asserts=disable --max-stack-alloc=0 > $B/log 2>&1 || true
  sed 's/.*): //' $B/log | sort | uniq -c | sort -rn | sed -n 1,6p; }
run                       # must be OK
run -gTRT_PS=4000         # must be OK (read window)
run -gTRT_PS=8000         # must be OK
run -gDROP=300 -gPASSES=1 # must FAIL: one lost write
