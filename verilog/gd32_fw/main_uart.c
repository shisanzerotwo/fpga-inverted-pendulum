/* ============================================================================
 * main_uart.c -- GD32F303 "remote ADC" firmware, UART-transport variant
 *                (2026-10-16 link rescue).
 *
 * WHY THIS VARIANT EXISTS: on this specific board the SPI link's SCK lane
 * (FPGA ball L12 <-> GD32 PA5) went OPEN (bench-diagnosed 2026-10-16: NSS
 * arrives at 20 kSPS while the SPI slave hardware counts ZERO clocked
 * frames).  SPI0's SCK pin is fixed in silicon, so the link moved to the
 * spare point-to-point net PA2 (GD32 USART1_TX -> FPGA ball K11) running
 * 1 Mbaud 8N1.  Everything else is IDENTICAL to main.c (the hardened SPI
 * variant): same ADC path, same glitch filter, same CN1 debug telemetry,
 * and the same frame CONTRACT consumed by arm_adc_uart.v:
 *
 *   frame = 2 UART bytes, free-running at roughly 50 kframes/s at 1 Mbaud:
 *       byte1 = {seq[3:0], adc[11:8]}     (first)
 *       byte2 = adc[7:0]                  (second)
 *   The 4-bit counter advances once per frame; the FPGA requires the
 *   counter to advance by exactly +1 (8 consecutive frames => link_ok).
 *
 *   No interrupts; everything is a tight poll in main().
 * ========================================================================== */
#include "gd32f30x_libopt.h"

/* NOTE the instance name: on GD32F30x the serial port wired to PA2/PA3 is
   called USART1 (GigaDevice's numbering is one below ST's: GD32 USART0 =
   ST USART1 on PA9/PA10, GD32 USART1 = ST USART2 on PA2/PA3).  Using
   GD32's "USART2" here would drive a different pin block entirely and leave
   PA2's AF output parked at the disabled level (bench-verified 2026-10-16:
   the line sat low / no bytes). */
#define LINK_UART       USART1

static volatile uint16_t g_adc;         /* latest 12-bit sample, right-aligned */
static uint16_t g_seq;                  /* 4-bit rolling counter               */

/* ---- link UART: USART1 on PA2 (TX, 1 Mbaud) / PA3 (RX, unused for now) ----
   PA2 is hard-wired to the FPGA ball K11 (spare net, 3.3 V). */
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

/* ============================================================================
 * ADC path -- UNCHANGED from main.c (see that file for the full history of
 * the stuck-at-0 trigger bugfix and the anti-saturation notes).
 * 2026-10-16 hardening, kept: the library's adc_calibration_enable() is two
 * unbounded while-loops; here both waits are bounded so a sick analog side
 * can never hang the boot before the link comes up.
 * ========================================================================== */
static void adc0_config(void)
{
    /* ---- chosen angle input -------------------------------------------------
       8 = PB0 / SENSOR1 (adapter board J1, U1 pin 33) -- default
       9 = PB1 / SENSOR2 (adapter board J2, U1 pin 34) -- fallback pin
       The two are otherwise identical 12-bit inputs on the same converter, so
       switching is a one-line change plus moving the pot wire J1 -> J2. */
#define ANGLE_ADC_CH   8
    gpio_init(GPIOB, GPIO_MODE_AIN, GPIO_OSPEED_2MHZ,
              (ANGLE_ADC_CH == 8) ? GPIO_PIN_0 : GPIO_PIN_1);

    /* The UART rewrite dropped this enable: rcu_adc_clock_config() only sets
       the prescaler, so without it ADC0 is unclocked and RDATA stays 0. */
    rcu_periph_clock_enable(RCU_ADC0);
    rcu_adc_clock_config(RCU_CKADC_CKAPB2_DIV6);        /* 120/6 = 20 MHz <= 40 MHz */
    adc_deinit(ADC0);
    adc_mode_config(ADC_MODE_FREE);
    adc_data_alignment_config(ADC0, ADC_DATAALIGN_RIGHT);

    /* REGULAR GROUP, CONTINUOUS (restored 2026-10-21).
       This is the path the original SPI build (main.c) ran for weeks on this
       board: the converter free-runs on the angle channel and the loop reads
       RDATA.  2026-10-17 moved the fast loop to the injected group; every
       injected build read a frozen value, while the 1 Hz scan build (which
       also keeps the regular group running) followed the pot.  Go back to the
       proven path; keep only the two 10-17 fixes: the ADC0 clock enable above
       and the longer 239.5-cycle sample time (10 k pot + slip ring + wire). */
    adc_channel_length_config(ADC0, ADC_REGULAR_CHANNEL, 1U);
    adc_regular_channel_config(ADC0, 0U, (uint8_t)ANGLE_ADC_CH,
                               ADC_SAMPLETIME_239POINT5);
    adc_external_trigger_source_config(ADC0, ADC_REGULAR_CHANNEL,
                                       ADC0_1_2_EXTTRIG_REGULAR_NONE);
    adc_external_trigger_config(ADC0, ADC_REGULAR_CHANNEL, ENABLE);
    adc_special_function_config(ADC0, ADC_CONTINUOUS_MODE, ENABLE);
    adc_enable(ADC0);
    {
        volatile uint32_t stab;                         /* ~1 ms stabilization */
        for (stab = 0; stab < 120000U; ++stab) { /* wait */ }
    }
    ADC_CTL1(ADC0) |= (uint32_t)ADC_CTL1_RSTCLB;
    {
        volatile uint32_t to = 0U;                      /* reset-calib, bounded */
        while ((ADC_CTL1(ADC0) & ADC_CTL1_RSTCLB) && (to < 2400000U)) { ++to; }
    }
    ADC_CTL1(ADC0) |= ADC_CTL1_CLB;
    {
        volatile uint32_t to = 0U;                      /* calibration, bounded */
        while ((ADC_CTL1(ADC0) & ADC_CTL1_CLB) && (to < 2400000U)) { ++to; }
    }
    /* start the free-running regular group (same as the original SPI build) */
    adc_software_trigger_enable(ADC0, ADC_REGULAR_CHANNEL);
}

/* angle sample: the regular group free-runs on ANGLE_ADC_CH, so a read is
   just RDATA -- no per-read trigger, no wait, nothing that can time out and
   freeze the value (the original main.c path, proven on this board). */
static uint16_t adc_angle_read(void)
{
    return (uint16_t)(adc_regular_data_read(ADC0) & 0x0FFFU);
}

/* ---- CN1 debug telemetry (USART0 PA9, 115200 8N1) -- unchanged, 'A<adc>'
   at 50 Hz.  This stream is what proved the app alive during the rescue. ---- */
static char    tx_buf[8];
static uint8_t tx_len, tx_pos;

static void dbg_uart_config(void)
{
    rcu_periph_clock_enable(RCU_USART0);
    gpio_init(GPIOA, GPIO_MODE_AF_PP,       GPIO_OSPEED_MAX, GPIO_PIN_9);   /* CN1.1 TX */
    gpio_init(GPIOA, GPIO_MODE_IN_FLOATING, GPIO_OSPEED_MAX, GPIO_PIN_10);  /* CN1.2 RX */
    usart_deinit(USART0);
    usart_baudrate_set(USART0, 115200U);
    usart_word_length_set(USART0, USART_WL_8BIT);
    usart_stop_bit_set(USART0, USART_STB_1BIT);
    usart_parity_config(USART0, USART_PM_NONE);
    usart_receive_config(USART0, USART_RECEIVE_ENABLE);
    usart_transmit_config(USART0, USART_TRANSMIT_ENABLE);
    usart_enable(USART0);
}

static void tick_init(void)                 /* SysTick as a 1 ms poll flag, no IRQ */
{
    SysTick->LOAD = SystemCoreClock / 1000U - 1U;
    SysTick->VAL  = 0U;
    SysTick->CTRL = SysTick_CTRL_CLKSOURCE_Msk | SysTick_CTRL_ENABLE_Msk;
}

static uint32_t tick_ms(void)               /* keep calling: polls COUNTFLAG */
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
    tx_buf[1] = (char)('0' + (v / 1000U) % 10U);    /* decimal, 0..4095 */
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
    /* Reset_Handler already called SystemInit(): 120 MHz from the 8 MHz HXTAL */
    uint32_t last_line = 0U;

    uint8_t  fr_buf[2];                     /* the 2-byte link frame          */
    uint8_t  fr_pos = 2U;                   /* 2 = idle                       */

    rcu_periph_clock_enable(RCU_GPIOA);
    rcu_periph_clock_enable(RCU_GPIOB);
    rcu_periph_clock_enable(RCU_AF);

    g_adc = 0;
    g_seq = 0;

    /* link + debug UART FIRST (hardening: a sick ADC must never take the
       link down), then the usual CN1 tick, then the (bounded) ADC init. */
    link_uart_config();
    dbg_uart_config();
    tick_init();

    adc0_config();

    for (;;) {
        uint32_t now = tick_ms();

        /* 1. freshest angle sample + wrap-aware glitch filter.
              (unchanged from main.c: >512-count step = contact glitch ->
              hold; the pot's 27-deg dead-zone wrap max<->min passes; a
              step surviving 16 samples is a sustained shift, accept it.) */
        {
            uint16_t v = adc_angle_read();
            static uint8_t adc_seen = 0U;
            static uint8_t hold     = 0U;
            uint16_t d = (v > g_adc) ? (uint16_t)(v - g_adc)
                                     : (uint16_t)(g_adc - v);
            if (!adc_seen) {
                g_adc     = v;          /* first sample after reset: accept */
                adc_seen  = 1U;
            }
            else if (d <= 512U ||
                     (g_adc > 3600U && v < 500U) ||      /* wrap down */
                     (g_adc < 500U  && v > 3600U)) {     /* wrap up */
                g_adc = v;
                hold  = 0U;
            }
            else if (++hold >= 16U) {
                g_adc = v;              /* sustained shift: real, let it through */
                hold  = 0U;
            }
            /* else: glitch -- keep the previous sample */
        }

        /* 2. link frame sender: byte1 = {seq, adc[11:8]}, byte2 = adc[7:0].
              FREE-RUN (2026-10-16): one frame is built as soon as the previous
              one has drained, so the rate is ~50 kSPS at 1 Mbaud.  The old
              DWT-cycle 20 kSPS pacing proved unreliable on this part (CYCCNT
              read-backs were not trustworthy); the FPGA side only requires
              the counter to advance by +1 per frame, at any rate.  TBE-paced,
              never blocking more than one byte (10 us at 1 Mbaud). */
        if (fr_pos >= 2U) {
            g_seq = (uint16_t)((g_seq + 1U) & 0x0FU);
            fr_buf[0] = (uint8_t)((g_seq << 4) | ((g_adc >> 8) & 0x0FU));
            fr_buf[1] = (uint8_t)(g_adc & 0x0FFU);
            fr_pos = 0U;
        }
        else if (usart_flag_get(LINK_UART, USART_FLAG_TBE) != RESET) {
            usart_data_transmit(LINK_UART, fr_buf[fr_pos++]);
        }

        /* 3. CN1 debug telemetry: a line every 100 ms, one byte per pass */
        if (tx_pos < tx_len) {
            if (usart_flag_get(USART0, USART_FLAG_TBE) != RESET) {
                usart_data_transmit(USART0, (uint8_t)tx_buf[tx_pos++]);
            }
        }
        else if ((now - last_line) >= 20U) {      /* 50 Hz */
            last_line = now;
            line_send();
        }
    }
}
