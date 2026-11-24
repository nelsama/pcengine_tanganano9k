#!/usr/bin/env bash
# tools/build_cpu.sh : bitstream of the CPU board test, build/cpu/impl/pnr/cpu_test.fs
# (run sim/run_cpusys.sh first: it assembles the test program)
set -euo pipefail
GW_SH=${GW_SH:-/c/Gowin/Gowin_V1.9.12.03_x64/IDE/bin/gw_sh.exe}
W=$(cd "$(dirname "$0")/.." && pwd -W); O=$W/build/cpu; mkdir -p "$O"; cd "$O"
/c/msys64/ucrt64/bin/python - "$W" "$O" <<'E'
import sys
w, o = sys.argv[1:]
b = open(w + '/build/sim_cpusys/t.bin', 'rb').read()
open(o + '/prog.hex', 'w').write('\n'.join('%02x%02x' % (b[i+1], b[i]) for i in range(0, 8192, 2)) + '\n')
open(o + '/rom_gen.v', 'w').write('`define PROG_HEX "%s/prog.hex"\n' % o + open(w + '/test/cpu/cpu_test_rom.v').read())
E
{
  echo "set_device GW1NR-LV9QN88PC6/I5 -device_version C"
  for f in src/board/gw_rpll src/debug/uart_tx src/debug/uart_report src/memory/psram_burst src/pce/huc6280 src/pce/rom_cache src/pce/cpu_sys test/cpu/cpu_test_top; do
    echo "add_file -type vhdl {$W/$f.vhd}"; done
  echo "add_file -type verilog {$O/rom_gen.v}"
  echo "add_file -type cst {$W/test/cpu/cpu_test.cst}"
  echo "add_file -type sdc {$W/test/cpu/cpu_test.sdc}"
  echo "set_option -vhdl_std vhd2008"
  echo "set_option -top_module cpu_test_top"
  echo "set_option -output_base_name cpu_test"
  for o in "use_sspi_as_gpio 1" "use_mspi_as_gpio 1" "timing_driven 1" "place_option 1" "route_option 1"; do echo "set_option -$o"; done
  echo "run all"
} > b.tcl
rm -rf impl
"$GW_SH" b.tcl > out.log 2>&1 || true
grep -E 'ERROR' out.log || true
tail -1 out.log
grep -E '^ +(Logic|Register|BSRAM|CLS|rPLL) ' impl/pnr/cpu_test.rpt.txt
sed 's/<[^>]*>/ /g' impl/pnr/cpu_test_tr_content.html | grep -A40 'Max Frequency Summary' | tr -s ' \n\r' ' ' | head -c 400; echo
grep -A1 'Violated Endpoints' impl/pnr/cpu_test_tr_content.html | sed 's/<[^>]*>/ /g' | tr -d '\n-'; echo
