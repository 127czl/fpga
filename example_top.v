`timescale 1ns/1ps

//`include "ddr3_controller.vh"


module example_top 
#(
	//	Display color controls. Keep CFA_PATTERN at 0 as the first test.
	parameter [1:0]  CFA_PATTERN     = 2'd0,
	parameter [7:0]  ISP_R_BLACK_LEVEL = 8'd8,
	parameter [7:0]  ISP_G_BLACK_LEVEL = 8'd8,
	parameter [7:0]  ISP_B_BLACK_LEVEL = 8'd8,
	parameter [9:0]  ISP_R_GAIN_Q8   = 10'd352,
	parameter [9:0]  ISP_G_GAIN_Q8   = 10'd256,
	parameter [9:0]  ISP_B_GAIN_Q8   = 10'd352,
	parameter [9:0]  ISP_SATURATION_Q8 = 10'd416,
	parameter [9:0]  ISP_CONTRAST_Q8  = 10'd320,
	parameter [7:0]  ISP_BLACK_CUTOFF = 8'd8,
	parameter [7:0]  ISP_RED_GREEN_SUPPRESS_Q8 = 8'd48,
	parameter [7:0]  ISP_RED_GREEN_BLUE_MAX = 8'd48,
	parameter [7:0]  ISP_RED_GREEN_RED_MARGIN = 8'd24,
	parameter [7:0]  ISP_SHADOW_LUMA_KNEE = 8'd64,
	parameter        ISP_GAMMA_EN    = 1'b1,
	parameter        ISP_GAMMA_PROFILE = 1'b0,
	parameter        ISP_AUTO_GAIN_ENABLE = 1'b1,
	parameter [9:0]  ISP_AUTO_GAIN_MIN_Q8 = 10'd128,
	parameter [9:0]  ISP_AUTO_GAIN_MAX_Q8 = 10'd384,
	parameter [9:0]  ISP_AUTO_GAIN_STEP_Q8 = 10'd4,
	parameter [7:0]  ISP_AUTO_AVG_TARGET = 8'd136,
	parameter [7:0]  ISP_AUTO_AVG_TOLERANCE = 8'd8
)
(
	////////////////////////////////////////////////////////////////
	//	External Clock & Reset
	//input 			nrst, 			//	Button K2
	input 			clk_24m,			//	24MHz Crystal
	input 			clk_25m,			//	25MHz Crystal 
	
	////////////////////////////////////////////////////////////////
	//	User Keys (released from the unused LVDS LCD interface)
	//	KEY0 = N2 / GPIOL_P_02, KEY1 = M2 / GPIOL_N_02, active low
	input 			key0,
	input 			key1,
	
	
	////////////////////////////////////////////////////////////////
	//	System Clock
	output 			sys_pll_rstn_o, 		
	
	input 			clk_sys,			//	Sys PLL 96MHz 
	input 			clk_pixel,			//	Sys PLL 74.25MHz
	input 			clk_pixel_2x,		//	Sys PLL 148.5MHz
	input 			clk_pixel_10x,		//	Sys PLL 742.5MHz
	
	input 			sys_pll_lock,		//	Sys PLL Lock
	
	////////////////////////////////////////////////////////////////
	//	MIPI-DSI Clock & Reset
	output 			dsi_pll_rstn_o,
	
	input 			dsi_refclk_i,		//	48MHz Reference Clock (for DSI PLL)
	input 			dsi_byteclk_i,		//	DSI Byte Clock (1X)
	input 			dsi_serclk_i,		//	DSI Serial Clock (4X 45)
	input 			dsi_txcclk_i,		//	DSI Serial Clock (4X 135)
	
	input 			dsi_pll_lock,
	
	////////////////////////////////////////////////////////////////
	//	DDR Clock
	output 			ddr_pll_rstn_o, 
	
	input 			tdqss_clk,			
	input 			core_clk,			//	DDR PLL 200MHz
	input 			tac_clk,			
	input 			twd_clk,			
	
	input 			ddr_pll_lock,		//	DDR PLL Lock
	
	////////////////////////////////////////////////////////////////
	//	DDR PLL Phase Shift Interface
	output 	[2:0] 	shift,
	output 	[4:0] 	shift_sel,
	output 			shift_ena,
	
	
	
	////////////////////////////////////////////////////////////////
	//	LVDS Clock
	output 			lvds_pll_rstn_o, 
	
	input 			clk_lvds_1x, 
	input 			clk_lvds_7x, 
	input 			clk_27m, 			//	RGB 1X Clock (16MHz)
	input 			clk_54m, 			//	RGB 2X Clock (32MHz, for export control)
	
	input 			lvds_pll_lock, 
	
	
	
	////////////////////////////////////////////////////////////////
	//	DDR Interface Ports
	output 	[15:0] 	addr,
	output 	[2:0] 	ba,
	output 			we,
	output 			reset,
	output 			ras,
	output 			cas,
	output 			odt,
	output 			cke,
	output 			cs,
	
	//	DQ I/O
	input 	[15:0] 	i_dq_hi,
	input 	[15:0] 	i_dq_lo,
	
	output 	[15:0] 	o_dq_hi,
	output 	[15:0] 	o_dq_lo,
	output 	[15:0] 	o_dq_oe,
	
	//	DM O
	output 	[1:0] 	o_dm_hi,
	output 	[1:0] 	o_dm_lo,
	
	//	DQS I/O
	input 	[1:0] 	i_dqs_hi,
	input 	[1:0] 	i_dqs_lo,
	
//	input 	[1:0] 	i_dqs_n_hi,
//	input 	[1:0] 	i_dqs_n_lo,
	
	output 	[1:0] 	o_dqs_hi,
	output 	[1:0] 	o_dqs_lo,
	
//	output 	[1:0] 	o_dqs_n_hi,
//	output 	[1:0] 	o_dqs_n_lo,
	
	output 	[1:0] 	o_dqs_oe,
	output 	[1:0] 	o_dqs_n_oe,
	
	//	CK
	output 			clk_p_hi, 
	output 			clk_p_lo, 
	output 			clk_n_hi, 
	output 			clk_n_lo, 
	
	
	
	////////////////////////////////////////////////////////////////
	//	MIPI-CSI Ctl / I2C
	output 			csi_ctl0_o,
	output 			csi_ctl0_oe,
	input 			csi_ctl0_i,
	
	output 			csi_ctl1_o,
	output 			csi_ctl1_oe,
	input 			csi_ctl1_i,
	
	output 			csi_scl_o,
	output 			csi_scl_oe,
	input 			csi_scl_i,
	
	output 			csi_sda_o,
	output 			csi_sda_oe,
	input 			csi_sda_i,
	
	//	MIPI-CSI RXC 
	input 			csi_rxc_lp_p_i,
	input 			csi_rxc_lp_n_i,
	output 			csi_rxc_hs_en_o,
	output 			csi_rxc_hs_term_en_o,
	input 			csi_rxc_i,
	
	//	MIPI-CSI RXD0
	output 			csi_rxd0_rst_o,
	output 			csi_rxd0_hs_en_o,
	output 			csi_rxd0_hs_term_en_o,
	
	input 			csi_rxd0_lp_p_i,
	input 			csi_rxd0_lp_n_i,
	input 	[7:0] 	csi_rxd0_hs_i,
	
	//	MIPI-CSI RXD1
	output 			csi_rxd1_rst_o,
	output 			csi_rxd1_hs_en_o,
	output 			csi_rxd1_hs_term_en_o,
	
	input 			csi_rxd1_lp_n_i,
	input 			csi_rxd1_lp_p_i,
	input 	[7:0] 	csi_rxd1_hs_i,
	
	//	MIPI-CSI RXD2
	output 			csi_rxd2_rst_o,
	output 			csi_rxd2_hs_en_o,
	output 			csi_rxd2_hs_term_en_o,
	
	input 			csi_rxd2_lp_p_i,
	input 			csi_rxd2_lp_n_i,
	input 	[7:0] 	csi_rxd2_hs_i,
	
	//	MIPI-CSI RXD3
	output 			csi_rxd3_rst_o,
	output 			csi_rxd3_hs_en_o,
	output 			csi_rxd3_hs_term_en_o,
	
	input 			csi_rxd3_lp_p_i,
	input 			csi_rxd3_lp_n_i,
	input 	[7:0] 	csi_rxd3_hs_i,
	
	//output 			csi_rxd0_fifo_rd_o, 
	//input 			csi_rxd0_fifo_empty_i, 
	//output 			csi_rxd1_fifo_rd_o, 
	//input 			csi_rxd1_fifo_empty_i, 
	//output 			csi_rxd2_fifo_rd_o, 
	//input 			csi_rxd2_fifo_empty_i, 
	//output 			csi_rxd3_fifo_rd_o, 
	//input 			csi_rxd3_fifo_empty_i, 
	
	
	
	////////////////////////////////////////////////////////////////
	//	DSI PWM & Reset Control 
	output 			dsi_pwm_o,			//	MIPI-DSI LCD PWM
	output 			dsi_resetn_o,		//	MIPI-DSI LCD Reset
	
	//	MIPI-DSI TXC / TXD
	output 			dsi_txc_rst_o,
	output 			dsi_txc_lp_p_oe,
	output 			dsi_txc_lp_p_o,
	output 			dsi_txc_lp_n_oe,
	output 			dsi_txc_lp_n_o,
	output 			dsi_txc_hs_oe,
	output 	[7:0] 	dsi_txc_hs_o,
	
	output 			dsi_txd0_rst_o,
	output 			dsi_txd0_hs_oe,
	output 	[7:0] 	dsi_txd0_hs_o,
	output 			dsi_txd0_lp_p_oe,
	output 			dsi_txd0_lp_p_o,
	output 			dsi_txd0_lp_n_oe,
	output 			dsi_txd0_lp_n_o,
	
	output 			dsi_txd1_rst_o,
	output 			dsi_txd1_lp_p_oe,
	output 			dsi_txd1_lp_p_o,
	output 			dsi_txd1_lp_n_oe,
	output 			dsi_txd1_lp_n_o,
	output 			dsi_txd1_hs_oe,
	output 	[7:0] 	dsi_txd1_hs_o,
	
	output 			dsi_txd2_rst_o,
	output 			dsi_txd2_lp_p_oe,
	output 			dsi_txd2_lp_p_o,
	output 			dsi_txd2_lp_n_oe,
	output 			dsi_txd2_lp_n_o,
	output 			dsi_txd2_hs_oe,
	output 	[7:0] 	dsi_txd2_hs_o,
	
	output 			dsi_txd3_rst_o,
	output 			dsi_txd3_lp_p_oe,
	output 			dsi_txd3_lp_p_o,
	output 			dsi_txd3_lp_n_oe,
	output 			dsi_txd3_lp_n_o,
	output 			dsi_txd3_hs_oe,
	output 	[7:0] 	dsi_txd3_hs_o,
	
	input 			dsi_txd0_lp_p_i,
	input 			dsi_txd0_lp_n_i,
	input 			dsi_txd1_lp_p_i,
	input 			dsi_txd1_lp_n_i,
	input 			dsi_txd2_lp_p_i,
	input 			dsi_txd2_lp_n_i,
	input 			dsi_txd3_lp_p_i,
	input 			dsi_txd3_lp_n_i,
	
	
	////////////////////////////////////////////////////////////////
	//	UART Interface
	input 		 	uart_rx_i,			//	Support 460800-8-N-1. 
	output 		 	uart_tx_o, 
	
	
	output 	[5:0] 	led_o,			//	
	
	
	////////////////////////////////////////////////////////////////
	//	CMOS Sensor
	output 			cmos_sclk,
	input 			cmos_sdat_IN,
	output 			cmos_sdat_OUT,
	output 			cmos_sdat_OE,
	
	//	CMOS Interface
	input 			cmos_pclk,
	input 			cmos_vsync,
	input 			cmos_href,
	input 	[7:0] 	cmos_data,
	input 			cmos_ctl1,
	output 			cmos_ctl2,
	output 			cmos_ctl3,
	
	
	////////////////////////////////////////////////////////////////
	//	HDMI Interface
	output 			hdmi_txc_oe,
	output 			hdmi_txd0_oe,
	output 			hdmi_txd1_oe,
	output 			hdmi_txd2_oe,
	
	output 			hdmi_txc_rst_o,
	output 			hdmi_txd0_rst_o,
	output 			hdmi_txd1_rst_o,
	output 			hdmi_txd2_rst_o,
	
	output 	[9:0] 	hdmi_txc_o,
	output 	[9:0] 	hdmi_txd0_o,
	output 	[9:0] 	hdmi_txd1_o,
	output 	[9:0] 	hdmi_txd2_o,
	
	
	////////////////////////////////////////////////////////////////
	//	LVDS Interface
	output 			lvds_txc_oe,
	output 	[6:0] 	lvds_txc_o,
	output 			lvds_txc_rst_o,
	
	output 			lvds_txd0_oe,
	output 	[6:0] 	lvds_txd0_o,
	output 			lvds_txd0_rst_o,
	
	output 			lvds_txd1_oe,
	output 	[6:0] 	lvds_txd1_o,
	output 			lvds_txd1_rst_o,
	
	output 			lvds_txd2_oe,
	output 	[6:0] 	lvds_txd2_o,
	output 			lvds_txd2_rst_o,
	
	output 			lvds_txd3_oe,
	output 	[6:0] 	lvds_txd3_o,
	output 			lvds_txd3_rst_o,
	
	
	////////////////////////////////////////////////////////////////
	//	RGB LCD 5Inch 800x480
	output 			lcd_tp_sda_o,		//	TP SDA
	output 			lcd_tp_sda_oe,
	input 			lcd_tp_sda_i,
	
	output 			lcd_tp_scl_o,		//	TP SCL
	output 			lcd_tp_scl_oe,
	input 			lcd_tp_scl_i,
	
	output 			lcd_tp_int_o,		//	TP INT
	output 			lcd_tp_int_oe,
	input 			lcd_tp_int_i,
	
	output 			lcd_tp_rst_o,		//	TP RST
	
	output 			lcd_pwm_o,			//	Backlight
	output 			lcd_blen_o,
	
	//output 			lcd_pclk_o,			//	PCLK & SCK Mux
	output 			lcd_vs_o,			//	VS & SSN Mux. Fixed to 1. Use DE-Only mode. 
	output 			lcd_hs_o,			//	HS. Fixed to 1. Use DE-Only mode. 
//output 			lcd_de_o,			//	DE. (released to key0)

	output 	[7:0] 	lcd_b7_0_o,			//	B7:B0. 
	output 	[7:0] 	lcd_g7_0_o,			//	G7:G0. Must output 8'hFF when access SPI. 
	output 	[7:0] 	lcd_r7_0_o,			//	R7:R0. 
	
	output 	[7:0] 	lcd_b7_0_oe,		//	B7:B0. 
	output 	[7:0] 	lcd_g7_0_oe,		//	G7:G0. Must output 8'hFF when access SPI. 
	output 	[7:0] 	lcd_r7_0_oe,		//	R7:R0. 

	input 	[7:0] 	lcd_b7_0_i,			//	B7:B0. 
	input 	[7:0] 	lcd_g7_0_i,			//	G7:G0. Must output 8'hFF when access SPI. 
	input 	[7:0] 	lcd_r7_0_i,			//	R7:R0. 
	
	//	SPI Pins
	output 			spi_sck_o, 
	output 			spi_ssn_o 			
);
	
	wire 			csi_rxd0_fifo_rd_o; 
	wire 			csi_rxd0_fifo_empty_i = 0;  
	wire 			csi_rxd1_fifo_rd_o;  
	wire 			csi_rxd1_fifo_empty_i = 0;  
	wire 			csi_rxd2_fifo_rd_o;  
	wire 			csi_rxd2_fifo_empty_i = 0;  
	wire 			csi_rxd3_fifo_rd_o;  
	wire 			csi_rxd3_fifo_empty_i = 0;  
	
	wire 	[1:0] 	i_dqs_n_hi;
	wire 	[1:0] 	i_dqs_n_lo;
	wire 	[1:0] 	o_dqs_n_hi;
	wire 	[1:0] 	o_dqs_n_lo;
	
	
	parameter 	SIM_DATA 	= 0; 
	
	//	Hardware Configuration
	assign clk_p_hi = 1'b0;	//	DDR3 Clock requires 180 degree shifted. 
	assign clk_p_lo = 1'b1;
	assign clk_n_hi = 1'b1;
	assign clk_n_lo = 1'b0; 
	
	//	System Clock Tree Control
	assign sys_pll_rstn_o = 1'b1; 	//	nrst; 	//	Reset whole system when nrst (K2) is pressed. 
	
	assign dsi_pll_rstn_o = sys_pll_lock; 
	assign ddr_pll_rstn_o = sys_pll_lock; 
	assign lvds_pll_rstn_o = sys_pll_lock; 
	
	wire 			w_pll_lock = sys_pll_lock && dsi_pll_lock && ddr_pll_lock && lvds_pll_lock; 
	
	//	Synchronize System Resets. 
	reg 			rstn_sys = 0, rstn_pixel = 0; 
	wire 			rst_sys = ~rstn_sys, rst_pixel = ~rstn_pixel; 
	
	reg 			rstn_dsi_refclk = 0, rstn_dsi_byteclk = 0; 
	wire 			rst_dsi_refclk = ~rstn_dsi_refclk, rst_dsi_byteclk = ~rstn_dsi_byteclk; 
	
	reg 			rstn_lvds_1x = 0; 
	wire 			rst_lvds_1x = ~rstn_lvds_1x; 
	
	reg 			rstn_27m = 0, rstn_54m = 0; 
	wire 			rst_27m = ~rstn_27m, rst_54m = ~rstn_54m; 
	
	//	Clock Gen
	always @(posedge clk_27m or negedge w_pll_lock) begin if(~w_pll_lock) rstn_27m <= 0; else rstn_27m <= 1; end
	always @(posedge clk_54m or negedge w_pll_lock) begin if(~w_pll_lock) rstn_54m <= 0; else rstn_54m <= 1; end
	always @(posedge clk_sys or negedge w_pll_lock) begin if(~w_pll_lock) rstn_sys <= 0; else rstn_sys <= 1; end
	always @(posedge clk_pixel_2x or negedge w_pll_lock) begin if(~w_pll_lock) rstn_pixel <= 0; else rstn_pixel <= 1; end
	always @(posedge dsi_refclk_i or negedge w_pll_lock) begin if(~w_pll_lock) rstn_dsi_refclk <= 0; else rstn_dsi_refclk <= 1; end
	always @(posedge dsi_byteclk_i or negedge w_pll_lock) begin if(~w_pll_lock) rstn_dsi_byteclk <= 0; else rstn_dsi_byteclk <= 1; end
	always @(posedge clk_lvds_1x or negedge w_pll_lock) begin if(~w_pll_lock) rstn_lvds_1x <= 0; else rstn_lvds_1x <= 1; end
	
	
	localparam 	CLOCK_MAIN 	= 96000000; 	//	System clock using 96MHz. 
	
	
	
	
	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	//	Flash Burner Control
	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	
	wire 			w_ustick, w_mstick; 
	
	wire  [7:0] 	w_dev_index_o;  
	wire  [7:0] 	w_dev_cmd_o;  
	wire  [31:0] 	w_dev_wdata_o;  
	wire  		w_dev_wvalid_o;  
	wire  		w_dev_rvalid_o;  
	wire 	[31:0] 	w_dev_rdata_i;  
	
	wire 			w_spi_ssn_o, w_spi_sck_o; 
	wire 	[3:0] 	w_spi_data_o, w_spi_data_oe; 
	wire 	[3:0] 	w_spi_data_i; 
	
	//	Flash Control
	reg 			r_flash_en = 0; 		//	0x00:0x00 Enable Flash
	
	always @(posedge clk_sys) begin
		r_flash_en <= (w_dev_wvalid_o && (w_dev_index_o == 8'h00) && (w_dev_cmd_o == 8'h00)) ? w_dev_wdata_o : r_flash_en; 
	end
	
	
	
	
	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	//	LCD Data Mux
	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	
	wire 	[7:0] 	w_lcd_b_o, w_lcd_g_o, w_lcd_r_o; 
	
	assign lcd_b7_0_o = r_flash_en ? {4'b0, w_spi_data_o[3:2], 2'b0} : w_lcd_b_o; 
	assign lcd_g7_0_o = r_flash_en ? {6'h0, w_spi_data_o[1:0]} : w_lcd_g_o; 
	assign lcd_r7_0_o = r_flash_en ? {8'h00} : w_lcd_r_o; 
	
	assign lcd_b7_0_oe = r_flash_en ? {4'b0, w_spi_data_oe[3:2], 2'b0} : 8'hFF; 
	assign lcd_g7_0_oe = r_flash_en ? {6'h0, w_spi_data_oe[1:0]} : 8'hFF; 
	assign lcd_r7_0_oe = r_flash_en ? {8'h00} : 8'hFF; 
	
	assign spi_sck_o = w_spi_sck_o; 
	assign spi_ssn_o = w_spi_ssn_o; 
	assign w_spi_data_i = {lcd_b7_0_i[3:2], lcd_g7_0_i[1:0]}; 
	
	
	
	
	
	
	
	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	//	DDR3 Controller
	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	wire			w_ddr3_ui_clk = clk_sys;
	wire			w_ddr3_ui_rst = rst_sys;
	wire			w_ddr3_ui_areset = rst_sys;
	wire			w_ddr3_ui_aresetn = rstn_sys;
	

	//	General AXI Interface 
	wire	[3:0] 	w_ddr3_awid;
	wire	[31:0]	w_ddr3_awaddr;
	wire	[7:0]		w_ddr3_awlen;
	wire			w_ddr3_awvalid;
	wire			w_ddr3_awready;
	
	wire 	[3:0]  	w_ddr3_wid;
	wire 	[127:0] 	w_ddr3_wdata;
	wire 	[15:0]	w_ddr3_wstrb;
	wire			w_ddr3_wlast;
	wire			w_ddr3_wvalid;
	wire			w_ddr3_wready;
	
	wire 	[3:0] 	w_ddr3_bid;
	wire 	[1:0] 	w_ddr3_bresp;
	wire			w_ddr3_bvalid;
	wire			w_ddr3_bready;
	
	wire	[3:0] 	w_ddr3_arid;
	wire	[31:0]	w_ddr3_araddr;
	wire	[7:0]		w_ddr3_arlen;
	wire			w_ddr3_arvalid;
	wire			w_ddr3_arready;
	
	wire 	[3:0] 	w_ddr3_rid;
	wire 	[127:0] 	w_ddr3_rdata;
	wire			w_ddr3_rlast;
	wire			w_ddr3_rvalid;
	wire			w_ddr3_rready;
	wire 	[1:0] 	w_ddr3_rresp;
	
	
	//	AXI Interface Request
	wire 	[3:0] 	w_ddr3_aid;
	wire 	[31:0] 	w_ddr3_aaddr;
	wire 	[7:0]  	w_ddr3_alen;
	wire 	[2:0]  	w_ddr3_asize;
	wire 	[1:0]  	w_ddr3_aburst;
	wire 	[1:0]  	w_ddr3_alock;
	wire			w_ddr3_avalid;
	wire			w_ddr3_aready;
	wire			w_ddr3_atype;
	
	wire 			w_ddr3_cal_done, w_ddr3_cal_pass; 
	
	//	Do not issue DDR read / write when ~cal_done. 
	reg 			r_ddr_unlock = 0; 
	always @(posedge w_ddr3_ui_clk or negedge w_ddr3_ui_aresetn) begin
		if(~w_ddr3_ui_aresetn)
			r_ddr_unlock <= 0; 
		else
			r_ddr_unlock <= w_ddr3_cal_done; 
	end
	
	DdrCtrl ddr3_ctl_axi (	
		.core_clk		(core_clk),
		.tac_clk		(tac_clk),
		.twd_clk		(twd_clk),	
		.tdqss_clk		(tdqss_clk),
		
		.reset		(reset),
		.cs			(cs),
		.ras			(ras),
		.cas			(cas),
		.we			(we),
		.cke			(cke),    
		.addr			(addr),
		.ba			(ba),
		.odt			(odt),
		
		.o_dm_hi		(o_dm_hi),
		.o_dm_lo		(o_dm_lo),
		
		.i_dq_hi		(i_dq_hi),
		.i_dq_lo		(i_dq_lo),
		.o_dq_hi		(o_dq_hi),
		.o_dq_lo		(o_dq_lo),
		.o_dq_oe		(o_dq_oe),
		
		.i_dqs_hi		(i_dqs_hi),
		.i_dqs_lo		(i_dqs_lo),
		.i_dqs_n_hi		(i_dqs_n_hi),
		.i_dqs_n_lo		(i_dqs_n_lo),
		.o_dqs_hi		(o_dqs_hi),
		.o_dqs_lo		(o_dqs_lo),
		.o_dqs_n_hi		(o_dqs_n_hi),
		.o_dqs_n_lo		(o_dqs_n_lo),
		.o_dqs_oe		(o_dqs_oe),
		.o_dqs_n_oe		(),				//	o_dqs_n_oe),
		
		.clk			(w_ddr3_ui_clk),
		.reset_n		(w_ddr3_ui_aresetn),
		
		.axi_avalid		(w_ddr3_avalid),		//	Enable command only when unlocked. 
		.axi_aready		(w_ddr3_aready),
		.axi_aaddr		(w_ddr3_aaddr),
		.axi_aid		(w_ddr3_aid),
		.axi_alen		(w_ddr3_alen),
		.axi_asize		(w_ddr3_asize),
		.axi_aburst		(w_ddr3_aburst),
		.axi_alock		(w_ddr3_alock),
		.axi_atype		(w_ddr3_atype),
		
		.axi_wid		(w_ddr3_wid),
		.axi_wvalid		(w_ddr3_wvalid),
		.axi_wready		(w_ddr3_wready),
		.axi_wdata		(w_ddr3_wdata),
		.axi_wstrb		(w_ddr3_wstrb),
		.axi_wlast		(w_ddr3_wlast),
		
		.axi_bvalid		(w_ddr3_bvalid),
		.axi_bready		(w_ddr3_bready),
		.axi_bid		(w_ddr3_bid),
		.axi_bresp		(w_ddr3_bresp),
		
		.axi_rvalid		(w_ddr3_rvalid),
		.axi_rready		(w_ddr3_rready),
		.axi_rdata		(w_ddr3_rdata),
		.axi_rid		(w_ddr3_rid),
		.axi_rresp		(w_ddr3_rresp),
		.axi_rlast		(w_ddr3_rlast),
		
		.shift		(shift),
		.shift_sel		(),
		.shift_ena		(shift_ena),
		
		.cal_ena		(1'b1),
		.cal_done		(w_ddr3_cal_done),
		.cal_pass		(w_ddr3_cal_pass)
	);
	//	The o_dqs_n_oe may not assert at negative edge. 
	assign o_dqs_n_oe = o_dqs_oe; 
	
	assign w_ddr3_bready = 1'b1; 
	assign shift_sel = 5'b00100; 		//	ddr_tac_clk always use PLLOUT[2]. 
	
	
	AXI4_AWARMux #(.AID_LEN(4), .AADDR_LEN(32)) axi4_awar_mux (
		.aclk_i			(w_ddr3_ui_clk), 
		.arst_i			(w_ddr3_ui_rst), 
		
		.awid_i			(w_ddr3_awid),
		.awaddr_i			(w_ddr3_awaddr),
		.awlen_i			(w_ddr3_awlen),
		.awvalid_i			(w_ddr3_awvalid && r_ddr_unlock),
		.awready_o			(w_ddr3_awready),
		
		.arid_i			(w_ddr3_arid),
		.araddr_i			(w_ddr3_araddr),
		.arlen_i			(w_ddr3_arlen),
		.arvalid_i			(w_ddr3_arvalid && r_ddr_unlock),
		.arready_o			(w_ddr3_arready),
		
		.aid_o			(w_ddr3_aid),
		.aaddr_o			(w_ddr3_aaddr),
		.alen_o			(w_ddr3_alen),
		.atype_o			(w_ddr3_atype),
		.avalid_o			(w_ddr3_avalid),
		.aready_i			(w_ddr3_aready)
	);
	
	assign w_ddr3_asize = 4; 		//	Fixed 128 bits (16 bytes, size = 4)
	assign w_ddr3_aburst = 1; 
	assign w_ddr3_alock = 0; 
	
	// led_o[1:0] are driven from the threshold level in the multi task block
	
	
	
	
	
	
	
	
	
	////////////////////////////////////////////////////////////////
	//	I2C Config (SC130GS)
	
	//  i2c timing controller module of 16Bit
	wire            [ 8:0]          sc2210_i2c_config_index;
	wire            [23:0]          sc2210_i2c_config_data;
	wire            [ 8:0]          sc2210_i2c_config_size;
	wire                            sc2210_i2c_config_done;
	
	i2c_timing_ctrl_reg16_dat8_wronly
	#(
	    .CLK_FREQ           (CLOCK_MAIN),                              //  100 MHz
	    .I2C_FREQ           (50_000    )                               //  10 KHz(<= 400KHz)
	) u_i2c_timing_ctrl_16bit (
	    //  global clock
	    .clk                (clk_sys                 ),                          //  96MHz
	    .rst_n              (rstn_sys                ),                          //  system reset

	    //  i2c interface
	    .i2c_sclk           (csi_scl_o               ),                          //  i2c clock
	    .i2c_sdat_IN        (csi_sda_i               ),
	    .i2c_sdat_OUT       (csi_sda_o               ),
	    .i2c_sdat_OE        (csi_sda_oe              ),

	    //  i2c config data
	    .i2c_config_index   (sc2210_i2c_config_index        ),                          //  i2c config reg index, read 2 reg and write xx reg
	    .i2c_config_data    ({8'h60, sc2210_i2c_config_data}),                     //  i2c config data
	    .i2c_config_size    (sc2210_i2c_config_size         ),                          //  i2c config data counte
	    .i2c_config_done    (sc2210_i2c_config_done         )                          //  i2c config timing complete
	);
	assign csi_scl_oe = 1; 

	//  I2C Configure Data of SC2210
	I2C_SC2210_19201080_4Lanes_Config u_I2C_SC2210_19201080_4Lanes_Config
	(
	    .LUT_INDEX  (sc2210_i2c_config_index   ),
	    .LUT_DATA   (sc2210_i2c_config_data    ),
	    .LUT_SIZE   (sc2210_i2c_config_size    )
	);
		
	
		
	//	CMOS Interface
	//input 			cmos_pclk,
	//input 			cmos_vsync,
	//input 			cmos_href,
	//input 	[7:0] 	cmos_data,
	//input 			cmos_ctl1,
	//output 			cmos_ctl2,
	//output 			cmos_ctl3,

	
	//	Output LED
	reg 	[3:0]		r_cmos_fv_o = 0; 
	reg 	[1:0] 	r_cmos_rx_vsync0_in = 0; 
	wire 	[1:0] 	w_shape_type;
	wire 	[3:0] 	w_circle_count;
	wire 	[3:0] 	w_rect_count;
	wire 			w_icon_vsync, w_icon_href, w_icon_hsync;
	wire 	[7:0] 	w_icon_r, w_icon_g, w_icon_b;
	wire 	[2:0] 	w_icon_class;
	wire 			w_icon_valid;
	wire 			w_gesture_toggle;
	wire 			w_gesture_palm;
	wire 			w_gesture_event_px;
	wire 			w_gesture_palm_px;
	wire 			w_gesture_roi;
	wire 			w_gesture_camera;
	wire 	[11:0]	w_gesture_peak;
	reg 	[1:0] 	r_ddr_mode = 2'd0;
	reg 	[1:0] 	r_vid_mode = 2'd0;
	reg 				r_play_active = 1'b0;
	reg 	[1:0] 	r_ddr_mode_d = 2'd0;
	reg 	[1:0] 	r_vid_mode_d = 2'd0;
	reg 				r_play_active_d = 1'b0;
	reg 	[4:0] 	r_compare_pos_d = 5'd0;
	always @(posedge cmos_pclk) begin
		r_cmos_rx_vsync0_in <= {r_cmos_rx_vsync0_in, cmos_vsync}; 
		r_cmos_fv_o <= r_cmos_fv_o + ((r_cmos_rx_vsync0_in == 2'b01) ? 1 : 0); 
	end
	// led_o[5:2] show the running task (nine tasks), led_o[1:0] show the
	// task-specific status: DDR mode, record/play state, or shape type.
	assign led_o[5:2] = r_task_active + 1'b1;
	assign led_o[1:0] = (r_task_active == 4'd6) ? r_ddr_mode :
	                    (r_task_active == 4'd7) ? {r_play_active, r_vid_mode[0]} :
	                    (r_task_active == 4'd8) ? w_shape_type :
	                                        2'b00;
	
	
	
	
	
	
	
	
	////////////////////////////////////////////////////////////////
	//	System Control. Can be removed for public. 
	
	localparam 	CLK_FREQ 	= 96_000_000; 	//	clk_sys is 96MHz. 
	localparam 	BAUD_RATE 	= 460_800; 		//	Use 460800-8-N-1. 
	
	
	//	SFR I/O Interface
	wire 	[7:0] 	w_sfr_addr_o; 	//	SFR Address (0xFF00 ~ 0xFFFF). 00:Power; 40~5F:Stream0; 60~7F:Stream1. 
	wire 	[7:0] 	w_sfr_wdata_o; 	//	SFR Write Data. 
	wire 			w_sfr_we_o; 		//	SFR WE. 
	reg 	[7:0] 	w_sfr_rdata_i; 	//	Must be valid after sfr_rd_o. 
	wire 			w_sfr_rd_o; 		//	SFR RD. 
	
	
	//	System Control Registers
	reg 			r_dsi_tx_rstn = 0; 	//	DSI TX Reset
	reg 	[7:0] 	r_dsi_pwm = 64; 		//	[6:0]PWM, [7]Pol
	reg 			r_dsi_resetn_o = 0; 	//	DSI Panel Reset
	reg 			r_dsi_data_rstn = 0; 	//	DSI TX Reset
	
	reg 	[3:0] 	r_dsi_lp_p_ovr = 0; 	
	reg 	[3:0] 	r_dsi_lp_n_ovr = 0; 	
	
	
	
	//	AXI-Lite Interface Bridge
	localparam 	CSI_AXILITE_ID 	= 0; 				//	Select DSI_TX when r_axi_sel = DSI_AXILITE_ID. 
	localparam 	DSI_AXILITE_ID 	= 1; 				//	Select DSI_TX when r_axi_sel = DSI_AXILITE_ID. 
	
	reg 	[7:0] 	r_axi_addr = 8'h18; 		//	0xE0 (RW)
	reg 	[31:0] 	r_axi_wdata = 32'h0000000A; 	//	0xE1~0xE4 (RW)
	wire 	[31:0] 	w_axi_rdata; 			//	0xE5~0xE8 (RO)
	reg 	[0:0] 	r_axi_sel = 1; 			//	0xE9[7:2] (RW)
	reg 			r_axi_r1w0 = 0; 			//	0xE9[1] (RW)
	reg 			r_axi_req = 0; 			//	0xE9[0] (WO, Single Cycle)
	reg 			r_axi_req_o = 0; 			//	Delayed of r_axi_req. 
	
	
	//	Buffered AXI Read Data
	reg 	[31:0] 	r_axi_rdata = 0; 		//	Use state machine
	reg 			r_axi_idle = 0; 		//	AXI Idle 
	
	reg 	[3:0] 	rs_axilite = 0; 		//	AXI Access
	wire 	[3:0] 	ws_axilite_idle = 0; 		
	wire 	[3:0] 	ws_axilite_write = 1; 
	wire 	[3:0] 	ws_axilite_read = 2; 
	wire 	[3:0] 	ws_axilite_endread = 3; 
	
	reg 			r_axi_awvalid = 0, r_axi_wvalid = 0, r_axi_arvalid = 0; 
	wire 			w_axi_awready, w_axi_wready, w_axi_arready, w_axi_rvalid; 
	
	
	reg 	[3:0] 	rc_axi_init = 0; 

	always @(posedge clk_sys or posedge rst_sys) begin
		if(rst_sys) begin
			r_dsi_tx_rstn <= 0; 
			r_dsi_pwm <= 64; 
			r_axi_req <= 0; 
			r_dsi_resetn_o <= 0; 
			r_dsi_data_rstn <= 0; 
			
			rs_axilite <= 0; 
			r_axi_awvalid <= 0; 
			r_axi_wvalid <= 0;
			r_axi_arvalid <= 0; 
			
			r_dsi_lp_p_ovr <= 0; 
			r_dsi_lp_n_ovr <= 0; 
			
			rc_axi_init <= 0; 
			r_axi_idle <= 0; 
			
		end else begin
			r_dsi_tx_rstn <= 1; 
			r_dsi_resetn_o <= 1; 
			r_dsi_data_rstn <= 1; 
			
		end
	end
	
	assign dsi_resetn_o = r_dsi_resetn_o; 
	
	assign csi_ctl0_oe = 0; 
	assign csi_ctl1_oe = 0; 
	
	
	PWMLite dsi_pwm (		//	#(.ENABLE_TICK(0), .PWM_BITS(7)) 
		.clk_i			(clk_sys),
		.rst_i			(rst_sys),
		.pwm_i			(r_dsi_pwm[6:0]),
		.pol_i			(r_dsi_pwm[7]), 
		.pwm_o			(dsi_pwm_o)
	);






	////////////////////////////////////////////////////////////////
	//	MIPI CSI RX
	
	//	The CSI RXC shall not be inverted. Data can be inverted with swapped LP data and flipped HS data. 
	localparam 	CSI_RXD_INV 	= 4'b1111; 
	localparam 	CSI_DATA_WIDTH 	= 32; 			
	localparam 	CSI_STRB_WIDTH 	= CSI_DATA_WIDTH / 8; 

	//	Current implementation supports RAW8 only. 
	wire 			w_csi_rx_clk; 
	wire 			w_csi_rx_vsync0, w_csi_rx_hsync0, w_csi_rx_dvalid; 
	wire 	[63:0] 	w_csi_rx_data; 
	wire 	[47:0] 	w_csi_rx_data_rel_raw; 

	// Cross one camera-frame pulse into the pixel-clock domain.
	reg 			r_cam_vs_d = 1'b0;
	reg 			r_cam_frame_toggle = 1'b0;
	always @(posedge w_csi_rx_clk or negedge rstn_sys) begin
		if(~rstn_sys) begin
			r_cam_vs_d <= 1'b0;
			r_cam_frame_toggle <= 1'b0;
		end else begin
			r_cam_vs_d <= w_csi_rx_vsync0;
			if(w_csi_rx_vsync0 && !r_cam_vs_d)
				r_cam_frame_toggle <= ~r_cam_frame_toggle;
		end
	end
	
	//	AXI Interface
	wire 	[31:0] 	w_csi_axi_rdata; 
	wire 			w_csi_axi_awready, w_csi_axi_wready, w_csi_axi_arready, w_csi_axi_rvalid; 
	
	
	
`define PRI_MIPI_IP
	
	
`ifdef PRI_MIPI_IP
	wire 	[7:0] 	w_mipi_d0 = (CSI_RXD_INV[0] ? 8'hFF : 8'h00) ^ csi_rxd0_hs_i; 
	wire 	[7:0] 	w_mipi_d1 = (CSI_RXD_INV[1] ? 8'hFF : 8'h00) ^ csi_rxd1_hs_i; 
	wire 	[7:0] 	w_mipi_d2 = (CSI_RXD_INV[2] ? 8'hFF : 8'h00) ^ csi_rxd2_hs_i; 
	wire 	[7:0] 	w_mipi_d3 = (CSI_RXD_INV[3] ? 8'hFF : 8'h00) ^ csi_rxd3_hs_i; 
	MIPIRx4LaneFre mipi0_rx (
		.sclk_i			(clk_sys), 
		.srst_i			(rst_sys), 
		
		.mipi_rx_byteclk_i	(csi_rxc_i), 
		.mipi_rx_d0_i		({w_mipi_d0[0], w_mipi_d0[1], w_mipi_d0[2], w_mipi_d0[3], w_mipi_d0[4], w_mipi_d0[5], w_mipi_d0[6], w_mipi_d0[7]}), 
		.mipi_rx_d1_i		({w_mipi_d1[0], w_mipi_d1[1], w_mipi_d1[2], w_mipi_d1[3], w_mipi_d1[4], w_mipi_d1[5], w_mipi_d1[6], w_mipi_d1[7]}), 
		.mipi_rx_d2_i		({w_mipi_d2[0], w_mipi_d2[1], w_mipi_d2[2], w_mipi_d2[3], w_mipi_d2[4], w_mipi_d2[5], w_mipi_d2[6], w_mipi_d2[7]}), 
		.mipi_rx_d3_i		({w_mipi_d3[0], w_mipi_d3[1], w_mipi_d3[2], w_mipi_d3[3], w_mipi_d3[4], w_mipi_d3[5], w_mipi_d3[6], w_mipi_d3[7]}), 
		.mipi_rx_clk_lp_p_i	(csi_rxc_lp_p_i), 
		.mipi_rx_clk_lp_n_i	(csi_rxc_lp_n_i), 
		.mipi_rx_d0_lp_p_i	(CSI_RXD_INV[0] ? csi_rxd0_lp_n_i : csi_rxd0_lp_p_i), 
		.mipi_rx_d0_lp_n_i	(CSI_RXD_INV[0] ? csi_rxd0_lp_p_i : csi_rxd0_lp_n_i), 
		.mipi_rx_rst_o		(), 
		.mipi_rx_rst_n_o		(), 
		.mipi_rx_clk_hs_en_o	(csi_rxc_hs_en_o), 
		.mipi_rx_dat_hs_en_o	(csi_rxd0_hs_en_o), 
		.mipi_rx_clk_term_en_o	(csi_rxc_hs_term_en_o), 
		.mipi_rx_dat_term_en_o	(csi_rxd0_hs_term_en_o), 
		
		.CLK				(w_csi_rx_clk), 
		.VSYNC			(w_csi_rx_vsync0), 
		.HSYNC			(w_csi_rx_hsync0), 
		.DE				(w_csi_rx_dvalid), 
		.DAT				(w_csi_rx_data_rel_raw)
	);
	assign w_csi_rx_data = {2{w_csi_rx_data_rel_raw[47:40], w_csi_rx_data_rel_raw[35:28], w_csi_rx_data_rel_raw[23:16], w_csi_rx_data_rel_raw[11:4]}}; 
	assign {csi_rxd3_hs_en_o, csi_rxd2_hs_en_o, csi_rxd1_hs_en_o} = {3{csi_rxd0_hs_en_o}}; 
	assign {csi_rxd3_hs_term_en_o, csi_rxd2_hs_term_en_o, csi_rxd1_hs_term_en_o} = {3{csi_rxd0_hs_term_en_o}}; 
	
	
`else	
	
	//	Reset pixel 16 cycles after ~vsync. 
	reg 			r_reset_pixen_n = 0; 
	reg 	[1:0] 	r_csi_rx_vsync0_i = 0; 
	always @(posedge w_csi_rx_clk or negedge rstn_sys) begin
		if(~rstn_sys) begin
			r_reset_pixen_n <= 0; 
			r_csi_rx_vsync0_i <= 0; 
		end else begin
			r_csi_rx_vsync0_i <= {r_csi_rx_vsync0_i, w_csi_rx_vsync0}; 
			r_reset_pixen_n <= (r_csi_rx_vsync0_i == 2'b10) ? 1'b0 : 1'b1; 
		end
	end
	
	assign w_csi_rx_clk = clk_sys; 
	csi_rx mipi_rx_0(
		.reset_n			(rstn_sys), 
		.clk				(w_csi_rx_clk), 
		.reset_byte_HS_n		(rstn_sys), 
		.clk_byte_HS		(csi_rxc_i), 
		.reset_pixel_n		(r_reset_pixen_n), 	//rstn_sys), 
		.clk_pixel			(w_csi_rx_clk), 
		.Rx_LP_CLK_P		(csi_rxc_lp_p_i), 
		.Rx_LP_CLK_N		(csi_rxc_lp_n_i), 
		
		.Rx_HS_enable_C		(csi_rxc_hs_en_o), 
		.LVDS_termen_C		(csi_rxc_hs_term_en_o), 
		
		//	Lane inversion affects HS & LP data only. 
		.Rx_LP_D_P			({CSI_RXD_INV[3] ? csi_rxd3_lp_n_i : csi_rxd3_lp_p_i, CSI_RXD_INV[2] ? csi_rxd2_lp_n_i : csi_rxd2_lp_p_i, CSI_RXD_INV[1] ? csi_rxd1_lp_n_i : csi_rxd1_lp_p_i, CSI_RXD_INV[0] ? csi_rxd0_lp_n_i : csi_rxd0_lp_p_i}), 
		.Rx_LP_D_N			({CSI_RXD_INV[3] ? csi_rxd3_lp_p_i : csi_rxd3_lp_n_i, CSI_RXD_INV[2] ? csi_rxd2_lp_p_i : csi_rxd2_lp_n_i, CSI_RXD_INV[1] ? csi_rxd1_lp_p_i : csi_rxd1_lp_n_i, CSI_RXD_INV[0] ? csi_rxd0_lp_p_i : csi_rxd0_lp_n_i}), 
		.Rx_HS_D_0			((CSI_RXD_INV[0] ? 8'hFF : 8'h00) ^ csi_rxd0_hs_i), 
		.Rx_HS_D_1			((CSI_RXD_INV[1] ? 8'hFF : 8'h00) ^ csi_rxd1_hs_i), 
		.Rx_HS_D_2			((CSI_RXD_INV[2] ? 8'hFF : 8'h00) ^ csi_rxd2_hs_i), 
		.Rx_HS_D_3			((CSI_RXD_INV[3] ? 8'hFF : 8'h00) ^ csi_rxd3_hs_i), 
		.Rx_HS_D_4			(), 
		.Rx_HS_D_5			(), 
		.Rx_HS_D_6			(), 
		.Rx_HS_D_7			(), 
		
		.Rx_HS_enable_D		({csi_rxd3_hs_en_o, csi_rxd2_hs_en_o, csi_rxd1_hs_en_o, csi_rxd0_hs_en_o}), 
		.LVDS_termen_D		({csi_rxd3_hs_term_en_o, csi_rxd2_hs_term_en_o, csi_rxd1_hs_term_en_o, csi_rxd0_hs_term_en_o}), 
		.fifo_rd_enable		({csi_rxd3_fifo_rd_o, csi_rxd2_fifo_rd_o, csi_rxd1_fifo_rd_o, csi_rxd0_fifo_rd_o}), 
		.fifo_rd_empty		({csi_rxd3_fifo_empty_i, csi_rxd2_fifo_empty_i, csi_rxd1_fifo_empty_i, csi_rxd0_fifo_empty_i}), 
		.DLY_enable_D		(), 
		.DLY_inc_D			(), 
		.u_dly_enable_D		(0), 
		.u_dly_inc_D		(), 
		
		.vsync_vc1			(), 
		.vsync_vc15			(), 
		.vsync_vc12			(), 
		.vsync_vc9			(), 
		.vsync_vc7			(), 
		.vsync_vc14			(), 
		.vsync_vc13			(), 
		.vsync_vc11			(), 
		.vsync_vc10			(), 
		.vsync_vc8			(), 
		.vsync_vc6			(), 
		.vsync_vc4			(), 
		.vsync_vc0			(w_csi_rx_vsync0), 
		.vsync_vc5			(), 
		.vsync_vc3			(), 
		.vsync_vc2			(), 
	
		.irq				(), 
		
		.pixel_data_valid		(w_csi_rx_dvalid), 
		.pixel_data			(w_csi_rx_data), 
		.pixel_per_clk		(), 
		.datatype			(), 
		.shortpkt_data_field	(), 
		.word_count			(), 
		.vcx				(), 
		.vc				(), 
		.hsync_vc3			(), 
		.hsync_vc2			(), 
		.hsync_vc8			(), 
		.hsync_vc12			(), 
		.hsync_vc7			(), 
		.hsync_vc10			(), 
		.hsync_vc1			(), 
		.hsync_vc0			(w_csi_rx_hsync0), 
		.hsync_vc13			(), 
		.hsync_vc4			(), 
		.hsync_vc11			(), 
		.hsync_vc6			(), 
		.hsync_vc9			(), 
		.hsync_vc15			(), 
		.hsync_vc14			(), 
		.hsync_vc5			(), 
		
		.axi_clk			(clk_sys), 
		.axi_reset_n		(rstn_sys), 
		
		.axi_awaddr			(r_axi_addr), 
		.axi_awvalid		((r_axi_sel == CSI_AXILITE_ID) && r_axi_awvalid), 
		.axi_awready		(w_csi_axi_awready), 
	
		.axi_wvalid			((r_axi_sel == CSI_AXILITE_ID) && r_axi_wvalid), 
		.axi_wdata			(r_axi_wdata), 
		.axi_wready			(w_csi_axi_wready), 
	
		.axi_bvalid			(), 
		.axi_bready			(1), 
		
		.axi_araddr			(r_axi_addr), 
		.axi_arvalid		((r_axi_sel == CSI_AXILITE_ID) && r_axi_arvalid), 
		.axi_arready		(w_csi_axi_arready), 
		
		.axi_rready			(1), 
		.axi_rvalid			(w_csi_axi_rvalid), 
		.axi_rdata			(w_csi_axi_rdata)
		
	);
	
	assign csi_rxd0_rst_o = rst_sys; 
	assign csi_rxd1_rst_o = rst_sys; 
	assign csi_rxd2_rst_o = rst_sys; 
	assign csi_rxd3_rst_o = rst_sys; 
`endif
	
	
	
	//	Output LED
	reg 	[5:0]		r_csi_fv_o = 0; 
	reg 	[1:0] 	r_csi_rx_vsync0_in = 0; 
	always @(posedge w_csi_rx_clk) begin
		r_csi_rx_vsync0_in <= {r_csi_rx_vsync0_in, w_csi_rx_vsync0}; 
		r_csi_fv_o <= r_csi_fv_o + ((r_csi_rx_vsync0_in == 2'b01) ? 1 : 0); 
	end
	// led_o[4] is driven from r_task in the multi task block above
	
	
	
	////////////////////////////////////////////////////////////////
	//	MIPI-CSI Crop
	
	wire			XYCrop_frame_vsync; 
	wire			XYCrop_frame_href;
	wire			XYCrop_frame_de;
	wire	[63:0]	XYCrop_frame_Gray;

	//Sensor_Image_XYCrop
	//#(
	//	.IMAGE_HSIZE_SOURCE (1920 / CSI_STRB_WIDTH),
	//	.IMAGE_VSIZE_SOURCE (1080	 ),
	//	.IMAGE_HSIZE_TARGET (1024 / CSI_STRB_WIDTH),
	//	.IMAGE_YSIZE_TARGET (600 	 ),
	//	.PIXEL_DATA_WIDTH	(CSI_DATA_WIDTH) 		//	32		 )
	//)
	//u_Sensor_Image_XYCrop
	//(
	//	//	globel clock
	//	.clk			(w_csi_rx_clk),			//	image pixel clock
	//	.rst_n		(rstn_sys),			//	system reset
	//	
	//	//CMOS Sensor interface
	//	.image_in_vsync (w_csi_rx_vsync0		),			//H : Data Valid; L : Frame Sync(Set it by register)
	//	.image_in_href	(w_csi_rx_hsync0		),			//H : Data vaild, L : Line Sync
	//	.image_in_de	(w_csi_rx_dvalid		), 			//H : Data Enable, L : Line Sync
	//	.image_in_data	({w_csi_rx_data[7:0], w_csi_rx_data[15:8], w_csi_rx_data[23:16], w_csi_rx_data[31:24], w_csi_rx_data[39:32], w_csi_rx_data[47:40], w_csi_rx_data[55:48], w_csi_rx_data[63:56]}),			//8 bits cmos data input
	//	
	//	.image_out_vsync(XYCrop_frame_vsync ),			//H : Data Valid; L : Frame Sync(Set it by register)
	//	.image_out_href (XYCrop_frame_href	),			//H : Data vaild, L : Line Sync
	//	.image_out_de	(XYCrop_frame_de	), 			//H : Data Enable, L : Line Sync
	//	.image_out_data (XYCrop_frame_Gray	)			//8 bits cmos data input	
	//);

	reg			r_XYCrop_frame_vsync = 0; 
	reg			r_XYCrop_frame_href = 0;
	reg			r_XYCrop_frame_de = 0;
	reg	[63:0]	r_XYCrop_frame_Gray = 0;
	
	always @(posedge w_csi_rx_clk) begin
		r_XYCrop_frame_vsync <= XYCrop_frame_vsync; 
		r_XYCrop_frame_href <= XYCrop_frame_href;
		r_XYCrop_frame_de <= XYCrop_frame_de;
		r_XYCrop_frame_Gray <= XYCrop_frame_Gray;
	end
	
	//	Data Write Assignment
	//wire			cmos_frame_vsync = r_XYCrop_frame_vsync;                     //  cmos frame data vsync valid signal
	//wire			cmos_frame_href = r_XYCrop_frame_href && r_XYCrop_frame_de;	 //  cmos frame data href vaild  signal
	//wire	[63:0]	cmos_frame_Gray = r_XYCrop_frame_Gray; 
	wire			cmos_frame_vsync = w_csi_rx_vsync0;                     //  cmos frame data vsync valid signal
	wire			cmos_frame_href = w_csi_rx_hsync0 && w_csi_rx_dvalid;	 //  cmos frame data href vaild  signal
	wire	[63:0]	cmos_frame_Gray = {w_csi_rx_data[7:0], w_csi_rx_data[15:8], w_csi_rx_data[23:16], w_csi_rx_data[31:24], w_csi_rx_data[39:32], w_csi_rx_data[47:40], w_csi_rx_data[55:48], w_csi_rx_data[63:56]}; 













	////////////////////////////////////////////////////////////////
	//	DDR R/W Control
	

	wire                            lcd_de;
	wire                            lcd_hs;      
	wire                            lcd_vs;
	wire 	[11:0]		lcd_xpos;
	wire 	[11:0]		lcd_ypos;
	wire 					  lcd_request; 
	wire            [7:0]           lcd_red, lcd_red2;
	wire            [7:0]           lcd_green, lcd_green2;
	wire            [7:0]           lcd_blue, lcd_blue2;
	wire            [15:0]          lcd_data;


	assign w_ddr3_awid = 0; 
	assign w_ddr3_wid = 0; 
	
	wire 			w_wframe_vsync; 
	wire 	[7:0] 	w_axi_tp; 
	wire 			w_frame_hold;
	wire 			w_ddr_read_ext_en;
	wire 			w_ddr_record_region;
	wire 			w_ddr_read_flush;
	wire 	[6:0] 	w_ddr_read_index;
	wire 			w_ddr_ring_clear;
	wire 	[6:0] 	w_ddr_last_frame_index;
	wire 			w_snapshot_toggle;
	wire 			w_ddr_write_freeze;
	wire 			w_ov_vsync, w_ov_hsync, w_ov_href;
	wire 	[7:0] 	w_ov_r, w_ov_g, w_ov_b;
	wire 			w_delay_vsync, w_delay_hsync, w_delay_href;
	wire 	[7:0] 	w_delay_r, w_delay_g, w_delay_b;
	wire 			w_shape_vsync, w_shape_hsync, w_shape_href;
	wire 	[7:0] 	w_shape_r, w_shape_g, w_shape_b;
	wire 			w_status_vsync, w_status_hsync, w_status_href;
	wire 	[7:0] 	w_status_r, w_status_g, w_status_b;
	wire 	[9:0] 	w_status_number;
	
	axi4_ctrl #(.C_RD_END_ADDR(1920 * 1080), .C_W_WIDTH(CSI_DATA_WIDTH), .C_R_WIDTH(8), .C_ID_LEN(4)) u_axi4_ctrl (

		.axi_clk        (w_ddr3_ui_clk            ),
		.axi_reset      (w_ddr3_ui_rst            ),
		.frame_hold     (w_frame_hold             ),
		.read_ext_en    (w_ddr_read_ext_en        ),
		.read_index     (w_ddr_read_index         ),
		.record_region  (w_ddr_record_region      ),
		.read_flush     (w_ddr_read_flush         ),
		.ring_clear     (w_ddr_ring_clear         ),
		.snapshot_req   (r_snapshot_req           ),
		.snapshot_slot  (r_snapshot_slot          ),
		.write_freeze   (w_ddr_write_freeze        ),
		.last_frame_index(w_ddr_last_frame_index  ),
		.snapshot_toggle(w_snapshot_toggle        ),

		.axi_awaddr     (w_ddr3_awaddr       ),
		.axi_awlen      (w_ddr3_awlen        ),
		.axi_awvalid    (w_ddr3_awvalid      ),
		.axi_awready    (w_ddr3_awready      ),

		.axi_wdata      (w_ddr3_wdata        ),
		.axi_wstrb      (w_ddr3_wstrb        ),
		.axi_wlast      (w_ddr3_wlast        ),
		.axi_wvalid     (w_ddr3_wvalid       ),
		.axi_wready     (w_ddr3_wready       ),

		.axi_bid        (0          ),
		.axi_bresp      (0        ),
		.axi_bvalid     (1       ),

		.axi_arid       (w_ddr3_arid         ),
		.axi_araddr     (w_ddr3_araddr       ),
		.axi_arlen      (w_ddr3_arlen        ),
		.axi_arvalid    (w_ddr3_arvalid      ),
		.axi_arready    (w_ddr3_arready      ),

		.axi_rid        (w_ddr3_rid          ),
		.axi_rdata      (w_ddr3_rdata        ),
		.axi_rresp      (0        ),
		.axi_rlast      (w_ddr3_rlast        ),
		.axi_rvalid     (w_ddr3_rvalid       ),
		.axi_rready     (w_ddr3_rready       ),

		.wframe_pclk    (w_csi_rx_clk          ),
		.wframe_vsync   (cmos_frame_vsync && !w_ddr_write_freeze), //w_wframe_vsync   ),		//	Writter VSync. Flush on rising edge. Connect to EOF. 
		.wframe_data_en (cmos_frame_href && !w_ddr_write_freeze),
		.wframe_data    (cmos_frame_Gray),
		
		.rframe_pclk    (clk_pixel_2x            ),
		.rframe_vsync   (~lcd_vs             ),		//	Reader VSync. Flush on rising edge. Connect to ~EOF. 
		.rframe_data_en (lcd_request             ),
		.rframe_data    (lcd_data           ),
		
		.tp_o 		(w_axi_tp)
	);
	// led_o[3:2] are driven from r_threshold in the multi task block above
	
	
	
	
	////////////////////////////////////////////////////////////////
	//  LCD Timing Driver
	
	lcd_driver u_lcd_driver
	(
	    //  global clock
	    .clk        (clk_pixel_2x   ),
	    .rst_n      (rstn_pixel), 
	    
	    //  lcd interface
	    .lcd_dclk   (               ),
	    .lcd_blank  (               ),
	    .lcd_sync   (               ),
	    .lcd_request(lcd_request    ), 	//	Request data 1 cycle ahead. 
	    .lcd_hs     (lcd_hs         ),
	    .lcd_vs     (lcd_vs         ),
	    .lcd_en     (lcd_de         ),
	    .lcd_rgb    ({lcd_red2,lcd_green2,lcd_blue2, lcd_red,lcd_green,lcd_blue}),
	    .lcd_xpos   (lcd_xpos       ),
	    .lcd_ypos   (lcd_ypos       ),
	    
	    //  user interface
	    .lcd_data   ({{3{lcd_data[15:8]}}, {3{lcd_data[7:0]}}}  )
	);
	
	
	

	wire 			w_rgb_vsync, w_rgb_hsync, w_rgb_href; 
	wire 	[7:0] 	w_rgb_r, w_rgb_g, w_rgb_b; 
	wire 			w_color_vsync, w_color_hsync, w_color_href;
	wire 	[7:0] 	w_color_r, w_color_g, w_color_b;
	
	VIP_RAW8_RGB888 #(.IMG_HDISP(1920), .IMG_VDISP(1080)) bayer2rgb (
		.clk				(clk_pixel_2x),                //cmos video pixel clock
		.rst_n			(rstn_pixel),              //global reset
	    
		.mirror			(CFA_PATTERN),

		    //CMOS YCbCr444 data output
		.per_frame_vsync		(lcd_vs),    //Prepared Image data vsync valid signal. Reset on falling edge. 
		.per_frame_href		(lcd_de),     //Prepared Image data href vaild  signal
		.per_frame_hsync		(lcd_hs),     //Prepared Image data href vaild  signal
		.per_img_RAW		(lcd_green),        //Prepared Image data 8 Bit RAW Data

		.post_frame_vsync		(w_rgb_vsync),   //Processed Image data vsync valid signal
		.post_frame_href		(w_rgb_href),    //Processed Image data href vaild  signal
		.post_frame_hsync		(w_rgb_hsync),    //Processed Image data href vaild  signal
		.post_img_red		(w_rgb_r),       //Prepared Image green data to be processed 
		.post_img_green		(w_rgb_g),     //Prepared Image green data to be processed
		.post_img_blue		(w_rgb_b)       //Prepared Image blue data to be processed
	);

	VIP_RGB888_ColorCorrect #(
		.R_BLACK_LEVEL	(ISP_R_BLACK_LEVEL),
		.G_BLACK_LEVEL	(ISP_G_BLACK_LEVEL),
		.B_BLACK_LEVEL	(ISP_B_BLACK_LEVEL),
		.R_GAIN_Q8		(ISP_R_GAIN_Q8),
		.G_GAIN_Q8		(ISP_G_GAIN_Q8),
		.B_GAIN_Q8		(ISP_B_GAIN_Q8),
		.SATURATION_Q8	(ISP_SATURATION_Q8),
		.CONTRAST_Q8	(ISP_CONTRAST_Q8),
		.BLACK_CUTOFF	(ISP_BLACK_CUTOFF),
		.RED_GREEN_SUPPRESS_Q8	(ISP_RED_GREEN_SUPPRESS_Q8),
		.RED_GREEN_BLUE_MAX	(ISP_RED_GREEN_BLUE_MAX),
		.RED_GREEN_RED_MARGIN	(ISP_RED_GREEN_RED_MARGIN),
		.SHADOW_LUMA_KNEE	(ISP_SHADOW_LUMA_KNEE),
		.ENABLE_GAMMA	(ISP_GAMMA_EN),
		.GAMMA_PROFILE	(ISP_GAMMA_PROFILE),
		.AUTO_GAIN_ENABLE	(ISP_AUTO_GAIN_ENABLE),
		.AUTO_GAIN_MIN_Q8	(ISP_AUTO_GAIN_MIN_Q8),
		.AUTO_GAIN_MAX_Q8	(ISP_AUTO_GAIN_MAX_Q8),
		.AUTO_GAIN_STEP_Q8	(ISP_AUTO_GAIN_STEP_Q8),
		.AUTO_AVG_TARGET	(ISP_AUTO_AVG_TARGET),
		.AUTO_AVG_TOLERANCE	(ISP_AUTO_AVG_TOLERANCE)
	) u_color_correct (
		.clk			(clk_pixel_2x),
		.rst_n			(rstn_pixel),

		.per_frame_vsync(w_rgb_vsync),
		.per_frame_href	(w_rgb_href),
		.per_frame_hsync(w_rgb_hsync),
		.per_img_red	(w_rgb_r),
		.per_img_green	(w_rgb_g),
		.per_img_blue	(w_rgb_b),

		.post_frame_vsync(w_color_vsync),
		.post_frame_href(w_color_href),
		.post_frame_hsync(w_color_hsync),
		.post_img_red	(w_color_r),
		.post_img_green	(w_color_g),
		.post_img_blue	(w_color_b)
	);

	// The Chinese task OSD is the only text overlay.  Tasks 7 and 8 use
	// the colour stream directly; their numeric status is rendered by the
	// single OSD below, avoiding a second overlay on top of the task text.
	assign w_status_vsync = w_delay_vsync;
	assign w_status_href  = w_delay_href;
	assign w_status_hsync = w_delay_hsync;
	assign w_status_r     = w_delay_r;
	assign w_status_g     = w_delay_g;
	assign w_status_b     = w_delay_b;

	// Original colour delayed by the same three 3x3 stages used by
	// gray -> median -> Gaussian -> Sobel.  This gives a red-edge overlay
	// path that is pixel aligned with w_sob_edge without a second DDR read.
	VIP_RGB888_DelaySobel #(.IMG_HDISP(1920), .IMG_VDISP(1080)) u_delay_rgb
	(
		.clk				(clk_pixel_2x),
		.rst_n				(rstn_pixel),
		.per_frame_vsync	(w_color_vsync),
		.per_frame_href		(w_color_href),
		.per_frame_hsync	(w_color_hsync),
		.per_img_red		(w_color_r),
		.per_img_green		(w_color_g),
		.per_img_blue		(w_color_b),
		.post_frame_vsync	(w_delay_vsync),
		.post_frame_href	(w_delay_href),
		.post_frame_hsync	(w_delay_hsync),
		.post_img_red		(w_delay_r),
		.post_img_green		(w_delay_g),
		.post_img_blue		(w_delay_b)
	);

	////////////////////////////////////////////////////////////////
	//	Multi task chain: gray -> Sobel -> split -> display mix
	////////////////////////////////////////////////////////////////
	wire 			w_gray_vsync, w_gray_hsync, w_gray_href;
	wire 	[7:0] 	w_gray;
	wire 			w_med_vsync, w_med_hsync, w_med_href;
	wire 	[7:0] 	w_med_gray;
	wire 			w_gauss_vsync, w_gauss_hsync, w_gauss_href;
	wire 	[7:0] 	w_gauss_gray;
	wire 			w_sob_vsync, w_sob_hsync, w_sob_href;
	wire 	[7:0] 	w_sob_gray;
	wire 			w_sob_edge;
	wire 	[7:0] 	w_sob_strength;
	wire 	[7:0] 	w_sob_strength_g;
	wire 	[7:0] 	w_sob_grad_lin;
	wire 			w_nms_vsync, w_nms_hsync, w_nms_href;
	wire 	[7:0] 	w_nms_gray, w_nms_mag;
	wire 			w_nms_bin;
	wire 	[7:0] 	w_thr_high, w_thr_low;
	wire 	[12:0] 	w_sob_grad;
	wire 	[11:0] 	w_sob_gx, w_sob_gy;
	wire 	[12:0] 	w_auto_thr;
	wire 	[12:0] 	w_eff_thr;
	wire 			w_split_vsync, w_split_hsync, w_split_href;
	wire 	[7:0] 	w_split_r, w_split_g, w_split_b;
	wire 			w_disp_vsync, w_disp_hsync, w_disp_href;
	wire 	[7:0] 	w_disp_r, w_disp_g, w_disp_b;
	wire 			w_osd_vsync, w_osd_hsync, w_osd_href;
	wire 	[7:0] 	w_osd_r, w_osd_g, w_osd_b;
	wire 			w_key0_short, w_key1_short, w_key0_long, w_key1_long;
	wire 			w_key0_hold, w_key1_hold;

	localparam [3:0] TASK_DDR    = 4'd6;
	localparam [3:0] TASK_VIDEO  = 4'd7;
	localparam [3:0] TASK_SHAPE  = 4'd8;
	localparam [1:0] DDR_LIVE    = 2'd0;
	localparam [1:0] DDR_FREEZE  = 2'd1;
	localparam [1:0] DDR_COMPARE = 2'd2;
	localparam [1:0] VID_IDLE    = 2'd0;
	localparam [1:0] VID_RECORD  = 2'd1;
	localparam [1:0] VID_PLAYBACK= 2'd2;
	localparam [4:0] MAX_SNAPSHOTS = 5'd16;
	localparam [7:0] MAX_RECORD_FRAMES = 8'd104;

	reg 	[3:0] 		r_task      = 4'd0;
	reg 	[3:0] 		r_task_active = 4'd0;
	reg 	[3:0] 		r_task_d    = 4'd0;
	reg 	[1:0] 		r_task_blank = 2'd0;
	reg signed [12:0] 	r_thr_off   = 13'sd0;
	reg 	[1:0] 		r_roi_level = 2'd0;
	reg 				r_icon_enabled = 1'b1;
	reg 				r_gesture_enabled = 1'b1;
	reg 	[4:0] 		r_snap_count = 5'd0;
	reg 	[6:0] 		r_snap_index [0:15];
	reg 	[2:0] 		r_snap_icon_class [0:15];
	reg 				r_snap_icon_valid [0:15];
	reg 				r_snapshot_req = 1'b0;
	reg 				r_snapshot_pending = 1'b0;
	reg 	[6:0] 		r_snapshot_slot = 7'd112;
	reg 	[4:0] 		r_compare_pos = 5'd0;
	reg 	[6:0] 		r_record_start_index = 7'd0;
	reg 	[7:0] 		r_record_count = 8'd0;
	reg 	[6:0] 		r_play_pos = 7'd0;
	reg 				r_record_arm = 1'b0;
	reg 				r_vid_preserve = 1'b0;
	reg 				r_vid_long_guard = 1'b0;
	reg 	[24:0] 		r_vid_lockout = 25'd0;
	reg 	[6:0] 		r_last_index_seen = 7'd0;
	reg 	[4:0] 		r_ddr_clear_timer = 5'd0;
	reg 	[1:0] 		r_ddr_freeze_sync = 2'b00;
	reg 				r_ddr_freeze_sync_d = 1'b0;
	reg 	[6:0] 		r_ddr_index_s1 = 7'd0;
	reg 	[6:0] 		r_ddr_index_s2 = 7'd0;
	reg 				r_lcd_vs_d = 1'b0;
	reg 	[2:0] 		r_snapshot_toggle_sync = 3'b000;
	reg 	[2:0] 		r_cam_toggle_sync = 3'b000;
	reg 				r_gesture_toggle_d = 1'b0;
	reg 	[1:0] 		r_icon_rst_sync = 2'b00;
	reg 	[1:0] 		r_gesture_rst_sync = 2'b00;

	// Conditionally-held blocks use a synchronized reset release. Assertion is
	// immediate; de-assertion reaches the block only after two pixel clocks.
	always @(posedge clk_pixel_2x or negedge rstn_pixel)
	begin
		if (!rstn_pixel)
		begin
			r_icon_rst_sync <= 2'b00;
			r_gesture_rst_sync <= 2'b00;
		end
		else
		begin
			r_icon_rst_sync <= {r_icon_rst_sync[0],
				(r_task_active == TASK_DDR) && r_icon_enabled};
			r_gesture_rst_sync <= {r_gesture_rst_sync[0],
				(r_task_active == TASK_VIDEO) && r_gesture_enabled &&
				(r_vid_mode != VID_PLAYBACK)};
		end
	end
	wire w_icon_rst_n = r_icon_rst_sync[1];
	wire w_gesture_rst_n = r_gesture_rst_sync[1];

	// The DDR controller runs in the 96 MHz system clock; the task logic runs
	// in the 148.5 MHz pixel clock.  These two small synchronisers carry the
	// "freeze complete" flag and the last completed DDR frame index across.
	always @(posedge clk_pixel_2x or negedge rstn_pixel)
	begin
		if(!rstn_pixel)
		begin
			r_task_active       <= 4'd0;
			r_task_d            <= 4'd0;
			r_task_blank        <= 2'd0;
			r_ddr_freeze_sync   <= 2'b00;
			r_ddr_freeze_sync_d <= 1'b0;
			r_ddr_index_s1      <= 7'd0;
			r_ddr_index_s2      <= 7'd0;
			r_lcd_vs_d          <= 1'b0;
			r_snapshot_toggle_sync <= 3'b000;
			r_cam_toggle_sync   <= 3'b000;
		end
		else
		begin
			// Keep all pixel paths on one task for the complete frame.
			// The requested task is latched at the start of vertical blank.
			if(w_lcd_vs_fall)
				r_task_active <= r_task;
			r_task_d            <= r_task_active;
			// Hide exactly the transition frames while DDR pointers and the
			// processing line buffers are re-armed.
			if(w_task_changed || w_ddr_ui_state_changed)
				r_task_blank <= 2'd3;
			else if(w_lcd_vs_fall && (r_task_blank != 2'd0))
				r_task_blank <= r_task_blank - 1'b1;
			r_ddr_freeze_sync   <= {r_ddr_freeze_sync[0], w_ddr_write_freeze};
			r_ddr_freeze_sync_d <= r_ddr_freeze_sync[1];
			r_ddr_index_s1      <= w_ddr_last_frame_index;
			r_ddr_index_s2      <= r_ddr_index_s1;
			r_lcd_vs_d          <= lcd_vs;
			r_snapshot_toggle_sync <= {r_snapshot_toggle_sync[1:0],
			                           w_snapshot_toggle};
			r_cam_toggle_sync <= {r_cam_toggle_sync[1:0],
			                      r_cam_frame_toggle};
		end
	end

	wire w_ddr_freeze_done      = r_ddr_freeze_sync[1];
	wire w_ddr_freeze_done_rise = w_ddr_freeze_done && !r_ddr_freeze_sync_d;
	wire w_lcd_vs_fall          = !lcd_vs && r_lcd_vs_d;
	wire w_task_changed         = (r_task_active != r_task_d);
	wire w_ddr_ui_state_changed =
		((r_task_active == 4'd6) &&
		 ((r_ddr_mode != r_ddr_mode_d) ||
		  (r_compare_pos != r_compare_pos_d))) ||
		((r_task_active == 4'd7) &&
		 ((r_vid_mode != r_vid_mode_d) ||
		  (r_play_active != r_play_active_d)));
	wire [6:0] w_ddr_index_sync = r_ddr_index_s2;
	wire w_snapshot_toggle_edge = r_snapshot_toggle_sync[2] ^
	                              r_snapshot_toggle_sync[1];
	wire w_cam_frame_tick_px = r_cam_toggle_sync[2] ^
	                           r_cam_toggle_sync[1];

	// The controller clears its ring pointers while this request is held.
	// A short timer makes the request survive the 96/148.5 MHz crossing.
	assign w_ddr_ring_clear = (r_ddr_clear_timer != 5'd0);

	always @(posedge clk_pixel_2x or negedge rstn_pixel)
	begin
		if(!rstn_pixel)
		begin
			r_ddr_mode_d    <= 2'd0;
			r_vid_mode_d    <= 2'd0;
			r_play_active_d <= 1'b0;
			r_compare_pos_d <= 5'd0;
		end
		else
		begin
			r_ddr_mode_d    <= r_ddr_mode;
			r_vid_mode_d    <= r_vid_mode;
			r_play_active_d <= r_play_active;
			r_compare_pos_d <= r_compare_pos;
		end
	end

	always @(posedge clk_pixel_2x or negedge rstn_pixel)
	begin
		if(!rstn_pixel)
		begin
			r_task    <= 4'd0;
			r_thr_off <= 13'sd0;
			r_roi_level <= 2'd0;
			r_icon_enabled <= 1'b1;
			r_gesture_enabled <= 1'b1;
			r_ddr_mode <= DDR_LIVE;
			r_vid_mode <= VID_IDLE;
			r_play_active <= 1'b0;
			r_snap_count <= 5'd0;
			r_snapshot_req <= 1'b0;
			r_snapshot_pending <= 1'b0;
			r_snapshot_slot <= 7'd112;
			r_compare_pos <= 5'd0;
			r_record_start_index <= 7'd0;
			r_record_count <= 8'd0;
			r_play_pos <= 7'd0;
			r_record_arm <= 1'b0;
			r_vid_preserve <= 1'b0;
			r_vid_long_guard <= 1'b0;
			r_vid_lockout <= 25'd0;
			r_last_index_seen <= 7'd0;
			r_ddr_clear_timer <= 5'd0;
		end
		else if(w_task_changed)
		begin
			// Do not reset the DDR write/read ring on a task switch.  AXI
			// bursts already accepted by the DDR controller can otherwise
			// finish against newly reset pointers and corrupt several frames.
			r_ddr_clear_timer <= 5'd0;
			r_ddr_mode <= DDR_LIVE;
			r_vid_mode <= VID_IDLE;
			r_play_active <= 1'b0;
			r_icon_enabled <= 1'b1;
			r_gesture_enabled <= 1'b1;
			r_snap_count <= 5'd0;
			r_snapshot_req <= 1'b0;
			r_snapshot_pending <= 1'b0;
			r_snapshot_slot <= 7'd112;
			r_compare_pos <= 5'd0;
			r_record_start_index <= 7'd0;
			r_record_count <= 8'd0;
			r_play_pos <= 7'd0;
			r_record_arm <= 1'b0;
			r_vid_preserve <= 1'b0;
			r_vid_long_guard <= 1'b0;
			r_vid_lockout <= 25'd0;
			r_last_index_seen <= w_ddr_index_sync;
		end
		else
		begin
			if(r_ddr_clear_timer != 5'd0)
				r_ddr_clear_timer <= r_ddr_clear_timer - 1'b1;

			// KEY0 tap: next task. In tasks 7 and 8, KEY0 hold toggles the
			// traffic recogniser or palm gesture trigger. In task 9, it
			// cycles the shape-recognition ROI size.
			if(w_key0_short)
			begin
				if(r_task >= TASK_SHAPE)
					r_task <= 4'd0;
				else
					r_task <= r_task + 1'b1;
			end
			else if(w_key0_long)
			begin
				if(r_task == TASK_SHAPE)
					r_roi_level <= r_roi_level + 1'b1;
				else if(r_task == TASK_DDR) begin
					r_icon_enabled <= ~r_icon_enabled;
				end
				else if(r_task == TASK_VIDEO) begin
					r_gesture_enabled <= ~r_gesture_enabled;
				end
				else if(r_task == 4'd0)
					r_task <= TASK_SHAPE;
				else
					r_task <= r_task - 1'b1;
			end

			// ---------------------------------------------------------
			// Task 7: frame freeze and multi-frame DDR snapshot compare
			// ---------------------------------------------------------
			if(r_task == TASK_DDR)
			begin
				if(w_key1_short)
				begin
					if((r_ddr_mode == DDR_LIVE) && !r_snapshot_pending)
					begin
						if(r_snap_count < MAX_SNAPSHOTS)
						begin
							r_snapshot_slot <= 7'd112 + r_snap_count;
							r_snapshot_req  <= 1'b1;
							r_snapshot_pending <= 1'b1;
							r_ddr_mode      <= DDR_LIVE;
						end
					end
					else if(r_ddr_mode == DDR_FREEZE)
					begin
						r_snapshot_req <= 1'b0;
						r_snapshot_pending <= 1'b0;
						r_ddr_mode     <= DDR_LIVE;
					end
					else if(r_ddr_mode == DDR_COMPARE)
					begin
						if(r_snap_count != 5'd0)
						begin
							if((r_compare_pos + 1'b1) >= r_snap_count)
								r_compare_pos <= 5'd0;
							else
								r_compare_pos <= r_compare_pos + 1'b1;
						end
					end
				end
				else if(w_key1_long)
				begin
					if(r_snapshot_pending)
					begin
						// Wait for the protected snapshot to finish before
						// entering a comparison that may need it.
					end
					else if(r_ddr_mode == DDR_COMPARE)
					begin
						r_ddr_mode <= DDR_LIVE;
						r_compare_pos <= 5'd0;
					end
					else
					begin
						r_ddr_mode <= DDR_COMPARE;
						r_compare_pos <= 5'd0;
						if(r_snap_count == 5'd0)
						begin
							r_snap_index[0] <= w_ddr_index_sync;
							r_snap_icon_class[0] <=
								r_icon_enabled ? w_icon_class : 3'd0;
							r_snap_icon_valid[0] <=
								r_icon_enabled && w_icon_valid;
							r_snap_count <= 5'd1;
						end
					end
				end

			end
			// ---------------------------------------------------------
			// Task 8: video record and loop playback
			// ---------------------------------------------------------
			else if(r_task == TASK_VIDEO)
			begin
				if(r_vid_lockout != 25'd0)
					r_vid_lockout <= r_vid_lockout - 1'b1;

				if(w_key1_long)
				begin
					// Consume this press until KEY1 is released.  Otherwise
					// the release can be seen as a new short press and start
					// recording immediately after entering playback.
					r_vid_long_guard <= 1'b1;
					r_vid_lockout <= 25'd14_849_999;
					r_vid_preserve <= (r_record_count != 8'd0);
					if(r_vid_mode == VID_PLAYBACK)
					begin
						r_vid_mode <= VID_IDLE;
						r_play_active <= 1'b0;
						r_record_arm <= 1'b0;
					end
					else
					begin
						r_vid_mode <= VID_PLAYBACK;
						r_play_active <= 1'b0;
						r_play_pos <= 7'd0;
						r_record_arm <= 1'b0;
					end
				end
				else if((w_key1_short ||
				         (r_gesture_enabled && w_gesture_event_px &&
				          (r_vid_mode != VID_PLAYBACK))) &&
				        !r_vid_long_guard &&
				        (r_vid_lockout == 25'd0))
				begin
					if(r_vid_mode == VID_PLAYBACK)
						r_play_active <= ~r_play_active;
					else if(r_vid_mode == VID_RECORD)
					begin
						r_vid_mode <= VID_IDLE;
						r_play_active <= 1'b0;
						r_record_arm <= 1'b0;
						r_vid_preserve <= 1'b1;
						r_last_index_seen <= w_ddr_index_sync;
					end
					else
					begin
						r_record_start_index <= 7'd0;
						r_record_count <= 8'd0;
						r_play_pos <= 7'd0;
						r_last_index_seen <= w_ddr_index_sync;
						r_record_arm <= 1'b1;
						r_vid_preserve <= 1'b0;
						r_vid_mode <= VID_RECORD;
					end
				end

				if(!w_key1_hold)
					r_vid_long_guard <= 1'b0;
			end
			else
			begin
				if(w_key1_short)
				begin
					if(r_thr_off < 13'sd1536)
						r_thr_off <= r_thr_off + 13'sd8;
				end
				else if(w_key1_long)
				begin
					if(r_thr_off > -13'sd1536)
						r_thr_off <= r_thr_off - 13'sd8;
				end
			end

			// A completed protected snapshot is registered in the compare list.
			if((r_task == TASK_DDR) && r_snapshot_pending &&
			   w_snapshot_toggle_edge)
			begin
				if(r_snap_count < MAX_SNAPSHOTS)
				begin
					r_snap_index[r_snap_count] <= r_snapshot_slot;
					// Capture metadata after the protected frame completes.
					// w_icon_* is then closer to the snapshot image than the
					// value that was present when KEY1 was pressed.
					r_snap_icon_class[r_snap_count] <=
						r_icon_enabled ? w_icon_class : 3'd0;
					r_snap_icon_valid[r_snap_count] <=
						r_icon_enabled && w_icon_valid;
					r_snap_count <= r_snap_count + 1'b1;
				end
				r_snapshot_req <= 1'b0;
				r_snapshot_pending <= 1'b0;
				r_ddr_mode <= DDR_FREEZE;
			end

			// Count recorded frames from the DDR write counter.  Stop
			// automatically before the 128-frame ring can wrap.
			if((r_task == TASK_VIDEO) && (r_vid_mode == VID_RECORD))
			begin
				if(w_ddr_index_sync != r_last_index_seen)
				begin
					r_last_index_seen <= w_ddr_index_sync;
					if(r_record_arm)
					begin
						// The write counter updates when a frame actually
						// completes.  This is the first frame belonging to
						// the recording, not the frame that preceded it.
						r_record_start_index <= w_ddr_index_sync;
						r_record_count <= 8'd1;
						r_record_arm <= 1'b0;
					end
					else if(r_record_count >= (MAX_RECORD_FRAMES - 1'b1))
					begin
						r_record_count <= MAX_RECORD_FRAMES;
						r_vid_mode <= VID_IDLE;
						r_play_active <= 1'b0;
						r_record_arm <= 1'b0;
					end
					else
						r_record_count <= r_record_count + 1'b1;
				end
			end

			// Playback advances once per display frame while playing.
			if((r_task == TASK_VIDEO) && (r_vid_mode == VID_PLAYBACK) &&
			   r_play_active && w_lcd_vs_fall)
			begin
				if((r_play_pos + 1'b1) >= r_record_count)
					r_play_pos <= 7'd0;
				else
					r_play_pos <= r_play_pos + 1'b1;
			end
		end
	end

	// Task 8 palm-area trigger on the live colour stream. It is held in reset
	// outside idle/recording or when KEY0 disables gesture control.
	VIP_HandMotionWave #(
		.IMG_HDISP(1920),
		.IMG_VDISP(1080)
	) u_hand_motion
	(
		.clk				(clk_pixel_2x),
		.rst_n				(w_gesture_rst_n),
		.per_frame_vsync	(w_color_vsync),
		.per_frame_href		(w_color_href),
		.per_frame_hsync	(w_color_hsync),
		.per_img_red		(w_color_r),
		.per_img_green		(w_color_g),
		.per_img_blue		(w_color_b),
		.gesture_toggle		(w_gesture_toggle),
		.motion_active		(w_gesture_palm),
		.roi_motion_active	(w_gesture_roi),
		.camera_motion_active	(w_gesture_camera),
		.motion_peak		(w_gesture_peak)
	);

	always @(posedge clk_pixel_2x or negedge rstn_pixel) begin
		if (!rstn_pixel)
			r_gesture_toggle_d <= 1'b0;
		else if ((r_task_active == TASK_VIDEO) &&
		         r_gesture_enabled &&
		         (r_vid_mode != VID_PLAYBACK))
			r_gesture_toggle_d <= w_gesture_toggle;
		else
			r_gesture_toggle_d <= 1'b0;
	end
	assign w_gesture_event_px = w_gesture_toggle ^ r_gesture_toggle_d;
	assign w_gesture_palm_px = r_gesture_enabled && w_gesture_palm;

	assign w_frame_hold = (r_task_active == TASK_DDR) && (r_ddr_mode != DDR_LIVE);

	assign w_ddr_read_ext_en = ((r_task_active == TASK_DDR) && (r_ddr_mode != DDR_LIVE)) ||
	                           ((r_task_active == TASK_VIDEO) && (r_vid_mode == VID_PLAYBACK));
	assign w_ddr_record_region = (r_task_active == TASK_VIDEO) &&
	                             (r_vid_mode == VID_RECORD);
	assign w_ddr_read_flush = (r_task_blank != 2'd0);

	// The video ring is 0..111.  Snapshot slots 112..127 are reserved, so
	// playback must wrap at 112 rather than at the full 128-frame address
	// space; otherwise it would read snapshot memory in the middle of a video.
	wire [7:0] w_play_sum = {1'b0, r_record_start_index} +
	                        {1'b0, r_play_pos};
	wire [6:0] w_play_index = (w_play_sum >= 8'd112) ?
	                          (w_play_sum - 8'd112) : w_play_sum[6:0];

	assign w_ddr_read_index =
		((r_task_active == TASK_DDR) && (r_ddr_mode == DDR_FREEZE)) ?
			(r_snapshot_req ? r_snapshot_slot :
			 ((r_snap_count == 5'd0) ? 7'd0 : r_snap_index[r_snap_count - 1'b1])) :
		((r_task_active == TASK_DDR) && (r_ddr_mode == DDR_COMPARE)) ?
			((r_snap_count == 5'd0) ? 7'd0 : r_snap_index[r_compare_pos]) :
		((r_task_active == TASK_VIDEO) && (r_vid_mode == VID_PLAYBACK)) ?
			w_play_index :
			7'd0;

	assign w_status_number =
		((r_task_active == TASK_DDR) && (r_ddr_mode == DDR_FREEZE)) ?
			{5'b00000, r_snap_count} :
		((r_task_active == TASK_DDR) && (r_ddr_mode == DDR_COMPARE)) ?
			{5'b00000, (r_compare_pos + 1'b1)} :
		((r_task_active == TASK_VIDEO) && (r_vid_mode == VID_RECORD)) ?
			{2'b00, r_record_count} :
		((r_task_active == TASK_VIDEO) && (r_vid_mode == VID_PLAYBACK)) ?
			{3'b000, (r_play_pos + 1'b1)} :
		((r_task_active == TASK_VIDEO) && (r_vid_mode == VID_IDLE)) ?
			((w_gesture_peak > 12'd999) ? 10'd999 : w_gesture_peak[9:0]) :
			10'd0;

	// Recognition metadata is stored alongside each DDR snapshot, so replay
	// shows the class that belonged to that image rather than the live class.
	reg [4:0] w_snap_view_pos;
	reg [2:0] w_ddr_icon_class;
	reg       w_ddr_icon_valid;
	always @(*) begin
		w_snap_view_pos = 5'd0;
		w_ddr_icon_class = 3'd0;
		w_ddr_icon_valid = 1'b0;
		if(r_ddr_mode == DDR_FREEZE)
			w_snap_view_pos = (r_snap_count == 5'd0) ?
			                  5'd0 : (r_snap_count - 1'b1);
		else if(r_ddr_mode == DDR_COMPARE)
			w_snap_view_pos = r_compare_pos;

		if(r_ddr_mode == DDR_LIVE)
		begin
			w_ddr_icon_class = w_icon_class;
			w_ddr_icon_valid = r_icon_enabled && w_icon_valid;
		end
		else if(r_snap_count != 5'd0)
		begin
			w_ddr_icon_class = r_snap_icon_class[w_snap_view_pos];
			w_ddr_icon_valid = r_snap_icon_valid[w_snap_view_pos];
		end
	end
	wire [2:0] w_osd_icon_class =
		(r_task_active == TASK_DDR) ?
		(r_icon_enabled ? w_ddr_icon_class : 3'd0) : 3'd0;
	wire w_osd_icon_valid =
		(r_task_active == TASK_DDR) && r_icon_enabled && w_ddr_icon_valid;

	// effective threshold = adaptive base + manual offset, clamped to the
	// gradient range
	wire signed [13:0] w_thr_sum = $signed({1'b0, w_auto_thr}) + r_thr_off;
	assign w_eff_thr = (w_thr_sum < 14'sd0) ? 13'd0 :
	                   ((w_thr_sum > 14'sd2040) ? 13'd2040 : w_thr_sum[12:0]);
	key_ctrl u_key_ctrl
	(
		.clk			(clk_pixel_2x	),
		.rst_n			(rstn_pixel		),
		.key0_n			(key0			),
		.key1_n			(key1			),
		.key0_short		(w_key0_short	),
		.key1_short		(w_key1_short	),
		.key0_long		(w_key0_long	),
		.key1_long		(w_key1_long	),
		.key0_hold		(w_key0_hold	),
		.key1_hold		(w_key1_hold	)
	);

	VIP_RGB888_Gray u_rgb2gray
	(
		.clk				(clk_pixel_2x	),
		.rst_n				(rstn_pixel		),
		.per_frame_vsync	(w_color_vsync	),
		.per_frame_href		(w_color_href	),
		.per_frame_hsync	(w_color_hsync	),
		.per_img_red		(w_color_r		),
		.per_img_green		(w_color_g		),
		.per_img_blue		(w_color_b		),
		.post_frame_vsync	(w_gray_vsync	),
		.post_frame_href	(w_gray_href	),
		.post_frame_hsync	(w_gray_hsync	),
		.post_img_gray		(w_gray			)
	);

	VIP_Median3x3 #(.IMG_HDISP(1920), .IMG_VDISP(1080)) u_median
	(
		.clk				(clk_pixel_2x	),
		.rst_n				(rstn_pixel		),
		.per_frame_vsync	(w_gray_vsync	),
		.per_frame_href		(w_gray_href	),
		.per_frame_hsync	(w_gray_hsync	),
		.per_img_gray		(w_gray			),
		.post_frame_vsync	(w_med_vsync	),
		.post_frame_href	(w_med_href		),
		.post_frame_hsync	(w_med_hsync	),
		.post_img_gray		(w_med_gray		)
	);

	// Canny step 1: Gaussian pre-smoothing. The median above satisfies the
	// competition's 3x3 median requirement; the Gaussian is what makes the
	// later non maximum suppression behave, because a median leaves fine grain
	// sensor noise which NMS would otherwise chop into dotted edges.
	VIP_Gauss3x3 #(.IMG_HDISP(1920), .IMG_VDISP(1080)) u_gauss
	(
		.clk				(clk_pixel_2x	),
		.rst_n				(rstn_pixel		),
		.per_frame_vsync	(w_med_vsync	),
		.per_frame_href		(w_med_href		),
		.per_frame_hsync	(w_med_hsync	),
		.per_img_gray		(w_med_gray		),
		.post_frame_vsync	(w_gauss_vsync	),
		.post_frame_href	(w_gauss_href	),
		.post_frame_hsync	(w_gauss_hsync	),
		.post_img_gray		(w_gauss_gray	)
	);

	VIP_Sobel3x3 #(.IMG_HDISP(1920), .IMG_VDISP(1080)) u_sobel
	(
		.clk				(clk_pixel_2x	),
		.rst_n				(rstn_pixel		),
		.cfg_threshold		(w_eff_thr		),
		.per_frame_vsync	(w_gauss_vsync	),
		.per_frame_href		(w_gauss_href	),
		.per_frame_hsync	(w_gauss_hsync	),
		.per_img_gray		(w_gauss_gray	),
		.post_frame_vsync	(w_sob_vsync	),
		.post_frame_href	(w_sob_href		),
		.post_frame_hsync	(w_sob_hsync	),
		.post_img_gray		(w_sob_gray		),
		.post_img_edge		(w_sob_edge		),
		.post_img_strength	(w_sob_strength	),
		.post_img_strength_g(w_sob_strength_g),
		.post_grad_lin		(w_sob_grad_lin	),
		.post_grad_mag		(w_sob_grad		),
		.post_gx			(w_sob_gx		),
		.post_gy			(w_sob_gy		)
	);

	// Task 6: original colour with Sobel edges drawn in red.
	assign w_ov_vsync = w_delay_vsync;
	assign w_ov_href  = w_delay_href;
	assign w_ov_hsync = w_delay_hsync;
	assign w_ov_r     = w_sob_edge ? 8'hFF : w_delay_r;
	assign w_ov_g     = w_sob_edge ? 8'h00 : w_delay_g;
	assign w_ov_b     = w_sob_edge ? 8'h00 : w_delay_b;

	// Canny style finalisation, kept as a SEPARATE task (task 4) so the
	// strength view the user is happy with stays untouched, while the
	// competition's "binary edge via threshold comparison" requirement is
	// still covered by a dedicated display.
	// NMS now runs on grad_mag/8, so its threshold must use the same scale.
	// Clamp to at least one so a very low manual threshold cannot make the
	// binary map accept the zero/gradient floor.
	// Adaptive high threshold with a small noise margin.  Keep this small:
	// the 3x3 support filter now removes short flecks, so an excessive margin
	// would only lose genuine borders.
	wire [8:0] w_thr_high_sum = {1'b0, w_eff_thr[10:3]} + 9'd2;
	assign w_thr_high = (w_eff_thr < 13'd8) ? 8'd1 :
	                    (w_thr_high_sum > 9'd255) ? 8'hFF :
	                    w_thr_high_sum[7:0];
	// Standard Canny low threshold: one half of the high threshold.
	assign w_thr_low  = {1'b0, w_thr_high[7:1]};

	VIP_NmsEdge #(.IMG_HDISP(1920), .IMG_VDISP(1080)) u_nms_edge
	(
		.clk				(clk_pixel_2x	),
		.rst_n				(rstn_pixel		),
		.cfg_thr_high		(w_thr_high		),
		.cfg_thr_low		(w_thr_low		),
		.per_frame_vsync	(w_sob_vsync	),
		.per_frame_href		(w_sob_href		),
		.per_frame_hsync	(w_sob_hsync	),
		.per_img_mag		(w_sob_grad_lin	),
		.per_img_gray		(w_sob_gray		),
		.per_img_gx			(w_sob_gx		),
		.per_img_gy			(w_sob_gy		),
		.post_frame_vsync	(w_nms_vsync	),
		.post_frame_href	(w_nms_href		),
		.post_frame_hsync	(w_nms_hsync	),
		.post_img_gray		(w_nms_gray		),
		.post_img_edge		(w_nms_mag		),
		.post_img_edge_bin	(w_nms_bin		)
	);

	// Task 9 v82: v81 projection detector plus a selectable centre ROI.
	// KEY0 hold cycles 100% -> 80% -> 60% -> 45% while this task is active.
	VIP_CCLShapeOverlay #(
		.IMG_HDISP(1920),
		.IMG_VDISP(1080),
		.ROI_X0(160),
		.ROI_X1(1759),
		.ROI_Y0(40),
		.ROI_Y1(1039),
		.MIN_BOX_AREA(64800),
		.MAX_BOX_AREA(1000000),
		.MIN_SIDE(120),
		.MAX_SIDE(1000),
		.BOUNDARY_GUARD(8)
	) u_shape_overlay
	(
		.clk				(clk_pixel_2x),
		.rst_n				(rstn_pixel && (r_task_active == 4'd8)),
		.per_frame_vsync	(w_sob_vsync),
		.per_frame_href		(w_sob_href),
		.per_frame_hsync	(w_sob_hsync),
		.per_img_edge		(w_sob_edge || (w_sob_strength >= 8'd12)),
		.per_img_grad		(w_sob_strength),
		.per_img_red		(w_sob_strength),
		.per_img_green		(w_sob_strength),
		.per_img_blue		(w_sob_strength),
		.cfg_roi_level		(r_roi_level),
		.post_frame_vsync	(w_shape_vsync),
		.post_frame_href	(w_shape_href),
		.post_frame_hsync	(w_shape_hsync),
		.post_img_red		(w_shape_r),
		.post_img_green		(w_shape_g),
		.post_img_blue		(w_shape_b),
		.shape_type			(w_shape_type),
		.circle_count_out	(w_circle_count),
		.rect_count_out		(w_rect_count)
	);

	// Task 10: six-card warning-sign icon recognition.
	VIP_IconRecognizer #(
		.IMG_HDISP(1920),
		.IMG_VDISP(1080)
	) u_icon_recognizer
	(
		.clk				(clk_pixel_2x),
		.rst_n				(w_icon_rst_n),
		.cfg_diag_mode		(3'd0),
		.per_frame_vsync	(w_color_vsync),
		.per_frame_href		(w_color_href),
		.per_frame_hsync	(w_color_hsync),
		.per_img_red		(w_color_r),
		.per_img_green		(w_color_g),
		.per_img_blue		(w_color_b),
		.post_frame_vsync	(w_icon_vsync),
		.post_frame_href	(w_icon_href),
		.post_frame_hsync	(w_icon_hsync),
		.post_img_red		(w_icon_r),
		.post_img_green		(w_icon_g),
		.post_img_blue		(w_icon_b),
		.icon_class			(w_icon_class),
		.icon_valid			(w_icon_valid)
	);

	// frame adaptive threshold: threshold = gain * mean gradient of the frame
	VIP_AdaptiveThreshold #(.IMG_HDISP(1920), .IMG_VDISP(1080), .GAIN_Q4(8'd48)) u_adaptive_thr
	(
		.clk				(clk_pixel_2x	),
		.rst_n				(rstn_pixel		),
		.per_frame_vsync	(w_sob_vsync	),
		.per_frame_href		(w_sob_href		),
		.per_img_grad		(w_sob_grad		),
		.per_img_valid		(w_sob_href		),
		.adaptive_threshold	(w_auto_thr		)
	);

	VIP_SplitScreen #(.IMG_HDISP(1920)) u_split
	(
		.clk				(clk_pixel_2x	),
		.rst_n				(rstn_pixel		),
		.per_frame_vsync	(w_sob_vsync	),
		.per_frame_href		(w_sob_href		),
		.per_frame_hsync	(w_sob_hsync	),
		.per_img_gray		(w_sob_gray		),
		.per_img_edge		(w_sob_strength	),
		.post_frame_vsync	(w_split_vsync	),
		.post_frame_href	(w_split_href	),
		.post_frame_hsync	(w_split_hsync	),
		.post_img_red		(w_split_r		),
		.post_img_green		(w_split_g		),
		.post_img_blue		(w_split_b		)
	);

	VIP_TaskDisplay #(.IMG_HDISP(1920), .IMG_VDISP(1080)) u_task_display
	(
		.clk				(clk_pixel_2x	),
		.rst_n				(rstn_pixel		),
		.cfg_task			(r_task_active	),
		.c_vsync			(w_delay_vsync	),
		.c_href				(w_delay_href	),
		.c_hsync			(w_delay_hsync	),
		.c_red				(w_delay_r		),
		.c_green			(w_delay_g		),
		.c_blue				(w_delay_b		),
		.p_vsync			(w_sob_vsync	),
		.p_href				(w_sob_href		),
		.p_hsync			(w_sob_hsync	),
		.p_gray				(w_sob_gray		),
		.p_edge				(w_sob_edge		),
		.p_strength			(w_sob_strength	),
		.p_strength_g		(w_sob_strength_g),
		.p_edge_bin			(w_nms_bin		),
		.b_vsync			(w_nms_vsync	),
		.b_href				(w_nms_href		),
		.b_hsync			(w_nms_hsync	),
		.split_red			(w_split_r		),
		.split_green		(w_split_g		),
		.split_blue			(w_split_b		),
		.ov_vsync			(w_ov_vsync		),
		.ov_href			(w_ov_href		),
		.ov_hsync			(w_ov_hsync		),
		.ov_red				(w_ov_r			),
		.ov_green			(w_ov_g			),
		.ov_blue			(w_ov_b			),
		.status_vsync		(w_status_vsync	),
		.status_href		(w_status_href	),
		.status_hsync		(w_status_hsync	),
		.status_red			(w_status_r		),
		.status_green		(w_status_g		),
		.status_blue		(w_status_b		),
		.shape_vsync		(w_shape_vsync	),
		.shape_href			(w_shape_href	),
		.shape_hsync		(w_shape_hsync	),
		.shape_red			(w_shape_r		),
		.shape_green		(w_shape_g		),
		.shape_blue			(w_shape_b		),
		.icon_vsync			(w_icon_vsync	),
		.icon_href			(w_icon_href	),
		.icon_hsync			(w_icon_hsync	),
		.icon_red			(w_icon_r		),
		.icon_green			(w_icon_g		),
		.icon_blue			(w_icon_b		),
		.post_frame_vsync	(w_disp_vsync	),
		.post_frame_href	(w_disp_href	),
		.post_frame_hsync	(w_disp_hsync	),
		.post_img_red		(w_disp_r		),
		.post_img_green		(w_disp_g		),
		.post_img_blue		(w_disp_b		)
	);

	isp_task_osd #(
		.IMG_HDISP(1920),
		.IMG_VDISP(1080),
		.IMG_HTOTAL(2200),
		.IMG_VTOTAL(1125)
	) u_task_osd (
		.clk				(clk_pixel_2x	),
		.rst_n				(rstn_pixel		),
		.per_frame_vsync	(w_disp_vsync	),
		.per_frame_href		(w_disp_href	),
		.per_frame_hsync	(w_disp_hsync	),
		.per_img_red		(w_disp_r		),
		.per_img_green		(w_disp_g		),
		.per_img_blue		(w_disp_b		),
		.pos_x			(lcd_xpos		),
		.pos_y			(lcd_ypos		),
		.cfg_task			(r_task_active	),
		.ddr_mode			(r_ddr_mode		),
		.vid_mode			(r_vid_mode		),
		.play_active		(r_play_active	),
		.shape_type		(w_shape_type	),
		.threshold_offset	(r_thr_off		),
		.status_number		(w_status_number),
		.input_frame_tick	(w_cam_frame_tick_px),
		.circle_count		(w_circle_count),
		.rect_count			(w_rect_count),
		.icon_class			(w_osd_icon_class),
		.icon_valid			(w_osd_icon_valid),
		.icon_enable		(r_icon_enabled),
		.gesture_enable		(r_gesture_enabled),
		.gesture_palm_valid	(w_gesture_palm_px),
		.gesture_roi_valid	(w_gesture_roi),
		.gesture_camera_valid	(w_gesture_camera),
		.post_frame_vsync	(w_osd_vsync	),
		.post_frame_href	(w_osd_href		),
		.post_frame_hsync	(w_osd_hsync	),
		.post_img_red		(w_osd_r		),
		.post_img_green		(w_osd_g		),
		.post_img_blue		(w_osd_b		)
	);

	
	
	
	
	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	//	LVDS Output 
	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	//	HDMI requires specific timing, thus is not compatible with LCD & LVDS & DSI. Must implement standalone. 
	
	assign hdmi_txd0_rst_o = rst_pixel; 
	assign hdmi_txd1_rst_o = rst_pixel; 
	assign hdmi_txd2_rst_o = rst_pixel; 
	assign hdmi_txc_rst_o = rst_pixel; 
	
	assign hdmi_txd0_oe = 1'b1; 
	assign hdmi_txd1_oe = 1'b1; 
	assign hdmi_txd2_oe = 1'b1; 
	assign hdmi_txc_oe = 1'b1; 

	wire [7:0] w_hdmi_r = (r_task_blank != 2'd0) ? 8'd0 : w_osd_r;
	wire [7:0] w_hdmi_g = (r_task_blank != 2'd0) ? 8'd0 : w_osd_g;
	wire [7:0] w_hdmi_b = (r_task_blank != 2'd0) ? 8'd0 : w_osd_b;
	
	//-------------------------------------
	//Digilent HDMI-TX IP Modified by CB elec.
	rgb2dvi #(.ENABLE_OSERDES(0)) u_rgb2dvi 
	(
		.oe_i 		(1), 			//	Always enable output
		.bitflip_i 		(4'b0000), 		//	Reverse clock & data lanes. 
		
		.aRst			(1'b0), 
		.aRst_n		(1'b1), 
		
		.PixelClk		(clk_pixel_2x        ),//pixel clk = 74.25M
		.SerialClk		(     ),//pixel clk *5 = 371.25M
		
		.vid_pVSync		(w_osd_vsync), 
		.vid_pHSync		(w_osd_hsync), 
		.vid_pVDE		(w_osd_href), 
		.vid_pData		({w_hdmi_r, w_hdmi_g, w_hdmi_b}), 
		
		.txc_o		(hdmi_txc_o), 
		.txd0_o		(hdmi_txd0_o), 
		.txd1_o		(hdmi_txd1_o), 
		.txd2_o		(hdmi_txd2_o)
	); 
			
	
	
endmodule


