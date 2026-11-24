#!/usr/bin/env bash
# sim/run_cpusys.sh : CPU + RAM + timer + cache + PSRAM model with cputest.s
set -euo pipefail
export PATH=/c/msys64/ucrt64/bin:$PATH
cd "$(dirname "$0")/.."; R=$PWD; B=build/sim_cpusys; mkdir -p $B; cd $B
CC=${CC65:-/d/cc65/bin}
$CC/ca65 -o t.o ../../sim/cputest.s
cat > t.cfg <<'E'
MEMORY { M: start=$E000, size=$1FF6, fill=yes, fillval=$EA; V: start=$FFF6, size=10; }
SEGMENTS { CODE: load=M, type=ro; VEC: load=V, type=ro; }
E
$CC/ld65 -C t.cfg -o t.bin t.o
python -c "
b=bytearray((i*7+(i>>8))&255 for i in range(65536))
b[0:8192]=open('t.bin','rb').read()
b[16384:16384+4096]=b'\xea'*4095+b'\x60'
open('rom.bin','wb').write(b)
s=sum(b[8192:])&65535
print('expected: test 1 = %d then %d; test 2 = 77; test 4 = 23 or 24 (+ irq time)'%(s&255,s>>8))"
F="--std=08"
for s in sim/gowin_ddr.vhd sim/hyperram_model.vhd src/memory/psram_burst.vhd src/pce/huc6280.vhd src/pce/rom_cache.vhd src/pce/cpu_sys.vhd sim/tb_cpusys.vhd; do ghdl -a $F -frelaxed ../../$s; done
ghdl -e $F -frelaxed -o tb.exe tb_cpusys
./tb.exe --ieee-asserts=disable --max-stack-alloc=0 2>&1 | sed 's/.*): //' | tail -20
