//============================================================================
//
//  Gottlieb GG-III logic board (8088 system): address decode, RAM, I/O, watchdog, video
//  Copyright (C) 2026 Rodimus
//
//  Bus side carried over from the LaserdiscGames core's Mach 3 board (same logic board, HW-proven).
//  MAME reference: gottlieb/gottlieb.cpp (reactor_map, gottlieb_*_map).
//
//  map_sel (MRA index 1 byte 148):
//    0 RAM map      0000-0FFF NVRAM, 1000-2FFF RAM              (Q*bert, Mad Planets, most sets)
//    1 ROM map      0000-0FFF NVRAM, 1000-2FFF ROM              (Krull, Argus)
//    2 RAM+ROM map  0000-0FFF NVRAM, 1000-1FFF RAM, 2000-2FFF ROM (3 Stooges, Video Vince)
//    3 Reactor      0000-1FFF RAM, 2000 sprites, 3000 video RAM, 4000 char RAM, 6000 palette, 7000 I/O, 8000-FFFF ROM
//  Maps 0-2 share:  3000-37FF sprite RAM (256, write-only), 3800-3FFF video RAM (1K), 4000-4FFF char RAM (4K),
//                   5000-57FF palette (32), 5800-5FFF I/O (8, only with A3 = 0), 6000-FFFF ROM.
//
//  I/O (a[2:0]): read  0 DSW, 1 IN1, 2 IN2 (trackball H), 3 IN3 (trackball V), 4 IN4
//                write 0 watchdog, 1 analog (trackball) reset, 2 sound command, 3 outputs
//  Outputs (out_mode, byte 151): bits 0-2 video control (BG priority, flip X, flip Y) on every game;
//    1 Q*bert: bit 5 knocker   2 Qubes: bit 4 sprite bank   3 3 Stooges: bits 6-5 joystick select
//
//  Main ROM pool address (48K image): CPU 6000-FFFF -> 0000-9FFF, CPU 1000-2FFF -> A000-BFFF.
//
//============================================================================

module gottlieb_main
(
    input  logic        clk,            // 80 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic  [1:0] map_sel,
    input  logic  [2:0] out_mode,
    input  logic  [1:0] an_flags,       // [0] IN2 = trackball H delta, [1] IN3 = trackball V delta
    input  logic        no_wd,
    input  logic  [2:0] tile_cfg,       // [0] codes 00-7F from ROM, [1] codes 80-FF from ROM, [2] split at C0 (Screw Loose)

    // 8088 bus (dl2_bus request / acknowledge)
    input  logic        req,
    input  logic  [2:0] req_type,
    input  logic [15:0] req_addr,
    input  logic  [7:0] req_wdata,
    output logic  [7:0] req_rdata,
    output logic        req_ack,
    output logic        wd_reset,       // watchdog: CPU reset request

    // inputs (already assembled to the board's polarity)
    input  logic  [7:0] in_dsw,
    input  logic  [7:0] in1,
    input  logic  [7:0] in2,
    input  logic  [7:0] in3,
    input  logic  [7:0] in4,
    input  logic  [3:0] joy_p1,         // 3 Stooges multiplexed sticks, active high {L, D, R, U}
    input  logic  [3:0] joy_p2,
    input  logic  [3:0] joy_p3,
    input  logic  [7:0] track_h,        // free-running trackball / dial position counters
    input  logic  [7:0] track_v,

    // main program ROM (pool in gottlieb_board)
    output logic [15:0] rom_a,
    input  logic  [7:0] rom_d,

    // NVRAM second port (MiSTer load / save)
    input  logic [11:0] nv_addr,
    input  logic  [7:0] nv_din,
    input  logic        nv_we,
    output logic  [7:0] nv_dout,

    // sound board command
    output logic  [7:0] snd_cmd,
    output logic        snd_stb,
    output logic        knocker,

    // graphics ROMs (pools in gottlieb_board)
    output logic [12:0] tile_rom_a,
    input  logic  [7:0] tile_rom_d,
    output logic [13:0] spr_rom_a,
    input  logic [31:0] spr_rom_d,      // four planes, MSB plane in [31:24]

    input  logic        crt_flip,
    input  logic  [3:0] h_adj,
    input  logic  [3:0] v_adj,

    output logic        ce_pix,
    output logic        vblank_rise,    // NMI tick
    output logic  [7:0] video_r,
    output logic  [7:0] video_g,
    output logic  [7:0] video_b,
    output logic        video_hs,
    output logic        video_vs,
    output logic        video_hblank,
    output logic        video_vblank
);

/////////////////////////////  Decode  /////////////////////////////

wire [15:0] a       = req_addr;
wire        reactor = (map_sel == 2'd3);
wire        is_code  = (req_type == 3'b100);
wire        is_memrd = (req_type == 3'b101) | is_code;
wire        is_memwr = (req_type == 3'b110);

logic in_nv, in_ram, in_spr, in_vram, in_chram, in_pal, in_io, in_rom;
always_comb begin
    in_nv = 0; in_ram = 0; in_spr = 0; in_vram = 0; in_chram = 0; in_pal = 0; in_io = 0; in_rom = 0;
    if (reactor) case (a[15:12])
        4'h0:         in_nv    = 1;
        4'h1:         in_ram   = 1;
        4'h2:         in_spr   = 1;
        4'h3:         in_vram  = 1;
        4'h4:         in_chram = 1;
        4'h6:         in_pal   = 1;
        4'h7:         in_io    = 1;
        4'h5:         ;
        default:      in_rom   = 1;
    endcase
    else case (a[15:12])
        4'h0:         in_nv    = 1;
        4'h1:         if (map_sel == 2'd1) in_rom = 1; else in_ram = 1;
        4'h2:         if (map_sel == 2'd0) in_ram = 1; else in_rom = 1;
        4'h3:         if (a[11]) in_vram = 1; else in_spr = 1;
        4'h4:         in_chram = 1;
        4'h5:         if (!a[11]) in_pal = 1; else if (!a[3]) in_io = 1;   // I/O needs A3 = 0 (Q*bert A1 sheet; MAME mirrors wider)
        default:      in_rom   = 1;
    endcase
end

wire [2:0] io_a = a[2:0];
wire       wr   = req & req_ack & is_memwr;

assign rom_a = (a >= 16'h6000) ? a - 16'h6000 : a + 16'h9000;

/////////////////////////////  RAM  /////////////////////////////

logic [7:0] nv_q, ram_q, vram_q, chram_q;
logic [9:0] vram_va;
logic [11:0] chram_va;
logic [7:0] spram_va, vram_vd, chram_vd, spram_vd;

dpram_dc #(.widthad_a(12)) u_nvram
(
    .clock_a(clk), .address_a(a[11:0]), .data_a(req_wdata), .wren_a(wr & in_nv), .q_a(nv_q),
    .clock_b(clk), .address_b(nv_addr), .data_b(nv_din), .wren_b(nv_we), .q_b(nv_dout)
);

// 1000-2FFF (Reactor 1000-1FFF)
wire [12:0] ram_a = a[12:0] - 13'h1000;
dpram_dc #(.widthad_a(13)) u_ram
(
    .clock_a(clk), .address_a(ram_a), .data_a(req_wdata), .wren_a(wr & in_ram), .q_a(ram_q),
    .clock_b(clk), .address_b(13'd0), .data_b(8'd0), .wren_b(1'b0), .q_b()
);

dpram_dc #(.widthad_a(10)) u_vram
(
    .clock_a(clk), .address_a(a[9:0]), .data_a(req_wdata), .wren_a(wr & in_vram), .q_a(vram_q),
    .clock_b(clk), .address_b(vram_va), .data_b(8'd0), .wren_b(1'b0), .q_b(vram_vd)
);

dpram_dc #(.widthad_a(12)) u_chram
(
    .clock_a(clk), .address_a(a[11:0]), .data_a(req_wdata), .wren_a(wr & in_chram), .q_a(chram_q),
    .clock_b(clk), .address_b(chram_va), .data_b(8'd0), .wren_b(1'b0), .q_b(chram_vd)
);

// sprite RAM is write-only to the CPU
dpram_dc #(.widthad_a(8)) u_spram
(
    .clock_a(clk), .address_a(a[7:0]), .data_a(req_wdata), .wren_a(wr & in_spr), .q_a(),
    .clock_b(clk), .address_b(spram_va), .data_b(8'd0), .wren_b(1'b0), .q_b(spram_vd)
);

/////////////////////////////  Watchdog  /////////////////////////////

// Cleared by a write to I/O 0; 16 VBLANKs without one reset the CPU. Frozen while paused.
logic [4:0] wd_cnt;
logic [7:0] wd_hold;
always_ff @(posedge clk) begin
    if (reset) begin
        wd_cnt <= 5'd0; wd_hold <= 8'd0;
    end else begin
        if (wd_hold != 8'd0) wd_hold <= wd_hold - 8'd1;
        if (wr && in_io && io_a == 3'd0) wd_cnt <= 5'd0;
        else if (vblank_rise && !pause && !no_wd) begin
            if (wd_cnt == 5'd15) begin wd_cnt <= 5'd0; wd_hold <= 8'hFF; end
            else wd_cnt <= wd_cnt + 5'd1;
        end
    end
end
assign wd_reset = (wd_hold != 8'd0);

/////////////////////////////  Outputs, sound, analog  /////////////////////////////

logic [7:0] out_r;
logic [7:0] tb_ref_h, tb_ref_v;
always_ff @(posedge clk) begin
    snd_stb <= 1'b0;
    if (reset) begin
        out_r <= 8'd0; snd_cmd <= 8'hFF; tb_ref_h <= 8'd0; tb_ref_v <= 8'd0;
    end else if (wr && in_io) case (io_a)
        3'd1: begin tb_ref_h <= track_h; tb_ref_v <= track_v; end
        3'd2: begin snd_cmd <= req_wdata; snd_stb <= 1'b1; end
        3'd3: out_r <= req_wdata;
        default: ;
    endcase
end

wire       bg_priority = out_r[0];
wire       flip_x      = out_r[1];
wire       flip_y      = out_r[2];
wire       spritebank  = (out_mode == 3'd2) & out_r[4];
assign     knocker     = (out_mode == 3'd1) & out_r[5];
wire [1:0] joy_sel     = (out_mode == 3'd3) ? out_r[6:5] : 2'd3;

/////////////////////////////  I/O read  /////////////////////////////

logic [3:0] joy_mux;
always_comb case (joy_sel)
    2'd0:    joy_mux = joy_p2;
    2'd1:    joy_mux = joy_p3;
    2'd2:    joy_mux = joy_p1;
    default: joy_mux = 4'hF;
endcase

logic [7:0] io_q;
always_comb case (io_a)
    3'd0:    io_q = in_dsw;
    3'd1:    io_q = in1;
    3'd2:    io_q = an_flags[0] ? track_h - tb_ref_h : in2;
    3'd3:    io_q = an_flags[1] ? track_v - tb_ref_v : in3;
    3'd4:    io_q = (out_mode == 3'd3) ? {in4[7:4], joy_mux} : in4;
    default: io_q = 8'hFF;
endcase

/////////////////////////////  Bus response  /////////////////////////////

// dpram_dc registers its address: a read is valid the clock after it is presented.
logic mem_wait;
always_ff @(posedge clk) begin
    req_ack <= 1'b0;
    if (reset) begin
        req_rdata <= 8'hFF; mem_wait <= 1'b0;
    end else begin
        if (!req) mem_wait <= 1'b0;
        if (req && !req_ack) begin
            if (in_io && is_memrd) begin
                req_rdata <= io_q; req_ack <= 1'b1;
            end else if (is_memwr || in_io) begin
                req_ack <= 1'b1;
            end else if (is_memrd) begin
                if (!mem_wait) mem_wait <= 1'b1;
                else begin
                    req_rdata <= in_rom   ? rom_d   :
                                 in_nv    ? nv_q    :
                                 in_ram   ? ram_q   :
                                 in_vram  ? vram_q  :
                                 in_chram ? chram_q :
                                 8'hFF;
                    req_ack <= 1'b1;
                end
            end else begin
                req_rdata <= 8'hFF; req_ack <= 1'b1;
            end
        end
    end
end

/////////////////////////////  Video  /////////////////////////////

gottlieb_video video
(
    .clk(clk), .reset(reset),
    .bg_priority(bg_priority), .flip_x(flip_x), .flip_y(flip_y), .spritebank(spritebank), .tile_cfg(tile_cfg),
    .pal_we(wr & in_pal), .pal_wa(a[4:0]), .pal_wd(req_wdata),
    .vram_a(vram_va), .vram_d(vram_vd), .chram_a(chram_va), .chram_d(chram_vd), .spram_a(spram_va), .spram_d(spram_vd),
    .tile_rom_a(tile_rom_a), .tile_rom_d(tile_rom_d), .spr_rom_a(spr_rom_a), .spr_rom_d(spr_rom_d),
    .crt_flip(crt_flip), .h_adj(h_adj), .v_adj(v_adj),
    .ce_pix(ce_pix), .vblank_rise(vblank_rise),
    .video_r(video_r), .video_g(video_g), .video_b(video_b),
    .video_hs(video_hs), .video_vs(video_vs), .video_hblank(video_hblank), .video_vblank(video_vblank)
);

endmodule
