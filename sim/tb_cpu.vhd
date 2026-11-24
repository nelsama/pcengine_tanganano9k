-- compares huc6280 with the trace of cpu_ref (registers, cycles, every write)
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all; use std.textio.all;
entity tb_cpu is end entity;
architecture s of tb_cpu is
  signal clk, reset, ce, mem, we, fast, sync : std_logic := '0';
  signal addr : std_logic_vector(20 downto 0);
  signal dout, din : std_logic_vector(7 downto 0) := x"00";
  signal dbg  : std_logic_vector(55 downto 0);
  signal stop : boolean := false;
  type mem_t is array (0 to 2**21 - 1) of natural range 0 to 255;
  type char_file is file of character;
begin
  clk <= not clk after 5 ns when not stop;
  ce <= '1';
  dut : entity work.huc6280 port map (clk, reset, ce, addr, mem, we, dout, din, "000", fast, sync, dbg);
  process
    variable m : mem_t;
    file fb : char_file open read_mode is "mem.bin";
    file ft : text open read_mode is "trace.txt";
    file fw : text open read_mode is "wr.txt";
    variable c : character; variable l : line;
    variable n, cyc, want, op, opp : integer := 0;
    variable k : character;
    variable v1, v2, v3, v4, v5, v6, v7, wa, wd : integer;
    variable first : boolean := true;
    variable exp : std_logic_vector(55 downto 0);
    procedure hexrd(v : out integer) is
      variable c : character; variable r : integer := 0; variable any : boolean := false;
    begin
      while l'length > 0 loop
        read(l, c);
        if c = ' ' then exit when any; next; end if;
        any := true;
        if c <= '9' then r := r * 16 + character'pos(c) - 48; else r := r * 16 + character'pos(c) - 87; end if;
      end loop;
      v := r;
    end procedure;
    function b8(i : integer) return std_logic_vector is
    begin return std_logic_vector(to_unsigned(i, 8)); end function;
  begin
    for i in mem_t'range loop read(fb, c); m(i) := character'pos(c); end loop;
    reset <= '1';
    wait until rising_edge(clk); wait until rising_edge(clk);
    reset <= '0';
    loop
      wait for 1 ns;
      if sync = '1' then
        if not first and cyc /= want then
          report "FAIL cycles " & integer'image(cyc) & " want " & integer'image(want) & " op " & to_hstring(b8(op)) & " n " & integer'image(n);
          exit;
        end if;
        opp := op;
        loop
          if endfile(ft) then exit; end if;
          readline(ft, l); read(l, k);
          hexrd(v1); hexrd(v2);
          exit when k = 'I';
          m(v1) := v2;
        end loop;
        exit when endfile(ft);
        hexrd(v3); hexrd(v4); hexrd(v5); hexrd(v6); read(l, v7);
        exp := std_logic_vector(to_unsigned(v1, 16)) & b8(v2) & b8(v3) & b8(v4) & b8(v5) & b8(v6);
        if dbg /= exp then
          report "FAIL state n " & integer'image(n) & " after op " & to_hstring(b8(opp)) & " pc_a_x_y_p_s " & to_hstring(dbg)
            & " want " & to_hstring(exp);
          exit;
        end if;
        want := v7; cyc := 0; first := false; n := n + 1;
        op := m(to_integer(unsigned(addr)));
      end if;
      cyc := cyc + 1;
      din <= b8(m(to_integer(unsigned(addr))));
      wait for 1 ns;
      if we = '1' then
        readline(fw, l); hexrd(wa); hexrd(wd);
        if wa /= to_integer(unsigned(addr)) or wd /= to_integer(unsigned(dout)) or mem = '0' then
          report "FAIL write op " & to_hstring(b8(op)) & " n " & integer'image(n) & " got " & to_hstring(addr) & " " & to_hstring(dout)
             & " want " & to_hstring(to_unsigned(wa, 24)) & " " & to_hstring(b8(wd));
          exit;
        end if;
        m(wa) := wd;
      end if;
      wait until rising_edge(clk);
    end loop;
    report "instructions compared: " & integer'image(n);
    stop <= true; wait;
  end process;
end architecture;
