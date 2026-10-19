//============================================================================
//
//  Gottlieb System 80 (GG-III) raster hardware — board top
//  Copyright (C) 2026 Rodimus
//
//  Owns the shared parts: the 8088 (MCL86, Ted Fried / MicroCore Labs), the ROM pools and the sound boards.
//  The logic board (rtl/boards/gottlieb_main) exports the CPU bus.
//
//  ioctl index 0 (MRA), sized for every set in MAME gottlieb.cpp:
//    00000-0BFFF  main CPU 48K: CPU 6000-FFFF at 0000-9FFF, CPU 1000-2FFF at A000-BFFF (Krull, Argus, 3 Stooges)
//    0C000-0DFFF  tile ROM 8K (Video Vince 4K; RAM-tile games none)
//    0E000-0FFFF  sound ROM pool A 8K: Rev 1 CPU 6000-7FFF, or Rev 2 sound CPU C000-DFFF
//    10000-1FFFF  sprite ROM 64K as four 16K planes, MSB plane first (Qubes 64K; others 32K, planes padded to 16K)
//    20000-23FFF  sound ROM pool B 16K: Rev 2 speech CPU C000-FFFF
//    24000-241FF  Votrax SC-01 / SC-01A internal ROM (speech sets: MAME votrsc01 / votrsc01a zip)
//
//  MRA index 1 bytes 148-152 (see Arcade-Gottlieb.sv): map_sel, tile_cfg, sound board, out_mode, an_flags
//  ioctl index 4: NVRAM 4K (MRA <nvram>)
//
//============================================================================

module gottlieb_board
(
    input  logic        clk,            // 80 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic  [1:0] map_sel,
    input  logic  [2:0] tile_cfg,
    input  logic  [2:0] snd_sel,        // 0 none, 1 Rev 1, 2 Rev 1 + SC-01, 3 Rev 1 + SC-01A, 4 Rev 2
    input  logic  [2:0] out_mode,
    input  logic  [1:0] an_flags,
    input  logic        no_wd,
    output logic        ce_pix,

    input  logic  [7:0] in_dsw,
    input  logic  [7:0] in1,
    input  logic  [7:0] in2,
    input  logic  [7:0] in3,
    input  logic  [7:0] in4,
    input  logic  [3:0] joy_p1,
    input  logic  [3:0] joy_p2,
    input  logic  [3:0] joy_p3,
    input  logic  [7:0] track_h,
    input  logic  [7:0] track_v,

    input  logic [24:0] ioctl_addr,
    input  logic  [7:0] ioctl_dout,
    input  logic        ioctl_wr0,

    input  logic [11:0] nv_addr,
    input  logic  [7:0] nv_din,
    input  logic        nv_we,
    output logic  [7:0] nv_dout,

    input  logic        crt_flip,
    input  logic  [3:0] h_adj,
    input  logic  [3:0] v_adj,

    output logic  [7:0] video_r,
    output logic  [7:0] video_g,
    output logic  [7:0] video_b,
    output logic        video_hs,
    output logic        video_vs,
    output logic        video_hblank,
    output logic        video_vblank,

    output logic        knocker,
    output logic signed [15:0] audio
);

/////////////////////////////  ROM pools  /////////////////////////////

wire [24:0] ia = ioctl_addr;

logic [15:0] main_a;
logic  [7:0] main_d;
dpram_dc #(.widthad_a(16)) u_main_rom
(
    .clock_a(clk), .address_a(ia[15:0]), .data_a(ioctl_dout), .wren_a(ioctl_wr0 && ia < 25'h0C000), .q_a(),
    .clock_b(clk), .address_b(main_a), .data_b(8'd0), .wren_b(1'b0), .q_b(main_d)
);

logic [12:0] tile_a;
logic  [7:0] tile_d;
dpram_dc #(.widthad_a(13)) u_tile_rom
(
    .clock_a(clk), .address_a(ia[12:0]), .data_a(ioctl_dout), .wren_a(ioctl_wr0 && ia[24:13] == 12'h006), .q_a(),
    .clock_b(clk), .address_b(tile_a), .data_b(8'd0), .wren_b(1'b0), .q_b(tile_d)
);

logic [13:0] spr_a;
logic [31:0] spr_d;
genvar gp;
generate for (gp = 0; gp < 4; gp++) begin : spr_plane
    dpram_dc #(.widthad_a(14)) u_spr_rom
    (
        .clock_a(clk), .address_a(ia[13:0]), .data_a(ioctl_dout),
        .wren_a(ioctl_wr0 && ia[24:16] == 9'h001 && ia[15:14] == gp), .q_a(),
        .clock_b(clk), .address_b(spr_a), .data_b(8'd0), .wren_b(1'b0), .q_b(spr_d[31 - gp*8 -: 8])
    );
end endgenerate

logic [12:0] snda_a, r1_a, r2_a;
logic  [7:0] snda_d;
logic [13:0] sndb_a;
logic  [7:0] sndb_d;
wire        rev2 = (snd_sel == 3'd4);
assign snda_a = rev2 ? r2_a : r1_a;
dpram_dc #(.widthad_a(13)) u_snd_rom_a
(
    .clock_a(clk), .address_a(ia[12:0]), .data_a(ioctl_dout), .wren_a(ioctl_wr0 && ia[24:13] == 12'h007), .q_a(),
    .clock_b(clk), .address_b(snda_a), .data_b(8'd0), .wren_b(1'b0), .q_b(snda_d)
);
dpram_dc #(.widthad_a(14)) u_snd_rom_b
(
    .clock_a(clk), .address_a(ia[13:0]), .data_a(ioctl_dout), .wren_a(ioctl_wr0 && ia[24:14] == 11'h008), .q_a(),
    .clock_b(clk), .address_b(sndb_a), .data_b(8'd0), .wren_b(1'b0), .q_b(sndb_d)
);

// Votrax SC-01 / SC-01A internal ROM (512 bytes, MAME device zip) at ioctl 0x24000
logic [8:0] vrom_a;
logic [7:0] vrom_d;
dpram_dc #(.widthad_a(9)) u_votrax_rom
(
    .clock_a(clk), .address_a(ia[8:0]), .data_a(ioctl_dout), .wren_a(ioctl_wr0 && ia[24:9] == 16'h0120), .q_a(),
    .clock_b(clk), .address_b(vrom_a), .data_b(8'd0), .wren_b(1'b0), .q_b(vrom_d)
);

/////////////////////////////  8088 (MCL86)  /////////////////////////////

logic wd_reset, vblank_rise;
wire  cpu_reset = reset | wd_reset;

// 5 MHz pin clock = 80 MHz / 16 (XTAL 15 MHz / 3 on the board); held while paused
logic [2:0] clkdiv;
logic       cpu_clk;
always_ff @(posedge clk) begin
    if (cpu_reset) begin clkdiv <= 3'd0; cpu_clk <= 1'b0; end
    else if (!pause) begin
        clkdiv <= clkdiv + 3'd1;
        if (clkdiv == 3'd7) cpu_clk <= ~cpu_clk;
    end
end

// VBLANK is the only interrupt and drives NMI
wire nmi = vblank_rise & ~pause;

wire [15:0] eu_biu_command, eu_biu_dataout, eu_register_r3;
wire        eu_prefix_lock, eu_flag_i;
wire        biu_done, biu_clk_counter_zero, biu_nmi_caught, biu_nmi_debounce, biu_intr;
wire  [7:0] pfq_top_byte;
wire        pfq_empty;
wire [15:0] pfq_addr_out;
wire [15:0] biu_es, biu_ss, biu_cs, biu_ds, biu_rm, biu_reg, biu_ret;
wire        ad_oe, lock_n, s6_3_mux;
wire [19:0] ad_out;
wire  [7:0] ad_in;
wire  [2:0] s2_s0;
wire        ready_in;

biu_max BIU
(
    .CORE_CLK_INT(clk),
    .CLK(cpu_clk), .RESET_INT(cpu_reset), .READY_IN(ready_in),
    .NMI(nmi), .INTR(1'b0),
    .LOCK_n(lock_n), .AD_OE(ad_oe), .AD_OUT(ad_out), .AD_IN(ad_in),
    .S6_3_MUX(s6_3_mux), .S2_S0_OUT(s2_s0),
    .EU_BIU_COMMAND(eu_biu_command), .EU_BIU_DATAOUT(eu_biu_dataout),
    .EU_REGISTER_R3(eu_register_r3), .EU_PREFIX_LOCK(eu_prefix_lock),
    .BIU_DONE(biu_done), .BIU_CLK_COUNTER_ZERO(biu_clk_counter_zero),
    .BIU_SEGMENT(), .BIU_NMI_CAUGHT(biu_nmi_caught),
    .BIU_NMI_DEBOUNCE(biu_nmi_debounce), .BIU_INTR(biu_intr),
    .PFQ_TOP_BYTE(pfq_top_byte), .PFQ_EMPTY(pfq_empty), .PFQ_ADDR_OUT(pfq_addr_out),
    .BIU_REGISTER_ES(biu_es), .BIU_REGISTER_SS(biu_ss), .BIU_REGISTER_CS(biu_cs),
    .BIU_REGISTER_DS(biu_ds), .BIU_REGISTER_RM(biu_rm), .BIU_REGISTER_REG(biu_reg),
    .BIU_RETURN_DATA(biu_ret)
);

// private execution unit (a pooled EU broke DL2 and Mach 3 on hardware, LaserdiscGames 2026-10-16)
mcl86_eu_core EU
(
    .CORE_CLK_INT(clk), .RESET_INT(cpu_reset), .TEST_N_INT(1'b1),
    .EU_BIU_COMMAND(eu_biu_command), .EU_BIU_DATAOUT(eu_biu_dataout),
    .EU_REGISTER_R3(eu_register_r3), .EU_PREFIX_LOCK(eu_prefix_lock), .EU_FLAG_I(eu_flag_i),
    .BIU_DONE(biu_done), .BIU_CLK_COUNTER_ZERO(biu_clk_counter_zero),
    .BIU_NMI_CAUGHT(biu_nmi_caught), .BIU_NMI_DEBOUNCE(biu_nmi_debounce), .BIU_INTR(biu_intr),
    .PFQ_TOP_BYTE(pfq_top_byte), .PFQ_EMPTY(pfq_empty), .PFQ_ADDR_OUT(pfq_addr_out),
    .BIU_REGISTER_ES(biu_es), .BIU_REGISTER_SS(biu_ss), .BIU_REGISTER_CS(biu_cs),
    .BIU_REGISTER_DS(biu_ds), .BIU_REGISTER_RM(biu_rm), .BIU_REGISTER_REG(biu_reg),
    .BIU_RETURN_DATA(biu_ret)
);

wire        req, req_ack;
wire  [2:0] req_type;
wire [19:0] req_addr;
wire  [7:0] req_wdata, req_rdata;

dl2_bus busglue
(
    .clk(clk), .reset_n(~cpu_reset),
    .s2_s0(s2_s0), .s6_3_mux(s6_3_mux), .ad_out(ad_out),
    .ad_in(ad_in), .ready_in(ready_in),
    .req(req), .req_type(req_type), .req_addr(req_addr), .req_wdata(req_wdata),
    .req_rdata(req_rdata), .req_ack(req_ack)
);

/////////////////////////////  Logic board  /////////////////////////////

logic [7:0] snd_cmd;
logic       snd_stb;

gottlieb_main main_b
(
    // the watchdog resets only the 8088 (8284 RES); the logic board takes the board reset
    .clk(clk), .reset(reset), .pause(pause),
    .map_sel(map_sel), .out_mode(out_mode), .an_flags(an_flags), .no_wd(no_wd), .tile_cfg(tile_cfg),
    .req(req), .req_type(req_type), .req_addr(req_addr[15:0]), .req_wdata(req_wdata),
    .req_rdata(req_rdata), .req_ack(req_ack), .wd_reset(wd_reset),
    .in_dsw(in_dsw), .in1(in1), .in2(in2), .in3(in3), .in4(in4),
    .joy_p1(joy_p1), .joy_p2(joy_p2), .joy_p3(joy_p3), .track_h(track_h), .track_v(track_v),
    .rom_a(main_a), .rom_d(main_d),
    .nv_addr(nv_addr), .nv_din(nv_din), .nv_we(nv_we), .nv_dout(nv_dout),
    .snd_cmd(snd_cmd), .snd_stb(snd_stb), .knocker(knocker),
    .tile_rom_a(tile_a), .tile_rom_d(tile_d), .spr_rom_a(spr_a), .spr_rom_d(spr_d),
    .crt_flip(crt_flip), .h_adj(h_adj), .v_adj(v_adj),
    .ce_pix(ce_pix), .vblank_rise(vblank_rise),
    .video_r(video_r), .video_g(video_g), .video_b(video_b),
    .video_hs(video_hs), .video_vs(video_vs), .video_hblank(video_hblank), .video_vblank(video_vblank)
);

/////////////////////////////  Sound boards  /////////////////////////////

logic signed [15:0] r1_audio, r2_audio;
wire rev1 = (snd_sel >= 3'd1 && snd_sel <= 3'd3);

// Pooled sound 6502 (T65): the Rev 1 board's CPU; the Rev 2 board's sound CPU when that board is built
logic        s0_ce, s0_rst, s0_irq_n, s0_nmi_n, s0_rw;
logic [23:0] s0_a24;
logic  [7:0] s0_do, s0_di;

T65 snd_cpu
(
    .Mode(2'b00), .Res_n(~s0_rst), .Enable(s0_ce), .Clk(clk), .Rdy(1'b1), .Abort_n(1'b1),
    .IRQ_n(s0_irq_n), .NMI_n(s0_nmi_n), .SO_n(1'b1), .R_W_n(s0_rw), .Sync(), .EF(), .MF(), .XF(), .ML_n(), .VP_n(),
    .VDA(), .VPA(), .A(s0_a24), .DI(s0_di), .DO(s0_do), .Regs(), .NMI_ack()
);

gottlieb_snd_r1 snd_r1
(
    .clk(clk), .reset(reset | ~rev1), .pause(pause), .speech(snd_sel[1:0] - 2'd1),
    .cmd(snd_cmd), .cmd_stb(snd_stb),
    .cpu_ce(s0_ce), .cpu_rst(s0_rst), .cpu_irq_n(s0_irq_n), .cpu_nmi_n(s0_nmi_n),
    .cpu_a(s0_a24[15:0]), .cpu_do(s0_do), .cpu_rw(s0_rw), .cpu_di(s0_di),
    .rom_a(r1_a), .rom_d(snda_d), .vrom_a(vrom_a), .vrom_d(vrom_d),
    .audio(r1_audio)
);
gottlieb_snd_r2 snd_r2
(
    .clk(clk), .reset(reset | ~rev2), .pause(pause),
    .cmd(snd_cmd), .cmd_stb(snd_stb),
    .rom_a(r2_a), .rom_d(snda_d), .sp_rom_a(sndb_a), .sp_rom_d(sndb_d),
    .audio(r2_audio)
);

/////////////////////////////  Knocker  /////////////////////////////

// Q*bert's cabinet knocker (solenoid on the wooden cabinet, OP35 -> 2N6044 -> A-5195 coil): synthesized wood knock
// (rtl/sound/knocker, fitted to a real-cabinet recording). The game's own Kicker DIP gates the drive, so no OSD
// option. It is far louder than the game on a real cabinet: mixed on top at ~0.9 FS, saturating.
logic signed [15:0] knock;
knocker knock_gen
(
    .clk(clk), .reset(reset), .pause(pause), .trig(knocker),
    .audio(knock), .sample()
);

wire signed [15:0] snd  = rev2 ? r2_audio : rev1 ? r1_audio : 16'sd0;
wire signed [16:0] mixk = $signed({snd[15], snd}) + $signed({knock[15], knock});
assign audio = (mixk > 17'sd32767) ? 16'sh7fff : (mixk < -17'sd32768) ? -16'sh8000 : mixk[15:0];

endmodule
