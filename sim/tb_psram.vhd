library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity tb_psram is
  generic (TRT_PS : integer := 6000; DROP : integer := -1; PASSES : integer := 3);
end entity;
architecture s of tb_psram is
  constant T : time := 11.576 ns;
  signal clk, clk_p, rstn : std_logic := '0';
  signal stop : boolean := false;
  signal mr, mf, rd, wr, bw, rv, wt, by, ck, cs, rwds, err : std_logic;
  signal dq8 : std_logic_vector(7 downto 0);
  signal ad : std_logic_vector(21 downto 0);
  signal ln : std_logic_vector(6 downto 0);
  signal di, do, e1, e2, e3, fg, fx, sl, ps : std_logic_vector(15 downto 0);
  signal ph : std_logic_vector(3 downto 0);
  signal fa : std_logic_vector(23 downto 0);
  signal r1f, r1vn, r1vx, r9f, r33f, r16v, w1 : std_logic_vector(7 downto 0);
  function i(v : std_logic_vector) return string is begin return integer'image(to_integer(unsigned(v))); end;
begin
  clk <= not clk after T/2 when not stop;
  clk_p <= transport clk after T/4;
  rstn <= '1' after 1 us;
  u_m : entity work.psram_burst generic map (FREQ => 86400000)
    port map (clk, clk_p, mr, mf, rd, wr, ad, ln, di, bw, do, rv, wt, by, ck, cs, rwds, dq8);
  u_t : entity work.psram_tester generic map (WBITS => 13, TBITS => 11)
    port map (clk, rstn, '0', mr, mf, rd, wr, bw, ad, ln, di, do, rv, wt, by, ph, ps, e1, e2, e3,
              fa, fg, fx, r1f, r1vn, r1vx, r9f, r33f, r16v, w1, sl, err);
  u_r : entity work.hyperram_model generic map (ABITS => 13, TRT => TRT_PS * (1 ns / 1000), DROP => DROP)
    port map (ck, cs, rwds, dq8);
  process begin
    wait until (rstn = '1' and to_integer(unsigned(ps)) = PASSES) for 20 ms;
    wait for 2 us;
    report "pass " & i(ps) & " phase " & i(ph) & " errors " & i(e1) & "/" & i(e2) & "/" & i(e3) & " at " & i(fa)
      & " got " & i(fg) & " exp " & i(fx)
      & " R1F " & i(r1f) & " R1V " & i(r1vn) & "-" & i(r1vx) & " R9F " & i(r9f) & " R33F " & i(r33f)
      & " R16V " & i(r16v) & " W1 " & i(w1) & " slow " & i(sl);
    if err = '0' and to_integer(unsigned(ps)) = PASSES then report "RESULT: OK"; else report "RESULT: FAIL"; end if;
    stop <= true; wait;
  end process;
end architecture;
