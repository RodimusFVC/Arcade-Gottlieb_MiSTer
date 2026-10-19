//============================================================================
//
//  Gottlieb Rev 2 sound board: 2 x 6502 (sound, speech), 2 x AY-3-8913, SP0250, AD7528 DACs
//  Copyright (C) 2026 Rodimus
//
//  MAME reference: shared/gottlieb_a.cpp (gottlieb_sound_r2_device): 6502s at 4 MHz / 4, AY-3-8913s at 4 MHz / 2,
//  SP0250 at 3.12 MHz. ROMs: sound CPU 8K at C000-DFFF (pool A), speech CPU 16K at C000-FFFF (pool B).
//
//  SCAFFOLD: ports only; the board is built from the Rev 2 sound sheet (mach3_s.pdf pp 15-16).
//
//============================================================================

module gottlieb_snd_r2
(
    input  logic        clk,            // 80 MHz
    input  logic        reset,
    input  logic        pause,

    input  logic  [7:0] cmd,
    input  logic        cmd_stb,

    output logic [12:0] rom_a,          // sound CPU
    input  logic  [7:0] rom_d,
    output logic [13:0] sp_rom_a,       // speech CPU
    input  logic  [7:0] sp_rom_d,

    output logic signed [15:0] audio
);

assign rom_a    = 13'd0;
assign sp_rom_a = 14'd0;
assign audio    = 16'sd0;

endmodule
