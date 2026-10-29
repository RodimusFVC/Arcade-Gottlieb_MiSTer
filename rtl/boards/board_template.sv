//============================================================================
//  board_template.sv - start a new Gottlieb-core board by copying this file (NOT in files.qip, never compiled).
//  Copyright (C) 2026 Rodimus
//
//  Boards never instantiate a CPU, sound chip, ROM store or board RAM. They live ONCE in the dispatcher
//  rtl/gottlieb_dispatcher.sv: 8088 mcl86_0, 6502 t65_0, RIOT riot6532_0, Votrax sc01_0 (chip_pool_pkg buses), the
//  ROM blocks (main, tile, sprite planes, sound A / B, Votrax) and the seven board RAM pool blocks (ram_pool_pkg; map
//  in the dispatcher's "Shared RAM pool" section).
//  To add a board (next: the Rev 2 sound board): copy this file to rtl/boards/<board>/<board>.sv (the port list below
//  is gottlieb_snd_r1's), add it to files.qip + verilator/Makefile SRC, instance it in the dispatcher, put its *_i
//  buses on the variant muxes (snd_sel selects the sound board; today plain assigns, one user per slot). A chip the
//  pool lacks = a new chip_pool_pkg type in RodimusCoresMaster + a slot in the dispatcher, never a private instance.
//  A RAM / chip that truly can't pool = "// POOL-EXCEPTION: <reason>" on its line + a Pool contract row
//  (Claude/gottlieb_core_2026-10-18.md). verilator/common/pool_check.sh (POOL_MODS in verilator/Makefile) enforces it.
//============================================================================

module board_template
(
    input  logic        clk,            // 80 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic  [7:0] cmd,            // sound command from the logic board
    input  logic        cmd_stb,

    // Shared CPU / sound chip pool
    output chip_pool_pkg::t65_i_t      t65_0_i,
    input  chip_pool_pkg::t65_o_t      t65_0_o,
    output chip_pool_pkg::riot6532_i_t riot6532_0_i,
    input  chip_pool_pkg::riot6532_o_t riot6532_0_o,
    output chip_pool_pkg::sc01_i_t     sc01_0_i,
    input  chip_pool_pkg::sc01_o_t     sc01_0_o,

    // Shared ROM block (sound ROM pool A), one clock from address to data
    output logic [12:0] rom_a,
    input  logic  [7:0] rom_d,

    output logic signed [15:0] audio
);

assign t65_0_i      = '0;
assign riot6532_0_i = '0;
assign sc01_0_i     = '0;
assign rom_a        = 13'd0;
assign audio        = 16'sd0;

endmodule
