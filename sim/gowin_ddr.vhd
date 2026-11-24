-- ODDR / IDDR as in the Gowin prim_sim.vhd, without GSR
library ieee; use ieee.std_logic_1164.all;
entity ODDR is
  port (CLK, D0, D1 : in std_logic; TX : in std_logic := '0'; Q0, Q1 : out std_logic);
end entity;
architecture s of ODDR is
  signal a0, a1, a2, b0, b1, b2, t0, t1, t2, t3 : std_logic := '0';
begin
  process(CLK) begin
    if rising_edge(CLK) then
      a0 <= D0; b0 <= D1; a1 <= a0; b1 <= b0; b2 <= b1; t0 <= TX; t1 <= t0; t3 <= t2;
    end if;
    if falling_edge(CLK) then a2 <= a1; t2 <= t1; end if;
  end process;
  Q0 <= a2 when CLK = '1' else b2;
  Q1 <= t3;
end architecture;
library ieee; use ieee.std_logic_1164.all;
entity IDDR is port (CLK, D : in std_logic; Q0, Q1 : out std_logic); end entity;
architecture s of IDDR is
  signal a, b : std_logic := '0';
begin
  process(CLK) begin
    if rising_edge(CLK) then a <= D; Q0 <= a; Q1 <= b; end if;
    if falling_edge(CLK) then b <= D; end if;
  end process;
end architecture;
