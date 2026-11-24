--
-- rom_cache.vhd : HuCard ROM in PSRAM with a 4 KB direct-mapped read cache
-- (16-byte lines, 3 BSRAM).
--   clk    21.6 MHz        memclk  86.4 MHz, same PLL, edges aligned
--   start  pulse in the first clk of the access, addr already valid and then
--          stable; ready = 1 and dout valid in the third clk on a hit, later
--          on a miss, until the next start
-- The memclk side drives one psram_burst (read only here).
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rom_cache is
  port (
    clk, reset : in  std_logic;          -- reset also empties the cache (256 clk)
    start      : in  std_logic;
    addr       : in  std_logic_vector(21 downto 0);
    ready      : out std_logic;
    dout       : out std_logic_vector(7 downto 0);
    miss       : out std_logic;          -- pulse, statistics
    memclk     : in  std_logic;
    p_read     : out std_logic;
    p_addr     : out std_logic_vector(21 downto 0);
    p_len      : out std_logic_vector(6 downto 0);
    p_dout     : in  std_logic_vector(15 downto 0);
    p_rvalid, p_busy : in std_logic
  );
end entity;

architecture rtl of rom_cache is
  type ram8 is array (0 to 2047) of std_logic_vector(7 downto 0);
  signal d0, d1 : ram8;
  type tag_t is array (0 to 255) of std_logic_vector(10 downto 0);
  signal tags : tag_t;
  signal q0, q1 : std_logic_vector(7 downto 0);
  signal qt     : std_logic_vector(10 downto 0);
  type st_t is (CLEAR, IDLE, CHECK, FILL, RELOAD, DONE);
  signal st   : st_t := CLEAR;
  signal cnt  : unsigned(7 downto 0) := (others => '0');
  signal tw   : std_logic;
  signal ta   : std_logic_vector(7 downto 0);
  signal td   : std_logic_vector(10 downto 0);
  signal pend : std_logic := '0';        -- start during CLEAR
  signal req  : std_logic := '0';
  signal ra   : std_logic_vector(21 downto 4) := (others => '0');
  -- memclk
  signal req1, req2, rd, fin, fin1 : std_logic := '0';
  signal wn   : unsigned(2 downto 0) := "000";
begin
  tw <= '1' when st = CLEAR or st = RELOAD else '0';
  ta <= std_logic_vector(cnt) when st = CLEAR else addr(11 downto 4);
  td <= (others => '0') when st = CLEAR else '1' & addr(21 downto 12);
  process(clk)
  begin
    if rising_edge(clk) then
      if tw = '1' then tags(to_integer(unsigned(ta))) <= td; end if;
    end if;
  end process;
  process(clk)
  begin
    if rising_edge(clk) then
      qt <= tags(to_integer(unsigned(addr(11 downto 4))));
      q0 <= d0(to_integer(unsigned(addr(11 downto 1))));
      q1 <= d1(to_integer(unsigned(addr(11 downto 1))));
    end if;
  end process;
  dout <= q1 when addr(0) = '1' else q0;

  process(clk)
  begin
    if rising_edge(clk) then
      miss <= '0';
      fin1 <= fin;
      case st is
        when CLEAR =>
          cnt <= cnt + 1;
          if start = '1' then pend <= '1'; end if;
          if cnt = 255 then
            st <= IDLE;
          end if;
        when IDLE => if pend = '1' then pend <= '0'; st <= CHECK; end if;
        when CHECK =>                      -- qt, q0, q1 belong to addr
          if qt = '1' & addr(21 downto 12) then st <= DONE;
          else
            ra   <= addr(21 downto 4);
            req  <= not req;
            miss <= '1';
            st   <= FILL;
          end if;
        when FILL   => if fin1 = req then st <= RELOAD; end if;
        when RELOAD => st <= DONE;         -- the line is in q0, q1 after this clk
        when DONE   => null;
      end case;
      if start = '1' and st /= CLEAR then st <= CHECK; end if;
      if reset = '1' then st <= CLEAR; cnt <= (others => '0'); pend <= '0'; end if;
    end if;
  end process;
  ready <= '1' when st = DONE else '0';

  p_read <= rd;
  p_addr <= ra & "0000";
  p_len  <= "0001000";
  process(memclk)
  begin
    if rising_edge(memclk) then
      req1 <= req;
      req2 <= req1;
      if req1 /= req2 then rd <= '1'; wn <= "000";
      elsif p_busy = '0' then rd <= '0'; end if;
      if p_rvalid = '1' then
        wn <= wn + 1;
        if wn = 7 then fin <= req1; end if;
      end if;
    end if;
  end process;
  process(memclk)
  begin
    if rising_edge(memclk) then
      if p_rvalid = '1' then
        d0(to_integer(unsigned(ra(11 downto 4)) & wn)) <= p_dout(7 downto 0);
        d1(to_integer(unsigned(ra(11 downto 4)) & wn)) <= p_dout(15 downto 8);
      end if;
    end if;
  end process;
end architecture;
