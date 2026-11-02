/* ============================================================================
 * main.c -- GD32F303CBT6 firmware: the on-board "remote ADC" for the FPGA.
 *
 * Contract (must match fpga_project/src/arm_adc_link.v exactly):
 *   - FPGA is SPI master, GD32 is SPI0 slave, mode 0 (CKPL=0, CKPH=0), MSB first.
 *   - One frame = 16 clocks, SCK 6.25 MHz, frames start every 50 us (20 kSPS).
 *   - Frame = [15:12] 4-bit rolling counter  +  [11:0] 12-bit ADC (PB0, pot).
 *   - The FPGA requires the counter to advance by EXACTLY +1 per frame
 *     (8 consecutive good frames => link_ok).  The counter therefore advances
 *     on the RBNE event (one RBNE = one finished frame), NOT on a local timer:
 *     the two chips run on independent crystals and any free-running scheme
 *     would drift apart and kill the link.
 *   - SPI works in 16-bit frame mode (SPI_CTL0.FF16), so one frame = one
 *     SPI_DATA write.  The next frame is loaded while the bus is idle
 *     (NSS high), which the master guarantees to be ~49 us long.
 *
 * No interrupts are used: everything is a tight poll in main().  The loop
 * period is far below both the 50 us poll gap and the 2.56 us frame time.
 * ========================================================================== */
#include "gd32f30x_libopt.h"

#define LINK_SPI        SPI0
#define LINK_NSS_PORT   GPIOA
#define LINK_NSS_PIN    GPIO_PIN_4

static volatile uint16_t g_adc;         /* latest 12-bit sample, right-aligned */
static uint16_t g_seq;                  /* 4-bit rolling counter               */
static uint8_t  g_need_load;            /* SPI_DATA must be (re)loaded         */

static void link_gpio_config(void)
{
    /* GD32 PA4=SPI_NSS(in) PA5=SCK(in) PA6=MISO(out,AF) PA7=MOSI(in),
       hard-wired to the FPGA balls E15 / L12 / L13 / L16 (bank 1, 3.3 V). */
    gpio_init(GPIOA, GPIO_MODE_IN_FLOATING, GPIO_OSPEED_MAX, GPIO_PIN_4);
    gpio_init(GPIOA, GPIO_MODE_IN_FLOATING, GPIO_OSPEED_MAX, GPIO_PIN_5);
    gpio_init(GPIOA, GPIO_MODE_AF_PP,       GPIO_OSPEED_MAX, GPIO_PIN_6);
    gpio_init(GPIOA, GPIO_MODE_IN_FLOATING, GPIO_OSPEED_MAX, GPIO_PIN_7);
}

static void link_spi_config(void)
{
    spi_parameter_struct sp;

    spi_i2s_deinit(LINK_SPI);
    spi_struct_para_init(&sp);
    sp.device_mode          = SPI_SLAVE;
    sp.trans_mode           = SPI_TRANSMODE_FULLDUPLEX;
    sp.frame_size           = SPI_FRAMESIZE_16BIT;      /* one frame = one DATA write */
    sp.nss                  = SPI_NSS_HARD;             /* FPGA drives NSS            */
    sp.endian               = SPI_ENDIAN_MSB;
    sp.clock_polarity_phase = SPI_CK_PL_LOW_PH_1EDGE;   /* mode 0                     */
    sp.prescale             = SPI_PSC_2;                /* unused in slave mode       */
    spi_init(LINK_SPI, &sp);
    spi_enable(LINK_SPI);
}

static void adc0_config(void)
{
    /* Angle potentiometer on PB0 = ADC0/ADC1 channel 8 (ADC01_IN8).
       Continuous conversion keeps ADC0_RDATA always fresh; the FPGA-side
       filter/decimation does the real signal processing.

       BUGFIX (bench-verified stuck-at-0): with adc_external_trigger_config
       DISABLE, the GD32F30x ignores SWRCST -- the ADC never converts and
       RDATA stays 0 forever.  The official polling example instead sets the
       trigger SOURCE to NONE and ENABLES trigger detection, then starts with
       a software trigger.  Do exactly that. */
    gpio_init(GPIOB, GPIO_MODE_AIN, GPIO_OSPEED_2MHZ, GPIO_PIN_0);

    rcu_adc_clock_config(RCU_CKADC_CKAPB2_DIV6);        /* 120/6 = 20 MHz <= 40 MHz */
    adc_deinit(ADC0);
    adc_mode_config(ADC_MODE_FREE);
    adc_data_alignment_config(ADC0, ADC_DATAALIGN_RIGHT);
    adc_channel_length_config(ADC0, ADC_REGULAR_CHANNEL, 1U);
    adc_regular_channel_config(ADC0, 0U, ADC_CHANNEL_8, ADC_SAMPLETIME_71POINT5);
    adc_external_trigger_source_config(ADC0, ADC_REGULAR_CHANNEL,
                                       ADC0_1_2_EXTTRIG_REGULAR_NONE);
    adc_external_trigger_config(ADC0, ADC_REGULAR_CHANNEL, ENABLE);
    adc_special_function_config(ADC0, ADC_CONTINUOUS_MODE, ENABLE);
    adc_enable(ADC0);
    {
        volatile uint32_t stab;                         /* ~1 ms stabilization */
        for (stab = 0; stab < 120000U; ++stab) { /* wait */ }
    }
    /* BOUNDED calibration (2026-10-16 hardening).  The library's
       adc_calibration_enable() is two unbounded while-loops on RSTCLB/CLB:
       if the analog side is sick those bits never clear and the firmware
       spins HERE forever -- i.e. BEFORE link_spi_config() ever ran, the SPI
       slave stays disabled and the FPGA link is dead for good (bench
       2026-10-16: MISO held static high by exactly this boot hang).  Same
       register sequence, both waits bounded; on timeout we run the
       converter uncalibrated (values may be slightly off -- the link
       lives, which is what matters). */
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
    adc_software_trigger_enable(ADC0, ADC_REGULAR_CHANNEL);
}

/* ---- bring-up telemetry: raw ADC out of CN1's USART0 (PA9, 115200 8N1).
   The board has NO USB-UART bridge chip (schematic checked), so the FPGA's
   F12/F13 UART cannot reach the PC; CN1 + a USB-TTL cable is the honest path.
   Non-blocking: at most one byte per loop pass, so the SPI frame bookkeeping
   below is never stalled.  Line = 'A' <adc hi> <mid> <lo> <seq> '1' CR LF,
   same format as the FPGA-side debug_uart.v; trailing '1' = GD32 alive. ---- */
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

    rcu_periph_clock_enable(RCU_GPIOA);
    rcu_periph_clock_enable(RCU_GPIOB);
    rcu_periph_clock_enable(RCU_AF);
    rcu_periph_clock_enable(RCU_SPI0);
    rcu_periph_clock_enable(RCU_ADC0);

    g_adc       = 0;
    g_seq       = 0;
    g_need_load = 1;

    link_gpio_config();
    /* ORDER CHANGED 2026-10-16 (hardening): the SPI link and the debug UART
       come up BEFORE the ADC.  Before this change, any ADC-init problem kept
       the SPI slave disabled forever (the FPGA saw a silent link) and also
       kept the CN1 telemetry dark, so the failure was invisible from both
       sides.  Now the link and the 'A<adc>' stream start first; a sick ADC
       only shows as frozen values, never as a dead rig. */
    link_spi_config();
    dbg_uart_config();
    tick_init();
    adc0_config();              /* bounded inside (see adc0_config) */

    for (;;) {
        uint32_t now = tick_ms();

        /* 1. freshest angle sample + wrap-aware glitch filter.
              At 20 kSPS a real angle change is <= ~3 LSB per sample, so a
              bigger step is either a contact glitch (hold last value) or the
              pot's 27-deg dead-zone wrap (max<->min, legal, let it pass).
              HOLD ESCAPE (bench 2026-10-07): with the motor PWM running the
              pot's 3V3 rail sags, shifting ALL readings by >512; holding
              forever then froze alpha while balancing (blind flight).  A
              step that survives 16 samples (0.8 ms) is a sustained shift,
              not a contact glitch -> accept it. */
        {
            uint16_t v = (uint16_t)(adc_regular_data_read(ADC0) & 0x0FFFU);
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

        /* 2. frame bookkeeping: one RBNE = one finished frame -> counter +1 */
        if (spi_i2s_flag_get(LINK_SPI, SPI_FLAG_RBNE) != RESET) {
            (void)spi_i2s_data_receive(LINK_SPI);       /* drop the master's dummy word */
            g_seq       = (uint16_t)((g_seq + 1U) & 0x0FU);
            g_need_load = 1;
        }

        /* 3. overrun recovery (only possible if we ever missed a frame):
              clear sequence per manual = read SPI_DATA, then read SPI_STAT */
        if (spi_i2s_flag_get(LINK_SPI, SPI_FLAG_RXORERR) != RESET) {
            (void)spi_i2s_data_receive(LINK_SPI);
            (void)SPI_STAT(LINK_SPI);
            g_need_load = 1;
        }

        /* 4. (re)load the next 16-bit frame, only while the bus is idle.
              TBE gate: never overwrite a pending TX buffer.
              NSS gate: never write during a frame in progress. */
        if (g_need_load &&
            (spi_i2s_flag_get(LINK_SPI, SPI_FLAG_TBE) != RESET) &&
            (gpio_input_bit_get(LINK_NSS_PORT, LINK_NSS_PIN) == SET)) {
            spi_i2s_data_transmit(LINK_SPI,
                                  (uint16_t)((g_seq << 12) | (g_adc & 0x0FFFU)));
            g_need_load = 0;
        }

        /* 5. telemetry: a line every 100 ms, one byte per pass (never stalls) */
        if (tx_pos < tx_len) {
            if (usart_flag_get(USART0, USART_FLAG_TBE) != RESET) {
                usart_data_transmit(USART0, (uint8_t)tx_buf[tx_pos++]);
            }
        }
        else if ((now - last_line) >= 20U) {      /* 50 Hz: resolve the pass-through */
            last_line = now;
            line_send();
        }
    }
}
