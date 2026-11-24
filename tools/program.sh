#!/usr/bin/env bash
# tools/program.sh file.fs : load into the FPGA SRAM (the flash is not touched)
unset PYTHONIOENCODING PYTHONUTF8
cd /c/Gowin/Gowin_V1.9.12.03_x64/Programmer/bin && ./programmer_cli.exe --device GW1NR-9C --operation_index 2 --fsFile "$(cd "$OLDPWD" && realpath "$1" | xargs cygpath -m)"
