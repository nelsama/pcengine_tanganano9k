--
-- cpu_sys.vhd : HuC6280 + 8 KB work RAM + timer + interrupt controller +
-- joypad port + ROM cache. clk = 21.6 MHz, CPU 7.2 MHz (clk / 3) or 1.8 MHz.
-- The timer counts the 7.2 MHz of the clock, not the CPU cycles: a cache miss
-- does not change the tempo of the music.
-- Peripheral bus (VDC, VCE, PSG): cs, b_addr, b_dout stable for the whole
-- cycle; b_wr / b_rd one clk pulse in its last clk.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cpu_sys is
  port (
    clk, reset : in  std_logic;
    irq1       : in  std_logic;                        -- VDC, level
    pad        : in  std_logic_vector(3 downto 0);     -- port K3-0
    pad_o      : out std_logic_vector(1 downto 0);     -- CLR, SEL
    vdc_cs, vce_cs, psg_cs : out std_logic;
    b_addr     : out std_logic_vector(9 downto 0);
    b_dout     : out std_logic_vector(7 downto 0);
    b_wr, b_rd : out std_logic;
    vdc_din, vce_din : in std_logic_vector(7 downto 0);
    vdc_busy   : in  std_logic;                        -- holds a VDC access
    rom_mask   : in  std_logic_vector(6 downto 0);     -- 8 KB banks - 1 (power of 2)
    rom_mode   : in  std_logic_vector(1 downto 0);     -- 1 384 KB, 2 Street Fighter II, 3 768 KB
    menu       : in  std_logic;                        -- banks 00-01 = menu ROM
    cart_cs    : out std_logic;
    cart_din   : in  std_logic_vector(7 downto 0);
    bram_wr    : out std_logic;                        -- the game wrote the backup RAM
    miss       : out std_logic;
    memclk     : in  std_logic;
    p_read     : out std_logic;
    p_addr     : out std_logic_vector(21 downto 0);
    p_len      : out std_logic_vector(6 downto 0);
    p_dout     : in  std_logic_vector(15 downto 0);
    p_rvalid, p_busy : in std_logic
  );
end entity;

architecture rtl of cpu_sys is
  signal addr : std_logic_vector(20 downto 0);
  signal mem, we, fast, sync, ce : std_logic;
  signal dout, din, q_rom, q_ram, q_io : std_logic_vector(7 downto 0);
  signal dbg  : std_logic_vector(55 downto 0);
  signal cnt  : unsigned(3 downto 0) := (others => '0');
  signal lim  : unsigned(3 downto 0);
  signal extra, init : std_logic := '0';
  signal irq  : std_logic_vector(2 downto 0);
  signal s_rom, s_ram, s_io, rom_rdy, start, rst : std_logic;
  type bram_t is array (0 to 2047) of std_logic_vector(7 downto 0);
  signal bram : bram_t := (others => x"00");
  signal q_bram : std_logic_vector(7 downto 0);
  signal s_bram, bram_we, bram_en : std_logic := '0';
  signal q_menu : std_logic_vector(7 downto 0);
  signal sf2  : std_logic_vector(1 downto 0) := "00";
  component menu_rom is
    port (clk : in std_logic; a : in std_logic_vector(13 downto 0); q : out std_logic_vector(7 downto 0));
  end component;
  signal rst_c : unsigned(8 downto 0) := (others => '0');
  signal rom_a : std_logic_vector(21 downto 0);
  signal bank : std_logic_vector(6 downto 0);
  type ram_t is array (0 to 8191) of std_logic_vector(7 downto 0);
  signal ram  : ram_t;
  signal iobuf : std_logic_vector(7 downto 0) := x"00";
  signal mask : std_logic_vector(2 downto 0) := "000";
  signal tload, tval : unsigned(6 downto 0) := (others => '0');
  signal tpre : unsigned(9 downto 0) := (others => '0');
  signal t3   : unsigned(1 downto 0) := "00";
  signal ten, tirq : std_logic := '0';
  signal wr, rd, pen, ram_we, vdc_sel : std_logic;
begin
  -- the CPU starts when the cache is clear
  rst <= not rst_c(8) or reset;
  process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then rst_c <= (others => '0');
      elsif rst_c(8) = '0' then rst_c <= rst_c + 1; end if;
    end if;
  end process;

  u_huc : entity work.huc6280
    port map (clk => clk, reset => rst, ce => ce, addr => addr, mem => mem, we => we,
      dout => dout, din => din, irq => irq, fast => fast, sync => sync, dbg => dbg);

  s_rom <= mem and not addr(20) and not menu;
  s_ram <= mem when addr(20 downto 15) = "111110" else '0';             -- F8-FB
  s_io  <= mem when addr(20 downto 13) = x"FF" else '0';
  pen   <= s_io when addr(12 downto 11) = "00" else '0';                -- VDC / VCE

  -- one CPU cycle = 3 clk (12 in low speed), twice that on VDC / VCE accesses
  -- (extra cycle); it waits for the ROM
  lim <= "0010" when fast = '1' else "1011";
  ce  <= '1' when cnt = lim and (pen = '0' or extra = '1') and (s_rom = '0' or rom_rdy = '1')
         and not (vdc_sel = '1' and vdc_busy = '1') and rst = '0' else '0';
  start <= s_rom when cnt = 0 and extra = '0' and rst = '0' else '0';
  process(clk)
  begin
    if rising_edge(clk) then
      if ce = '1' then cnt <= "0000"; extra <= '0';
      elsif cnt = lim then
        if pen = '1' and extra = '0' then cnt <= "0000"; extra <= '1'; end if;
      else cnt <= cnt + 1; end if;
      if rst = '1' then cnt <= "0000"; extra <= '0'; end if;
    end if;
  end process;
  wr <= ce and we;
  rd <= ce and mem and not we;

  -- HuCard
  bank <= "00" & addr(17 downto 13) when rom_mode = "01" and addr(19) = '0' else
          "010" & addr(16 downto 13) when rom_mode = "01" else
          "10" & addr(17 downto 13) when rom_mode = "11" and addr(19) = '1' else
          addr(19 downto 13) and rom_mask;
  process(all)
  begin
    rom_a <= "00" & bank & addr(12 downto 0);
    if rom_mode = "10" and addr(19) = '1' then       -- SF2: 512 KB pages after the first 512 KB
      rom_a(21 downto 19) <= std_logic_vector(resize(unsigned(sf2), 3) + 1);
    end if;
  end process;
  process(clk)
  begin
    if rising_edge(clk) then                          -- page: write to $1FF0-$1FF3 of the card
      if wr = '1' and addr(20 downto 4) = "00000000111111111" then sf2 <= addr(1 downto 0); end if;
      if rst = '1' then sf2 <= "00"; end if;
    end if;
  end process;
  u_menu : menu_rom port map (clk => clk, a => addr(13 downto 0), q => q_menu);
  u_rom : entity work.rom_cache
    port map (clk => clk, reset => reset, start => start, addr => rom_a,
      ready => rom_rdy, dout => q_rom, miss => miss, memclk => memclk, p_read => p_read,
      p_addr => p_addr, p_len => p_len, p_dout => p_dout, p_rvalid => p_rvalid, p_busy => p_busy);

  -- work RAM
  ram_we <= wr and s_ram;
  process(clk)
  begin
    if rising_edge(clk) then
      if ram_we = '1' then ram(to_integer(unsigned(addr(12 downto 0)))) <= dout;
      else q_ram <= ram(to_integer(unsigned(addr(12 downto 0)))); end if;
    end if;
  end process;

  -- backup RAM: 2 KB in bank F7; $1807 bit 7 unlocks it, reading $1803 locks it
  s_bram <= mem and (bram_en or menu) when addr(20 downto 11) = "1111011100" else '0';
  bram_we <= wr and s_bram;
  bram_wr <= bram_we and not menu;
  process(clk)
  begin
    if rising_edge(clk) then
      if bram_we = '1' then bram(to_integer(unsigned(addr(10 downto 0)))) <= dout;
      else q_bram <= bram(to_integer(unsigned(addr(10 downto 0)))); end if;
    end if;
  end process;
  process(clk)
  begin
    if rising_edge(clk) then
      if s_io = '1' and addr(12 downto 0) = "1100000000111" and wr = '1' then bram_en <= dout(7); end if;
      if s_io = '1' and addr(12 downto 0) = "1100000000011" and rd = '1' then bram_en <= '0'; end if;
      if rst = '1' then bram_en <= '0'; end if;
    end if;
  end process;

  -- peripheral bus
  vdc_sel <= s_io when addr(12 downto 10) = "000" else '0';
  vdc_cs <= vdc_sel;
  vce_cs <= s_io when addr(12 downto 10) = "001" else '0';
  psg_cs <= s_io when addr(12 downto 10) = "010" else '0';
  cart_cs <= s_io when addr(12 downto 10) = "110" else '0';
  b_addr <= addr(9 downto 0);
  b_dout <= dout;
  b_wr <= wr and s_io;
  b_rd <= rd and s_io;

  -- timer, interrupts, joypad port
  process(clk)
  begin
    if rising_edge(clk) then
      if t3 = 2 then
        t3 <= "00";
        tpre <= tpre - 1;
        if ten = '1' and tpre = 0 then
          tval <= tval - 1;
          if tval = 0 then tval <= tload; tirq <= '1'; end if;
        end if;
      else t3 <= t3 + 1; end if;
      if wr = '1' and s_io = '1' and addr(12 downto 11) /= "00" then
        if addr(12 downto 10) /= "110" and addr(12 downto 10) /= "111" then iobuf <= dout; end if;
        case addr(12 downto 10) is
          when "011" =>
            if addr(0) = '0' then tload <= unsigned(dout(6 downto 0));
            else
              ten <= dout(0);
              if dout(0) = '1' and ten = '0' then tval <= tload; tpre <= (others => '1'); end if;
            end if;
          when "100" => pad_o <= dout(1 downto 0);
          when "101" =>
            if addr(1 downto 0) = "10" then mask <= dout(2 downto 0); end if;
            if addr(1 downto 0) = "11" then tirq <= '0'; end if;
          when others => null;
        end case;
      end if;
      if rst = '1' then
        ten <= '0'; tirq <= '0'; mask <= "000"; pad_o <= "00"; iobuf <= x"00";
      end if;
    end if;
  end process;
  irq <= (tirq and not mask(2)) & (irq1 and not mask(1)) & '0';

  process(all)
  begin
    case addr(12 downto 10) is
      when "000" => q_io <= vdc_din;
      when "001" => q_io <= vce_din;
      when "011" => q_io <= iobuf(7) & std_logic_vector(tval);
      when "100" => q_io <= "1011" & pad;               -- bit 6 = 0: PC Engine; bit 7 = 1: no CD
      when "101" =>
        q_io <= iobuf;
        if addr(1 downto 0) = "10" then q_io(2 downto 0) <= mask; end if;
        if addr(1 downto 0) = "11" then q_io(2 downto 0) <= tirq & irq1 & '0'; end if;
      when "110" => q_io <= cart_din;
      when "111" => q_io <= x"FF";
      when others => q_io <= iobuf;
    end case;
    din <= x"FF";
    if addr(20) = '0' and menu = '1' then din <= q_menu;
    elsif addr(20) = '0' then din <= q_rom;
    elsif s_bram = '1' then din <= q_bram;
    elsif addr(15) = '0' then din <= q_ram;
    elsif addr(20 downto 13) = x"FF" then din <= q_io; end if;
    if addr(20) = '1' and addr(20 downto 15) /= "111110" and addr(20 downto 13) /= x"FF" and s_bram = '0' then din <= x"FF"; end if;
  end process;
end architecture;
