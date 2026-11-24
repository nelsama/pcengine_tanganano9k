# Launcher de consolas en la Tang Nano 9K: evaluación

Idea: guardar los bitstreams de NES, SMS, PC Engine y Atari en la SD, elegir uno desde
un launcher, cargarlo y volver al launcher con un botón.

**Conclusión:** es viable. Para que funcione solo con la placa hace falta la flash
externa y **una resistencia** (o un condensador). Sin tocar la placa, hace falta otro
dispositivo conectado por USB. Evaluado con documentación y esquema; **sin probar en la placa**.

## Datos de partida

| Dato | Valor |
|---|---|
| Bitstream binario | 444.430 bytes (434 KB), igual para todos los cores |
| Archivo `.fs` | unos 3,5 MB, porque es texto; a la flash va la versión binaria (`.bin`) |
| Flash externa | P25Q32U, 4 MB, pines 59-62 (la usa Pengo para sus datos) |
| Ranuras de 448 KB | 9: launcher y 8 cores |
| User flash interna | 608 Kbit (76 KB) |
| Pines MODE | MODE0 y MODE1 a masa con 4,7 kΩ (R19, R17); MODE2 no sale del encapsulado |
| RECONFIG_N | pin 9, 4,7 kΩ a 1,8 V; la lógica puede activarlo |
| BSRAM de los 4 cores | 93 bloques de 26: no caben en un solo bitstream |

## Por qué hace falta la resistencia

| Paso | Quién lo hace | ¿Resistencia? |
|---|---|---|
| 1. SD → flash externa | la lógica (launcher), por SPI | no |
| 2. Pulso en RECONFIG_N | la lógica | no |
| 3. Flash externa → SRAM | el cargador fijo del chip | **sí** |

El cargador lee los pines MODE al encender y en cada RECONFIG_N:

| MODE2 MODE1 MODE0 | Origen |
|---|---|
| 0 0 0 | flash interna (así está la placa) |
| 0 1 0 | flash externa (MSPI) |
| 1 1 0 | externa y, si falla, interna (no disponible: falta MODE2) |

Durante la reconfiguración las patas quedan sueltas y R17 pone MODE1 a 0, así que un
bitstream no puede cambiarlo.

## Opciones

| Opción | Modificar la placa | Autónoma | Riesgo |
|---|---|---|---|
| **1. Flash externa + resistencia** | unos 470 Ω entre el lado del pin 87 de R17 y 1,8 V | sí | salto MULTIBOOT sin probar |
| **2. Flash externa + condensador** | unos 1 µF en el pin 87 a masa | sí | lo anterior y el tiempo de retención |
| **3. Raspberry Pi o PC por USB** | nada | no | bajo: la carga por USB ya funciona |
| **4. Microcontrolador por JTAG** | 4 hilos y masa en R36-R39 | sí, con ese añadido | medio |
| **5. Reprogramar el BL702** | nada | sí | alto: se puede perder el programador USB |
| **6. SSPI con un microcontrolador** | resistencia y varios hilos | sí, con ese añadido | peor que la 4 |

Descartadas:

- **Flash interna:** solo arranca en la dirección 0 (una imagen) y, en el GW1N-9, la
  documentación solo describe grabarla desde fuera, por JTAG.
- **User flash:** no cabe un core y el chip no arranca desde ella. Sirve para datos pequeños.
- **Todos los cores en un bitstream:** no cabe.

## Opción 1: cómo funcionaría

```
Encendido ─► flash 0x000000: LAUNCHER ─► lista SD:/CORES/*.bin
                 ▲                           │ eliges uno
                 │                           ▼
   botón en el core                  borra y graba la ranura 0x080000
   (pulso RECONFIG_N)                 (si ya está ahí, se lo salta)
                 │                           │ pulso RECONFIG_N
                 └───────── CORE ◄───────────┘
```

- Cada bitstream lleva fija la dirección del siguiente: el launcher apunta a `0x080000`
  y los cores a `0x000000`. Por eso el core elegido se copia siempre a la misma ranura.
- Con 470 Ω y los 4,7 kΩ de R17 quedan unos 1,6 V en el pin (calculado: medir al montarlo).
- La placa deja de arrancar de la flash interna. Es reversible y se recupera por USB (JTAG no depende de MODE).
- Con el **condensador** (opción 2) el launcher iría en la flash interna: al encender o al
  pulsar RECONFIG_N sin cargarlo, arrancaría como hoy.

Tiempos estimados: copiar SD → flash, 2-6 s (solo al cambiar de core); cargar el core,
1,4 s a 2,5 MHz (por defecto) o unos 0,15 s a 25 MHz.

## Opción 3: cómo funcionaría

1. La flash interna guarda el launcher.
2. Al elegir, el launcher envía `LOAD nes` por la UART (pin 17, el mismo cable USB).
3. La Raspberry ejecuta `openFPGALoader -b tangnano9k nes.fs`, que carga la SRAM. Con el
   programador de Gowin en el PC tarda 3,5-5 s.
4. Para volver, el core envía `LOAD launcher`, o se apaga y enciende.

Los juegos siguen en la SD de la placa; los bitstreams, en la Raspberry. Requiere un equipo
con USB host y Linux (por ejemplo, Pi Zero 2 W); un ESP32 común no sirve.

## Trabajo (opción 1)

1. **Prueba de concepto:** dos bitstreams mínimos que saltan entre sí, sujetando la
   resistencia con un cable. Antes, respaldar la flash externa.
2. **Launcher:** base del SMS (Z80, menú, FAT32) más escritura de la flash con verificación.
3. **Cores:** pin 9 y botón de volver (S2 mantenido 2 s dentro del menú, con la partida ya
   guardada). No gasta BSRAM; Atari ya usa 26 de 26.

## Riesgos y límites

- El salto MULTIBOOT en el GW1N-9C no está probado, y el valor `010` se dedujo de una tabla
  de UG290 que se extrajo desordenada.
- Un corte de luz al copiar daña solo la ranura del core, no el launcher.
- Pengo guarda datos en esa flash: hay que reservarle zona o moverlo.
- Primera versión: el launcher elige la consola y el menú de cada core, el juego.

## Decisión pendiente

| Se quiere | Elegir |
|---|---|
| Consola autónoma, solo la placa | opción 1 (o 2) |
| No tocar la placa | opción 3 |

Siguiente paso: la prueba de concepto de la opción elegida.

## Fuentes

- UG290-2.9E (programación y configuración) y SUG935-1.6.1E (restricciones físicas), en la instalación de Gowin.
- [Esquema de la Tang Nano 9K](https://dl.sipeed.com/fileList/TANG/Nano%209K/2_Schematic/Tang_Nano_9k_3672_Schematic.pdf).
- El tamaño de la user flash (608 Kbit) no se comprobó en estos documentos.
