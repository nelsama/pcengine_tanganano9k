#!/usr/bin/env bash
# tools/build.sh : full bitstream build/pce/impl/pnr/PCE_TN9K.fs (run menu/build.sh first)
set -euo pipefail
GW_SH=${GW_SH:-/c/Gowin/Gowin_V1.9.12.03_x64/IDE/bin/gw_sh.exe}
W=$(cd "$(dirname "$0")/.." && pwd -W); O=$W/build/pce; mkdir -p "$O"; cd "$O"
VHD="src/board/gw_rpll src/memory/psram_burst src/pce/sdp_ram src/pce/huc6280 src/pce/rom_cache src/pce/cpu_sys src/pce/vdc src/pce/vce src/pce/cart src/pce/psg src/pce/pce_core src/board/hdmi/tmds_encoder_2 src/board/hdmi/hdmi_tx src/board/hdmi/hdmi_phy src/board/hdmi_audio src/debug/uart_tx src/debug/uart_report src/board/pce_top"
{
  echo "set_device GW1NR-LV9QN88PC6/I5 -device_version C"
  for f in $VHD; do echo "add_file -type vhdl {$W/$f.vhd}"; done
  for f in src/board/menu_rom.v src/board/pce2hdmi.v; do echo "add_file -type verilog {$W/$f}"; done
  echo "add_file -type cst {$W/src/board/pce_tn9k.cst}"
  echo "add_file -type sdc {$W/src/board/pce_tn9k.sdc}"
  echo "set_option -vhdl_std vhd2008"; echo "set_option -verilog_std sysv2017"
  echo "set_option -include_path {$W/src/board}"
  echo "set_option -top_module pce_top"; echo "set_option -output_base_name PCE_TN9K"
  for o in "use_sspi_as_gpio 1" "use_mspi_as_gpio 1" "timing_driven 1" "place_option 1" "route_option 1"; do echo "set_option -$o"; done
  echo "run all"
} > b.tcl
rm -rf impl
"$GW_SH" b.tcl > out.log 2>&1 || true
grep -E 'ERROR' out.log || true
tail -1 out.log
grep -E '^ +(Logic|Register|BSRAM|CLS|rPLL) ' impl/pnr/PCE_TN9K.rpt.txt
sed 's/<[^>]*>/ /g; s/&nbsp//g' impl/gwsynthesis/*syn_resource.html | tr -s ' \n\r' ' ' | sed 's/.*ROM16 NUMBER//; s/|--/\n  /g; s#(D:[^)]*)##g'; echo
sed 's/<[^>]*>/ /g' impl/pnr/PCE_TN9K_tr_content.html | grep -A60 'Max Frequency Summary' | tr -s ' \n\r' ' ' | head -c 420; echo
grep -A1 'Violated Endpoints' impl/pnr/PCE_TN9K_tr_content.html | sed 's/<[^>]*>/ /g' | tr -d '\n-'; echo
