/*
 * VGA sync generator: 640 x 480 at 60 Hz from a 25.175 MHz pixel clock.
 *
 * One clock is one pixel. hpos and vpos count the pixel on screen right now, and
 * display_on is high while that pixel is inside the 640 x 480 picture, so a design
 * only has to draw when display_on is high and output black otherwise.
 *
 *   horizontal, in clocks     vertical, in lines
 *   visible       640         visible        480
 *   front porch    16         front porch     10
 *   sync pulse     96         sync pulse       2
 *   back porch     48         back porch      33
 *   total         800         total          525
 *
 * hsync and vsync are active low, and are registered: they change one clock after
 * the counters do, which is what keeps them free of glitches on real silicon.
 * reset is synchronous and active high (connect ~rst_n).
 */

`default_nettype none

module hvsync_generator (
    input  wire       clk,
    input  wire       reset,
    output reg        hsync,
    output reg        vsync,
    output wire       display_on,
    output reg  [9:0] hpos,
    output reg  [9:0] vpos
);

    localparam H_VISIBLE = 640;
    localparam H_FRONT   = 16;
    localparam H_SYNC    = 96;
    localparam H_BACK    = 48;

    localparam V_VISIBLE = 480;
    localparam V_FRONT   = 10;
    localparam V_SYNC    = 2;
    localparam V_BACK    = 33;

    localparam H_SYNC_START = H_VISIBLE + H_FRONT;
    localparam H_SYNC_END   = H_SYNC_START + H_SYNC - 1;
    localparam H_LAST       = H_VISIBLE + H_FRONT + H_SYNC + H_BACK - 1;

    localparam V_SYNC_START = V_VISIBLE + V_FRONT;
    localparam V_SYNC_END   = V_SYNC_START + V_SYNC - 1;
    localparam V_LAST       = V_VISIBLE + V_FRONT + V_SYNC + V_BACK - 1;

    wire line_end  = (hpos == H_LAST);
    wire frame_end = (vpos == V_LAST);

    // Pixel counter along the line.
    always @(posedge clk) begin
        if (reset || line_end) hpos <= 10'd0;
        else                   hpos <= hpos + 10'd1;
    end

    // Line counter, which moves on at the end of every line.
    always @(posedge clk) begin
        if (reset) begin
            vpos <= 10'd0;
        end else if (line_end) begin
            if (frame_end) vpos <= 10'd0;
            else           vpos <= vpos + 10'd1;
        end
    end

    // Sync pulses. Low while the counters are inside the sync window.
    always @(posedge clk) begin
        if (reset) begin
            hsync <= 1'b1;
            vsync <= 1'b1;
        end else begin
            hsync <= ~(hpos >= H_SYNC_START && hpos <= H_SYNC_END);
            vsync <= ~(vpos >= V_SYNC_START && vpos <= V_SYNC_END);
        end
    end

    assign display_on = (hpos < H_VISIBLE) && (vpos < V_VISIBLE);

endmodule
