#!/usr/bin/env bash
# tools/syn.sh top file... : synthesis only, prints the resources per module
set -euo pipefail
GW_SH=${GW_SH:-/c/Gowin/Gowin_V1.9.12.03_x64/IDE/bin/gw_sh.exe}
W=$(cd "$(dirname "$0")/.." && pwd -W); T=$1; shift; O=$W/build/syn_$T; mkdir -p "$O"; cd "$O"
{
  echo "set_device GW1NR-LV9QN88PC6/I5 -device_version C"
  for f in "$@"; do case $f in *.vhd) t=vhdl;; *) t=verilog;; esac; echo "add_file -type $t {$W/$f}"; done
  echo "set_option -vhdl_std vhd2008"; echo "set_option -verilog_std sysv2017"
  echo "set_option -top_module $T"; echo "set_option -disable_io_insertion 1"; echo "run syn"
} > b.tcl
rm -rf impl; "$GW_SH" b.tcl > out.log 2>&1 || true
grep -E 'ERROR' out.log || true
sed 's/<[^>]*>/ /g; s/&nbsp//g' impl/gwsynthesis/*syn_resource.html | tr -s ' \n\r' ' ' | sed 's/.*ROM16 NUMBER//; s/|--/\n  /g; s#(D:[^)]*)##g'; echo
