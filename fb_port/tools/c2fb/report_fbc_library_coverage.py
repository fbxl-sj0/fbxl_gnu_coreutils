#!/usr/bin/env python3
"""
Project: SQLite FreeBASIC port tools
File: report_fbc_library_coverage.py
Purpose: Measure C2FB-integrated Basic units in the active FBC library graph.
Responsibilities: Read Make source lists, identify translated Basic modules,
  and report selected C and Basic source counts in text or JSON form.
This file intentionally does NOT contain: C translation or candidate scoring.
"""

import argparse
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path


SOURCE_VARIABLE_RE = re.compile(
    r"^(RTLIB|GFX|GFX3|SFX)_SRC(?:_(FB|C))? := (.*)$"
)
C2FB_MARKERS = ("c2fb translated", "translated with c2fb")
LIBRARIES = (
    ("RTLIB", "RTLIB"),
    ("GFXLIB2", "GFX"),
    ("GFXLIB3", "GFX3"),
    ("SFXLIB", "SFX"),
)


def parse_source_graph(make_output):
    """Return the active FBC source lists printed by `make -pn`."""
    variables = {}
    for line in make_output.splitlines():
        match = SOURCE_VARIABLE_RE.match(line)
        if match is None:
            continue
        suffix = "" if match.group(2) is None else "_" + match.group(2)
        variables[match.group(1) + "_SRC" + suffix] = shlex.split(match.group(3))

    missing = [prefix + "_SRC" for _, prefix in LIBRARIES
               if prefix + "_SRC" not in variables]
    if missing:
        raise ValueError("Make output omitted source lists: " + ", ".join(missing))
    return variables


def is_c2fb_translated(source):
    """Identify reviewed Basic source files carrying a C2FB provenance mark."""
    contents = Path(source).read_text(errors="replace").lower()
    return any(marker in contents for marker in C2FB_MARKERS)


def relative_to_source_root(path, source_root):
    try:
        return path.relative_to(source_root).as_posix()
    except ValueError:
        return path.as_posix()


def percent(numerator, denominator):
    if denominator == 0:
        return 0.0
    return round(100.0 * numerator / denominator, 1)


def build_report(source_root, variables):
    """Summarize only source units selected by the active FBC Make graph."""
    source_root = Path(source_root).resolve()
    libraries = {}

    for name, prefix in LIBRARIES:
        selected = {
            Path(path).resolve()
            for path in variables[prefix + "_SRC"]
        }
        basic = {
            Path(path).resolve()
            for path in variables.get(prefix + "_SRC_FB", ())
        }
        c_sources = {
            Path(path).resolve()
            for path in variables.get(prefix + "_SRC_C", ())
        }
        if not basic <= selected or not c_sources <= selected:
            raise ValueError(name + " source subsets are not included in its selected graph")

        translated = sorted(
            (path for path in basic if is_c2fb_translated(path)),
            key=lambda path: path.as_posix(),
        )
        peers_still_selected = sorted(
            (path for path in translated if path.with_suffix(".c") in c_sources),
            key=lambda path: path.as_posix(),
        )
        selected_count = len(selected)
        libraries[name] = {
            "selected_source_units": selected_count,
            "selected_c_units": len(c_sources),
            "selected_basic_units": len(basic),
            "unmarked_basic_units": len(basic) - len(translated),
            "c2fb_marked_basic_units": len(translated),
            "c2fb_marked_percent": percent(len(translated), selected_count),
            "basic_percent": percent(len(basic), selected_count),
            "c2fb_basic_units_with_c_peer_selected": [
                relative_to_source_root(path, source_root)
                for path in peers_still_selected
            ],
            "c2fb_basic_units": [
                relative_to_source_root(path, source_root)
                for path in translated
            ],
        }

    totals = {
        key: sum(library[key] for library in libraries.values())
        for key in (
            "selected_source_units",
            "selected_c_units",
            "selected_basic_units",
            "unmarked_basic_units",
            "c2fb_marked_basic_units",
        )
    }
    totals["c2fb_marked_percent"] = percent(
        totals["c2fb_marked_basic_units"], totals["selected_source_units"]
    )
    totals["basic_percent"] = percent(
        totals["selected_basic_units"], totals["selected_source_units"]
    )

    return {
        "schema_version": 1,
        "fbc_source_root": str(source_root),
        "scope": "source units selected by the active FBC Make graph",
        "candidate_outputs_counted_as_integrated": False,
        "libraries": libraries,
        "totals": totals,
    }


def load_report(source_root, make_executable, make_arguments):
    command = [
        make_executable,
        "-s",
        "-C",
        str(source_root),
        "-pn",
        *make_arguments,
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(
            "Make source-graph query failed with status "
            + str(result.returncode)
            + ":\n"
            + result.stderr[-4000:]
        )
    variables = parse_source_graph(result.stdout)
    report = build_report(source_root / "src", variables)
    report["make_arguments"] = list(make_arguments)
    return report


def text_report(report):
    lines = [
        "C2FB integration coverage for the active FreeBASIC Make source graph",
        "Library   C2FB Basic / selected   Basic / selected   C units   Unmarked Basic",
    ]
    if report["make_arguments"]:
        lines.append("Make arguments: " + " ".join(report["make_arguments"]))
    for name, _ in LIBRARIES:
        item = report["libraries"][name]
        lines.append(
            f"{name:<9} "
            f"{item['c2fb_marked_basic_units']:>4}/{item['selected_source_units']:<4} "
            f"({item['c2fb_marked_percent']:>4.1f}%)          "
            f"{item['selected_basic_units']:>4}/{item['selected_source_units']:<4} "
            f"({item['basic_percent']:>4.1f}%)       "
            f"{item['selected_c_units']:>4}       "
            f"{item['unmarked_basic_units']:>4}"
        )

    totals = report["totals"]
    lines.extend((
        f"Total     {totals['c2fb_marked_basic_units']}/"
        f"{totals['selected_source_units']} ({totals['c2fb_marked_percent']:.1f}%) "
        f"C2FB-marked; {totals['selected_basic_units']}/"
        f"{totals['selected_source_units']} ({totals['basic_percent']:.1f}%) Basic",
        "Only selected source units are counted; generated candidates are not integrated ports.",
    ))
    peer_conflicts = [
        unit
        for item in report["libraries"].values()
        for unit in item["c2fb_basic_units_with_c_peer_selected"]
    ]
    if peer_conflicts:
        lines.append("C2FB-marked Basic units whose C peer remains selected:")
        lines.extend("  " + unit for unit in peer_conflicts)
    return "\n".join(lines)


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--fbc-root",
        required=True,
        type=Path,
        help="FreeBASIC source-tree root containing GNUmakefile and src/",
    )
    parser.add_argument("--make", default="make", help="GNU Make executable")
    parser.add_argument(
        "--make-arg",
        action="append",
        default=[],
        metavar="NAME=VALUE",
        help="pass a Make variable to select a target source graph; repeatable",
    )
    parser.add_argument("--format", choices=("text", "json"), default="text")
    parser.add_argument(
        "--fail-on-c2fb-peer",
        action="store_true",
        help="fail if a C2FB-marked Basic unit and its C peer are both selected",
    )
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_arguments(argv)
    source_root = args.fbc_root.resolve()
    if not (source_root / "GNUmakefile").is_file():
        print("ERROR: --fbc-root must contain GNUmakefile", file=sys.stderr)
        return 2

    try:
        report = load_report(source_root, args.make, args.make_arg)
    except (OSError, RuntimeError, ValueError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        return 2

    if args.format == "json":
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(text_report(report))

    if args.fail_on_c2fb_peer and any(
        item["c2fb_basic_units_with_c_peer_selected"]
        for item in report["libraries"].values()
    ):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


# end of report_fbc_library_coverage.py
