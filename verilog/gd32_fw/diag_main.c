/* ============================================================================
 * diag_main.c -- GD32 SPI-link diagnostic firmware (2026-10-16, ZCode).
 *
 * WHY: the FPGA<->GD32 SPI link is dead while BOTH sides demonstrably run
 * (the app streams its A<adc> telemetry; the FPGA clocks its 20 kSPS poll).
 * The remaining unknown: which of the four point-to-point lanes is broken.
 *
 * v2 (this build): the GPIO pin-poller of v1 counted NSS perfectly
 * (F~19010/s) but SCK zero -- which could be a mere polling-rate artifact
 * at 6.25 MHz.  v2 therefore uses the REAL SPI0 slave peripheral, whose
 * hardware cannot miss the clock: a frame completes (RBNE) only when the
 * slave sees NSS low AND 16 SCK pulses on its own pins.  Output per second:
 *
 *      R<rbne/s> O<orerr total>\r\n
 *
 * Reading (with NSS confirmed arriving by v1):
 *      R ~ 19000..20000  -> SCK arrives and the slave works => the fault is
 *                           on the MISO (PA6) / FPGA-input side.
 *      R = 0             -> SCK (PA5) never reaches the GD32 => that lane
 *                           (FPGA ball L12 <-> PA5) is dead.
 * ========================================================================== */
#include "gd32f30x_libopt.h"

/* ---- USART0 (CN1 / DAPLink CDC), same format family as main.c ---- */
static void uart_init(void)
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

static void putc_blocking(char c)
{
    while (usart_flag_get(USART0, USART_FLAG_TBE) == RESET) { }
    usart_data_transmit(USART0, (uint8_t)c);
}

static void put_u32(uint32_t v)
{
    char b[11];
    int i = 0;
    if (v == 0U) { putc_blocking('0'); return; }
    while (v > 0U) { b[i++] = (char)('0' + (v % 10U)); v /= 10U; }
    while (i > 0) { putc_blocking(b[--i]); }
}

/* SysTick as a 1 ms poll flag, no IRQ (same as main.c) */
static void tick_init(void)
{
    SysTick->LOAD = SystemCoreClock / 1000U - 1U;
    SysTick->VAL  = 0U;
    SysTick->CTRL = SysTick_CTRL_CLKSOURCE_Msk | SysTick_CTRL_ENABLE_Msk;
}

/* same pin roles as the real firmware: PA4/5/7 inputs (NSS/SCK/MOSI),
   PA6 = AF push-pull (MISO out) */
static void link_gpio_config(void)
{
    gpio_init(GPIOA, GPIO_MODE_IN_FLOATING, GPIO_OSPEED_MAX, GPIO_PIN_4);
    gpio_init(GPIOA, GPIO_MODE_IN_FLOATING, GPIO_OSPEED_MAX, GPIO_PIN_5);
    gpio_init(GPIOA, GPIO_MODE_AF_PP,       GPIO_OSPEED_MAX, GPIO_PIN_6);
    gpio_init(GPIOA, GPIO_MODE_IN_FLOATING, GPIO_OSPEED_MAX, GPIO_PIN_7);
}

static void link_spi_config(void)
{
    spi_parameter_struct sp;
    spi_i2s_deinit(SPI0);
    spi_struct_para_init(&sp);
    sp.device_mode          = SPI_SLAVE;
    sp.trans_mode           = SPI_TRANSMODE_FULLDUPLEX;
    sp.frame_size           = SPI_FRAMESIZE_16BIT;
    sp.nss                  = SPI_NSS_HARD;
    sp.endian               = SPI_ENDIAN_MSB;
    sp.clock_polarity_phase = SPI_CK_PL_LOW_PH_1EDGE;
    sp.prescale             = SPI_PSC_2;
    spi_init(SPI0, &sp);
    spi_enable(SPI0);
}

int main(void)
{
    uint32_t last = 0U;
    uint32_t ms_now = 0U;
    uint32_t r_cnt = 0U, o_cnt = 0U, tx = 0x0123U;

    rcu_periph_clock_enable(RCU_GPIOA);
    rcu_periph_clock_enable(RCU_GPIOB);
    rcu_periph_clock_enable(RCU_AF);
    rcu_periph_clock_enable(RCU_SPI0);

    link_gpio_config();
    link_spi_config();
    uart_init();
    tick_init();

    for (;;) {
        /* the hardware catches every clocked frame; RBNE = NSS low + 16 SCK */
        if (spi_i2s_flag_get(SPI0, SPI_FLAG_RBNE) != RESET) {
            (void)spi_i2s_data_receive(SPI0);
            r_cnt++;
            tx = (tx + 0x1000U) & 0xF000U;      /* rolling nibble, harmless */
            spi_i2s_data_transmit(SPI0, (uint16_t)(tx | 0x0123U));
        }
        if (spi_i2s_flag_get(SPI0, SPI_FLAG_RXORERR) != RESET) {
            (void)spi_i2s_data_receive(SPI0);
            (void)SPI_STAT(SPI0);
            o_cnt++;
        }

        /* 1 s report window (COUNTFLAG poll, no IRQ) */
        if (SysTick->CTRL & SysTick_CTRL_COUNTFLAG_Msk) {
            ms_now++;
            if (ms_now - last >= 1000U) {
                last = ms_now;
                putc_blocking('R'); put_u32(r_cnt);
                putc_blocking('O'); put_u32(o_cnt);
                putc_blocking('\r'); putc_blocking('\n');
                r_cnt = 0U;
            }
        }
    }
}
