// ============================================================================
// arm_adc_link_tb.v -- testbench for the FPGA<->GD32 SPI ADC link.
//
//   This is the SECOND testbench in the project (the agreement was one, for
//   the encoder).  The reason it gets one too: it is a two-chip protocol, and
//   "the angle reads garbage" on hardware can be the FPGA FSM, the GD32
//   firmware, the wiring or the frame format -- un-localisable by looking at
//   the board.  A GD32 SPI-slave behaviour model makes it deterministic.
//
//   The model answers every NSS-low frame with 16 bits {seq[3:0], adc[11:0]},
//   where seq increments once per frame and adc is set by the test.
// ============================================================================
`timescale 1ns/1ps

module arm_adc_link_tb;

    localparam CLK_T = 20;                 // 50 MHz

    reg  clk   = 1'b0;
    reg  rst_n = 1'b0;

    wire SPI_NSS, SPI_SCK, SPI_MOSI;
    wire SPI_MISO;
    wire [11:0] adc;
    wire [3:0]  seq;
    wire        frame, link_ok;

    integer errors = 0;
    integer i;

    arm_adc_link #(
        .POLL_DIV (100),                   // 2 us per frame, keeps sim short
        .SCK_DIV  (4),
        .CNT_OK   (4)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .SPI_NSS  (SPI_NSS),
        .SPI_SCK  (SPI_SCK),
        .SPI_MOSI (SPI_MOSI),
        .SPI_MISO (SPI_MISO),
        .adc      (adc),
        .seq      (seq),
        .frame    (frame),
        .link_ok  (link_ok)
    );

    always #(CLK_T/2) clk = ~clk;

    // ---------------------------------------------------------------- model --
    reg [11:0] gd_adc   = 12'h123;         // what the GD32's ADC currently holds
    reg [3:0]  gd_seq   = 4'd0;
    reg [15:0] gd_tx    = 16'd0;
    reg        advance  = 1'b1;            // 0 = firmware stuck, seq stops moving

    // slave: load the answer when CS falls (CPHA=0 presents MSB immediately)
    always @(negedge SPI_NSS) begin
        gd_tx = {gd_seq, gd_adc};
        if (advance) gd_seq = gd_seq + 4'd1;
    end

    // slave: shift on the falling SCK edge
    always @(negedge SPI_SCK) begin
        if (SPI_NSS === 1'b0) gd_tx = {gd_tx[14:0], 1'b0};
    end

    assign SPI_MISO = gd_tx[15];

    initial begin
        $dumpfile("arm_adc_link_tb.vcd");
        $dumpvars(0, arm_adc_link_tb);

        // ------------------------------------------------------------ reset --
        repeat (10) @(negedge clk);
        rst_n = 1'b1;

        // ------------------------------------ wait for the link to come up --
        i = 0;
        while (link_ok !== 1'b1 && i < 20000) begin
            @(negedge clk);
            i = i + 1;
        end
        if (link_ok !== 1'b1) begin
            $display("FAIL link never came up (link_ok=%b)", link_ok);
            errors = errors + 1;
        end else begin
            $display("  ok  link up after %0d clocks, frame=%0d", i, adc);
        end

        // -------------------------------------------- first value read back --
        if (adc !== 12'h123) begin
            $display("FAIL adc read = 12'h%03h, want 123", adc);
            errors = errors + 1;
        end else begin
            $display("  ok  adc read back = 12'h123");
        end

        // --------------------------------- let the model send a new value --
        @(negedge clk);
        gd_adc = 12'h456;
        repeat (4) @(posedge frame);
        repeat (4) @(negedge clk);
        if (adc !== 12'h456) begin
            $display("FAIL adc did not follow to 12'h456 (got 12'h%03h)", adc);
            errors = errors + 1;
        end else begin
            $display("  ok  adc followed the model to 12'h456");
        end

        // ----------------------------------- counter check catches a stall --
        @(negedge clk);
        advance = 1'b0;                     // firmware froze: seq stops moving
        wait (link_ok === 1'b0);
        repeat (4) @(negedge clk);
        if (link_ok !== 1'b0) begin
            $display("FAIL link_ok stayed high even though the counter stalled");
            errors = errors + 1;
        end else begin
            $display("  ok  stalled counter detected, link_ok dropped");
        end

        // --------------------------------------- and recovers when it moves --
        @(negedge clk);
        advance = 1'b1;
        i = 0;
        while (link_ok !== 1'b1 && i < 20000) begin
            @(negedge clk);
            i = i + 1;
        end
        if (link_ok !== 1'b1) begin
            $display("FAIL link did not recover");
            errors = errors + 1;
        end else begin
            $display("  ok  link recovered");
        end

        if (errors == 0) $display("PASS: arm_adc_link verified");
        else             $display("FAIL: %0d check(s) failed", errors);

        $finish;
    end

endmodule
