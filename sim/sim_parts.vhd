-- simulation stand-ins used by tb_top: gw_rpll, CLKDIV, pce2hdmi (writes the raw
-- frames of raw2png.py), hdmi_module, and an SDHC card in SPI mode (CMD17 / 24).
library ieee; use ieee.std_logic_1164.all;
entity gw_rpll is
  generic (FCLKIN : string := "27"; IDIV : integer := 0; FBDIV : integer := 3; ODIV : integer := 8;
           PSDA : string := "0000"; SDIV : integer := 2);
  port (clkin : in std_logic; clkout, clkoutp, clkoutd, lock : out std_logic);
end entity;
architecture s of gw_rpll is
  signal c, d : std_logic := '0';
begin
  g : if IDIV = 4 generate
    c <= not c after 5.788 ns;
    clkoutp <= transport c after 2.894 ns;
    process begin
      wait until rising_edge(c); d <= '1';
      wait until rising_edge(c); wait until rising_edge(c); d <= '0';
      wait until rising_edge(c);
    end process;
  end generate;
  clkout <= c; clkoutd <= d;
  lock <= '0', '1' after 100 ns;
end architecture;

library ieee; use ieee.std_logic_1164.all;
entity CLKDIV is
  generic (DIV_MODE : string := "2"; GSREN : string := "false");
  port (CLKOUT : out std_logic; HCLKIN, RESETN, CALIB : in std_logic);
end entity;
architecture s of CLKDIV is begin CLKOUT <= '0'; end architecture;

library ieee; use ieee.std_logic_1164.all;
entity hdmi_module is
  port (vga_clk_x5, vga_clk, rst : in std_logic; vga_red_in, vga_green_in, vga_blue_in : in std_logic_vector(7 downto 0);
    vga_hsync_in, vga_vsync_in, vga_disp_ena_in : in std_logic;
    tmds_c0_p_out, tmds_c0_n_out, tmds_c1_p_out, tmds_c1_n_out, tmds_c2_p_out, tmds_c2_n_out, tmds_ck_p_out, tmds_ck_n_out : out std_logic);
end entity;
architecture s of hdmi_module is begin end architecture;

library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity pce2hdmi is
  port (clk, we : in std_logic; waddr : in std_logic_vector(10 downto 0); wdata : in std_logic_vector(8 downto 0);
    div : in std_logic_vector(1 downto 0); frame_t, clk_pix : in std_logic;
    r, g, b : out std_logic_vector(7 downto 0); hs, vs, de, locked : out std_logic);
end entity;
architecture s of pce2hdmi is
begin
  r <= x"00"; g <= x"00"; b <= x"00"; hs <= '0'; vs <= '0'; de <= '0'; locked <= '1';
  process
    type cf is file of character;
    file f : cf;
    variable lastft : std_logic := '0';
    variable opened : boolean := false;
    variable ln, fr : integer := 0;
    variable lb : std_logic := '0';
    variable fn : string(1 to 8) := "f000.raw";
  begin
    loop
      wait until rising_edge(clk);
      if frame_t /= lastft then
        lastft := frame_t;
        if opened then file_close(f); end if;
        fn(2) := character'val(48 + fr / 100); fn(3) := character'val(48 + fr / 10 mod 10); fn(4) := character'val(48 + fr mod 10);
        fr := fr + 1;
        file_open(f, fn, write_mode); opened := true;
        ln := 18; lb := '0';
      end if;
      if we = '1' and opened then
        if waddr(10) /= lb then lb := waddr(10); ln := ln + 1; end if;
        write(f, character'val(ln mod 256)); write(f, character'val(ln / 256 + 2 * to_integer(unsigned(div))));
        write(f, character'val(to_integer(unsigned(waddr(7 downto 0))))); write(f, character'val(to_integer(unsigned(waddr(9 downto 8)))));
        write(f, character'val(to_integer(unsigned(wdata(7 downto 0))))); write(f, character'val(to_integer(unsigned(wdata(8 downto 8)))));
      end if;
    end loop;
  end process;
end architecture;

library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity sd_model is
  generic (IMG : string := "sd.img");
  port (sck, cs, mosi : in std_logic; miso : out std_logic := '1');
end entity;
architecture s of sd_model is
begin
  process
    type cf is file of character;
    type img_t is array (natural range <>) of character;
    type img_p is access img_t;
    file f : cf; variable im : img_p; variable n : integer := 0; variable c : character;
    variable sh, o : std_logic_vector(7 downto 0) := x"FF";
    variable bitn : integer := 0;
    type q_t is array (0 to 1023) of integer;
    variable q : q_t; variable qh, qt : integer := 0;
    variable cmd : std_logic_vector(47 downto 0);
    variable cn, lba : integer := 0;
    variable app : boolean := false; variable idle : integer := 3;
    variable wst, wn : integer := 0;     -- write: 1 waiting for FE, 2 data, 3 CRC
    type wf_t is file of character;
    file wf : wf_t open write_mode is "wr.bin";
    procedure put(b : integer) is begin q(qt mod 1024) := b; qt := qt + 1; end procedure;
    procedure byte_in is
      variable k : integer;
    begin
      if wst = 1 then
        if sh = x"FE" then
          wst := 2; wn := 0;
          for i in 0 to 3 loop write(wf, character'val(lba / 256**i mod 256)); end loop;
        end if;
        return;
      elsif wst = 2 then
        write(wf, character'val(to_integer(unsigned(sh))));
        if lba * 512 + wn < n then im(lba * 512 + wn) := character'val(to_integer(unsigned(sh))); end if;
        wn := wn + 1;
        if wn = 512 then wst := 3; wn := 0; end if;
        return;
      elsif wst = 3 then
        wn := wn + 1;
        if wn = 2 then
          put(16#E5#); for i in 1 to 10 loop put(0); end loop;
          wst := 0; flush(wf);
          report "SD: sector written " & integer'image(lba);
        end if;
        return;
      end if;
      if cn = 0 and sh(7 downto 6) /= "01" then return; end if;
      cmd := cmd(39 downto 0) & sh; cn := cn + 1;
      if cn < 6 then return; end if;
      cn := 0;
      put(255);
      k := to_integer(unsigned(cmd(45 downto 40)));
      lba := to_integer(unsigned(cmd(38 downto 8)));
      case k is
        when 0 => put(1);
        when 8 => put(1); put(0); put(0); put(1); put(16#AA#);
        when 55 => put(1); app := true;
        when 41 => if idle = 0 then put(0); else put(1); idle := idle - 1; end if;
        when 58 => put(0); put(16#C0#); put(255); put(128); put(0);
        when 17 =>
          put(0); for i in 1 to 20 loop put(255); end loop; put(254);
          for i in 0 to 511 loop
            if lba * 512 + i < n then put(character'pos(im(lba * 512 + i))); else put(0); end if;
          end loop;
          put(255); put(255);
        when 24 => put(0); wst := 1;
        when others => put(4); report "SD: command " & integer'image(k);
      end case;
    end procedure;
  begin
    file_open(f, IMG, read_mode);
    while not endfile(f) loop read(f, c); n := n + 1; end loop;
    file_close(f);
    im := new img_t(0 to n - 1);
    file_open(f, IMG, read_mode);
    for i in 0 to n - 1 loop read(f, c); im(i) := c; end loop;
    file_close(f);
    loop
      wait on sck, cs;
      if cs = '1' then
        bitn := 0; cn := 0; qh := 0; qt := 0; o := x"FF"; miso <= '1';
      elsif rising_edge(sck) then
        sh := sh(6 downto 0) & mosi;
        bitn := bitn + 1;
        if bitn = 8 then byte_in; end if;
      elsif falling_edge(sck) then
        if bitn = 8 then
          bitn := 0;
          if qh /= qt then o := std_logic_vector(to_unsigned(q(qh mod 1024), 8)); qh := qh + 1; else o := x"FF"; end if;
        else o := o(6 downto 0) & '1'; end if;
        miso <= o(7) after 10 ns;
      end if;
    end loop;
  end process;
end architecture;
