// Q*bert cabinet knocker (A-5195 solenoid hammering the wooden cabinet), synthesised - no samples.
//   15 noise bands: xorshift32 noise -> 4th-order Butterworth band-pass (2 DF1 sections) -> * envelope
//   (exponential decay per band; strike adds AMP, the recoil 124 ms later adds RAD)
//   + 8 decaying resonators (wood 845/912/1013/2334/2588 Hz, cabinet 86/150/222 Hz), coupled form.
// Model, fit and constants: tools/knocker_fit.py (bit-exact Python model; verilator/knocker checks it).
// fs = 80 MHz / 1664 = 48.077 kHz.  One shared 27x27 multiplier, 3-stage MAC: operand reg -> product reg
// -> accumulate reg; rounding/saturation always in a further register stage (80 MHz). 317 clocks of work
// per 1664-clock sample.  Resources: 1 DSP (27x27), 2 M10K (state RAM 256x27, coef ROM 256x27).
// Retrigger while ringing = superposition (envelopes add, resonators get another impulse); the recoil is
// scheduled 124 ms after the latest strike.  Output is exactly 0 from 2 s after the last strike.
// pause: no new samples, audio holds its last value, all state frozen; trig edges are not sampled.
module knocker
(
    input  logic        clk,        // 80 MHz
    input  logic        reset,
    input  logic        pause,      // freeze the sound (hold state) while paused
    input  logic        trig,       // knocker solenoid drive (level); a rising edge = one knock
    output logic signed [15:0] audio,
    output logic        sample       // 1-clk pulse per output sample
);

`include "knocker_coef.svh"


function automatic logic signed [26:0] sat27(input logic signed [57:0] v);
    if (v > 58'sd67108863)       sat27 = 27'sh3ffffff;
    else if (v < -58'sd67108864) sat27 = -27'sh4000000;
    else                         sat27 = v[26:0];
endfunction

function automatic logic signed [15:0] sat16(input logic signed [59:0] v);
    if (v > 60'sd32767)       sat16 = 16'sh7fff;
    else if (v < -60'sd32768) sat16 = -16'sh8000;
    else                      sat16 = v[15:0];
endfunction

function automatic logic [31:0] xorshift(input logic [31:0] x);
    logic [31:0] a, b;
    a = x ^ (x << 13);
    b = a ^ (a >> 17);
    xorshift = b ^ (b << 5);
endfunction

// ---------------------------------------------------------------------------------------------
// sample timing, trigger, event counters
// ---------------------------------------------------------------------------------------------
logic [10:0] div;
logic        clr;                  // post-reset state-RAM clear
logic  [7:0] clr_a;
logic        trig_d, pend;
logic        strike_s, recoil_s, act_s;
logic [12:0] rcnt;                 // samples to the recoil
logic [16:0] acnt;                 // samples to idle
wire         edge_t = !pause && trig && !trig_d;
wire         go     = !clr && !pause && (div == 11'd0);

// ---------------------------------------------------------------------------------------------
// sequencer
// ---------------------------------------------------------------------------------------------
localparam logic [1:0] PH_IDLE = 2'd0, PH_BAND = 2'd1, PH_MODE = 2'd2, PH_OUT = 2'd3;
// MAC ops: INITR acc = p + 2^24 (round-half-up at >>25), INIT0 acc = p, ADD acc += p, OADD oacc += p
localparam logic [2:0] M_NOP = 3'd0, M_INITR = 3'd1, M_INIT0 = 3'd2, M_ADD = 3'd3, M_OADD = 3'd4;

logic  [1:0] ph;
logic  [3:0] idx;                  // band 0..14 / mode 0..7
logic  [3:0] st;
logic        par;                  // sample parity: x[n-2] / y[n-2] slot

// state RAM: band b {0,b,slot}: 0/1 N[par], 2/3 Y1[par], 4/5 Y2[par], 6 E;  mode m: {1,000,m,j} j 0 C, 1 S
// the core's proven RAM wrapper (dpram_dc, altsyncram), 32 bits wide (27 is not a whole number of byte lanes);
// 1-clk registered read like the original inferred block. A same-address read and write in one clock is undefined
// on Cyclone V, so the sim checks it never happens.
logic        [7:0]  ra;
logic signed [26:0] sram_q;
logic               w_en;
logic        [7:0]  w_a;
logic signed [26:0] w_d;
logic        [31:0] sram_q32;

dpram_dc #(.widthad_a(8), .width_a(32)) u_state
(
    .clock_a(clk), .address_a(w_a), .data_a({{5{w_d[26]}}, w_d}), .wren_a(w_en), .q_a(),
    .clock_b(clk), .address_b(ra), .data_b(32'd0), .wren_b(1'b0), .q_b(sram_q32)
);
assign sram_q = $signed(sram_q32[26:0]);

`ifdef VERILATOR
always_ff @(posedge clk) if (w_en && !clr && w_a == ra) $error("knocker: state RAM read and write of %0d in one clock", w_a);   // the post-reset clear ignores reads
`endif

logic        [7:0]  ca;
logic signed [26:0] coef_q;
knocker_rom rom (.clk(clk), .addr(ca), .q(coef_q));

wire [7:0] rb = {1'b0, idx, 3'd0};
wire [7:0] rm = {4'b1000, idx[2:0], 1'b0};
wire [7:0] cb = {idx, 4'd0};
wire [7:0] cm = {1'b0, idx[2:0], 4'b1100};

always_comb begin
    ra = 8'd0;
    ca = 8'd0;
    if (ph == PH_BAND) begin
        case (st)
            4'd0: begin ra = rb | {7'd0,  par}; ca = cb | 8'd0; end    // N[n-2]   / G1
            4'd1: begin ra = rb | {7'd1, ~par}; ca = cb | 8'd1; end    // Y1[n-1]  / NA11
            4'd2: begin ra = rb | {7'd1,  par}; ca = cb | 8'd2; end    // Y1[n-2]  / NA12
            4'd3: begin ra = rb | {7'd2, ~par}; ca = cb | 8'd3; end    // Y2[n-1]  / G2
            4'd4: begin ra = rb | {7'd2,  par}; ca = cb | 8'd4; end    // Y2[n-2]  / NA21
            4'd5: begin ra = rb | 8'd6;         ca = cb | 8'd5; end    // E        / NA22
            4'd6: ca = cb | 8'd6;                                      // AMP
            4'd7: ca = cb | 8'd7;                                      // RAD
            4'd8: ca = cb | 8'd8;                                      // D
            default: ;
        endcase
    end else if (ph == PH_MODE) begin
        case (st)
            4'd0: begin ra = rm;         ca = cm | 8'd0; end           // C / RC
            4'd1: begin ra = rm | 8'd1;  ca = cm | 8'd1; end           // S / RS
            4'd2: ca = cm | 8'd2;                                      // -RS
            4'd3: ca = cm | 8'd3;                                      // GM
            default: ;
        endcase
    end
end

// MAC
logic signed [26:0] opa, opb;
logic        [2:0]  mop, mop1;
logic signed [53:0] prod;
logic signed [57:0] acc;
logic signed [59:0] oacc;
wire  signed [57:0] prod58 = {{4{prod[53]}}, prod};

always_ff @(posedge clk) begin
    prod <= opa * opb;
    mop1 <= mop;
    case (mop1)
        M_INITR: acc  <= prod58 + 58'sd16777216;
        M_INIT0: acc  <= prod58;
        M_ADD:   acc  <= acc + prod58;
        M_OADD:  oacc <= oacc + {{6{prod[53]}}, prod};
        default: ;
    endcase
    if (ph == PH_OUT && st == 4'd1) oacc <= 60'sd0;      // never coincides with an OADD
    if (reset) begin
        mop1 <= M_NOP;
        oacc <= 60'sd0;
    end
end

// per-step registers
logic        [31:0] x;             // noise
logic signed [26:0] r_y1m2, r_y2m1, r_y2m2, r_g2, r_na21, r_na22, r_d, r_y, r_s, r_rc, r_rs, r_nrs, r_cn;
logic signed [28:0] r_e, r_c;
logic signed [59:0] r_t;           // output rounding
logic signed [57:0] r_tm;          // resonator trunc-toward-0

wire signed [26:0] nz    = {{3{x[31]}}, x[31:16], 8'd0};                // Q24 +-0.5
wire signed [27:0] y1dif = {r_y[26], r_y} - {r_y1m2[26], r_y1m2};
wire signed [57:0] acc_t = acc + (acc[57] ? 58'sd33554431 : 58'sd0);    // trunc toward 0 pre-add

always_ff @(posedge clk) begin
    sample <= 1'b0;
    w_en   <= 1'b0;
    mop    <= M_NOP;

    // trigger edge -> pending strike (consumed at the next sample start)
    if (!pause) trig_d <= trig;
    if (go) begin
        strike_s <= pend;
        recoil_s <= (rcnt == 13'd1);
        act_s    <= pend || (acnt > 17'd1);
        if (pend)              rcnt <= KN_RECOIL_N;
        else if (rcnt != 13'd0) rcnt <= rcnt - 13'd1;
        if (pend)              acnt <= KN_IDLE_N;
        else if (acnt != 17'd0) acnt <= acnt - 17'd1;
        pend     <= edge_t;
    end else if (edge_t)
        pend <= 1'b1;

    if (!clr && !pause) div <= (div == KN_DIV_M1) ? 11'd0 : div + 11'd1;

    if (clr) begin
        w_en  <= 1'b1;
        w_a   <= clr_a;
        w_d   <= 27'sd0;
        clr_a <= clr_a + 8'd1;
        if (clr_a == 8'd255) clr <= 1'b0;
    end

    case (ph)
        PH_IDLE: if (go) begin ph <= PH_BAND; idx <= 4'd0; st <= 4'd0; end

        PH_BAND: begin
            st <= st + 4'd1;
            case (st)
                4'd0:  x <= xorshift(x);
                4'd1:  begin
                           opa <= nz - sram_q; opb <= coef_q; mop <= M_INITR;
                           w_en <= 1'b1; w_a <= rb | {7'd0, par}; w_d <= nz;
                       end
                4'd2:  begin opa <= sram_q; opb <= coef_q; mop <= M_ADD; end
                4'd3:  begin r_y1m2 <= sram_q; opa <= sram_q; opb <= coef_q; mop <= M_ADD; end
                4'd4:  begin r_y2m1 <= sram_q; r_g2 <= coef_q; end
                4'd5:  begin r_y2m2 <= sram_q; r_na21 <= coef_q; end
                4'd6:  begin r_e <= {2'b00, sram_q}; r_na22 <= coef_q; r_y <= sat27(acc >>> 25); end
                4'd7:  begin
                           w_en <= 1'b1; w_a <= rb | {7'd1, par}; w_d <= r_y;
                           opa <= (y1dif > 28'sd67108863) ? 27'sh3ffffff :
                                  (y1dif < -28'sd67108864) ? -27'sh4000000 : y1dif[26:0];
                           opb <= r_g2; mop <= M_INITR;
                           if (strike_s) r_e <= r_e + {{2{coef_q[26]}}, coef_q};
                       end
                4'd8:  begin
                           opa <= r_y2m1; opb <= r_na21; mop <= M_ADD;
                           if (recoil_s) r_e <= r_e + {{2{coef_q[26]}}, coef_q};
                       end
                4'd9:  begin
                           opa <= r_y2m2; opb <= r_na22; mop <= M_ADD;
                           r_d <= coef_q;
                           if (r_e > 29'sd67108863) r_e <= 29'sd67108863;
                       end
                4'd10: begin opa <= r_e[26:0]; opb <= r_d; end                 // E decay (product read at 12)
                4'd12: begin
                           r_y  <= sat27(acc >>> 25);
                           w_en <= 1'b1; w_a <= rb | 8'd6; w_d <= prod[51:25];   // E <= floor(e*D >> 25)
                       end
                4'd13: begin
                           w_en <= 1'b1; w_a <= rb | {7'd2, par}; w_d <= r_y;
                           opa <= r_y; opb <= r_e[26:0]; mop <= M_OADD;
                           st  <= 4'd0;
                           if (idx == 4'd14) begin ph <= PH_MODE; idx <= 4'd0; end
                           else idx <= idx + 4'd1;
                       end
                default: ;
            endcase
        end

        PH_MODE: begin
            st <= st + 4'd1;
            case (st)
                4'd1:  begin
                           r_c  <= {{2{sram_q[26]}}, sram_q} + (strike_s ? {{2{KN_IMP[26]}}, KN_IMP} : 29'sd0);
                           r_rc <= coef_q;
                       end
                4'd2:  begin
                           r_s <= sram_q; r_rs <= coef_q;
                           if (r_c > 29'sd67108863)       r_c <= 29'sd67108863;
                           else if (r_c < -29'sd67108864) r_c <= -29'sd67108864;
                       end
                4'd3:  begin r_nrs <= coef_q; opa <= r_c[26:0]; opb <= r_rc; mop <= M_INIT0; end
                4'd4:  begin opa <= r_s; opb <= coef_q; mop <= M_OADD; end       // out += s*GM
                4'd5:  begin opa <= r_s; opb <= r_nrs; mop <= M_ADD; end        // c' = rc*c - rs*s
                4'd6:  begin opa <= r_c[26:0]; opb <= r_rs; mop <= M_INIT0; end
                4'd7:  begin opa <= r_s; opb <= r_rc; mop <= M_ADD; end         // s' = rs*c + rc*s
                4'd8:  r_tm <= acc_t;
                4'd9:  r_cn <= sat27(r_tm >>> 25);
                4'd10: r_tm <= acc_t;
                4'd11: begin
                           w_en <= 1'b1; w_a <= rm; w_d <= r_cn;
                           r_cn <= sat27(r_tm >>> 25);
                       end
                4'd12: begin
                           w_en <= 1'b1; w_a <= rm | 8'd1; w_d <= r_cn;
                           st <= 4'd0;
                           if (idx == 4'd7) ph <= PH_OUT;
                           else idx <= idx + 4'd1;
                       end
                default: ;
            endcase
        end

        default: begin  // PH_OUT
            st <= st + 4'd1;
            if (st == 4'd0) r_t <= oacc + 60'sd268435456;
            else begin
                audio  <= act_s ? sat16(r_t >>> 29) : 16'sd0;
                sample <= 1'b1;
                par    <= ~par;
                ph     <= PH_IDLE;
                st     <= 4'd0;
            end
        end
    endcase

    if (reset) begin
        div      <= 11'd0;
        clr      <= 1'b1;
        clr_a    <= 8'd0;
        trig_d   <= trig;
        pend     <= 1'b0;
        strike_s <= 1'b0;
        recoil_s <= 1'b0;
        act_s    <= 1'b0;
        rcnt     <= 13'd0;
        acnt     <= 17'd0;
        ph       <= PH_IDLE;
        idx      <= 4'd0;
        st       <= 4'd0;
        par      <= 1'b0;
        x        <= KN_SEED;
        audio    <= 16'sd0;
        sample   <= 1'b0;
        w_en     <= 1'b0;
        mop      <= M_NOP;
    end
end

endmodule
