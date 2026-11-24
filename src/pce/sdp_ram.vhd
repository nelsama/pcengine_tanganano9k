-- sdp_ram.vhd : one write port, one registered read port, independent clocks
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdp_ram is
  generic (AW : integer; DW : integer);
  port (
    wclk, we : in  std_logic;
    wa       : in  std_logic_vector(AW - 1 downto 0);
    wd       : in  std_logic_vector(DW - 1 downto 0);
    rclk     : in  std_logic;
    ra       : in  std_logic_vector(AW - 1 downto 0);
    rd       : out std_logic_vector(DW - 1 downto 0)
  );
end entity;

architecture rtl of sdp_ram is
  type ram_t is array (0 to 2**AW - 1) of std_logic_vector(DW - 1 downto 0);
  signal ram : ram_t := (others => (others => '0'));
  attribute syn_ramstyle : string;
  attribute syn_ramstyle of ram : signal is "block_ram";
begin
  process(wclk)
  begin
    if rising_edge(wclk) then
      if we = '1' then ram(to_integer(unsigned(wa))) <= wd; end if;
    end if;
  end process;
  process(rclk)
  begin
    if rising_edge(rclk) then
      rd <= ram(to_integer(unsigned(ra)));
    end if;
  end process;
end architecture;
