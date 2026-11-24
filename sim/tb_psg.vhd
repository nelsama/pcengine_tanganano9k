-- tb_psg : plays a square wave on channel 0 (period 254), then DDA, then noise;
-- measures the period and the levels of left / right.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity tb_psg is end entity;
architecture s of tb_psg is
  signal clk, reset, wr : std_logic := '0';
  signal a : std_logic_vector(3 downto 0) := x"0";
  signal d : std_logic_vector(7 downto 0) := x"00";
  signal l, r : signed(15 downto 0);
  signal stop : boolean := false;
begin
  clk <= not clk after 23.148 ns when not stop;
  dut : entity work.psg port map (clk, reset, '1', wr, a, d, l, r);
  process
    procedure w(r, v : integer) is
    begin
      a <= std_logic_vector(to_unsigned(r, 4)); d <= std_logic_vector(to_unsigned(v, 8));
      wait until falling_edge(clk); wr <= '1'; wait until falling_edge(clk); wr <= '0';
      for i in 1 to 14 loop wait until falling_edge(clk); end loop;
    end procedure;
    procedure measure(n : string) is
      variable t0, t1 : time := 0 ns; variable c, mx, mn, rx, rn : integer := 0; variable last : boolean := false;
    begin
      mx := -99999; mn := 99999; rx := -99999; rn := 99999;
      for i in 1 to 600000 loop
        wait until falling_edge(clk);
        if l > mx then mx := to_integer(l); end if; if l < mn then mn := to_integer(l); end if;
        if r > rx then rx := to_integer(r); end if; if r < rn then rn := to_integer(r); end if;
        if l > 0 and not last then c := c + 1; if c = 1 then t0 := now; end if; t1 := now; end if;
        last := l > 0;
      end loop;
      report n & ": L " & integer'image(mn) & ".." & integer'image(mx) & " R " & integer'image(rn) & ".." & integer'image(rx)
        & " rises " & integer'image(c);
      if c > 1 then report "   period us " & real'image(real((t1 - t0) / 1 ns) / real(c - 1) / 1000.0); end if;
    end procedure;
  begin
    reset <= '1'; for i in 1 to 40 loop wait until falling_edge(clk); end loop; reset <= '0';
    w(1, 16#FF#); w(0, 0); w(4, 16#40#); w(4, 0);
    for i in 0 to 31 loop if i < 16 then w(6, 31); else w(6, 0); end if; end loop;
    w(2, 254); w(3, 0); w(5, 16#FF#); w(4, 16#9F#);
    measure("square, full volume: 5270, 2258 us expected");
    w(5, 16#F5#);                 -- right 10 steps of 3 dB = 20 x 1.5 dB = -30 dB
    measure("right -30 dB: 167 expected");
    w(5, 16#FF#); w(4, 16#95#);   -- 10 x 1.5 dB = -15 dB
    measure("-15 dB: 937 expected");
    w(4, 16#DF#); w(6, 31);
    measure("DDA 31: constant 5270");
    w(4, 0); w(0, 4); w(5, 16#FF#); w(7, 16#9E#); w(4, 16#9F#);
    measure("noise");
    w(0, 4); w(4, 0); w(0, 1); w(4, 16#40#); w(4, 0); for i in 0 to 31 loop w(6, i); end loop;
    w(0, 1); w(2, 100); w(5, 16#FF#); w(4, 16#9F#);
    measure("ramp on channel 1: 889 us");
    stop <= true; wait;
  end process;
end architecture;
