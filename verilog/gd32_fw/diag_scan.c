/* ============================================================================
 * diag_scan.c -- GD32F303 ADC channel-scan DIAGNOSTIC (2026-10-17).
 *
 * Purpose: the pot signal never changes the ADC reading even though the
 * firmware reads PB0 (ADC01_IN8) and the datasheet/config are correct.
 * This build scans several ADC channels in a fixed pattern so a single
 * flash can tell WHICH pin (if any) actually carries the pot voltage:
 *
 *   pattern: 200 ms marker (adc = 0x0FFF), then 1 s per channel
 *            in this order: 8(PB0), 9(PB1), 0(PA0), 1(PA1),
 *                           4(PA4), 5(PA5), 6(PA6), 7(PA7)
 *   cycle length = 0.2 + 8*1.0 = 8.2 s.  Markers delimit cycles.
 *
 * PA2/PA3 are deliberately NOT scanned: they are the 1 Mbaud link UART
 * (USART1 TX/RX); configuring them analog would kill the telemetry link.
 *
 * Frame contract to the FPGA is unchanged ({seq4|adc[11:8]}, adc[7:0]);
 * the FPGA is in STOP/brake, so the scanning adc does not drive anything.
 * ========================================================================== */
#include "gd32f30x_libopt.h"

#define LINK_UART       USART1

static volatile uint16_t g_adc;         /* latest scan value, right-aligned */
static uint16_t g_seq;                  /* 4-bit rolling counter            */

/* ---- link UART: PA2 (TX, 1 Mbaud) / PA3 (RX) ---- */
static void link_uart_config(void)
{
    rcu_periph_clock_enable(RCU_USART1);
    gpio_init(GPIOA, GPIO_MODE_AF_PP,       GPIO_OSPEED_MAX, GPIO_PIN_2);
    gpio_init(GPIOA, GPIO_MODE_IN_FLOATING, GPIO_OSPEED_MAX, GPIO_PIN_3);
    usart_deinit(LINK_UART);
    usart_baudrate_set(LINK_UART, 1000000U);
    usart_word_length_set(LINK_UART, USART_WL_8BIT);
    usart_stop_bit_set(LINK_UART, USART_STB_1BIT);
    usart_parity_config(LINK_UART, USART_PM_NONE);
    usart_receive_config(LINK_UART, USART_RECEIVE_ENABLE);
    usart_transmit_config(LINK_UART, USART_TRANSMIT_ENABLE);
    usart_enable(LINK_UART);
}

/* ---- ADC0: regular channel 8 kept as before; injected channel used for scan ---- */
static void adc0_config(void)
{
    gpio_init(GPIOB, GPIO_MODE_AIN, GPIO_OSPEED_2MHZ, GPIO_PIN_0);

    rcu_periph_clock_enable(RCU_ADC0);
    rcu_adc_clock_config(RCU_CKADC_CKAPB2_DIV6);
    adc_deinit(ADC0);
    adc_mode_config(ADC_MODE_FREE);
    adc_data_alignment_config(ADC0, ADC_DATAALIGN_RIGHT);
    adc_channel_length_config(ADC0, ADC_REGULAR_CHANNEL, 1U);
    adc_regular_channel_config(ADC0, 0U, ADC_CHANNEL_8, ADC_SAMPLETIME_71POINT5);
    adc_external_trigger_source_config(ADC0, ADC_REGULAR_CHANNEL,
                                       ADC0_1_2_EXTTRIG_REGULAR_NONE);
    adc_external_trigger_config(ADC0, ADC_REGULAR_CHANNEL, ENABLE);
    adc_external_trigger_source_config(ADC0, ADC_INSERTED_CHANNEL,
                                       ADC0_1_2_EXTTRIG_INSERTED_NONE);
    adc_external_trigger_config(ADC0, ADC_INSERTED_CHANNEL, ENABLE);
    adc_special_function_config(ADC0, ADC_CONTINUOUS_MODE, ENABLE);
    adc_tempsensor_vrefint_enable();            /* ch16/17 self-check channels */
    adc_enable(ADC0);
    {
        volatile uint32_t stab;
        for (stab = 0; stab < 120000U; ++stab) { /* ~1 ms */ }
    }
    ADC_CTL1(ADC0) |= (uint32_t)ADC_CTL1_RSTCLB;
    {
        volatile uint32_t to = 0U;
        while ((ADC_CTL1(ADC0) & ADC_CTL1_RSTCLB) && (to < 2400000U)) { ++to; }
    }
    ADC_CTL1(ADC0) |= ADC_CTL1_CLB;
    {
        volatile uint32_t to = 0U;
        while ((ADC_CTL1(ADC0) & ADC_CTL1_CLB) && (to < 2400000U)) { ++to; }
    }
    adc_software_trigger_enable(ADC0, ADC_REGULAR_CHANNEL);
}

/* read one injected channel (configurable on the fly) */
static uint16_t adc_scan_read(uint8_t ch)
{
    adc_flag_clear(ADC0, ADC_FLAG_EOIC);
    adc_inserted_channel_config(ADC0, 0U, ch, ADC_SAMPLETIME_239POINT5);
    adc_software_trigger_enable(ADC0, ADC_INSERTED_CHANNEL);
    while (adc_flag_get(ADC0, ADC_FLAG_EOIC) == RESET) { }
    return (uint16_t)(adc_inserted_data_read(ADC0, 0U) & 0x0FFFU);
}

/* ---- CN1 debug telemetry (USART0 PA9, 115200) ---- */
static char    tx_buf[8];
static uint8_t tx_len, tx_pos;

static void dbg_uart_config(void)
{
    rcu_periph_clock_enable(RCU_USART0);
    gpio_init(GPIOA, GPIO_MODE_AF_PP,       GPIO_OSPEED_MAX, GPIO_PIN_9);
    gpio_init(GPIOA, GPIO_MODE_IN_FLOATING, GPIO_OSPEED_MAX, GPIO_PIN_10);
    usart_deinit(USART0);
    usart_baudrate_set(USART0, 115200U);
    usart_word_length_set(USART0, USART_WL_8BIT);
    usart_stop_bit_set(USART0, USART_STB_1BIT);
    usart_parity_config(USART0, USART_PM_NONE);
    usart_receive_config(USART0, USART_RECEIVE_ENABLE);
    usart_transmit_config(USART0, USART_TRANSMIT_ENABLE);
    usart_enable(USART0);
}

static void tick_init(void)
{
    SysTick->LOAD = SystemCoreClock / 1000U - 1U;
    SysTick->VAL  = 0U;
    SysTick->CTRL = SysTick_CTRL_CLKSOURCE_Msk | SysTick_CTRL_ENABLE_Msk;
}

static uint32_t tick_ms(void)
{
    static uint32_t ms = 0U;
    if (SysTick->CTRL & SysTick_CTRL_COUNTFLAG_Msk) {
        ms++;
    }
    return ms;
}

static void line_send(void)
{
    uint16_t v = g_adc & 0x0FFFU;
    tx_buf[0] = 'A';
    tx_buf[1] = (char)('0' + (v / 1000U) % 10U);
    tx_buf[2] = (char)('0' + (v / 100U) % 10U);
    tx_buf[3] = (char)('0' + (v / 10U) % 10U);
    tx_buf[4] = (char)('0' + v % 10U);
    tx_buf[5] = '\r';
    tx_buf[6] = '\n';
    tx_len = 7U;
    tx_pos  = 0U;
}

int main(void)
{
    /* ch17 = internal Vrefint (~1.2 V, hardware-fixed) and ch16 = internal
       temperature sensor: two SELF-CHECK channels.  If they read sane while
       ch8 (PB0) is stuck, the fault is external to the chip (pot/wiring).
       If ch17/ch16 are also wrong, the ADC setup itself is broken. */
    static const uint8_t scan_ch[10] = { 8U, 9U, 17U, 16U, 0U, 1U, 4U, 5U, 6U, 7U };
    uint32_t last_line = 0U;
    uint8_t  fr_buf[2];
    uint8_t  fr_pos = 2U;

    rcu_periph_clock_enable(RCU_GPIOA);
    rcu_periph_clock_enable(RCU_GPIOB);
    rcu_periph_clock_enable(RCU_AF);

    g_adc = 0;
    g_seq = 0;

    link_uart_config();
    dbg_uart_config();
    tick_init();
    adc0_config();

    {
        uint8_t  scan_idx = 10U;            /* 10 = marker state */
        uint32_t last_scan = 0U;

        for (;;) {
            uint32_t now = tick_ms();

            /* 1. scan pattern: 200 ms marker then 1 s per channel */
            {
                uint32_t dwell = (scan_idx >= 10U) ? 200U : 1000U;
                if ((now - last_scan) >= dwell) {
                    last_scan = now;
                    if (scan_idx >= 10U) {
                        g_adc = 0x0FFFU;    /* marker */
                        scan_idx = 0U;
                    } else {
                        g_adc = adc_scan_read(scan_ch[scan_idx]);
                        scan_idx++;
                    }
                }
            }

            /* 2. link frame sender (same contract as main_uart.c) */
            if (fr_pos >= 2U) {
                g_seq = (uint16_t)((g_seq + 1U) & 0x0FU);
                fr_buf[0] = (uint8_t)((g_seq << 4) | ((g_adc >> 8) & 0x0FU));
                fr_buf[1] = (uint8_t)(g_adc & 0x0FFU);
                fr_pos = 0U;
            }
            else if (usart_flag_get(LINK_UART, USART_FLAG_TBE) != RESET) {
                usart_data_transmit(LINK_UART, fr_buf[fr_pos++]);
            }

            /* 3. CN1 debug telemetry */
            if (tx_pos < tx_len) {
                if (usart_flag_get(USART0, USART_FLAG_TBE) != RESET) {
                    usart_data_transmit(USART0, (uint8_t)tx_buf[tx_pos++]);
                }
            }
            else if ((now - last_line) >= 20U) {
                last_line = now;
                line_send();
            }
        }
    }
}
