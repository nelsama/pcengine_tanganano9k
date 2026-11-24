// cputest.s as 4096 x 16 (even byte = low half), from build/sim_cpusys/prog.hex
module cpu_test_rom(input clk, input [11:0] a, output reg [15:0] q);
  reg [15:0] m[0:4095];
  initial $readmemh(`PROG_HEX, m);
  always @(posedge clk) q <= m[a];
endmodule
