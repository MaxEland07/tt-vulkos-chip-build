/*
 * Vulkos chip build: a Tiny Tapeout tile is built on screen the way LibreLane
 * builds it, stage by stage, and then packaged with the Vulkos logo on top.
 * Loops every 20 seconds.
 *
 *   FLOORPLAN    die, core area, standard-cell rows, pins on the edge
 *   TAP CELLS    tap and end-cap cells dropped into every row
 *   POWER GRID   rails along the rows, vertical and horizontal stripes
 *   PLACEMENT    the standard cells fill the rows
 *   CLOCK TREE   the clock tree and its buffers
 *   ROUTING      metal 1, metal 2, metal 3 and the vias between them
 *   FILL CELLS   the gaps in the rows filled
 *   SIGNOFF      the outline flashes green: DRC, LVS, timing clean
 *   PACKAGE      the package closes over the die
 *
 * There is no framebuffer. A stage counter and a per-stage frame counter say how
 * far the current stage has got, and every pixel is worked out from (x, y, stage,
 * frame) as it is drawn. A small hash of the pixel's coarse position decides which
 * cells, wires and buffers exist, so the core looks placed and routed rather than
 * ruled. The stage name is drawn top left from a 5 x 7 font (labels.v) and the logo
 * on the package is a 128 x 30 bitmap of the real one (logo.v).
 *
 *   ui_in[0]  hold: freeze the animation on the current frame
 *   ui_in[1]  step: while held, each press moves on one frame
 *
 * How this file is laid out:
 *   1. WIRING      pins, buttons and the sync generator
 *   2. TIME        the stage and frame counters
 *   3. THE DIE     the tile, its core and every layer in it
 *   4. THE PACKAGE the part that closes over the die
 *   5. THE LABEL   the stage name
 *   6. THE PIXEL   which of those is on top
 */

`default_nettype none

module tt_um_maxeland07_vulkos_chip_build (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // ========================================================================
    // 1. WIRING
    // ========================================================================

    wire       hsync;
    wire       vsync;
    wire       video_active;
    wire [9:0] x;
    wire [9:0] y;

    hvsync_generator hvsync_gen (
        .clk(clk),
        .reset(~rst_n),
        .hsync(hsync),
        .vsync(vsync),
        .display_on(video_active),
        .hpos(x),
        .vpos(y)
    );

    assign uio_out = 8'd0;
    assign uio_oe  = 8'd0;
    wire _unused = &{ena, uio_in, ui_in[7:2], 1'b0};

    // The buttons are asynchronous to the clock, so they pass through two flops
    // before anything looks at them.
    reg [1:0] btn_meta;
    reg [1:0] btn;
    always @(posedge clk) begin
        if (!rst_n) begin
            btn_meta <= 2'b00;
            btn      <= 2'b00;
        end else begin
            btn_meta <= ui_in[1:0];
            btn      <= btn_meta;
        end
    end
    wire hold = btn[0];
    wire step = btn[1];

    // ========================================================================
    // 2. TIME
    //    stage says which step of the flow is running; r counts its frames.
    // ========================================================================

    // One clock per frame, as vsync goes active. vsync_q resets inactive so the
    // first frame after reset is not counted twice.
    reg  vsync_q;
    wire new_frame = vsync_q & ~vsync;
    always @(posedge clk) vsync_q <= rst_n ? vsync : 1'b1;

    // Step is edge triggered, sampled once per frame: holding it does not repeat.
    reg  step_q;
    always @(posedge clk) begin
        if (!rst_n)         step_q <= 1'b0;
        else if (new_frame) step_q <= step;
    end
    wire step_edge = step & ~step_q;
    wire advance   = new_frame & (~hold | step_edge);

    localparam [3:0] ST_FLOOR = 4'd0;
    localparam [3:0] ST_TAP   = 4'd1;
    localparam [3:0] ST_PWR   = 4'd2;
    localparam [3:0] ST_PLACE = 4'd3;
    localparam [3:0] ST_CTS   = 4'd4;
    localparam [3:0] ST_ROUTE = 4'd5;
    localparam [3:0] ST_FILL  = 4'd6;
    localparam [3:0] ST_SIGN  = 4'd7;
    localparam [3:0] ST_PKG   = 4'd8;

    reg [3:0] stage;
    reg [7:0] r;
    reg [7:0] len;

    always @* begin
        case (stage)
            ST_FLOOR: len = 8'd120;
            ST_TAP:   len = 8'd90;
            ST_PWR:   len = 8'd90;
            ST_PLACE: len = 8'd150;
            ST_CTS:   len = 8'd120;
            ST_ROUTE: len = 8'd180;
            ST_FILL:  len = 8'd90;
            ST_SIGN:  len = 8'd90;
            default:  len = 8'd240;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            stage <= ST_FLOOR;
            r     <= 8'd0;
        end else if (advance) begin
            if (r == len - 8'd1) begin
                r     <= 8'd0;
                stage <= (stage == ST_PKG) ? ST_FLOOR : stage + 4'd1;
            end else begin
                r <= r + 8'd1;
            end
        end
    end

    wire [9:0] r2 = {1'b0, r, 1'b0};        // two pixels a frame
    wire [9:0] r4 = {r, 2'b00};             // four pixels a frame
    wire [9:0] r8 = {r[6:0], 3'b000};       // eight pixels a frame (r below 128)
    wire       after = (stage > ST_FLOOR);  // "a later stage"

    // A small hash of the pixel's coarse position: not random, but varied enough
    // that the layers look placed and routed rather than ruled. One hash serves
    // every layer, each reading different bits of it.
    function [7:0] mix;
        input [5:0] a;
        input [5:0] b;
        reg   [5:0] s;
        reg   [5:0] t;
        begin
            s   = a + {b[2:0], b[5:3]};
            t   = b + {a[1:0], a[5:2]};
            mix = {s[5:2] ^ t[3:0], s[3:0] ^ t[5:2]} ^ {b[0], a[5], b[4], a[1], a[3], b[2], a[0], b[5]};
        end
    endfunction

    // ========================================================================
    // 3. THE DIE
    //    A 320 x 224 tile. The core is 288 x 192 inside it: twelve 16 px
    //    standard-cell rows of 8 px sites. dx, dy are the pixel's place on the die.
    // ========================================================================

    localparam [9:0] DIE_X = 10'd160;
    localparam [9:0] DIE_Y = 10'd128;
    localparam [9:0] DIE_W = 10'd320;
    localparam [9:0] DIE_H = 10'd224;

    wire       in_die = (x >= DIE_X) && (x < DIE_X + DIE_W) && (y >= DIE_Y) && (y < DIE_Y + DIE_H);
    wire [9:0] dx     = x - DIE_X;
    wire [9:0] dy     = y - DIE_Y;

    wire die_edge  = (dx == 10'd0) || (dx == DIE_W - 10'd1) || (dy == 10'd0) || (dy == DIE_H - 10'd1);
    wire in_core   = (dx >= 10'd16) && (dx < 10'd304) && (dy >= 10'd16) && (dy < 10'd208);
    wire core_edge = (((dx == 10'd15) || (dx == 10'd304)) && (dy >= 10'd15) && (dy <= 10'd208)) ||
                     (((dy == 10'd15) || (dy == 10'd208)) && (dx >= 10'd15) && (dx <= 10'd304));
    wire [7:0] h   = mix(dx[8:3], dy[8:3]);

    // --- FLOORPLAN: rows and pins -------------------------------------------
    // Row boundaries every 16 px; the pins are 2 x 8 marks on the die edge.
    wire row_line = (dy[3:0] == 4'd0);
    wire pin_lr   = ((dx < 10'd8) || (dx >= 10'd312)) && (dy[3:0] >= 4'd7) && (dy[3:0] <= 4'd8) && (dy >= 10'd16) && (dy < 10'd208);
    wire pin_top  = (dy < 10'd8) && (dx[3:0] >= 4'd7) && (dx[3:0] <= 4'd8) && (dx >= 10'd16) && (dx < 10'd304);
    wire pin      = pin_lr || pin_top;
    wire floor_rows_vis = after || (dy < r2);            // rows sweep down
    wire floor_pins_vis = after || (r >= 8'd64);         // then the pins appear

    // --- TAP CELLS: a 4 px tap every 64 px, end caps at both ends of each row -
    wire in_row  = (dy[3:0] >= 4'd1) && (dy[3:0] <= 4'd14);
    wire tap     = in_row && (dx[5:0] >= 6'd32) && (dx[5:0] <= 6'd35);
    wire endcap  = in_row && (((dx >= 10'd16) && (dx <= 10'd19)) || ((dx >= 10'd300) && (dx <= 10'd303)));
    wire tap_vis = (stage > ST_TAP) || ((stage == ST_TAP) && (dx < r4));

    // --- POWER GRID: rails on the row boundaries, met4 and met5 stripes -------
    wire rail     = row_line || (dy == 10'd208);
    wire stripe_v = (dx[5:0] >= 6'd46) && (dx[5:0] <= 6'd49);
    wire stripe_h = ((dy >= 10'd60) && (dy <= 10'd63)) || ((dy >= 10'd156) && (dy <= 10'd159));
    wire pwr_vis  = (stage > ST_PWR) || ((stage == ST_PWR) && (dx < r4));

    // --- PLACEMENT: cells in 16 px blocks of two sites -----------------------
    // h[1:0] picks the block's shape: empty, one 8 px cell, one 16 px cell, or two
    // 8 px cells. h[3:2] picks the cell kind, which sets its colour. In a tap
    // block only the right site is free.
    wire       blk_tap   = (dx[5:4] == 2'b10);
    wire [1:0] shape     = blk_tap ? 2'b01 : h[1:0];
    wire       site_r    = dx[3];
    wire       cell_here = (shape == 2'b01) ? (blk_tap ? site_r : ~site_r) : (shape != 2'b00);
    // A cell's outline: its own left and right pixel columns and top and bottom rows.
    wire       cell_lr   = (shape == 2'b10) ? ((dx[3:0] == 4'd0) || (dx[3:0] == 4'd15)) : ((dx[2:0] == 3'd0) || (dx[2:0] == 3'd7));
    wire       cell_tb   = (dy[3:0] == 4'd1) || (dy[3:0] == 4'd14);
    wire       stdcell      = in_row && cell_here && !endcap;
    wire       cell_edge = stdcell && (cell_lr || cell_tb);
    wire       place_vis = (stage > ST_PLACE) || ((stage == ST_PLACE) && (r[7:3] > {1'b0, h[7:4]}));

    // --- CLOCK TREE: an H tree from the middle of the core, buffers at the leaves
    wire trunk  = (dx >= 10'd159) && (dx <= 10'd161) && (dy >= 10'd40) && (dy <= 10'd184);
    wire branch = (((dy >= 10'd39) && (dy <= 10'd41)) || ((dy >= 10'd183) && (dy <= 10'd185))) && (dx >= 10'd48) && (dx <= 10'd272);
    wire twig   = (((dx >= 10'd47) && (dx <= 10'd49)) || ((dx >= 10'd271) && (dx <= 10'd273))) &&
                  (((dy >= 10'd16) && (dy <= 10'd72)) || ((dy >= 10'd152) && (dy <= 10'd207)));
    wire leaf   = (((dx >= 10'd44) && (dx <= 10'd52)) || ((dx >= 10'd268) && (dx <= 10'd276))) &&
                  (((dy >= 10'd17) && (dy <= 10'd22)) || ((dy >= 10'd66) && (dy <= 10'd72)) || ((dy >= 10'd152) && (dy <= 10'd158)) || ((dy >= 10'd201) && (dy <= 10'd206)));
    wire root   = (dx >= 10'd156) && (dx <= 10'd164) && (dy >= 10'd109) && (dy <= 10'd115);
    wire cts_trunk_vis  = (stage > ST_CTS) || (stage == ST_CTS);
    wire cts_branch_vis = (stage > ST_CTS) || ((stage == ST_CTS) && (r >= 8'd40));
    wire cts_twig_vis   = (stage > ST_CTS) || ((stage == ST_CTS) && (r >= 8'd80));
    wire clock = ((trunk || root) && cts_trunk_vis) || (branch && cts_branch_vis) || ((twig || leaf) && cts_twig_vis);

    // --- ROUTING: three metal layers in turn, vias where the first two cross --
    wire m1 = (h[5:4] != 2'b00) && ((dy[3:0] == 4'd5) || (dy[3:0] == 4'd6) || (dy[3:0] == 4'd10) || (dy[3:0] == 4'd11));
    wire m2 = (h[6] ^ h[2]) && ((dx[3:0] == 4'd4) || (dx[3:0] == 4'd5) || (dx[3:0] == 4'd12) || (dx[3:0] == 4'd13));
    wire m3 = (h[7] & h[3]) && (dy[4:0] >= 5'd14) && (dy[4:0] <= 5'd16);
    wire via = m1 && m2;
    // Each layer sweeps once and then stays: metal 1 across in the first 40 frames,
    // metal 2 down from frame 64, metal 3 across from frame 128. A sweep must never
    // read a counter that wraps while the layer is still being drawn, or it would
    // start again: metal 2 once did, using the low six bits of r. Each layer has its
    // own count from its start frame, and is simply on once it has covered the die.
    wire [7:0] r_m2 = r - 8'd64;
    wire [7:0] r_m3 = r - 8'd128;
    wire m1_vis = (stage > ST_ROUTE) || ((stage == ST_ROUTE) && ((r >= 8'd40) || (dx < r8)));
    wire m2_vis = (stage > ST_ROUTE) || ((stage == ST_ROUTE) && (r >= 8'd64) && ((r >= 8'd120) || (dy < {2'b00, r_m2[5:0], 2'b00})));
    wire m3_vis = (stage > ST_ROUTE) || ((stage == ST_ROUTE) && (r >= 8'd128) && ((r >= 8'd168) || (dx < {r_m3[6:0], 3'b000})));

    // --- FILL CELLS: every empty site gets a filler --------------------------
    wire filler   = in_row && !stdcell && !tap && !endcap;
    wire fill_vis = (stage > ST_FILL) || ((stage == ST_FILL) && (dx < r4));

    // --- SIGNOFF: the core outline flashes green ----------------------------
    wire signoff = (stage == ST_SIGN) && r[4];

    // ========================================================================
    // 4. THE PACKAGE
    //    416 x 320 with chamfered corners, pins on all four sides, the logo on top.
    // ========================================================================

    localparam [9:0] PKG_X = 10'd112;
    localparam [9:0] PKG_Y = 10'd80;
    localparam [9:0] PKG_W = 10'd416;
    localparam [9:0] PKG_H = 10'd320;

    wire       in_pkg_box = (x >= PKG_X) && (x < PKG_X + PKG_W) && (y >= PKG_Y) && (y < PKG_Y + PKG_H);
    wire [9:0] px  = x - PKG_X;
    wire [9:0] py  = y - PKG_Y;

    // Chamfered corners: in the outer 32 px band on each side, the distance in from
    // the edge is the low five bits (complemented on the far side), and the corner
    // is cut where the two distances sum to less than 24.
    wire   px_lo = (px[9:5] == 5'd0);
    wire   px_hi = (px[9:5] == 5'd12);
    wire   py_lo = (py[9:5] == 5'd0);
    wire   py_hi = (py[9:5] == 5'd9);
    wire [4:0] ex = px_lo ? px[4:0] : ~px[4:0];
    wire [4:0] ey = py_lo ? py[4:0] : ~py[4:0];
    wire pkg_corner = (px_lo || px_hi) && (py_lo || py_hi) && ({1'b0, ex} + {1'b0, ey} < 6'd24);
    wire pkg_body   = in_pkg_box && !pkg_corner;
    wire pkg_bevel  = (py < 10'd2) || (px < 10'd2);
    // The pin 1 dot: an 8 px box with its corners cut.
    wire dot_edge_x = (px[2:0] == 3'd0) || (px[2:0] == 3'd7);
    wire dot_edge_y = (py[2:0] == 3'd0) || (py[2:0] == 3'd7);
    wire pkg_dot    = (px[9:3] == 7'd5) && (py[9:3] == 7'd5) && !(dot_edge_x && dot_edge_y);

    // Pins: 24 px long, 8 px wide, 32 px pitch, with a bright tip.
    wire [9:0] pin_along_y = y - 10'd104;
    wire [9:0] pin_along_x = x - 10'd144;
    wire pins_l = (x >= 10'd88) && (x < PKG_X);
    wire pins_r = (x >= PKG_X + PKG_W) && (x < 10'd552);
    wire pins_t = (y >= 10'd56) && (y < PKG_Y);
    wire pins_b = (y >= PKG_Y + PKG_H) && (y < 10'd424);
    wire pins_lr = (y >= 10'd104) && (y < 10'd376) && (pin_along_y[4:3] == 2'b00) && (pins_l || pins_r);
    wire pins_tb = (x >= 10'd144) && (x < 10'd496) && (pin_along_x[4:3] == 2'b00) && (pins_t || pins_b);
    wire pins    = pins_lr || pins_tb;

    // Fully down from frame 80. Past that the sum below would overflow 10 bits (at
    // frame 236 it reaches 1024), so it is not looked at.
    wire pkg_vis = (stage == ST_PKG) && ((r >= 8'd80) || (y < r4 + PKG_Y));

    // The logo printed on the package: 128 x 30, centred.
    wire [9:0] mx = x - 10'd256;
    wire [9:0] my = y - 10'd225;
    wire in_mark  = (x >= 10'd256) && (mx < 10'd128) && (y >= 10'd225) && (my < 10'd30);
    wire logo_ink;
    vulkos_logo logo (.x(mx[6:0]), .y(my[4:0]), .ink(logo_ink));
    wire mark_ink = in_mark && logo_ink;

    // ========================================================================
    // 5. THE LABEL
    //    The stage name, top left, 5 x 7 font at 2x on a 16 px pitch.
    // ========================================================================

    localparam [9:0] LBL_X = 10'd16;
    localparam [9:0] LBL_Y = 10'd16;
    wire [9:0] lx = x - LBL_X;
    wire [9:0] ly = y - LBL_Y;
    wire in_label = (x >= LBL_X) && (lx < 10'd112) && (y >= LBL_Y) && (ly < 10'd14);
    wire [4:0] glyph;
    stage_label label (.stage(stage), .idx(lx[6:4]), .row(ly[3:1]), .bits(glyph));
    wire [2:0] col = 3'd4 - lx[3:1];
    wire label_ink = in_label && (lx[3:1] < 3'd5) && glyph[col[2:0]];

    // ========================================================================
    // 6. THE PIXEL
    // ========================================================================

    localparam [5:0] BLACK   = 6'b000000;
    localparam [5:0] WHITE   = 6'b111111;
    localparam [5:0] DIE     = 6'b000001;
    localparam [5:0] EDGE    = 6'b101010;
    localparam [5:0] ROWLINE = 6'b010101;
    localparam [5:0] PIN     = 6'b111111;
    localparam [5:0] TAP     = 6'b110100;
    localparam [5:0] RAIL    = 6'b010011;
    localparam [5:0] MET4    = 6'b001111;
    localparam [5:0] MET5    = 6'b111000;
    localparam [5:0] CELL_A  = 6'b010110;
    localparam [5:0] CELL_B  = 6'b011001;
    localparam [5:0] CELL_C  = 6'b100110;
    localparam [5:0] CELL_D  = 6'b010101;
    localparam [5:0] OUTLINE = 6'b101010;
    localparam [5:0] CLOCK   = 6'b111100;
    localparam [5:0] METAL1  = 6'b010011;
    localparam [5:0] METAL2  = 6'b100011;
    localparam [5:0] METAL3  = 6'b011011;
    localparam [5:0] FILL    = 6'b010100;
    localparam [5:0] GREEN   = 6'b001100;
    localparam [5:0] BODY    = 6'b010101;
    localparam [5:0] BEVEL   = 6'b101010;
    localparam [5:0] MARK    = 6'b101010;

    reg [5:0] cell_rgb;
    always @* begin
        case (h[3:2])
            2'b00:   cell_rgb = CELL_A;
            2'b01:   cell_rgb = CELL_B;
            2'b10:   cell_rgb = CELL_C;
            default: cell_rgb = CELL_D;
        endcase
    end

    reg [5:0] rgb_build;
    always @* begin
        if (pkg_vis && (pkg_body || pins)) begin
            if      (pins)             rgb_build = BEVEL;
            else if (pkg_dot)          rgb_build = BLACK;
            else if (pkg_bevel)        rgb_build = BEVEL;
            else if (mark_ink)         rgb_build = MARK;
            else                       rgb_build = BODY;
        end else if (label_ink) begin
            rgb_build = WHITE;
        end else if (in_die) begin
            if      (die_edge)                     rgb_build = EDGE;
            else if (pin && floor_pins_vis)        rgb_build = PIN;
            else if (core_edge)                    rgb_build = signoff ? GREEN : ROWLINE;
            else if (!in_core)                     rgb_build = DIE;
            else if (via && m2_vis)                rgb_build = WHITE;
            else if (stripe_h && pwr_vis)          rgb_build = MET5;
            else if (stripe_v && pwr_vis)          rgb_build = MET4;
            else if (m3 && m3_vis)                 rgb_build = METAL3;
            else if (m2 && m2_vis)                 rgb_build = METAL2;
            else if (m1 && m1_vis)                 rgb_build = METAL1;
            else if (clock)                        rgb_build = CLOCK;
            else if ((tap || endcap) && tap_vis)   rgb_build = TAP;
            else if (cell_edge && place_vis)       rgb_build = OUTLINE;
            else if (stdcell && place_vis)            rgb_build = cell_rgb;
            else if (filler && fill_vis)           rgb_build = FILL;
            else if (rail && pwr_vis)              rgb_build = RAIL;
            else if (row_line && floor_rows_vis)   rgb_build = ROWLINE;
            else                                   rgb_build = DIE;
        end else begin
            rgb_build = BLACK;
        end
    end

    wire [5:0] rgb = video_active ? rgb_build : BLACK;

    // Tiny VGA PMOD: R1 G1 B1 vsync R0 G0 B0 hsync.
    assign uo_out = {hsync, rgb[0], rgb[2], rgb[4], vsync, rgb[1], rgb[3], rgb[5]};

endmodule
