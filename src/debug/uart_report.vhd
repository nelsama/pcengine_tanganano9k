--
-- Informe periodico por UART para depuracion.
--
-- Cada 2^PERIOD_BITS ciclos (y al arrancar) captura "snap" y envia la
-- plantilla TPL. Cada '#' de TPL se sustituye por el siguiente nibble de
-- snap en hexadecimal, empezando por el mas significativo. TPL debe
-- contener exactamente NNIB caracteres '#'. Terminar TPL con CR & LF.
--
-- Ejemplo:
--   TPL  => "P=#### E=#" & CR & LF,  NNIB => 5,
--   snap => pasadas(15 downto 0) & '0' & err(2 downto 0)
--
library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity uart_report is
  generic (
    TPL          : string;
    NNIB         : integer;
    CLKS_PER_BIT : integer := 410;      -- 47,25 MHz / 115200
    PERIOD_BITS  : integer := 26        -- ~1,4 s a 47,25 MHz
  );
  port (
    clk  : in  std_logic;
    snap : in  std_logic_vector(NNIB * 4 - 1 downto 0);
    tx   : out std_logic
  );
end entity;

architecture rtl of uart_report is

  type tpl_t is array (0 to TPL'length - 1) of std_logic_vector(7 downto 0);
  function to_tpl(s : string) return tpl_t is
    variable r : tpl_t;
  begin
    for i in 0 to s'length - 1 loop
      r(i) := std_logic_vector(to_unsigned(character'pos(s(s'low + i)), 8));
    end loop;
    return r;
  end function;
  constant TPL_ROM : tpl_t := to_tpl(TPL);

  signal cnt      : unsigned(PERIOD_BITS - 1 downto 0) := (others => '0');
  signal active   : std_logic := '0';
  signal pos      : integer range 0 to TPL'length - 1 := 0;
  signal hold     : std_logic := '0';
  signal sh       : std_logic_vector(NNIB * 4 - 1 downto 0) := (others => '0');
  signal tx_start : std_logic := '0';
  signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_busy  : std_logic;

begin

  u_tx : entity work.uart_tx
    generic map (CLKS_PER_BIT => CLKS_PER_BIT)
    port map (
      clk   => clk,
      start => tx_start,
      data  => tx_data,
      busy  => tx_busy,
      tx    => tx
    );

  process(clk)
    variable c : std_logic_vector(7 downto 0);
    variable n : unsigned(3 downto 0);
  begin
    if rising_edge(clk) then
      tx_start <= '0';
      cnt      <= cnt + 1;

      if active = '0' then
        if cnt = 0 then
          active <= '1';
          pos    <= 0;
          sh     <= snap;
        end if;
      elsif hold = '1' then
        hold <= '0';                         -- busy sube un ciclo despues
      elsif tx_busy = '0' then
        c := TPL_ROM(pos);
        if c = x"23" then                    -- '#'
          n  := unsigned(sh(sh'high downto sh'high - 3));
          sh <= sh(sh'high - 4 downto 0) & "0000";
          if n < 10 then
            c := std_logic_vector(unsigned'(x"30") + resize(n, 8));
          else
            c := std_logic_vector(unsigned'(x"37") + resize(n, 8));
          end if;
        end if;
        tx_data  <= c;
        tx_start <= '1';
        hold     <= '1';
        if pos = TPL'length - 1 then
          active <= '0';
        else
          pos <= pos + 1;
        end if;
      end if;
    end if;
  end process;

end architecture;
