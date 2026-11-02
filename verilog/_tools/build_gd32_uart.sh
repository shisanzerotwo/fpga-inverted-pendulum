#!/usr/bin/env bash
# Build the GD32 UART-transport "remote ADC" firmware (main_uart.c) --
# the 2026-10-16 link rescue over the spare net PA2 -> FPGA ball K11.
# Same toolchain/flags as gd32_fw/build.sh; output in gd32_fw/build_uart/.
#   bash _tools/build_gd32_uart.sh
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/docs/gd32/GD32F30x_Firmware_Library_V2.1.5"
FW="$ROOT/gd32_fw"
OUT="$FW/build_uart"

TC=""
for d in /d/GitHub/xiangmu/FPGA/msys2-arm /c/Users/Xie/opt/msys2-arm; do
    [ -d "$d" ] && TC="$d"
done
[ -n "$TC" ] || { echo "ERROR: arm toolchain not found"; exit 1; }
if [ -d "$TC/ucrt64/bin" ]; then
    export PATH="$TC/ucrt64/bin:$PATH"
elif [ -d "$TC/mingw64/bin" ]; then
    export PATH="$TC/mingw64/bin:$PATH"
else
    export PATH="$TC/bin:$PATH"
fi

mkdir -p "$OUT"

CFLAGS="-mcpu=cortex-m4 -mthumb -O2 -g2 -Wall -Wextra -Wno-unused-parameter -ffreestanding -nostdlib \
 -ffunction-sections -fdata-sections -fno-unwind-tables -fno-asynchronous-unwind-tables \
 -DGCC_COMPILE=1 -DGD32F30X_HD -DHXTAL_VALUE=8000000U \
 -I$FW \
 -I$LIB/Firmware/CMSIS \
 -I$LIB/Firmware/CMSIS/GD/GD32F30x/Include \
 -I$LIB/Firmware/GD32F30x_standard_peripheral/Include"

LIBSRC="$LIB/Firmware/GD32F30x_standard_peripheral/Source"
SRCS="
 $FW/main_uart.c
 $LIB/Firmware/CMSIS/GD/GD32F30x/Source/system_gd32f30x.c
 $LIBSRC/gd32f30x_rcu.c
 $LIBSRC/gd32f30x_gpio.c
 $LIBSRC/gd32f30x_usart.c
 $LIBSRC/gd32f30x_adc.c
 $LIBSRC/gd32f30x_misc.c
"

OBJS=""
for s in $SRCS; do
    o="$OUT/$(basename "${s%.*}").o"
    arm-none-eabi-gcc $CFLAGS -c "$s" -o "$o"
    OBJS="$OBJS $o"
done

arm-none-eabi-gcc $CFLAGS -c "$FW/startup_gd32f30x_hd.s" -o "$OUT/startup.o"

arm-none-eabi-gcc $CFLAGS \
    -T"$FW/gd32f303cb.ld" \
    -Wl,--gc-sections \
    -Wl,-Map="$OUT/gd32_uart.map" \
    -o "$OUT/gd32_uart.elf" \
    "$OUT/startup.o" $OBJS

arm-none-eabi-size "$OUT/gd32_uart.elf"
arm-none-eabi-objcopy -O ihex "$OUT/gd32_uart.elf" "$OUT/gd32_uart.hex"
echo "BUILD OK: $OUT/gd32_uart.hex"
