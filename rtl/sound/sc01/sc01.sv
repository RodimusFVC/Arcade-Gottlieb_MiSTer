//  Based on MAME votrax.cpp (Olivier Galibert, BSD-3-Clause)
// Port of MAME src/devices/sound/votrax.cpp (BSD-3-Clause, Olivier Galibert): digital part
// license:BSD-3-Clause  copyright-holders:Olivier Galibert (MAME votrax.cpp: algorithm, constants).

module sc01
#(
    parameter int CLK_HZ = 80_000_000
)
(
    input  logic        clk,
    input  logic        reset,
    input  logic        mc,
    input  logic        stb,
    input  logic  [5:0] phoneme,
    input  logic  [1:0] inflection,
    output logic        ar,
    output logic  [8:0] rom_a,
    input  logic  [7:0] rom_q,
    output logic signed [15:0] audio,
    output logic        sample
);

`include "sc01_coef.svh"

logic  [5:0] phone_r;
logic  [1:0] infl_r;

typedef enum logic [1:0] { SC_IDLE, SC_SRCH, SC_FETCH } scan_t;
scan_t       sst;
logic  [5:0] sidx, sidx_d;
logic        sval, slast;
logic  [5:0] fidx;
logic  [2:0] fcnt;
logic        fval;
logic  [2:0] fcnt_d;
logic [39:0] fword;
logic [43:0] stg_word;
logic        stg_found;
logic        scan_go;

assign rom_a = (sst == SC_FETCH) ? {fidx, fcnt} : {sidx, 3'd7};

always_ff @(posedge clk) begin
    if (reset) begin
        sst       <= SC_IDLE;
        sidx      <= 6'd0;
        sidx_d    <= 6'd0;
        sval      <= 1'b0;
        slast     <= 1'b0;
        fidx      <= 6'd0;
        fcnt      <= 3'd0;
        fcnt_d    <= 3'd0;
        fval      <= 1'b0;
        fword     <= 40'd0;
        stg_word  <= 44'd0;
        stg_found <= 1'b0;
    end else if (scan_go) begin
        sst   <= SC_SRCH;
        sidx  <= 6'd0;
        sval  <= 1'b0;
        slast <= 1'b0;
    end else begin
        case (sst)
            SC_SRCH: begin
                sidx   <= sidx + 6'd1;
                sidx_d <= sidx;
                sval   <= 1'b1;
                slast  <= (sidx == 6'd63);
                if (sval && rom_q[5:0] == phone_r) begin
                    sst  <= SC_FETCH;
                    fidx <= sidx_d;
                    fcnt <= 3'd0;
                    fval <= 1'b0;
                end else if (sval && slast) begin
                    sst       <= SC_IDLE;
                    stg_found <= 1'b0;
                end
            end
            SC_FETCH: begin
                fcnt   <= fcnt + 3'd1;
                fcnt_d <= fcnt;
                fval   <= 1'b1;
                if (fval && fcnt_d != 3'd5) fword[fcnt_d*8 +: 8] <= rom_q;
                if (fval && fcnt_d == 3'd5) begin
                    sst       <= SC_IDLE;
                    stg_word  <= {rom_q[3:0], fword};
                    stg_found <= 1'b1;
                end
            end
            default: ;
        endcase
    end
end

wire scan_busy = (sst != SC_IDLE) || scan_go;

wire [3:0] d_f1  = {stg_word[ 0], stg_word[ 7], stg_word[14], stg_word[21]};
wire [3:0] d_va  = {stg_word[ 1], stg_word[ 8], stg_word[15], stg_word[22]};
wire [3:0] d_f2  = {stg_word[ 2], stg_word[ 9], stg_word[16], stg_word[23]};
wire [3:0] d_fc  = {stg_word[ 3], stg_word[10], stg_word[17], stg_word[24]};
wire [3:0] d_f2q = {stg_word[ 4], stg_word[11], stg_word[18], stg_word[25]};
wire [3:0] d_f3  = {stg_word[ 5], stg_word[12], stg_word[19], stg_word[26]};
wire [3:0] d_fa  = {stg_word[ 6], stg_word[13], stg_word[20], stg_word[27]};
wire [3:0] d_cld = {stg_word[34], stg_word[32], stg_word[30], stg_word[28]};
wire [3:0] d_vd  = {stg_word[35], stg_word[33], stg_word[31], stg_word[29]};
wire       d_cl  = stg_word[36];
wire [6:0] d_dur = ~{stg_word[37], stg_word[38], stg_word[39], stg_word[40], stg_word[41], stg_word[42], stg_word[43]};

logic [6:0] rom_duration;
logic [3:0] rom_vd, rom_cld, rom_fa, rom_fc, rom_va, rom_f1, rom_f2, rom_f2q, rom_f3;
logic       rom_closure, rom_pause;
logic [7:0] cur_fa, cur_fc, cur_va, cur_f1, cur_f2, cur_f2q, cur_f3;
logic [3:0] filt_fa, filt_fc, filt_va, filt_f1, filt_f2q, filt_f3;
logic [4:0] filt_f2;
logic [8:0] phonetick;
logic [4:0] ticks;
logic [7:0] pitch;
logic [4:0] closure;
logic [5:0] update_counter;
logic       cur_closure;
logic [14:0] noise;
logic       cur_noise;

function automatic logic [7:0] interp(input logic [7:0] r, input logic [3:0] t);
    interp = r - {3'd0, r[7:3]} + {3'd0, t, 1'b0};
endfunction

logic [8:0] n_phonetick;
logic [4:0] n_ticks;
logic       n_cur_closure;
logic [5:0] n_uc;
logic [7:0] n_cur_fa, n_cur_fc, n_cur_va, n_cur_f1, n_cur_f2, n_cur_f2q, n_cur_f3;
logic [4:0] n_closure;
logic [7:0] n_pitch;
logic       n_fcommit;
logic [14:0] n_noise;
logic       n_cur_noise;
logic       tick_625, tick_208, n_inp;
logic [8:0] pitch_cmp;

always_comb begin
    n_phonetick   = phonetick;
    n_ticks       = ticks;
    n_cur_closure = cur_closure;
    if (ticks != 5'h10) begin
        n_phonetick = phonetick + 9'd1;
        if (n_phonetick == {rom_duration, 2'b01}) begin
            n_phonetick = 9'd0;
            n_ticks     = ticks + 5'd1;
            if (n_ticks == {1'b0, rom_vd})
                n_cur_closure = rom_closure;
        end
    end

    n_uc = (update_counter == 6'd47) ? 6'd0 : update_counter + 6'd1;
    tick_625 = (n_uc[3:0] == 4'd0);
    tick_208 = (n_uc == 6'h28);

    n_cur_f1 = cur_f1; n_cur_f2 = cur_f2; n_cur_f2q = cur_f2q; n_cur_f3 = cur_f3;
    n_cur_fa = cur_fa; n_cur_fc = cur_fc; n_cur_va = cur_va;
    if (tick_208 && (!rom_pause || !((filt_fa != 4'd0) || (filt_va != 4'd0)))) begin
        n_cur_f1  = interp(cur_f1,  rom_f1);
        n_cur_f2  = interp(cur_f2,  rom_f2);
        n_cur_f2q = interp(cur_f2q, rom_f2q);
        n_cur_f3  = interp(cur_f3,  rom_f3);
    end
    if (tick_625) begin
        if (n_ticks >= {1'b0, rom_vd}) begin
            n_cur_fa = interp(cur_fa, rom_fa);
            n_cur_fc = interp(cur_fc, rom_fc);
        end
        if (n_ticks >= {1'b0, rom_cld})
            n_cur_va = interp(cur_va, rom_va);
    end

    if (!n_cur_closure && ((filt_fa != 4'd0) || (filt_va != 4'd0)))
        n_closure = 5'd0;
    else if (closure != 5'd28)
        n_closure = closure + 5'd1;
    else
        n_closure = closure;

    // 9-bit compare: (0xe0 ^ (infl<<5) ^ (f1<<1)) + 2 can be 0x100, which an 8-bit pitch never hits
    pitch_cmp = {1'b0, 8'he0 ^ {1'b0, infl_r, 5'd0} ^ {3'd0, filt_f1, 1'b0}} + 9'd2;
    n_pitch = pitch + 8'd1;
    if ({1'b0, n_pitch} == pitch_cmp)
        n_pitch = 8'd0;
    n_fcommit = ((n_pitch & 8'hf9) == 8'h08);

    n_inp       = cur_noise && (noise != 15'h7fff);
    n_noise     = {noise[13:0], n_inp};
    n_cur_noise = !(n_noise[14] ^ n_noise[13]);
end

localparam logic [1:0] T_NONE = 2'd0, T_COMMIT = 2'd1, T_END = 2'd2;

logic        ready;
logic        init_scan;
logic  [1:0] tparam;
logic [19:0] tleft;
logic        commit_req;
logic  [4:0] phase;
logic        samp_req;
logic        scnt;
logic        seq_go;
logic        seq_busy;

wire do_commit = commit_req && !scan_busy;

always_ff @(posedge clk) begin
    scan_go <= 1'b0;
    seq_go  <= 1'b0;
    if (reset) begin
        ready      <= 1'b0;
        init_scan  <= 1'b1;
        phone_r    <= 6'h3f;
        infl_r     <= 2'd0;
        ar         <= 1'b1;
        tparam     <= T_NONE;
        tleft      <= 20'd0;
        commit_req <= 1'b0;
        phase      <= 5'd0;
        samp_req   <= 1'b0;
        scnt       <= 1'b0;
        rom_duration <= 7'd0;
        {rom_vd, rom_cld, rom_fa, rom_fc, rom_va, rom_f1, rom_f2, rom_f2q, rom_f3} <= 36'd0;
        rom_closure <= 1'b0;
        rom_pause   <= 1'b0;
        {cur_fa, cur_fc, cur_va, cur_f1, cur_f2, cur_f2q, cur_f3} <= 56'd0;
        {filt_fa, filt_fc, filt_va, filt_f1, filt_f2q, filt_f3} <= 24'd0;
        filt_f2     <= 5'd0;
        phonetick   <= 9'd0;
        ticks       <= 5'd0;
        pitch       <= 8'd0;
        closure     <= 5'd0;
        update_counter <= 6'd0;
        cur_closure <= 1'b1;
        noise       <= 15'd0;
        cur_noise   <= 1'b0;
    end else if (!ready) begin
        if (init_scan) begin
            init_scan <= 1'b0;
            scan_go   <= 1'b1;
        end else if (!scan_busy) begin
            if (stg_found) begin
                rom_f1 <= d_f1; rom_va <= d_va; rom_f2 <= d_f2; rom_fc <= d_fc; rom_f2q <= d_f2q;
                rom_f3 <= d_f3; rom_fa <= d_fa; rom_cld <= d_cld; rom_vd <= d_vd;
                rom_closure <= d_cl; rom_duration <= d_dur;
            end
            rom_pause <= 1'b0;
            ready     <= 1'b1;
        end
    end else begin
        if (mc) begin
            if (tparam != T_NONE) begin
                if (tleft == 20'd1) begin
                    if (tparam == T_COMMIT) commit_req <= 1'b1;
                    else                    ar <= 1'b1;
                    tparam <= T_NONE;
                end else
                    tleft <= tleft - 20'd1;
            end
            if (phase == 5'd17) begin
                phase    <= 5'd0;
                samp_req <= 1'b1;
            end else
                phase <= phase + 5'd1;
        end

        if (do_commit) begin
            commit_req <= 1'b0;
            phonetick  <= 9'd0;
            ticks      <= 5'd0;
            if (stg_found) begin
                rom_f1 <= d_f1; rom_va <= d_va; rom_f2 <= d_f2; rom_fc <= d_fc; rom_f2q <= d_f2q;
                rom_f3 <= d_f3; rom_fa <= d_fa; rom_cld <= d_cld; rom_vd <= d_vd;
                rom_closure  <= d_cl;
                rom_duration <= d_dur;
                rom_pause    <= (phone_r == 6'h03) || (phone_r == 6'h3e);
                if (d_vd == 4'd0) cur_closure <= d_cl;
            end
            if (tparam != T_COMMIT) begin
                tparam <= T_END;
                tleft  <= {2'd0, stg_found ? d_dur : rom_duration, 11'd0} + {5'd0, stg_found ? d_dur : rom_duration, 8'd0} + 20'd578;
            end
        end

        if (samp_req && !commit_req && !do_commit && !seq_busy) begin
            samp_req <= 1'b0;
            scnt     <= ~scnt;
            seq_go   <= 1'b1;
            if (!scnt) begin
                phonetick      <= n_phonetick;
                ticks          <= n_ticks;
                cur_closure    <= n_cur_closure;
                update_counter <= n_uc;
                cur_f1 <= n_cur_f1; cur_f2 <= n_cur_f2; cur_f2q <= n_cur_f2q; cur_f3 <= n_cur_f3;
                cur_fa <= n_cur_fa; cur_fc <= n_cur_fc; cur_va <= n_cur_va;
                closure <= n_closure;
                pitch   <= n_pitch;
                if (n_fcommit) begin
                    filt_fa  <= n_cur_fa[7:4];
                    filt_fc  <= n_cur_fc[7:4];
                    filt_va  <= n_cur_va[7:4];
                    filt_f1  <= n_cur_f1[7:4];
                    filt_f2  <= n_cur_f2[7:3];
                    filt_f2q <= n_cur_f2q[7:4];
                    filt_f3  <= n_cur_f3[7:4];
                end
                noise     <= n_noise;
                cur_noise <= n_cur_noise;
            end
        end

        if (stb) begin
            phone_r <= phoneme;
            infl_r  <= inflection;
            ar      <= 1'b0;
            scan_go <= 1'b1;
            if (tparam != T_COMMIT) begin
                tparam <= T_COMMIT;
                tleft  <= 20'd72;
            end
        end
    end
end

localparam logic [63:0] CLK64  = 64'd1 * CLK_HZ;
// CLK_HZ in 64 bits (no SV size cast for Quartus 17)
localparam logic [63:0] G_STEP = (NS_G_NUM + CLK64/64'd2) / CLK64;
localparam logic [63:0] E_STEP = (NS_E_NUM + CLK64/64'd2) / CLK64;
localparam int          MAXI_I = CLK_HZ / 150000;
localparam logic [9:0]  MAXI   = MAXI_I[9:0];
localparam int          WEND_I = NS_WIN - 1;
localparam logic [8:0]  WEND   = WEND_I[8:0];

logic [51:0] gacc;
logic [43:0] eacc;
logic  [9:0] ivcnt;
logic  [8:0] wcnt;
logic        wbad, wfirst;
logic signed [26:0] ns_g, ns_r;
wire  [51:0] gacc_n = gacc + G_STEP[51:0];
wire  [43:0] eacc_n = eacc + E_STEP[43:0];
wire  [26:0] gacc_s = gacc_n[NS_SH +: 27];
wire  [19:0] eacc_s = eacc_n[NS_SH +: 20];
wire         iv_slow = (ivcnt > MAXI);

always_ff @(posedge clk) begin
    if (reset) begin
        gacc   <= 52'd0;
        eacc   <= 44'd0;
        ivcnt  <= 10'd0;
        wcnt   <= 9'd0;
        wbad   <= 1'b0;
        wfirst <= 1'b1;
        ns_g   <= NS_G_DEF;
        ns_r   <= NS_R_DEF;
    end else begin
        gacc <= gacc_n;
        eacc <= eacc_n;
        if (ivcnt != 10'h3ff) ivcnt <= ivcnt + 10'd1;
        if (mc) begin
            ivcnt <= 10'd0;
            if (iv_slow) wbad <= 1'b1;
            if (wfirst || wcnt == WEND) begin
                wcnt   <= 9'd0;
                wfirst <= 1'b0;
                gacc   <= 52'd0;
                eacc   <= 44'd0;
                wbad   <= 1'b0;
                if (!wfirst && !wbad && !iv_slow) begin
                    ns_g <= gacc_s;
                    ns_r <= {7'd0, eacc_s} - 27'sd33554432;
                end
            end else
                wcnt <= wcnt + 9'd1;
        end
    end
end

logic signed [23:0] hv1 [4];
logic signed [23:0] hv2 [4];
logic signed [23:0] hv3 [3];
logic signed [23:0] hn1 [2];
logic signed [23:0] hn2;
logic signed [23:0] hn3 [2];
logic signed [23:0] hn4;
logic signed [23:0] hvn1 [4];
logic signed [23:0] hvn2 [3];
logic signed [23:0] hvn3 [3];
logic signed [23:0] hvn4 [2];
logic signed [23:0] hvn5;
logic signed [23:0] hvn6;

function automatic logic signed [26:0] sx(input logic signed [23:0] v);
    sx = {{3{v[23]}}, v};
endfunction

function automatic logic signed [23:0] sat24(input logic signed [57:0] v);
    if (v > 58'sd8388607)       sat24 = 24'sh7fffff;
    else if (v < -58'sd8388608) sat24 = -24'sh800000;
    else                        sat24 = v[23:0];
endfunction

localparam logic signed [23:0] ONE = 24'sd524288;

localparam logic [1:0] I_ACC = 2'd0, I_CLR = 2'd1, I_LD = 2'd2;
localparam logic [3:0] W_V1 = 4'd0, W_V2 = 4'd1, W_V3 = 4'd2, W_N1 = 4'd3, W_N2 = 4'd4, W_N3 = 4'd5,
                       W_N4 = 4'd6, W_VN1 = 4'd7, W_VN2 = 4'd8, W_VN3 = 4'd9, W_VN4 = 4'd10,
                       W_VN5 = 4'd11, W_VN6 = 4'd12, W_OUT = 4'd13;

logic  [5:0] pc;
logic  [1:0] ph;
logic        p_wb;
logic  [3:0] p_tgt;
logic signed [26:0] p_a;
logic [12:0] p_c;
logic        p_breg;
logic        p_bsel;
logic  [1:0] p_init;
logic signed [26:0] p_ld;
logic        p_sub;
logic        p_last;
logic  [2:0] p_res;
logic        p_out;
localparam logic [2:0] R_NONE = 3'd0, R_F1 = 3'd1, R_F2V = 3'd2, R_F3 = 3'd3, R_F4 = 3'd4;

wire [12:0] A_F2   = {1'b0, filt_f2, filt_f2q, 3'd0};
wire [12:0] A_F1   = {7'b1000000, filt_f1, 2'd0};
wire [12:0] A_F3   = {7'b1000001, filt_f3, 2'd0};
localparam logic [12:0] A_MISC = 13'd4224, A_FR15 = 13'd4240, A_FR7 = 13'd4256;

logic signed [23:0] glot;
always_comb begin
    case (pitch[7:3])
        5'd0: glot = GLOT0;  5'd1: glot = GLOT1;  5'd2: glot = GLOT2;
        5'd3: glot = GLOT3;  5'd4: glot = GLOT4;  5'd5: glot = GLOT5;
        5'd6: glot = GLOT6;  5'd7: glot = GLOT7;  5'd8: glot = GLOT8;
        default: glot = 24'sd0;
    endcase
end

always_comb begin
    p_wb = 1'b0; p_tgt = W_V1; p_a = 27'sd0; p_c = 13'd0; p_breg = 1'b0; p_bsel = 1'b0;
    p_init = I_ACC; p_ld = 27'sd0; p_sub = 1'b0; p_last = 1'b0; p_res = R_NONE; p_out = 1'b0;
    case (pc)
        6'd0:  begin p_a = sx(glot); p_c = A_FR15 + {9'd0, filt_va}; p_init = I_CLR; end
        6'd1:  begin p_wb = 1'b1; p_tgt = W_V1; end
        6'd2:  begin p_a = sx(hv1[0]) + (sx(hv1[1]) <<< 1) + sx(hv1[2]); p_c = A_F1;
                     p_init = I_LD; p_ld = -sx(hv2[0]); p_res = R_F1; end
        6'd3:  begin p_a = sx(hv1[1]) + (sx(hv1[2]) <<< 1) + sx(hv1[3]); p_c = A_F1 + 13'd1; end
        6'd4:  begin p_a = sx(hv2[0]) + sx(hv2[1]); p_c = A_F1 + 13'd2; p_sub = 1'b1; end
        6'd5:  begin p_a = sx(hv2[1]) + sx(hv2[2]); p_c = A_F1 + 13'd3; p_sub = 1'b1; end
        6'd6:  begin p_wb = 1'b1; p_tgt = W_V2; end
        6'd7:  begin p_a = sx(hv2[0]) + (sx(hv2[1]) <<< 1) + sx(hv2[2]); p_c = A_F2;
                     p_init = I_LD; p_ld = -sx(hv3[0]); p_res = R_F2V; end
        6'd8:  begin p_a = sx(hv2[1]) + (sx(hv2[2]) <<< 1) + sx(hv2[3]); p_c = A_F2 + 13'd1; end
        6'd9:  begin p_a = sx(hv3[0]) + sx(hv3[1]); p_c = A_F2 + 13'd2; p_sub = 1'b1; end
        6'd10: begin p_a = sx(hv3[1]) + sx(hv3[2]); p_c = A_F2 + 13'd3; p_sub = 1'b1; end
        6'd11: begin p_wb = 1'b1; p_tgt = W_V3; end
        6'd12: begin p_a = (pitch[6] && cur_noise) ? sx(ONE) : -sx(ONE); p_c = A_FR15 + {9'd0, filt_fa};
                     p_init = I_CLR; end
        6'd13: begin p_wb = 1'b1; p_tgt = W_N1; end
        6'd14: begin p_a = sx(hn1[0]) + sx(hn1[1]); p_breg = 1'b1; p_bsel = 1'b0; p_init = I_CLR; end
        6'd15: begin p_a = sx(hn2); p_breg = 1'b1; p_bsel = 1'b1; end
        6'd16: begin p_wb = 1'b1; p_tgt = W_N2; end
        6'd17: begin p_a = sx(hn2); p_c = A_FR15 + {9'd0, filt_fc}; p_init = I_CLR; end
        6'd18: begin p_wb = 1'b1; p_tgt = W_N3; end
        6'd19: begin p_a = sx(hn3[0]); p_c = A_F2 + 13'd4; p_init = I_CLR; end
        6'd20: begin p_a = sx(hn3[1]); p_c = A_F2 + 13'd5; end
        6'd21: begin p_a = sx(hn4);    p_c = A_F2 + 13'd6; p_sub = 1'b1; end
        6'd22: begin p_wb = 1'b1; p_tgt = W_N4; end
        6'd23: begin p_a = 27'sd0; p_c = A_MISC; p_init = I_LD; p_ld = sx(hv3[0]) + sx(hn4); end
        6'd24: begin p_wb = 1'b1; p_tgt = W_VN1; end
        6'd25: begin p_a = sx(hvn1[0]) + (sx(hvn1[1]) <<< 1) + sx(hvn1[1]) + (sx(hvn1[2]) <<< 1) + sx(hvn1[2]) + sx(hvn1[3]);
                     p_c = A_F3; p_init = I_LD; p_ld = -sx(hvn2[0]); p_res = R_F3; end
        6'd26: begin p_a = sx(hvn2[0]) + sx(hvn2[1]); p_c = A_F3 + 13'd1; p_sub = 1'b1; end
        6'd27: begin p_a = sx(hvn2[1]) + sx(hvn2[2]); p_c = A_F3 + 13'd2; p_sub = 1'b1; end
        6'd28: begin p_wb = 1'b1; p_tgt = W_VN2; end
        6'd29: begin p_a = sx(hn2); p_c = A_FR15 + {9'd0, filt_fc ^ 4'hf}; p_init = I_LD; p_ld = sx(hvn2[0]); end
        6'd30: begin p_wb = 1'b1; p_tgt = W_VN3; end
        6'd31: begin p_a = sx(hvn3[0]) + (sx(hvn3[1]) <<< 1) + sx(hvn3[2]); p_c = A_MISC; p_init = I_CLR; p_res = R_F4; end
        6'd32: begin p_a = sx(hvn4[0]); p_c = A_MISC + 13'd1; p_sub = 1'b1; end
        6'd33: begin p_a = sx(hvn4[1]); p_c = A_MISC + 13'd2; p_sub = 1'b1; end
        6'd34: begin p_wb = 1'b1; p_tgt = W_VN4; end
        6'd35: begin p_a = sx(hvn4[0]); p_c = A_FR7 + {10'd0, closure[4:2] ^ 3'd7}; p_init = I_CLR; end
        6'd36: begin p_wb = 1'b1; p_tgt = W_VN5; end
        6'd37: begin p_a = sx(hvn5); p_c = A_MISC + 13'd3; p_init = I_CLR; end
        6'd38: begin p_a = sx(hvn6); p_c = A_MISC + 13'd4; p_sub = 1'b1; end
        6'd39: begin p_wb = 1'b1; p_tgt = W_VN6; end
        6'd40: begin p_a = sx(hvn6); p_c = A_MISC + 13'd5; p_init = I_CLR; p_out = 1'b1; end
        6'd41: begin p_wb = 1'b1; p_tgt = W_OUT; p_last = 1'b1; end
        default: begin p_wb = 1'b1; p_tgt = W_OUT; p_last = 1'b1; end
    endcase
end

logic signed [26:0] coef_q;
sc01_coef_rom coef_rom (.clk(clk), .addr(p_c), .q(coef_q));

logic signed [26:0] opa, opb_reg;
logic               use_breg;
logic signed [53:0] prod;
logic signed [57:0] acc, base;
logic  [1:0]        r_init;
logic signed [26:0] r_ld;
logic               r_sub;
logic signed [24:0] r_res;
logic               r_out;

logic signed [24:0] res_f1, res_f2v, res_f3, res_f4;
logic signed [24:0] res_sel;
always_comb begin
    case (p_res)
        R_F1:    res_sel = res_f1;
        R_F2V:   res_sel = res_f2v;
        R_F3:    res_sel = res_f3;
        R_F4:    res_sel = res_f4;
        default: res_sel = 25'sd0;
    endcase
end

wire signed [26:0] opb     = use_breg ? opb_reg : coef_q;
wire signed [57:0] ld_x    = {{6{r_ld[26]}}, r_ld, 25'd0};
wire signed [57:0] rnd_x   = r_out ? 58'sd268435456 : 58'sd16777216;
wire signed [57:0] base_n  = (r_init == I_ACC) ? acc :
                             ((r_init == I_LD) ? ld_x : 58'sd0) + {{33{r_res[24]}}, r_res} + rnd_x;
wire signed [57:0] prod_x  = {{4{prod[53]}}, prod};
wire signed [57:0] y_full  = acc >>> 25;
wire signed [23:0] y       = sat24(y_full);
wire               y_sat   = (y_full != {{34{y[23]}}, y});
wire signed [24:0] res_new = y_sat ? 25'sd0 : {~acc[24], acc[23:0]};
wire signed [57:0] o_full  = acc >>> 29;
wire signed [15:0] o_sat   = (o_full > 58'sd32767) ? 16'sh7fff : (o_full < -58'sd32768) ? -16'sh8000 : o_full[15:0];

// writebacks registered: acc -> saturate -> residual does not fit one 80 MHz clock (same values, one clock later)
logic signed [23:0] y_r;
logic signed [24:0] res_r;
logic signed [15:0] o_r;
logic               wb_wait;
always_ff @(posedge clk) begin y_r <= y; res_r <= res_new; o_r <= o_sat; end

always_ff @(posedge clk) begin
    sample <= 1'b0;
    if (reset) begin
        seq_busy <= 1'b0;
        wb_wait  <= 1'b0;
        pc       <= 6'd0;
        ph       <= 2'd0;
        audio    <= 16'sd0;
        acc      <= 58'sd0;
        base     <= 58'sd0;
        prod     <= 54'sd0;
        r_res    <= 25'sd0;
        r_out    <= 1'b0;
        opa      <= 27'sd0;
        opb_reg  <= 27'sd0;
        use_breg <= 1'b0;
        r_init   <= I_ACC;
        r_ld     <= 27'sd0;
        r_sub    <= 1'b0;
        for (int i = 0; i < 4; i++) begin hv1[i] <= 24'sd0; hv2[i] <= 24'sd0; hvn1[i] <= 24'sd0; end
        for (int i = 0; i < 3; i++) begin hv3[i] <= 24'sd0; hvn2[i] <= 24'sd0; hvn3[i] <= 24'sd0; end
        for (int i = 0; i < 2; i++) begin hn1[i] <= 24'sd0; hn3[i] <= 24'sd0; hvn4[i] <= 24'sd0; end
        hn2 <= 24'sd0; hn4 <= 24'sd0; hvn5 <= 24'sd0; hvn6 <= 24'sd0;
        res_f1 <= 25'sd0; res_f2v <= 25'sd0; res_f3 <= 25'sd0; res_f4 <= 25'sd0;
    end else if (!seq_busy) begin
        if (seq_go) begin
            seq_busy <= 1'b1;
            pc       <= 6'd0;
            ph       <= 2'd0;
        end
    end else if (p_wb && !wb_wait) begin
        wb_wait <= 1'b1;
    end else if (p_wb) begin
        wb_wait <= 1'b0;
        case (p_tgt)
            W_V1:  begin hv1[3] <= hv1[2]; hv1[2] <= hv1[1]; hv1[1] <= hv1[0]; hv1[0] <= y_r; end
            W_V2:  begin hv2[3] <= hv2[2]; hv2[2] <= hv2[1]; hv2[1] <= hv2[0]; hv2[0] <= y_r; res_f1 <= res_r; end
            W_V3:  begin hv3[2] <= hv3[1]; hv3[1] <= hv3[0]; hv3[0] <= y_r; res_f2v <= res_r; end
            W_N1:  begin hn1[1] <= hn1[0]; hn1[0] <= y_r; end
            W_N2:  hn2 <= y_r;
            W_N3:  begin hn3[1] <= hn3[0]; hn3[0] <= y_r; end
            W_N4:  hn4 <= y_r;
            W_VN1: begin hvn1[3] <= hvn1[2]; hvn1[2] <= hvn1[1]; hvn1[1] <= hvn1[0]; hvn1[0] <= y_r; end
            W_VN2: begin hvn2[2] <= hvn2[1]; hvn2[1] <= hvn2[0]; hvn2[0] <= y_r; res_f3 <= res_r; end
            W_VN3: begin hvn3[2] <= hvn3[1]; hvn3[1] <= hvn3[0]; hvn3[0] <= y_r; end
            W_VN4: begin hvn4[1] <= hvn4[0]; hvn4[0] <= y_r; res_f4 <= res_r; end
            W_VN5: hvn5 <= y_r;
            W_VN6: hvn6 <= y_r;
            default: begin audio <= o_r; sample <= 1'b1; end
        endcase
        if (p_last) seq_busy <= 1'b0;
        else        pc <= pc + 6'd1;
    end else begin
        case (ph)
            2'd0: begin
                opa      <= p_a;
                opb_reg  <= p_bsel ? ns_r : ns_g;
                use_breg <= p_breg;
                r_init   <= p_init;
                r_ld     <= p_ld;
                r_sub    <= p_sub;
                r_res    <= res_sel;
                r_out    <= p_out;
                ph       <= 2'd1;
            end
            2'd1: begin
                prod <= opa * opb;
                base <= base_n;
                ph   <= 2'd2;
            end
            default: begin
                acc <= r_sub ? base - prod_x : base + prod_x;
                ph  <= 2'd0;
                pc  <= pc + 6'd1;
            end
        endcase
    end
end

endmodule
