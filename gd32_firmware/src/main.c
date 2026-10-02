// GD32F303 摆角 ADC 采样 + 原码转发（FPGA 倒立摆的采集前置）。
//
// 合规分工（项目红线）：本固件只做"采样 + 原码转发"，不做任何滤波、角度换算、判断或控制。
// 滤波、角度换算、双环 PID、能量起摆、PWM 全部在 FPGA 内实现。源码留档作为"MCU 无算法"佐证。
//
// 链路：电位器 -> 排针 EX_PB0（GD32 ADC01_IN8）-> 本固件采 12bit 原码 -> USART1_TX(PA2)
//       -> FPGA K11 -> adc_bridge 收帧交给控制律。
//
// 帧协议（与 fpga/pendulum/src/adc_bridge.v 一致）：1 Mbaud、8N1、每帧 4 字节、1 kHz
//   [0] 0xA5  帧同步
//   [1] {4'b0, code[11:8]}   高 4 位必须为 0（接收侧据此判错位）
//   [2] code[7:0]
//   [3] 0xA5 ^ [1] ^ [2]     XOR 校验
//
// 节拍：TIMER2 溢出中断 1 kHz 触发一次采样 + 发送（TIMER2 与 ADC01_IN8 复用 PB0，仅用其定时功能）。
// 时钟：GD32F303 常规配置 120 MHz（CK_APB2 = 120 MHz），USART1 挂在 APB1（60 MHz）。

#include "gd32f30x.h"

#define CENTER_NOT_USED   0        // 本固件不涉及中心值/角度换算，故意不定义

#define ADC_CHANNEL_POT   ADC_CHANNEL_8      // PB0 = ADC01_IN8
#define UART_BAUD         1000000U           // 1 Mbaud
#define FRAME_SYNC        0xA5U

static void rcu_config(void);
static void gpio_config(void);
static void adc_config(void);
static void usart_config(void);
static void timer_config(void);
static uint16_t adc_sample(void);
static void     frame_send(uint16_t code);

// 1 kHz 节拍：每拍采一次并转发一帧
void TIMER2_IRQHandler(void)
{
    if (SET == timer_interrupt_flag_get(TIMER2, TIMER_INT_FLAG_UP)) {
        timer_interrupt_flag_clear(TIMER2, TIMER_INT_FLAG_UP);
        frame_send(adc_sample());
    }
}

int main(void)
{
    rcu_config();
    gpio_config();
    adc_config();
    usart_config();
    timer_config();

    while (1) {
        /* 空转：采样与转发全部在 TIMER2 中断里完成，主循环不承载算法 */
    }
}

static void rcu_config(void)
{
    rcu_periph_clock_enable(RCU_GPIOB);
    rcu_periph_clock_enable(RCU_GPIOA);
    rcu_periph_clock_enable(RCU_ADC0);
    rcu_periph_clock_enable(RCU_USART1);
    rcu_periph_clock_enable(RCU_TIMER2);
    /* ADC 时钟不得超过 14 MHz：APB2 = 120 MHz，/8 = 15 MHz 仍偏高，取 /12 = 10 MHz */
    rcu_adc_clock_config(RCU_CKADC_CKAPB2_DIV12);
}

static void gpio_config(void)
{
    /* PB0：模拟输入（ADC01_IN8，接摆角电位器） */
    gpio_init(GPIOB, GPIO_MODE_AIN, GPIO_OSPEED_10MHZ, GPIO_PIN_0);

    /* PA2：复用推挽输出，USART1_TX -> FPGA K11
     * 注意：USART1_TX 的默认复用脚是 PA2（与 ADC 无关），此处只配 TX，RX 不需要。 */
    gpio_init(GPIOA, GPIO_MODE_AF_PP, GPIO_OSPEED_50MHZ, GPIO_PIN_2);
}

static void adc_config(void)
{
    adc_mode_config(ADC_MODE_FREE);
    adc_data_alignment_config(ADC0, ADC_DATAALIGN_RIGHT);
    adc_channel_length_config(ADC0, ADC_REGULAR_CHANNEL, 1U);
    adc_external_trigger_source_config(ADC0, ADC_REGULAR_CHANNEL, ADC0_1_2_EXTTRIG_REGULAR_NONE);
    adc_external_trigger_config(ADC0, ADC_REGULAR_CHANNEL, ENABLE);

    adc_enable(ADC0);
    /* 上电后需延时再校准（官方例程给 1ms） */
    {
        volatile uint32_t i;
        for (i = 0; i < 120000U; i++) { __NOP(); }
    }
    adc_calibration_enable(ADC0);
}

static uint16_t adc_sample(void)
{
    /* 采样时间取较长档（239.5 周期）：电位器输出阻抗高，短采样时间会失真 */
    adc_regular_channel_config(ADC0, 0U, ADC_CHANNEL_POT, ADC_SAMPLETIME_239POINT5);
    adc_software_trigger_enable(ADC0, ADC_REGULAR_CHANNEL);
    while (!adc_flag_get(ADC0, ADC_FLAG_EOC)) { }
    adc_flag_clear(ADC0, ADC_FLAG_EOC);
    return (uint16_t)(adc_regular_data_read(ADC0) & 0x0FFFU);   // 只要 12bit 原码
}

static void usart_config(void)
{
    usart_deinit(USART1);
    usart_baudrate_set(USART1, UART_BAUD);
    usart_word_length_set(USART1, USART_WL_8BIT);
    usart_stop_bit_set(USART1, USART_STB_1BIT);
    usart_parity_config(USART1, USART_PM_NONE);
    usart_transmit_config(USART1, USART_TRANSMIT_ENABLE);
    usart_enable(USART1);
}

static void timer_config(void)
{
    /* TIMER2 提供 1 kHz 节拍（仅用定时功能；其 CH2 虽与 PB0 复用，但本工程不启用该通道） */
    timer_parameter_struct tp;
    timer_deinit(TIMER2);
    timer_struct_para_init(&tp);
    tp.prescaler         = 12000U - 1U;   /* 120 MHz / 12000 = 10 kHz */
    tp.period            = 10U - 1U;      /* 10 kHz / 10 = 1 kHz */
    tp.clockdivision     = TIMER_CKDIV_DIV1;
    tp.counterdirection  = TIMER_COUNT_UP;
    tp.alignedmode       = TIMER_COUNTER_EDGE;
    tp.repetitioncounter = 0U;
    timer_init(TIMER2, &tp);

    timer_interrupt_enable(TIMER2, TIMER_INT_UP);
    nvic_irq_enable(TIMER2_IRQn, 1U, 0U);
    timer_enable(TIMER2);
}

static void frame_send(uint16_t code)
{
    uint8_t hi = (uint8_t)((code >> 8) & 0x0FU);            /* 高 4 位恒 0（协议不变量） */
    uint8_t lo = (uint8_t)(code & 0xFFU);
    uint8_t chk = (uint8_t)(FRAME_SYNC ^ hi ^ lo);

    usart_data_transmit(USART1, FRAME_SYNC);
    while (RESET == usart_flag_get(USART1, USART_FLAG_TBE)) { }
    usart_data_transmit(USART1, hi);
    while (RESET == usart_flag_get(USART1, USART_FLAG_TBE)) { }
    usart_data_transmit(USART1, lo);
    while (RESET == usart_flag_get(USART1, USART_FLAG_TBE)) { }
    usart_data_transmit(USART1, chk);
    while (RESET == usart_flag_get(USART1, USART_FLAG_TBE)) { }
}
