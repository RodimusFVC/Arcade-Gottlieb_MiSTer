//  Based on MAME gottlieb_a.cpp (Aaron Giles, BSD-3-Clause)
//  Copyright (C) 2026 Rodimus

module gottlieb_snd_r2
(
    input  logic        clk,
    input  logic        reset,
    input  logic        pause,

    input  logic  [7:0] cmd,
    input  logic        cmd_stb,

    output logic [12:0] rom_a,
    input  logic  [7:0] rom_d,
    output logic [13:0] sp_rom_a,
    input  logic  [7:0] sp_rom_d,

    output logic signed [15:0] audio
);

assign rom_a    = 13'd0;
assign sp_rom_a = 14'd0;
assign audio    = 16'sd0;

endmodule
