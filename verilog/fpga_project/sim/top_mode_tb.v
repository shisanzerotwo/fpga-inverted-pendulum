`timescale 1ns/1ps
// top_mode_tb.v -- top-level checks for the runtime AUTO/MANUAL switch (2026-10-30)
//
//   1. power-up is AUTO (mode_auto = 1)
//   2. one SW press toggles to MANUAL
//   3. in MANUAL, one knob detent moves loc_target_gen.cmd by 20 counts
//   4. one more SW press returns to AUTO
//   5. in AUTO the knob is ignored (cmd does not move)
//   6. AUTO: forcing the BAL timer to 4999 fires a demo stroke -> cmd += 408
//   7. MANUAL: the same forced timer does NOT fire (demo gated)
//
// The 5 s demo timing is not simulated: demo_ms is forced via a hierarchy
// assignment so the 5000-count comparison runs in a millisecond of sim time.
module top_mode_tb;
    reg clk = 1'b0, rst_n = 1'b0;
    reg key1 = 1'b1, uart_rxd = 1'b1, uart2_rxd = 1'b1, SPI_MISO = 1'b0;
    reg [1:0] kbtn = 2'b11;
    reg EA = 1'b0, EB = 1'b0;
    reg knob_a = 1'b0, knob_b = 1'b0, knob_sw = 1'b1;
    wire uart_txd, led, led2, PWMA, AIN1, AIN2, SPI_NSS, SPI_SCK, SPI_MOSI;
    wire [7:0] seg;
    integer errors = 0;

    top dut (
        .sys_clk (clk), .rst_n (rst_n), .key1 (key1), .kbtn (kbtn),
        .knob_a (knob_a), .knob_b (knob_b), .knob_sw (knob_sw),
        .uart_rxd (uart_rxd), .uart_txd (uart_txd),
        .led (led), .led2 (led2),
        .PWMA (PWMA), .AIN1 (AIN1), .AIN2 (AIN2),
        .EA (EA), .EB (EB),
        .SPI_NSS (SPI_NSS), .SPI_SCK (SPI_SCK),
        .SPI_MOSI (SPI_MOSI), .SPI_MISO (SPI_MISO),
        .uart2_rxd (uart2_rxd),
        .seg (seg)
    );

    always #10 clk = ~clk;              // 50 MHz

    task check(input [255:0] name, input cond);
        if (cond === 1'b1) $display("  ok  %0s", name);
        else begin
            $display("FAIL %0s (mode_auto=%b cmd=%0d)", name,
                     dut.mode_auto, dut.u_ltg.cmd);
            errors = errors + 1;
        end
    endtask

    // one SW press: 5 ms low (must exceed knob_dec's DEB_MS=2 ms debounce,
    // or the press is filtered out entirely), released well inside the 50 ms
    // lock window so a second press cannot double-toggle
    task press_sw;
        begin
            @(negedge clk);
            knob_sw = 1'b0;
            repeat (150_000) @(negedge clk);     // 3 ms (> DEB_MS=2)
            knob_sw = 1'b1;
            repeat (2_750_000) @(negedge clk);   // 55 ms > SW_LOCK_MS=50
        end
    endtask

    // one knob detent in the + direction: 4 quadrature phases, each held
    // 3 ms (> DEB_MS=2), with a 30 ms gap after (> DET_MIN_MS=25)
    task detent_up;
        begin
            // phase sequence for A/B: 00 -> 10 -> 11 -> 01 -> 00
            {knob_a, knob_b} = 2'b00; repeat (125_000) @(negedge clk);
            {knob_a, knob_b} = 2'b10; repeat (125_000) @(negedge clk);
            {knob_a, knob_b} = 2'b11; repeat (125_000) @(negedge clk);
            {knob_a, knob_b} = 2'b01; repeat (125_000) @(negedge clk);
            {knob_a, knob_b} = 2'b00; repeat (1_300_000) @(negedge clk); // 30 ms
        end
    endtask

    initial begin
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        // knob_dec primes its debounce state on its FIRST 1 kHz tick (it
        // latches sw_stable from the live pin).  A press that arrives before
        // that tick is absorbed as "the idle level", so wait several ticks
        // with the button released before driving anything.
        repeat (900_000) @(negedge clk);         // 18 ms >= 18 ticks

        check("power-up is AUTO", dut.mode_auto === 1'b1);

        // ---- 2. SW -> MANUAL ----
        press_sw;
        check("SW press -> MANUAL", dut.mode_auto === 1'b0);

        // ---- 3. knob detent moves cmd by 20 in MANUAL ----
        // give the machine a running state so the tool sees a live target
        force dut.ctrl_en = 1'b1;
        detent_up;
        check("MANUAL: detent -> cmd 20", dut.u_ltg.cmd === 32'sd20);

        detent_up;
        check("MANUAL: second detent -> cmd 40", dut.u_ltg.cmd === 32'sd40);

        // ---- 4. SW -> AUTO ----
        press_sw;
        check("SW press -> AUTO", dut.mode_auto === 1'b1);

        // ---- 5. knob ignored in AUTO ----
        detent_up;
        check("AUTO: detent ignored", dut.u_ltg.cmd === 32'sd40);

        // ---- 6. AUTO demo fires at demo_ms == 5000 ----
        // ctrl_mode is a wire driven by the child's output port; forcing
        // the child's own state register is what Icarus actually holds.
        force dut.u_ctrl.mode_r = 3'd3;
        force dut.demo_ms = 20'd4999;
        repeat (5) @(negedge clk);
        release dut.demo_ms;
        // The stroke needs THREE ticks: (1) demo_ms 4999 -> 5000,
        // (2) the 5000 compare sets demo_up_s, (3) loc_target_gen samples the
        // now-visible strobe.  1.2 ms only reaches tick 1.
        repeat (600_000) @(negedge clk);          // 12 ms = 12 ticks
        check("AUTO: demo stroke -> cmd 448", dut.u_ltg.cmd === 32'sd448);

        // ---- 7. MANUAL gates the demo off ----
        press_sw;                                // -> MANUAL
        check("back to MANUAL", dut.mode_auto === 1'b0);
        repeat (40_000) @(negedge clk);
        force dut.demo_ms = 20'd4999;
        repeat (5) @(negedge clk);
        release dut.demo_ms;
        repeat (600_000) @(negedge clk);          // same 12 ms budget
        check("MANUAL: demo gated (cmd unchanged)", dut.u_ltg.cmd === 32'sd448);

        release dut.u_ctrl.mode_r;
        release dut.ctrl_en;

        if (errors == 0) $display("PASS: top mode switching verified");
        else             $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end

    initial begin
        #2_000_000_000;                          // 2 s sim-time guard
                                                 // (3 SW presses x 120 ms +
                                                 //  4 detents x 42 ms)
        $display("FAIL: timeout (mode_auto=%b cmd=%0d)", dut.mode_auto, dut.u_ltg.cmd);
        $finish;
    end
endmodule
