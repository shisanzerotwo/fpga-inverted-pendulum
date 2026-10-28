// Gowin timing constraint file
// Board oscillator on T7 is 50 MHz -> 20 ns period, 50% duty -> edges at 0 / 10 ns
create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports {sys_clk}]
