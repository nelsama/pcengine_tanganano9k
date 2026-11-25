-- pce_top with both PSRAM dies and an SD card. Button I is pressed at frame PRESS
-- (opens the first entry), S2 at frame S2AT (back to the menu). Frames in f*.raw.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity tb_top is
  generic (FRAMES : integer := 12; PRESS : integer := 8; S2AT : integer := 999);
end entity;
architecture s of tb_top is
  constant F : time := 16.6833 ms;
  signal ck, csn, rwds, ckn, rst : std_logic_vector(1 downto 0);
  signal dq : std_logic_vector(15 downto 0);
  signal sck, cmd, cs, dat : std_logic;
  signal fire, s2 : std_logic := '1';
  signal led : std_logic_vector(5 downto 0);
begin
  fire <= '1', '0' after F * PRESS, '1' after F * (PRESS + 2);
  s2 <= '1', '0' after F * S2AT, '1' after F * (S2AT + 1);
  dut : entity work.pce_top port map (clk27 => '0', btn_s1_n => '1', btn_s2_n => s2, btn_start1 => '1', btn_credit => '1',
    led_n => led, joy_up => '1', joy_down => '1', joy_left => '1', joy_right => '1', joy_fire => fire, joy_btn2 => '1',
    sd_sck => sck, sd_cmd => cmd, sd_cs => cs, sd_dat0 => dat, O_psram_ck => ck, O_psram_ck_n => ckn, IO_psram_rwds => rwds,
    IO_psram_dq => dq, O_psram_reset_n => rst, O_psram_cs_n => csn);
  u_r0 : entity work.hyperram_model generic map (ABITS => 18) port map (ck(0), csn(0), rwds(0), dq(7 downto 0));
  u_r1 : entity work.hyperram_model generic map (ABITS => 16) port map (ck(1), csn(1), rwds(1), dq(15 downto 8));
  u_sd : entity work.sd_model port map (sck, cs, cmd, dat);
  process begin
    wait for F * FRAMES;
    report "end, led_n " & to_string(led);
    std.env.stop(0);
  end process;
end architecture;
