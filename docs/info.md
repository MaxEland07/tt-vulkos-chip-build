## How it works

A sync generator counts through the 640 by 480 pixels of each frame at 60 Hz. A stage counter and a per-stage frame counter say how far the current stage of the flow has got on a 320 by 224 pixel tile drawn in the middle of the screen: floorplan, tap cells, power grid, placement, clock tree, routing, fill cells, signoff, package. A small hash of each pixel's coarse position decides which cells, wire segments and buffers exist, so the core looks placed and routed rather than ruled. The stage name is drawn top left from a 5 by 7 font ROM. The package then sweeps down over the die with the Vulkos logo, a 128 by 30 bitmap ROM, printed on top. There is no framebuffer: every pixel is worked out from its position and the counters as it is drawn, and the loop restarts every 20 seconds.

## How to test

Use a 25.175 MHz clock and hold rst_n low for a few cycles, then raise it. The animation plays on a monitor connected through a TinyVGA PMOD. Hold ui[0] to freeze it on a stage, and press ui[1] while frozen to move on a frame at a time.

## External hardware

A TinyVGA PMOD and a VGA monitor. Two buttons on ui[0] and ui[1] are optional.
