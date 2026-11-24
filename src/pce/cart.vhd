--
-- cart.vhd : flash cart registers and SD card SPI. Menu mode (power-on, S2): banks
-- 00-01 are the menu ROM, the HuCard is not visible. Ports at $1800 (only in the menu):
--   0 W send SPI byte           R last byte received
--   1 W bit 0 CS (1 = high), bit 1 fast clock      R bit 7 SPI / DMA busy, bit 0
--     the game wrote the backup RAM
--   2/3/4 W PSRAM byte address (even), low / mid / high
--   5 W copy 512 SPI bytes to PSRAM die 0; bit 0: reverse the bits of every
--     byte; the address increments
--   6 W ROM layout: 0 power of 2, 1 384 KB, 2 Street Fighter II, 3 768 KB
--   7 W bank mask (8 KB banks - 1)
--   8 W leave the menu: reset and run the game
--   9 W clear the "backup RAM written" flag (bit 0 of port 1)
--   A R last byte, and sends FF
--   10-1F R/W 16 bytes that survive the games (what the backup RAM belongs to)
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cart is
  port (
    clk, hard  : in  std_logic;                        -- hard: power-on / S1
    to_menu    : in  std_logic;
    mem_rdy    : in  std_logic;                        -- PSRAM ready in the right mode
    menu       : out std_logic;
    reset      : out std_logic;                        -- of the whole console
    cs, wr, rd : in  std_logic;
    bram_wr    : in  std_logic;
    a          : in  std_logic_vector(4 downto 0);
    din        : in  std_logic_vector(7 downto 0);
    dout       : out std_logic_vector(7 downto 0);
    rom_mode   : out std_logic_vector(1 downto 0);
    rom_mask   : out std_logic_vector(6 downto 0);
    -- word write to die 0: a change of pw_t
    pw_t       : out std_logic;
    pw_a       : out std_logic_vector(21 downto 0);
    pw_d       : out std_logic_vector(15 downto 0);
    loading    : out std_logic;
    sd_sck, sd_cmd, sd_cs : out std_logic;
    sd_dat0    : in  std_logic
  );
end entity;

architecture rtl of cart is
  signal m    : std_logic := '1';
  signal rcnt : unsigned(9 downto 0) := (others => '0');
  signal rst, launch, sel, dirty : std_logic := '0';
  type note_t is array (0 to 15) of std_logic_vector(7 downto 0);
  signal note : note_t := (others => x"00");
  signal nq   : std_logic_vector(7 downto 0);
  signal csn  : std_logic := '1';
  signal fast, go, dma, flip, t : std_logic := '0';
  signal tx, b, lo : std_logic_vector(7 downto 0) := x"FF";
  signal da   : unsigned(21 downto 0) := (others => '0');
  signal dcnt : unsigned(8 downto 0) := (others => '0');
  -- SPI mode 0: slow = clk / 64 (337 kHz), fast = clk / 4 (5.4 MHz)
  signal sr   : std_logic_vector(7 downto 0) := x"FF";
  signal div  : unsigned(4 downto 0) := (others => '0');
  signal n    : unsigned(2 downto 0) := "000";
  signal busy, done, sck, bitin, tick : std_logic := '0';
begin
  menu <= m;
  rst  <= '1' when rcnt(9) = '0' else '0';
  reset <= rst;
  process(clk)
  begin
    if rising_edge(clk) then
      if to_menu = '1' or hard = '1' then m <= '1';
      elsif launch = '1' then m <= '0'; end if;
      if hard = '1' or to_menu = '1' or launch = '1' then rcnt <= (others => '0');
      elsif rst = '1' and (rcnt /= 511 or mem_rdy = '1') then rcnt <= rcnt + 1; end if;
    end if;
  end process;

  sel <= cs and m;
  process(all)
  begin
    b <= sr;
    if flip = '1' then
      for i in 0 to 7 loop b(i) <= sr(7 - i); end loop;
    end if;
  end process;
  process(clk)
  begin
    if rising_edge(clk) then
      go <= '0'; launch <= '0';
      if bram_wr = '1' then dirty <= '1'; end if;
      if sel = '1' and wr = '1' and a(4) = '0' then
        case a(3 downto 0) is
          when x"0" => tx <= din; go <= '1';
          when x"1" => csn <= din(0); fast <= din(1);
          when x"2" => da(7 downto 0) <= unsigned(din);
          when x"3" => da(15 downto 8) <= unsigned(din);
          when x"4" => da(21 downto 16) <= unsigned(din(5 downto 0));
          when x"5" => dma <= '1'; flip <= din(0); dcnt <= (others => '0'); tx <= x"FF"; go <= '1';
          when x"6" => rom_mode <= din(1 downto 0);
          when x"7" => rom_mask <= din(6 downto 0);
          when x"8" => launch <= '1';
          when x"9" => dirty <= '0';
          when others => null;
        end case;
      end if;
      if sel = '1' and rd = '1' and a = "01010" then tx <= x"FF"; go <= '1'; end if;
      if dma = '1' and done = '1' then
        dcnt <= dcnt + 1;
        if dcnt(0) = '0' then lo <= b;
        else
          pw_a <= std_logic_vector(da); pw_d <= b & lo; t <= not t;
          da <= da + 2;
        end if;
        if dcnt = 511 then dma <= '0'; else go <= '1'; end if;
      end if;
      if rst = '1' then csn <= '1'; fast <= '0'; dma <= '0'; end if;
    end if;
  end process;
  pw_t <= t;
  loading <= dma;
  process(clk)
  begin
    if rising_edge(clk) then
      if sel = '1' and wr = '1' and a(4) = '1' then note(to_integer(unsigned(a(3 downto 0)))) <= din; end if;
    end if;
  end process;
  nq <= note(to_integer(unsigned(a(3 downto 0))));
  dout <= x"FF" when m = '0' else nq when a(4) = '1' else
          (busy or go or dma) & "000000" & dirty when a(3 downto 0) = x"1" else sr;

  sd_cs  <= csn;
  sd_sck <= sck;
  sd_cmd <= sr(7) when busy = '1' else '1';
  tick <= div(0) when fast = '1' else '1' when div = 31 else '0';
  process(clk)
  begin
    if rising_edge(clk) then
      done <= '0';
      if busy = '0' then
        sck <= '0'; div <= (others => '0'); n <= "000";
        if go = '1' then busy <= '1'; sr <= tx; end if;
      elsif tick = '1' then
        div <= (others => '0');
        sck <= not sck;
        if sck = '0' then bitin <= sd_dat0;             -- rising edge
        else
          sr <= sr(6 downto 0) & bitin;
          n <= n + 1;
          if n = 7 then busy <= '0'; done <= '1'; end if;
        end if;
      else
        div <= div + 1;
      end if;
    end if;
  end process;
end architecture;
