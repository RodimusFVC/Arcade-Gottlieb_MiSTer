//============================================================================
//
//  diag_overlay - rows of bit cells drawn over the core's picture (no SignalTap: read values off the screen)
//  Copyright (C) 2026 Rodimus
//
//  Spec: vault Tools/Reusable diagnostic swatch-overlay module.md. Conventions:
//    each row is one byte, cell 0 = LEFTMOST = bit 0 (in raster order; a rotated core turns the strips);
//    lit cell = 1 (white), dim cell = 0 (dark grey); rows stack downward from (X0, Y0) in visible-pixel
//    coordinates; enable = 0 is a pure pass-through.
//  Position comes from ce_pix / hblank / vblank, so it works on any core without its counters.
//  Cell / row position are kept by counters, not / and %: the divider version missed 80 MHz timing
//  (Gottlieb 2026-10-18) and a failing diagnostic must never disturb the core it is probing.
//
//============================================================================

module diag_overlay #(
    parameter N_ROWS  = 4,
    parameter CELL_W  = 6,
    parameter CELL_H  = 8,
    parameter ROW_GAP = 4,
    parameter X0      = 16,
    parameter Y0      = 24
)(
    input  logic                clk,
    input  logic                ce_pix,
    input  logic                hblank,
    input  logic                vblank,
    input  logic                enable,
    input  logic [N_ROWS*8-1:0] rowdata,       // row 0 in [7:0]
    input  logic          [7:0] core_r, core_g, core_b,
    output logic          [7:0] out_r,  out_g,  out_b
);

localparam ROW_H = CELL_H + ROW_GAP;

logic [9:0] x, y;
logic       hb_d;
logic [7:0] cx, cel;                    // pixel within cell, cell index along the row
logic [7:0] ry, row;                    // line within row band, row index
logic       in_x, in_y;

always_ff @(posedge clk) if (ce_pix) begin
    hb_d <= hblank;
    // horizontal
    if (hblank) begin x <= 10'd0; cx <= 8'd0; cel <= 8'd0; in_x <= 1'b0; end
    else begin
        x <= x + 10'd1;
        if (x + 10'd1 == X0) begin in_x <= 1'b1; cx <= 8'd0; cel <= 8'd0; end
        else if (in_x) begin
            if (cx == CELL_W - 1) begin cx <= 8'd0; cel <= cel + 8'd1; end
            else cx <= cx + 8'd1;
        end
    end
    // vertical: one step per line (at the end of each line's active area)
    if (vblank) begin y <= 10'd0; ry <= 8'd0; row <= 8'd0; in_y <= 1'b0; end
    else if (hblank && !hb_d) begin
        y <= y + 10'd1;
        if (y + 10'd1 == Y0) begin in_y <= 1'b1; ry <= 8'd0; row <= 8'd0; end
        else if (in_y) begin
            if (ry == ROW_H - 1) begin ry <= 8'd0; row <= row + 8'd1; end
            else ry <= ry + 8'd1;
        end
    end
end

wire in_band = enable && in_x && in_y && row < N_ROWS && ry < CELL_H && cel < 8 && cx != CELL_W - 1;
wire lit     = rowdata[{row[4:0], cel[2:0]}];

assign {out_r, out_g, out_b} = !in_band ? {core_r, core_g, core_b} : lit ? 24'hFFFFFF : 24'h303030;

endmodule
