`timescale 1ns/1ps
// ============================================================================
// uart_link_tb.v -- bench for uart_rx.v + arm_adc_uart.v (the UART rescue
// link over the spare net PA2/K11).  Checks, in order:
//   1. 8 good frames lock link_ok; adc/seq read back exactly.
//   2. one bad-seq frame drops link_ok immediately.
//   3. re-lock after 8 good frames.
//   4. phase recovery: a receiver that starts MID-FRAME (extra leading byte)
//      hunts its boundary and locks within a bounded number of frames.
//   5. 5 ms byte starvation drops link_ok.
// ============================================================================
module uart_link_tb;

    reg clk = 0;
    reg rst_n = 0;
    reg rx = 1;
    wire [11:0] adc;
    wire [3:0]  seq;
    wire        frame, link_ok;

    integer errors = 0;
    integer frame_cnt = 0;

    always #10 clk = ~clk;                 // 50 MHz

    arm_adc_uart #(
        .CLK_HZ (50_000_000),
        .BAUD   (1_000_000),
        .CNT_OK (8),
        .TO_MS  (5)
    ) dut (
        .clk (clk), .rst_n (rst_n), .uart_rx_i (rx),
        .adc (adc), .seq (seq), .frame (frame), .link_ok (link_ok)
    );

    always @(posedge clk) if (frame) frame_cnt = frame_cnt + 1;

    localparam integer BIT = 1000;         // 1 Mbaud -> 1 us per bit

    task send_byte(input [7:0] b);
        integer i;
        begin
            rx = 0; #(BIT);                        // start
            for (i = 0; i < 8; i = i + 1) begin    // LSB first
                rx = b[i]; #(BIT);
            end
            rx = 1; #(BIT);                        // stop
        end
    endtask

    task send_frame(input [3:0] s, input [11:0] a);
        begin
            send_byte({s, a[11:8]});
            send_byte(a[7:0]);
        end
    endtask

    task check(input cond, input [255:0] what);
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL: %0s at t=%0t", what, $time);
            end
            else $display("ok  : %0s", what);
        end
    endtask

    integer i;
    initial begin
        #200 rst_n = 1;
        #(BIT*2);

        // ---- 1. lock on good frames (first frame only syncs prev_seq) ----
        for (i = 0; i < 10; i = i + 1) send_frame(i[3:0], 12'h100 + i);
        #(BIT*4);
        check(link_ok === 1'b1, "link locks after 8 good frames");
        check(adc === 12'h109,        "adc reads back the last frame");
        check(seq === 4'd9,           "seq reads back the last frame");

        // ---- 2. bad seq drops the link ----
        send_frame(4'd12, 12'h200);              // 7 -> 12: wrong step
        #(BIT*4);
        check(link_ok === 1'b0, "bad seq frame drops link_ok");

        // ---- 3. re-lock ----
        for (i = 13; i < 21; i = i + 1) send_frame(i[3:0] & 4'hF, 12'h300 + (i & 12'hF));
        #(BIT*4);
        check(link_ok === 1'b1, "link re-locks after 8 good frames");

        // ---- 4. phase recovery: the DUT comes up MID-FRAME ----
        // send a hi-role byte, reset the DUT while it is "in flight", then a
        // lo-role byte as the DUT's very first byte -> wrong pairing must be
        // detected and hunted away.
        send_byte({4'd2, 4'hA});                 // never seen by the DUT
        rst_n = 0; #(BIT*2); rst_n = 1;
        send_byte(8'h55);                        // DUT's first byte (lo-role)
        begin : phase_loop
            integer k;
            integer locked_at;
            locked_at = -1;
            for (k = 0; k < 300 && locked_at < 0; k = k + 1) begin
                send_frame(k[3:0], 12'h400 + (k & 12'hFF));
                #10;
                if (link_ok === 1'b1) locked_at = k;
            end
            check(locked_at >= 0,   "phase hunt re-aligns and locks");
            if (locked_at >= 0)
                $display("      (locked after %0d frames)", locked_at + 1);
        end
        #(BIT*4);
        check(adc[11:8] === 4'h4 || adc[11:8] === 4'h5 || adc[11:8] === 4'h6,
              "adc sane after re-align");

        // ---- 5. starvation timeout ----
        #(6_000_000);                            // > 5 ms of silence
        check(link_ok === 1'b0, "5ms starvation drops link_ok");

        if (errors == 0) $display("PASS: uart_link_tb, %0d frames total", frame_cnt);
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end
endmodule
