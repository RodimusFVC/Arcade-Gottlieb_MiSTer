//  Based on MAME gottlieb.cpp (Fabrice Frances, Nicola Salmoria, Aaron Giles, BSD-3-Clause)
//  Sprite engine shape after the LaserdiscGames core's mach3_video.sv
//  Copyright (C) 2026 Rodimus

module gottlieb_video
(
    output ram_pool_pkg::pram_i_t [1:0] pr_i,
    input  ram_pool_pkg::pram_o_t [1:0] pr_o,
    input  logic        clk,
    input  logic        reset,

    input  logic        bg_priority,
    input  logic        flip_x,
    input  logic        flip_y,
    input  logic        spritebank,
    input  logic  [2:0] tile_cfg,

    input  logic        pal_we,
    input  logic  [4:0] pal_wa,
    input  logic  [7:0] pal_wd,

    output logic  [9:0] vram_a,
    input  logic  [7:0] vram_d,
    output logic [11:0] chram_a,
    input  logic  [7:0] chram_d,
    output logic  [7:0] spram_a,
    input  logic  [7:0] spram_d,

    output logic [12:0] tile_rom_a,
    input  logic  [7:0] tile_rom_d,
    output logic [13:0] spr_rom_a,
    input  logic [31:0] spr_rom_d,      // MSB plane in [31:24]

    input  logic        crt_flip,
    input  logic  [3:0] h_adj,
    input  logic  [3:0] v_adj,

    output logic        ce_pix,
    output logic        vblank_rise,
    output logic  [7:0] video_r,
    output logic  [7:0] video_g,
    output logic  [7:0] video_b,
    output logic        video_hs,
    output logic        video_vs,
    output logic        video_hblank,
    output logic        video_vblank
);

logic [3:0] div;
always_ff @(posedge clk) div <= reset ? 4'd0 : div + 4'd1;
always_ff @(posedge clk) ce_pix <= (div == 4'd15);

logic [8:0] hc;
logic [7:0] vc;
always_ff @(posedge clk) begin
    if (reset) begin
        hc <= 9'd0; vc <= 8'd0;
    end else if (ce_pix) begin
        if (hc == 9'd317) begin
            hc <= 9'd0;
            vc <= vc + 8'd1;
        end else hc <= hc + 9'd1;
    end
end

wire [7:0] vc_c = (crt_flip ^ flip_y) ? 8'd239 - vc : vc;
wire [7:0] hh = hc[7:0] ^ {8{flip_x ^ crt_flip}};
wire [7:0] vv = vc_c;

wire       dma_win = (vc[7:3] == 5'b11110) && !hc[8];
wire [9:0] dma_a   = {vc[2:0], hc[7:1]};
assign vram_a = dma_a;

logic [7:0] bg_q;
logic [7:0] bg_ra;
assign pr_i[0].a_addr = {5'd0, dma_a};
assign pr_i[0].a_d    = vram_d;
assign pr_i[0].a_we   = dma_win && div == 4'd4;
assign pr_i[0].b_addr = {5'd0, {vv[7:3], hh[7:3]}};
assign pr_i[0].b_d    = 8'd0;
assign pr_i[0].b_we   = 1'b0;
assign bg_q = pr_o[0].b_q;

logic [7:0] code;
logic       use_rom;
always_ff @(posedge clk) if (div == 4'd3) code <= bg_q;
wire hi_half = tile_cfg[2] ? (code[7:6] != 2'b00) : code[7];
always_comb use_rom = hi_half ? tile_cfg[1] : tile_cfg[0];
assign tile_rom_a = {code, vv[2:0], hh[2:1]};
assign chram_a    = {code[6:0], vv[2:0], hh[2:1]};

logic [3:0] bg_pen;
always_ff @(posedge clk) if (div == 4'd6) begin
    if (use_rom) bg_pen <= hh[0] ? tile_rom_d[3:0] : tile_rom_d[7:4];
    else         bg_pen <= hh[0] ? chram_d[3:0]    : chram_d[7:4];
end

logic        bank;
logic  [7:0] line_q;
wire   [7:0] next_vv = (crt_flip ^ flip_y) ? 8'd237 - vc : vc + 8'd2;

typedef enum logic [3:0] {S_IDLE, S_CLR, S_R0, S_R1, S_R2, S_CHK, S_ROM0, S_ROM1, S_EMIT, S_NEXT} st_t;
st_t         st;
logic  [7:0] clr_i;
logic  [5:0] spr_i;
logic  [1:0] spram_sel;
logic  [1:0] wait_c;
logic signed [9:0] s_y;
logic  [9:0] s_x;
logic  [8:0] s_code;
logic  [3:0] s_row;
logic        half;
logic [31:0] pl_l, pl_r;
logic  [3:0] emit_i;
logic        lb_we;
logic  [8:0] lb_wa;
logic  [3:0] lb_wd;

assign spram_a   = {spr_i, spram_sel};
assign spr_rom_a = {s_code, s_row, half};

wire signed [9:0] row_s = $signed({2'b00, line_q}) - s_y;
wire [31:0] pl       = emit_i[3] ? pl_r : pl_l;
wire  [2:0] bi       = 3'd7 - emit_i[2:0];
wire  [3:0] emit_pen = {pl[{2'd3, bi}], pl[{2'd2, bi}], pl[{2'd1, bi}], pl[{2'd0, bi}]};
wire  [9:0] emit_x   = s_x + {6'd0, emit_i};

always_ff @(posedge clk) begin
    lb_we <= 1'b0;
    if (reset) begin
        st <= S_IDLE; bank <= 1'b0; line_q <= 8'd0; clr_i <= 8'd0; spr_i <= 6'd0; spram_sel <= 2'd0; wait_c <= 2'd0;
    end else case (st)
        S_IDLE: if (ce_pix && hc == 9'd317) begin
            line_q <= next_vv; bank <= ~bank; clr_i <= 8'd0; st <= S_CLR;
        end
        S_CLR: begin
            lb_we <= 1'b1; lb_wa <= {bank, clr_i}; lb_wd <= 4'd0;
            if (clr_i == 8'hFF) begin spr_i <= 6'd0; spram_sel <= 2'd0; wait_c <= 2'd0; st <= S_R0; end
            else clr_i <= clr_i + 8'd1;
        end
        S_R0: if (wait_c != 2'd1) wait_c <= wait_c + 2'd1;
              else begin s_y <= $signed({2'b00, spram_d}) - (flip_y ? 10'sd10 : 10'sd13); spram_sel <= 2'd1; wait_c <= 2'd0; st <= S_R1; end
        S_R1: if (wait_c != 2'd1) wait_c <= wait_c + 2'd1;
              else begin s_x <= {2'b00, spram_d} + (flip_x ? 10'd3 : -10'd4); spram_sel <= 2'd2; wait_c <= 2'd0; st <= S_R2; end
        S_R2: if (wait_c != 2'd1) wait_c <= wait_c + 2'd1;
              else begin s_code <= {spritebank, ~spram_d}; wait_c <= 2'd0; st <= S_CHK; end
        S_CHK: if (row_s >= 10'sd0 && row_s < 10'sd16) begin
                   s_row <= row_s[3:0]; half <= 1'b0; wait_c <= 2'd0; st <= S_ROM0;
               end else st <= S_NEXT;
        S_ROM0: if (wait_c != 2'd1) wait_c <= wait_c + 2'd1;
                else begin pl_l <= spr_rom_d; half <= 1'b1; wait_c <= 2'd0; st <= S_ROM1; end
        S_ROM1: if (wait_c != 2'd1) wait_c <= wait_c + 2'd1;
                else begin pl_r <= spr_rom_d; emit_i <= 4'd0; st <= S_EMIT; end
        S_EMIT: begin
            if (emit_pen != 4'd0 && emit_x < 10'd256 && emit_x >= 10'd8) begin
                lb_we <= 1'b1; lb_wa <= {bank, emit_x[7:0]}; lb_wd <= emit_pen;
            end
            if (emit_i == 4'd15) st <= S_NEXT;
            else emit_i <= emit_i + 4'd1;
        end
        S_NEXT: if (spr_i == 6'd63) st <= S_IDLE;
                else begin spr_i <= spr_i + 6'd1; spram_sel <= 2'd0; wait_c <= 2'd0; st <= S_R0; end
        default: st <= S_IDLE;
    endcase
end

logic [7:0] lb_q;
assign pr_i[1].a_addr = {6'd0, lb_wa};
assign pr_i[1].a_d    = {4'd0, lb_wd};
assign pr_i[1].a_we   = lb_we;
assign pr_i[1].b_addr = {6'd0, {~bank, hh}};
assign pr_i[1].b_d    = 8'd0;
assign pr_i[1].b_we   = 1'b0;
assign lb_q = pr_o[1].b_q;
logic [3:0] spr_pen;
always_ff @(posedge clk) if (div == 4'd3) spr_pen <= lb_q[3:0];

logic [7:0] pal[32];
always_ff @(posedge clk) if (pal_we) pal[pal_wa] <= pal_wd;

function automatic [7:0] dac(input [3:0] v);
    case (v)
        4'h0: dac = 8'd0;   4'h1: dac = 8'd16;  4'h2: dac = 8'd33;  4'h3: dac = 8'd49;
        4'h4: dac = 8'd70;  4'h5: dac = 8'd86;  4'h6: dac = 8'd102; 4'h7: dac = 8'd119;
        4'h8: dac = 8'd136; 4'h9: dac = 8'd153; 4'hA: dac = 8'd169; 4'hB: dac = 8'd185;
        4'hC: dac = 8'd206; 4'hD: dac = 8'd222; 4'hE: dac = 8'd239; default: dac = 8'd255;
    endcase
endfunction

wire [3:0] pen = bg_priority ? (bg_pen  != 4'd0 ? bg_pen  : spr_pen)
                             : (spr_pen != 4'd0 ? spr_pen : bg_pen);
logic [23:0] rgb;
always_ff @(posedge clk) if (div == 4'd8) rgb <= {dac(pal[{pen, 1'b1}][3:0]), dac(pal[{pen, 1'b0}][7:4]), dac(pal[{pen, 1'b0}][3:0])};

wire [8:0] hs_start = 9'd272 + {{5{h_adj[3]}}, h_adj};
wire [7:0] vs_start = 8'd244 + {{4{v_adj[3]}}, v_adj};

logic vbl_q;
always_ff @(posedge clk) if (div == 4'd15) begin
    video_hblank <= hc[8];
    video_vblank <= (vc >= 8'd240);
    video_hs     <= (hc >= hs_start) && (hc < hs_start + 9'd24);
    video_vs     <= (vc >= vs_start) && (vc < vs_start + 8'd4);
    {video_r, video_g, video_b} <= (hc[8] || vc >= 8'd240) ? 24'd0 : rgb;
end
always_ff @(posedge clk) begin
    vbl_q       <= video_vblank;
    vblank_rise <= video_vblank & ~vbl_q;
end

endmodule
