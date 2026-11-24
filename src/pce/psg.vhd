--
-- psg.vhd : HuC6280 PSG. clk = 21.6 MHz; one channel per clk, so every channel
-- is updated at 3.6 MHz (clk / 6). Left and right are mixed on alternate rounds
-- (1.8 MHz). 2 BSRAM: wave forms, and volume table (attenuation x sample).
-- Samples are taken as signed (centred), so a silent channel gives no offset.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity psg is
  port (
    clk, reset : in  std_logic;                       -- reset for 16 clk or more
    cs, wr     : in  std_logic;
    a          : in  std_logic_vector(3 downto 0);
    din        : in  std_logic_vector(7 downto 0);
    left, right : out signed(15 downto 0)
  );
end entity;

architecture rtl of psg is
  type r8_t  is array (0 to 7) of std_logic_vector(7 downto 0);
  type r5_t  is array (0 to 7) of std_logic_vector(4 downto 0);
  type r4_t  is array (0 to 7) of std_logic_vector(3 downto 0);
  type r12_t is array (0 to 7) of unsigned(11 downto 0);
  type u5_t  is array (0 to 7) of unsigned(4 downto 0);
  signal f_lo, ctl, bal : r8_t := (others => x"00");
  signal f_hi : r4_t := (others => x"0");
  signal dda  : r5_t := (others => "00000");
  signal cnt  : r12_t := (others => x"000");
  signal idx  : u5_t := (others => "00000");
  signal sel  : unsigned(2 downto 0) := "000";
  signal mvol : std_logic_vector(7 downto 0) := x"00";
  signal lfo_f : unsigned(7 downto 0) := x"00";
  signal lfo_c : std_logic_vector(7 downto 0) := x"00";
  signal ncr4, ncr5 : std_logic_vector(5 downto 0) := "000000";   -- enable, frequency
  -- CPU operations executed in the slot of the channel
  signal p_wave, p_rst, c40 : std_logic := '0';
  signal p_ch : unsigned(2 downto 0) := "000";
  signal p_d  : std_logic_vector(4 downto 0) := "00000";
  -- slots
  signal s    : unsigned(2 downto 0) := "000";
  signal lr   : std_logic := '0';
  signal ci   : integer range 0 to 7;
  signal c_ctl, c_bal : std_logic_vector(7 downto 0);
  signal c_idx : unsigned(4 downto 0);
  signal c_cnt : unsigned(11 downto 0);
  signal lfoon : std_logic;
  signal lfo_n : unsigned(7 downto 0) := x"00";
  signal m1   : signed(5 downto 0) := (others => '0');   -- channel 1 sample - 16
  signal w_we : std_logic;
  signal w_a  : std_logic_vector(7 downto 0);
  signal w_q  : std_logic_vector(4 downto 0);
  -- noise
  signal n4, n5 : std_logic_vector(17 downto 0) := (0 => '1', others => '0');
  signal nc4, nc5 : unsigned(11 downto 0) := (others => '0');
  -- pipeline
  signal s1   : unsigned(2 downto 0) := "000";
  signal lr1, lr2, on1, on2, dd1, nz1, nb1 : std_logic := '0';
  signal d1   : std_logic_vector(4 downto 0) := "00000";
  signal at1  : unsigned(6 downto 0) := (others => '0');
  signal last2 : std_logic := '0';
  signal smp  : std_logic_vector(4 downto 0);
  signal t_a  : std_logic_vector(9 downto 0);
  type tab_t is array (0 to 1023) of std_logic_vector(13 downto 0);
  function mktab return tab_t is
    variable t : tab_t;
    variable g : integer := 170 * 1024;
  begin
    for at in 0 to 31 loop
      for w in 0 to 31 loop
        t(at * 32 + w) := std_logic_vector(to_signed(((2 * w - 31) * (g / 16)) / 64, 14));
      end loop;
      g := (g / 32) * 862 / 32;                        -- -1.5 dB
    end loop;
    return t;
  end function;
  signal tab  : tab_t := mktab;
  attribute syn_romstyle : string;
  attribute syn_romstyle of tab : signal is "block_rom";
  signal t_q  : std_logic_vector(13 downto 0);
  signal acc  : signed(15 downto 0) := (others => '0');

  function nper(f : std_logic_vector(5 downto 0)) return unsigned is
  begin
    if f(4 downto 0) = "11111" then return to_unsigned(32, 12); end if;
    return '0' & unsigned(not f(4 downto 0)) & "000000";
  end function;
  function lfsr(n : std_logic_vector(17 downto 0)) return std_logic_vector is
  begin
    return (n(0) xor n(1) xor n(11) xor n(12) xor n(17)) & n(17 downto 1);
  end function;
  function addend(q : std_logic_vector(13 downto 0); en : std_logic) return signed is
  begin
    if en = '1' then return resize(signed(q), 16); end if;
    return to_signed(0, 16);
  end function;
begin
  -- registers ------------------------------------------------------------------
  process(clk)
    variable k : integer range 0 to 7;
    variable we_c : std_logic;
    variable dc : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk) then
      k := to_integer(sel);
      we_c := '0'; dc := din;
      if reset = '1' then k := to_integer(s); we_c := '1'; dc := x"00"; end if;
      if cs = '1' and wr = '1' then
        case a is
          when x"0" => sel <= unsigned(din(2 downto 0));
          when x"1" => mvol <= din;
          when x"2" => f_lo(to_integer(sel)) <= din;
          when x"3" => f_hi(to_integer(sel)) <= din(3 downto 0);
          when x"4" => we_c := '1';
          when x"5" => bal(to_integer(sel)) <= din;
          when x"6" => dda(to_integer(sel)) <= din(4 downto 0);
          when x"7" =>
            if sel = 4 then ncr4 <= din(7) & din(4 downto 0); end if;
            if sel = 5 then ncr5 <= din(7) & din(4 downto 0); end if;
          when x"8" => lfo_f <= unsigned(din);
          when x"9" => lfo_c <= din;
          when others => null;
        end case;
      end if;
      if we_c = '1' then ctl(k) <= dc; end if;
      if reset = '1' then
        mvol <= x"00"; lfo_c <= x"00"; ncr4 <= "000000"; ncr5 <= "000000"; sel <= "000";
      end if;
    end if;
  end process;
  ci <= to_integer(s);
  c_ctl <= ctl(ci);
  c_bal <= bal(ci);
  c_idx <= idx(ci);
  c_cnt <= cnt(ci);
  lfoon <= '1' when lfo_c(1 downto 0) /= "00" else '0';

  -- slots ------------------------------------------------------------------------
  process(clk)
    variable per : unsigned(11 downto 0);
    variable ni  : unsigned(4 downto 0);
    variable iw, adv : std_logic;
    variable nw  : std_logic_vector(4 downto 0);
  begin
    if rising_edge(clk) then
      if s = 5 then s <= "000"; lr <= not lr; else s <= s + 1; end if;
      if reset = '1' then s <= s + 1; end if;                      -- also clears 6 and 7

      -- period and wave index
      per := unsigned(f_hi(ci)) & unsigned(f_lo(ci));
      if s = 0 and lfoon = '1' then
        case lfo_c(1 downto 0) is
          when "01"   => per := per + unsigned(resize(m1, 12));
          when "10"   => per := per + unsigned(resize(m1, 10) & "00");
          when others => per := per + unsigned(resize(m1, 8) & "0000");
        end case;
      end if;
      ni := c_idx; iw := '0'; adv := '0';
      if c_cnt = 0 then
        cnt(ci) <= per - 1;
        adv := '1';
        if s = 1 and lfoon = '1' then                               -- slowed by the LFO frequency
          if lfo_n = 0 then lfo_n <= lfo_f - 1; else lfo_n <= lfo_n - 1; adv := '0'; end if;
        end if;
      else
        cnt(ci) <= c_cnt - 1;
      end if;
      if c_ctl(7 downto 6) = "10" and adv = '1' then ni := ni + 1; iw := '1'; end if;
      if s = 1 and lfo_c(7) = '1' then ni := "00000"; iw := '1'; end if;   -- LFO reset

      -- wave data: c_ctl(6) = 0 writes, the index moves while the channel is off
      if p_wave = '1' and p_ch = s then
        p_wave <= '0';
        if c_ctl(7 downto 6) = "00" then ni := ni + 1; iw := '1'; end if;
      end if;
      if p_rst = '1' and p_ch = s then p_rst <= '0'; ni := "00000"; iw := '1'; end if;
      if iw = '1' then idx(ci) <= ni; end if;

      if cs = '1' and wr = '1' then
        if a = x"6" then p_wave <= '1'; p_ch <= sel; p_d <= din(4 downto 0); end if;
        if a = x"4" then
          p_ch <= sel;
          if din(6) = '0' and c40 = '1' then p_rst <= '1'; end if;
        end if;
      end if;

      -- noise
      if s = 0 then
        if nc4 = 0 then nc4 <= nper(ncr4); n4 <= lfsr(n4); else nc4 <= nc4 - 1; end if;
        if nc5 = 0 then nc5 <= nper(ncr5); n5 <= lfsr(n5); else nc5 <= nc5 - 1; end if;
      end if;

      -- stage 1
      s1 <= s; lr1 <= lr;
      on1 <= c_ctl(7);
      if s(2 downto 1) = "11" or (s = 1 and lfoon = '1') then on1 <= '0'; end if;
      dd1 <= c_ctl(6); d1 <= dda(ci);
      nz1 <= '0'; nb1 <= n4(0);
      if s = 4 then nz1 <= ncr4(5); end if;
      if s = 5 then nz1 <= ncr5(5); nb1 <= n5(0); end if;
      if lr = '0' then nw := '0' & c_bal(7 downto 4); else nw := '0' & c_bal(3 downto 0); end if;
      if lr = '0' then
        at1 <= ("00" & unsigned(not c_ctl(4 downto 0))) + ("00" & unsigned(not nw(3 downto 0)) & '0')
               + ("00" & unsigned(not mvol(7 downto 4)) & '0');
      else
        at1 <= ("00" & unsigned(not c_ctl(4 downto 0))) + ("00" & unsigned(not nw(3 downto 0)) & '0')
               + ("00" & unsigned(not mvol(3 downto 0)) & '0');
      end if;
      if s1 = 1 then m1 <= signed('0' & w_q) - 16; end if;
      -- stage 2 -> mix
      on2 <= on1;
      if at1(6 downto 5) /= "00" then on2 <= '0'; end if;
      lr2 <= lr1;
      last2 <= '0';
      if s1 = 5 then last2 <= '1'; end if;
      if last2 = '1' then
        if lr2 = '0' then left <= acc + addend(t_q, on2); else right <= acc + addend(t_q, on2); end if;
        acc <= (others => '0');
      else
        acc <= acc + addend(t_q, on2);
      end if;
      if reset = '1' then
        p_wave <= '0'; p_rst <= '0'; lfo_n <= x"00";
        idx(ci) <= "00000"; cnt(ci) <= x"000";
        acc <= (others => '0'); left <= (others => '0'); right <= (others => '0');
      end if;
    end if;
  end process;
  c40 <= ctl(to_integer(sel))(6);

  -- wave RAM: written in the slot of the channel
  w_we <= '1' when p_wave = '1' and p_ch = s and c_ctl(6) = '0' else '0';
  w_a  <= std_logic_vector(s) & std_logic_vector(c_idx);
  u_w : entity work.sdp_ram generic map (8, 5) port map (clk, w_we, w_a, p_d, clk, w_a, w_q);

  smp <= d1 when dd1 = '1' else (others => nb1) when nz1 = '1' else w_q;
  t_a <= std_logic_vector(at1(4 downto 0)) & smp;
  process(clk)
  begin
    if rising_edge(clk) then t_q <= tab(to_integer(unsigned(t_a))); end if;
  end process;
end architecture;
