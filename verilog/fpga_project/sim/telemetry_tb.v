`timescale 1ns/1ps
// ============================================================================
// telemetry_tb.v -- end-to-end test of the COM9 telemetry frame.
//
//   Decodes the actual uart_txd line (start bit / 8 data bits / stop bit at
//   the real 115200 bit time), reassembles the 13-byte frame and checks every
//   field against the values the TB itself drives into telemetry.v.  Two
//   consecutive frames with different payloads are checked, so a stale
//   snapshot (fields not re-latched) is caught too.
// ============================================================================
module telemetry_tb;
    reg clk = 0, rst_n = 0;
    reg tick_1k = 0;

    reg [2:0]  mode = 3'd0;
    reg        link_ok = 0, enable = 0, braking = 0, key1 = 1;
    reg signed [15:0] alpha = 0, adot = 0, duty = 0;
    reg [11:0] adc = 0;
    reg signed [31:0] enc_pos = 0;
    reg [15:0] frames = 0;
    reg wdog = 1'b0;              // saturation watchdog release window

    wire tx;
    integer errors = 0;

    localparam BIT_CLKS = 434;      // 50 MHz / 115200
    localparam integer GAP = 80000; // clocks between frame starts (> 15 bytes)

    // RATE_HZ = 1000 -> a frame starts on every 1 kHz tick
    telemetry #(.RATE_HZ(1000)) dut (
        .clk(clk), .rst_n(rst_n), .tick_1k(tick_1k),
        .mode(mode), .link_ok(link_ok), .enable(enable), .braking(braking), .key1(key1),
        .wdog(wdog),
        .alpha(alpha), .adot(adot), .duty(duty), .adc(adc), .enc_pos(enc_pos),
        .frames(frames),
        .uart_txd(tx)
    );

    always #10 clk = ~clk;

    // ---- one 1 kHz tick, well below the frame time so frames never overlap
    integer c = 0;
    always @(posedge clk) begin
        c = c + 1;
        tick_1k <= ((c % GAP) == 0);
    end

    // ---- UART receiver: one byte per call, sampling bit centres
    task get_byte(output [7:0] b);
        integer i;
        begin
            @(negedge tx);                     // start bit edge
            #((BIT_CLKS / 2) * 20);            // centre of the start bit
            for (i = 0; i < 8; i = i + 1) begin
                #(BIT_CLKS * 20);
                b[i] = tx;
            end
            #(BIT_CLKS * 20);                  // stop bit centre
            if (tx !== 1'b1) begin
                errors = errors + 1;
                $display("FAIL: stop bit not high");
            end
        end
    endtask

    task chk(input cond, input [8*64-1:0] msg);
        if (!cond) begin
            errors = errors + 1;
            $display("FAIL: %0s", msg);
        end
    endtask

    reg [7:0] b;
    reg [7:0] f_sync, f_seq, f_flags, ahi, alo, dhi, dlo, thi, tlo, adhi, adlo, ehi, elo;
    reg [7:0] fhi, flo;
    integer   frame;

    task get_frame(output integer seq_out);
        begin
            get_byte(f_sync);
            get_byte(f_seq);
            get_byte(f_flags);
            get_byte(ahi);  get_byte(alo);
            get_byte(thi);  get_byte(tlo);
            get_byte(dhi);  get_byte(dlo);
            get_byte(adhi); get_byte(adlo);
            get_byte(ehi);  get_byte(elo);
            get_byte(fhi);  get_byte(flo);
            seq_out = f_seq;
        end
    endtask

    initial begin
        $dumpfile("telemetry_tb.vcd");
        $dumpvars(0, telemetry_tb);

        repeat (4) @(negedge clk);

        // ================= frame 1 payload (set BEFORE reset release) =====
        mode    = 3'd2;            // PUMP
        link_ok = 1'b1;
        enable  = 1'b1;
        braking = 1'b0;
        key1    = 1'b0;            // pressed (active low)
        alpha   = -16'sd1234;
        adot    =  16'sd5678;
        duty    = -16'sd10000;
        adc     =  12'd2048;
        enc_pos = -32'sd408;
        frames  =  16'd500;

        rst_n = 1;

        get_frame(frame);
        $display("frame1 seq=%0d", frame);
        chk(f_sync  === 8'hA5,                                  "frame1 sync 0xA5");
        chk(f_flags === {1'b0, 1'b0, 1'b1, 1'b1, 1'b0, 3'd2},   "frame1 flags");
        chk({ahi, alo} === 16'hFB2E, "frame1 alpha bytes (-1234 = 0xFB2E)");
        chk($signed({ahi,alo}) === -16'sd1234,                  "frame1 alpha value");
        chk($signed({thi,tlo}) ===  16'sd5678,                  "frame1 adot value");
        chk($signed({dhi,dlo}) === -16'sd10000,                 "frame1 duty value");
        chk({adhi, adlo} === 16'h0800,                          "frame1 adc (2048)");
        chk($signed({ehi,elo}) === -16'sd408,                   "frame1 enc_pos low16 (-408)");
        chk({fhi, flo} === 16'd500,                             "frame1 spi frame counter");

        // ================= frame 2: change the payload immediately after
        //                   frame 1 drained, so the NEXT tick latches it ====
        mode    = 3'd3;            // BALANCE
        link_ok = 1'b0;
        enable  = 1'b0;
        braking = 1'b1;
        key1    = 1'b1;            // released
        wdog    = 1'b1;            // watchdog release window active
        alpha   =  16'sd9999;
        adot    = -16'sd1;
        duty    =  16'sd1;
        adc     =  12'd4095;
        enc_pos =  32'sd12345;
        frames  =  16'd60001;

        get_frame(frame);
        $display("frame2 seq=%0d", frame);
        chk(f_sync  === 8'hA5,                                  "frame2 sync 0xA5");
        chk(f_flags === {1'b1, 1'b1, 1'b0, 1'b0, 1'b1, 3'd3},   "frame2 flags");
        chk($signed({ahi,alo}) === 16'sd9999,                   "frame2 alpha value");
        chk($signed({thi,tlo}) === -16'sd1,                     "frame2 adot value");
        chk($signed({dhi,dlo}) ===  16'sd1,                     "frame2 duty value");
        chk({adhi, adlo} === 16'h0FFF,                          "frame2 adc (4095)");
        chk($signed({ehi,elo}) === 16'sd12345,                  "frame2 enc_pos low16");
        chk({fhi, flo} === 16'd60001,                           "frame2 spi frame counter");

        if (errors == 0) $display("PASS: telemetry frame verified end-to-end");
        else             $display("FAIL: %0d problem(s)", errors);
        $finish;
    end

    initial begin
        #30_000_000 $display("FAIL: watchdog timeout");
        $finish;
    end
endmodule
