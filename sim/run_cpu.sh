#!/usr/bin/env bash
# sim/run_cpu.sh [seeds] [instructions] : huc6280 against cpu_ref with random code
set -euo pipefail
export PATH=/c/msys64/ucrt64/bin:$PATH
cd "$(dirname "$0")/.."; R=$PWD; B=build/sim_cpu; mkdir -p $B; cd $B
g++ -O1 -o cpu_ref "$R/sim/cpu_ref.cpp"
ghdl -a --std=08 "$R/src/pce/huc6280.vhd"; ghdl -a --std=08 "$R/sim/tb_cpu.vhd"; ghdl -e --std=08 -o tb.exe tb_cpu
for s in $(seq 1 ${1:-4}); do
  ./cpu_ref $s ${2:-100000}
  ./tb.exe --ieee-asserts=disable --max-stack-alloc=0 2>&1 | sed 's/.*): //'
done
