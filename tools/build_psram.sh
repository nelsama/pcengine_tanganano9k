#!/usr/bin/env bash
# tools/build_psram.sh : bitstream of the PSRAM board test, build/psram/impl/pnr/psram_test.fs
set -euo pipefail
GW_SH=${GW_SH:-/c/Gowin/Gowin_V1.9.12.03_x64/IDE/bin/gw_sh.exe}
W=$(cd "$(dirname "$0")/.." && pwd -W); O=$W/build/psram; mkdir -p "$O"; cd "$O"
{
  echo "set_device GW1NR-LV9QN88PC6/I5 -device_version C"
  for f in src/board/gw_rpll src/debug/uart_tx src/debug/uart_report src/memory/psram_burst test/psram/psram_tester test/psram/psram_test_top; do
    echo "add_file -type vhdl {$W/$f.vhd}"; done
  echo "add_file -type cst {$W/test/psram/psram_test.cst}"
  echo "add_file -type sdc {$W/test/psram/psram_test.sdc}"
  echo "set_option -vhdl_std vhd2008"
  echo "set_option -top_module psram_test_top"
  echo "set_option -output_base_name psram_test"
  for o in "use_sspi_as_gpio 1" "use_mspi_as_gpio 1" "timing_driven 1" "place_option 1" "route_option 1"; do echo "set_option -$o"; done
  echo "run all"
} > b.tcl
rm -rf impl
"$GW_SH" b.tcl > out.log 2>&1 || true
grep -E 'ERROR' out.log || true
tail -1 out.log
grep -E '^ +(Logic|Register|BSRAM|CLS|rPLL) ' impl/pnr/psram_test.rpt.txt
sed 's/<[^>]*>/ /g' impl/pnr/psram_test_tr_content.html | grep -A40 'Max Frequency Summary' | tr -s ' \n\r' ' ' | head -c 400; echo
grep -A1 'Violated Endpoints' impl/pnr/psram_test_tr_content.html | sed 's/<[^>]*>/ /g' | tr -d '\n-'; echo
