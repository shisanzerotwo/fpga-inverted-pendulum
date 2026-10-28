// ============================================================================
// enc_decoder_tb.v -- the ONLY testbench in this project (by agreement).
//
//   Everything else is verified by programming the board; the encoder is the
//   one module where a hardware failure is un-localisable ("the number jumps"),
//   so it gets a known-input test.
//
//   Real figures used: 408 edges per output revolution, 11 PPR, up to 4216
//   edges/s.  The tb drives 50 k edges/s (20 us per edge) so it runs quickly
//   while still holding each state far longer than the 80 ns deglitch.
//
//   Run:
//     iverilog -o enc_tb.vvp enc_decoder_tb.v ../src/enc_decoder.v
//     vvp enc_tb.vvp
// ============================================================================
`timescale 1ns/1ps

module enc_decoder_tb;

    localparam CLK_T    = 20;         // 50 MHz
    localparam EDGE_T   = 20_000;     // 20 us per quadrature edge
    localparam TICK_DIV = 50_000;     // 1 ms tick strobe

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    reg  EA = 1'b0;
    reg  EB = 1'b0;
    reg  tick = 1'b0;

    wire signed [31:0] pos, delta;
    wire dir;

    integer errors = 0;

    enc_decoder #(.FILTER(4), .DIR_INVERT(1'b0)) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .tick  (tick),
        .EA    (EA),
        .EB    (EB),
        .pos   (pos),
        .delta (delta),
        .dir   (dir)
    );

    always #(CLK_T/2) clk = ~clk;

    // ---- 1 kHz control tick, 1-clock strobe ----
    reg [15:0] tcnt = 16'd0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tcnt <= 16'd0;
            tick <= 1'b0;
        end else begin
            tick <= 1'b0;
            if (tcnt == TICK_DIV-1) begin
                tcnt <= 16'd0;
                tick <= 1'b1;
            end else begin
                tcnt <= tcnt + 16'd1;
            end
        end
    end

    // ---- quadrature stimulus ----
    reg [1:0] ab = 2'b00;

    task fwd_edges(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                case (ab)
                    2'b00: ab = 2'b01;
                    2'b01: ab = 2'b11;
                    2'b11: ab = 2'b10;
                    2'b10: ab = 2'b00;
                endcase
                {EA, EB} = ab;
                #EDGE_T;
            end
        end
    endtask

    task rev_edges(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                case (ab)
                    2'b00: ab = 2'b10;
                    2'b10: ab = 2'b11;
                    2'b11: ab = 2'b01;
                    2'b01: ab = 2'b00;
                endcase
                {EA, EB} = ab;
                #EDGE_T;
            end
        end
    endtask

    // returns just after a tick, on a negedge (no race with the DUT)
    task wait_tick;
        begin
            @(negedge clk);
            while (tick !== 1'b1) @(negedge clk);
        end
    endtask

    initial begin
        $dumpfile("enc_decoder_tb.vcd");
        $dumpvars(0, enc_decoder_tb);

        // ---------------------------------------------------------- reset ---
        repeat (10) @(negedge clk);
        if (pos !== 32'sd0 || delta !== 32'sd0) begin
            $display("FAIL reset: pos=%0d delta=%0d (want 0/0)", pos, delta);
            errors = errors + 1;
        end else begin
            $display("  ok  reset: pos=0 delta=0");
        end
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        // ------------------------------------- one output revolution fwd ---
        fwd_edges(408);
        repeat (8) @(negedge clk);
        if (pos !== 32'sd408) begin
            $display("FAIL 408 forward edges: pos=%0d, want 408", pos);
            errors = errors + 1;
        end else begin
            $display("  ok  408 forward edges -> pos=408  (1 arm revolution)");
        end

        // -------------------------------------------------- reverse 100 ---
        rev_edges(100);
        repeat (8) @(negedge clk);
        if (pos !== 32'sd308) begin
            $display("FAIL 100 reverse edges: pos=%0d, want 308", pos);
            errors = errors + 1;
        end else begin
            $display("  ok  100 reverse edges -> pos=308");
        end

        // ----------------------------------- delta over one tick window ---
        wait_tick;
        fwd_edges(20);
        wait_tick;
        repeat (4) @(negedge clk);
        if (delta !== 32'sd20) begin
            $display("FAIL delta over one tick: %0d, want 20", delta);
            errors = errors + 1;
        end else begin
            $display("  ok  delta over one 1 ms tick = 20");
        end

        // ----------------------------------- deglitch rejects a 3-clock ---
        // white-box: look at the filtered node inside the DUT
        begin : glitch_test
            reg signed [31:0] p0;
            @(negedge clk);
            p0 = pos;
            EA = 1'b1;                       // spike of exactly 3 clocks
            repeat (3) @(negedge clk);
            EA = 1'b0;
            repeat (20) @(negedge clk);
            if (dut.ea_f !== 1'b0) begin
                $display("FAIL deglitch: ea_f went high on a 3-clock spike");
                errors = errors + 1;
            end else if (pos !== p0) begin
                $display("FAIL deglitch: pos moved %0d -> %0d on a spike", p0, pos);
                errors = errors + 1;
            end else begin
                $display("  ok  3-clock (60 ns) spike rejected, pos unchanged");
            end
        end

        // ------------------------------- deglitch passes a real edge ---
        begin : edge_test
            reg signed [31:0] p1;
            // force the encoder to a known state and let the deglitch settle,
            // so this test does not depend on where the earlier tests left us
            {EA, EB} = 2'b00;
            ab = 2'b00;
            repeat (20) @(negedge clk);
            p1 = pos;
            {EA, EB} = 2'b01;                // one legal forward edge
            ab = 2'b01;
            #(EDGE_T);
            if (pos !== p1 + 32'sd1) begin
                $display("FAIL real edge: pos moved %0d -> %0d, want +1", p1, pos);
                errors = errors + 1;
            end else if (dir !== 1'b1) begin
                $display("FAIL real edge: dir=%b, want 1", dir);
                errors = errors + 1;
            end else begin
                $display("  ok  real edge counted: pos %0d -> %0d, dir=1", p1, pos);
            end
        end

        // ------------------------------------------------------- verdict ---
        if (errors == 0) $display("PASS: enc_decoder verified");
        else             $display("FAIL: %0d check(s) failed", errors);

        $finish;
    end

endmodule
