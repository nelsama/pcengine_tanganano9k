--
-- pce_top.vhd : PC Engine on the Tang Nano 9K.
--   PLL sys : 27 / 5 x 16 = 86.4 MHz, + 90 degrees (PSRAM), / 4 = 21.6 MHz
--   PLL hdmi: 27 x 5 = 135 MHz, CLKDIV / 5 = 27 MHz pixel clock
-- Starts in the SD menu. S2 = menu.
-- Pad: joy_* pins, fire = I, btn2 = II, start1 = Run, credit = Select. S1 = reset.
-- LEDs: 0 HDMI locked, 1 heartbeat, 2 any pad button, 3 menu, 4 loading.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pce_top is
  port (
    clk27       : in    std_logic;
    btn_s1_n, btn_s2_n, btn_start1, btn_credit : in std_logic;
    led_n       : out   std_logic_vector(5 downto 0);
    tmds_ck_p, tmds_ck_n : out std_logic;
    tmds_d_p, tmds_d_n : out std_logic_vector(2 downto 0);
    joy_up, joy_down, joy_left, joy_right, joy_fire, joy_btn2 : in std_logic;
    audio_l, audio_r : out std_logic;
    uart_tx     : out   std_logic;
    sd_sck, sd_cmd, sd_cs : out std_logic;
    sd_dat0     : in    std_logic;
    O_psram_ck      : out   std_logic_vector(1 downto 0);
    O_psram_ck_n    : out   std_logic_vector(1 downto 0);
    IO_psram_rwds   : inout std_logic_vector(1 downto 0);
    IO_psram_dq     : inout std_logic_vector(15 downto 0);
    O_psram_reset_n : out   std_logic_vector(1 downto 0);
    O_psram_cs_n    : out   std_logic_vector(1 downto 0)
  );
end entity;

architecture rtl of pce_top is
  component CLKDIV
    generic (DIV_MODE : string := "2"; GSREN : string := "false");
    port (CLKOUT : out std_logic; HCLKIN, RESETN, CALIB : in std_logic);
  end component;
  component pce2hdmi is
    port (
      clk, we : in std_logic;
      waddr : in std_logic_vector(10 downto 0);
      wdata : in std_logic_vector(8 downto 0);
      div   : in std_logic_vector(1 downto 0);
      clk_pix : in std_logic;
      r, g, b : out std_logic_vector(7 downto 0);
      hs, vs, de, line_t, line_f : out std_logic;
      h_tx, v_tx : out std_logic_vector(9 downto 0));
  end component;
  signal memclk, memclk_p, clk, lock_s, clk135, clk_pix, lock_h, lock_h1 : std_logic;
  signal porp : unsigned(9 downto 0) := (others => '0');
  signal por  : unsigned(9 downto 0) := (others => '0');
  signal rstn, pore : std_logic := '0';
  signal s1   : std_logic_vector(1 downto 0) := "00";
  -- die 0 mode (memclk): fixed latency in the menu (loading), variable in the game
  type lst_t is (L_RST, L_BOOT, L_INIT, L_RUN);
  signal l    : lst_t := L_RST;
  signal tmr  : unsigned(5 downto 0) := (others => '0');
  signal fixed : std_logic := '1';
  signal mr, l_wr, run, menu1, tw1, tw2 : std_logic := '0';
  signal hard, run1, run2 : std_logic := '1';
  signal menu, loading, to_menu, pw_t : std_logic;
  signal pw_a : std_logic_vector(21 downto 0);
  signal pw_d : std_logic_vector(15 downto 0);
  signal s2   : std_logic_vector(1 downto 0) := "11";
  signal s2c  : unsigned(15 downto 0) := (others => '0');
  -- PSRAM
  signal r0, v0, t0, b0, r1, w1, v1, t1, b1, b1s : std_logic;
  signal a0, m0_a, a1 : std_logic_vector(21 downto 0);
  signal l0, m0_l, l1 : std_logic_vector(6 downto 0);
  signal q0, q1, d1 : std_logic_vector(15 downto 0);
  -- core
  signal pad, p0, p1 : std_logic_vector(7 downto 0) := (others => '0');   -- active high: run sel II I left down right up
  signal k    : std_logic_vector(3 downto 0);
  signal po   : std_logic_vector(1 downto 0);
  signal pix_we, frame_t, locked, line_t, line_f : std_logic;
  signal pix_a : std_logic_vector(10 downto 0);
  signal pix_c : std_logic_vector(8 downto 0);
  signal pix_d : std_logic_vector(1 downto 0);
  signal r, g, b : std_logic_vector(7 downto 0);
  signal hs, vs, de, audio_req : std_logic;
  signal h_tx, v_tx, tq0, tq1, tq2 : std_logic_vector(9 downto 0);
  signal haudio : std_logic_vector(31 downto 0);
  -- debug: last values written to $0801 / $0802 by the test program, cache misses
  signal psg_cs, b_wr, miss : std_logic;
  signal b_addr : std_logic_vector(9 downto 0);
  signal b_dout, dbg1, dbg2 : std_logic_vector(7 downto 0) := x"00";
  signal nmiss : unsigned(15 downto 0) := (others => '0');
  signal lk : std_logic_vector(1 downto 0) := "00";
  signal vdbg : std_logic_vector(31 downto 0);
  signal al, ar : signed(15 downto 0);
  signal ul, ur : unsigned(15 downto 0) := x"8000";
  signal dl, dr : unsigned(16 downto 0) := (others => '0');
  signal beat : unsigned(23 downto 0) := (others => '0');
begin
  u_pll : entity work.gw_rpll
    generic map (FCLKIN => "27", IDIV => 4, FBDIV => 15, ODIV => 8, PSDA => "0100", SDIV => 4)
    port map (clkin => clk27, clkout => memclk, clkoutp => memclk_p, clkoutd => clk, lock => lock_s);
  u_pllh : entity work.gw_rpll
    generic map (FCLKIN => "27", IDIV => 0, FBDIV => 4, ODIV => 4, PSDA => "0000", SDIV => 2)
    port map (clkin => clk27, clkout => clk135, clkoutp => open, clkoutd => open, lock => lock_h);
  u_div : CLKDIV generic map (DIV_MODE => "5", GSREN => "false")
    port map (CLKOUT => clk_pix, HCLKIN => clk135, RESETN => lock_h, CALIB => '0');

  process(memclk, lock_s)
  begin
    if lock_s = '0' then por <= (others => '0'); rstn <= '0'; s1 <= "00";
    elsif rising_edge(memclk) then
      s1 <= s1(0) & btn_s1_n;
      rstn <= '0';
      porp <= porp + 1; pore <= '0';
      if porp = 0 then pore <= '1'; end if;
      if s1(1) = '0' then por <= (others => '0');
      elsif por(9) = '0' then if pore = '1' then por <= por + 1; end if;
      else rstn <= '1'; end if;
    end if;
  end process;

  process(memclk)
  begin
    if rising_edge(memclk) then
      mr <= '1';
      tmr <= tmr + 1;
      menu1 <= menu;
      tw1 <= pw_t; tw2 <= tw1;
      case l is
        when L_RST  => mr <= '0'; run <= '0'; fixed <= menu1;
                       if tmr = 63 then l <= L_BOOT; end if;
        when L_BOOT => if tmr = 63 then l <= L_INIT; end if;
        when L_INIT => if b0 = '0' and b1 = '0' then l <= L_RUN; end if;
        when L_RUN  => run <= '1';
                       if menu1 /= fixed then l <= L_RST; tmr <= (others => '0'); end if;
      end case;
      if tw1 /= tw2 then l_wr <= '1';
      elsif b0 = '0' then l_wr <= '0'; end if;
      if rstn = '0' then l <= L_RST; tmr <= (others => '0'); mr <= '0'; l_wr <= '0'; run <= '0'; end if;
    end if;
  end process;
  m0_a <= pw_a when fixed = '1' else a0;
  m0_l <= "0000001" when fixed = '1' else l0;

  u_m0 : entity work.psram_burst generic map (FREQ => 86400000)
    port map (clk => memclk, clk_p => memclk_p, resetn => mr, fixed => fixed, read => r0, write => l_wr,
      addr => m0_a, len => m0_l, din => pw_d, byte_write => '0', dout => q0, rvalid => v0,
      wtake => t0, busy => b0, psram_ck => O_psram_ck(0), psram_cs_n => O_psram_cs_n(0),
      psram_rwds => IO_psram_rwds(0), psram_dq => IO_psram_dq(7 downto 0));
  u_m1 : entity work.psram_burst generic map (FREQ => 86400000)
    port map (clk => memclk, clk_p => memclk_p, resetn => rstn, fixed => '1', read => r1, write => w1,
      addr => a1, len => l1, din => d1, byte_write => '0', dout => q1, rvalid => v1,
      wtake => t1, busy => b1, psram_ck => O_psram_ck(1), psram_cs_n => O_psram_cs_n(1),
      psram_rwds => IO_psram_rwds(1), psram_dq => IO_psram_dq(15 downto 8));
  O_psram_ck_n <= "00"; O_psram_reset_n <= lock_s & lock_s;

  -- core -----------------------------------------------------------------------
  process(clk)
  begin
    if rising_edge(clk) then
      hard <= not rstn; run1 <= run; run2 <= run1;
      s2 <= s2(0) & btn_s2_n;                         -- S2, debounced (3 ms)
      if s2(1) = '1' then s2c <= (others => '0'); elsif s2c /= x"FFFF" then s2c <= s2c + 1; end if;
      to_menu <= '0';
      if s2c = x"FFFE" then to_menu <= '1'; end if;
      p0 <= not (btn_start1 & btn_credit & joy_btn2 & joy_fire & joy_left & joy_down & joy_right & joy_up);
      p1 <= p0;
      pad <= p1(7 downto 4) & (p1(3) and not p1(1)) & (p1(2) and not p1(0))
             & (p1(1) and not p1(3)) & (p1(0) and not p1(2));
      beat <= beat + 1;
    end if;
  end process;
  k <= "0000" when po(1) = '1' else not pad(3 downto 0) when po(0) = '1' else not pad(7 downto 4);
  u_core : entity work.pce_core
    port map (clk => clk, hard => hard, to_menu => to_menu, mem_rdy => run2, menu => menu, loading => loading,
      sd_sck => sd_sck, sd_cmd => sd_cmd, sd_cs => sd_cs, sd_dat0 => sd_dat0, pw_t => pw_t, pw_a => pw_a, pw_d => pw_d,
      memclk => memclk, pad => k, pad_o => po, psg_cs => psg_cs, b_wr => b_wr, b_addr => b_addr, b_dout => b_dout, audio_l => al, audio_r => ar,
      pix_we => pix_we, pix_addr => pix_a, pix_color => pix_c, pix_div => pix_d, frame_t => frame_t, line_t => line_t, line_f => line_f, locked => locked, miss => miss, dbg => vdbg,
      p0_read => r0, p0_addr => a0, p0_len => l0, p0_dout => q0, p0_rvalid => v0, p0_busy => b0,
      p1_read => r1, p1_write => w1, p1_addr => a1, p1_len => l1, p1_din => d1, p1_dout => q1,
      p1_rvalid => v1, p1_busy => b1);

  u_v2h : pce2hdmi port map (clk => clk, we => pix_we, waddr => pix_a, wdata => pix_c, div => pix_d,
    clk_pix => clk_pix, line_t => line_t, line_f => line_f, h_tx => h_tx, v_tx => v_tx, r => r, g => g, b => b, hs => hs, vs => vs, de => de);
  -- HDMI with 48 kHz stereo audio (FULL => false: DVI, picture only)
  u_haud : entity work.hdmi_audio
    port map (clk => clk, left => ul, right => ur, req => audio_req, audio => haudio);
  u_tx : entity work.hdmi_tx generic map (FULL => true)
    port map (clk => clk_pix, h_cnt => unsigned(h_tx), v_cnt => unsigned(v_tx), hs => hs, vs => vs, de => de,
      rgb => r & g & b, audio_req => audio_req, audio => haudio, q0 => tq0, q1 => tq1, q2 => tq2);
  u_phy : entity work.hdmi_phy
    port map (clk_135 => clk135, clk_pix => clk_pix, lock => lock_h, q0 => tq0, q1 => tq1, q2 => tq2,
      tmds_c0_p => tmds_d_p(0), tmds_c0_n => tmds_d_n(0), tmds_c1_p => tmds_d_p(1), tmds_c1_n => tmds_d_n(1),
      tmds_c2_p => tmds_d_p(2), tmds_c2_n => tmds_d_n(2), tmds_ck_p => tmds_ck_p, tmds_ck_n => tmds_ck_n);

  process(clk)
  begin
    if rising_edge(clk) then
      lk <= lk(0) & locked;
      if miss = '1' then nmiss <= nmiss + 1; end if;
      if psg_cs = '1' and b_wr = '1' then
        if b_addr(3 downto 0) = "0001" then dbg1 <= b_dout; end if;
        if b_addr(3 downto 0) = "0010" then dbg2 <= b_dout; end if;
      end if;
    end if;
  end process;
  u_uart : entity work.uart_report
    generic map (TPL => "PCE HSW=## HDS=## LOCK=# HDW.VDS=####" & CR & LF, NNIB => 9, CLKS_PER_BIT => 188, PERIOD_BITS => 24)
    port map (clk => clk, snap => vdbg(31 downto 16) & "000" & lk(1) & vdbg(15 downto 0), tx => uart_tx);

  -- x 2 with saturation, first-order sigma-delta DAC
  process(clk)
    function sat(x : signed(15 downto 0)) return unsigned is
    begin
      if x(15) = '1' and x(14) = '0' then return x"0000"; end if;
      if x(15) = '0' and x(14) = '1' then return x"FFFF"; end if;
      return unsigned(x(14 downto 0) & '0') xor x"8000";
    end function;
  begin
    if rising_edge(clk) then
      ul <= sat(al); ur <= sat(ar);
      dl <= ('0' & dl(15 downto 0)) + ('0' & ul);
      dr <= ('0' & dr(15 downto 0)) + ('0' & ur);
    end if;
  end process;
  audio_l <= dl(16); audio_r <= dr(16);
  led_n(0) <= not locked;
  led_n(1) <= beat(23);
  led_n(2) <= '0' when pad /= x"00" else '1';
  led_n(3) <= not menu;
  led_n(4) <= not loading;
  led_n(5) <= '1';
end architecture;
