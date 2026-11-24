--
-- pce_core.vhd : CPU system + VDC + VCE. PSRAM die 0 = ROM, die 1 = VRAM; the
-- psram_burst controllers are outside (p0_* / p1_*).
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pce_core is
  port (
    clk, hard  : in  std_logic;                       -- hard: power-on / S1
    to_menu, mem_rdy : in std_logic;
    menu, loading : out std_logic;
    sd_sck, sd_cmd, sd_cs : out std_logic;
    sd_dat0    : in  std_logic;
    pw_t       : out std_logic;                       -- ROM writes of the loader
    pw_a       : out std_logic_vector(21 downto 0);
    pw_d       : out std_logic_vector(15 downto 0);
    memclk     : in  std_logic;
    pad        : in  std_logic_vector(3 downto 0);
    pad_o      : out std_logic_vector(1 downto 0);
    psg_cs, b_wr : out std_logic;
    b_addr     : out std_logic_vector(9 downto 0);
    b_dout     : out std_logic_vector(7 downto 0);
    audio_l, audio_r : out signed(15 downto 0);
    pix_we     : out std_logic;
    pix_addr   : out std_logic_vector(10 downto 0);
    pix_color  : out std_logic_vector(8 downto 0);
    pix_div    : out std_logic_vector(1 downto 0);
    frame_t    : out std_logic;
    miss       : out std_logic;
    p0_read    : out std_logic;
    p0_addr    : out std_logic_vector(21 downto 0);
    p0_len     : out std_logic_vector(6 downto 0);
    p0_dout    : in  std_logic_vector(15 downto 0);
    p0_rvalid, p0_busy : in std_logic;
    p1_read, p1_write : out std_logic;
    p1_addr    : out std_logic_vector(21 downto 0);
    p1_len     : out std_logic_vector(6 downto 0);
    p1_din     : out std_logic_vector(15 downto 0);
    p1_dout    : in  std_logic_vector(15 downto 0);
    p1_rvalid, p1_busy : in std_logic
  );
end entity;

architecture rtl of pce_core is
  signal reset, menu_i, cart_cs : std_logic;
  signal cart_q : std_logic_vector(7 downto 0);
  signal rom_mode : std_logic_vector(1 downto 0);
  signal rom_mask : std_logic_vector(6 downto 0);
  signal bram_wr : std_logic;
  signal psg_sel : std_logic;
  signal irq1, vdc_cs, vce_cs, wr, rd, vbusy, sol, eol, dot : std_logic;
  signal ba : std_logic_vector(9 downto 0);
  signal bd, vdc_q, vce_q : std_logic_vector(7 downto 0);
  signal line : unsigned(8 downto 0);
  signal dotclk : std_logic_vector(1 downto 0);
  signal pa : std_logic_vector(8 downto 0);
begin
  u_cpu : entity work.cpu_sys
    port map (clk => clk, reset => reset, irq1 => irq1, pad => pad, pad_o => pad_o,
      vdc_cs => vdc_cs, vce_cs => vce_cs, psg_cs => psg_sel, b_addr => ba, b_dout => bd, b_wr => wr, b_rd => rd,
      vdc_din => vdc_q, vce_din => vce_q, vdc_busy => vbusy, rom_mask => rom_mask, rom_mode => rom_mode,
      menu => menu_i, cart_cs => cart_cs, cart_din => cart_q, bram_wr => bram_wr, miss => miss,
      memclk => memclk, p_read => p0_read, p_addr => p0_addr, p_len => p0_len, p_dout => p0_dout,
      p_rvalid => p0_rvalid, p_busy => p0_busy);
  psg_cs <= psg_sel;
  u_psg : entity work.psg
    port map (clk => clk, reset => reset, cs => psg_sel, wr => wr, a => ba(3 downto 0), din => bd,
      left => audio_l, right => audio_r);
  menu <= menu_i;
  u_cart : entity work.cart
    port map (clk => clk, hard => hard, to_menu => to_menu, mem_rdy => mem_rdy, menu => menu_i, reset => reset,
      bram_wr => bram_wr, cs => cart_cs, wr => wr, rd => rd, a => ba(4 downto 0), din => bd, dout => cart_q,
      rom_mode => rom_mode, rom_mask => rom_mask, pw_t => pw_t, pw_a => pw_a, pw_d => pw_d, loading => loading,
      sd_sck => sd_sck, sd_cmd => sd_cmd, sd_cs => sd_cs, sd_dat0 => sd_dat0);
  b_wr <= wr; b_addr <= ba; b_dout <= bd;

  u_vdc : entity work.vdc
    port map (clk => clk, reset => reset, cs => vdc_cs, wr => wr, rd => rd, a => ba(1 downto 0), din => bd,
      dout => vdc_q, busy => vbusy, irq => irq1, sol => sol, eol => eol, dot => dot, line => line,
      dotclk => dotclk, pa => pa, memclk => memclk, p_read => p1_read, p_write => p1_write, p_addr => p1_addr,
      p_len => p1_len, p_din => p1_din, p_dout => p1_dout, p_rvalid => p1_rvalid, p_busy => p1_busy);

  u_vce : entity work.vce
    port map (clk => clk, reset => reset, cs => vce_cs, wr => wr, rd => rd, a => ba(2 downto 0), din => bd,
      dout => vce_q, sol => sol, eol => eol, dot => dot, line => line, dotclk => dotclk, pa => pa,
      pix_we => pix_we, pix_addr => pix_addr, pix_color => pix_color, pix_div => pix_div, frame_t => frame_t);
end architecture;
