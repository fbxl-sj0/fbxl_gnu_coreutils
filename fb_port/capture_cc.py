#!/usr/bin/env python3
"""
Project: GNU Coreutils FreeBASIC port
File: capture_cc.py
Purpose: Record the compiler invocations used by the C reference build.
Responsibilities: Capture working directories, arguments, and object paths in
independent JSON files, then execute the configured C compiler unchanged.
This file intentionally does NOT contain: C translation or compiler emulation.
"""

import json
import os
from pathlib import Path
import sys
import tempfile


def main():
    compiler = os.environ.get("COREUTILS_REAL_CC", "/usr/bin/gcc")
    capture_directory = os.environ.get("COREUTILS_CAPTURE_DIRECTORY")
    arguments = sys.argv[1:]
    sources = [argument for argument in arguments
               if not argument.startswith("-") and argument.endswith(".c")]
    if capture_directory and "-c" in arguments:
        directory = Path(capture_directory)
        directory.mkdir(parents=True, exist_ok=True)
        # Separate files avoid shared append state when make runs concurrently.
        for source in sources:
            entry = {
                "directory": os.getcwd(),
                "file": source,
                "arguments": [compiler, *arguments],
            }
            if "-o" in arguments:
                output_position = arguments.index("-o") + 1
                if output_position >= len(arguments):
                    raise ValueError("C compiler -o option has no output path")
                entry["output"] = arguments[output_position]
            with tempfile.NamedTemporaryFile(
                    mode="w", encoding="utf-8", suffix=".json",
                    prefix="compile-", dir=directory, delete=False) as capture:
                json.dump(entry, capture, indent=2)
                capture.write("\n")
    os.execv(compiler, [compiler, *arguments])


if __name__ == "__main__":
    main()

# end of capture_cc.py
