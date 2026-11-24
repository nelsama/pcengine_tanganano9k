# PC Engine en Tang Nano 9K (en desarrollo)

## Paso 1: PSRAM con ráfagas

- `src/memory/psram_burst.vhd`: un chip de la PSRAM a 86,4 MHz, ráfagas de 1 a
  64 palabras (da la vuelta cada 64) y latencia fija o variable (interfaz y tiempos en su cabecera).
- `bash sim/run_psram.sh`: simulación contra un modelo de los pines. Las tres
  primeras deben dar OK; la última, con una escritura perdida a propósito, FAIL.
- `bash tools/build_psram.sh`: bitstream `build/psram/impl/pnr/psram_test.fs`.

### En la placa

LED 0 / 1: error en el chip 0 / 1. LED 2: ambos funcionan. LED 4 / 5: parpadean
con las pasadas. S1 borra los errores. Por el USB (115200 8N1), una línea por chip:

    D0 H=f P=pppp EF=.. ET=.. EV=.. A=.. G=.. X=.. R1F=0E R1V=0B-0E R9F=16 R33F=2E R16V=1D W1=09 SL=..

Todo en hexadecimal. `P` pasadas; `EF`/`ET`/`EV` errores con latencia fija, en los
cambios lectura-escritura y con latencia variable (deben ser 0000); `A`/`G`/`X`
primer error: dirección, leído, esperado; `R..`/`W1` duración en ciclos de 86,4 MHz
(los valores de arriba son los simulados); `SL` lecturas lentas por refresco.

Licencia: `psram_burst.vhd` y los derivados de zf3, Apache 2.0.

Resultado en la placa (2026-11-23): 4732 pasadas de 4 MB por chip en unos 10
minutos, 0 errores; duraciones iguales a las simuladas. Grabar en SRAM y leer el puerto:
`bash tools/program.sh archivo.fs`, `tools/uart.ps1 -Port COM3 -Seconds 10`.

## Paso 2: HuC6280 con caché de ROM

- `src/pce/huc6280.vhd`: CPU y MMU, con los ciclos del original. `rom_cache.vhd`:
  caché de 4 KB, líneas de 16 bytes. `cpu_sys.vhd`: CPU, 8 KB de RAM, timer,
  interrupciones, mando y caché.
- `bash sim/run_cpu.sh [semillas] [instrucciones]`: CPU contra un modelo de referencia
  propio (`sim/cpu_core.h`) con código aleatorio: registros, ciclos y escrituras.
- `sim/tb_klaus.vhd`: prueba funcional 6502 de Klaus Dormann (debe parar en `$3469`).
- `bash sim/run_cpusys.sh`: sistema completo con la PSRAM simulada (`sim/cputest.s`).
- `bash tools/build_cpu.sh`: bitstream de prueba `build/cpu/impl/pnr/cpu_test.fs`; por
  el puerto serie, `E` debe ser 0000 y `V1=7637 V2=4D V4=17/18 CV=00`.
- `sim/cachesim.cpp`: fallos de varias cachés con una HuCard (`cachesim rom.pce cuadros`).

Recursos (síntesis): 1713 LUT+ALU y 7 BSRAM. Un fallo de caché cuesta unos 2,7 ciclos
de CPU: 8 % más lento en código lineal que se ejecuta por primera vez (medido en la
placa con 4 KB de NOP). Placa, 2026-11-23: 2319 ejecuciones seguidas, 0 errores.
El timer no se retrasa con los fallos.

## Paso 3: VDC, VCE y HDMI

- `src/pce/vdc.vhd`: HuC6270 con la VRAM en la PSRAM. `vce.vhd`: HuC6260.
  `pce_core.vhd`: CPU + VDC + VCE. `src/board/pce2hdmi.v`: escalado a 720x480p.
- `bash sim/run_pce.sh cuadros [rom.pce] [-gPADBTN=1 -gPADAT=10]`: simula e imprime
  imágenes en `build/sim_pce` (unos 20 s por cuadro). Sin ROM usa `sim/vdctest.s`.
- `bash tools/build.sh`: bitstream `build/pce/impl/pnr/PCE_TN9K.fs`; en el IDE,
  `PCE_TN9K.gprj` (ejecuta antes `tools/build.sh` si mueves el proyecto).
- De momento arranca `sim/vdctest.s` desde BSRAM: izquierda / derecha cambian el
  scroll, I cambia entre 256, 336 y 512 puntos. Borde gris = VRAM correcta, rojo = error.
  Mando: Run 85, Select 86, I 35, II 29. UART: cuadros, errores, HDMI enganchado, fallos de caché.
- Sin implementar: modos de ancho de acceso de MWR y modos CG de 2 colores.

## Paso 4: menú y carga desde la SD

- Formatea la SD en FAT32 y copia los `.pce` en cualquier carpeta (hasta 2,5 MB, con o
  sin cabecera de 512 bytes; las ROM con los bits invertidos se detectan solas).
- Menú: arriba / abajo elige, izquierda / derecha cambia de página, I o Run abre, II vuelve.
  En el juego, S2 vuelve al menú y S1 reinicia todo.
- Tamaños: potencia de 2, 384 KB, 768 KB y Street Fighter II (2,5 MB).
- `bash menu/build.sh` compila el menú (cc65) y luego `bash tools/build.sh`;
  `python menu/test_fat.py` prueba FAT32 y cargador en el PC.
- `bash sim/run_top.sh cuadros "ruta/a.pce" [-gPRESS=8 -gS2AT=24]`: `pce_top` completo con
  una SD simulada (unos 25 s por cuadro).
- `sim/vdctest.s` ya no arranca solo: copia `build/sim_pce/vdctest.pce` a la SD.
- LEDs: 0 HDMI, 1 latido, 2 botón, 3 menú, 4 cargando.

## Paso 5 (parte): sonido

- `src/pce/psg.vhd`: PSG del HuC6280 (6 canales, ruido, DDA, LFO), estéreo, por los
  pines 77 (L) y 76 (R) con el filtro RC del Master System. Prueba: `sim/tb_psg.vhd`.
  Confirmado en la placa (2026-11-23): imagen, carga de juegos y sonido.

## Partidas guardadas

La RAM de respaldo (2 KB, banco F7) es propia de cada juego: `<nombre corto>.SAV` en su
carpeta. Guarda dentro del juego y pulsa **S2** (o S1): si cambió, el menú muestra
`SAVING...` y la escribe; al abrir el juego se carga sola. **Si apagas sin pulsar S2 o S1, se
pierde.** Solo sirve para juegos que guardan en RAM de respaldo, no con contraseña.
Si falla, I reintenta y II descarta. Haz una copia de la SD y pasa `chkdsk` la primera vez.
`sim/savetest.s`: prueba (borde azul = escrita ahora, verde = recuperada, rojo = error).
