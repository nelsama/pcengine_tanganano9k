// pce2hdmi.v : PC Engine dots -> 720x480p raster (858 x 525 at 27 MHz, 59.94 Hz).
// One PCE line = 2 HDMI lines. A pixel (1.6 clk of the line at 21.6 MHz)
// is 8 units of a dot of 20 (5.4 MHz), 15 (7.2 MHz) or 10 (10.8 MHz) units.
// 720 pixels = 1152 clk of the line; pixels over two dots are blended.
// Two-line buffer. Lines 19..258 are shown; line n is written in the two HDMI lines
// before it is shown. The raster is the master: line_t changes at the start of
// v = 0, 2 .. 520 and 523 (262 per frame); line_f = 1 for 523, where line 19 starts.
// r, g, b, hs, vs, de come 2 clk after h_tx, v_tx (as hdmi_tx needs).
module pce2hdmi(
  input             clk,        // PCE side
  input             we,
  input      [10:0] waddr,      // {line[0], dot}
  input      [8:0]  wdata,      // GRB
  input      [1:0]  div,        // dot clock of the line being written
  input             clk_pix,
  output reg [7:0]  r, g, b,
  output reg        hs, vs, de,
  output reg        line_t, line_f,
  output reg [9:0]  h_tx, v_tx
);
  localparam H_TOT = 858, V_TOT = 525;

  reg [8:0] lb[0:2047];
  reg [1:0] dv[0:1];
  always @(posedge clk) begin
    if (we) lb[waddr] <= wdata;
    if (we) dv[waddr[10]] <= div;
  end

  reg [9:0] h, v, h_d, v_d;
  reg [4:0] acc;
  reg [9:0] dx;
  reg [1:0] d;
  initial begin h = 0; v = 0; line_t = 0; line_f = 0; acc = 0; dx = 0; d = 0; end
  wire [4:0] unit = d == 0 ? 5'd20 : d == 1 ? 5'd15 : 5'd10;
  wire [4:0] left = unit - acc;

  always @(posedge clk_pix) begin
    if (h == H_TOT - 1) begin
      h <= 0;
      v <= (v == V_TOT - 1) ? 10'd0 : v + 1'b1;
    end else h <= h + 1'b1;

    if (h >= 720) begin acc <= 0; dx <= 0; d <= dv[!v[1]]; end
    else if (left <= 8) begin acc <= 5'd8 - left; dx <= dx + 1'b1; end
    else acc <= acc + 5'd8;
    if (h == H_TOT - 2) d <= dv[v[0] ? v[1] : !v[1]];   // the line about to be shown

    if (h == 0 && (v == 523 || (!v[0] && v < 522))) begin
      line_t <= !line_t;
      line_f <= v == 523;
    end
    h_d <= h;  h_tx <= h_d;                 // the picture pipeline is 4 stages long
    v_d <= v;  v_tx <= v_d;
  end

  // stage 1: address   2: colour   3: rgb   4: output
  reg [10:0] ra;
  reg [8:0]  c2;
  reg        vis1, vis2, vis3, bl1, bl2, bl3, de1, de2, de3, hs1, hs2, hs3, vs1, vs2, vs3;
  wire [14:0] rgb = {c2[5:3], c2[5:4], c2[8:6], c2[8:7], c2[2:0], c2[2:1]};
  reg [14:0] rgb3, prev;
  wire [5:0] sr = {1'b0, rgb3[14:10]} + (bl3 ? prev[14:10] : rgb3[14:10]);
  wire [5:0] sg = {1'b0, rgb3[9:5]}   + (bl3 ? prev[9:5]   : rgb3[9:5]);
  wire [5:0] sb = {1'b0, rgb3[4:0]}   + (bl3 ? prev[4:0]   : rgb3[4:0]);

  always @(posedge clk_pix) begin
    ra   <= {!v[1], left < 6 ? dx + 10'd1 : dx};
    bl1  <= left >= 3 && left < 6;
    vis1 <= h < 720 && v < 480;
    de1  <= h < 720 && v < 480;
    hs1  <= !(h >= 736 && h < 798);
    vs1  <= !((v > 489 || (v == 489 && h >= 736)) && (v < 495 || (v == 495 && h < 736)));
    c2   <= lb[ra];
    {vis2, bl2, de2, hs2, vs2} <= {vis1, bl1, de1, hs1, vs1};
    rgb3 <= rgb;  prev <= rgb3;
    {vis3, bl3, de3, hs3, vs3} <= {vis2, bl2, de2, hs2, vs2};
    {de, hs, vs} <= {de3, hs3, vs3};
    r <= vis3 ? {sr, sr[5:4]} : 8'd0;
    g <= vis3 ? {sg, sg[5:4]} : 8'd0;
    b <= vis3 ? {sb, sb[5:4]} : 8'd0;
  end
endmodule
