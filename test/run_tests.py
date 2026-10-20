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

# Files whose module name differs from the file name. Tiny Tapeout requires the
# top-level module to be named tt_um_<something>, independent of the file name.
MODULE_NAME_BY_FILE = {"tt_um_": "tt_um_example"}
toplevel = MODULE_NAME_BY_FILE.get(unit, unit)

runner = get_runner("icarus")
runner.build(
    sources=[src_dir / f"{name}.v" for name in [unit, *deps]],
    hdl_toplevel=toplevel,
    build_args=["-g2012"],
    build_dir=test_dir / "sim_build" / unit,
    always=True,
    timescale=("1ns", "1ps"),  # without this, Icarus can't represent a 10 ns clock
)
# Runs test_<unit>.py plus any test_<unit>_*.py (e.g. test_processor_spi.py).
test_modules = sorted(p.stem for p in test_dir.glob(f"test_{unit}*.py"))
runner.test(hdl_toplevel=toplevel, test_module=test_modules, test_dir=test_dir)