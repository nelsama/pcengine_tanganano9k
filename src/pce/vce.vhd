--
-- vce.vhd : HuC6260. Line / frame timing, dot clock and the 512 x 9 palette.
-- clk = 21.6 MHz: 1368 clk per line, 262 lines. Dot = clk / 4, / 3, / 2.
-- The HDMI raster is the master (59.94 Hz): the last clk of a line waits for a
-- change of line_t (every 1372.8 clk); line 18 waits for the one with line_f = 1.
-- Only the dots stop, the CPU and the PSG go on.
-- Output: 9-bit colour (GRB) of every dot into a two-line buffer, from clk 128
-- of the line on (288 / 384 / 576 dots are used), see pce2hdmi.v.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vce is
  port (
    clk, reset : in  std_logic;
    cs, wr, rd : in  std_logic;
    a          : in  std_logic_vector(2 downto 0);
    din        : in  std_logic_vector(7 downto 0);
    dout       : out std_logic_vector(7 downto 0);
    line_t, line_f : in std_logic;                    -- from pce2hdmi (pixel clock)
    locked     : out std_logic;
    -- timing
    sol        : out std_logic;                       -- first clk of a line
    eol        : out std_logic;                       -- last clk of a line
    dot        : out std_logic;                       -- last clk of a dot
    line       : out unsigned(8 downto 0);            -- 0 = vertical sync
    dotclk     : out std_logic_vector(1 downto 0);    -- 00 /4, 01 /3, 1x /2
    -- pixels
    pa         : in  std_logic_vector(8 downto 0);    -- palette index, changes after dot
    pix_we     : out std_logic;
    pix_addr   : out std_logic_vector(10 downto 0);   -- line(0), dot
    pix_color  : out std_logic_vector(8 downto 0);
    pix_div    : out std_logic_vector(1 downto 0);    -- dotclk of the line being written
    frame_t    : out std_logic                        -- toggles at the start of line 19
  );
end entity;

architecture rtl of vce is
  signal hc  : unsigned(10 downto 0) := (others => '0');
  signal ln  : unsigned(8 downto 0) := (others => '0');
  signal ph  : unsigned(1 downto 0) := "00";
  signal dc, dcl : std_logic_vector(1 downto 0) := "00";
  signal dot_i, eol_i, ft : std_logic := '0';
  signal ca  : unsigned(8 downto 0) := (others => '0');
  signal lo  : std_logic_vector(7 downto 0) := (others => '0');
  signal pra, q, rbuf : std_logic_vector(8 downto 0);
  signal pwe, crd, crd1, cdir : std_logic := '0';
  signal px  : unsigned(9 downto 0) := (others => '0');
  signal col : std_logic_vector(8 downto 0);
  signal act, fresh : std_logic := '0';
  signal lt  : std_logic_vector(2 downto 0) := "000";
  signal go, pulse, lck : std_logic := '0';
  signal last, ph_end : std_logic;
begin
  last  <= '1' when hc = 1367 else '0';
  eol_i <= last and go;
  ph_end <= '1' when (dcl = "00" and ph = 3) or (dcl = "01" and ph = 2) or (dcl(1) = '1' and ph = 1) else '0';
  dot_i <= ph_end and (go or not last);
  pulse <= lt(2) xor lt(1);
  sol  <= '1' when hc = 0 else '0';
  eol  <= eol_i;
  dot  <= dot_i;
  line <= ln;
  dotclk <= dcl;
  process(clk)
  begin
    if rising_edge(clk) then
      lt <= lt(1 downto 0) & line_t;
      if last = '0' then hc <= hc + 1; ph <= ph + 1; end if;
      if dot_i = '1' then ph <= "00"; end if;
      if eol_i = '1' then go <= '0'; end if;
      if pulse = '1' and (ln /= 18 or line_f = '1') then go <= '1'; end if;
      if pulse = '1' and line_f = '1' then
        lck <= '0';
        if ln = 18 and last = '1' then lck <= '1'; end if;
      end if;
      if eol_i = '1' then
        hc <= (others => '0'); ph <= "00";
        dcl <= dc;                                    -- the dot clock changes between lines
        if ln = 261 then ln <= (others => '0'); else ln <= ln + 1; end if;
        if ln = 18 then ft <= not ft; end if;
      end if;
    end if;
  end process;
  frame_t <= ft;
  locked <= lck;

  -- palette; the CPU reads in the clk after the display read (a dot has 2 clk or more)
  pwe <= wr and cs when a = "101" else '0';
  u_pal : entity work.sdp_ram generic map (9, 9)
    port map (clk, pwe, std_logic_vector(ca), din(0) & lo, clk, pra, q);
  pra <= pa when fresh = '1' else std_logic_vector(ca);
  process(clk)
  begin
    if rising_edge(clk) then
      fresh <= dot_i;                                 -- pa is new in this clk
      crd <= fresh;
      if crd = '1' then col <= q; else rbuf <= q; end if;
      if cs = '1' and wr = '1' then
        case a is
          when "000" => dc <= din(1 downto 0);
          when "010" => ca(7 downto 0) <= unsigned(din);
          when "011" => ca(8) <= din(0);
          when "100" => lo <= din;
          when "101" => ca <= ca + 1;
          when others => null;
        end case;
      end if;
      if cs = '1' and rd = '1' and a = "101" then ca <= ca + 1; end if;
      if reset = '1' then dc <= "00"; end if;
    end if;
  end process;
  dout <= rbuf(7 downto 0) when a = "100" else "1111111" & rbuf(8) when a = "101" else x"FF";

  -- line buffer: written at the dot tick with the colour of the previous index
  process(clk)
  begin
    if rising_edge(clk) then
      pix_we <= '0';
      if dot_i = '1' then
        if act = '1' then
          pix_we <= not (px(9) and px(8));
          px <= px + 1;
        end if;
        pix_addr <= ln(0) & std_logic_vector(px);
        pix_color <= q when crd = '1' else col;
      end if;
      if hc = 131 then act <= '1'; px <= (others => '0'); pix_div <= dcl; end if;
      if eol_i = '1' then act <= '0'; end if;
      if px(9 downto 8) = "11" then act <= '0'; end if;
    end if;
  end process;
end architecture;
