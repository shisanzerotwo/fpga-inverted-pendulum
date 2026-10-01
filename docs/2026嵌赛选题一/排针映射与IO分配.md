# 排针映射与 IO 分配（M1 进行中）

> 状态：**网络清单已提取（原理图源 ✓）+ 丝印对照机制已确认；物理 pin 序待实物核对**（板卡 2026-09-30 到货后第一步）。
> 双证纪律（主文档 §1.5-3）：原理图网络名 ✓ + 实物丝印 ✓ 之后才能写进 .cst。

## 一、数据来源与提取方法

- 来源：`逻辑派FPGA-G1/06逻辑派硬件素材/extracted/01.素材/ProPrj_ProDoc_逻辑派.epro`（zip）→ `SHEET/*/[1..11].esch`（嘉立创EDA专业版原理图，行式 JSON）。
- 网络名格式：`["ATTR", id, <wire>, "NET", <名字>, x, y, ...]`。**扩展 IO 网络一律 `EX_` 前缀，名字自带 FPGA 球号**（如 `EX_IOT54A_P15` → 球 P15）。
- 1.esch 为管脚分配总览页：扩展 IO、板载功能（LED/数码管/GD32 口/DDR3/JTAG/FLASH/配置）网络全在此页。

## 二、映射机制（已确认）

**排针实物丝印 = FPGA 球号 = EX_ 网络名后缀**。

框图下排丝印样本（已逐一对上网络清单）：`J15 C16 J16 J14 F16 F14 H11 J13 … E16 D15 C16 E14 D16 B14 B13 K14 B11 A12 C12 B12 A11 C11 A9 C9 D10 E10 M11 P11 P12 T11 R14 3V3 5V GND`。

→ 明天到货后：**读排针丝印（球号）→ 查下表得网络名/信号**，无需逐脚通断测量（万用表抽查 2~3 脚复核即可）。

## 三、扩展 IO 网络清单（原理图提取，按 bank 分组）

物理排针信号为混合 bank 排布，**位置顺序以实物丝印为准**，下表仅按 bank 归类。

### IOT bank（29 个）

| 球号 | 网络名 | | 球号 | 网络名 |
|---|---|---|---|---|
| P15 | EX_IOT54A_P15 | | J15 | EX_IOT24A_J15 |
| R16 | EX_IOT54B_R16 | | J14 | EX_IOT22B_J14 |
| K12 | EX_IOT36B_K12 | | J16 | EX_IOT22A_J16 |
| K13 | EX_IOT36A_K13 | | G14 | EX_IOT13B_G14 |
| N14 | EX_IOT52B_N14 | | G15 | EX_IOT13A_G15 |
| N16 | EX_IOT52A_N16 | | G16 | EX_IOT16A_G16 |
| P16 | EX_IOT48B_P16 | | H15 | EX_IOT16B_H15 |
| N15 | EX_IOT48A_N15 | | F16 | EX_IOT9B_F16 |
| K15 | EX_IOT30B_K15 | | F14 | EX_IOT9A_F14 |
| K14 | EX_IOT30A_K14 | | F15 | EX_IOT6B_F15 |
| H11 | EX_IOT27A_H11 | | E16 | EX_IOT6A_E16 |
| J13 | EX_IOT27B_J13 | | D15 | EX_IOT5B_D15 |
| | | | C16 | EX_IOT5A_C16 |
| | | | E14 | EX_IOT4B_E14 |
| | | | D16 | EX_IOT4A_D16 |
| | | | L15 | EX_IOT2A_L15 |

### IOR bank（23 个）

| 球号 | 网络名 | | 球号 | 网络名 |
|---|---|---|---|---|
| T6 | EX_IOR53B_T6 | | T13 | EX_IOR8B_T13 |
| T8 | EX_IOR42B_T8 | | P12 | EX_IOR8A_P12 |
| T9 | EX_IOR38A_T9 | | R14 | EX_IOR7B_R14 |
| R8 | EX_IOR29B_R8 | | T15 | EX_IOR7A_T15 |
| N7 | EX_IOR47B_N7 | | M11 | EX_IOR27B_M11 |
| M7 | EX_IOR47A_M7 | | N10 | EX_IOR27A_N10 |
| L8 | EX_IOR44B_L8 | | P11 | EX_IOR24B_P11 |
| M6 | EX_IOR44A_M6 | | T11 | EX_IOR24A_T11 |
| P8 | EX_IOR42A_P8 | | L9 | EX_IOR40B_L9 |
| N8 | EX_IOR40A_N8 | | P9 | EX_IOR38B_P9 |
| M8 | EX_IOR36A_M8 | | N9 | EX_IOR36B_N9 |
| P6 | EX_IOR53A_P6 | | | |

### IOL bank（14 个）

| 球号 | 网络名 | | 球号 | 网络名 |
|---|---|---|---|---|
| E10 | EX_IOL17B_E10 | | A15 | EX_IOL2B_A15 |
| A14 | EX_IOL8B_A14 | | B14 | EX_IOL2A_B14 |
| B13 | EX_IOL8A_B13 | | C9 | EX_IOL27B_C9 |
| B12 | EX_IOL7B_B12 | | A9 | EX_IOL27A_A9 |
| C12 | EX_IOL7A_C12 | | D10 | EX_IOL17A_D10 |
| C11 | EX_IOL15B_C11 | | A11 | EX_IOL15A_A11 |
| A12 | EX_IOL13B_A12 | | B11 | EX_IOL13A_B11 |

合计 66 个 EX_ 网络（官方口径 65 IO，差额待实物核对，或含 1 个复用脚）。

## 四、板内占用清单（必须避开）

| 功能 | 球号 |
|---|---|
| 系统时钟 50MHz | T7 |
| RGB LED ×2 | R9 / C10 / R7 / N6 / T10 / P7 |
| 用户按键 ×2 | D11 / F10 |
| 板载 UART（USB-Serial） | F12（TX）/ F13（RX） |
| 数码管 seg[0..7] | G13 / H16 / H12 / H13 / H14 / G12 / G11 / L14 |
| GD32 通信口（硬件直连，禁用） | J12 / J11 / K11 / D14 / E15 / L12 / L13 / L16 |
| 配置/模式 | B10（RECFG）/ A13（READY）/ C13（DONE）/ M16 / B16 / C15（MODE） |
| FLASH SPI | L10 / M9 / R10 / P10 |
| JTAG | TDO / TMS / TCK / TDI |
| DDR3 / HDMI / TFT | 其余全部，不外引 |

## 五、本项目拟用 IO 初选（待实物核对后定稿 .cst）

选脚原则：避开上表全部占用；信号同区集中，接线短；首版不占用 IOL bank（留给阶段 5 扩展）。

| 信号 | 方向 | 拟用球号 | 网络 |
|---|---|---|---|
| PWMA（20kHz PWM） | → | G15 | EX_IOT13A_G15 |
| AIN1 | → | G14 | EX_IOT13B_G14 |
| AIN2 | → | G16 | EX_IOT16A_G16 |
| EA（编码器 A） | ← | J15 | EX_IOT24A_J15 |
| EB（编码器 B） | ← | K16 | EX_IOT24B_K16 |
| ADC_CS | → | J16 | EX_IOT22A_J16 |
| ADC_SCK | → | J14 | EX_IOT22B_J14 |
| ADC_MOSI（DIN） | → | H15 | EX_IOT16B_H15 |
| ADC_MISO（DOUT） | ← | F14 | EX_IOT9A_F14 |
| K1~K4（套件按键，可选） | ← | N10 / M11 / P11 / T11 | EX_IOR27A/B、EX_IOR24B/A |
| UART 调试 | 双向 | F12 / F13 | 板载 USB-Serial，无需接线 |

## 六、明日实物核对步骤（到货 D1，并入到货 checklist）

1. 目视确认 4 条排针丝印（球号）与 H1~H4 位置对应关系，拍照存档。
2. 抽查 3 脚万用表通断复核（建议：G15、J15、T7 附近 GND）。
3. 按上表接线；若丝印与清单冲突，**以丝印为准**并回查 .esch 记录差异。
4. 核对通过后：球号 → GPIO 约束写入 `pendulum.cst`（M1 验收）。

## 七、M1 软件侧验收记录（2026-10-01）

| 核对项 | 结果 | 证据 |
|---|---|---|
| 13 个拟用扩展脚均在原理图 EX_ 网络内 | ✅ | 脚本正则提取 .esch 共 66 个 EX_ 网络，13 脚全部命中（**K16=EX_IOT24B_K16 在 1.esch/3.esch 中存在**，§三表格漏列，EX 总数 66 才完整） |
| 与板内占用清单（§四）无交集 | ✅ | 脚本集合求交为空 |
| 官方 `立创逻辑派FPGA_G1_IO.cst` / `引脚分配表` | ⚠️ 仅覆盖板载功能（时钟/LED/按键/UART/数码管），**不含扩展排针**，扩展脚无官方第二来源 | 官方 cst 共 71 条 IO_LOC，无 G15/J15 等 |
| `gw_sh build.tcl` 一键综合 + 布局布线 + 比特流 | ✅ 0 error，逻辑 29/20736（<1%） | `pendulum.pin.html` 19 个抽查信号全部落在预期球号 |
| 实物丝印核对 | ⏳ **待 D1**（你持板核对 §六第 1~3 步） | .cst 中 `[待丝印]` 标记在核对后删除 |

**三源对照现状**：原理图 ✓、Gowin 工具链落位 ✓、实物丝印 ⏳。扩展脚因官方资料不覆盖，第二来源改为"工具链落位 + 实物丝印"。

---
*2026-09-29 由原理图 .esch 提取 + 功能框图丝印对照生成；2026-10-01 追加 M1 软件侧验收；下次更新：实物核对。*
