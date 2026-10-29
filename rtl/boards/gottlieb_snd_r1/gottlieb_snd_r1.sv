//  Based on MAME gottlieb_a.cpp (Aaron Giles, BSD-3-Clause)
//  Copyright (C) 2026 Rodimus

module gottlieb_snd_r1
(
    input  logic        clk,
    input  logic        reset,
    input  logic        pause,
    input  logic  [1:0] speech,

    input  logic  [7:0] cmd,
    input  logic        cmd_stb,

    output chip_pool_pkg::t65_i_t      t65_0_i,
    input  chip_pool_pkg::t65_o_t      t65_0_o,
    output chip_pool_pkg::riot6532_i_t riot6532_0_i,
    input  chip_pool_pkg::riot6532_o_t riot6532_0_o,
    output chip_pool_pkg::sc01_i_t     sc01_0_i,
    input  chip_pool_pkg::sc01_o_t     sc01_0_o,

    output logic [12:0] rom_a,
    input  logic  [7:0] rom_d,

    output logic signed [15:0] audio
);

logic        cpu_ce, cpu_rst, cpu_irq_n, cpu_nmi_n;
logic  [7:0] cpu_di;
wire  [15:0] cpu_a  = t65_0_o.a;
wire   [7:0] cpu_do = t65_0_o.dout;
wire         cpu_rw = t65_0_o.rw;
assign t65_0_i.res_n  = ~cpu_rst;
assign t65_0_i.enable = cpu_ce;
assign t65_0_i.rdy    = 1'b1;
assign t65_0_i.irq_n  = cpu_irq_n;
assign t65_0_i.nmi_n  = cpu_nmi_n;
assign t65_0_i.di     = cpu_di;

logic [31:0] ph;
logic        ph_c;
always_ff @(posedge clk) begin
    if (reset) begin ph <= 32'd0; cpu_ce <= 1'b0; end
    else begin
        {ph_c, ph} <= {1'b0, ph} + 33'd48043728;
        cpu_ce     <= ph_c & ~pause;
    end
end
assign cpu_rst = reset;

wire [2:0] blk    = cpu_a[14:12];
wire       riot_s = (blk == 3'd0);
wire       wr     = cpu_ce & ~cpu_rw;
assign rom_a = cpu_a[12:0];

logic [7:0] riot_q;
logic       riot_irq;
logic       ar;
wire  [7:0] pa_in = {~&cmd[3:0], 1'b1, ~cmd[5:0]};
wire  [7:0] pb_in = {(speech != 2'd0) ? ar : 1'b1, 1'b1, 6'h3F};

assign riot6532_0_i.rst    = reset;
assign riot6532_0_i.ce     = cpu_ce;
assign riot6532_0_i.ram_cs = riot_s & ~cpu_a[9];
assign riot6532_0_i.io_cs  = riot_s & cpu_a[9];
assign riot6532_0_i.rw     = cpu_rw;
assign riot6532_0_i.a      = cpu_a[6:0];
assign riot6532_0_i.din    = cpu_do;
assign riot6532_0_i.pa_i   = pa_in;
assign riot6532_0_i.pb_i   = pb_in;
assign riot_q   = riot6532_0_o.dout;
assign riot_irq = riot6532_0_o.irq;

assign cpu_irq_n = ~riot_irq;
assign cpu_nmi_n = (speech != 2'd0) ? ~ar : 1'b1;
assign cpu_di    = riot_s ? riot_q : (blk[2:1] == 2'b11) ? rom_d : 8'hFF;

logic [7:0] dac, sp_data, sp_clk;
always_ff @(posedge clk) begin
    if (reset) begin dac <= 8'h80; sp_data <= 8'h00; sp_clk <= 8'h00; end
    else if (wr) case (blk)
        3'd1: dac     <= cpu_do;
        3'd2: sp_data <= cpu_do;
        3'd3: sp_clk  <= cpu_do;
        default: ;
    endcase
end
wire sp_stb = wr && blk == 3'd2;

wire  [7:0] d_cl = (sp_clk < 8'h40) ? 8'h40 : sp_clk;
wire [21:0] sp_f = 22'd950000 + {14'd0, d_cl} * 22'd5500 - 22'd880000;
// two register stages: the clock-DAC multiply does not fit one 80 MHz clock
logic [21:0] sp_f_r;
logic [43:0] sp_inc_r;
logic [31:0] sp_ph;
logic        sp_c, sp_mc;
always_ff @(posedge clk) begin
    sp_f_r   <= sp_f;
    sp_inc_r <= sp_f_r * 22'd3518437;
    if (reset) begin sp_ph <= 32'd0; sp_mc <= 1'b0; end
    else begin
        {sp_c, sp_ph} <= {1'b0, sp_ph} + {5'd0, sp_inc_r[43:16]};
        sp_mc         <= sp_c & ~pause;
    end
end

logic signed [15:0] sp_audio;
assign sc01_0_i.reset      = reset | (speech == 2'd0);
assign sc01_0_i.mc         = sp_mc;
assign sc01_0_i.stb        = sp_stb;
assign sc01_0_i.phoneme    = ~cpu_do[5:0];
assign sc01_0_i.inflection = cpu_do[7:6];
assign ar       = sc01_0_o.ar;
assign sp_audio = sc01_0_o.audio;

wire signed [15:0] dac_s = $signed({{3{~dac[7]}}, dac[6:0], 6'd0});

logic signed [31:0] dc;
always_ff @(posedge clk)
    if (reset) dc <= 32'sd0;
    else if (cpu_ce) dc <= dc + (($signed({dac_s, 16'd0}) - dc) >>> 15);
wire signed [15:0] dc_hi = dc[31:16];

logic [7:0] lp_div;
logic signed [31:0] lp1, lp2, lp3, lp4, lp_d, lp_x;
wire  signed [31:0] lp_in = {{8{sp_audio[15]}}, sp_audio, 8'd0};
always_ff @(posedge clk) begin
    if (reset) begin lp_div <= 8'd0; lp1 <= 32'sd0; lp2 <= 32'sd0; lp3 <= 32'sd0; lp4 <= 32'sd0; lp_d <= 32'sd0; lp_x <= 32'sd0; end
    else begin
        lp_div <= (lp_div == 8'd207) ? 8'd0 : lp_div + 8'd1;
        case (lp_div)
            8'd0:  lp_x <= lp_in - lp1;
            8'd1:  lp_d <= lp_x * 32'sd35;
            8'd2:  lp1  <= lp1 + (lp_d >>> 8);
            8'd3:  lp_x <= lp1 - lp2;
            8'd4:  lp_d <= lp_x * 32'sd35;
            8'd5:  lp2  <= lp2 + (lp_d >>> 8);
            8'd6:  lp_x <= lp2 - lp3;
            8'd7:  lp_d <= lp_x * 32'sd35;
            8'd8:  lp3  <= lp3 + (lp_d >>> 8);
            8'd9:  lp_x <= lp3 - lp4;
            8'd10: lp_d <= lp_x * 32'sd35;
            8'd11: lp4  <= lp4 + (lp_d >>> 8);
            default: ;
        endcase
    end
end
wire signed [15:0] sp_lp = lp4[23:8];

localparam signed [23:0] SP_GAIN = 24'sd61;
wire signed [23:0] sp_mix = (speech != 2'd0) ? (($signed({{8{sp_lp[15]}}, sp_lp}) * SP_GAIN) >>> 6) : 24'sd0;
wire signed [23:0] mix    = $signed({{8{dac_s[15]}}, dac_s}) - $signed({{8{dc_hi[15]}}, dc_hi}) + sp_mix;
assign audio = (mix > 24'sd32767) ? 16'sh7fff : (mix < -24'sd32768) ? -16'sh8000 : mix[15:0];
endmodule
