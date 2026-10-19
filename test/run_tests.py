"""Run a cocotb unit test without make (works on Windows and Linux).

Usage (from the test/ folder):
    python run_tests.py timer              # src/timer.v + test_timer.py
    python run_tests.py processor timer    # extra modules the unit instantiates
"""
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

if len(sys.argv) < 2:
    sys.exit(__doc__)

unit, *deps = sys.argv[1:]
test_dir = Path(__file__).parent
src_dir = test_dir.parent / "src"

runner = get_runner("icarus")
runner.build(
    sources=[src_dir / f"{name}.v" for name in [unit, *deps]],
    hdl_toplevel=unit,
    build_args=["-g2012"],
    build_dir=test_dir / "sim_build" / unit,
    always=True,
    timescale=("1ns", "1ps"),  # without this, Icarus can't represent a 10 ns clock
)
runner.test(hdl_toplevel=unit, test_module=f"test_{unit}", test_dir=test_dir)
