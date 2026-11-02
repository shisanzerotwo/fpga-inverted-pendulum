/* ============================================================================
 * test2_main.c -- USART2 transmit bisection firmware (2026-10-16, link
 *                 rescue commissioning).  NOT part of the product set.
 *
 * WHY: the PA2 -> K11 -> FPGA path is PROVEN alive (the GPIO-square test
 * firmware's waveform reached the FPGA).  The remaining suspect split:
 *   (a) the USART2 peripheral configuration itself (shared by main_uart.c),
 *   (b) main_uart.c's sender logic on top of it (frame buffers, DWT pacing).
 * This firmware exercises (a) alone: the EXACT same USART2 init as
 * main_uart.c, then 'U' (0x55, a clean alternating pattern) back-to-back,
 * plus 'T' on USART0 (CN1) for liveness.
 *
 * Measurement (FPGA debug build): telemetry `enc` (dbg_last2 on K11) should
 * show 0x55/0x55-ish bytes if the USART2 path works; if it stays 0x0000 or
 * differs from the square-wave signature, the USART2 init is at fault.
 * ========================================================================== */
#include "gd32f30x_libopt.h"

int main(void)
{
    rcu_periph_clock_enable(RCU_GPIOA);
    rcu_periph_clock_enable(RCU_USART0);
    rcu_periph_clock_enable(RCU_USART2);

    /* CN1 debug UART (PA9 TX), 115200 8N1 -- liveness */
    gpio_init(GPIOA, GPIO_MODE_AF_PP,       GPIO_OSPEED_MAX, GPIO_PIN_9);
    gpio_init(GPIOA, GPIO_MODE_IN_FLOATING, GPIO_OSPEED_MAX, GPIO_PIN_10);
    usart_deinit(USART0);
    usart_baudrate_set(USART0, 115200U);
    usart_word_length_set(USART0, USART_WL_8BIT);
    usart_stop_bit_set(USART0, USART_STB_1BIT);
    usart_parity_config(USART0, USART_PM_NONE);
    usart_transmit_config(USART0, USART_TRANSMIT_ENABLE);
    usart_enable(USART0);

    /* PA2 = USART2_TX: the EXACT init sequence from main_uart.c */
    gpio_init(GPIOA, GPIO_MODE_AF_PP,       GPIO_OSPEED_MAX, GPIO_PIN_2);
    gpio_init(GPIOA, GPIO_MODE_IN_FLOATING, GPIO_OSPEED_MAX, GPIO_PIN_3);
    usart_deinit(USART2);
    usart_baudrate_set(USART2, 1000000U);
    usart_word_length_set(USART2, USART_WL_8BIT);
    usart_stop_bit_set(USART2, USART_STB_1BIT);
    usart_parity_config(USART2, USART_PM_NONE);
    usart_receive_config(USART2, USART_RECEIVE_ENABLE);
    usart_transmit_config(USART2, USART_TRANSMIT_ENABLE);
    usart_enable(USART2);

    for (;;) {
        if (usart_flag_get(USART2, USART_FLAG_TBE) != RESET) {
            usart_data_transmit(USART2, (uint8_t)'U');   /* 0x55 */
        }
        if (usart_flag_get(USART0, USART_FLAG_TBE) != RESET) {
            usart_data_transmit(USART0, (uint8_t)'T');
        }
    }
}
