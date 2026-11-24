-- pce_core with two PSRAM models running rom.bin; writes raw frames f000.raw...
-- (line buffer stream: per dot "line dot colour" packed as 288/384/576 x 240 text is
-- avoided: each written dot is 3 bytes: line low, line high + div, colours in two chars)
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity tb_pce is
  generic (FRAMES : integer := 4; ROMBITS : integer := 12; MASK : integer := 0; PADBTN : integer := 0; PADAT : integer := 0);
end entity;
architecture s of tb_pce is
  constant T : time := 11.576 ns;
  signal memclk, memclk_p, clk, rstn, reset : std_logic := '0';
  signal stop : boolean := false;
  signal r0, v0, w0t, b0, c0, n0, rw0, r1, w1, v1, w1t, b1, c1, n1, rw1 : std_logic;
  signal a0, a1 : std_logic_vector(21 downto 0);
  signal l0, l1 : std_logic_vector(6 downto 0);
  signal q0, q1, d1 : std_logic_vector(15 downto 0);
  signal dq0, dq1, bd : std_logic_vector(7 downto 0);
  signal ba : std_logic_vector(9 downto 0);
  signal po : std_logic_vector(1 downto 0);
  signal pad : std_logic_vector(3 downto 0);
  signal psg, bw, pw, ft, ms : std_logic;
  signal pa : std_logic_vector(10 downto 0);
  signal pc : std_logic_vector(8 downto 0);
  signal pd : std_logic_vector(1 downto 0);
  signal fr : integer := 0;
begin
  memclk <= not memclk after T/2 when not stop;
  memclk_p <= transport memclk after T/4;
  process begin
    wait until rising_edge(memclk); clk <= '1';
    wait until rising_edge(memclk); wait until rising_edge(memclk); clk <= '0';
    wait until rising_edge(memclk);
  end process;
  rstn <= '1' after 1 us;
  reset <= '1', '0' after 200 us;
  u_m0 : entity work.psram_burst generic map (FREQ => 86400000)
    port map (memclk, memclk_p, rstn, '0', r0, '0', a0, l0, x"0000", '0', q0, v0, w0t, b0, c0, n0, rw0, dq0);
  u_r0 : entity work.hyperram_model generic map (ABITS => ROMBITS, INIT => "rom.bin") port map (c0, n0, rw0, dq0);
  u_m1 : entity work.psram_burst generic map (FREQ => 86400000)
    port map (memclk, memclk_p, rstn, '1', r1, w1, a1, l1, d1, '0', q1, v1, w1t, b1, c1, n1, rw1, dq1);
  u_r1 : entity work.hyperram_model generic map (ABITS => 16) port map (c1, n1, rw1, dq1);
  u_c : entity work.pce_core port map (clk => clk, reset => reset, memclk => memclk, pad => pad, pad_o => po,
    rom_mask => std_logic_vector(to_unsigned(MASK, 7)), rom_384 => '0', psg_cs => psg, b_wr => bw, b_addr => ba, b_dout => bd,
    pix_we => pw, pix_addr => pa, pix_color => pc, pix_div => pd, frame_t => ft, miss => ms,
    p0_read => r0, p0_addr => a0, p0_len => l0, p0_dout => q0, p0_rvalid => v0, p0_busy => b0,
    p1_read => r1, p1_write => w1, p1_addr => a1, p1_len => l1, p1_din => d1, p1_dout => q1, p1_rvalid => v1, p1_busy => b1);
  -- pad: SEL = 1 directions, 0 buttons (run sel II I), low = pressed
  pad <= "1111" when po(0) = '1' or fr < PADAT or PADBTN = 0 else not std_logic_vector(to_unsigned(PADBTN, 4));
  process
    type cf is file of character;
    file f : cf;
    variable lastft : std_logic := '0';
    variable opened : boolean := false;
    variable ln : integer := 0;
    variable lb : std_logic := '0';
    variable fn : string(1 to 8) := "f000.raw";
  begin
    loop
      wait until rising_edge(clk);
      if psg = '1' and bw = '1' then
        report "psg " & to_hstring(ba) & " = " & to_hstring(bd) & " frame " & integer'image(fr);
      end if;
      if ft /= lastft then
        lastft := ft;
        if opened then file_close(f); end if;
        fr <= fr + 1;
        exit when fr = FRAMES;
        fn(2) := character'val(48 + fr / 100); fn(3) := character'val(48 + fr / 10 mod 10); fn(4) := character'val(48 + fr mod 10);
        file_open(f, fn, write_mode); opened := true;
        ln := 18;
        lb := '0';
      end if;
      if pw = '1' and opened then
        if pa(10) /= lb then lb := pa(10); ln := ln + 1; end if;
        write(f, character'val(ln mod 256)); write(f, character'val(ln / 256 + 2 * to_integer(unsigned(pd))));
        write(f, character'val(to_integer(unsigned(pa(7 downto 0))))); write(f, character'val(to_integer(unsigned(pa(9 downto 8)))));
        write(f, character'val(to_integer(unsigned(pc(7 downto 0))))); write(f, character'val(to_integer(unsigned(pc(8 downto 8)))));
      end if;
    end loop;
    stop <= true; wait;
  end process;
end architecture;
