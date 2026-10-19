//============================================================================
//
//  Gottlieb Rev 1 sound board (MA-309 / speech MA-216): 6502, 6532 RIOT, 1408 DAC, optional Votrax SC-01 / SC-01A
//  Copyright (C) 2026 Rodimus
//
//  From the Q*bert manual A6 sheet (facts: Claude/gottlieb_schematic_facts.md); MAME shared/gottlieb_a.cpp agrees.
//  The 6502 is pooled in gottlieb_board (T65); this board supplies its enable, interrupts and read data.
//
//  Clock: 3.579545 MHz / 4 = 894.886 kHz (standard jumper E16-E17).
//  Decode (U4 74LS138 on A14-A12, A15 not decoded):
//    0 RIOT (A9 = 0 RAM 128, A9 = 1 I/O)   1 sound DAC   2 Votrax phoneme + inflection   3 Votrax clock DAC
//    4-5 expansion (unused)   6-7 ROM (8K, sound ROM pool A)   other reads float high
//  Command: no latch on this board (the main board's OP2 latch holds it). RIOT PA0-5 = ~cmd[5:0],
//  PA7 = NAND(cmd[3:0]) — its edge interrupt is how a new command is noticed. PB0-5 = SB1 (open), PB6 = TEST
//  button (open), PB7 = speech ready (A/R). NMI = speech ready (A/R) on speech boards, idle otherwise.
//
//============================================================================

module gottlieb_snd_r1
(
    input  logic        clk,            // 80 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic  [1:0] speech,         // 0 none, 1 SC-01 (Reactor), 2 SC-01A (Q*bert)

    input  logic  [7:0] cmd,
    input  logic        cmd_stb,

    // pooled 6502 (gottlieb_board)
    output logic        cpu_ce,
    output logic        cpu_rst,
    output logic        cpu_irq_n,
    output logic        cpu_nmi_n,
    input  logic [15:0] cpu_a,
    input  logic  [7:0] cpu_do,
    input  logic        cpu_rw,
    output logic  [7:0] cpu_di,

    output logic [12:0] rom_a,
    input  logic  [7:0] rom_d,
    output logic  [8:0] vrom_a,         // Votrax internal ROM (gottlieb_board, 1-clk read latency)
    input  logic  [7:0] vrom_d,

    output logic signed [15:0] audio
);

/////////////////////////////  894.886 kHz CPU enable  /////////////////////////////

// 80 MHz phase accumulator: 894886 * 2^32 / 80e6 = 48043728
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

/////////////////////////////  Decode  /////////////////////////////

wire [2:0] blk    = cpu_a[14:12];
wire       riot_s = (blk == 3'd0);
wire       wr     = cpu_ce & ~cpu_rw;
assign rom_a = cpu_a[12:0];

/////////////////////////////  RIOT  /////////////////////////////

logic [7:0] riot_q;
logic       riot_irq;
logic       ar;                         // speech ready (1 = ready)
wire  [7:0] pa_in = {~&cmd[3:0], 1'b1, ~cmd[5:0]};
wire  [7:0] pb_in = {(speech != 2'd0) ? ar : 1'b1, 1'b1, 6'h3F};

riot6532 riot
(
    .clk(clk), .rst(reset), .ce(cpu_ce),
    .ram_cs(riot_s & ~cpu_a[9]), .io_cs(riot_s & cpu_a[9]), .rw(cpu_rw), .a(cpu_a[6:0]),
    .din(cpu_do), .dout(riot_q), .irq(riot_irq),
    .pa_i(pa_in), .pa_pins(), .pb_i(pb_in), .pb_pins()
);

assign cpu_irq_n = ~riot_irq;
assign cpu_nmi_n = (speech != 2'd0) ? ~ar : 1'b1;
assign cpu_di    = riot_s ? riot_q : (blk[2:1] == 2'b11) ? rom_d : 8'hFF;

/////////////////////////////  Latches  /////////////////////////////

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

/////////////////////////////  Speech clock (Votrax master clock)  /////////////////////////////

// The 3000 DAC sets a current-controlled oscillator (schematic); MAME's linear guess is used until it is measured:
// f = 950000 + (d - 0xA0) * 5500 Hz, d clamped to >= 0x40. sp_mc = one master-clock enable at f.
wire  [7:0] d_cl = (sp_clk < 8'h40) ? 8'h40 : sp_clk;
wire [21:0] sp_f = 22'd950000 + {14'd0, d_cl} * 22'd5500 - 22'd880000;        // 0xA0 * 5500 = 880000
// enable increment = f * 2^32 / 80e6 = f * 53.687 = (f * 3518437) >> 16. Two register stages (f, then the product):
// the clock DAC changes ~33,000 times a second during Q*bert's sweeps and the multiply did not fit one 80 MHz clock.
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

// Votrax SC-01 / SC-01A (rtl/sound/sc01, port of MAME votrax.cpp). The phoneme comes straight off the data bus
// through the inverting U13 (~D5-D0), inflection from D7-D6 (MAME votrax_data_w). The two chips differ only in
// their internal ROM, which the MRA loads (votrsc01 / votrsc01a).
logic signed [15:0] sp_audio;
sc01 votrax
(
    .clk(clk), .reset(reset | (speech == 2'd0)), .mc(sp_mc),
    .stb(sp_stb), .phoneme(~cpu_do[5:0]), .inflection(cpu_do[7:6]), .ar(ar),
    .rom_a(vrom_a), .rom_q(vrom_d),
    .audio(sp_audio), .sample()
);

/////////////////////////////  DAC and output  /////////////////////////////

// 1408 unipolar DAC centred on 0x80, quarter scale (MAME route 0.25 / 0.20 with speech)
wire signed [15:0] dac_s = $signed({{3{~dac[7]}}, dac[6:0], 6'd0});

// The board's amplifier is AC-coupled: one-pole DC block, tau = 2^15 CPU clocks (37 ms, ~4 Hz) — Williams pattern
logic signed [31:0] dc;
always_ff @(posedge clk)
    if (reset) dc <= 32'sd0;
    else if (cpu_ce) dc <= dc + (($signed({dac_s, 16'd0}) - dc) >>> 15);
wire signed [15:0] dc_hi = dc[31:16];

// Speech level = MAME's speech/DAC balance, measured on Q*bert's power-on speech against a MAME WAV:
// at unity, speech and DAC are both ~1.2x MAME, so the balance is 61/64. Mixed in 24 bits, saturated to 16.
// The SC-01 output is a sample-and-hold at master/18 (~53 kHz): its images near 50 kHz fold into the audio band
// at 48 kHz. Anti-imaging low-pass, 4 one-pole stages at ~9 kHz run at 80 MHz / 208 = 384.6 kHz
// (k = 1 - exp(-2 pi 9k / 384.6k) = 35/256): ~-60 dB at 50 kHz, ~-1.8 dB at 3 kHz.
logic [7:0] lp_div;
// state s16.8 in 32 bits: (x - y) * 35 needs 25 + 6 bits of headroom. Each stage takes three slots of the 208-clock
// period (difference, product, add) so no subtract / multiply / add chain has to fit one 80 MHz clock.
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

localparam signed [23:0] SP_GAIN = 24'sd61;                     // speech gain, x/64
wire signed [23:0] sp_mix = (speech != 2'd0) ? (($signed({{8{sp_lp[15]}}, sp_lp}) * SP_GAIN) >>> 6) : 24'sd0;
wire signed [23:0] mix    = $signed({{8{dac_s[15]}}, dac_s}) - $signed({{8{dc_hi[15]}}, dc_hi}) + sp_mix;
assign audio = (mix > 24'sd32767) ? 16'sh7fff : (mix < -24'sd32768) ? -16'sh8000 : mix[15:0];
endmodule
