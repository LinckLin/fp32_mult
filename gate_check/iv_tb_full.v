// VCS gate-level golden replay: full 2,421,115 vectors, latency-5 streaming
`timescale 10ps/1ps
module iv_tb;
  reg clk, rst_n, in_valid, out_ready;
  reg [31:0] a, b;
  reg [4:0] fmt;
  reg [2:0] rm;
  wire in_ready, out_valid;
  wire [63:0] result;
  wire [15:0] fflags;

  fp32_mult dut ( .clk(clk), .rst_n(rst_n), .in_valid(in_valid),
                  .in_ready(in_ready), .a(a), .b(b), .fmt(fmt), .rm(rm),
                  .out_valid(out_valid), .out_ready(out_ready),
                  .result(result), .fflags(fflags) );

  reg [71:0] stim [0:2421114];
  reg [79:0] exp  [0:2421114];
  integer n = 2421115;
  integer i, recv, errs, cycles;
  reg [4:0]  efmt;
  reg [63:0] eres;
  reg [15:0] efl;

  initial begin clk = 0; forever #5000 clk = ~clk; end

  initial begin
    $readmemh("stim_full.hex", stim);
    $readmemh("exp_full.hex",  exp);
    rst_n = 0; in_valid = 0; out_ready = 1;
    a = 0; b = 0; fmt = 0; rm = 0;
    repeat (8) @(posedge clk);
    #1000 rst_n = 1;
    recv = 0; errs = 0; cycles = 0;

    fork
      begin : drive
        for (i = 0; i < n; i = i + 1) begin
          @(negedge clk);
          fmt = stim[i][71:67];
          a   = stim[i][66:35];
          b   = stim[i][34:3];
          rm  = stim[i][2:0];
          in_valid = 1'b1;
        end
        @(negedge clk);
        in_valid = 1'b0;
      end

      begin : check
        while (recv < n) begin
          @(posedge clk);
          #100;
          if (out_valid && out_ready) begin
            efmt = stim[recv][71:67];
            eres = exp[recv][79:16];
            efl  = exp[recv][15:0];
            if (result !== eres || fflags !== efl) begin
              errs = errs + 1;
              if (errs <= 5)
                $display("MISMATCH recv=%0d fmt=%0d a=%h b=%h rm=%0d | got=%h fl=%h | exp=%h fl=%h",
                         recv, efmt, stim[recv][66:35], stim[recv][34:3],
                         stim[recv][2:0], result, fflags, eres, efl);
            end
            recv = recv + 1;
            if (recv % 500000 == 0)
              $display("  ... %0d / %0d vectors checked, %0d mismatches", recv, n, errs);
          end
          cycles = cycles + 1;
          if (cycles > n + 1000) begin
            $display("WATCHDOG: stuck at recv=%0d", recv);
            $finish;
          end
        end
        $display("VCS GATE CHECK: %0d vectors, %0d mismatches", recv, errs);
        if (errs == 0) $display("GATE-LEVEL GOLDEN REPLAY PASSED");
        else           $display("GATE-LEVEL GOLDEN REPLAY FAILED");
        $finish;
      end
    join
  end
endmodule
