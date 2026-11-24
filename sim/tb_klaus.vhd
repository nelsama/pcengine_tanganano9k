-- Klaus Dormann's 6502_functional_test.bin on huc6280 (KLAUS = true); start $0400
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity tb_klaus is end entity;
architecture s of tb_klaus is
  signal clk, reset, mem, we, fast, sync : std_logic := '0';
  signal addr : std_logic_vector(20 downto 0);
  signal dout, din : std_logic_vector(7 downto 0) := x"00";
  signal dbg  : std_logic_vector(55 downto 0);
  signal stop : boolean := false;
  type mem_t is array (0 to 65535) of natural range 0 to 255;
  type char_file is file of character;
begin
  clk <= not clk after 5 ns when not stop;
  dut : entity work.huc6280 generic map (true) port map (clk, reset, '1', addr, mem, we, dout, din, "000", fast, sync, dbg);
  process
    variable m : mem_t;
    file fb : char_file open read_mode is "6502_functional_test.bin";
    variable c : character;
    variable a, last, n, vl, vh : integer := 0;
  begin
    for i in mem_t'range loop read(fb, c); m(i) := character'pos(c); end loop;
    vl := m(16#FFFE#); vh := m(16#FFFF#);
    m(16#FFFE#) := 0; m(16#FFFF#) := 4;
    reset <= '1'; wait until rising_edge(clk); wait until rising_edge(clk); reset <= '0';
    loop
      wait for 1 ns;
      a := to_integer(unsigned(addr(15 downto 0)));
      if sync = '1' then
        if n = 0 then m(16#FFFE#) := vl; m(16#FFFF#) := vh; end if;
        n := n + 1;
        exit when a = last;            -- jump or branch to itself: trap or success
        last := a;
      end if;
      din <= std_logic_vector(to_unsigned(m(a), 8));
      wait for 1 ns;
      if we = '1' then m(a) := to_integer(unsigned(dout)); end if;
      wait until rising_edge(clk);
    end loop;
    report "stopped at " & to_hstring(addr) & " after " & integer'image(n) & " instructions, test " & to_hstring(to_unsigned(m(512), 8))
      & " dbg " & to_hstring(dbg);
    stop <= true; wait;
  end process;
end architecture;
