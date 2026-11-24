--
-- psram_tester.vhd : endless test of one PSRAM die through psram_burst.
-- Requests are held until accepted, so the accesses are back to back.
-- phase 0 fill (bursts of 2,4,9,16,33,64,1,1 words)      fixed latency
--       1 read and check, same lengths, other alignment   fixed latency
--       2 per block: write inverted, read, two byte writes, read, write
--         normal, read (turn-arounds in both directions)  fixed latency
--       3 read and check                                  variable latency
-- then pass + 1. Errors are counted per phase (1, 2, 3), saturating.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity psram_tester is
  generic (
    WBITS : integer := 21;     -- words tested = 2**WBITS (21 = the whole 4 MB)
    TBITS : integer := 16      -- words of phase 2 = 2**TBITS
  );
  port (
    clk, resetn : in  std_logic;
    clr         : in  std_logic;
    m_resetn, m_fixed, m_read, m_write, m_bw : out std_logic;
    m_addr      : out std_logic_vector(21 downto 0);
    m_len       : out std_logic_vector(6 downto 0);
    m_din       : out std_logic_vector(15 downto 0);
    m_dout      : in  std_logic_vector(15 downto 0);
    m_rvalid, m_wtake, m_busy : in std_logic;
    phase       : out std_logic_vector(3 downto 0);
    pass        : out std_logic_vector(15 downto 0);
    e1, e2, e3  : out std_logic_vector(15 downto 0);
    fa          : out std_logic_vector(23 downto 0);   -- first error: word address
    fg, fx      : out std_logic_vector(15 downto 0);   -- got, expected
    -- clk: read 1 word fixed max, variable min / max, 9 and 33 words fixed
    -- max, variable 16 words max, write 1 word max
    r1f, r1vn, r1vx, r9f, r33f, r16v, w1 : out std_logic_vector(7 downto 0);
    slow        : out std_logic_vector(15 downto 0);   -- variable: 1-word reads above the min, last pass
    err         : out std_logic
  );
end entity;

architecture rtl of psram_tester is
  subtype wa_t is unsigned(20 downto 0);
  type st_t is (S_RST, S_BOOT, S_PREP, S_PREP2, S_REQ, S_WAIT);
  signal st    : st_t := S_RST;
  signal tmr   : unsigned(4 downto 0) := (others => '0');
  signal ph    : unsigned(1 downto 0) := "00";
  signal step  : unsigned(2 downto 0) := "000";
  signal pass_i: unsigned(15 downto 0) := (others => '0');
  signal cut   : std_logic := '0';
  signal bump  : std_logic := '0';
  signal fixed : std_logic := '1';
  signal req, req_wr, req_bw, req_inv, req_w0 : std_logic := '0';
  signal n_a   : unsigned(21 downto 0) := (others => '0');   -- one more bit: done
  signal b0    : std_logic := '0';
  signal n_len, t_len : unsigned(6 downto 0) := (others => '0');
  signal li    : unsigned(2 downto 0) := "000";
  signal room  : unsigned(6 downto 0);
  signal acc   : std_logic;
  -- access in progress
  signal wa    : wa_t := (others => '0');
  signal w_inv, w_pre : std_logic := '0';
  signal din   : std_logic_vector(15 downto 0) := (others => '0');
  signal ra    : wa_t := (others => '0');
  signal r_inv, r_w0 : std_logic := '0';
  signal lat   : unsigned(7 downto 0) := (others => '0');
  signal c_wr  : std_logic := '0';
  signal c_len : unsigned(6 downto 0) := (others => '0');
  signal c_act, done_p, d_wr : std_logic := '0';
  signal d_lat : unsigned(7 downto 0) := (others => '0');
  signal d_len : unsigned(6 downto 0) := (others => '0');
  -- check pipeline
  signal v1, v2, v3, v4, i1 : std_logic := '0';
  signal a1, a2, a3, a4 : wa_t := (others => '0');
  signal d1, d2, d3, x2, x3, d4, x4 : std_logic_vector(15 downto 0) := (others => '0');
  signal ne    : std_logic_vector(3 downto 0) := "0000";
  signal e1i, e2i, e3i, sl : unsigned(15 downto 0) := (others => '0');
  signal err_i : std_logic := '0';
  signal r1fi, r1vxi, r9fi, r33fi, r16vi, w1i : unsigned(7 downto 0) := (others => '0');
  signal r1vni : unsigned(7 downto 0) := x"FF";

  -- neighbouring words are nearly complementary
  function pat(a : wa_t; p : unsigned(15 downto 0); inv : std_logic) return std_logic_vector is
    variable x : unsigned(15 downto 0);
  begin
    x := a(15 downto 0) xor (a(20 downto 16) & a(4 downto 0) & "000000")
         xor (p(7 downto 0) & p(7 downto 0)) xor x"00FF";
    if (a(0) xor inv) = '1' then x := not x; end if;
    return std_logic_vector(x);
  end function;
  function length_of(i : unsigned(2 downto 0)) return integer is
  begin
    case to_integer(i) is
      when 0 => return 2;   when 1 => return 4;   when 2 => return 9;
      when 3 => return 16;  when 4 => return 33;  when 5 => return 64;
      when others => return 1;
    end case;
  end function;
begin
  acc      <= req and not m_busy;
  m_fixed  <= fixed;
  m_read   <= req and not req_wr;
  m_write  <= req and req_wr;
  m_bw     <= req_bw;
  m_addr   <= std_logic_vector(n_a(20 downto 0)) & b0;
  m_len    <= std_logic_vector(n_len);
  m_din    <= din;
  room     <= "1000000" - ("0" & n_a(5 downto 0));

  process(clk)
    variable fin : boolean;
  begin
    if rising_edge(clk) then
      m_resetn <= '1';
      case st is
        when S_RST =>                         -- controller reset: new latency mode
          m_resetn <= '0';
          tmr <= tmr + 1;
          if tmr = 20 and bump = '1' then pass_i <= pass_i + 1; bump <= '0'; end if;
          if tmr = 31 then st <= S_BOOT; end if;
        when S_BOOT =>
          tmr <= tmr + 1;
          if tmr = 31 then st <= S_WAIT; end if;
        when S_WAIT =>                        -- init of the device done
          if m_busy = '0' then st <= S_PREP; end if;
        when S_PREP =>
          t_len <= to_unsigned(length_of(li), 7);
          if n_a(WBITS) = '0' and not (ph = 2 and n_a(TBITS) = '1') then
            st <= S_PREP2;
          elsif ph < 2 or m_busy = '0' then   -- 2 and 3: let the last access finish
            n_a <= (others => '0');
            ph  <= ph + 1;
            li  <= li + 1;                    -- other alignment in each phase
            if ph >= 2 then                   -- to variable / back to fixed
              fixed <= not fixed;
              if ph = 3 then bump <= '1'; end if;
              tmr <= (others => '0');
              st  <= S_RST;
            end if;
          end if;
        when S_PREP2 =>
          cut <= '0';
          if t_len > room then n_len <= room; cut <= '1'; else n_len <= t_len; end if;
          req_wr <= '0'; req_bw <= '0'; req_inv <= '0'; req_w0 <= '0'; b0 <= '0';
          if ph = 0 then req_wr <= '1'; end if;
          if ph = 2 then
            case to_integer(step) is
              when 0 => req_wr <= '1'; req_inv <= '1';
              when 1 => req_inv <= '1';
              when 2 => req_wr <= '1'; req_bw <= '1'; b0 <= '1'; n_len <= "0000001";
              when 3 => req_wr <= '1'; req_bw <= '1'; n_len <= "0000001";
              when 4 => req_inv <= '1'; req_w0 <= '1';
              when 5 => req_wr <= '1';
              when others => null;
            end case;
          end if;
          req <= '1';
          st  <= S_REQ;
        when S_REQ =>
          if acc = '1' then
            req <= '0';
            fin := true;
            if ph = 2 then
              step <= step + 1;
              if step = 6 then step <= "000"; else fin := false; end if;
            end if;
            if fin then
              n_a <= n_a + n_len;
              if cut = '0' then li <= li + 1; end if;   -- cut: again, aligned
            end if;
            st <= S_PREP;
          end if;
      end case;
      if resetn = '0' then
        m_resetn <= '0';
        st <= S_RST; tmr <= (others => '0'); req <= '0'; ph <= "00"; step <= "000"; bump <= '0';
        n_a <= (others => '0'); fixed <= '1'; pass_i <= (others => '0');
      end if;

      -- write data
      w_pre <= '0';
      if acc = '1' and req_wr = '1' then
        wa <= n_a(20 downto 0); w_inv <= req_inv; w_pre <= '1';
      elsif w_pre = '1' or m_wtake = '1' then
        din <= pat(wa, pass_i, w_inv);
        wa  <= wa + 1;
      end if;

      -- read check
      v1 <= m_rvalid; d1 <= m_dout;
      a1 <= ra; i1 <= r_inv and not r_w0;
      if acc = '1' and req_wr = '0' then
        ra <= n_a(20 downto 0); r_inv <= req_inv; r_w0 <= req_w0;
      elsif m_rvalid = '1' then
        ra <= ra + 1; r_w0 <= '0';
      end if;
      v2 <= v1; a2 <= a1; d2 <= d1; x2 <= pat(a1, pass_i, i1);
      a3 <= a2; d3 <= d2; x3 <= x2;
      for i in 0 to 3 loop
        ne(i) <= '0';
        if d2(4*i+3 downto 4*i) /= x2(4*i+3 downto 4*i) then ne(i) <= v2; end if;
      end loop;
      v4 <= '0'; a4 <= a3; d4 <= d3; x4 <= x3;
      if ne /= "0000" then v4 <= '1'; end if;
      if v4 = '1' then
        if err_i = '0' then
          fa <= "000" & std_logic_vector(a4); fg <= d4; fx <= x4;
        end if;
        err_i <= '1';
        case to_integer(ph) is
          when 2      => if e2i /= x"FFFF" then e2i <= e2i + 1; end if;
          when 3      => if e3i /= x"FFFF" then e3i <= e3i + 1; end if;
          when others => if e1i /= x"FFFF" then e1i <= e1i + 1; end if;
        end case;
      end if;

      -- durations
      lat <= lat + 1;
      done_p <= '0';
      if c_act = '1' and m_busy = '0' then
        done_p <= '1'; d_lat <= lat; d_wr <= c_wr; d_len <= c_len; c_act <= '0';
      end if;
      if acc = '1' then
        lat <= (others => '0'); c_act <= '1'; c_wr <= req_wr; c_len <= n_len;
      end if;
      if done_p = '1' then
        if d_wr = '1' then
          if d_len = 1 and d_lat > w1i then w1i <= d_lat; end if;
        elsif fixed = '1' then
          if d_len = 1 and d_lat > r1fi then r1fi <= d_lat; end if;
          if d_len = 9 and d_lat > r9fi then r9fi <= d_lat; end if;
          if d_len = 33 and d_lat > r33fi then r33fi <= d_lat; end if;
        else
          if d_len = 1 and d_lat > r1vxi then r1vxi <= d_lat; end if;
          if d_len = 1 and d_lat < r1vni then r1vni <= d_lat; end if;
          if d_len = 16 and d_lat > r16vi then r16vi <= d_lat; end if;
          if d_len = 1 and d_lat > r1vni and sl /= x"FFFF" then sl <= sl + 1; end if;
        end if;
      end if;
      if fixed = '1' and st = S_RST then
        if tmr = 5 then slow <= std_logic_vector(sl); end if;
        if tmr = 6 then sl <= (others => '0'); end if;
      end if;

      if clr = '1' or resetn = '0' then
        err_i <= '0'; e1i <= (others => '0'); e2i <= (others => '0'); e3i <= (others => '0');
        fa <= (others => '0'); fg <= (others => '0'); fx <= (others => '0');
        r1fi <= (others => '0'); r1vxi <= (others => '0'); r9fi <= (others => '0');
        r33fi <= (others => '0'); r16vi <= (others => '0'); w1i <= (others => '0');
        r1vni <= x"FF";
      end if;
    end if;
  end process;

  phase <= "00" & std_logic_vector(ph);
  pass  <= std_logic_vector(pass_i);
  e1 <= std_logic_vector(e1i); e2 <= std_logic_vector(e2i); e3 <= std_logic_vector(e3i);
  r1f <= std_logic_vector(r1fi); r1vn <= std_logic_vector(r1vni); r1vx <= std_logic_vector(r1vxi);
  r9f <= std_logic_vector(r9fi); r33f <= std_logic_vector(r33fi); r16v <= std_logic_vector(r16vi);
  w1 <= std_logic_vector(w1i);
  err <= err_i;
end architecture;
