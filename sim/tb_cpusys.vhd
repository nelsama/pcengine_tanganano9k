-- cpu_sys + psram_burst + HyperRAM model running cputest.s. Prints the values
-- the program sends and the time / misses of each part.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity tb_cpusys is end entity;
architecture s of tb_cpusys is
  constant T : time := 11.576 ns;
  signal memclk, memclk_p, clk, rstn, reset : std_logic := '0';
  signal stop : boolean := false;
  signal rd, rv, wt, by, ck, cs, rwds, miss : std_logic;
  signal ad : std_logic_vector(21 downto 0);
  signal ln : std_logic_vector(6 downto 0);
  signal dq : std_logic_vector(15 downto 0);
  signal dq8, bd : std_logic_vector(7 downto 0);
  signal ba : std_logic_vector(9 downto 0);
  signal po : std_logic_vector(1 downto 0);
  signal cvdc, cvce, cpsg, bw, br : std_logic;
begin
  memclk <= not memclk after T/2 when not stop;
  memclk_p <= transport memclk after T/4;
  process begin                      -- clk / 4, rising edges aligned
    wait until rising_edge(memclk); clk <= '1';
    wait until rising_edge(memclk); wait until rising_edge(memclk); clk <= '0';
    wait until rising_edge(memclk);
  end process;
  rstn <= '1' after 1 us;
  u_m : entity work.psram_burst generic map (FREQ => 86400000)
    port map (memclk, memclk_p, rstn, '0', rd, '0', ad, ln, x"0000", '0', dq, rv, wt, by, ck, cs, rwds, dq8);
  u_r : entity work.hyperram_model generic map (ABITS => 15, INIT => "rom.bin") port map (ck, cs, rwds, dq8);
  reset <= '1', '0' after 200 us;    -- the PSRAM is ready
  u_c : entity work.cpu_sys port map (clk => clk, reset => reset, irq1 => '0', pad => x"F", pad_o => po,
    vdc_cs => cvdc, vce_cs => cvce, psg_cs => cpsg, b_addr => ba, b_dout => bd, b_wr => bw, b_rd => br,
    vdc_din => x"00", vce_din => x"00", vdc_busy => '0', rom_mask => "0000111", rom_mode => "00", menu => '0', cart_cs => open, cart_din => x"00", bram_wr => open, miss => miss,
    memclk => memclk, p_read => rd, p_addr => ad, p_len => ln, p_dout => dq, p_rvalid => rv, p_busy => by);
  process
    variable n, v, sum, k, t0, m0 : integer := 0;
    variable now_c, miss_c, vn : integer := 0;
    variable bad : boolean := false;
  begin
    loop
      wait until rising_edge(clk);
      now_c := now_c + 1;
      if miss = '1' then miss_c := miss_c + 1; end if;
      if bw = '1' and cvdc = '1' then
        vn := vn + 1;
        if vn = 1 then
          if ba /= "0000000000" or bd /= x"55" then report "FAIL st0"; bad := true; end if;
        else
          -- bank 1 holds i * 7 + i / 256 ... see mkrom.py: byte = (i * 7 + (i >> 8)) and 255, i from 8192
          v := ((8192 + vn - 2) * 7 + (8192 + vn - 2) / 256) mod 256;
          if to_integer(unsigned(bd)) /= v or to_integer(unsigned(ba)) /= 2 + (vn - 2) mod 2 then
            if not bad then report "FAIL tia " & integer'image(vn) & " " & to_hstring(bd) & " want " & integer'image(v); end if;
            bad := true;
          end if;
        end if;
      end if;
      if bw = '1' and cpsg = '1' then
        if ba(0) = '0' then n := to_integer(unsigned(bd));
        else
          report "test " & integer'image(n) & " value " & integer'image(to_integer(unsigned(bd))) & "  cpu cycles "
            & integer'image((now_c - t0) / 3) & " misses " & integer'image(miss_c - m0) & "  vdc writes " & integer'image(vn);
          t0 := now_c; m0 := miss_c;
          exit when n = 6;
        end if;
      end if;
      exit when now_c > 8000000;
    end loop;
    if bad or n /= 6 or vn /= 257 then report "RESULT: FAIL"; else report "RESULT: end reached"; end if;
    stop <= true; wait;
  end process;
end architecture;
