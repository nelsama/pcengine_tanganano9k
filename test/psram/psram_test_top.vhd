--
-- psram_test_top.vhd : board test of src/memory/psram_burst.vhd, both dies at
-- once, 86.4 MHz (the clocks of the Master System project).
-- LEDs: 0 / 1 error in die 0 / 1    2 both dies got past the first phase
--       4 / 5 blink with the passes of die 0 / 1. S1 clears the errors.
-- UART (pin 17, the USB one, and 32; 115200 8N1), one line per die every ~0.8 s.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity psram_test_top is
  port (
    clk27       : in    std_logic;
    btn_s1_n    : in    std_logic;
    led_n       : out   std_logic_vector(5 downto 0);
    uart_tx     : out   std_logic;
    uart_tx2    : out   std_logic;
    O_psram_ck      : out   std_logic_vector(1 downto 0);
    O_psram_ck_n    : out   std_logic_vector(1 downto 0);
    IO_psram_rwds   : inout std_logic_vector(1 downto 0);
    IO_psram_dq     : inout std_logic_vector(15 downto 0);
    O_psram_reset_n : out   std_logic_vector(1 downto 0);
    O_psram_cs_n    : out   std_logic_vector(1 downto 0)
  );
end entity;

architecture rtl of psram_test_top is
  constant NN : integer := 1+4+4+4+4+6+4+4+14+4;
  type snap_t is array (0 to 1) of std_logic_vector(4*NN-1 downto 0);
  signal snap : snap_t;
  signal memclk, memclk_p, clk21, lock, utx : std_logic;
  signal s1   : std_logic_vector(2 downto 0) := "111";
  signal por  : unsigned(15 downto 0) := (others => '0');
  signal rstn : std_logic := '0';
  signal clr  : std_logic := '0';
  signal err  : std_logic_vector(1 downto 0);
  signal alive : std_logic_vector(1 downto 0) := "00";
begin
  u_pll : entity work.gw_rpll
    generic map (FCLKIN => "27", IDIV => 4, FBDIV => 15, ODIV => 8, PSDA => "0100", SDIV => 4)
    port map (clkin => clk27, clkout => memclk, clkoutp => memclk_p, clkoutd => clk21, lock => lock);

  process(memclk, lock)
  begin
    if lock = '0' then
      por <= (others => '0'); rstn <= '0';
    elsif rising_edge(memclk) then
      if por /= x"FFFF" then por <= por + 1; else rstn <= '1'; end if;
    end if;
  end process;
  process(memclk)
  begin
    if rising_edge(memclk) then
      s1  <= s1(1 downto 0) & btn_s1_n;
      clr <= not s1(2);
    end if;
  end process;

  g : for i in 0 to 1 generate
    signal mr, mf, rd, wr, bw, rv, wt, by : std_logic;
    signal ad : std_logic_vector(21 downto 0);
    signal ln : std_logic_vector(6 downto 0);
    signal di, dq, e1, e2, e3, fg, fx, sl, ps : std_logic_vector(15 downto 0);
    signal ph : std_logic_vector(3 downto 0);
    signal fa : std_logic_vector(23 downto 0);
    signal r1f, r1vn, r1vx, r9f, r33f, r16v, w1 : std_logic_vector(7 downto 0);
  begin
    u_m : entity work.psram_burst
      generic map (FREQ => 86400000, LATENCY => 3)
      port map (clk => memclk, clk_p => memclk_p, resetn => mr, fixed => mf,
        read => rd, write => wr, addr => ad, len => ln, din => di, byte_write => bw,
        dout => dq, rvalid => rv, wtake => wt, busy => by,
        psram_ck => O_psram_ck(i), psram_cs_n => O_psram_cs_n(i),
        psram_rwds => IO_psram_rwds(i), psram_dq => IO_psram_dq(8*i+7 downto 8*i));
    u_t : entity work.psram_tester
      port map (clk => memclk, resetn => rstn, clr => clr, m_resetn => mr, m_fixed => mf,
        m_read => rd, m_write => wr, m_bw => bw, m_addr => ad, m_len => ln, m_din => di,
        m_dout => dq, m_rvalid => rv, m_wtake => wt, m_busy => by,
        phase => ph, pass => ps, e1 => e1, e2 => e2, e3 => e3, fa => fa, fg => fg, fx => fx,
        r1f => r1f, r1vn => r1vn, r1vx => r1vx, r9f => r9f, r33f => r33f, r16v => r16v, w1 => w1,
        slow => sl, err => err(i));
    -- quasi static; a value changing during the capture may print torn
    snap(i) <= ph & ps & e1 & e2 & e3 & fa & fg & fx & r1f & r1vn & r1vx & r9f & r33f & r16v & w1 & sl;
    process(memclk)
    begin
      if rising_edge(memclk) then
        if ph /= "0000" then alive(i) <= '1'; end if;
      end if;
    end process;
    led_n(i)     <= not err(i);
    led_n(4 + i) <= not ps(1);
  end generate;

  u_uart : entity work.uart_report
    generic map (
      TPL => "D0 H=# P=#### EF=#### ET=#### EV=#### A=###### G=#### X=#### R1F=## R1V=##-## R9F=## R33F=## R16V=## W1=## SL=####" & CR & LF
           & "D1 H=# P=#### EF=#### ET=#### EV=#### A=###### G=#### X=#### R1F=## R1V=##-## R9F=## R33F=## R16V=## W1=## SL=####" & CR & LF,
      NNIB => 2*NN, CLKS_PER_BIT => 188, PERIOD_BITS => 24)
    port map (clk => clk21, snap => snap(0) & snap(1), tx => utx);
  uart_tx  <= utx;
  uart_tx2 <= utx;
  led_n(2) <= not (alive(0) and alive(1));
  led_n(3) <= '1';
  O_psram_ck_n    <= "00";
  O_psram_reset_n <= lock & lock;
end architecture;
