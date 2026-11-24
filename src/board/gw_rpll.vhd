--
-- gw_rpll.vhd : Gowin rPLL (GW1NR-9C) with the dividers as generics.
--
--   PFD     = FCLKIN / (IDIV_SEL + 1)          3 .. 400 MHz
--   CLKOUT  = PFD * (FBDIV_SEL + 1)            (ODIV_SEL does not divide CLKOUT)
--   VCO     = CLKOUT * ODIV_SEL                400 .. 1200 MHz
--   CLKOUTP = CLKOUT shifted PSDA_SEL * 22.5 degrees
--   CLKOUTD = CLKOUT / SDIV                    (SDIV even, 2 .. 128)
--
-- (same structure as the IP-generated wrappers of pengo_arcade)
--
library ieee;
use ieee.std_logic_1164.all;

entity gw_rpll is
  generic (
    FCLKIN : string  := "27";
    IDIV   : integer := 0;
    FBDIV  : integer := 3;
    ODIV   : integer := 8;
    PSDA   : string  := "0000";
    SDIV   : integer := 2
  );
  port (
    clkin   : in  std_logic;
    clkout  : out std_logic;
    clkoutp : out std_logic;
    clkoutd : out std_logic;
    lock    : out std_logic
  );
end entity;

architecture rtl of gw_rpll is

  component rPLL
    generic (
      FCLKIN          : in string  := "100.0";
      DEVICE          : in string  := "GW1N-4";
      DYN_IDIV_SEL    : in string  := "false";
      IDIV_SEL        : in integer := 0;
      DYN_FBDIV_SEL   : in string  := "false";
      FBDIV_SEL       : in integer := 0;
      DYN_ODIV_SEL    : in string  := "false";
      ODIV_SEL        : in integer := 8;
      PSDA_SEL        : in string  := "0000";
      DYN_DA_EN       : in string  := "false";
      DUTYDA_SEL      : in string  := "1000";
      CLKOUT_FT_DIR   : in bit     := '1';
      CLKOUTP_FT_DIR  : in bit     := '1';
      CLKOUT_DLY_STEP : in integer := 0;
      CLKOUTP_DLY_STEP: in integer := 0;
      CLKOUTD3_SRC    : in string  := "CLKOUT";
      CLKFB_SEL       : in string  := "internal";
      CLKOUT_BYPASS   : in string  := "false";
      CLKOUTP_BYPASS  : in string  := "false";
      CLKOUTD_BYPASS  : in string  := "false";
      CLKOUTD_SRC     : in string  := "CLKOUT";
      DYN_SDIV_SEL    : in integer := 2
    );
    port (
      CLKOUT  : out std_logic;
      LOCK    : out std_logic;
      CLKOUTP : out std_logic;
      CLKOUTD : out std_logic;
      CLKOUTD3: out std_logic;
      RESET   : in  std_logic;
      RESET_P : in  std_logic;
      CLKIN   : in  std_logic;
      CLKFB   : in  std_logic;
      FBDSEL  : in  std_logic_vector(5 downto 0);
      IDSEL   : in  std_logic_vector(5 downto 0);
      ODSEL   : in  std_logic_vector(5 downto 0);
      PSDA    : in  std_logic_vector(3 downto 0);
      DUTYDA  : in  std_logic_vector(3 downto 0);
      FDLY    : in  std_logic_vector(3 downto 0)
    );
  end component;

  signal gnd : std_logic := '0';

begin

  u_pll : rPLL
    generic map (
      FCLKIN           => FCLKIN,
      DEVICE           => "GW1NR-9C",
      DYN_IDIV_SEL     => "false",
      IDIV_SEL         => IDIV,
      DYN_FBDIV_SEL    => "false",
      FBDIV_SEL        => FBDIV,
      DYN_ODIV_SEL     => "false",
      ODIV_SEL         => ODIV,
      PSDA_SEL         => PSDA,
      DYN_DA_EN        => "false",
      DUTYDA_SEL       => "1000",
      CLKOUT_FT_DIR    => '1',
      CLKOUTP_FT_DIR   => '1',
      CLKOUT_DLY_STEP  => 0,
      CLKOUTP_DLY_STEP => 0,
      CLKFB_SEL        => "internal",
      CLKOUT_BYPASS    => "false",
      CLKOUTP_BYPASS   => "false",
      CLKOUTD_BYPASS   => "false",
      DYN_SDIV_SEL     => SDIV,
      CLKOUTD_SRC      => "CLKOUT",
      CLKOUTD3_SRC     => "CLKOUT"
    )
    port map (
      CLKOUT   => clkout,
      LOCK     => lock,
      CLKOUTP  => clkoutp,
      CLKOUTD  => clkoutd,
      CLKOUTD3 => open,
      RESET    => gnd,
      RESET_P  => gnd,
      CLKIN    => clkin,
      CLKFB    => gnd,
      FBDSEL   => (others => '0'),
      IDSEL    => (others => '0'),
      ODSEL    => (others => '0'),
      PSDA     => (others => '0'),
      DUTYDA   => (others => '0'),
      FDLY     => "1111"
    );

end architecture;
