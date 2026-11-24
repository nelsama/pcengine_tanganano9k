-- simulation version of menu_rom.v: reads menu.hex
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all; use std.textio.all;
entity menu_rom is
  port (clk : in std_logic; a : in std_logic_vector(13 downto 0); q : out std_logic_vector(7 downto 0));
end entity;
architecture s of menu_rom is
  type m_t is array (0 to 16383) of std_logic_vector(7 downto 0);
  impure function load return m_t is
    file f : text open read_mode is "menu.hex"; variable l : line; variable m : m_t;
  begin
    for i in m_t'range loop readline(f, l); hread(l, m(i)); end loop;
    return m;
  end function;
  signal m : m_t := load;
begin
  process(clk) begin if rising_edge(clk) then q <= m(to_integer(unsigned(a))); end if; end process;
end architecture;
