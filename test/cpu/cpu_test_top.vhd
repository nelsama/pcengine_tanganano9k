--
-- cpu_test_top.vhd : board test of cpu_sys. Writes the 64 KB test ROM
-- (sim/cputest.s + generated data) to PSRAM die 0 with fixed latency, switches
-- to variable latency, runs the program and checks what it sends through the
-- PSG and VDC ports; then everything again.
-- LEDs: 0 error seen   2 at least one good run   4 blinks with the runs
-- UART 115200: R runs, E bad runs, then of the last run: V1 = test 1 (sum),
--   V2 test 2, V4 test 4 (timer interrupts), CV = ST0 / TIA errors (00 = ok),
--   C1 / C2 = clk / 4 of the 4 KB of NOP cold / cached (hex), M = cache misses
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_test_top is
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

architecture rtl of cpu_test_top is
  signal memclk, memclk_p, clk, lock, utx : std_logic;
  signal por  : unsigned(15 downto 0) := (others => '0');
  signal rstn : std_logic := '0';
  -- loader (memclk)
  type lst_t is (L_RST, L_BOOT, L_INIT, L_NEXT, L_ROM, L_REQ, L_RST2, L_BOOT2, L_INIT2, L_RUN);
  signal l    : lst_t := L_RST;
  signal tmr  : unsigned(4 downto 0) := (others => '0');
  signal w    : unsigned(15 downto 0) := (others => '0');
  signal b0, b1 : unsigned(7 downto 0);
  signal fixed, mr, l_wr, run, again1, again2, again : std_logic := '0';
  signal l_din : std_logic_vector(15 downto 0);
  signal q_prog : std_logic_vector(15 downto 0);
  -- PSRAM
  signal p_read, p_rvalid, p_wtake, p_busy : std_logic;
  signal p_addr, m_addr : std_logic_vector(21 downto 0);
  signal p_len, m_len : std_logic_vector(6 downto 0);
  signal p_dout : std_logic_vector(15 downto 0);
  -- system (clk)
  signal run1, run2, reset : std_logic := '1';
  signal bw, cvdc, cpsg, miss : std_logic;
  signal ba : std_logic_vector(9 downto 0);
  signal bd : std_logic_vector(7 downto 0);
  signal test : unsigned(7 downto 0) := (others => '0');
  signal v1   : std_logic_vector(15 downto 0) := (others => '0');
  signal v2, v4 : std_logic_vector(7 downto 0) := (others => '0');
  signal vn   : unsigned(15 downto 0) := (others => '0');
  signal tx   : unsigned(7 downto 0);
  signal cv   : std_logic_vector(7 downto 0) := (others => '0');
  signal tc   : unsigned(17 downto 0) := (others => '0');
  signal c1, c2, ms, mc : unsigned(15 downto 0) := (others => '0');
  signal runs, bad : unsigned(15 downto 0) := (others => '0');
  signal fin  : std_logic := '0';
  signal wdog : unsigned(22 downto 0) := (others => '0');
  signal r_v1 : std_logic_vector(15 downto 0) := (others => '0');
  signal r_v2, r_v4, r_cv : std_logic_vector(7 downto 0) := (others => '0');
  signal r_c1, r_c2, r_ms : unsigned(15 downto 0) := (others => '0');

  component cpu_test_rom is
    port (clk : in std_logic; a : in std_logic_vector(11 downto 0); q : out std_logic_vector(15 downto 0));
  end component;
begin
  u_pll : entity work.gw_rpll
    generic map (FCLKIN => "27", IDIV => 4, FBDIV => 15, ODIV => 8, PSDA => "0100", SDIV => 4)
    port map (clkin => clk27, clkout => memclk, clkoutp => memclk_p, clkoutd => clk, lock => lock);
  process(memclk, lock)
  begin
    if lock = '0' then por <= (others => '0'); rstn <= '0';
    elsif rising_edge(memclk) then
      if por /= x"FFFF" then por <= por + 1; else rstn <= '1'; end if;
    end if;
  end process;

  u_prog : cpu_test_rom port map (clk => memclk, a => std_logic_vector(w(11 downto 0)), q => q_prog);

  process(memclk)
    variable i : unsigned(15 downto 0);
  begin
    if rising_edge(memclk) then
      mr <= '1';
      again1 <= again; again2 <= again1;
      tmr <= tmr + 1;
      case l is
        when L_RST  => mr <= '0'; fixed <= '1'; run <= '0'; w <= (others => '0');
                       if tmr = 31 then l <= L_BOOT; end if;
        when L_BOOT => if tmr = 31 then l <= L_INIT; end if;
        when L_INIT => if p_busy = '0' then l <= L_NEXT; tmr <= (others => '0'); end if;
        when L_NEXT =>                                    -- byte i = i * 7 + i / 256
          i  := w(14 downto 0) & '0';
          b0 <= (i(4 downto 0) & "000") - i(7 downto 0) + i(15 downto 8);
          b1 <= (i(4 downto 1) & "1000") - (i(7 downto 1) & '1') + i(15 downto 8);
          if tmr = 7 then l <= L_ROM; end if;
        when L_ROM =>
          l_din <= std_logic_vector(b1) & std_logic_vector(b0);
          if w(15 downto 12) = 0 then l_din <= q_prog; end if;
          if w(15 downto 11) = "00100" then                 -- 16384 .. 20479: NOP, RTS at the end
            l_din <= x"EAEA";
            if w(10 downto 0) = "11111111111" then l_din <= x"60EA"; end if;
          end if;
          l_wr <= '1'; l <= L_REQ;
        when L_REQ =>
          if l_wr = '1' and p_busy = '0' then l_wr <= '0'; tmr <= (others => '0');
          elsif l_wr = '0' and p_busy = '0' then
            w <= w + 1; tmr <= (others => '0');
            if w = 32767 then l <= L_RST2; else l <= L_NEXT; end if;
          end if;
        when L_RST2  => mr <= '0'; fixed <= '0'; if tmr = 31 then l <= L_BOOT2; end if;
        when L_BOOT2 => if tmr = 31 then l <= L_INIT2; end if;
        when L_INIT2 => if p_busy = '0' then l <= L_RUN; end if;
        when L_RUN   => run <= '1'; if again1 /= again2 then l <= L_RST; tmr <= (others => '0'); end if;
      end case;
      if rstn = '0' then l <= L_RST; tmr <= (others => '0'); mr <= '0'; l_wr <= '0'; run <= '0'; end if;
    end if;
  end process;
  m_addr <= "000000" & std_logic_vector(w(14 downto 0)) & '0' when run = '0' else p_addr;
  m_len  <= "0000001" when run = '0' else p_len;

  u_m : entity work.psram_burst
    generic map (FREQ => 86400000)
    port map (clk => memclk, clk_p => memclk_p, resetn => mr, fixed => fixed, read => p_read, write => l_wr,
      addr => m_addr, len => m_len, din => l_din, byte_write => '0', dout => p_dout, rvalid => p_rvalid,
      wtake => p_wtake, busy => p_busy, psram_ck => O_psram_ck(0), psram_cs_n => O_psram_cs_n(0),
      psram_rwds => IO_psram_rwds(0), psram_dq => IO_psram_dq(7 downto 0));
  O_psram_ck(1) <= '0'; O_psram_cs_n(1) <= '1'; IO_psram_rwds(1) <= 'Z'; IO_psram_dq(15 downto 8) <= (others => 'Z');
  O_psram_ck_n <= "00"; O_psram_reset_n <= lock & lock;

  u_c : entity work.cpu_sys
    port map (clk => clk, reset => reset, irq1 => '0', pad => x"F", pad_o => open,
      vdc_cs => cvdc, vce_cs => open, psg_cs => cpsg, b_addr => ba, b_dout => bd, b_wr => bw, b_rd => open,
      vdc_din => x"00", vce_din => x"00", vdc_busy => '0', rom_mask => "0000111", rom_mode => "00", menu => '0', cart_cs => open, cart_din => x"00", bram_wr => open, miss => miss,
      memclk => memclk, p_read => p_read, p_addr => p_addr, p_len => p_len, p_dout => p_dout,
      p_rvalid => p_rvalid, p_busy => p_busy);

  process(clk)
    variable ok : boolean;
  begin
    if rising_edge(clk) then
      run1 <= run; run2 <= run1; reset <= not run2;
      tc <= tc + 1;
      if miss = '1' then mc <= mc + 1; end if;
      if bw = '1' and cvdc = '1' then
        vn <= vn + 1;
        if vn = 0 then
          if ba(1 downto 0) /= "00" or bd /= x"55" then cv(0) <= '1'; end if;
        else
          -- bank 1: i = 8192 + vn - 1, byte = i * 7 + i / 256
          tx <= tx + 7;
          if unsigned(bd) /= tx then cv(1) <= '1'; end if;
          if ba(1 downto 0) /= '1' & (not vn(0)) then cv(2) <= '1'; end if;
        end if;
      end if;
      if vn = 0 then tx <= x"20"; end if;                   -- (8192 * 7 + 32) mod 256
      fin <= '0';
      if bw = '1' and cpsg = '1' then
        if ba(0) = '0' then test <= unsigned(bd);
        else
          case to_integer(test) is
            when 1 => v1 <= v1(7 downto 0) & bd;             -- low byte first
            when 2 => v2 <= bd;
            when 4 => v4 <= bd;
            when 5 =>
              tc <= (others => '0');
              if bd = x"02" then c1 <= tc(17 downto 2); end if;
              if bd = x"03" then c2 <= tc(17 downto 2); end if;
            when 6 => fin <= '1';
            when others => null;
          end case;
        end if;
      end if;
      wdog <= wdog + 1;                                     -- 0.39 s
      if (fin = '1' or wdog = "11111111111111111111111") and reset = '0' then
        ok := fin = '1' and v1 = x"7637" and v2 = x"4D" and (v4 = x"18" or v4 = x"17") and cv = x"00" and vn = 257;
        runs <= runs + 1;
        if not ok and bad /= x"FFFF" then bad <= bad + 1; end if;
        r_v1 <= v1; r_v2 <= v2; r_v4 <= v4; r_c1 <= c1; r_c2 <= c2; r_ms <= mc; r_cv <= cv;
        if vn /= 257 then r_cv(7) <= '1'; end if;
        again <= not again;
      end if;
      if reset = '1' then
        test <= (others => '0'); v1 <= (others => '0'); v2 <= (others => '0'); v4 <= (others => '0');
        cv <= (others => '0'); vn <= (others => '0'); mc <= (others => '0'); wdog <= (others => '0'); fin <= '0';
      end if;
      if btn_s1_n = '0' then bad <= (others => '0'); runs <= (others => '0'); end if;
    end if;
  end process;

  u_uart : entity work.uart_report
    generic map (
      TPL => "CPU R=#### E=#### V1=#### V2=## V4=## CV=## C1=#### C2=#### M=####" & CR & LF,
      NNIB => 4+4+4+2+2+2+4+4+4, CLKS_PER_BIT => 188, PERIOD_BITS => 24)
    port map (clk => clk, snap => std_logic_vector(runs) & std_logic_vector(bad) & r_v1 & r_v2 & r_v4 & r_cv
      & std_logic_vector(r_c1) & std_logic_vector(r_c2) & std_logic_vector(r_ms), tx => utx);
  uart_tx <= utx; uart_tx2 <= utx;
  led_n(0) <= '0' when bad /= 0 else '1';
  led_n(1) <= '1';
  led_n(2) <= '0' when runs /= bad else '1';
  led_n(3) <= '1';
  led_n(4) <= not runs(1);
  led_n(5) <= '1';
end architecture;
