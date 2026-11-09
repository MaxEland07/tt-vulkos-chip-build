"""cocotb tests for the Vulkos chip build.

What is checked, and why it matters on silicon:

  reset        every output is a known value straight after reset, never X, and the
               bidirectional pins are driven low as inputs
  hsync        800 clocks a line, a 96 clock active-low pulse, stable line after line
  vsync        525 lines a frame, a 2 line active-low pulse, stable frame after frame
  blanking     the colour pins are black outside the 640 x 480 picture, so a monitor
               locks cleanly and the picture sits where it should
  stages       every stage lasts exactly its number of frames and the loop wraps
  sweeps       a layer that has swept across the die stays on until its stage ends,
               and the package is still drawn on the last frames of the loop
  hold, step   hold freezes the animation, step moves it one frame per press and does
               not repeat while held, both through the input synchronisers
  label, logo  the stage name and the package logo come out of the ROMs pixel exact
  determinism  a held frame is drawn identically twice over, so nothing depends on
               uninitialised state

A simulated frame is 420 000 clocks and the sandbox simulates about 25 000 clocks a
second, so a frame costs 16 s there. The tests wait on sync edges and sim time rather
than polling the clock, each spends as few frames as it can, and the groups in GROUPS
(used by daytona.ts) hold every run to about five frames, under the 120 s limit.

The RTL tests may read the design's own counters to jump ahead; the gate-level run
(GATES=yes) only has the pins, so those tests are skipped there and the timing,
blanking and reset checks carry the weight.
"""
import os
import re
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge
from cocotb.utils import get_sim_time

GATES = os.environ.get('GATES') == 'yes'
HERE = Path(__file__).resolve().parent

CLK_NS = 40
H_TOTAL, H_VISIBLE, H_FRONT, H_SYNC, H_BACK = 800, 640, 16, 96, 48
V_TOTAL, V_VISIBLE, V_FRONT, V_SYNC, V_BACK = 525, 480, 10, 2, 33
FRAME = H_TOTAL * V_TOTAL

STAGE_LEN = [120, 90, 90, 150, 120, 180, 90, 90, 240]

# Test groups small enough to run inside one 120 s sandbox job each (see daytona.ts).
GROUPS = {
    'timing': 'test_reset_outputs_known|test_hsync_timing|test_vsync_timing|test_hsync_through_vsync',
    'blanking': 'test_black_in_vertical_blanking|test_black_in_horizontal_blanking|test_picture_edges',
    'stages_a': 'test_stage_lengths_0_to_2|test_reset_restarts_animation',
    'stages_b': 'test_stage_lengths_3_to_5',
    'stages_c': 'test_stage_lengths_6_to_8',
    'counter': 'test_frame_counter_counts_every_frame',
    'hold': 'test_hold_freezes',
    'step': 'test_step_moves_one_frame_per_press',
    'glitch': 'test_button_glitch_is_filtered',
    'label_a': 'test_label_pixels_0_to_2',
    'label_b': 'test_label_pixels_3_to_5',
    'label_c': 'test_label_pixels_6_to_8',
    'logo': 'test_package_logo_matches_rom',
    'determinism': 'test_held_frame_is_deterministic',
    'route': 'test_route_layers_sweep_once',
    'package_end': 'test_package_stays_to_the_end',
    # The gate-level netlist, through daytona.ts --gates: only what fits its speed.
    'gl': 'test_reset_outputs_known|test_hsync_timing',
}


def val(sig):
    """A signal as an int. A one-bit signal reads back as a Logic, a bus as a LogicArray."""
    value = sig.value
    return value.to_unsigned() if hasattr(value, 'to_unsigned') else int(value)


def now():
    return get_sim_time('ns')


async def start(dut, hold=0, step=0):
    """Clock, reset, inputs idle. Returns after reset is released."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit='ns').start())  # 25 MHz, near enough to 25.175
    dut.ena.value = 1
    dut.ui_in.value = (step << 1) | hold
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


def rgb_of(dut):
    """RRGGBB from the Tiny VGA pin order."""
    v = val(dut.uo_out)
    return ((v & 1) << 5) | ((v >> 4 & 1) << 4) | ((v >> 1 & 1) << 3) | ((v >> 5 & 1) << 2) | ((v >> 2 & 1) << 1) | (v >> 6 & 1)


async def frames(dut, n):
    for _ in range(n):
        await FallingEdge(dut.vsync)
    await ClockCycles(dut.clk, 4)


# ---------------------------------------------------------------------------
# reset and pins
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_outputs_known(dut):
    """Every output is 0 or 1 from the first clock after reset; uio is all inputs."""
    await start(dut)
    for _ in range(1000):
        await RisingEdge(dut.clk)
        assert dut.uo_out.value.is_resolvable, f'uo_out has X/Z after reset: {dut.uo_out.value}'
        assert dut.uio_out.value.is_resolvable and val(dut.uio_out) == 0, 'uio_out must be 0'
        assert dut.uio_oe.value.is_resolvable and val(dut.uio_oe) == 0, 'uio_oe must be 0 (inputs)'


@cocotb.test()
async def test_reset_restarts_animation(dut):
    """A second reset in the middle of the loop goes back to stage 0, frame 0."""
    if GATES:
        return
    await start(dut)
    dut.stage.value = 5
    dut.r.value = 77
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)
    assert val(dut.stage) == 0 and val(dut.r) == 0


# ---------------------------------------------------------------------------
# sync timing
# ---------------------------------------------------------------------------

async def measure_low(sig):
    """Waits for a falling edge, then returns (low clocks, period clocks) from sim time."""
    await FallingEdge(sig)
    t0 = now()
    await RisingEdge(sig)
    t1 = now()
    await FallingEdge(sig)
    t2 = now()
    return round((t1 - t0) / CLK_NS), round((t2 - t0) / CLK_NS)


@cocotb.test()
async def test_hsync_timing(dut):
    """hsync: 96 clocks low, 800 clocks a line, for several lines in a row."""
    await start(dut)
    for _ in range(4):
        low, period = await measure_low(dut.hsync)
        assert low == H_SYNC, f'hsync low for {low} clocks, expected {H_SYNC}'
        assert period == H_TOTAL, f'hsync period {period} clocks, expected {H_TOTAL}'


@cocotb.test()
async def test_vsync_timing(dut):
    """vsync: 2 lines low, 525 lines a frame, twice in a row."""
    await start(dut)
    for _ in range(2):
        low, period = await measure_low(dut.vsync)
        assert low == V_SYNC * H_TOTAL, f'vsync low for {low} clocks, expected {V_SYNC * H_TOTAL}'
        assert period == FRAME, f'vsync period {period} clocks, expected {FRAME}'


@cocotb.test()
async def test_hsync_through_vsync(dut):
    """The hsync rhythm carries straight through the vsync pulse."""
    await start(dut)
    await FallingEdge(dut.vsync)
    for _ in range(V_SYNC + 2):
        low, period = await measure_low(dut.hsync)
        assert low == H_SYNC and period == H_TOTAL, f'line of {period} clocks, pulse {low}, during vsync'


# ---------------------------------------------------------------------------
# blanking. Positions come from the sync pins only, so these run on the netlist.
# hsync falls 16 clocks after the last pixel of a line; vsync falls as line 490 begins.
# ---------------------------------------------------------------------------

async def line_start(dut, line):
    """Waits until the first pixel of `line` of the next frame is on the pins."""
    await FallingEdge(dut.vsync)
    # Now inside line 490. Line 0 of the next frame starts 35 lines on; its hsync
    # fell in line 524, 143 clocks before pixel 0 of line 0 (16 front + 96 + 48 - 17).
    for _ in range(V_TOTAL - (V_VISIBLE + V_FRONT) + line):
        await FallingEdge(dut.hsync)
    await ClockCycles(dut.clk, H_BACK + H_SYNC)


async def black_for(dut, clocks, what):
    for i in range(clocks):
        assert rgb_of(dut) == 0, f'colour during {what}, clock {i}'
        await RisingEdge(dut.clk)


@cocotb.test()
async def test_black_in_vertical_blanking(dut):
    """The colour pins are black for every clock of the 45 blanking lines."""
    await start(dut)
    await line_start(dut, V_VISIBLE - 1)
    await ClockCycles(dut.clk, H_TOTAL + 2)       # into line 480, past any edge
    await black_for(dut, (V_TOTAL - V_VISIBLE) * H_TOTAL - 4, 'vertical blanking')


@cocotb.test()
async def test_black_in_horizontal_blanking(dut):
    """On a picture line, the colour pins are black from the end of the 640 pixels
    to the start of the next line: front porch, sync and back porch."""
    await start(dut)
    await line_start(dut, 200)
    await ClockCycles(dut.clk, H_VISIBLE + 2)
    await black_for(dut, H_TOTAL - H_VISIBLE - 4, 'horizontal blanking')


@cocotb.test()
async def test_picture_edges(dut):
    """On line 200 the die is drawn between x 160 and 479 and nothing outside it,
    which pins the picture to the right place on the screen."""
    await start(dut)
    await line_start(dut, 200)
    first = last = None
    for xpos in range(H_VISIBLE):
        if rgb_of(dut):
            last = xpos
            if first is None:
                first = xpos
        await RisingEdge(dut.clk)
    assert first is not None, 'nothing drawn on line 200'
    assert 157 <= first <= 163, f'die left edge at {first}, expected 160'
    assert 476 <= last <= 482, f'die right edge at {last}, expected 479'


# ---------------------------------------------------------------------------
# the stage counter, hold and step
# ---------------------------------------------------------------------------

async def stage_lengths(dut, first, last):
    """Each stage lasts exactly its number of frames, and the last wraps to the
    first. The frame counter is jumped to the last frame of each stage so the
    check costs one frame per stage; the wrap logic itself is exercised for real."""
    await start(dut)
    await frames(dut, 1)
    for stage in range(first, last + 1):
        length = STAGE_LEN[stage]
        dut.stage.value = stage
        dut.r.value = length - 1
        await frames(dut, 1)
        expect = (stage + 1) % len(STAGE_LEN)
        got = (val(dut.stage), val(dut.r))
        assert got == (expect, 0), f'stage {stage} after its last frame: expected ({expect}, 0), got {got}'


@cocotb.test()
async def test_stage_lengths_0_to_2(dut):
    if not GATES:
        await stage_lengths(dut, 0, 2)


@cocotb.test()
async def test_stage_lengths_3_to_5(dut):
    if not GATES:
        await stage_lengths(dut, 3, 5)


@cocotb.test()
async def test_stage_lengths_6_to_8(dut):
    """Includes the wrap from the last stage back to the first."""
    if not GATES:
        await stage_lengths(dut, 6, 8)


@cocotb.test()
async def test_frame_counter_counts_every_frame(dut):
    """With nothing held, r goes up by exactly one per frame."""
    if GATES:
        return
    await start(dut)
    await frames(dut, 1)
    r0 = val(dut.r)
    await frames(dut, 2)
    assert val(dut.r) == r0 + 2


@cocotb.test()
async def test_hold_freezes(dut):
    """Holding ui_in[0] stops the counters for as long as it is held."""
    if GATES:
        return
    await start(dut)
    await frames(dut, 1)
    dut.ui_in.value = 1
    await ClockCycles(dut.clk, 4)  # through the synchroniser
    r0, s0 = val(dut.r), val(dut.stage)
    await frames(dut, 2)
    assert (val(dut.r), val(dut.stage)) == (r0, s0), 'hold did not freeze the animation'
    dut.ui_in.value = 0
    await frames(dut, 1)
    assert val(dut.r) == r0 + 1, 'did not resume after hold was released'


@cocotb.test()
async def test_step_moves_one_frame_per_press(dut):
    """While held, each press of ui_in[1] moves on one frame, and keeping it
    pressed does not repeat."""
    if GATES:
        return
    await start(dut, hold=1)
    await frames(dut, 1)
    r0 = val(dut.r)
    dut.ui_in.value = 0b11            # press step
    await frames(dut, 2)              # hold it across two frames
    assert val(dut.r) == r0 + 1, f'one press should move one frame, moved {val(dut.r) - r0}'
    dut.ui_in.value = 0b01            # release
    await frames(dut, 1)
    assert val(dut.r) == r0 + 1, 'releasing step moved the animation'
    dut.ui_in.value = 0b11            # press again
    await frames(dut, 1)
    assert val(dut.r) == r0 + 2, 'second press did not move one frame'


@cocotb.test()
async def test_button_glitch_is_filtered(dut):
    """A one-clock pulse on the step pin, away from a frame edge, cannot advance
    the frame counter: the press is only looked at once per frame."""
    if GATES:
        return
    await start(dut, hold=1)
    await frames(dut, 1)
    r0 = val(dut.r)
    await ClockCycles(dut.clk, 1000)  # mid-frame
    dut.ui_in.value = 0b11
    await ClockCycles(dut.clk, 1)
    dut.ui_in.value = 0b01
    await frames(dut, 1)
    assert val(dut.r) == r0, 'a mid-frame glitch on step advanced the animation'


# ---------------------------------------------------------------------------
# the picture itself. RTL only: pixels are read against the design's own x, y.
# ---------------------------------------------------------------------------

def read_rom_bitmap(path, width, height):
    """Parses a gen_logo.py ROM back into rows of 0/1."""
    text = Path(path).read_text()
    rows = {}
    for m in re.finditer(r"(\d+)'d(\d+): begin (.*?) end", text):
        y = int(m.group(2))
        chunks = re.findall(r"32'b([01]{32})", m.group(3))
        rows[y] = ''.join(chunks)[:width]
    return [[int(b) for b in rows[y]] for y in range(height)]


def read_font():
    """Stage names and the 5 x 7 font, parsed out of the ROM itself (src/labels.v),
    so the test can only ever agree with what is on the chip."""
    text = (HERE.parent / 'src' / 'labels.v').read_text()
    # Letter codes from the header comment: "Letter codes: 1=A, 2=C, ..., 16=W".
    code_char = {int(c): ch for c, ch in re.findall(r"(\d+)=([A-Z])", text)}
    # Stage names: lines "{4'd<stage>, 3'd<idx>}: letter = 5'd<code>;  // <char>".
    letters = {}
    for m in re.finditer(r"\{4'd(\d+), 3'd(\d+)\}: letter = 5'd(\d+);\s*// ([A-Z])", text):
        letters[(int(m.group(1)), int(m.group(2)))] = code_char[int(m.group(3))]
    stages = [''.join(letters.get((s, i), ' ') for i in range(7)) for s in range(9)]
    # Font rows: lines "{5'd<code>, 3'd<row>}: bits = 5'b<5 bits>;". String index
    # 0 is the MSB, which the RTL draws as the leftmost column.
    rows = {}
    for m in re.finditer(r"\{5'd(\d+), 3'd(\d+)\}: bits = 5'b([01]{5});", text):
        rows[(int(m.group(1)), int(m.group(2)))] = m.group(3)
    font = {ch: [rows.get((code, r), '00000') for r in range(7)] for code, ch in code_char.items()}
    return stages, font


async def row_pixels(dut, y, x0, n):
    """rgb of pixels x0..x0+n-1 on line y of the next frame, each read in the same
    clock as the design's own counters say it is drawing that pixel."""
    await line_start(dut, y)
    await ClockCycles(dut.clk, max(0, x0 - 8))
    for _ in range(24):
        if val(dut.y) == y and val(dut.x) == x0:
            break
        await RisingEdge(dut.clk)
    assert val(dut.x) == x0 and val(dut.y) == y, \
        f'could not line up on pixel ({x0}, {y}): at ({val(dut.x)}, {val(dut.y)})'
    out = []
    for _ in range(n):
        out.append(rgb_of(dut))
        await RisingEdge(dut.clk)
    return out


async def label_pixels(dut, first, last):
    """The stage name comes out of the font ROM pixel for pixel: three glyph rows
    of each stage, one frame per stage."""
    stages, font = read_font()
    await start(dut, hold=1)
    for stage in range(first, last + 1):
        name = stages[stage]
        dut.stage.value = stage
        for k, row in enumerate((0, 3, 6)):
            y = 16 + 2 * row
            if k == 0:
                got = await row_pixels(dut, y, 16, 112)
            else:
                # Later rows of the same frame: wait for their line by counting hsync.
                for _ in range(6):
                    await FallingEdge(dut.hsync)
                await ClockCycles(dut.clk, H_BACK + H_SYNC)
                for _ in range(24):
                    if val(dut.y) == y and val(dut.x) == 16:
                        break
                    await RisingEdge(dut.clk)
                got = [rgb_of(dut)]
                for _ in range(111):
                    await RisingEdge(dut.clk)
                    got.append(rgb_of(dut))
            for ci in range(7):
                ch = name[ci] if ci < len(name) else ' '
                glyph = font[ch][row] if ch != ' ' else '00000'
                for col in range(8):
                    px = got[ci * 16 + col * 2]
                    want = 0b111111 if col < 5 and glyph[col] == '1' else 0
                    assert px == want, f'stage {name} char {ci} row {row} col {col}: got {px:06b} want {want:06b}'


@cocotb.test()
async def test_label_pixels_0_to_2(dut):
    if not GATES:
        await label_pixels(dut, 0, 2)


@cocotb.test()
async def test_label_pixels_3_to_5(dut):
    if not GATES:
        await label_pixels(dut, 3, 5)


@cocotb.test()
async def test_label_pixels_6_to_8(dut):
    if not GATES:
        await label_pixels(dut, 6, 8)


@cocotb.test()
async def test_package_logo_matches_rom(dut):
    """In the package stage the logo marking is the ROM, pixel for pixel, on five rows."""
    if GATES:
        return
    bitmap = read_rom_bitmap(HERE.parent / 'src' / 'logo.v', 128, 30)
    await start(dut, hold=1)
    dut.stage.value = 8
    dut.r.value = 200
    body, mark = 0b010101, 0b101010
    rows = (3, 10, 15, 22, 28)
    got = await row_pixels(dut, 225 + rows[0], 256, 128)
    checks = [(rows[0], got)]
    for prev, row in zip(rows, rows[1:]):
        for _ in range(row - prev):
            await FallingEdge(dut.hsync)
        await ClockCycles(dut.clk, H_BACK + H_SYNC)
        for _ in range(300):
            if val(dut.y) == 225 + row and val(dut.x) == 256:
                break
            await RisingEdge(dut.clk)
        got = [rgb_of(dut)]
        for _ in range(127):
            await RisingEdge(dut.clk)
            got.append(rgb_of(dut))
        checks.append((row, got))
    for row, got in checks:
        for i, px in enumerate(got):
            want = mark if bitmap[row][i] else body
            assert px == want, f'logo row {row} col {i}: got {px:06b} want {want:06b}'


@cocotb.test()
async def test_held_frame_is_deterministic(dut):
    """Two frames drawn while held are identical, pixel for pixel, over a band of
    lines through the die: nothing in the picture depends on state the frame
    does not reset."""
    await start(dut, hold=1)

    async def band():
        await line_start(dut, 200)   # through the die, which is drawn from line 128
        out = []
        for _ in range(8 * H_TOTAL):
            out.append(rgb_of(dut))
            await RisingEdge(dut.clk)
        return out

    a = await band()
    b = await band()
    assert a == b, 'the same held frame was drawn differently twice'
    assert any(a), 'the band was all black, so the comparison proves nothing'


# ---------------------------------------------------------------------------
# sweeps. These read the design's own visibility wires at one pixel, one frame
# per reading, so they are RTL only. They guard two bugs that were real: metal 2
# swept a second time when the low bits of the frame counter wrapped, and the
# package vanished on the last four frames because its sweep sum overflowed.
# ---------------------------------------------------------------------------

async def at_pixel(dut, x, y):
    """Waits until the design is drawing pixel (x, y) of the next frame."""
    await line_start(dut, y)
    await ClockCycles(dut.clk, max(0, x - 8))
    for _ in range(24):
        if val(dut.y) == y and val(dut.x) == x:
            break
        await RisingEdge(dut.clk)
    assert val(dut.x) == x and val(dut.y) == y, \
        f'could not line up on pixel ({x}, {y}): at ({val(dut.x)}, {val(dut.y)})'


@cocotb.test()
async def test_route_layers_sweep_once(dut):
    """Once a routing layer has swept across the die it stays on until the stage ends.
    Read at the die pixel (140, 200): metal 2 is reached at frame 115 of the stage and
    must stay on after the low bits of the frame counter wrap at frame 128; metal 3 only
    reaches that pixel at frame 146."""
    if GATES:
        return
    await start(dut, hold=1)
    cases = [(110, 0, 0), (120, 1, 0), (128, 1, 0), (140, 1, 0), (179, 1, 1)]
    for r, want_m2, want_m3 in cases:
        dut.stage.value = 5
        dut.r.value = r
        await at_pixel(dut, 300, 328)
        got = (val(dut.m2_vis), val(dut.m3_vis))
        assert got == (want_m2, want_m3), f'route frame {r}: metal 2 and metal 3 visible {got}, expected {(want_m2, want_m3)}'


@cocotb.test()
async def test_package_stays_to_the_end(dut):
    """The package is fully drawn on the last frames of its stage, right up to the
    wrap back to the first stage."""
    if GATES:
        return
    await start(dut, hold=1)
    for r in (236, 239):
        dut.stage.value = 8
        dut.r.value = r
        await at_pixel(dut, 320, 200)
        assert val(dut.pkg_vis) == 1, f'package not drawn at frame {r} of its stage'
