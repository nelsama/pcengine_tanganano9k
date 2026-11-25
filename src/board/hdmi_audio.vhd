--
-- hdmi_audio.vhd : stereo sample -> 48 kHz L & R (signed) for hdmi_tx. One-pole low
-- pass at 13 kHz against aliasing. audio only changes on a change of req.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity hdmi_audio is
  port (
    clk         : in  std_logic;                       -- 21.6 MHz
    left, right : in  unsigned(15 downto 0);           -- offset binary
    req         : in  std_logic;                       -- pixel clock domain
    audio       : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of hdmi_audio is
  signal fl, fr : unsigned(23 downto 0) := x"800000";  -- sample x 256, k = 1 / 256
  signal rq : std_logic_vector(2 downto 0) := "000";
begin
  process(clk)
  begin
    if rising_edge(clk) then
      fl <= fl + left  - fl(23 downto 8);
      fr <= fr + right - fr(23 downto 8);
      rq <= rq(1 downto 0) & req;
      if rq(2) /= rq(1) then
        audio <= (not fl(23)) & std_logic_vector(fl(22 downto 8)) & (not fr(23)) & std_logic_vector(fr(22 downto 8));
      end if;
    end if;
  end process;
end architecture;
