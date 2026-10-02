/* GD32F303CBT6 链接脚本（GCC）
 *
 * 器件：GD32F303CBT6（LQFP48，Flash 128KB，SRAM 见下）
 *   Flash: 0x08000000, 128K
 *   SRAM : 0x20000000
 *
 * RAM 长度取 20K 的**保守值**（STM32F103CB 同级规格；GD32F303CB 实际可能更大）。
 * 本工程只用几 KB RAM（栈 1KB + 少量全局），20K 足够且不会越界。
 * 若日后确认器件 RAM 更大且需要，再调 LENGTH（[待核实]：GD32F303CB 的 SRAM 实际容量）。
 *
 * 命名约定（供 startup_gd32f30x.s 使用）：
 *   _sidata = .data 在 Flash 中的加载地址；_sdata/_edata = .data 在 RAM 的起止
 *   _sbss/_ebss = .bss 起止；__initial_sp = 向量表第 0 项（栈顶）
 */
ENTRY(Reset_Handler)

_estack     = ORIGIN(RAM) + LENGTH(RAM);   /* 栈顶（向下生长） */
__initial_sp = _estack;

MEMORY
{
  FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 128K
  RAM   (xrw) : ORIGIN = 0x20000000, LENGTH = 20K
}

SECTIONS
{
  /* 向量表必须落在 Flash 最前 */
  .isr_vector :
  {
    . = ALIGN(4);
    KEEP(*(.isr_vector))
    . = ALIGN(4);
  } >FLASH

  .text :
  {
    . = ALIGN(4);
    *(.text)
    *(.text*)
    *(.glue_7)
    *(.glue_7t)
    *(.eh_frame)
    KEEP(*(.init))
    KEEP(*(.fini))
    . = ALIGN(4);
    _etext = .;
  } >FLASH

  .rodata :
  {
    . = ALIGN(4);
    *(.rodata)
    *(.rodata*)
    . = ALIGN(4);
  } >FLASH

  .ARM.extab : { *(.ARM.extab* .gnu.linkonce.armextab.*) } >FLASH
  .ARM : {
    __exidx_start = .;
    *(.ARM.exidx*)
    __exidx_end = .;
  } >FLASH

  .preinit_array :
  {
    PROVIDE_HIDDEN(__preinit_array_start = .);
    KEEP(*(.preinit_array*))
    PROVIDE_HIDDEN(__preinit_array_end = .);
  } >FLASH
  .init_array :
  {
    PROVIDE_HIDDEN(__init_array_start = .);
    KEEP(*(SORT(.init_array.*)))
    KEEP(*(.init_array*))
    PROVIDE_HIDDEN(__init_array_end = .);
  } >FLASH
  .fini_array :
  {
    PROVIDE_HIDDEN(__fini_array_start = .);
    KEEP(*(SORT(.fini_array.*)))
    KEEP(*(.fini_array*))
    PROVIDE_HIDDEN(__fini_array_end = .);
  } >FLASH

  _sidata = LOADADDR(.data);

  .data :
  {
    . = ALIGN(4);
    _sdata = .;
    *(.data)
    *(.data*)
    . = ALIGN(4);
    _edata = .;
  } >RAM AT> FLASH

  .bss :
  {
    . = ALIGN(4);
    _sbss = .;
    __bss_start__ = _sbss;
    *(.bss)
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    _ebss = .;
    __bss_end__ = _ebss;
  } >RAM

  /* 栈/堆剩余空间做链接期检查（_estack 已在上方定义） */
  ._user_heap_stack :
  {
    . = ALIGN(8);
    PROVIDE(end = .);
    PROVIDE(_end = .);
    . = . + 0x1000;      /* 预留 4K 栈检查区 */
    . = ALIGN(8);
  } >RAM

  /DISCARD/ :
  {
    libc.a(*)
    libm.a(*)
    libgcc.a(*)
  }
}
