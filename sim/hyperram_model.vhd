-- Pin-level model of one W955D8MBYA die (2**ABITS words; the address wraps).
-- Latency count 3; variable mode: 1 access of 16 (LFSR) takes 2x. Checks cs
-- high time, tCSM, wrap at 64 words and the CR0 latency.
-- TRT = clock to data plus pads, seen from the FPGA. DROP: lose write number DROP.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity hyperram_model is
  generic (ABITS : integer := 13; TRT : time := 6 ns; DROP : integer := -1;
           INIT : string := "");   -- binary file, even byte = low half of the word
  port (ck, cs_n : in std_logic; rwds : inout std_logic; dq : inout std_logic_vector(7 downto 0));
end entity;
architecture s of hyperram_model is
  signal q : std_logic_vector(7 downto 0) := (others => 'Z');
  signal r : std_logic := 'Z';
begin
  dq   <= transport q after TRT;
  rwds <= transport r after TRT;
  process
    type mem_t is array (0 to 2**ABITS - 1) of std_logic_vector(15 downto 0);
    impure function load return mem_t is
      type cf is file of character;
      file f : cf; variable c : character; variable m : mem_t := (others => x"DEAD"); variable i : integer := 0;
    begin
      if INIT'length > 0 then
        file_open(f, INIT, read_mode);
        while not endfile(f) and i < 2**(ABITS+1) loop
          read(f, c);
          if i mod 2 = 0 then m(i/2)(7 downto 0) := std_logic_vector(to_unsigned(character'pos(c), 8));
          else m(i/2)(15 downto 8) := std_logic_vector(to_unsigned(character'pos(c), 8)); end if;
          i := i + 1;
        end loop;
      end if;
      return m;
    end function;
    variable mem  : mem_t := load;
    variable ca   : std_logic_vector(47 downto 0) := (others => '0');
    variable n    : integer;                 -- ck edges since cs fell
    variable lat, w, w0 : integer;
    variable fix  : boolean := false;
    variable slow : boolean;
    variable lfsr : unsigned(15 downto 0) := x"ACE1";
    variable hi, lo : std_logic_vector(7 downto 0);
    variable mhi : std_logic;
    variable t0, t1 : time := 0 ns;
    variable nw : integer := 0;
    variable wad : std_logic_vector(31 downto 0);
  begin
    wait until falling_edge(cs_n);
    t0 := now;
    assert t1 = 0 ns or t0 - t1 > 10 ns report "cs_n high too short" severity error;
    lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
    slow := fix or lfsr(3 downto 0) = 0;
    if slow then r <= '1'; lat := 6; else r <= '0'; lat := 3; end if;
    n := 0; w := 0; w0 := 0;
    loop
      wait on ck, cs_n;
      exit when cs_n = '1';
      if rising_edge(ck) or falling_edge(ck) then
        if n < 6 then
          ca := ca(39 downto 0) & dq;
          if n = 5 then
            wad := ca(44 downto 16) & ca(2 downto 0);
            w0 := to_integer(unsigned(wad(ABITS - 1 downto 0)));
            w := w0; r <= 'Z';
            if ca(47) = '1' then r <= '0'; end if;
            assert ca(45) = '1' or ca(46) = '1' report "wrapped burst" severity error;
          end if;
        elsif ca(46) = '1' then              -- register write, no latency
          if n = 7 then
            fix := dq(3) = '1';
            assert dq(7 downto 4) = "1110" and dq(2 downto 0) = "100" report "CR0" severity error;
          end if;
        elsif n >= 2 * (2 + lat) then
          if ca(47) = '1' then               -- read
            if n mod 2 = 0 then
              q <= mem(w)(15 downto 8); r <= '1';
            else
              q <= mem(w)(7 downto 0); r <= '0'; w := w / 64 * 64 + (w + 1) mod 64;
            end if;
          else
            if n mod 2 = 0 then
              if n = 2 * (2 + lat) then nw := nw + 1; end if;
              hi := dq; mhi := rwds;
            else
              lo := dq;
              assert rwds /= 'Z' and mhi /= 'Z' report "mask not driven" severity error;
              if nw /= DROP then
                if mhi = '0' then mem(w)(15 downto 8) := hi; end if;
                if rwds = '0' then mem(w)(7 downto 0) := lo; end if;
              end if;
              w := w / 64 * 64 + (w + 1) mod 64;
            end if;
          end if;
        end if;
        n := n + 1;
      end if;
    end loop;
    t1 := now;
    assert t1 - t0 < 4 us report "tCSM" severity error;
    q <= (others => 'Z'); r <= 'Z';
  end process;
end architecture;
