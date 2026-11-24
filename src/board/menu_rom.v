// 16 KB menu ROM, bank 0 ($E000) first
`include "menu_cfg.vh"
module menu_rom(input clk, input [13:0] a, output reg [7:0] q);
  reg [7:0] m[0:16383];
  initial $readmemh(`MENU_HEX, m);
  always @(posedge clk) q <= m[a];
endmodule
