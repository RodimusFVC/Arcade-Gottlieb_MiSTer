//============================================================================
//
//  Gottlieb System 80 (GG-III) raster arcade hardware for MiSTer
//  Copyright (C) 2026 Rodimus
//
//  Top level carried over from the Rodimus Williams / Exidy cores (Pac-Man core lineage, MikeJ / Sorgelig)
//
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
//
//============================================================================

module emu
(
    `include "sys/emu_ports.vh"
);

wire        CLK_SYS;
wire        CLK_40;                  // video back end (artwork, pause, screen_rotate, arcade_video): PLL C2, locked 2:1 to CLK_SYS
wire        locked;
wire [127:0] status;
wire  [1:0] buttons;
wire        forced_scandoubler;
wire [10:0] ps2_key;
wire [24:0] ps2_mouse;               // [24] toggles per packet, [23:16] dy (up +), [15:8] dx, [5] / [4] dy / dx sign
wire  [8:0] spinner_0;               // [8] toggles per event, [7:0] signed delta
wire        ioctl_download;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire  [7:0] ioctl_din;
wire        ioctl_wr;
wire  [7:0] ioctl_index;
wire [26:0] ioctl_addr27;                     // hps_io's full address: the artwork download can pass 32 MB
wire [24:0] ioctl_addr = ioctl_addr27[24:0];  // every other ioctl user
wire  [7:0] ioctl_dout;
wire [15:0] joystick_0, joystick_1, joystick_2;
wire [15:0] joy_a0;                  // left analog stick, pad 1: Y high byte, X low byte (signed, up / left negative)
wire [15:0] joy_r0, joy_r1;          // right analog sticks, pads 1 and 2
/* verilator lint_off UNUSED */
wire [15:0] joy_a1;                  // left analog stick, pad 2 (unused since CTL-2026-10-24: the board reads one trackball)
/* verilator lint_on UNUSED */
wire [21:0] gamma_bus;
wire        direct_video;
wire        video_rotated;
wire        pause_cpu;
wire        hblank, vblank;

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign FB_FORCE_BLANK = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

wire signed [15:0] audio;
assign AUDIO_L = pause_cpu ? 16'd0 : audio;
assign AUDIO_R = pause_cpu ? 16'd0 : audio;
assign AUDIO_S = 1;   // signed
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS = 0;

///////////////////////////////////////////////////

// MRA index 1 (same layout as the Exidy core):
//   byte 0      game id (informational; the board is configured by bytes 148-152)
//   byte 1      flags: [0] 4-way joystick, [4] vertical, [5] no watchdog (bootleg ROMs that never clear it), [7] vertical is ROT90
//   bytes 4-11  idle level of every bit of the 8 ports (DSW, IN1, IN2, IN3, IN4, P1JOY, P2JOY, P3JOY)
//   bytes 12-19 per port: DIP switch byte that supplies it (bit 7 set = none, use the idle byte)
//   bytes 20-83 input map, one byte per port bit (bit 0 first): control id, 0 = none; a pressed control inverts its bit
//   bytes 84-147 per port bit: which bit of its DIP switch byte supplies it
//   byte 148    main map: 0 RAM, 1 ROM, 2 RAM+ROM, 3 Reactor (rtl/boards/gottlieb_main/gottlieb_main.sv)
//   byte 149    tiles: [0] codes 00-7F from ROM, [1] codes 80-FF from ROM, [2] split at C0 (Screw Loose)
//   byte 150    sound board: 0 none, 1 Rev 1, 2 Rev 1 + SC-01, 3 Rev 1 + SC-01A, 4 Rev 2
//   byte 151    output port: 0 plain, 1 Q*bert knocker, 2 Qubes sprite bank, 3 3 Stooges joystick select
//   byte 152    analog: [0] IN2 = trackball H, [1] IN3 = trackball V, [2] IN3 = MAME IPT_DIAL (Mad Planets, Wiz Warz)
//   bytes 153-154  dial: MAME PORT_SENSITIVITY * 128 / 100, PORT_KEYDELTA
reg [7:0] game_var    = 8'd0;
reg [7:0] game_flags  = 8'h00;
reg [7:0] cfg_map = 8'd0, cfg_tile = 8'd3, cfg_snd = 8'd0, cfg_out = 8'd0, cfg_an = 8'd0;
reg [7:0] cfg_dsens = 8'd0, cfg_dkey = 8'd0;
reg [5:0] in_map[64];
reg [7:0] port_idle[8] = '{8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00};
reg [7:0] port_dip[8]  = '{8'h80,8'h80,8'h80,8'h80,8'h80,8'h80,8'h80,8'h80};
wire [7:0] map_idx8  = ioctl_addr[7:0] - 8'd20;    // bytes 20-83  -> 0-63
wire [7:0] perm_idx8 = ioctl_addr[7:0] - 8'd84;    // bytes 84-147 -> 0-63
wire [5:0] map_idx   = map_idx8[5:0];
wire [5:0] perm_idx  = perm_idx8[5:0];
wire [2:0] idle_idx  = ioctl_addr[2:0] - 3'd4;     // bytes 4-11  -> 0-7
wire [2:0] dip_idx   = ioctl_addr[2:0] - 3'd4;     // bytes 12-19 -> 0-7
reg  [2:0] dip_bit[64];
initial for (int i = 0; i < 64; i++) dip_bit[i] = i % 8;
initial for (int i = 0; i < 64; i++) in_map[i] = 6'd0;

always @(posedge CLK_SYS) begin
    if (ioctl_wr && ioctl_index == 8'd1) begin
        if (ioctl_addr >= 25'd84 && ioctl_addr < 25'd148) dip_bit[perm_idx] <= ioctl_dout[2:0];
        if (ioctl_addr == 25'd0) game_var   <= ioctl_dout;
        if (ioctl_addr == 25'd1) game_flags <= ioctl_dout;
        if (ioctl_addr >= 25'd4  && ioctl_addr < 25'd12) port_idle[idle_idx] <= ioctl_dout;
        if (ioctl_addr >= 25'd12 && ioctl_addr < 25'd20) port_dip[dip_idx]   <= ioctl_dout;
        if (ioctl_addr >= 25'd20 && ioctl_addr < 25'd84) in_map[map_idx] <= ioctl_dout[5:0];
        if (ioctl_addr == 25'd148) cfg_map  <= ioctl_dout;
        if (ioctl_addr == 25'd149) cfg_tile <= ioctl_dout;
        if (ioctl_addr == 25'd150) cfg_snd  <= ioctl_dout;
        if (ioctl_addr == 25'd151) cfg_out  <= ioctl_dout;
        if (ioctl_addr == 25'd152) cfg_an   <= ioctl_dout;
        if (ioctl_addr == 25'd153) cfg_dsens <= ioctl_dout;
        if (ioctl_addr == 25'd154) cfg_dkey  <= ioctl_dout;
    end
end

wire game_vert = game_flags[4];
wire vert_view = game_vert & ~status[12];

wire [1:0] ar = status[9:8];

wire        art_fb;                // artwork framebuffer on HDMI: square canvas pixels
wire        art_wait, art_avail;
wire        ioctl_wait;            // artwork download handshake (CLK_SYS side, see Video)
wire [11:0] art_cw, art_ch;
assign VIDEO_ARX = (!ar) ? (art_fb ? art_cw : vert_view ? 12'd3 : 12'd4) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (art_fb ? art_ch : vert_view ? 12'd4 : 12'd3) : 12'd0;

// Status bit layout kept the same as the Exidy core
`include "build_id.v"
localparam CONF_STR = {
	"GOTTLIEB;;",
	"P1,Video Options;",
	"P1O89,Aspect Ratio,Original,Full screen,[ARC1],[ARC2];",
	"P1OC,Orientation,Vert,Horz;",
	"P1OB,HDMI Flip,Off,On;",
	"P1OM,CRT Flip,Off,On;",
	"P1O[40:37],H Position (CRT),0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P1O[44:41],V Position (CRT),0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P1OGI,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"H1P2,Game Options;",
	"H1P2-,Artwork (MAME layout views);",
	"H1P2O[48:45],View,Off,View 1,View 2,View 3,View 4,View 5,View 6,View 7,View 8,View 9,View 10,View 11,View 12,View 13,View 14,View 15;",
	"H1P2O[49],Backdrop,On,Off;",
	"H1P2O[50],Overlay,On,Off;",
	"H1P2O[51],Bezel,On,Off;",
	"H1P2O[54],Control Panel,On,Off;",
	"H1P2O[52],Side Art,On,Off;",
	"H1P2O[53],Zoom to Screen,Off,On;",
	"H1-;",
	"P3,Pause Options;",
	"P3OJ,Pause when OSD is open,On,Off;",
	"P3OK,Dim video after 10s,On,Off;",
	"-;",
	"OR,Autosave NVRAM,On,Off;",
	"-;",
	"H2O[30:28],Dial Sensitivity,1.0x,0.75x,0.5x,0.25x,0.125x,1.25x,1.5x,2.0x;",
	"H2O[31],Dial Direction,Normal,Reversed;",
	"H2-;",
	"DIP;",
	"-;",
	"R0,Reset;",
	"J1,Btn 1,Btn 2,Btn 3,Btn 4,Coin,Start 1P,Start 2P,Pause,Btn 5,Btn 6;",
	"jn,A,B,X,Y,Select,Start,R,L;",
	"V,v",`BUILD_DATE
};

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(CLK_SYS),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),
	.video_rotated(video_rotated),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({~cfg_an[2], ~art_avail, direct_video}),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_din(ioctl_din),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr27),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	.joystick_0(joystick_0),
	.joystick_l_analog_0(joy_a0),
	.joystick_l_analog_1(joy_a1),
	.joystick_r_analog_0(joy_r0),
	.joystick_r_analog_1(joy_r1),
	.joystick_1(joystick_1),
	.joystick_2(joystick_2),
	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),
	.spinner_0(spinner_0)
);

////////////////////   CLOCKS   ///////////////////

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(CLK_SYS),
	.outclk_2(CLK_40),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll),
	.locked(locked)
);

wire [63:0] reconfig_to_pll;
wire [63:0] reconfig_from_pll;
wire        cfg_waitrequest;

pll_cfg pll_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(0),
	.mgmt_waitrequest(cfg_waitrequest),
	.mgmt_read(0),
	.mgmt_readdata(),
	.mgmt_write(0),
	.mgmt_address(0),
	.mgmt_writedata(0),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

// Hold the board in reset until the PLL is locked and the ROM download has finished
wire reset = RESET | status[0] | buttons[1] | ioctl_download | ~locked;

///////////////////         Keyboard           //////////////////

// CTL-2026-10-24: original keyboard block commented out below (now controllers.sv ctl_keyboard; keys act on press)
// reg kb_up = 0, kb_down = 0, kb_left = 0, kb_right = 0;
// reg kb_b1 = 0, kb_b2 = 0;
// reg kb_coin1 = 0, kb_coin2 = 0, kb_start1 = 0, kb_start2 = 0, kb_pause = 0, kb_service = 0, kb_tilt = 0;
// reg kb_hsreset = 0, auto_up = 1;   // coin door: High Score Reset key, Auto Up / Manual Down switch (starts on Auto)
//
// wire       pressed = ~ps2_key[9];
// wire [7:0] code    = ps2_key[7:0];
//
// always @(posedge CLK_SYS) begin
// 	reg old_state;
// 	old_state <= ps2_key[10];
// 	if (old_state != ps2_key[10]) begin
// 		case (code)
// 			'h16: kb_start1  <= pressed; // 1
// 			'h1E: kb_start2  <= pressed; // 2
// 			'h2E: kb_coin1   <= pressed; // 5
// 			'h36: kb_coin2   <= pressed; // 6
// 			'h46: kb_service <= pressed; // 9 (Advance)
// 			'h06: kb_service <= pressed; // F2
// 			'h45: if (pressed) auto_up <= ~auto_up; // 0 (Auto Up / Manual Down)
// 			'h3E: kb_hsreset <= pressed; // 8 (High Score Reset)
// 			'h2C: kb_tilt    <= pressed; // T
// 			'h4D: kb_pause   <= pressed; // P
//
// 			'h75: kb_up      <= pressed; // up
// 			'h72: kb_down    <= pressed; // down
// 			'h6B: kb_left    <= pressed; // left
// 			'h74: kb_right   <= pressed; // right
// 			'h14: kb_b1      <= pressed; // ctrl
// 			'h11: kb_b2      <= pressed; // alt
// 		endcase
// 	end
// end

// CTL2-2026-10-25: v1 keyboard + local coin-door block commented out below (now ctl_keyboard's extra-key table)
// // MAME default keys (controllers.sv): kb [0] up [1] down [2] left [3] right [4] ctrl [5] alt [6] 1 [7] 2 [8] 5 [9] 6
// // [10] 9 [11] T [12] P. The coin-door keys stay here: 9 / F2 Advance (one register, as before), 0 Auto Up / Manual
// // Down, 8 High Score Reset. ps2_key[9] = 1 while the key is down.
// /* verilator lint_off UNUSED */
// wire [12:0] kb;                                    // [10] (9) unused: Advance is kb_service below
// /* verilator lint_on UNUSED */
// ctl_keyboard u_kb(.clk(CLK_SYS), .ps2_key(ps2_key), .kb(kb));
//
// reg kb_service = 0, kb_hsreset = 0, auto_up = 1;   // coin door: Advance, High Score Reset, Auto Up / Manual Down (starts on Auto)
// always @(posedge CLK_SYS) begin
// 	reg old_state;
// 	old_state <= ps2_key[10];
// 	if (old_state != ps2_key[10]) begin
// 		case (ps2_key[7:0])
// 			'h46: kb_service <= ps2_key[9]; // 9 (Advance)
// 			'h06: kb_service <= ps2_key[9]; // F2
// 			'h45: if (ps2_key[9]) auto_up <= ~auto_up; // 0 (Auto Up / Manual Down)
// 			'h3E: kb_hsreset <= ps2_key[9]; // 8 (High Score Reset)
// 		endcase
// 	end
// end
// wire kb_pause = kb[12];
// MAME default keys + coin-door keys (controllers.sv ctl_keyboard): kb [0] up [1] down [2] left [3] right [4] ctrl
// [5] alt [6] 1 [7] 2 [8] 5 [9] 6 [10] 9 [11] T [12] P; kbx [0] 9 / F2 Advance (last key event wins), [1] 0 Auto Up /
// Manual Down toggle (starts on Auto; presses ignored while paused), [2] 8 High Score Reset, [4:3] X / Z dial
// increment / decrement (MAME's dial keys). ps2_key[9] = 1 while down.
/* verilator lint_off UNUSED */
wire [12:0] kb;                                    // [10] (9) unused: Advance is kbx[0]
/* verilator lint_on UNUSED */
// DIAL-2026-10-25: original keyboard below (no dial keys)
// wire  [2:0] kbx;
// ctl_keyboard #(.NX(4), .NXO(3), .XKEYS({24'h10_3E_02, 24'h20_45_01, 24'h10_06_00, 24'h10_46_00}), .XINIT(3'b010)) u_kb
wire  [4:0] kbx;
ctl_keyboard #(.NX(6), .NXO(5), .XKEYS({24'h10_22_04, 24'h10_1A_03, 24'h10_3E_02, 24'h20_45_01, 24'h10_06_00, 24'h10_46_00}),
               .XINIT(5'b00010)) u_kb
(
	.clk(CLK_SYS), .ps2_key(ps2_key), .pause(pause_cpu), .kb(kb), .kbx(kbx)
);
wire auto_up = kbx[1], kb_hsreset = kbx[2];       // coin door: Auto Up / Manual Down switch, High Score Reset
wire kb_pause = kb[12];

//////////////////  Arcade Buttons/Interfaces   ///////////////////////////

// Joystick bits: 0 R, 1 L, 2 D, 3 U, 4-7 Btn 1-4, 8 Coin, 9 Start 1P, 10 Start 2P, 11 Pause, 12-13 Btn 5-6
// CTL-2026-10-24: original directions / 4-way / twin-stick fire / control ids commented out below (now controllers.sv)
// wire [3:0] dir1_raw = {joystick_0[3] | kb_up, joystick_0[2] | kb_down, joystick_0[1] | kb_left, joystick_0[0] | kb_right};
// wire [3:0] dir2_raw = joystick_1[3:0];
// wire [3:0] dir1, dir2;   // {U, D, L, R}
//
// joy4way joy4way_1(.clk(CLK_SYS), .en(game_flags[0]), .in(dir1_raw), .out(dir1));
// joy4way joy4way_2(.clk(CLK_SYS), .en(game_flags[0]), .in(dir2_raw), .out(dir2));
//
// wire m_pause = joystick_0[11] | kb_pause;
//
// // Twin-stick fire (Robotron, Splat, Inferno): Btn 1-4 = fire up / down / left / right, ORed with the right stick
// // pushed past a dead zone (8-way: a diagonal gives two directions)
// function [3:0] rstick(input [15:0] a);   // {right, left, down, up}
// 	reg signed [7:0] x, y;
// 	begin
// 		x = a[7:0]; y = a[15:8];
// 		rstick = {x > 8'sd40, x < -8'sd40, y > 8'sd40, y < -8'sd40};
// 	end
// endfunction
// wire [3:0] rs0 = rstick(joy_r0), rs1 = rstick(joy_r1);
// wire [3:0] fire1 = joystick_0[7:4] | {rs0[3], rs0[2], rs0[1], rs0[0]};   // {R, L, D, U} on Btn 4-1
// wire [3:0] fire2 = joystick_1[7:4] | {rs1[3], rs1[2], rs1[1], rs1[0]};
//
// // control ids used by the MRA input map (same numbering as the Exidy core; 24-31 reserved for analog)
// wire [63:0] ctl =
// {
// 	16'd0,
// 	kb_hsreset,                                     // 47 high score reset
// 	auto_up,                                        // 46 Auto Up / Manual Down switch
// 	2'd0,                                           // 45-44 reserved
// 	joystick_2[9],                                  // 43 P3 start
// 	joystick_2[4],                                  // 42 P3 Btn 1
// 	joystick_2[0], joystick_2[1], joystick_2[2], joystick_2[3],   // 41 P3 R, 40 L, 39 D, 38 U (3 Stooges)
// 	dir1[3] | dir1[2], dir1[1] | dir1[0],          // 37 P1 U or D, 36 P1 L or R (49-way stick off centre)
// 	joystick_1[13:12],                              // 35-34 P2 Btn 6-5
// 	joystick_0[13:12],                              // 33-32 P1 Btn 6-5
// 	fire2,                                          // 31-28 P2 fire R, L, D, U (Btn 4-1 or right stick)
// 	fire1,                                          // 27-24 P1 fire R, L, D, U (Btn 4-1 or right stick)
// 	1'b0,                                           // 23 coin 3
// 	kb_service,                                     // 22 service
// 	kb_tilt,                                        // 21 tilt
// 	joystick_0[10] | joystick_1[10] | joystick_1[9] | kb_start2,   // 20 start 2 (pad 2's Start is Start 2P)
// 	joystick_0[9]  | kb_start1,                     // 19 start 1
// 	joystick_1[8]  | kb_coin2,                      // 18 coin 2
// 	joystick_0[8]  | kb_coin1,                      // 17 coin 1
// 	joystick_1[7:4],                                // 16-13 P2 Btn 4-1
// 	dir2[0], dir2[1], dir2[2], dir2[3],             // 12 R, 11 L, 10 D, 9 U
// 	joystick_0[7:6], joystick_0[5] | kb_b2, joystick_0[4] | kb_b1,   // 8-5 P1 Btn 4-1
// 	dir1[0], dir1[1], dir1[2], dir1[3],             // 4 R, 3 L, 2 D, 1 U
// 	1'b0                                            // 0 none
// };

wire [3:0] dir1_raw = {joystick_0[3] | kb[0], joystick_0[2] | kb[1], joystick_0[1] | kb[2], joystick_0[0] | kb[3]};
wire [3:0] dir2_raw = joystick_1[3:0];
wire [3:0] dir1, dir2;   // {U, D, L, R}

ctl_joy4way u_j4w1(.clk(CLK_SYS), .en(game_flags[0]), .in(dir1_raw), .out(dir1));
ctl_joy4way u_j4w2(.clk(CLK_SYS), .en(game_flags[0]), .in(dir2_raw), .out(dir2));

wire m_pause = joystick_0[11] | kb_pause;

// Twin-stick fire (Robotron, Splat, Inferno): Btn 1-4 = fire up / down / left / right, ORed with the right stick
// pushed past +-40 (8-way: a diagonal gives two directions)
wire [3:0] rs0, rs1;   // {U, D, L, R}
ctl_stick_dirs #(.MODE(0), .THRESH(7'd40)) u_rs0(.stick(joy_r0), .dir(rs0));
ctl_stick_dirs #(.MODE(0), .THRESH(7'd40)) u_rs1(.stick(joy_r1), .dir(rs1));
wire [3:0] fire1 = joystick_0[7:4] | {rs0[0], rs0[1], rs0[2], rs0[3]};   // {R, L, D, U} on Btn 4-1
wire [3:0] fire2 = joystick_1[7:4] | {rs1[0], rs1[1], rs1[2], rs1[3]};

// control ids used by the MRA input map: 0-23 and 32-35 shared (controllers.sv ctl_ids), 24-31 / 36-47 this core's
/* verilator lint_off UNUSED */
wire [35:0] ids;                                   // 31-24 unused (0 in ctl_ids; this core's ids below)
/* verilator lint_on UNUSED */
ctl_ids u_ids
(
	// CTL2-2026-10-25: original below
// 	.joy0(joystick_0), .joy1(joystick_1), .kb({kb[12:11], kb_service, kb[9:0]}), .dir1(dir1), .dir2(dir2),
	.joy0(joystick_0), .joy1(joystick_1), .kb({kb[12:11], kbx[0], kb[9:0]}), .dir1(dir1), .dir2(dir2),
	.coin1(joystick_0[8] | kb[8]), .coin2(joystick_1[8] | kb[9]), .coin3(1'b0), .ctl(ids)
);
wire [63:0] ctl =
{
	16'd0,
	kb_hsreset,                                     // 47 high score reset
	auto_up,                                        // 46 Auto Up / Manual Down switch
	2'd0,                                           // 45-44 reserved
	joystick_2[9],                                  // 43 P3 start
	joystick_2[4],                                  // 42 P3 Btn 1
	joystick_2[0], joystick_2[1], joystick_2[2], joystick_2[3],   // 41 P3 R, 40 L, 39 D, 38 U (3 Stooges)
	dir1[3] | dir1[2], dir1[1] | dir1[0],          // 37 P1 U or D, 36 P1 L or R (49-way stick off centre)
	ids[35:32],                                     // 35-32 P2 / P1 Btn 6-5
	fire2,                                          // 31-28 P2 fire R, L, D, U (Btn 4-1 or right stick)
	fire1,                                          // 27-24 P1 fire R, L, D, U (Btn 4-1 or right stick)
	ids[23:0]                                       // 23-0 shared ids (pad 2's Start is Start 2P)
};

// CTL-2026-10-24: original trackball counters commented out below (now controllers.sv ctl_trackball)
// // Trackballs / spinner (Speed Ball AN0-AN3, Conquest dial): 8-bit position counters per player and axis, X right +,
// // Y up +. Player 1: mouse, else the left analog stick, else the D-pad; player 2: its left analog stick, else its D-pad.
// // Sticks and D-pads move a 16-bit position at 2930 Hz by the deflection (D-pad: half scale); the top byte is the count.
// // One mouse count = half a position count.
// wire signed [7:0] ax = joy_a0[7:0], ay = joy_a0[15:8], bx1 = joy_a1[7:0], by1 = joy_a1[15:8];
// wire       a_on  = (ax  > 8'sd24) || (ax  < -8'sd24) || (ay  > 8'sd24) || (ay  < -8'sd24);
// wire       a1_on = (bx1 > 8'sd24) || (bx1 < -8'sd24) || (by1 > 8'sd24) || (by1 < -8'sd24);
// wire signed [15:0] mdx = {{7{ps2_mouse[4]}}, ps2_mouse[15:8], 1'b0} <<< 6;
// wire signed [15:0] mdy = {{7{ps2_mouse[5]}}, ps2_mouse[23:16], 1'b0} <<< 6;
// function signed [15:0] step(input on, input signed [7:0] v, input neg, input pos);   // stick, else D-pad
// 	step = on ? {{8{v[7]}}, v} : neg ? -16'sd64 : pos ? 16'sd64 : 16'sd0;
// endfunction
// reg [15:0] tb_x0 = 0, tb_y0 = 0, tb_x1 = 0, tb_y1 = 0;
// reg [13:0] tb_div = 0;
// reg        mouse_t = 0;
// always @(posedge CLK_SYS) begin
// 	mouse_t <= ps2_mouse[24];
// 	tb_div  <= tb_div + 1'd1;
// 	if (mouse_t != ps2_mouse[24]) begin
// 		tb_x0 <= tb_x0 + mdx;
// 		tb_y0 <= tb_y0 + mdy;
// 	end
// 	else if (!tb_div) begin   // stick Y is up negative, the counter up positive
// 		tb_x0 <= tb_x0 + step(a_on,  ax,  dir1[1], dir1[0]);
// 		tb_y0 <= tb_y0 - step(a_on,  ay,  dir1[3], dir1[2]);
// 		tb_x1 <= tb_x1 + step(a1_on, bx1, dir2[1], dir2[0]);
// 		tb_y1 <= tb_y1 - step(a1_on, by1, dir2[3], dir2[2]);
// 	end
// end

// Trackball / spinner (Speed Ball, Conquest dial), player 1 (the board reads one): X right +, Y up +. Mouse (half a
// count per count), left stick (any axis past +-24 drives both, by the deflection) or D-pad (+-64) at clk / 16384
// (2930 Hz) on a 16-bit position; the top byte is the count. Every source on one clock is summed.
wire       ms_ev;
wire [9:0] ms_dx, ms_dy;
/* verilator lint_off UNUSED */
wire [2:0] ms_btn;
wire [1:0] track_dir;
/* verilator lint_on UNUSED */
wire [7:0] track_h, track_v;
wire       tb_tick;
ctl_mouse u_ms(.clk(CLK_SYS), .ps2_mouse(ps2_mouse), .ev(ms_ev), .dx(ms_dx), .dy(ms_dy), .btn(ms_btn));
// CTL2-2026-10-25: original below (tick and trackball now stop while paused)
// ctl_tick #(.MODE(1), .DW(14)) u_tbt(.clk(CLK_SYS), .pause(1'b0), .vblank(1'b0), .period(14'd16383), .tick(tb_tick));
// ctl_trackball #(.CW(16), .OUT_W(8), .MOUSE_SH(7), .STICK_RSH(0), .DPAD_STEP(64), .DZ(24), .LIVE_ANY(1)) u_tb
// (
// 	.clk(CLK_SYS), .reset(1'b0), .pause(1'b0), .rev(2'b10), .unit_sh(2'd0), .base_sh(4'd8), .speed(2'd0),
ctl_tick #(.MODE(1), .DW(14)) u_tbt(.clk(CLK_SYS), .pause(pause_cpu), .vblank(1'b0), .period(14'd16383), .tick(tb_tick));
ctl_trackball #(.CW(16), .OUT_W(8), .MOUSE_SH(7), .STICK_RSH(0), .DPAD_STEP(64), .DZ(24), .LIVE_ANY(1)) u_tb
(
	.clk(CLK_SYS), .reset(1'b0), .pause(pause_cpu), .rev(2'b10), .unit_sh(2'd0), .base_sh(4'd8), .speed(2'd0),
	.mouse_ev(ms_ev), .mouse_dx(ms_dx), .mouse_dy(ms_dy), .spinner(9'd0), .quad_ce(2'b00), .quad_dir(2'b00),
	.tick(tb_tick), .stick_en(1'b1), .stick(joy_a0), .dpad(dir1), .x(track_h), .y(track_v), .dir(track_dir)
);

// DIP switches arrive from the OSD via ioctl index 254
reg [7:0] dip_sw[8] = '{8'hFF,8'hFF,8'hFF,8'hFF,8'h00,8'h00,8'h00,8'h00};
always @(posedge CLK_SYS) begin
	if (ioctl_wr && (ioctl_index == 8'd254) && !ioctl_addr[24:3])
		dip_sw[ioctl_addr[2:0]] <= ioctl_dout;
end

// CTL2-2026-10-25: original port loop commented out below (now controllers.sv ctl_port_map BASE_MODE 2)
// reg [7:0] in_port[8];
// always @(posedge CLK_SYS) begin
// 	for (int p = 0; p < 8; p++)
// 		for (int b = 0; b < 8; b++)
// 			in_port[p][b] <= (port_dip[p][7] ? port_idle[p][b] : dip_sw[port_dip[p][2:0]][dip_bit[p*8 + b]]) ^ ctl[in_map[p*8 + b]];
// end
// MRA input map -> board input ports (controllers.sv ctl_port_map, registered): port_dip[p][7] = 1 takes the idle byte,
// else DIP byte port_dip[p][2:0] bit dip_bit[]; a pressed control (id in_map[]) inverts the bit
wire  [7:0] in_port[8];
wire [63:0] pm_idle, pm_sel, pm_dips, pm_ports;
wire [511:0] pm_map;
wire [191:0] pm_dbit;
// CTL2-2026-10-25: Quartus 17.0 rejects `for (genvar ...)` in the loop header (error 10170) and genvar b clashed
// with wire b; genvars now declared at module scope inside generate. Original block:
// for (genvar p = 0; p < 8; p++) begin : g_pm
// 	assign pm_idle[p*8 +: 8] = port_idle[p];
// 	assign pm_sel[p*8 +: 8]  = port_dip[p];
// 	assign pm_dips[p*8 +: 8] = dip_sw[p];
// 	assign in_port[p]        = pm_ports[p*8 +: 8];
// 	for (genvar b = 0; b < 8; b++) begin : g_b
// 		assign pm_map[(p*8 + b)*8 +: 8]  = {2'b00, in_map[p*8 + b]};
// 		assign pm_dbit[(p*8 + b)*3 +: 3] = dip_bit[p*8 + b];
// 	end
// end
genvar pm_p, pm_b;
generate
	for (pm_p = 0; pm_p < 8; pm_p = pm_p + 1) begin : g_pm
		assign pm_idle[pm_p*8 +: 8] = port_idle[pm_p];
		assign pm_sel[pm_p*8 +: 8]  = port_dip[pm_p];
		assign pm_dips[pm_p*8 +: 8] = dip_sw[pm_p];
		assign in_port[pm_p]        = pm_ports[pm_p*8 +: 8];
		for (pm_b = 0; pm_b < 8; pm_b = pm_b + 1) begin : g_b
			assign pm_map[(pm_p*8 + pm_b)*8 +: 8]  = {2'b00, in_map[pm_p*8 + pm_b]};
			assign pm_dbit[(pm_p*8 + pm_b)*3 +: 3] = dip_bit[pm_p*8 + pm_b];
		end
	end
endgenerate
ctl_port_map #(.NP(8), .IDW(6), .BASE_MODE(2)) u_pm
(
	.clk(CLK_SYS), .idle(pm_idle), .in_map(pm_map), .dips(32'd0), .port_sel(pm_sel), .dip_bytes(pm_dips),
	.dip_bit(pm_dbit), .ctl(ctl), .ovr_mask(64'd0), .ovr_val(64'd0), .ports(pm_ports)
);

// PAUSE SYSTEM
wire [23:0] rgb_out;
wire hs, vs;
wire [7:0] r, g, b;
wire ce_pix;                         // CLK_40 domain pixel enable (5 MHz)
pause #(8,8,8,40) pause
(
	.*,
	.clk_sys(CLK_40),
	.user_button(m_pause),
	.pause_request(1'b0),
	.options(~status[20:19])
);

///////////////                 Video                  ////////////////

// The board runs at 80 MHz (MCL86); the video back end runs at 40 MHz (CLK_40, same PLL VCO, rising edges aligned
// 2:1), where the artwork module closes timing. rtl/art/art_xclk.sv moves the pixels and the artwork download across
// (tested: verilator/art/xclk_tb.cpp).
wire        bd_ce, bd_hs, bd_vs, bd_hbl, bd_vbl;
wire  [7:0] bd_r, bd_g, bd_b;
wire [27:0] v_px;
wire        a_wr;
wire [26:0] a_addr;
wire  [7:0] a_dout;
art_xclk #(.IDX(8'd5), .VW(28)) art_xclk
(
	.clk_sys(CLK_SYS), .clk_art(CLK_40),
	.bd_ce(bd_ce), .bd_px({bd_hs, bd_vs, bd_hbl, bd_vbl, bd_r, bd_g, bd_b}), .ce_art(ce_pix), .px(v_px),
	.ioctl_wr(ioctl_wr), .ioctl_index(ioctl_index), .ioctl_addr(ioctl_addr27), .ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait), .a_wr(a_wr), .a_addr(a_addr), .a_dout(a_dout), .art_wait(art_wait)
);

// MAME artwork (OSD Game Options page): native composite on the core video (one pixel late),
// full view through the DDR3 framebuffer on HDMI
wire        art_run, art_ddr;
wire [31:0] art_fb_base;
wire  [7:0] art_burstcnt, art_be;
wire [28:0] art_addr;
wire [63:0] art_din;
wire        art_rd, art_we, art_clk;
artwork #(.IDX(8'd5)) artwork
(
	.clk(CLK_40),
	.sel(status[48:45]), .layer_off({status[54], status[51:49]}), .side_off(status[52]), .zoom(status[53]),
	.crt_flip(status[22]), .hdmi_flip(status[11]), .turn(status[12]), .avail(art_avail),
	.hdmi_w(HDMI_WIDTH), .hdmi_h(HDMI_HEIGHT),
	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(a_wr),
	.ioctl_addr(a_addr), .ioctl_dout(a_dout), .ioctl_wait(art_wait),
	.ce_pix(ce_pix),
	.hs_in(v_px[27]), .vs_in(v_px[26]), .hblank_in(v_px[25]), .vblank_in(v_px[24]), .rgb_in(v_px[23:0]),
	.hs_out(hs), .vs_out(vs), .hblank_out(hblank), .vblank_out(vblank), .rgb_out({r, g, b}),
	.running(art_run), .ddr_owner(art_ddr), .canvas_w(art_cw), .canvas_h(art_ch),
	.fb_base(art_fb_base), .fb_vbl(FB_VBL),
	.DDRAM_CLK(art_clk), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(art_burstcnt), .DDRAM_ADDR(art_addr),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(art_rd),
	.DDRAM_DIN(art_din), .DDRAM_BE(art_be), .DDRAM_WE(art_we)
);
assign art_fb = art_run & ~direct_video;

wire rotate_ccw = ~game_flags[7];  // ROT270 sets rotate CCW, ROT90 sets CW
wire no_rotate  = ~game_vert | status[12] | direct_video;
wire flip       = status[11];
wire        sr_fb_en, sr_clk, sr_rd, sr_we;
wire  [4:0] sr_fb_format;
wire [11:0] sr_fb_w, sr_fb_h;
wire [31:0] sr_fb_base;
wire [13:0] sr_fb_stride;
wire  [7:0] sr_burstcnt, sr_be;
wire [28:0] sr_addr;
wire [63:0] sr_din;
screen_rotate screen_rotate
(
	.*,
	.FB_EN(sr_fb_en), .FB_FORMAT(sr_fb_format), .FB_WIDTH(sr_fb_w), .FB_HEIGHT(sr_fb_h),
	.FB_BASE(sr_fb_base), .FB_STRIDE(sr_fb_stride),
	.DDRAM_CLK(sr_clk), .DDRAM_BURSTCNT(sr_burstcnt), .DDRAM_ADDR(sr_addr), .DDRAM_DIN(sr_din),
	.DDRAM_BE(sr_be), .DDRAM_WE(sr_we), .DDRAM_RD(sr_rd)
);

// the artwork takes the framebuffer while it draws, and DDR3 while it loads or draws
assign FB_EN     = art_fb | sr_fb_en;
assign FB_FORMAT = art_fb ? 5'b00110  : sr_fb_format;
assign FB_WIDTH  = art_fb ? art_cw    : sr_fb_w;
assign FB_HEIGHT = art_fb ? art_ch    : sr_fb_h;
assign FB_BASE   = art_fb ? art_fb_base : sr_fb_base;
assign FB_STRIDE = art_fb ? 14'd8192  : sr_fb_stride;
assign DDRAM_CLK      = CLK_40;
assign DDRAM_BURSTCNT = art_ddr ? art_burstcnt : sr_burstcnt;
assign DDRAM_ADDR     = art_ddr ? art_addr : sr_addr;
assign DDRAM_DIN      = art_ddr ? art_din : sr_din;
assign DDRAM_BE       = art_ddr ? art_be : sr_be;
assign DDRAM_WE       = art_ddr ? art_we : sr_we;
assign DDRAM_RD       = art_ddr ? art_rd : sr_rd;

arcade_video #(256,24) arcade_video
(
	.*,

	.clk_video(CLK_40),

	.RGB_in(rgb_out),
	.HBlank(hblank),
	.VBlank(vblank),
	.HSync(hs),
	.VSync(vs),

	.fx(status[18:16])
);

// Dial (byte 152 bit 2: Mad Planets, Wiz Warz): MAME IPT_DIAL on IN3 at the MRA's MAME sensitivity / key delta. MiSTer
// spinner, mouse X, right stick X (rate) and Z / X keys; the left stick and D-pad stay on the joystick only (as the
// trackball's Y they turned the ship on every move). OSD sensitivity / direction.
wire       dial_frame;
wire [7:0] dial_pos;
ctl_tick #(.MODE(0), .DW(1)) u_dft(.clk(CLK_SYS), .pause(pause_cpu), .vblank(bd_vbl), .period(1'b0), .tick(dial_frame));
ctl_dial_mame u_dial
(
	.clk(CLK_SYS), .reset(1'b0), .pause(pause_cpu), .frame(dial_frame), .sens(cfg_dsens), .keyd(cfg_dkey),
	.reverse(status[31]), .osd_sens(status[30:28]), .wheel(1'b0),
	.spinner(spinner_0), .mouse_ev(ms_ev), .mouse_d(ms_dx[8:0]), .stick(joy_r0[7:0]), .paddle(8'd0), .use_paddle(1'b0),
	.dec(kbx[3]), .inc(kbx[4]), .pos(dial_pos)
);
wire [7:0] track_v_bd = cfg_an[2] ? dial_pos : track_v;

///////////////                 Board                  ////////////////

wire knocker;   // Q*bert knocker solenoid (thump synthesis not built yet)

gottlieb_board board
(
	.clk(CLK_SYS),
	.reset(reset),
	.pause(pause_cpu),
	.map_sel(cfg_map[1:0]),
	.tile_cfg(cfg_tile[2:0]),
	.snd_sel(cfg_snd[2:0]),
	.out_mode(cfg_out[2:0]),
	.an_flags(cfg_an[1:0]),
	.no_wd(game_flags[5]),
	.ce_pix(bd_ce),

	.in_dsw(in_port[0]),
	.in1(in_port[1]),
	.in2(in_port[2]),
	.in3(in_port[3]),
	.in4(in_port[4]),
	.joy_p1(in_port[5][3:0]),
	.joy_p2(in_port[6][3:0]),
	.joy_p3(in_port[7][3:0]),
	// CTL-2026-10-24: original below
	// .track_h(tb_x0[15:8]),
	// .track_v(tb_y0[15:8]),
	.track_h(track_h),
	// DIAL-2026-10-25: original below
	// .track_v(track_v),
	.track_v(track_v_bd),

	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wr0(ioctl_wr & (ioctl_index == 8'd0)),

	// NVRAM (MRA <nvram index="4" size="4096">): loaded with the MRA, saved when the OSD opens / closes
	.nv_addr(ioctl_addr[11:0]),
	.nv_din(ioctl_dout),
	.nv_we(ioctl_download & ioctl_wr & (ioctl_index == 8'd4)),
	.nv_dout(ioctl_din),

	.crt_flip(status[22]),
	.h_adj(status[40:37]),
	.v_adj(status[44:41]),

	.video_r(bd_r),
	.video_g(bd_g),
	.video_b(bd_b),
	.video_hs(bd_hs),
	.video_vs(bd_vs),
	.video_hblank(bd_hbl),
	.video_vblank(bd_vbl),

	.knocker(knocker),
	.audio(audio)
);

assign ioctl_upload_req = ~status[27] & ~ioctl_download;

endmodule

// CTL-2026-10-24: original 4-way module commented out below (now controllers.sv ctl_joy4way, same logic)
// // 4-way joystick: the most recently pressed direction wins (from the MiSTer Pac-Man port)
// module joy4way
// (
// 	input        clk,
// 	input        en,
// 	input  [3:0] in,
// 	output [3:0] out
// );
//
// reg  [3:0] mask = 4'hF;
// reg  [3:0] in1 = 0, in2 = 0;
// wire [3:0] innew = in1 & ~in2;
//
// assign out = in1 & mask;
//
// always @(posedge clk) begin
// 	in1 <= in;
// 	in2 <= in1;
//
// 	if (innew[0]) mask <= 4'b0001;
// 	if (innew[1]) mask <= 4'b0010;
// 	if (innew[2]) mask <= 4'b0100;
// 	if (innew[3]) mask <= 4'b1000;
//
// 	if (!(in & mask) || !en) mask <= 4'hF;
// end
//
// endmodule
