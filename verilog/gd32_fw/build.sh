#!/usr/bin/env bash
# Build the GD32 "remote ADC" firmware with arm-none-eabi-gcc (no Keil needed).
#
#   bash gd32_fw/build.sh
#
# Toolchain locations tried in order (set TOOLCHAIN to override):
#   C:\Users\Xie\opt\xpack-arm-none-eabi-gcc-12.2.1-1.2
#   C:\Users\Xie\opt\arm-gnu-toolchain-13.2.rel1-mingw-w64-i686-arm-none-eabi
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/docs/gd32/GD32F30x_Firmware_Library_V2.1.5"
FW="$ROOT/gd32_fw"
OUT="$FW/build"
OPT="/c/Users/Xie/opt"

if [ -n "$TOOLCHAIN" ]; then
    TC="$TOOLCHAIN"
else
    TC=""
    for d in "$OPT"/msys2-arm /d/GitHub/xiangmu/FPGA/msys2-arm \
             "$OPT"/xpack-arm-none-eabi-gcc-* "$OPT"/arm-gnu-toolchain-*; do
        [ -d "$d" ] && TC="$d"
    done
    [ -n "$TC" ] || { echo "ERROR: arm-none-eabi-gcc toolchain not found under $OPT"; exit 1; }
fi
if [ -d "$TC/mingw64/bin" ]; then
    export PATH="$TC/mingw64/bin:$PATH"      # msys2-package assembled layout
elif [ -d "$TC/ucrt64/bin" ]; then
    export PATH="$TC/ucrt64/bin:$PATH"       # msys2 ucrt64-package layout
else
    export PATH="$TC/bin:$PATH"              # xpack / arm-gnu-toolchain layout
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
 $FW/main.c
 $LIB/Firmware/CMSIS/GD/GD32F30x/Source/system_gd32f30x.c
 $LIBSRC/gd32f30x_rcu.c
 $LIBSRC/gd32f30x_gpio.c
 $LIBSRC/gd32f30x_spi.c
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

arm-none-eabi-gcc $CFLAGS -c "$FW/startup_gd32f30x_hd.s" -o "$OUT/startup_gd32f30x_hd.o"

arm-none-eabi-gcc $CFLAGS \
    -T"$FW/gd32f303cb.ld" \
    -Wl,--gc-sections \
    -Wl,-Map="$OUT/gd32_fw.map" \
    -o "$OUT/gd32_fw.elf" \
    "$OUT/startup_gd32f30x_hd.o" $OBJS

arm-none-eabi-size "$OUT/gd32_fw.elf"
arm-none-eabi-objcopy -O ihex  "$OUT/gd32_fw.elf" "$OUT/gd32_fw.hex"
arm-none-eabi-objcopy -O binary "$OUT/gd32_fw.elf" "$OUT/gd32_fw.bin"
echo "BUILD OK: $OUT/gd32_fw.hex"
