//  Based on MAME gottlieb.cpp (Fabrice Frances, Nicola Salmoria, Aaron Giles, BSD-3-Clause)
//  Copyright (C) 2026 Rodimus

module gottlieb_dispatcher
(
    input  logic        clk,
    input  logic        reset,
    input  logic        pause,
    input  logic  [1:0] map_sel,
    input  logic  [2:0] tile_cfg,
    input  logic  [2:0] snd_sel,
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

logic [8:0] vrom_a;
logic [7:0] vrom_d;
dpram_dc #(.widthad_a(9)) u_votrax_rom
(
    .clock_a(clk), .address_a(ia[8:0]), .data_a(ioctl_dout), .wren_a(ioctl_wr0 && ia[24:9] == 16'h0120), .q_a(),
    .clock_b(clk), .address_b(vrom_a), .data_b(8'd0), .wren_b(1'b0), .q_b(vrom_d)
);

/////////////////////////////  Shared CPU / sound chip pool  /////////////////////////////

// mcl86_0: 8088 (master mcl86_cpu: BIU + EU + bus glue), logic board
chip_pool_pkg::mcl86_i_t mcl86_0_i;
chip_pool_pkg::mcl86_o_t mcl86_0_o;
mcl86_cpu mcl86_0
(
    .clk(clk), .reset(mcl86_0_i.reset), .cpu_clk(mcl86_0_i.cpu_clk), .nmi(mcl86_0_i.nmi), .intr(mcl86_0_i.intr),
    .req(mcl86_0_o.req), .req_type(mcl86_0_o.req_type), .req_addr(mcl86_0_o.req_addr), .req_wdata(mcl86_0_o.req_wdata),
    .req_rdata(mcl86_0_i.req_rdata), .req_ack(mcl86_0_i.req_ack)
);

// t65_0: Rev 1 sound board 6502 (stock T65)
chip_pool_pkg::t65_i_t t65_0_i;
chip_pool_pkg::t65_o_t t65_0_o;
wire [23:0] t65_0_a24;
wire        t65_0_rw;
T65 t65_0
(
    .Mode(2'b00), .Res_n(t65_0_i.res_n), .Enable(t65_0_i.enable), .Clk(clk), .Rdy(t65_0_i.rdy), .Abort_n(1'b1),
    .IRQ_n(t65_0_i.irq_n), .NMI_n(t65_0_i.nmi_n), .SO_n(1'b1), .R_W_n(t65_0_rw), .Sync(), .EF(), .MF(), .XF(), .ML_n(),
    .VP_n(), .VDA(), .VPA(), .A(t65_0_a24), .DI(t65_0_i.di), .DO(t65_0_o.dout), .Regs(), .NMI_ack()
);
assign t65_0_o.a  = t65_0_a24[15:0];
assign t65_0_o.rw = t65_0_rw;

// riot6532_0: Rev 1 sound board RIOT (master riot6532)
chip_pool_pkg::riot6532_i_t riot6532_0_i;
chip_pool_pkg::riot6532_o_t riot6532_0_o;
riot6532 riot6532_0
(
    .clk(clk), .rst(riot6532_0_i.rst), .ce(riot6532_0_i.ce), .ram_cs(riot6532_0_i.ram_cs), .io_cs(riot6532_0_i.io_cs),
    .rw(riot6532_0_i.rw), .a(riot6532_0_i.a), .din(riot6532_0_i.din), .dout(riot6532_0_o.dout), .irq(riot6532_0_o.irq),
    .pa_i(riot6532_0_i.pa_i), .pa_pins(riot6532_0_o.pa_pins), .pb_i(riot6532_0_i.pb_i), .pb_pins(riot6532_0_o.pb_pins)
);

// sc01_0: Rev 1 speech board Votrax SC-01 / SC-01A; internal ROM = the vrom block above
chip_pool_pkg::sc01_i_t sc01_0_i;
chip_pool_pkg::sc01_o_t sc01_0_o;
sc01 sc01_0
(
    .clk(clk), .reset(sc01_0_i.reset), .mc(sc01_0_i.mc),
    .stb(sc01_0_i.stb), .phoneme(sc01_0_i.phoneme), .inflection(sc01_0_i.inflection), .ar(sc01_0_o.ar),
    .rom_a(vrom_a), .rom_q(vrom_d),
    .audio(sc01_0_o.audio), .sample(sc01_0_o.sample)
);

/////////////////////////////  Shared RAM pool  /////////////////////////////

//   block 0  4K  NVRAM (stored inverted)      A = 8088, B = MiSTer NVRAM
//   block 1  8K  work RAM                     A = 8088
//   block 2  1K  video RAM                    A = 8088, B = tile fetch
//   block 3  4K  character RAM                A = 8088, B = tile fetch
//   block 4 256  sprite RAM                   A = 8088, B = sprite engine
//   block 5  1K  background RAM (DMA copy)    A = DMA, B = scan
//   block 6 512  sprite line buffer           A = sprite engine, B = scan
localparam int RAM_BLOCKS = 7;
function automatic int ram_aw(input int b);
    case (b)
        0:       ram_aw = 12;
        1:       ram_aw = 13;
        2:       ram_aw = 10;
        3:       ram_aw = 12;
        4:       ram_aw = 8;
        5:       ram_aw = 10;
        default: ram_aw = 9;
    endcase
endfunction

ram_pool_pkg::pram_i_t [RAM_BLOCKS-1:0] main_pr_i, pool_i;
ram_pool_pkg::pram_o_t [RAM_BLOCKS-1:0] pool_o;
assign pool_i = main_pr_i;
genvar n;
generate
    for (n = 0; n < RAM_BLOCKS; n++) begin : rpool
        dpram_dc #(.widthad_a(ram_aw(n))) ram (
            .clock_a(clk), .address_a(pool_i[n].a_addr[ram_aw(n)-1:0]), .data_a(pool_i[n].a_d),
            .wren_a(pool_i[n].a_we), .q_a(pool_o[n].a_q),
            .clock_b(clk), .address_b(pool_i[n].b_addr[ram_aw(n)-1:0]), .data_b(pool_i[n].b_d),
            .wren_b(pool_i[n].b_we), .q_b(pool_o[n].b_q)
        );
    end
endgenerate

/////////////////////////////  Boards  /////////////////////////////

/////////////////////////////  Logic board  /////////////////////////////

logic [7:0] snd_cmd;
logic       snd_stb;

gottlieb_main main_b
(
    .clk(clk), .reset(reset), .pause(pause),
    .map_sel(map_sel), .out_mode(out_mode), .an_flags(an_flags), .no_wd(no_wd), .tile_cfg(tile_cfg),
    .mcl86_0_i(mcl86_0_i), .mcl86_0_o(mcl86_0_o), .pr_i(main_pr_i), .pr_o(pool_o),
    .in_dsw(in_dsw), .in1(in1), .in2(in2), .in3(in3), .in4(in4),
    .joy_p1(joy_p1), .joy_p2(joy_p2), .joy_p3(joy_p3), .track_h(track_h), .track_v(track_v),
    .rom_a(main_a), .rom_d(main_d),
    .nv_addr(nv_addr), .nv_din(nv_din), .nv_we(nv_we), .nv_dout(nv_dout),
    .snd_cmd(snd_cmd), .snd_stb(snd_stb), .knocker(knocker),
    .tile_rom_a(tile_a), .tile_rom_d(tile_d), .spr_rom_a(spr_a), .spr_rom_d(spr_d),
    .crt_flip(crt_flip), .h_adj(h_adj), .v_adj(v_adj),
    .ce_pix(ce_pix),
    .video_r(video_r), .video_g(video_g), .video_b(video_b),
    .video_hs(video_hs), .video_vs(video_vs), .video_hblank(video_hblank), .video_vblank(video_vblank)
);

/////////////////////////////  Sound boards  /////////////////////////////

logic signed [15:0] r1_audio, r2_audio;
wire rev1 = (snd_sel >= 3'd1 && snd_sel <= 3'd3);

gottlieb_snd_r1 snd_r1
(
    .clk(clk), .reset(reset | ~rev1), .pause(pause), .speech(snd_sel[1:0] - 2'd1),
    .cmd(snd_cmd), .cmd_stb(snd_stb),
    .t65_0_i(t65_0_i), .t65_0_o(t65_0_o), .riot6532_0_i(riot6532_0_i), .riot6532_0_o(riot6532_0_o),
    .sc01_0_i(sc01_0_i), .sc01_0_o(sc01_0_o),
    .rom_a(r1_a), .rom_d(snda_d),
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
