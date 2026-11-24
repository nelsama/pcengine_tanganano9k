--
-- huc6280.vhd : HuC6280 CPU core (65C02 superset + MMU), one memory access or
-- dummy cycle per CPU cycle, with the cycle counts of the real part.
-- The timer, the interrupt controller, the I/O port and the PSG are outside.
--
--   ce    one clk pulse per CPU cycle; everything advances at that edge
--   mem   the current cycle really accesses memory (0 = dummy cycle)
--   addr  21-bit physical address, stable from one ce to the next
--   fast  1 = CSH (7.16 MHz), 0 = CSL (1.79 MHz): the caller makes the ce
--   irq   (2) timer, (1) IRQ1 = VDC, (0) IRQ2; levels, already masked
-- The extra cycle of the VDC / VCE accesses is also the caller's (a late ce).
--
-- Differences: block transfers push nothing on the stack; they make the 17 + 6n
-- cycles of the real part, not its exact bus sequence.
-- KLAUS = true: zero page at $0000, IRQ vector $FFFE, no T flag, only to run the
-- 6502 functional test.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity huc6280 is
  generic (KLAUS : boolean := false);
  port (
    clk, reset, ce : in std_logic;
    addr  : out std_logic_vector(20 downto 0);
    mem   : out std_logic;
    we    : out std_logic;
    dout  : out std_logic_vector(7 downto 0);
    din   : in  std_logic_vector(7 downto 0);
    irq   : in  std_logic_vector(2 downto 0);
    fast  : out std_logic;
    sync  : out std_logic;      -- opcode fetch cycle
    dbg   : out std_logic_vector(55 downto 0)   -- PC A X Y P S, simulation only
  );
end entity;

architecture rtl of huc6280 is
  subtype u8  is unsigned(7 downto 0);
  subtype u16 is unsigned(15 downto 0);
  type st_t is (
    F,                      -- opcode fetch
    D,                      -- second cycle
    OH, IX, PL, PH, I2,     -- effective address
    M, RM, RB, W,           -- memory, modify, RMB / SMB extra, write back
    T1, T2, TW,             -- T flag: read zp,X ; dummy ; write
    BB, BR,                 -- BBR / BBS
    TA,                     -- TST: address after the immediate
    SD, STW,               -- ST0-2
    PU, PO0, PO,            -- push, pull
    JD, PHH, PHL, PHP, VL, VH, RL, RH, RJ, BJ, JL, JH,
    MD, MW,                 -- TMA / TAM
    BO, B0, B1, B2, B3, B4, B5,
    WT);
  signal s : st_t;

  signal a, x, y, sp, dl, ir : u8;
  signal pc, ea, dst, len    : u16;
  signal fn, fv, ft, fd, fi, fz, fc : std_logic;
  signal tnow, pend, isirq, alt, fastr : std_logic;
  signal vec  : std_logic_vector(1 downto 0);
  signal wcnt : unsigned(3 downto 0);
  type mpr_t is array (0 to 7) of u8;
  signal mpr  : mpr_t := (others => x"FF");

  constant ZH : u8 := (5 => '1', others => '0');
  function zp(k : boolean) return u8 is
  begin if k then return x"00"; else return ZH; end if; end function;
  function st(k : boolean) return u8 is
  begin if k then return x"01"; else return x"21"; end if; end function;

  type mode_t is (M_IMP, M_IMM, M_ZP, M_ZPX, M_ZPY, M_ABS, M_ABSX, M_ABSY, M_INDX, M_INDY, M_IND);
  signal mode : mode_t;
  signal l5   : std_logic_vector(4 downto 0);
  signal i3   : std_logic_vector(2 downto 0);
  -- what to do with memory
  signal g1, is_st, is_rmw, is_bit, is_tsb, is_rmb, is_bb, is_tst, is_blk, tcap : std_logic;

  signal la    : u16;                              -- logical address
  signal agu_a, agu_b, agu : u16;
  signal alu_a, alu_b, alu_r : u8;
  signal alu_op : std_logic_vector(2 downto 0);    -- 0 ORA 1 AND 2 EOR 3 ADC 4 pass 5 pass 6 CMP 7 SBC
  signal alu_c, alu_v : std_logic;
  signal inc_r, inc_a, sh_r, sh_a, rmw_r : u8;
  signal sh_c  : std_logic;
  signal pbyte, st_data : u8;
  signal bmask : u8;
  signal bcond : std_logic;
  signal page  : u8;
begin
  l5 <= std_logic_vector(ir(4 downto 0));
  i3 <= std_logic_vector(ir(7 downto 5));

  -- decode -------------------------------------------------------------------
  process(all)
  begin
    mode <= M_IMP;
    g1 <= '0'; is_st <= '0'; is_rmw <= '0'; is_bit <= '0'; is_tsb <= '0';
    is_rmb <= '0'; is_bb <= '0'; is_tst <= '0'; is_blk <= '0';
    case l5 is
      when "00001" => mode <= M_INDX; g1 <= '1';
      when "00101" => mode <= M_ZP;   g1 <= '1';
      when "01001" => mode <= M_IMM;  g1 <= '1';
      when "01101" => mode <= M_ABS;  g1 <= '1';
      when "10001" => mode <= M_INDY; g1 <= '1';
      when "10010" => mode <= M_IND;  g1 <= '1';
      when "10101" => mode <= M_ZPX;  g1 <= '1';
      when "11001" => mode <= M_ABSY; g1 <= '1';
      when "11101" => mode <= M_ABSX; g1 <= '1';
      when "00000" => if i3 = "101" or i3 = "110" or i3 = "111" then mode <= M_IMM; end if;
      when "00010" => if i3 = "101" then mode <= M_IMM; end if;
      when "00100" => if i3 /= "010" then mode <= M_ZP; end if;
                      if i3 = "000" then is_rmw <= '1'; is_tsb <= '1'; end if;
      when "10100" =>
        case i3 is
          when "000" => mode <= M_ZP; is_rmw <= '1'; is_tsb <= '1';
          when "001" | "011" | "100" | "101" => mode <= M_ZPX;
          when others => null;
        end case;
      when "00110" => mode <= M_ZP;
      when "10110" => if i3 = "100" or i3 = "101" then mode <= M_ZPY; else mode <= M_ZPX; end if;
      when "01100" => mode <= M_ABS;
                      if i3 = "000" then is_rmw <= '1'; is_tsb <= '1'; end if;
      when "11100" =>
        case i3 is
          when "000" => mode <= M_ABS; is_rmw <= '1'; is_tsb <= '1';
          when "001" | "011" | "101" => mode <= M_ABSX;
          when "100" => mode <= M_ABS;
          when others => null;
        end case;
      when "01110" => mode <= M_ABS;
      when "11110" => if i3 = "101" then mode <= M_ABSY; else mode <= M_ABSX; end if;
      when "00111" | "10111" => mode <= M_ZP; is_rmw <= '1'; is_rmb <= '1';
      when "01111" | "11111" => mode <= M_ZP; is_bb <= '1';
      when "00011" | "10011" =>
        if ir(7) = '1' and ir(6) = '0' then       -- 83 93 A3 B3
          is_tst <= '1';
          if ir(4) = '0' and ir(5) = '0' then mode <= M_ZP;
          elsif ir(4) = '0' then mode <= M_ZPX;
          elsif ir(5) = '0' then mode <= M_ABS;
          else mode <= M_ABSX; end if;
        elsif (ir(7) = '1' and (ir(4) = '1' or ir(5) = '0')) or ir = x"73" then
          is_blk <= '1';                            -- 73 C3 D3 E3 F3 (E3 below)
        end if;
        if ir = x"E3" then is_blk <= '1'; end if;
      when others => null;
    end case;
    if ir(7 downto 5) /= "100" and ir(7 downto 5) /= "101" and
       (l5 = "00110" or l5 = "10110" or l5 = "01110" or l5 = "11110") then
      is_rmw <= '1';
    end if;
    -- stores: STA (all but 89), STZ 64 74 9C 9E, STY, STX
    if i3 = "100" and (g1 = '1' or l5 = "00100" or l5 = "10100" or l5 = "01100" or l5 = "11100"
       or l5 = "00110" or l5 = "10110" or l5 = "01110" or l5 = "11110") and ir /= x"89" then
      is_st <= '1';
    end if;
    if ir = x"64" or ir = x"74" then is_st <= '1'; end if;
    if ir = x"24" or ir = x"2C" or ir = x"34" or ir = x"3C" or ir = x"89" then is_bit <= '1'; end if;
  end process;
  tcap <= tnow and g1 and not ir(7);               -- ORA AND EOR ADC

  -- address ------------------------------------------------------------------
  process(all)
  begin
    case s is
      when M | RM | RB | W | JL | JH | PL | PH | B0 | B1 => la <= ea;
      when T1 | T2 | TW     => la <= zp(KLAUS) & x;
      when PU | PO | PHH | PHL | PHP | RL | RH => la <= st(KLAUS) & sp;
      when VL | VH =>
        case vec is
          when "00"   => la <= x"FFF6";
          when "01"   => la <= x"FFF8";
          when "10"   => la <= x"FFFA";
          when others => la <= x"FFFE";
        end case;
        if KLAUS then la <= x"FFFE"; end if;
        if s = VH then la(0) <= '1'; end if;
      when B2 => la <= dst;
      when MD =>                                    -- TMA: the mapping mux selects the MPR
        la <= (others => '0');
        for i in 0 to 7 loop
          if dl(i) = '1' then la(15 downto 13) <= to_unsigned(i, 3); end if;
        end loop;
      when others => la <= pc;
    end case;
  end process;
  page <= mpr(to_integer(la(15 downto 13)));
  process(all)
  begin
    addr <= std_logic_vector(page) & std_logic_vector(la(12 downto 0));
    if s = STW then
      addr <= (others => '1');
      addr(12 downto 2) <= (others => '0');
      addr(1) <= ir(4) or ir(5);                    -- 03 -> 0, 13 -> 2, 23 -> 3
      addr(0) <= ir(5);
    end if;
    case s is
      when F | OH | PL | PH | T1 | TW | BR | TA | STW | PU | PO | PHH | PHL | PHP | VL | VH
           | RL | RH | JL | JH | BO | B0 | B2 | M | W => mem <= '1';
      when D => if mode /= M_IMP or is_blk = '1' or is_tst = '1' then mem <= '1';
                else
                  mem <= '0';
                  case l5 is
                    when "10000" => mem <= '1';
                    when "00000" => mem <= not ir(6);
                    when "00011" | "10011" | "00100" => mem <= '1';
                    when others => null;
                  end case;
                end if;
      when others => mem <= '0';
    end case;
    we <= '0';
    case s is
      when W | TW | STW | PU | PHH | PHL | PHP | B2 => we <= '1';
      when M => we <= is_st;
      when others => null;
    end case;
  end process;
  sync <= '1' when s = F else '0';
  dbg <= std_logic_vector(unsigned'(pc & a & x & y & pbyte & sp));
  fast <= fastr;

  pbyte <= fn & fv & ft & '1' & fd & fi & fz & fc when not KLAUS else
           fn & fv & '1' & '1' & fd & fi & fz & fc;
  st_data <= x"00" when ir(1 downto 0) = "00" and (ir(7) = '0' or ir(4 downto 3) = "11") else   -- STZ 64 74 9C
             x"00" when ir = x"9E" else
             a when ir(0) = '1' or l5 = "10010" else x when ir(1) = '1' else y;
  process(all)
  begin
    case s is
      when M   => dout <= std_logic_vector(st_data);
      when PU  =>
        if ir(1) = '1' then
          if ir(7) = '1' then dout <= std_logic_vector(x); else dout <= std_logic_vector(y); end if;
        elsif ir(6) = '1' then dout <= std_logic_vector(a);
        else dout <= std_logic_vector(pbyte); end if;
      when PHH => dout <= std_logic_vector(pc(15 downto 8));
      when PHL => dout <= std_logic_vector(pc(7 downto 0));
      when PHP => dout <= std_logic_vector(pbyte); dout(4) <= not isirq;
      when others => dout <= std_logic_vector(dl);
    end case;
  end process;

  -- address adder --------------------------------------------------------------
  process(all)
  begin
    agu_a <= pc; agu_b <= x"0001";
    case s is
      when IX =>
        agu_a <= ea;
        case mode is
          when M_ZPX | M_ABSX | M_INDX => agu_b <= x"00" & x;
          when M_ZPY | M_ABSY => agu_b <= x"00" & y;
          when others => agu_b <= x"0000";
        end case;
      when I2 =>
        agu_a <= ea; agu_b <= x"0000";
        if mode = M_INDY then agu_b <= x"00" & y; end if;
      when PL | JL => agu_a <= ea;
      when BJ => agu_b <= unsigned(resize(signed(dl), 16));
      when B0 =>
        agu_a <= ea;
        if ir = x"C3" or (ir = x"F3" and alt = '1') then agu_b <= x"FFFF"; end if;
      when B3 =>
        agu_a <= dst;
        if ir = x"C3" or (ir = x"E3" and alt = '1') then agu_b <= x"FFFF"; end if;
        if ir = x"D3" then agu_b <= x"0000"; end if;
      when B4 => agu_a <= len; agu_b <= x"FFFF";
      when others => null;
    end case;
  end process;
  agu <= agu_a + agu_b;

  -- ALU --------------------------------------------------------------------------
  alu_b <= unsigned(din);
  process(all)
    variable b : u8;
    variable lo, hi : unsigned(4 downto 0);
    variable cin, hc, co, sub, dec : std_logic;
    variable sum, adj : u8;
  begin
    alu_op <= i3;
    alu_a  <= a;
    if g1 = '0' then
      if is_bit = '1' then alu_op <= "001";
      elsif i3 = "101" then alu_op <= "101";          -- LDX LDY
      else
        alu_op <= "110";                              -- CPX CPY
        if i3 = "111" then alu_a <= x; else alu_a <= y; end if;
      end if;
    end if;
    if ir = x"89" then alu_op <= "001"; end if;
    if s = T1 then alu_a <= dl; end if;
    if is_tst = '1' then alu_op <= "001"; alu_a <= dl; end if;

    sub := alu_op(2);
    dec := fd and alu_op(0);                          -- only ADC, SBC
    if sub = '1' then b := not alu_b; else b := alu_b; end if;
    cin := fc;
    if alu_op = "110" then cin := '1'; end if;
    lo := ('0' & alu_a(3 downto 0)) + ('0' & b(3 downto 0)) + ("0000" & cin);
    hc := lo(4);
    if dec = '1' and sub = '0' and lo > 9 then hc := '1'; end if;
    hi := ('0' & alu_a(7 downto 4)) + ('0' & b(7 downto 4)) + ("0000" & hc);
    co := hi(4);
    if dec = '1' and sub = '0' and hi > 9 then co := '1'; end if;
    sum := hi(3 downto 0) & lo(3 downto 0);
    adj := x"00";
    if dec = '1' then
      if sub = '0' then
        if hc = '1' then adj(3 downto 0) := x"6"; end if;
        if co = '1' then adj(7 downto 4) := x"6"; end if;
      else
        if hc = '0' then adj(3 downto 0) := x"A"; end if;
        if co = '0' then adj(7 downto 4) := x"A"; end if;
      end if;
    end if;
    alu_c <= co;
    alu_v <= (alu_a(7) xnor b(7)) and (alu_a(7) xor sum(7));
    case alu_op is
      when "000" => alu_r <= alu_a or alu_b;
      when "001" => alu_r <= alu_a and alu_b;
      when "010" => alu_r <= alu_a xor alu_b;
      when "101" | "100" => alu_r <= alu_b;
      when others => alu_r <= (sum(7 downto 4) + adj(7 downto 4)) & (sum(3 downto 0) + adj(3 downto 0));
    end case;
  end process;

  -- increment / shift units ---------------------------------------------------------
  -- 1A INC A, 3A DEC A, 88 DEY, C8 INY, CA DEX, E8 INX, INC / DEC memory
  process(all)
    variable d1 : std_logic;
  begin
    inc_a <= dl; sh_a <= dl;
    d1 := not ir(5);                                  -- C6 DEC, E6 INC
    if s = D then
      sh_a <= a;
      if ir(7) = '0' then inc_a <= a; d1 := ir(5);
      elsif ir(1) = '1' then inc_a <= x; d1 := '1';
      elsif ir(5) = '1' then inc_a <= x; d1 := '0';
      else inc_a <= y; d1 := not ir(6); end if;
    end if;
    if d1 = '1' then inc_r <= inc_a - 1; else inc_r <= inc_a + 1; end if;
    if ir(6) = '0' then                               -- ASL ROL
      sh_c <= sh_a(7);
      sh_r <= sh_a(6 downto 0) & (fc and ir(5));
    else                                              -- LSR ROR
      sh_c <= sh_a(0);
      sh_r <= (fc and ir(5)) & sh_a(7 downto 1);
    end if;
  end process;
  process(all)
  begin
    bmask <= (others => '0');
    bmask(to_integer(ir(6 downto 4))) <= '1';
    if is_rmb = '1' then
      if ir(7) = '1' then rmw_r <= dl or bmask; else rmw_r <= dl and not bmask; end if;
    elsif is_tsb = '1' then
      if ir(4) = '0' then rmw_r <= dl or a; else rmw_r <= dl and not a; end if;
    elsif ir(7) = '1' then rmw_r <= inc_r;
    else rmw_r <= sh_r; end if;
  end process;
  process(all)
    variable c : std_logic;
  begin
    case ir(7 downto 6) is
      when "00" => c := fn;
      when "01" => c := fv;
      when "10" => c := fc;
      when others => c := fz;
    end case;
    bcond <= c xnor ir(5);
    if l5 = "00000" then bcond <= '1'; end if;         -- BRA
  end process;

  -- sequencer -------------------------------------------------------------------------
  process(clk)
    variable nzv : u8;
    variable nze : std_logic;
    procedure wait_n(n : integer) is
    begin
      if n = 0 then s <= F; else s <= WT; wcnt <= to_unsigned(n - 1, 4); end if;
    end procedure;
    -- the last read of an ALU / load / compare / bit instruction
    procedure exec is
    begin
      nzv := alu_r; nze := '1';
      if is_bit = '1' or is_tst = '1' then
        nze := '0';
        fn <= alu_b(7); fv <= alu_b(6);
        if alu_r = 0 then fz <= '1'; else fz <= '0'; end if;
      else
        if g1 = '1' then
          if i3 /= "110" then a <= alu_r; end if;
        elsif i3 = "101" then
          if ir(1) = '1' then x <= alu_r; else y <= alu_r; end if;
        end if;
        if alu_op = "011" or alu_op = "111" then
          fc <= alu_c;
          if fd = '0' then fv <= alu_v; end if;
        elsif alu_op = "110" then fc <= alu_c; end if;
      end if;
      s <= F;
      if is_tst = '1' then wait_n(2);
      elsif g1 = '1' and fd = '1' and (i3 = "011" or i3 = "111") then wait_n(1); end if;
    end procedure;
  begin
    if rising_edge(clk) then
      if ce = '1' then
        nze := '0'; nzv := alu_r;
        pend <= (irq(0) or irq(1) or irq(2)) and not fi;
        case s is
          when F =>
            tnow <= ft;
            isirq <= pend;
            vec <= "00";
            if pend = '1' then
              ir <= x"00";
              if irq(2) = '1' then vec <= "10";
              elsif irq(1) = '1' then vec <= "01"; end if;
            else
              ir <= unsigned(din);
              pc <= agu;
              ft <= '0';
            end if;
            s <= D;

          when D =>
            dl <= unsigned(din);
            ea <= zp(KLAUS) & unsigned(din);
            s  <= F;
            if is_tst = '1' then pc <= agu; s <= TA;
            elsif is_blk = '1' then pc <= agu; s <= BO; wcnt <= x"0"; alt <= '0';
              ea(7 downto 0) <= unsigned(din);
            else
              case mode is
                when M_IMM =>
                  pc <= agu;
                  if tcap = '1' then s <= T1; else exec; end if;
                when M_ABS | M_ABSX | M_ABSY => pc <= agu; s <= OH;
                when M_ZP | M_ZPX | M_ZPY | M_INDX | M_INDY | M_IND => pc <= agu; s <= IX;
                when M_IMP =>
                  case ir is
                    when x"00" => if isirq = '0' then pc <= agu; end if; s <= PHH;
                    when x"20" => pc <= agu; s <= OH;
                    when x"40" => s <= PO;
                    when x"60" => s <= RL;
                    when x"44" => s <= JD;
                    when x"80" | x"10" | x"30" | x"50" | x"70" | x"90" | x"B0" | x"D0" | x"F0" =>
                      pc <= agu;
                      if bcond = '1' then s <= BJ; end if;
                    when x"03" | x"13" | x"23" => pc <= agu; s <= SD;
                    when x"43" | x"53" => pc <= agu; s <= MD;
                    when x"08" | x"48" | x"5A" | x"DA" => s <= PU;
                    when x"28" | x"68" | x"7A" | x"FA" => s <= PO0;
                    when x"0A" | x"2A" | x"4A" | x"6A" => a <= sh_r; fc <= sh_c; nzv := sh_r; nze := '1';
                    when x"1A" | x"3A" => a <= inc_r; nzv := inc_r; nze := '1';
                    when x"88" | x"C8" => y <= inc_r; nzv := inc_r; nze := '1';
                    when x"CA" | x"E8" => x <= inc_r; nzv := inc_r; nze := '1';
                    when x"8A" => a <= x; nzv := x; nze := '1';
                    when x"98" => a <= y; nzv := y; nze := '1';
                    when x"AA" => x <= a; nzv := a; nze := '1';
                    when x"A8" => y <= a; nzv := a; nze := '1';
                    when x"9A" => sp <= x;
                    when x"BA" => x <= sp; nzv := sp; nze := '1';
                    when x"62" => a <= x"00";
                    when x"82" => x <= x"00";
                    when x"C2" => y <= x"00";
                    when x"02" => x <= y; y <= x; wait_n(1);
                    when x"22" => x <= a; a <= x; wait_n(1);
                    when x"42" => y <= a; a <= y; wait_n(1);
                    when x"54" => fastr <= '0'; wait_n(1);
                    when x"D4" => fastr <= '1'; wait_n(1);
                    when x"F4" => ft <= '1';
                    when x"18" => fc <= '0';
                    when x"38" => fc <= '1';
                    when x"58" => fi <= '0';
                    when x"78" => fi <= '1';
                    when x"B8" => fv <= '0';
                    when x"D8" => fd <= '0';
                    when x"F8" => fd <= '1';
                    when others => null;
                  end case;
              end case;
            end if;

          when TA =>
            pc <= agu;
            ea <= zp(KLAUS) & unsigned(din);
            if ir(4) = '1' then s <= OH; else s <= IX; end if;
          when OH =>
            ea(15 downto 8) <= unsigned(din);
            if ir = x"20" then s <= JD;             -- pc stays on the last byte
            else pc <= agu; s <= IX; end if;
          when IX =>
            case mode is
              when M_ABS | M_ABSX | M_ABSY => ea <= agu;
              when others => ea(7 downto 0) <= agu(7 downto 0);
            end case;
            s <= M;
            if mode = M_INDX or mode = M_INDY or mode = M_IND then s <= PL; end if;
            if ir = x"4C" then pc <= ea; s <= F; end if;
            if ir = x"6C" or ir = x"7C" then s <= JL; end if;

          when JL => dl <= unsigned(din); ea <= agu; s <= JH;
          when JH => pc <= unsigned(din) & dl; wait_n(1);
          when PL => dl <= unsigned(din); ea(7 downto 0) <= agu(7 downto 0); s <= PH;
          when PH => ea <= unsigned(din) & dl; s <= I2;
          when I2 => ea <= agu; s <= M;

          when M =>
            if is_st = '1' then s <= F;
            elsif is_rmw = '1' then dl <= unsigned(din); s <= RM;
            elsif is_bb = '1' then dl <= unsigned(din); s <= BB;
            elsif tcap = '1' then dl <= unsigned(din); s <= T1;
            else exec; end if;
          when RM =>
            dl <= rmw_r;
            s <= W;
            if is_rmb = '1' then s <= RB;
            elsif is_tsb = '1' then
              fn <= dl(7); fv <= dl(6);
              if rmw_r = 0 then fz <= '1'; else fz <= '0'; end if;
            else
              nzv := rmw_r; nze := '1';
              if ir(7) = '0' then fc <= sh_c; end if;
            end if;
          when RB => s <= W;
          when W  => s <= F;

          when T1 =>
            dl <= alu_r; nzv := alu_r; nze := '1';
            if i3 = "011" then
              fc <= alu_c;
              if fd = '0' then fv <= alu_v; end if;
            end if;
            s <= T2;
          when T2 => s <= TW;
          when TW => s <= F; if fd = '1' and i3 = "011" then wait_n(1); end if;

          when BB => s <= BR;
          when BR =>
            pc <= agu; dl <= unsigned(din);
            -- dl still holds the tested byte
            if ((dl and bmask) /= 0) = (ir(7) = '1') then s <= BJ; else s <= F; end if;
          when BJ =>
            pc <= agu;
            wait_n(1);
            if ir = x"44" then wait_n(1); end if;

          when SD  => s <= STW;
          when STW => s <= F;

          when PU => sp <= sp - 1; s <= F;
          when PO0 => sp <= sp + 1; s <= PO;
          when PO =>
            s <= F;
            case ir is
              when x"40" =>                            -- dummy of RTI's pull, see RTI below
                null;
              when x"28" => null;
              when x"68" => a <= unsigned(din); nzv := unsigned(din); nze := '1';
              when x"7A" => y <= unsigned(din); nzv := unsigned(din); nze := '1';
              when others => x <= unsigned(din); nzv := unsigned(din); nze := '1';
            end case;
            if ir = x"28" or ir = x"40" then
              fn <= din(7); fv <= din(6); fd <= din(3); fi <= din(2); fz <= din(1); fc <= din(0);
              if not KLAUS then ft <= din(5); end if;
            end if;
            if ir = x"40" then sp <= sp + 1; s <= RL; end if;

          when JD  => s <= PHH;
          when PHH => sp <= sp - 1; s <= PHL;
          when PHL =>
            sp <= sp - 1;
            if ir = x"00" then s <= PHP;
            elsif ir = x"20" then pc <= ea; wait_n(1);
            else s <= RJ; end if;                      -- BSR
          when PHP =>
            sp <= sp - 1;
            fi <= '1'; fd <= '0'; ft <= '0';
            s <= VL;
          when VL => dl <= unsigned(din); s <= VH;
          when VH => pc <= unsigned(din) & dl; wait_n(1);

          when RL => dl <= unsigned(din); sp <= sp + 1; s <= RH;
          when RH =>
            pc <= unsigned(din) & dl;
            if ir = x"40" then wait_n(2); else s <= RJ; end if;
          when RJ =>                                     -- RTS, BSR: pc + 1
            pc <= agu;
            if ir = x"44" then s <= BJ; else wait_n(2); end if;

          when MD =>
            if ir = x"43" then
              if dl /= 0 then a <= page; end if;
              wait_n(1);
            else s <= MW; end if;
          when MW =>
            for i in 0 to 7 loop
              if dl(i) = '1' then mpr(i) <= a; end if;
            end loop;
            wait_n(1);

          when BO =>
            pc <= agu;
            wcnt <= wcnt + 1;
            case wcnt(2 downto 0) is
              when "000" => ea(15 downto 8)  <= unsigned(din);
              when "001" => dst(7 downto 0)  <= unsigned(din);
              when "010" => dst(15 downto 8) <= unsigned(din);
              when "011" => len(7 downto 0)  <= unsigned(din);
              when others =>
                len(15 downto 8) <= unsigned(din);
                s <= WT; wcnt <= x"9";
            end case;
          when B0 =>
            dl <= unsigned(din);
            ea <= agu;
            s <= B1;
          when B1 => s <= B2;
          when B2 => s <= B3;
          when B3 => dst <= agu; alt <= not alt; s <= B4;
          when B4 => len <= agu; s <= B5;
          when B5 => if len = 0 then s <= F; else s <= B0; end if;

          when WT =>
            wcnt <= wcnt - 1;
            if wcnt = 0 then
              s <= F;
              if is_blk = '1' then s <= B0; end if;
            end if;
        end case;
        -- the stack pointer is incremented before a pull
        if s = D and (ir = x"40" or ir = x"60") then sp <= sp + 1; end if;

        if nze = '1' then
          fn <= nzv(7);
          if nzv = 0 then fz <= '1'; else fz <= '0'; end if;
        end if;
      end if;
      if reset = '1' then
        s <= VL; vec <= "11"; ir <= x"00"; isirq <= '0'; pend <= '0';
        fi <= '1'; fd <= '0'; ft <= '0'; fn <= '0'; fv <= '0'; fz <= '0'; fc <= '0'; tnow <= '0';
        fastr <= '0'; a <= x"00"; x <= x"00"; y <= x"00"; sp <= x"00"; pc <= x"0000";
        mpr(7) <= x"00";
        if KLAUS then
          for i in 0 to 7 loop mpr(i) <= to_unsigned(i, 8); end loop;
        end if;
      end if;
    end if;
  end process;
end architecture;
