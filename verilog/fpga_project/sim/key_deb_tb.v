`timescale 1ns/1ps
// key_deb_tb.v -- KEY1 level debounce (2026-11-02).
//
// Board symptom this fixes: a balance that had run ~30 s dropped out at
// alpha +1.4 deg with link=1 and wdog=0 -- i.e. run_latch flipped, and the
// only remaining path for that is a KEY1 press edge.  The switch is known to
// chatter (it also drops contact ~150 ms after a real press), and KEY_LOCK_MS
// only covers the first second after a toggle.
//
// Checks:
//   1. reset -> not running
//   2. a 3 ms chatter pulse does NOT toggle run_latch
//   3. a 100 ms real press DOES start it
//   4. after the 1 s lock expires, another 3 ms chatter still does NOT stop it
//   5. a 100 ms press stops it
//
// KEY_DEB_MS stays at its default 30 ms, i.e. this exercises the board value.
module key_deb_tb;
    reg clk = 1'b0, rst_n = 1'b0, tick_1k = 1'b0;
    reg key_run = 1'b1;                 // released (active low)
    reg link_ok = 1'b1;
    reg [11:0] adc = 12'd1988;
    reg signed [31:0] enc_pos = 32'sd0, loc_target = 32'sd0;
    wire signed [15:0] duty, alpha, adot_w;
    wire enable, wdog_w;
    wire [2:0] mode;
    integer errors = 0;

    pendulum_ctrl #(
        .ANG_OFFSET (1988),
        .KEY_DEB_MS (30)                // board value, explicitly
    ) dut (
        .clk (clk), .rst_n (rst_n), .tick_1k (tick_1k),
        .key_run (key_run), .link_ok (link_ok),
        .adc (adc), .enc_pos (enc_pos), .loc_target (loc_target),
        .duty (duty), .enable (enable),
        .alpha (alpha), .adot_dbg (adot_w), .wdog (wdog_w), .mode (mode)
    );

    always #10 clk = ~clk;              // 50 MHz

    integer c = 0;
    always @(posedge clk) begin
        c <= c + 1;
        tick_1k <= (c % 1000 == 999);
    end

    task check(input [255:0] name, input cond);
        if (cond === 1'b1) $display("  ok  %0s", name);
        else begin
            $display("FAIL %0s (run_latch=%b mode=%0d)", name, dut.run_latch, mode);
            errors = errors + 1;
        end
    endtask

    // hold KEY1 low for `ms`, then release; no lock wait here
    task press_ms(input integer ms);
        begin
            @(negedge clk);
            key_run = 1'b0;
            repeat (ms * 1000) @(posedge clk);
            @(negedge clk);
            key_run = 1'b1;
        end
    endtask

    // wait past KEY_LOCK_MS (1000 ms) plus the debounce window
    task wait_lock;
        begin
            repeat (1_100_000) @(posedge clk);
        end
    endtask

    initial begin
        repeat (6) @(negedge clk);
        rst_n = 1'b1;
        repeat (50_000) @(posedge clk);          // let the debounce prime

        check("reset -> not running", dut.run_latch === 1'b0);

        // ---- 2. chatter must not pass the 30 ms window ----
        press_ms(3);
        repeat (200_000) @(posedge clk);         // 4 ms settle
        check("3 ms chatter does NOT start", dut.run_latch === 1'b0);
        wait_lock;

        // ---- 3. a real press starts it ----
        press_ms(100);
        repeat (200_000) @(posedge clk);
        check("100 ms press starts", dut.run_latch === 1'b1);
        wait_lock;

        // ---- 4. chatter must not STOP a running machine (the board bug) ----
        press_ms(3);
        repeat (200_000) @(posedge clk);
        check("3 ms chatter does NOT stop a running machine",
              dut.run_latch === 1'b1);
        wait_lock;

        // ---- 5. a real press stops it ----
        press_ms(100);
        repeat (200_000) @(posedge clk);
        check("100 ms press stops", dut.run_latch === 1'b0);

        if (errors == 0) $display("PASS: key debounce verified");
        else             $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end

    initial begin
        #300_000_000;                            // 300 ms sim-time guard
        $display("FAIL: timeout (run_latch=%b)", dut.run_latch);
        $finish;
    end
endmodule
