//  Based on MAME gottlieb.cpp (Fabrice Frances, Nicola Salmoria, Aaron Giles, BSD-3-Clause)
//  Bus side after the LaserdiscGames core's Mach 3 board (same logic board)
//  Copyright (C) 2026 Rodimus

module gottlieb_main
(
    input  logic        clk,
    input  logic        reset,
    input  logic        pause,
    input  logic  [1:0] map_sel,
    input  logic  [2:0] out_mode,
    input  logic  [1:0] an_flags,       // [0] IN2 = trackball H delta, [1] IN3 = trackball V delta
    input  logic        no_wd,
    input  logic  [2:0] tile_cfg,

    output chip_pool_pkg::mcl86_i_t mcl86_0_i,
    output ram_pool_pkg::pram_i_t [6:0] pr_i,
    input  ram_pool_pkg::pram_o_t [6:0] pr_o,
    input  chip_pool_pkg::mcl86_o_t mcl86_0_o,

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

    output logic [15:0] rom_a,
    input  logic  [7:0] rom_d,

    input  logic [11:0] nv_addr,
    input  logic  [7:0] nv_din,
    input  logic        nv_we,
    output logic  [7:0] nv_dout,

    output logic  [7:0] snd_cmd,
    output logic        snd_stb,
    output logic        knocker,

    output logic [12:0] tile_rom_a,
    input  logic  [7:0] tile_rom_d,
    output logic [13:0] spr_rom_a,
    input  logic [31:0] spr_rom_d,      // four planes, MSB plane in [31:24]

    input  logic        crt_flip,
    input  logic  [3:0] h_adj,
    input  logic  [3:0] v_adj,

    output logic        ce_pix,
    output logic  [7:0] video_r,
    output logic  [7:0] video_g,
    output logic  [7:0] video_b,
    output logic        video_hs,
    output logic        video_vs,
    output logic        video_hblank,
    output logic        video_vblank
);

logic       wd_reset, vblank_rise;
wire        req       = mcl86_0_o.req;
wire  [2:0] req_type  = mcl86_0_o.req_type;
wire [15:0] req_addr  = mcl86_0_o.req_addr[15:0];
wire  [7:0] req_wdata = mcl86_0_o.req_wdata;
logic [7:0] req_rdata;
logic       req_ack;

wire  cpu_reset = reset | wd_reset;
logic [2:0] clkdiv;
logic       cpu_clk;
always_ff @(posedge clk) begin
    if (cpu_reset) begin clkdiv <= 3'd0; cpu_clk <= 1'b0; end
    else if (!pause) begin
        clkdiv <= clkdiv + 3'd1;
        if (clkdiv == 3'd7) cpu_clk <= ~cpu_clk;
    end
end
assign mcl86_0_i.reset     = cpu_reset;
assign mcl86_0_i.cpu_clk   = cpu_clk;
assign mcl86_0_i.nmi       = vblank_rise & ~pause;
assign mcl86_0_i.intr      = 1'b0;
assign mcl86_0_i.req_rdata = req_rdata;
assign mcl86_0_i.req_ack   = req_ack;

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
        4'h5:         if (!a[11]) in_pal = 1; else if (!a[3]) in_io = 1;
        default:      in_rom   = 1;
    endcase
end

wire [2:0] io_a = a[2:0];
wire       wr   = req & req_ack & is_memwr;

assign rom_a = (a >= 16'h6000) ? a - 16'h6000 : a + 16'h9000;

logic [7:0] nv_q, ram_q, vram_q, chram_q;
logic [9:0] vram_va;
logic [11:0] chram_va;
logic [7:0] spram_va, vram_vd, chram_vd, spram_vd;

// NVRAM stored inverted on both ports: unloaded (BRAM powers up 00) it reads FF
logic [7:0] nv_qn, nv_doutn;
assign pr_i[0].a_addr = {3'd0, a[11:0]};
assign pr_i[0].a_d    = ~req_wdata;
assign pr_i[0].a_we   = wr & in_nv;
assign pr_i[0].b_addr = {3'd0, nv_addr};
assign pr_i[0].b_d    = ~nv_din;
assign pr_i[0].b_we   = nv_we;
assign nv_qn = pr_o[0].a_q;
assign nv_doutn = pr_o[0].b_q;
assign nv_q    = ~nv_qn;
assign nv_dout = ~nv_doutn;

wire [12:0] ram_a = a[12:0] - 13'h1000;
assign pr_i[1].a_addr = {2'd0, ram_a};
assign pr_i[1].a_d    = req_wdata;
assign pr_i[1].a_we   = wr & in_ram;
assign pr_i[1].b_addr = {2'd0, 13'd0};
assign pr_i[1].b_d    = 8'd0;
assign pr_i[1].b_we   = 1'b0;
assign ram_q = pr_o[1].a_q;

assign pr_i[2].a_addr = {5'd0, a[9:0]};
assign pr_i[2].a_d    = req_wdata;
assign pr_i[2].a_we   = wr & in_vram;
assign pr_i[2].b_addr = {5'd0, vram_va};
assign pr_i[2].b_d    = 8'd0;
assign pr_i[2].b_we   = 1'b0;
assign vram_q = pr_o[2].a_q;
assign vram_vd = pr_o[2].b_q;

assign pr_i[3].a_addr = {3'd0, a[11:0]};
assign pr_i[3].a_d    = req_wdata;
assign pr_i[3].a_we   = wr & in_chram;
assign pr_i[3].b_addr = {3'd0, chram_va};
assign pr_i[3].b_d    = 8'd0;
assign pr_i[3].b_we   = 1'b0;
assign chram_q = pr_o[3].a_q;
assign chram_vd = pr_o[3].b_q;

assign pr_i[4].a_addr = {7'd0, a[7:0]};
assign pr_i[4].a_d    = req_wdata;
assign pr_i[4].a_we   = wr & in_spr;
assign pr_i[4].b_addr = {7'd0, spram_va};
assign pr_i[4].b_d    = 8'd0;
assign pr_i[4].b_we   = 1'b0;
assign spram_vd = pr_o[4].b_q;

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

gottlieb_video video
(
    .clk(clk), .reset(reset), .pr_i(pr_i[6:5]), .pr_o(pr_o[6:5]),
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
