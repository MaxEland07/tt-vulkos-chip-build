`default_nettype none
`timescale 1ns / 1ps

/*
 * Testbench wrapper for the cocotb tests, in the Tiny Tapeout shape. The tests
 * drive the pins and read uo_out. hsync and vsync are brought out as wires so a
 * test can wait on their edges whether the design under test is the RTL or the
 * hardened gate-level netlist. No waveform dump: a frame is 420 000 clocks, so
 * a VCD of a test run would be gigabytes.
 */
module tb ();

    reg        clk;
    reg        rst_n;
    reg        ena;
    reg  [7:0] ui_in;
    reg  [7:0] uio_in;
    wire [7:0] uo_out;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;

    wire hsync = uo_out[7];
    wire vsync = uo_out[3];

`ifdef GL_TEST
    wire VPWR = 1'b1;
    wire VGND = 1'b0;
`endif

    tt_um_maxeland07_vulkos_chip_build user_project (
`ifdef GL_TEST
        .VPWR   (VPWR),
        .VGND   (VGND),
`endif
        .ui_in  (ui_in),
        .uo_out (uo_out),
        .uio_in (uio_in),
        .uio_out(uio_out),
        .uio_oe (uio_oe),
        .ena    (ena),
        .clk    (clk),
        .rst_n  (rst_n)
    );

endmodule
