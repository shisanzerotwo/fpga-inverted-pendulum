# -*- coding: utf-8 -*-
"""从 GD32 官方 ARM(Keil) 启动文件生成 GNU 汇编启动文件。

- 向量表 84 条：逐条从官方文件提取，不手工抄写
- 中断弱别名：从官方 EXPORT 列表生成，未实现的落到 Default_Handler
- Reset_Handler：手工模板（Keil 的 __main 负责搬 .data/清 .bss，GCC 无 __main，必须自己写）

用法: python3 gen_startup.py <官方 ARM 启动文件> <输出 .s>
"""
import re
import sys

SRC, OUT = sys.argv[1], sys.argv[2]
lines = open(SRC, encoding="utf-8", errors="replace").read().splitlines()

# ---- 1. 向量表 ----
vec = []
started = False
for ln in lines:
    if not started:
        if "__Vectors" in ln and "DCD" in ln:
            started = True
        else:
            continue
    if started:
        m = re.search(r"\bDCD\s+(\S+)", ln)
        if m:
            vec.append(m.group(1))
            continue
        s = ln.strip()
        if s == "" or s.startswith(";"):
            continue
        if re.match(r"^(Reset_Handler|AREA|EXPORT|IMPORT|PROC|ENDP|ALIGN)", s):
            break

# ---- 2. 中断/异常 handler 名（排除向量表辅助符号）----
SKIP = {"Reset_Handler", "__Vectors", "__Vectors_End", "__Vectors_Size",
        "__initial_sp", "__heap_base", "__heap_limit", "__user_initial_stackheap"}
handlers = []
for ln in lines:
    m = re.match(r"\s+EXPORT\s+(\w+)", ln)
    if m and m.group(1) not in SKIP and m.group(1) not in handlers:
        handlers.append(m.group(1))

# ---- 3. 生成 GNU 汇编 ----
o = []
o += [
    "/* startup_gd32f30x.s — GNU 汇编启动文件（ARM GCC 用）",
    " *",
    " * 来源：GD32F30x 固件库 V2.1.5 的 ARM(Keil) 版 startup_gd32f30x_cl.s，",
    " *       由 gd32_firmware/tools/gen_startup.py 自动移植。",
    " *       向量表与中断弱别名均为脚本生成，请勿手工编辑本文件。",
    " *",
    " * 与 Keil 版的唯一语义差异：",
    " *   Keil 的 __main 负责搬 .data / 清 .bss；GCC 没有 __main，",
    " *   故 Reset_Handler 里自行完成（用链接脚本导出的 _sidata/_sdata/_edata/_sbss/_ebss）。",
    " */",
    "",
    "  .syntax unified",
    "  .cpu cortex-m4",
    "  .fpu softvfp",
    "  .thumb",
    "",
    "  .global g_pfnVectors",
    "  .global Default_Handler",
    "",
    "/* ================= 向量表（%d 条，与官方一致）================= */" % len(vec),
    "  .section .isr_vector,\"a\",%progbits",
    "  .type g_pfnVectors, %object",
    "g_pfnVectors:",
]
for i, sym in enumerate(vec):
    if sym == "0":
        o.append("  .word 0                    /* %2d: Reserved */" % i)
    else:
        o.append("  .word %-24s /* %2d */" % (sym, i))
o += [
    "  .size g_pfnVectors, .-g_pfnVectors",
    "",
    "/* ================= Reset_Handler ================= */",
    "  .section .text.Reset_Handler",
    "  .weak Reset_Handler",
    "  .type Reset_Handler, %function",
    "Reset_Handler:",
    "  /* 1) 搬 .data：Flash(_sidata) -> RAM(_sdata.._edata) */",
    "  ldr  r0, =_sdata",
    "  ldr  r1, =_edata",
    "  ldr  r2, =_sidata",
    "  movs r3, #0",
    "  b    2f",
    "1:",
    "  ldr  r4, [r2, r3]",
    "  str  r4, [r0, r3]",
    "  adds r3, r3, #4",
    "2:",
    "  adds r4, r0, r3",
    "  cmp  r4, r1",
    "  bcc  1b",
    "  /* 2) 清 .bss */",
    "  ldr  r2, =_sbss",
    "  ldr  r4, =_ebss",
    "  movs r3, #0",
    "  b    4f",
    "3:",
    "  str  r3, [r2]",
    "  adds r2, r2, #4",
    "4:",
    "  cmp  r2, r4",
    "  bcc  3b",
    "  /* 3) 时钟/外设初始化 + main */",
    "  bl   SystemInit",
    "  bl   main",
    "  /* main 不应返回；若返回则原地自陷 */",
    "5:",
    "  b    5b",
    "  .size Reset_Handler, .-Reset_Handler",
    "",
    "/* ================= 默认 handler：原地自陷 ================= */",
    "/* 未实现的中断都落在这里；调试时停在 Default_Handler 即知是哪个异常/中断触发 */",
    "  .section .text.Default_Handler,\"ax\",%progbits",
    "Default_Handler:",
    "  b    .",
    "  .size Default_Handler, .-Default_Handler",
    "",
    "/* ================= 中断弱别名（%d 个）================= */" % len(handlers),
]
for h in handlers:
    o += ["  .weak %s" % h, "  .thumb_set %s, Default_Handler" % h]
o += ["", "  .end", ""]

open(OUT, "w", encoding="utf-8", newline="\n").write("\n".join(o))
print("已生成 %s：向量 %d 条、弱别名 %d 个" % (OUT, len(vec), len(handlers)))
