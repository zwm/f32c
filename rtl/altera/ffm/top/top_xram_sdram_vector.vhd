-- (c)EMARD
-- LICENSE=BSD

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

use work.f32c_pack.all;

entity ffm_xram_sdram_vector is
    generic
    (
	-- ISA: either ARCH_MI32 or ARCH_RV32
	C_arch: integer := ARCH_MI32;
	C_debug: boolean := false;
	C_branch_prediction: boolean := true;

	-- Main clock: 50/75/100
	C_clk_freq: integer := 75;

	-- SoC configuration options
	C_bram_size: integer := 16;
	C_bram_const_init: boolean := true;
        C_icache_size: integer := 2;
        C_dcache_size: integer := 2;
        C_acram: boolean := false;
        C_sdram: boolean := true;

        C_vector: boolean := false; -- vector processor unit (wip)
        C_vector_axi: boolean := false; -- vector processor bus type (false: normal f32c)
        C_vector_registers: integer := 8; -- number of internal vector registers min 2, each takes 8K
        C_vector_bram_pass_thru: boolean := true; -- Cyclone-V won't compile with pass_thru=false
        C_vector_vaddr_bits: integer := 10;
        C_vector_vdata_bits: integer := 32;
        C_vector_float_addsub: boolean := true; -- false will not have float addsub (+,-)
        C_vector_float_multiply: boolean := true; -- false will not have float multiply (*)
        C_vector_float_divide: boolean := true; -- false will not have float divide (/) will save much LUTs and DSPs

        C_video_mode: integer := 1; -- 0:640x360, 1:640x480, 2:800x480, 3:800x600, 5:1024x768
        C_hdmi_out: boolean := false;

        C_vgahdmi: boolean := false; -- simple VGA bitmap with compositing
        C_vgahdmi_cache_size: integer := 0; -- KB (0 to disable, 2,4,8,16,32 to enable)
        -- normally this should be actual bits per pixel
        C_vgahdmi_fifo_data_width: integer range 8 to 32 := 8;

	C_sio: integer := 1;
	C_sio_init_baudrate: integer := 115200;
        C_spi: integer := 2;
	C_gpio: integer := 32;
	C_timer: boolean := true;
	C_simple_io: boolean := true
    );
    port
    (
	clock_50a: in std_logic;
	-- RS232
	uart3_txd: out std_logic; -- rs232 txd
	uart3_rxd: in std_logic; -- rs232 rxd
	-- LED
	led: out std_logic;
	-- SD card (SPI)
        sd_m_clk, sd_m_cmd: out std_logic;
        sd_m_d: inout std_logic_vector(3 downto 0); 
        sd_m_cdet: in std_logic;
        -- SDRAM
	dr_clk: out std_logic;
	dr_cke: out std_logic;
	dr_cs_n: out std_logic;
	dr_a: out std_logic_vector(12 downto 0);
	dr_ba: out std_logic_vector(1 downto 0);
	dr_ras_n, dr_cas_n: out std_logic;
	dr_dqm: out std_logic_vector(3 downto 0);
	dr_d: inout std_logic_vector(31 downto 0);
	dr_we_n: out std_logic;
	-- FFM Module IO
	fio: inout std_logic_vector(93 downto 0);
	-- HDMI video out
	vid_d_p, vid_d_n: out std_logic_vector(2 downto 0);
	vid_clk_p, vid_clk_n: out std_logic
    );
end;

architecture Behavioral of ffm_xram_sdram_vector is
  signal clk: std_logic;
  signal clk_pixel, clk_pixel_shift, clk_pixel_shift_n: std_logic;
  signal tmds_rgb: std_logic_vector(2 downto 0);
  signal tmds_clk: std_logic;
  alias dv_clk: std_logic is fio(32);
  alias dv_sda: std_logic is fio(33);
  alias dv_scl: std_logic is fio(34);
  alias dv_int: std_logic is fio(35);
  alias dv_de: std_logic is fio(36);
  alias dv_hsync: std_logic is fio(37);
  alias dv_vsync: std_logic is fio(38);
  alias dv_spdif: std_logic is fio(39);
  alias dv_mclk: std_logic is fio(40);
  alias dv_i2s: std_logic_vector(3 downto 0) is fio(44 downto 41);
  alias dv_sclk: std_logic is fio(45);
  alias dv_lrclk: std_logic is fio(46);
  alias dv_d: std_logic_vector(23 downto 0) is fio(93 downto 70); -- attention, here must be reverse ordered bits
  signal ram_en             : std_logic;
  signal ram_byte_we        : std_logic_vector(3 downto 0) := (others => '0');
  signal ram_address        : std_logic_vector(31 downto 0) := (others => '0');
  signal ram_data_write     : std_logic_vector(31 downto 0) := (others => '0');
  signal ram_data_read      : std_logic_vector(31 downto 0) := (others => '0');
  signal ram_ready          : std_logic;
begin
    -- clock: generic, direct from onboard oscillator
    G_generic_clk:
    if C_clk_freq = 50 generate
      clk <= clock_50a;
      clk_pixel <= clock_50a; -- wrong, should be 25 MHz
      clk_pixel_shift <= clock_50a; -- wrong, should be 250 MHz
    end generate;

    G_75MHz_clk: if C_clk_freq = 75 generate
    clkgen_75: entity work.clk_125p_125n_25_75_100
    port map(
      refclk   => clock_50a,         --   50 MHz input from board
      rst      => '0',               --    0:don't reset
      outclk_0 => clk_pixel_shift,   --  125 MHz phase 0
      outclk_1 => clk_pixel_shift_n, --  125 MHz phase 180
      outclk_2 => clk_pixel,         --   25 MHz pixel clock
      outclk_3 => clk,               --   75 MHz CPU clock
      outclk_4 => open               --  100 MHz unused clock
    );
    end generate;

    -- generic XRAM glue
    glue_xram: entity work.glue_xram
    generic map (
      C_arch => C_arch,
      C_clk_freq => C_clk_freq,
      C_branch_prediction => C_branch_prediction,
      C_bram_size => C_bram_size,
      C_bram_const_init => C_bram_const_init,
      C_icache_size => C_icache_size,
      C_dcache_size => C_dcache_size,
      C_acram => C_acram,
      C_sdram => C_sdram,
      C_sdram_address_width => 24,
      C_sdram_column_bits => 9,
      C_sdram_startup_cycles => 10100,
      C_sdram_cycles_per_refresh => 1524,
      -- vector processor
      --C_vector => C_vector,
      --C_vector_axi => C_vector_axi,
      --C_vector_registers => C_vector_registers,
      --C_vector_vaddr_bits => C_vector_vaddr_bits,
      --C_vector_vdata_bits => C_vector_vdata_bits,
      --C_vector_bram_pass_thru => C_vector_bram_pass_thru,
      --C_vector_float_addsub => C_vector_float_addsub,
      --C_vector_float_multiply => C_vector_float_multiply,
      --C_vector_float_divide => C_vector_float_divide,
      -- vga simple bitmap
      C_vgahdmi => C_vgahdmi,
      C_vgahdmi_mode => C_video_mode,
      C_vgahdmi_cache_size => C_vgahdmi_cache_size,
      C_vgahdmi_fifo_data_width => C_vgahdmi_fifo_data_width,
      C_timer => C_timer,
      C_sio => C_sio,
      C_sio_init_baudrate => C_sio_init_baudrate,
      C_spi => C_spi,
      C_debug => C_debug
    )
    port map (
      clk => clk,
      clk_pixel => clk_pixel,
      clk_pixel_shift => clk_pixel_shift,
      sio_txd(0) => uart3_txd, sio_rxd(0) => uart3_rxd,
      spi_sck(0)  => open,  spi_sck(1)  => sd_m_clk,
      spi_ss(0)   => open,  spi_ss(1)   => sd_m_d(3),
      spi_mosi(0) => open,  spi_mosi(1) => sd_m_cmd,
      spi_miso(0) => open,  spi_miso(1) => sd_m_d(0),
      gpio => open,
      acram_en => ram_en,
      acram_addr(29 downto 2) => ram_address(29 downto 2),
      acram_byte_we(3 downto 0) => ram_byte_we(3 downto 0),
      acram_data_rd(31 downto 0) => ram_data_read(31 downto 0),
      acram_data_wr(31 downto 0) => ram_data_write(31 downto 0),
      acram_ready => ram_ready,
      sdram_addr => dr_a, sdram_data => dr_d(15 downto 0),
      sdram_ba => dr_ba, sdram_dqm => dr_dqm(1 downto 0),
      sdram_ras => dr_ras_n, sdram_cas => dr_cas_n,
      sdram_cke => dr_cke, sdram_clk => dr_clk,
      sdram_we => dr_we_n, sdram_cs => dr_cs_n,
      -- ***** VGA *****
      vga_vsync => dv_vsync,
      vga_hsync => dv_hsync,
      vga_r => dv_d(23 downto 16),
      vga_g => dv_d(15 downto 8),
      vga_b => dv_d(7 downto 0),
      -- ***** HDMI *****
      dvid_red(0)   => tmds_rgb(2), dvid_red(1)   => open,
      dvid_green(0) => tmds_rgb(1), dvid_green(1) => open,
      dvid_blue(0)  => tmds_rgb(0), dvid_blue(1)  => open,
      dvid_clock(0) => tmds_clk,    dvid_clock(1) => open,
      simple_out(0) => led, simple_out(31 downto 1) => open,
      simple_in(1 downto 0) => (others => '0'), simple_in(31 downto 2) => open
    );
    dv_clk <= clk_pixel;

    -- unused RAM upper 16 bits
    dr_dqm(3 downto 2) <= (others => '0');
    dr_d(31 downto 16) <= (others => 'Z');

    G_yes_acram: if C_acram generate
    acram_emulation: entity work.acram_emu
    generic map
    (
      C_addr_width => 12
    )
    port map
    (
      clk => clk,
      acram_a => ram_address(13 downto 2),
      acram_d_wr => ram_data_write,
      acram_d_rd => ram_data_read,
      acram_byte_we => ram_byte_we,
      acram_ready => ram_ready,
      acram_en => ram_en
    );
    end generate;

    -- differential output buffering for HDMI clock and video
    G_hdmi_out: if C_hdmi_out generate
    hdmi_output: entity work.hdmi_out
      port map
      (
        tmds_in_rgb    => tmds_rgb,
        tmds_out_rgb_p => vid_d_p,   -- D2+ red  D1+ green  D0+ blue
        tmds_out_rgb_n => vid_d_n,   -- D2- red  D1- green  D0- blue
        tmds_in_clk    => tmds_clk,
        tmds_out_clk_p => vid_clk_p, -- CLK+ clock
        tmds_out_clk_n => vid_clk_n  -- CLK- clock
      );
    end generate;

end Behavioral;
