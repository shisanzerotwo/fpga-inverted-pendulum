/* startup_gd32f30x.s — GNU 汇编启动文件（ARM GCC 用）
 *
 * 来源：GD32F30x 固件库 V2.1.5 的 ARM(Keil) 版 startup_gd32f30x_cl.s，
 *       由 gd32_firmware/tools/gen_startup.py 自动移植。
 *       向量表与中断弱别名均为脚本生成，请勿手工编辑本文件。
 *
 * 与 Keil 版的唯一语义差异：
 *   Keil 的 __main 负责搬 .data / 清 .bss；GCC 没有 __main，
 *   故 Reset_Handler 里自行完成（用链接脚本导出的 _sidata/_sdata/_edata/_sbss/_ebss）。
 */

  .syntax unified
  .cpu cortex-m4
  .fpu softvfp
  .thumb

  .global g_pfnVectors
  .global Default_Handler

/* ================= 向量表（84 条，与官方一致）================= */
  .section .isr_vector,"a",%progbits
  .type g_pfnVectors, %object
g_pfnVectors:
  .word __initial_sp             /*  0 */
  .word Reset_Handler            /*  1 */
  .word NMI_Handler              /*  2 */
  .word HardFault_Handler        /*  3 */
  .word MemManage_Handler        /*  4 */
  .word BusFault_Handler         /*  5 */
  .word UsageFault_Handler       /*  6 */
  .word 0                    /*  7: Reserved */
  .word 0                    /*  8: Reserved */
  .word 0                    /*  9: Reserved */
  .word 0                    /* 10: Reserved */
  .word SVC_Handler              /* 11 */
  .word DebugMon_Handler         /* 12 */
  .word 0                    /* 13: Reserved */
  .word PendSV_Handler           /* 14 */
  .word SysTick_Handler          /* 15 */
  .word WWDGT_IRQHandler         /* 16 */
  .word LVD_IRQHandler           /* 17 */
  .word TAMPER_IRQHandler        /* 18 */
  .word RTC_IRQHandler           /* 19 */
  .word FMC_IRQHandler           /* 20 */
  .word RCU_CTC_IRQHandler       /* 21 */
  .word EXTI0_IRQHandler         /* 22 */
  .word EXTI1_IRQHandler         /* 23 */
  .word EXTI2_IRQHandler         /* 24 */
  .word EXTI3_IRQHandler         /* 25 */
  .word EXTI4_IRQHandler         /* 26 */
  .word DMA0_Channel0_IRQHandler /* 27 */
  .word DMA0_Channel1_IRQHandler /* 28 */
  .word DMA0_Channel2_IRQHandler /* 29 */
  .word DMA0_Channel3_IRQHandler /* 30 */
  .word DMA0_Channel4_IRQHandler /* 31 */
  .word DMA0_Channel5_IRQHandler /* 32 */
  .word DMA0_Channel6_IRQHandler /* 33 */
  .word ADC0_1_IRQHandler        /* 34 */
  .word CAN0_TX_IRQHandler       /* 35 */
  .word CAN0_RX0_IRQHandler      /* 36 */
  .word CAN0_RX1_IRQHandler      /* 37 */
  .word CAN0_EWMC_IRQHandler     /* 38 */
  .word EXTI5_9_IRQHandler       /* 39 */
  .word TIMER0_BRK_TIMER8_IRQHandler /* 40 */
  .word TIMER0_UP_TIMER9_IRQHandler /* 41 */
  .word TIMER0_TRG_CMT_TIMER10_IRQHandler /* 42 */
  .word TIMER0_Channel_IRQHandler /* 43 */
  .word TIMER1_IRQHandler        /* 44 */
  .word TIMER2_IRQHandler        /* 45 */
  .word TIMER3_IRQHandler        /* 46 */
  .word I2C0_EV_IRQHandler       /* 47 */
  .word I2C0_ER_IRQHandler       /* 48 */
  .word I2C1_EV_IRQHandler       /* 49 */
  .word I2C1_ER_IRQHandler       /* 50 */
  .word SPI0_IRQHandler          /* 51 */
  .word SPI1_IRQHandler          /* 52 */
  .word USART0_IRQHandler        /* 53 */
  .word USART1_IRQHandler        /* 54 */
  .word USART2_IRQHandler        /* 55 */
  .word EXTI10_15_IRQHandler     /* 56 */
  .word RTC_Alarm_IRQHandler     /* 57 */
  .word USBFS_WKUP_IRQHandler    /* 58 */
  .word TIMER7_BRK_TIMER11_IRQHandler /* 59 */
  .word TIMER7_UP_TIMER12_IRQHandler /* 60 */
  .word TIMER7_TRG_CMT_TIMER13_IRQHandler /* 61 */
  .word TIMER7_Channel_IRQHandler /* 62 */
  .word 0                    /* 63: Reserved */
  .word EXMC_IRQHandler          /* 64 */
  .word 0                    /* 65: Reserved */
  .word TIMER4_IRQHandler        /* 66 */
  .word SPI2_IRQHandler          /* 67 */
  .word UART3_IRQHandler         /* 68 */
  .word UART4_IRQHandler         /* 69 */
  .word TIMER5_IRQHandler        /* 70 */
  .word TIMER6_IRQHandler        /* 71 */
  .word DMA1_Channel0_IRQHandler /* 72 */
  .word DMA1_Channel1_IRQHandler /* 73 */
  .word DMA1_Channel2_IRQHandler /* 74 */
  .word DMA1_Channel3_IRQHandler /* 75 */
  .word DMA1_Channel4_IRQHandler /* 76 */
  .word ENET_IRQHandler          /* 77 */
  .word ENET_WKUP_IRQHandler     /* 78 */
  .word CAN1_TX_IRQHandler       /* 79 */
  .word CAN1_RX0_IRQHandler      /* 80 */
  .word CAN1_RX1_IRQHandler      /* 81 */
  .word CAN1_EWMC_IRQHandler     /* 82 */
  .word USBFS_IRQHandler         /* 83 */
  .size g_pfnVectors, .-g_pfnVectors

/* ================= Reset_Handler ================= */
  .section .text.Reset_Handler
  .weak Reset_Handler
  .type Reset_Handler, %function
Reset_Handler:
  /* 1) 搬 .data：Flash(_sidata) -> RAM(_sdata.._edata) */
  ldr  r0, =_sdata
  ldr  r1, =_edata
  ldr  r2, =_sidata
  movs r3, #0
  b    2f
1:
  ldr  r4, [r2, r3]
  str  r4, [r0, r3]
  adds r3, r3, #4
2:
  adds r4, r0, r3
  cmp  r4, r1
  bcc  1b
  /* 2) 清 .bss */
  ldr  r2, =_sbss
  ldr  r4, =_ebss
  movs r3, #0
  b    4f
3:
  str  r3, [r2]
  adds r2, r2, #4
4:
  cmp  r2, r4
  bcc  3b
  /* 3) 时钟/外设初始化 + main */
  bl   SystemInit
  bl   main
  /* main 不应返回；若返回则原地自陷 */
5:
  b    5b
  .size Reset_Handler, .-Reset_Handler

/* ================= 默认 handler：原地自陷 ================= */
/* 未实现的中断都落在这里；调试时停在 Default_Handler 即知是哪个异常/中断触发 */
  .section .text.Default_Handler,"ax",%progbits
Default_Handler:
  b    .
  .size Default_Handler, .-Default_Handler

/* ================= 中断弱别名（75 个）================= */
  .weak NMI_Handler
  .thumb_set NMI_Handler, Default_Handler
  .weak HardFault_Handler
  .thumb_set HardFault_Handler, Default_Handler
  .weak MemManage_Handler
  .thumb_set MemManage_Handler, Default_Handler
  .weak BusFault_Handler
  .thumb_set BusFault_Handler, Default_Handler
  .weak UsageFault_Handler
  .thumb_set UsageFault_Handler, Default_Handler
  .weak SVC_Handler
  .thumb_set SVC_Handler, Default_Handler
  .weak DebugMon_Handler
  .thumb_set DebugMon_Handler, Default_Handler
  .weak PendSV_Handler
  .thumb_set PendSV_Handler, Default_Handler
  .weak SysTick_Handler
  .thumb_set SysTick_Handler, Default_Handler
  .weak WWDGT_IRQHandler
  .thumb_set WWDGT_IRQHandler, Default_Handler
  .weak LVD_IRQHandler
  .thumb_set LVD_IRQHandler, Default_Handler
  .weak TAMPER_IRQHandler
  .thumb_set TAMPER_IRQHandler, Default_Handler
  .weak RTC_IRQHandler
  .thumb_set RTC_IRQHandler, Default_Handler
  .weak FMC_IRQHandler
  .thumb_set FMC_IRQHandler, Default_Handler
  .weak RCU_CTC_IRQHandler
  .thumb_set RCU_CTC_IRQHandler, Default_Handler
  .weak EXTI0_IRQHandler
  .thumb_set EXTI0_IRQHandler, Default_Handler
  .weak EXTI1_IRQHandler
  .thumb_set EXTI1_IRQHandler, Default_Handler
  .weak EXTI2_IRQHandler
  .thumb_set EXTI2_IRQHandler, Default_Handler
  .weak EXTI3_IRQHandler
  .thumb_set EXTI3_IRQHandler, Default_Handler
  .weak EXTI4_IRQHandler
  .thumb_set EXTI4_IRQHandler, Default_Handler
  .weak DMA0_Channel0_IRQHandler
  .thumb_set DMA0_Channel0_IRQHandler, Default_Handler
  .weak DMA0_Channel1_IRQHandler
  .thumb_set DMA0_Channel1_IRQHandler, Default_Handler
  .weak DMA0_Channel2_IRQHandler
  .thumb_set DMA0_Channel2_IRQHandler, Default_Handler
  .weak DMA0_Channel3_IRQHandler
  .thumb_set DMA0_Channel3_IRQHandler, Default_Handler
  .weak DMA0_Channel4_IRQHandler
  .thumb_set DMA0_Channel4_IRQHandler, Default_Handler
  .weak DMA0_Channel5_IRQHandler
  .thumb_set DMA0_Channel5_IRQHandler, Default_Handler
  .weak DMA0_Channel6_IRQHandler
  .thumb_set DMA0_Channel6_IRQHandler, Default_Handler
  .weak ADC0_1_IRQHandler
  .thumb_set ADC0_1_IRQHandler, Default_Handler
  .weak CAN0_TX_IRQHandler
  .thumb_set CAN0_TX_IRQHandler, Default_Handler
  .weak CAN0_RX0_IRQHandler
  .thumb_set CAN0_RX0_IRQHandler, Default_Handler
  .weak CAN0_RX1_IRQHandler
  .thumb_set CAN0_RX1_IRQHandler, Default_Handler
  .weak CAN0_EWMC_IRQHandler
  .thumb_set CAN0_EWMC_IRQHandler, Default_Handler
  .weak EXTI5_9_IRQHandler
  .thumb_set EXTI5_9_IRQHandler, Default_Handler
  .weak TIMER0_BRK_TIMER8_IRQHandler
  .thumb_set TIMER0_BRK_TIMER8_IRQHandler, Default_Handler
  .weak TIMER0_UP_TIMER9_IRQHandler
  .thumb_set TIMER0_UP_TIMER9_IRQHandler, Default_Handler
  .weak TIMER0_TRG_CMT_TIMER10_IRQHandler
  .thumb_set TIMER0_TRG_CMT_TIMER10_IRQHandler, Default_Handler
  .weak TIMER0_Channel_IRQHandler
  .thumb_set TIMER0_Channel_IRQHandler, Default_Handler
  .weak TIMER1_IRQHandler
  .thumb_set TIMER1_IRQHandler, Default_Handler
  .weak TIMER2_IRQHandler
  .thumb_set TIMER2_IRQHandler, Default_Handler
  .weak TIMER3_IRQHandler
  .thumb_set TIMER3_IRQHandler, Default_Handler
  .weak I2C0_EV_IRQHandler
  .thumb_set I2C0_EV_IRQHandler, Default_Handler
  .weak I2C0_ER_IRQHandler
  .thumb_set I2C0_ER_IRQHandler, Default_Handler
  .weak I2C1_EV_IRQHandler
  .thumb_set I2C1_EV_IRQHandler, Default_Handler
  .weak I2C1_ER_IRQHandler
  .thumb_set I2C1_ER_IRQHandler, Default_Handler
  .weak SPI0_IRQHandler
  .thumb_set SPI0_IRQHandler, Default_Handler
  .weak SPI1_IRQHandler
  .thumb_set SPI1_IRQHandler, Default_Handler
  .weak USART0_IRQHandler
  .thumb_set USART0_IRQHandler, Default_Handler
  .weak USART1_IRQHandler
  .thumb_set USART1_IRQHandler, Default_Handler
  .weak USART2_IRQHandler
  .thumb_set USART2_IRQHandler, Default_Handler
  .weak EXTI10_15_IRQHandler
  .thumb_set EXTI10_15_IRQHandler, Default_Handler
  .weak RTC_Alarm_IRQHandler
  .thumb_set RTC_Alarm_IRQHandler, Default_Handler
  .weak USBFS_WKUP_IRQHandler
  .thumb_set USBFS_WKUP_IRQHandler, Default_Handler
  .weak TIMER7_BRK_TIMER11_IRQHandler
  .thumb_set TIMER7_BRK_TIMER11_IRQHandler, Default_Handler
  .weak TIMER7_UP_TIMER12_IRQHandler
  .thumb_set TIMER7_UP_TIMER12_IRQHandler, Default_Handler
  .weak TIMER7_TRG_CMT_TIMER13_IRQHandler
  .thumb_set TIMER7_TRG_CMT_TIMER13_IRQHandler, Default_Handler
  .weak TIMER7_Channel_IRQHandler
  .thumb_set TIMER7_Channel_IRQHandler, Default_Handler
  .weak EXMC_IRQHandler
  .thumb_set EXMC_IRQHandler, Default_Handler
  .weak TIMER4_IRQHandler
  .thumb_set TIMER4_IRQHandler, Default_Handler
  .weak SPI2_IRQHandler
  .thumb_set SPI2_IRQHandler, Default_Handler
  .weak UART3_IRQHandler
  .thumb_set UART3_IRQHandler, Default_Handler
  .weak UART4_IRQHandler
  .thumb_set UART4_IRQHandler, Default_Handler
  .weak TIMER5_IRQHandler
  .thumb_set TIMER5_IRQHandler, Default_Handler
  .weak TIMER6_IRQHandler
  .thumb_set TIMER6_IRQHandler, Default_Handler
  .weak DMA1_Channel0_IRQHandler
  .thumb_set DMA1_Channel0_IRQHandler, Default_Handler
  .weak DMA1_Channel1_IRQHandler
  .thumb_set DMA1_Channel1_IRQHandler, Default_Handler
  .weak DMA1_Channel2_IRQHandler
  .thumb_set DMA1_Channel2_IRQHandler, Default_Handler
  .weak DMA1_Channel3_IRQHandler
  .thumb_set DMA1_Channel3_IRQHandler, Default_Handler
  .weak DMA1_Channel4_IRQHandler
  .thumb_set DMA1_Channel4_IRQHandler, Default_Handler
  .weak ENET_IRQHandler
  .thumb_set ENET_IRQHandler, Default_Handler
  .weak ENET_WKUP_IRQHandler
  .thumb_set ENET_WKUP_IRQHandler, Default_Handler
  .weak CAN1_TX_IRQHandler
  .thumb_set CAN1_TX_IRQHandler, Default_Handler
  .weak CAN1_RX0_IRQHandler
  .thumb_set CAN1_RX0_IRQHandler, Default_Handler
  .weak CAN1_RX1_IRQHandler
  .thumb_set CAN1_RX1_IRQHandler, Default_Handler
  .weak CAN1_EWMC_IRQHandler
  .thumb_set CAN1_EWMC_IRQHandler, Default_Handler
  .weak USBFS_IRQHandler
  .thumb_set USBFS_IRQHandler, Default_Handler

  .end
