--
-- vdc.vhd : HuC6270 with its 64 KB VRAM in PSRAM (psram_burst, fixed latency).
-- clk 21.6 MHz, memclk 86.4 MHz (same PLL, edges aligned).
--
-- All the VRAM accesses go through one sequencer, one request at a time:
--   CPU (1 word) > background > sprites > SATB transfer > VRAM DMA
-- Background: the BAT row of the line is read (bursts of 32 / 64 words) just
--   before the display, then 9-word bursts for the patterns, into a FIFO of 8 tiles.
-- Sprites: found and drawn while the previous line is shown, 49-word burst
--   per 16 x 16 cell (the 4 planes of one row), into one of two line buffers.
-- Not implemented: the access-width modes of MWR and the 2-colour CG modes.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vdc is
  port (
    clk, reset : in  std_logic;
    cs, wr, rd : in  std_logic;
    a          : in  std_logic_vector(1 downto 0);
    din        : in  std_logic_vector(7 downto 0);
    dout       : out std_logic_vector(7 downto 0);
    busy       : out std_logic;                      -- the CPU must wait (data port)
    irq        : out std_logic;
    sol, eol, dot : in std_logic;                    -- from the VCE
    line       : in  unsigned(8 downto 0);
    dotclk     : in  std_logic_vector(1 downto 0);
    pa         : out std_logic_vector(8 downto 0);   -- palette index
    memclk     : in  std_logic;
    p_read, p_write : out std_logic;
    p_addr     : out std_logic_vector(21 downto 0);
    p_len      : out std_logic_vector(6 downto 0);
    p_din      : out std_logic_vector(15 downto 0);
    p_dout     : in  std_logic_vector(15 downto 0);
    p_rvalid, p_busy : in std_logic;
    dbg : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of vdc is
  subtype w16 is std_logic_vector(15 downto 0);
  -- registers
  signal sel  : std_logic_vector(4 downto 0) := (others => '0');
  signal mawr, marr : unsigned(15 downto 0) := (others => '0');
  signal vwl  : std_logic_vector(7 downto 0) := (others => '0');
  signal cr   : std_logic_vector(12 downto 0) := (others => '0');
  signal rcr, bxr : unsigned(9 downto 0) := (others => '0');
  signal byr  : unsigned(8 downto 0) := (others => '0');
  signal msz  : std_logic_vector(2 downto 0) := "000";
  signal hsw  : unsigned(4 downto 0) := "00010";
  signal hds  : unsigned(6 downto 0) := "0000010";
  signal hdw  : unsigned(6 downto 0) := "0011111";
  signal vsw  : unsigned(4 downto 0) := "00010";
  signal vds  : unsigned(7 downto 0) := x"0F";
  signal vdw  : unsigned(8 downto 0) := "011101111";
  signal dcr  : std_logic_vector(4 downto 0) := "00000";
  signal sour, desr, lenr, dvssr : unsigned(15 downto 0) := (others => '0');
  signal f_cr, f_or, f_rr, f_ds, f_dv, f_vd : std_logic := '0';
  signal inc  : unsigned(7 downto 0);
  -- CPU port
  signal wpend, rpend : std_logic := '0';
  signal wa, rd_a : unsigned(15 downto 0) := (others => '0');
  signal wdat : w16 := (others => '0');
  signal rbuf : w16;
  -- timing
  signal dcnt : unsigned(2 downto 0) := "000";
  signal chr  : unsigned(7 downto 0) := (others => '0');
  signal c_start, c_end : unsigned(7 downto 0);
  signal c_bg : unsigned(7 downto 0);
  signal k_bg : unsigned(7 downto 0);
  signal vstart, vend : unsigned(9 downto 0);
  signal rc   : unsigned(9 downto 0) := (others => '0');
  signal yoff : unsigned(8 downto 0) := (others => '0');
  signal ended, disp, lact, nact, bgon, spon, first_l : std_logic := '0';
  signal ev_end : std_logic;
  signal newchr : std_logic := '0';
  signal vbl  : std_logic := '1';
  signal dx   : unsigned(9 downto 0) := (others => '0');
  -- sequencer
  type kind_t is (K_CR, K_CW, K_BAT, K_CG, K_SPR, K_SATB, K_DR, K_DW);
  signal kind : kind_t := K_CR;
  signal act  : std_logic := '0';
  signal tog  : std_logic := '0';
  signal q_we : std_logic := '0';
  signal q_a  : unsigned(15 downto 0) := (others => '0');
  signal q_len : unsigned(6 downto 0) := "0000001";
  signal q_d  : w16 := (others => '0');
  signal q_dst : std_logic_vector(2 downto 0) := "000";
  signal done : std_logic;
  -- background
  type bg_t is (B_OFF, B_BAT, B_BAT2, B_WBAT, B_COL, B_RD, B_CG, B_WCG);
  signal bg   : bg_t := B_OFF;
  signal bgy  : unsigned(8 downto 0) := (others => '0');
  signal bgcol, bgleft : unsigned(6 downto 0) := (others => '0');
  signal fine : unsigned(2 downto 0) := "000";
  signal bat_q : w16;
  signal bat_row : unsigned(5 downto 0);
  signal bat_ra : std_logic_vector(6 downto 0);
  signal bat_a : unsigned(15 downto 0);
  signal bpage : std_logic := '0';
  type fifo_t is array (0 to 7) of std_logic_vector(35 downto 0);
  signal fifo : fifo_t;
  signal fw, fr, fcnt : unsigned(3 downto 0) := "0000";
  signal fq   : std_logic_vector(35 downto 0);
  signal bgp  : std_logic_vector(3 downto 0);
  -- sprites
  type sp_t is (S_OFF, S_Y, S_YW, S_AT, S_ATW, S_CHK, S_X, S_PT, S_GO, S_NEXT);
  signal sp   : sp_t := S_OFF;
  signal si   : unsigned(6 downto 0) := (others => '0');
  signal satb_ra : std_logic_vector(7 downto 0);
  signal satb_q : w16;
  signal sy   : unsigned(9 downto 0) := (others => '0');
  signal sdy  : unsigned(9 downto 0) := (others => '0');
  signal sx   : unsigned(9 downto 0) := (others => '0');
  signal sat  : w16 := (others => '0');
  signal spt  : unsigned(9 downto 0) := (others => '0');
  signal sline : unsigned(9 downto 0) := (others => '0');
  signal scell : std_logic := '0';
  signal ncell : unsigned(4 downto 0) := (others => '0');
  signal sreq, sbusy : std_logic := '0';
  signal sreq_a : unsigned(15 downto 0) := (others => '0');
  signal f_x  : unsigned(10 downto 0) := (others => '0');
  signal f_pal : std_logic_vector(3 downto 0) := "0000";
  signal f_pri, f_flip, f_s0 : std_logic := '0';
  -- drawing
  signal dr_n : unsigned(4 downto 0) := "10000";     -- 16 = idle
  signal dr_x : unsigned(10 downto 0) := (others => '0');
  signal dr0, dr1, dr2, dr3 : w16 := (others => '0');
  signal dr_pal : std_logic_vector(3 downto 0) := "0000";
  signal dr_pri, dr_flip, dr_s0 : std_logic := '0';
  signal dp   : std_logic_vector(3 downto 0);
  signal d1_v, d1_ok : std_logic := '0';
  signal d1_x : std_logic_vector(9 downto 0) := (others => '0');
  signal d1_d : std_logic_vector(9 downto 0) := (others => '0');
  signal sb   : std_logic := '0';                    -- bank being shown
  signal b0_we, b1_we, dw, clr : std_logic;
  signal b0_wa, b1_wa, b0_ra, b1_ra, b0_wd, b1_wd, b0_q, b1_q, sq, dq : std_logic_vector(9 downto 0);
  signal rdx : std_logic_vector(9 downto 0);
  -- DMA
  signal satb_req, satb_run, dma_run, dma_w : std_logic := '0';
  signal satb_n : unsigned(8 downto 0) := (others => '0');
  signal satb_a : unsigned(15 downto 0) := (others => '0');
  signal satb_len : unsigned(6 downto 0);
  signal dma_d : w16 := (others => '0');
  -- memclk side
  signal m_req, m_run, m_rd, m_wr, m_ack, ack1 : std_logic := '0';
  signal m_t   : std_logic := '0';
  signal m_cnt : unsigned(6 downto 0) := (others => '0');
  signal m_d0, m_d1, m_d2, m_d3 : w16 := (others => '0');
  signal bat_we, satb_we : std_logic;
  signal bat_wa : std_logic_vector(6 downto 0);
  signal satb_wa : std_logic_vector(7 downto 0);
  signal satb_base : unsigned(7 downto 0) := (others => '0');

  function rev(w : w16) return w16 is
    variable r : w16;
  begin
    for i in 0 to 15 loop r(i) := w(15 - i); end loop;
    return r;
  end function;
begin
  with cr(12 downto 11) select inc <=
    x"01" when "00", x"20" when "01", x"40" when "10", x"80" when others;

  dbg <= "000" & std_logic_vector(hsw) & '0' & std_logic_vector(hds) & '0' & std_logic_vector(hdw) & std_logic_vector(vds);
  irq <= f_cr or f_or or f_rr or f_ds or f_dv or f_vd;
  busy <= a(1) and (wpend or rpend);
  process(all)
  begin
    case a is
      when "00"   => dout <= '0' & (wpend or rpend) & f_vd & f_dv & f_ds & f_rr & f_or & f_cr;
      when "10"   => dout <= rbuf(7 downto 0);
      when "11"   => dout <= rbuf(15 downto 8);
      when others => dout <= x"00";
    end case;
  end process;

  -- timing of the line ---------------------------------------------------------
  c_start <= resize(hsw, 8) + resize(hds, 8) + 2;
  c_end   <= c_start + resize(hdw, 8) + 1;
  -- BG fetch 3 characters before the display (5 at 10 MHz)
  k_bg <= x"05" when dotclk(1) = '1' else x"03";
  c_bg <= c_start - k_bg when c_start > k_bg else x"00";
  vstart <= resize(vsw, 10) + resize(vds, 10) + 3;
  vend   <= vstart + resize(vdw, 10);                 -- last line shown
  -- end of the display part of the line: raster interrupt, next line
  ev_end <= '1' when ended = '0' and ((newchr = '1' and chr = c_end) or eol = '1') else '0';

  process(clk)
    variable nrc : unsigned(9 downto 0);
    variable nl  : unsigned(9 downto 0);
    variable room : unsigned(6 downto 0);
    variable rows : unsigned(9 downto 0);
    variable h, ok : boolean;
    variable cell : unsigned(9 downto 0);
    variable yy   : unsigned(5 downto 0);
    variable stb  : std_logic;
  begin
    if rising_edge(clk) then
      ack1 <= m_ack;
      ------------------------------------------------------------------ CPU
      stb := '0';
      if cs = '1' and rd = '1' then
        if a = "00" then
          f_cr <= '0'; f_or <= '0'; f_rr <= '0'; f_ds <= '0'; f_dv <= '0'; f_vd <= '0';
        end if;
        if a = "11" and sel = "00010" then
          rpend <= '1'; rd_a <= marr + inc; marr <= marr + inc;
        end if;
      end if;
      if cs = '1' and wr = '1' then
        if a = "00" then sel <= din(4 downto 0); end if;
        if a = "10" then
          case sel is
            when "00000" => mawr(7 downto 0) <= unsigned(din);
            when "00001" => marr(7 downto 0) <= unsigned(din);
            when "00010" => vwl <= din;
            when "00101" => cr(7 downto 0) <= din;
            when "00110" => rcr(7 downto 0) <= unsigned(din);
            when "00111" => bxr(7 downto 0) <= unsigned(din);
            when "01000" => byr(7 downto 0) <= unsigned(din); yoff <= byr(8) & unsigned(din);
            when "01001" => msz <= din(6 downto 4);
            when "01010" => hsw <= unsigned(din(4 downto 0));
            when "01011" => hdw <= unsigned(din(6 downto 0));
            when "01100" => vsw <= unsigned(din(4 downto 0));
            when "01101" => vdw(7 downto 0) <= unsigned(din);
            when "01111" => dcr <= din(4 downto 0);
            when "10000" => sour(7 downto 0) <= unsigned(din);
            when "10001" => desr(7 downto 0) <= unsigned(din);
            when "10010" => lenr(7 downto 0) <= unsigned(din);
            when "10011" => dvssr(7 downto 0) <= unsigned(din); satb_req <= '1';
            when others => null;
          end case;
        end if;
        if a = "11" then
          case sel is
            when "00000" => mawr(15 downto 8) <= unsigned(din);
            when "00001" => marr(15 downto 8) <= unsigned(din);
                            rpend <= '1'; rd_a <= unsigned(din) & marr(7 downto 0);
            when "00010" => wpend <= '1'; wa <= mawr; wdat <= din & vwl; mawr <= mawr + inc;
            when "00101" => cr(12 downto 8) <= din(4 downto 0);
            when "00110" => rcr(9 downto 8) <= unsigned(din(1 downto 0));
            when "00111" => bxr(9 downto 8) <= unsigned(din(1 downto 0));
            when "01000" => byr(8) <= din(0); yoff <= din(0) & byr(7 downto 0);
            when "01010" => hds <= unsigned(din(6 downto 0));
            when "01100" => vds <= unsigned(din);
            when "01101" => vdw(8) <= din(0);
            when "10000" => sour(15 downto 8) <= unsigned(din);
            when "10001" => desr(15 downto 8) <= unsigned(din);
            when "10010" => lenr(15 downto 8) <= unsigned(din); dma_run <= '1'; dma_w <= '0';
            when "10011" => dvssr(15 downto 8) <= unsigned(din); satb_req <= '1';
            when others => null;
          end case;
        end if;
      end if;

      ------------------------------------------------------------------ line timing
      newchr <= '0';
      if dot = '1' then
        dcnt <= dcnt + 1;
        if dcnt = 7 then chr <= chr + 1; newchr <= '1'; end if;
      end if;
      if eol = '1' then
        dcnt <= "000"; chr <= (others => '0'); newchr <= '1'; ended <= '0'; disp <= '0';
        -- this line is shown if the previous ev_end said so
        lact <= nact;
      end if;
      nl  := resize(line, 10) + 1;
      nrc := rc + 1;
      if nl = vstart then nrc := to_unsigned(64, 10); end if;
      if ev_end = '1' then
        ended <= not eol; disp <= '0';                  -- eol: window longer than the line
        rc <= nrc;
        if nrc = rcr and cr(2) = '1' then f_rr <= '1'; end if;
        if nl = vstart then nact <= '1'; first_l <= '1'; vbl <= '0'; end if;
        if nact = '1' and (line = vend(8 downto 0) or line = 261) then
          nact <= '0';
          vbl <= '1';
          if cr(3) = '1' then f_vd <= '1'; end if;
          if satb_req = '1' or dcr(4) = '1' then
            satb_run <= '1'; satb_req <= '0'; satb_n <= (others => '0'); satb_a <= dvssr;
          end if;
        end if;
      end if;

      -- background start / display start of a shown line
      if newchr = '1' and lact = '1' and ended = '0' then
        if chr = c_bg then
          bgy <= yoff + 1;
          yoff <= yoff + 1;
          if first_l = '1' then bgy <= byr; yoff <= byr; end if;
          first_l <= '0';
          fine <= bxr(2 downto 0);
          bgcol <= bxr(9 downto 3);
          bgleft <= hdw + 2;
          fw <= "0000"; fr <= "0000";
          bgon <= cr(7); spon <= cr(6);
          if cr(7) = '1' then bg <= B_BAT; bpage <= '0'; end if;
        end if;
        if chr = c_start then
          disp <= '1';
        end if;
        if chr = c_start - 1 then                       -- sprites of the next line
          sb <= not sb;
          si <= (others => '0'); ncell <= (others => '0'); sline <= rc + 1;
          sp <= S_OFF;
          if cr(6) = '1' and line /= vend(8 downto 0) then sp <= S_Y; end if;
        end if;
      end if;
      -- the line before the first one prepares its sprites too
      if newchr = '1' and lact = '0' and ended = '0' and chr = c_start - 1 then
        if nl = vstart then
          sb <= not sb;
          si <= (others => '0'); ncell <= (others => '0'); sline <= to_unsigned(64, 10);
          if cr(6) = '1' then sp <= S_Y; end if;
        end if;
      end if;

      if disp = '0' then dx <= (others => '0'); end if;
      if disp = '1' and dot = '1' then
        dx <= dx + 1;
        fine <= fine + 1;
        if fine = 7 then fr <= fr + 1; end if;
      end if;

      ------------------------------------------------------------------ requests
      if done = '1' then
        act <= '0';
        case kind is
          when K_CR => rbuf <= m_d0; rpend <= '0';
          when K_CW => wpend <= '0';
          when K_BAT => if bg = B_WBAT then
                          if msz(1) = '1' and bpage = '0' then bg <= B_BAT; bpage <= '1'; else bg <= B_COL; end if;
                        end if;
          when K_CG => if bg = B_WCG then
                         fifo(to_integer(fw(2 downto 0))) <= bat_q(15 downto 12) & m_d1 & m_d0;
                         fw <= fw + 1;
                         bgcol <= bgcol + 1;
                         bgleft <= bgleft - 1;
                         if bgleft = 1 then bg <= B_OFF; else bg <= B_COL; end if;
                       end if;
          when K_SPR =>
            sbusy <= '0';
            dr_n <= "00000"; dr_x <= f_x; dr_pal <= f_pal; dr_pri <= f_pri; dr_s0 <= f_s0;
            if f_flip = '1' then
              dr0 <= rev(m_d0); dr1 <= rev(m_d1); dr2 <= rev(m_d2); dr3 <= rev(m_d3);
            else
              dr0 <= m_d0; dr1 <= m_d1; dr2 <= m_d2; dr3 <= m_d3;
            end if;
          when K_SATB =>
            satb_n <= satb_n + resize(q_len, 9);
            satb_a <= satb_a + resize(q_len, 16);
            if satb_n + resize(q_len, 9) = 256 then
              satb_run <= '0';
              if dcr(0) = '1' then f_ds <= '1'; end if;
            end if;
          when K_DR => dma_w <= '1'; dma_d <= m_d0;
          when K_DW =>
            dma_w <= '0';
            if dcr(2) = '1' then sour <= sour - 1; else sour <= sour + 1; end if;
            if dcr(3) = '1' then desr <= desr - 1; else desr <= desr + 1; end if;
            lenr <= lenr - 1;
            if lenr = 0 then
              dma_run <= '0';
              if dcr(1) = '1' then f_dv <= '1'; end if;
            end if;
        end case;
      end if;
      if act = '0' then
        q_we <= '0'; q_len <= "0000001"; q_dst <= "000";
        if wpend = '1' then
          kind <= K_CW; act <= '1'; tog <= not tog; q_we <= '1'; q_a <= wa; q_d <= wdat;
        elsif rpend = '1' then
          kind <= K_CR; act <= '1'; tog <= not tog; q_a <= rd_a;
        elsif bg = B_BAT then
          kind <= K_BAT; act <= '1'; tog <= not tog; q_a <= bat_a; q_dst <= "001";
          if msz(1 downto 0) = "00" then q_len <= "0100000"; else q_len <= "1000000"; end if;
          bg <= B_WBAT;
        elsif bg = B_CG and fcnt(3) = '0' then
          kind <= K_CG; act <= '1'; tog <= not tog; q_dst <= "010"; q_len <= "0001001";
          q_a <= unsigned(bat_q(11 downto 0)) & '0' & bgy(2 downto 0);
          bg <= B_WCG;
        elsif sreq = '1' then
          kind <= K_SPR; act <= '1'; tog <= not tog; q_dst <= "011"; q_len <= "0110001"; q_a <= sreq_a;
          sreq <= '0';
        elsif satb_run = '1' then
          kind <= K_SATB; act <= '1'; tog <= not tog; q_dst <= "100"; q_a <= satb_a; q_len <= satb_len;
        elsif dma_run = '1' and (vbl = '1' or (bgon = '0' and spon = '0')) then
          act <= '1'; tog <= not tog;
          if dma_w = '0' then kind <= K_DR; q_a <= sour;
          else kind <= K_DW; q_a <= desr; q_we <= '1'; q_d <= dma_d; end if;
        end if;
      end if;

      -- background: BAT word (bgcol -> bat_q one clk later)
      case bg is
        when B_COL => bg <= B_RD;
        when B_RD  => bg <= B_CG;
        when others => null;
      end case;

      ------------------------------------------------------------------ sprites
      case sp is
        when S_Y   => sp <= S_YW;                              -- satb_ra = Y
        when S_YW  => sy <= unsigned(satb_q(9 downto 0)); sp <= S_AT;
        when S_AT  => sdy <= sline - sy; sp <= S_ATW;           -- satb_ra = attributes
        when S_ATW => sat <= satb_q; sp <= S_CHK;
        when S_CHK =>
          case sat(13 downto 12) is
            when "00"   => ok := sdy(9 downto 4) = 0;
            when "01"   => ok := sdy(9 downto 5) = 0;
            when others => ok := sdy(9 downto 6) = 0;
          end case;
          scell <= '0';
          if ok then sp <= S_X; else sp <= S_NEXT; end if;
        when S_X   => sx <= unsigned(satb_q(9 downto 0)); sp <= S_PT;
        when S_PT  => spt <= unsigned(satb_q(10 downto 1)); sp <= S_GO;
        when S_GO  =>
          if ncell = 16 then
            if cr(1) = '1' then f_or <= '1'; end if;
            sp <= S_OFF;
          elsif sreq = '0' and sbusy = '0' then
            yy := sdy(5 downto 0);
            if sat(15) = '1' then yy := not yy; end if;
            cell := spt;
            if sat(8) = '1' then cell(0) := scell xor sat(11); end if;
            case sat(13 downto 12) is
              when "00" => null;
              when "01" => cell(1) := yy(4);
              when others => cell(2 downto 1) := yy(5 downto 4);
            end case;
            sreq <= '1'; sbusy <= '1';
            sreq_a <= cell & "00" & yy(3 downto 0);
            f_x <= ('0' & sx) - 32;
            if scell = '1' then f_x <= ('0' & sx) - 16; end if;
            f_pal <= sat(3 downto 0); f_pri <= sat(7); f_flip <= sat(11);
            f_s0 <= '0';
            if si = 0 then f_s0 <= '1'; end if;
            ncell <= ncell + 1;
            scell <= '1';
            if sat(8) = '0' or scell = '1' then sp <= S_NEXT; end if;
          end if;
        when S_NEXT =>
          si <= si + 1;
          if si = 63 then sp <= S_OFF; else sp <= S_Y; end if;
        when S_OFF => null;
      end case;

      -- drawing: one pixel per clk, read then write two clk later
      d1_v <= '0';
      if dr_n(4) = '0' then
        dr_n <= dr_n + 1;
        dr_x <= dr_x + 1;
        dr0 <= dr0(14 downto 0) & '0'; dr1 <= dr1(14 downto 0) & '0';
        dr2 <= dr2(14 downto 0) & '0'; dr3 <= dr3(14 downto 0) & '0';
        if dp /= "0000" and dr_x(10) = '0' then d1_v <= '1'; end if;
        d1_x <= std_logic_vector(dr_x(9 downto 0));
        d1_d <= dr_s0 & dr_pri & dr_pal & dp;
      end if;
      if d1_v = '1' and dq(3 downto 0) /= "0000" and dq(9) = '1' and d1_d(9) = '0' and cr(0) = '1' then
        f_cr <= '1';
      end if;

      if reset = '1' then
        cr <= (others => '0'); dcr <= "00000"; wpend <= '0'; rpend <= '0';
        f_cr <= '0'; f_or <= '0'; f_rr <= '0'; f_ds <= '0'; f_dv <= '0'; f_vd <= '0';
        satb_req <= '0'; satb_run <= '0'; dma_run <= '0'; sp <= S_OFF; bg <= B_OFF; sreq <= '0'; sbusy <= '0';
        bgon <= '0'; spon <= '0'; nact <= '0'; lact <= '0'; dr_n <= "10000";
        -- a request in flight just ends
      end if;
    end if;
  end process;
  done <= act when ack1 = tog else '0';

  bat_row <= (bgy(8) and msz(2)) & bgy(7 downto 3);
  bat_a <= resize(bat_row, 16) sll 5 when msz(1 downto 0) = "00" else
           resize(bat_row, 16) sll 6 when msz(1 downto 0) = "01" else
           "000" & bat_row & bpage & "000000";
  bat_ra <= "00" & std_logic_vector(bgcol(4 downto 0)) when msz(1 downto 0) = "00" else
            '0' & std_logic_vector(bgcol(5 downto 0)) when msz(1 downto 0) = "01" else
            std_logic_vector(bgcol);
  fcnt <= fw - fr;
  fq <= fifo(to_integer(fr(2 downto 0)));
  process(all)
    variable b : integer range 0 to 7;
  begin
    b := 7 - to_integer(fine);
    bgp <= fq(24 + b) & fq(16 + b) & fq(8 + b) & fq(b);
  end process;

  -- SATB
  satb_ra <= std_logic_vector(si(5 downto 0)) & "00" when sp = S_Y or sp = S_OFF or sp = S_NEXT else
             std_logic_vector(si(5 downto 0)) & "11" when sp = S_YW or sp = S_AT else
             std_logic_vector(si(5 downto 0)) & "01" when sp = S_ATW or sp = S_CHK else
             std_logic_vector(si(5 downto 0)) & "10";
  satb_len <= "1000000" - ('0' & satb_a(5 downto 0)) when satb_n(8 downto 6) /= 3 or
                  ('0' & satb_n(5 downto 0)) <= ('0' & satb_a(5 downto 0)) else
              "1000000" - ('0' & satb_n(5 downto 0));

  -- sprite line buffers: bank sb is shown (and cleared), the other is drawn
  dp  <= dr3(15) & dr2(15) & dr1(15) & dr0(15);
  clr <= disp and dot;
  dw  <= '1' when d1_v = '1' and dq(3 downto 0) = "0000" else '0';
  rdx <= std_logic_vector(dx);
  b0_ra <= rdx when sb = '0' else std_logic_vector(dr_x(9 downto 0));
  b1_ra <= rdx when sb = '1' else std_logic_vector(dr_x(9 downto 0));
  b0_we <= clr when sb = '0' else dw;
  b1_we <= clr when sb = '1' else dw;
  b0_wa <= rdx when sb = '0' else d1_x;
  b1_wa <= rdx when sb = '1' else d1_x;
  b0_wd <= (others => '0') when sb = '0' else d1_d;
  b1_wd <= (others => '0') when sb = '1' else d1_d;
  u_b0 : entity work.sdp_ram generic map (10, 10) port map (clk, b0_we, b0_wa, b0_wd, clk, b0_ra, b0_q);
  u_b1 : entity work.sdp_ram generic map (10, 10) port map (clk, b1_we, b1_wa, b1_wd, clk, b1_ra, b1_q);
  sq <= b0_q when sb = '0' else b1_q;
  dq <= b1_q when sb = '0' else b0_q;

  process(clk)
  begin
    if rising_edge(clk) then
      if dot = '1' then
        pa <= "100000000";
        if disp = '1' then
          pa <= (others => '0');
          if bgon = '1' and bgp /= "0000" then pa <= '0' & fq(35 downto 32) & bgp; end if;
          if spon = '1' and sq(3 downto 0) /= "0000" and (sq(8) = '1' or bgon = '0' or bgp = "0000") then
            pa <= '1' & sq(7 downto 0);
          end if;
        end if;
      end if;
    end if;
  end process;

  -- memclk side ----------------------------------------------------------------
  p_addr <= "00000" & std_logic_vector(q_a) & '0';
  p_len  <= std_logic_vector(q_len);
  p_din  <= q_d;
  p_read <= m_rd;
  p_write <= m_wr;
  bat_we  <= p_rvalid when q_dst = "001" else '0';
  bat_wa  <= bpage & std_logic_vector(m_cnt(5 downto 0));
  satb_we <= p_rvalid when q_dst = "100" else '0';
  satb_wa <= std_logic_vector(satb_n(7 downto 0) + resize(m_cnt, 8));
  u_bat  : entity work.sdp_ram generic map (7, 16) port map (memclk, bat_we, bat_wa, p_dout, clk, bat_ra, bat_q);
  u_satb : entity work.sdp_ram generic map (8, 16) port map (memclk, satb_we, satb_wa, p_dout, clk, satb_ra, satb_q);
  process(memclk)
  begin
    if rising_edge(memclk) then
      m_req <= tog;
      m_t <= m_req;
      if m_req /= m_t then
        m_rd <= not q_we; m_wr <= q_we; m_cnt <= (others => '0');
      elsif p_busy = '0' then
        m_rd <= '0'; m_wr <= '0';
        if m_wr = '1' then m_ack <= m_t; end if;
      end if;
      if p_rvalid = '1' then
        m_cnt <= m_cnt + 1;
        if m_cnt = 0 then m_d0 <= p_dout; end if;
        if (q_dst(0) = '0' and m_cnt = 8) or (q_dst(0) = '1' and m_cnt = 16) then m_d1 <= p_dout; end if;
        if m_cnt = 32 then m_d2 <= p_dout; end if;
        if m_cnt = 48 then m_d3 <= p_dout; end if;
        if m_cnt = q_len - 1 then m_ack <= m_t; end if;
      end if;
    end if;
  end process;
end architecture;
