#!/usr/bin/env bash
# sim/run_pce.sh frames [rom.pce] [tb options]: pce_core with both PSRAM models;
# pictures in build/sim_pce. Without a ROM: sim/vdctest.s
set -euo pipefail
export PATH=/c/msys64/ucrt64/bin:$PATH
cd "$(dirname "$0")/.."; R=$PWD; B=build/sim_pce; mkdir -p $B; cd $B
N=${1:-4}; shift || true
ROM=""; if [ $# -gt 0 ] && [ -f "$1" ]; then ROM=$1; shift; fi
CC=${CC65:-/d/cc65/bin}
cat > t.cfg <<'E'
MEMORY { ZP: start=$0000, size=$100, type=rw; M: start=$E000, size=$1FF6, fill=yes, fillval=$EA; V: start=$FFF6, size=10; }
SEGMENTS { ZEROPAGE: load=ZP, type=zp; CODE: load=M, type=ro; VEC: load=V, type=ro; }
E
$CC/ca65 -o t.o ../../sim/vdctest.s && $CC/ld65 -C t.cfg -o vdctest.pce t.o
python - "${ROM:-vdctest.pce}" <<'E'
import sys
b = open(sys.argv[1], 'rb').read()
if len(b) % 8192 == 512: b = b[512:]
open('rom.bin', 'wb').write(b)
n = len(b) // 8192
print('-gROMBITS=%d -gMASK=%d' % (len(b).bit_length() - 2, n - 1), file=open('opt', 'w'))
E
for s in sim/gowin_ddr.vhd sim/hyperram_model.vhd src/memory/psram_burst.vhd src/pce/sdp_ram.vhd src/pce/huc6280.vhd src/pce/rom_cache.vhd src/pce/cpu_sys.vhd src/pce/vdc.vhd src/pce/vce.vhd src/pce/pce_core.vhd sim/tb_pce.vhd; do ghdl -a --std=08 -frelaxed ../../$s; done
ghdl -e --std=08 -frelaxed -o tb.exe tb_pce
rm -f f*.raw f*.png
./tb.exe $(cat opt) -gFRAMES=$N "$@" --ieee-asserts=disable --max-stack-alloc=0 2>&1 | sed 's/.*): //' | tail -20
python ../../sim/raw2png.py f*.raw; ls f*.png | tail -3
