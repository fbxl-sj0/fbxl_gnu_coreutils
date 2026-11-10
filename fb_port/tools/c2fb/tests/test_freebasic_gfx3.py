#!/usr/bin/env python3
"""
Project: SQLite FreeBASIC port tools
File: test_freebasic_gfx3.py
Purpose: Validate a GFXLIB3 platform logger port and its C2FB candidate.
Responsibilities: Check Basic source selection, translate and compile the C
  source, then compare stderr behavior for the candidate and reviewed Basic port.
This file intentionally does NOT contain: Full GFXLIB3 or rendering tests.
"""

import argparse
import platform
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path


SOURCE_RELATIVE_PATH = "core/gfx3_debug_platform.c"
BASIC_RELATIVE_PATH = "core/gfx3_debug_platform.bas"


def run(command, **options):
    result = subprocess.run(
        command, capture_output=True, text=True, **options
    )
    if result.returncode:
        raise RuntimeError(
            f"Command failed with status {result.returncode}: "
            f"{shlex.join(map(str, command))}\n"
            f"{result.stdout}{result.stderr}"
        )
    return result.stdout


def run_capture(command, expected_stderr, **options):
    result = subprocess.run(
        command, capture_output=True, text=True, **options
    )
    if result.returncode or result.stdout or result.stderr != expected_stderr:
        raise AssertionError(
            f"Command failed with status {result.returncode}: "
            f"{shlex.join(map(str, command))}\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}\n"
            f"expected stderr={expected_stderr!r}"
        )


def check_gfx3_source_graph(source_root):
    make_output = run([
        "make", "-s", "-C", str(source_root.parent), "-pn",
    ])
    variables = {}
    for line in make_output.splitlines():
        match = re.match(r"^(GFX3_SRC(?:_FB|_C)?) := (.*)$", line)
        if match is not None:
            variables[match.group(1)] = match.group(2).split()

    basic_source = str(
        (source_root / "gfxlib3" / BASIC_RELATIVE_PATH).resolve()
    )
    c_peer = str(
        (source_root / "gfxlib3" / SOURCE_RELATIVE_PATH).resolve()
    )
    selected = set(variables.get("GFX3_SRC", ()))
    if basic_source not in variables.get("GFX3_SRC_FB", ()) or \
       basic_source not in selected:
        raise AssertionError(
            "GFXLIB3 Make graph did not select the Basic debug platform unit"
        )
    if c_peer in selected or c_peer in variables.get("GFX3_SRC_C", ()):
        raise AssertionError("GFXLIB3 Make graph retained the replaced C peer")
    print("GFXLIB3 source graph: Basic debug writer selected; C peer replaced")


def compile_source_unit_candidate(converter, fbc, cc, source_root,
                                  profile_directory, work):
    gfx3_directory = source_root / "gfxlib3"
    candidate_directory = work / "gfx3-candidates"
    source_unit_tool = Path(__file__).resolve().parents[1] / "c2fb_source_unit.py"
    summary = run([
        sys.executable, str(source_unit_tool),
        str(gfx3_directory), str(candidate_directory), "--tree",
        "--source-pattern=" + SOURCE_RELATIVE_PATH,
        "--converter", converter, "--compiler", cc[0],
        "--include-header-types",
        "--body-option=--rename-proc-prefix=c2fbGfx3_",
        "--header-option=@" + str(
            profile_directory / "freebasic-linux-glibc-x86_64.rsp"),
        "--body-option=@" + str(
            profile_directory / "freebasic-linux-glibc-x86_64-body.rsp"),
        "--header-compiler-option=" + f"-I{source_root / 'rtlib'}",
        "--body-compiler-option=" + f"-I{source_root / 'rtlib'}",
        "--header-compiler-option=" + f"-I{gfx3_directory}",
        "--body-compiler-option=" + f"-I{gfx3_directory}",
        "--header-compiler-option=" + f"-I{source_root / 'gfxlib2'}",
        "--body-compiler-option=" + f"-I{source_root / 'gfxlib2'}",
    ])
    if "processed 1 C files; failed 0" not in summary:
        raise AssertionError(summary)
    if "translated 1 simple functions; skipped 0" not in summary:
        raise AssertionError(summary)

    candidate = candidate_directory / Path(SOURCE_RELATIVE_PATH).parent / (
        Path(SOURCE_RELATIVE_PATH).stem + "_candidates.bas"
    )
    object_path = candidate.with_suffix(".o")
    run(fbc + [
        "-w", "all", "-c", str(candidate), "-o", str(object_path),
        "-i", str(candidate.parent),
        "-i", str(source_root.parent / "inc"),
        "-i", str(source_root / "rtlib"),
        "-i", str(gfx3_directory),
    ], cwd=candidate.parent)
    return object_path


def compile_c_reference(source_root, cc, work):
    source = source_root / "gfxlib3" / SOURCE_RELATIVE_PATH
    object_path = work / "gfx3_debug_platform_c_reference.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        "-include", "sys/types.h",
        "-Dfb_gfx3_debug_platform_write=fb_gfx3_debug_platform_writeC",
        f"-I{source_root / 'rtlib'}", f"-I{source_root / 'gfxlib3'}",
        "-c", str(source), "-o", str(object_path),
    ], cwd=work)
    return object_path


def compile_test_main(fbc, source_root, work, module_object,
                      reference_object, label):
    main_source = work / "gfx3_debug_platform_test.bas"
    main_source.write_text(
        'Declare Sub debugWriteC CDecl Alias "fb_gfx3_debug_platform_writeC" ( _\n'
        '    ByVal level As Long, _\n'
        '    ByVal labelText As Const ZString Ptr, _\n'
        '    ByVal messageText As Const ZString Ptr _\n'
        ')\n'
        'Declare Sub debugWriteTarget CDecl Alias "fb_gfx3_debug_platform_write" ( _\n'
        '    ByVal level As Long, _\n'
        '    ByVal labelText As Const ZString Ptr, _\n'
        '    ByVal messageText As Const ZString Ptr _\n'
        ')\n'
        'Function main() As Integer\n'
        '    Dim nullText As ZString Ptr = 0\n'
        '    Dim labelText As String = "Window"\n'
        '    Dim messageText As String = "display ready"\n'
        '    debugWriteC(9, nullText, StrPtr(messageText))\n'
        '    debugWriteTarget(-2, nullText, StrPtr(messageText))\n'
        '    debugWriteC(9, StrPtr(labelText), nullText)\n'
        '    debugWriteTarget(-2, StrPtr(labelText), nullText)\n'
        '    debugWriteC(9, StrPtr(labelText), StrPtr(messageText))\n'
        '    debugWriteTarget(-2, StrPtr(labelText), StrPtr(messageText))\n'
        '    Return 0\n'
        'End Function\n'
        'End main()\n'
    )
    executable = work / ("gfx3_debug_platform_" + label)
    run(fbc + [
        "-w", "all", "-i", str(source_root.parent / "inc"),
        str(main_source), str(module_object), str(reference_object),
        "-x", str(executable),
    ], cwd=work)
    run_capture(
        [str(executable)],
        "gfxlib3 Window: display ready\n"
        "gfxlib3 Window: display ready\n",
        cwd=work,
    )


def check_reviewed_basic_port(fbc, source_root, work, reference_object):
    source = source_root / "gfxlib3" / BASIC_RELATIVE_PATH
    object_path = work / "gfx3_debug_platform_basic.o"
    run(fbc + [
        "-w", "all", "-c", "-i", str(source_root.parent / "inc"),
        str(source), "-o", str(object_path),
    ], cwd=work)
    compile_test_main(
        fbc, source_root, work, object_path, reference_object, "basic",
    )


def check_c2fb_candidate(fbc, source_root, work, candidate_object,
                         reference_object):
    compile_test_main(
        fbc, source_root, work, candidate_object, reference_object, "c2fb",
    )


def main():
    parser = argparse.ArgumentParser(
        description="Run focused FreeBASIC GFXLIB3 source checks."
    )
    parser.add_argument("--converter", required=True)
    parser.add_argument("--fbc", default="fbc")
    parser.add_argument("--cc", default="cc")
    parser.add_argument("--source-directory", required=True)
    parser.add_argument(
        "--profile-directory",
        default=str(Path(__file__).resolve().parents[1] / "profiles"),
    )
    args = parser.parse_args()
    if platform.system() != "Linux" or platform.machine().lower() not in (
        "x86_64", "amd64",
    ):
        parser.error("the current GFXLIB3 C2FB profile requires Linux x86-64")

    fbc = shlex.split(args.fbc)
    cc = shlex.split(args.cc)
    if not fbc or not cc:
        parser.error("--fbc and --cc must each contain a command")
    source_root = Path(args.source_directory).resolve()
    source = source_root / "gfxlib3" / SOURCE_RELATIVE_PATH
    if not source.is_file():
        parser.error(f"GFXLIB3 source file is missing: {source}")
    profile_directory = Path(args.profile_directory).resolve()

    with tempfile.TemporaryDirectory(prefix="c2fb-freebasic-gfx3-") as temp:
        work = Path(temp)
        check_gfx3_source_graph(source_root)
        candidate_object = compile_source_unit_candidate(
            args.converter, fbc, cc, source_root, profile_directory, work,
        )
        reference_object = compile_c_reference(source_root, cc, work)
        check_c2fb_candidate(
            fbc, source_root, work, candidate_object,
            reference_object,
        )
        check_reviewed_basic_port(
            fbc, source_root, work, reference_object,
        )
        print("GFXLIB3 debug writer: C2FB candidate and Basic port match C stderr behavior")


if __name__ == "__main__":
    main()

# end of test_freebasic_gfx3.py
