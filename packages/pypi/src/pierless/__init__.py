"""pierless — a Python entry point that hands off to the bundled bash CLI.

The scripts are the product; this package only puts them on PATH. exec
rather than subprocess so the shell script owns the terminal, the signals
and the exit status directly, with no Python process left in between.
"""

import os
import sys
from pathlib import Path

__all__ = ["main"]


def main():
    cli = Path(__file__).parent / "bin" / "pierless"
    try:
        os.execvp("bash", ["bash", str(cli), *sys.argv[1:]])
    except FileNotFoundError:
        print("pierless: bash is required and was not found on PATH", file=sys.stderr)
        sys.exit(1)
