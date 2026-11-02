/* ============================================================================
 * test_main.c -- minimal PA2 line-test firmware (2026-10-16, link rescue
 * commissioning).  NOT part of the product firmware set.
 *
 * WHY: the UART link over PA2 -> FPGA K11 showed the FPGA's receiver seeing
 * an endless stream of 0x00 bytes at ~116 kHz -- the signature of a line held
 * LOW (the receiver "decodes" a stuck-low line as back-to-back zero bytes
 * because its stop-bit level is not checked).  This firmware settles which
 * side owns the problem with the simplest possible signal:
 *
 *   PA2 = plain push-pull GPIO toggling as fast as the loop runs
 *         (~a few hundred kHz square -- nothing in the UART stack involved)
 *   PA8/PA9 USART0 keeps printing 'T' (liveness on the CN1/COM7 port) and a
 *   blink of the GPIOC13-free... (no other peripherals: no ADC, no DWT).
 *
 * Measurement: with the FPGA debug build flashed, telemetry's `enc` field
 * (dbg_last2 = last two raw bytes on K11) should stop being 0x0000 and show
 * a MIXED/square-wave pattern if the GD32->FPGA path works electrically.
 * ========================================================================== */
#include "gd32f30x_libopt.h"

int main(void)
{
    volatile int i;

    rcu_periph_clock_enable(RCU_GPIOA);
    rcu_periph_clock_enable(RCU_USART0);

    /* CN1 debug UART (PA9 TX), 115200 8N1 -- liveness only */
    gpio_init(GPIOA, GPIO_MODE_AF_PP,       GPIO_OSPEED_MAX, GPIO_PIN_9);
    gpio_init(GPIOA, GPIO_MODE_IN_FLOATING, GPIO_OSPEED_MAX, GPIO_PIN_10);
    usart_deinit(USART0);
    usart_baudrate_set(USART0, 115200U);
    usart_word_length_set(USART0, USART_WL_8BIT);
    usart_stop_bit_set(USART0, USART_STB_1BIT);
    usart_parity_config(USART0, USART_PM_NONE);
    usart_transmit_config(USART0, USART_TRANSMIT_ENABLE);
    usart_enable(USART0);

    /* PA2: plain push-pull output, square wave by loop speed (~hundreds of kHz) */
    gpio_init(GPIOA, GPIO_MODE_OUT_PP, GPIO_OSPEED_MAX, GPIO_PIN_2);

    for (;;) {
        gpio_bit_set(GPIOA, GPIO_PIN_2);
        for (i = 0; i < 30; i++) { }
        gpio_bit_reset(GPIOA, GPIO_PIN_2);
        for (i = 0; i < 30; i++) { }

        if (usart_flag_get(USART0, USART_FLAG_TBE) != RESET) {
            usart_data_transmit(USART0, (uint8_t)'T');
        }
    }
}
