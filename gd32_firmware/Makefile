# GD32F303CBT6 — 摆角 ADC 采样 + 原码转发固件（GCC 版）
#
# 依赖：arm-none-eabi-gcc（WSL: sudo apt install gcc-arm-none-eabi）
# 用法：
#   make            # 编译 -> build/gd32_adc_bridge.{elf,hex,bin}
#   make size       # 查看 Flash/RAM 占用
#   make clean
#
# 说明：
#   - 启动文件 src/startup_gd32f30x.s 由 tools/gen_startup.py 从官方 ARM(Keil) 版自动生成，勿手改
#   - 外设库用 lib/peripheral/source 全部源文件 + --gc-sections，未用到的会被链接器丢弃
#   - 本工程只用 nano specs + nosys（syscall stub），不依赖 printf/浮点

TARGET   := gd32_adc_bridge
BUILD    := build
LDSCRIPT := ld/gd32f303cb.ld

CROSS    := arm-none-eabi-
CC       := $(CROSS)gcc
OBJCOPY  := $(CROSS)objcopy
OBJDUMP  := $(CROSS)objdump
SIZE     := $(CROSS)size

CPU      := -mcpu=cortex-m4 -mthumb -mfloat-abi=soft
# 器件档：GD32F303CBT6 = 128KB Flash -> CL 档（与 src/startup_gd32f30x.s 的 84 条向量表匹配）
# HXTAL：必须显式定义！CL 档在 gd32f30x.h 里默认写的是 25MHz，而板载晶振实为
#        8MHz（原理图 X1 = X32258MOB4SI，3225封装/8M）——不覆盖会让主频/波特率全错。
DEFS     := -DGD32F30X_CL -DHXTAL_VALUE=8000000
INCS     := -Ilib/CMSIS -Ilib/peripheral/include -Isrc

CFLAGS   := $(CPU) $(DEFS) $(INCS) -O1 -g3 -Wall -Wextra \
            -ffunction-sections -fdata-sections
ASFLAGS  := $(CPU) $(INCS) -x assembler-with-cpp
LDFLAGS  := $(CPU) -T$(LDSCRIPT) -Wl,--gc-sections \
            -Wl,-Map=$(BUILD)/$(TARGET).map \
            --specs=nano.specs --specs=nosys.specs

C_SRCS   := $(wildcard src/*.c) $(wildcard lib/CMSIS/*.c) $(wildcard lib/peripheral/source/*.c)
ASM_SRCS := $(wildcard src/*.s)

OBJS     := $(addprefix $(BUILD)/,$(notdir $(C_SRCS:.c=.o))) \
            $(addprefix $(BUILD)/,$(notdir $(ASM_SRCS:.s=.o)))

vpath %.c $(sort $(dir $(C_SRCS)))
vpath %.s $(sort $(dir $(ASM_SRCS)))

.PHONY: all size clean

all: $(BUILD)/$(TARGET).elf $(BUILD)/$(TARGET).hex $(BUILD)/$(TARGET).bin

$(BUILD)/%.o: %.c | $(BUILD)
	$(CC) -c $(CFLAGS) $< -o $@

$(BUILD)/%.o: %.s | $(BUILD)
	$(CC) -c $(ASFLAGS) $< -o $@

$(BUILD)/$(TARGET).elf: $(OBJS) $(LDSCRIPT)
	$(CC) $(OBJS) $(LDFLAGS) -o $@
	$(SIZE) $@

$(BUILD)/%.hex: $(BUILD)/%.elf
	$(OBJCOPY) -O ihex $< $@

$(BUILD)/%.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD):
	mkdir -p $@

size: $(BUILD)/$(TARGET).elf
	$(SIZE) -A $<

clean:
	rm -rf $(BUILD)
