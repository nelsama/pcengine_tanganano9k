--
-- Transmisor UART minimo, 8N1, para depuracion.
-- CLKS_PER_BIT = frecuencia de clk / baudios (47,25 MHz / 115200 = 410).
-- Pulso de 1 ciclo en "start" con "data" valido; "busy" = 1 mientras envia.
--
library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity uart_tx is
  generic (
    CLKS_PER_BIT : integer := 410
  );
  port (
    clk   : in  std_logic;
    start : in  std_logic;
    data  : in  std_logic_vector(7 downto 0);
    busy  : out std_logic;
    tx    : out std_logic
  );
end entity;

architecture rtl of uart_tx is
  signal sr     : std_logic_vector(9 downto 0) := (others => '1');
  signal nbits  : integer range 0 to 10 := 0;
  signal cnt    : integer range 0 to CLKS_PER_BIT - 1 := 0;
begin
  busy <= '1' when nbits /= 0 else '0';
  tx   <= sr(0);

  process(clk)
  begin
    if rising_edge(clk) then
      if nbits = 0 then
        if start = '1' then
          sr    <= '1' & data & '0';      -- stop, datos (LSB primero), start
          nbits <= 10;
          cnt   <= CLKS_PER_BIT - 1;
        end if;
      elsif cnt = 0 then
        sr    <= '1' & sr(9 downto 1);
        nbits <= nbits - 1;
        cnt   <= CLKS_PER_BIT - 1;
      else
        cnt <= cnt - 1;
      end if;
    end if;
  end process;
end architecture;
