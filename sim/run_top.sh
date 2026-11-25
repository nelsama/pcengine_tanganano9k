#!/usr/bin/env bash
# sim/run_top.sh frames "a.pce b.pce" [tb options: -gPRESS=8 -gS2AT=999]
# the whole pce_top: menu, SD card with those files, game. Pictures in build/sim_top.
set -euo pipefail
export PATH=/c/msys64/ucrt64/bin:$PATH
cd "$(dirname "$0")/.."; B=build/sim_top; mkdir -p $B; cd $B
N=$1; FILES=$2; shift 2
cp ../../menu/menu.hex .
python ../../sim/mkimg.py sd.img $FILES
for s in sim/gowin_ddr.vhd sim/hyperram_model.vhd sim/sim_parts.vhd sim/menu_rom.vhd src/memory/psram_burst.vhd src/pce/sdp_ram.vhd src/pce/huc6280.vhd src/pce/rom_cache.vhd src/pce/cpu_sys.vhd src/pce/vdc.vhd src/pce/vce.vhd src/pce/cart.vhd src/pce/psg.vhd src/pce/pce_core.vhd src/debug/uart_tx.vhd src/debug/uart_report.vhd src/board/hdmi/tmds_encoder_2.vhd src/board/hdmi/hdmi_tx.vhd src/board/hdmi_audio.vhd src/board/pce_top.vhd sim/tb_top.vhd; do ghdl -a --std=08 -frelaxed ../../$s; done
ghdl -e --std=08 -frelaxed -o tb.exe tb_top
rm -f f*.raw f*.png
./tb.exe -gFRAMES=$N "$@" --ieee-asserts=disable --max-stack-alloc=0 2>&1 | sed 's/.*): //' | sort | uniq -c | tail -20
python ../../sim/raw2png.py f*.raw; ls f*.png | tail -2
