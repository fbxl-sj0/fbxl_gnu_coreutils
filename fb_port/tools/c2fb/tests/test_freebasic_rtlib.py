#!/usr/bin/env python3
"""
Project: SQLite FreeBASIC port tools
File: test_freebasic_rtlib.py
Purpose: Validate reviewed FreeBASIC RTLIB wrappers and matching C2FB candidates.
Responsibilities: Compile the selected RTLIB Basic units, exercise their C ABI,
  and translate/compile their original C source units.
This file intentionally does NOT contain: Full RTLIB archive or fbctests runs.
"""

import argparse
import ctypes
import json
import platform
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path


RTLIB_SOURCES = (
    "legacy/legacy_str_lcase.c",
    "legacy/legacy_str_ucase.c",
    "strings/str_asc.c",
    "strings/str_chr.c",
    "strings/str_bin.c",
    "strings/str_bin_lng.c",
    "strings/str_bin_ptr.c",
    "strings/str_hex.c",
    "strings/str_hex_lng.c",
    "strings/str_hex_ptr.c",
    "strings/str_oct.c",
    "strings/str_oct_lng.c",
    "strings/str_oct_ptr.c",
    "strings/str_len.c",
    "strings/str_fill.c",
    "strings/str_left.c",
    "strings/str_right.c",
    "strings/str_reverse.c",
    "strings/str_hskip.c",
    "strings/str_ltrim.c",
    "strings/str_ltrimex.c",
    "strings/str_rtrim.c",
    "strings/str_rtrimex.c",
    "strings/str_trim.c",
    "strings/str_trimex.c",
)
RTLIB_BASIC_SOURCES = tuple(
    str(Path(source).with_suffix(".bas")) for source in RTLIB_SOURCES
)
RTLIB_C2FB_STRING_ARCH_STEMS = (
    "str_asc", "str_chr", "str_bin", "str_bin_lng", "str_bin_ptr",
    "str_hex", "str_hex_lng", "str_hex_ptr", "str_oct", "str_oct_lng",
    "str_oct_ptr", "str_len", "str_fill", "str_left", "str_right", "str_reverse",
    "str_hskip",
    "str_ltrim", "str_ltrimex", "str_rtrim", "str_rtrimex",
    "str_trim", "str_trimex",
)


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


def check_rtlib_source_graph(source_root):
    make_output = run([
        "make", "-s", "-C", str(source_root.parent), "-pn",
    ])
    variables = {}
    for line in make_output.splitlines():
        match = re.match(r"^(RTLIB_SRC(?:_FB|_C)?|LIBFB_BI) := (.*)$", line)
        if match is not None:
            variables[match.group(1)] = match.group(2).split()

    basic_sources = {
        str((source_root / "rtlib" / source).resolve())
        for source in RTLIB_BASIC_SOURCES
    }
    for stem in RTLIB_C2FB_STRING_ARCH_STEMS:
        basic_sources.remove(
            str((source_root / f"rtlib/strings/{stem}.bas").resolve())
        )
        basic_sources.add(str(
            (source_root / f"rtlib/strings/linux/x86_64/{stem}.bas").resolve()
        ))
    wide_basic_sources = {
        str((source_root / "rtlib/strings/wide/linux" / f"{stem}.bas").resolve())
        for stem in (
            "strw_convto", "strw_convto_bool", "strw_convto_flt",
            "strw_convto_lng", "strw_ftoa",
        )
    }
    math_basic_sources = {
        str((source_root / "rtlib/math/linux/math_rnd.bas").resolve())
    }
    c_peers = {
        str((source_root / "rtlib" / source).resolve())
        for source in RTLIB_SOURCES
    }
    math_c_peer = str((source_root / "rtlib/math/math_rnd.c").resolve())
    if not (basic_sources | wide_basic_sources | math_basic_sources) <= \
       set(variables.get("RTLIB_SRC_FB", ())):
        raise AssertionError("RTLIB Make graph omitted a Basic module")
    if not (basic_sources | wide_basic_sources | math_basic_sources) <= \
       set(variables.get("RTLIB_SRC", ())):
        raise AssertionError("selected RTLIB sources omitted a Basic module")
    if (c_peers | {math_c_peer}) & set(variables.get("RTLIB_SRC", ())):
        raise AssertionError("selected RTLIB sources retained a replaced C peer")
    if (c_peers | {math_c_peer}) & set(variables.get("RTLIB_SRC_C", ())):
        raise AssertionError("RTLIB C object list retained a replaced C peer")
    wide_c_peers = {
        str((source_root / "rtlib/strings/wide" / f"{stem}.c").resolve())
        for stem in (
            "strw_convto", "strw_convto_bool", "strw_convto_flt",
            "strw_convto_lng", "strw_ftoa",
        )
    }
    if wide_c_peers & set(variables.get("RTLIB_SRC", ())):
        raise AssertionError("selected RTLIB sources retained a wide-string C peer")
    if wide_c_peers & set(variables.get("RTLIB_SRC_C", ())):
        raise AssertionError("RTLIB C object list retained a wide-string C peer")
    string_includes = {
        str((source_root / "rtlib/strings" / name).resolve())
        for name in ("fb_string.bi", "fb_string_runtime.bi")
    }
    if not string_includes <= set(variables.get("LIBFB_BI", ())):
        raise AssertionError("RTLIB build dependencies omitted a shared string .bi")
    math_initializer_context = str(
        (source_root / "rtlib/math/linux/math_rnd_types.bi").resolve()
    )
    if math_initializer_context not in set(variables.get("LIBFB_BI", ())):
        raise AssertionError("RTLIB build dependencies omitted the math C2FB type context")
    string_c2fb_type_contexts = {
        str((source_root / f"rtlib/strings/linux/x86_64/{stem}_types.bi").resolve())
        for stem in RTLIB_C2FB_STRING_ARCH_STEMS
    }
    if not string_c2fb_type_contexts <= set(variables.get("LIBFB_BI", ())):
        raise AssertionError("RTLIB build dependencies omitted a C2FB string type context")
    compile_rules = (source_root.parent / "mk/build/compile-rules.mk").read_text()
    if compile_rules.count(
        "$(srcdir)/rtlib/%.bas $(LIBFB_H) $(LIBFB_BI)"
    ) != 4:
        raise AssertionError("RTLIB Basic object variants do not depend on RTLIB .bi files")
    print(
        f"RTLIB source graph: "
        f"{len(basic_sources | wide_basic_sources | math_basic_sources)} "
        "Basic units selected; C peers replaced; Basic includes tracked"
    )


def check_rtlib_graph_precedence(source_root, work):
    fixture_root = work / "rtlib-graph-fixture"
    fixture_source = fixture_root / "src"
    fixtures = {
        "rtlib/core/core_keep.c": "",
        "rtlib/legacy/legacy_str_lcase.c": "",
        "rtlib/legacy/legacy_str_lcase.bas": "",
        "rtlib/strings/wide/strw_convto.c": "",
        "rtlib/strings/wide/linux/strw_convto.bas": "",
        "rtlib/system/target_only.c": "",
        "rtlib/drivers/linux/target_only.bas": "",
        "rtlib/console/unix_only.c": "",
        "rtlib/drivers/unix/unix_only.bas": "",
        "rtlib/math/arch_pick.c": "",
        "rtlib/math/math_keep.c": "",
        "rtlib/drivers/linux/arch_pick.c": "",
        "rtlib/drivers/linux/x86_64/arch_pick.bas": "",
        "rtlib/math/target_pick.c": "",
        "rtlib/math/linux/target_pick.bas": "",
        "rtlib/math/linux/math_only.bas": "",
        "rtlib/math/linux/x86_64/target_pick.bas": "",
    }
    for stem in RTLIB_C2FB_STRING_ARCH_STEMS:
        fixtures[f"rtlib/strings/{stem}.c"] = ""
        fixtures[f"rtlib/strings/{stem}.bas"] = ""
        fixtures[f"rtlib/strings/linux/{stem}.bas"] = ""
        fixtures[f"rtlib/strings/linux/x86_64/{stem}.bas"] = ""
    for relative_path, contents in fixtures.items():
        path = fixture_source / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)

    makefile = fixture_root / "source-graph.mk"
    makefile.write_text(
        f"srcdir := {fixture_source}\n"
        "USE_UNIX_LAYER := yes\n"
        "TARGET_OS := linux\n"
        "SOURCE_OS := linux\n"
        "TARGET_ARCH := x86_64\n"
        f"include {source_root.parent / 'mk/rtlib-sources.mk'}\n"
        ".PHONY: print-source-graph\n"
        "print-source-graph:\n"
        "\t@printf '%s\\n' $(RTLIB_SRC)\n"
    )
    selected = set(run([
        "make", "-s", "-f", str(makefile), "print-source-graph",
    ], cwd=fixture_root).splitlines())
    expected = {
        str((fixture_source / "rtlib/core/core_keep.c").resolve()),
        str((fixture_source / "rtlib/legacy/legacy_str_lcase.bas").resolve()),
        str((fixture_source / "rtlib/strings/wide/linux/strw_convto.bas").resolve()),
        str((fixture_source / "rtlib/drivers/linux/target_only.bas").resolve()),
        str((fixture_source / "rtlib/drivers/unix/unix_only.bas").resolve()),
        str((fixture_source / "rtlib/drivers/linux/x86_64/arch_pick.bas").resolve()),
        str((fixture_source / "rtlib/math/math_keep.c").resolve()),
        str((fixture_source / "rtlib/math/linux/x86_64/target_pick.bas").resolve()),
        str((fixture_source / "rtlib/math/linux/math_only.bas").resolve()),
    }
    expected.update(
        str((fixture_source / f"rtlib/strings/linux/x86_64/{stem}.bas").resolve())
        for stem in RTLIB_C2FB_STRING_ARCH_STEMS
    )
    if selected != expected:
        raise AssertionError(
            "RTLIB platform-source precedence mismatch: "
            f"expected={sorted(expected)}, selected={sorted(selected)}"
        )
    print("RTLIB source graph: generic, Unix, target, and target-arch precedence passed")


def check_c2fb_candidates(converter, fbc, cc, source_root,
                          profile_directory, work):
    rtlib_directory = source_root / "rtlib"
    candidate_directory = work / "rtlib-candidates"
    source_unit_tool = Path(__file__).resolve().parents[1] / "c2fb_source_unit.py"
    summary = run([
        sys.executable, str(source_unit_tool),
        str(rtlib_directory), str(candidate_directory), "--tree",
        *(f"--source-pattern={source}" for source in RTLIB_SOURCES),
        "--converter", converter, "--compiler", cc[0],
        "--unit-manifest", str(
            profile_directory / "freebasic-rtlib-linux-x86_64-units.json"),
        "--fb-source-directory", str(rtlib_directory),
        "--header-option=@" + str(
            profile_directory / "freebasic-linux-glibc-x86_64.rsp"),
        "--body-option=@" + str(
            profile_directory / "freebasic-linux-glibc-x86_64-body.rsp"),
        "--header-option=--emit-source=*fb.h",
        "--header-option=--emit-source=*fb_*.h",
        "--body-option=--rename-proc-prefix=c2fbRtl_",
        "--header-compiler-option=" + f"-I{rtlib_directory}",
        "--body-compiler-option=" + f"-I{rtlib_directory}",
        "--header-compiler-option=-DENABLE_MT",
        "--body-compiler-option=-DENABLE_MT",
    ])
    if f"processed {len(RTLIB_SOURCES)} C files; failed 0" not in summary:
        raise AssertionError(summary)

    expected_functions = {
        "legacy_str_lcase": 1,
        "legacy_str_ucase": 1,
        "str_asc": 1,
        "str_chr": 1,
        "str_bin": 6,
        "str_bin_lng": 2,
        "str_bin_ptr": 2,
        "str_hex": 6,
        "str_hex_lng": 2,
        "str_hex_ptr": 2,
        "str_oct": 6,
        "str_oct_lng": 2,
        "str_oct_ptr": 2,
        "str_len": 1,
        "str_fill": 2,
        "str_left": 1,
        "str_right": 1,
        "str_reverse": 1,
        "str_hskip": 2,
        "str_ltrim": 1,
        "str_ltrimex": 1,
        "str_rtrim": 1,
        "str_rtrimex": 1,
        "str_trim": 1,
        "str_trimex": 1,
    }
    counts = {
        Path(output).stem.removesuffix("_candidates"): (
            int(translated), int(skipped)
        )
        for translated, skipped, output in re.findall(
            r"translated (\d+) simple functions; skipped (\d+) "
            r"unsupported or duplicate candidates; output (.+)",
            summary,
        )
    }
    if set(counts) != set(expected_functions) or any(
        counts[stem] != (translated, 0)
        for stem, translated in expected_functions.items()
    ):
        raise AssertionError(summary)

    candidates = sorted(candidate_directory.rglob("*_candidates.bas"))
    if len(candidates) != len(RTLIB_SOURCES):
        raise AssertionError(summary)
    for stem in ("str_left", "str_right", "str_reverse"):
        candidate = candidate_directory / "strings" / f"{stem}_candidates.bas"
        generated = candidate.read_text()
        if (
            '"strings/fb_string_runtime.bi"' not in generated
            or "fb_StrLockImpl()" not in generated
            or "fb_StrUnlockImpl()" not in generated
        ):
            raise AssertionError(
                f"{stem} C2FB candidate did not reuse the ENABLE_MT string locks"
            )
    for stem in RTLIB_C2FB_STRING_ARCH_STEMS:
        type_context = candidate_directory / "strings" / f"{stem}_candidates_types.bi"
        generated_types = type_context.read_text(encoding="utf-8")
        if re.search(r"^Type _c2fb_record_", generated_types, re.MULTILINE):
            raise AssertionError(
                f"{stem} C2FB context retained an unrelated C record"
            )
    str_len_candidate = candidate_directory / "strings/str_len_candidates.bas"
    str_len_body = str_len_candidate.read_text(encoding="utf-8")
    if '"strings/fb_string_runtime.bi"' not in str_len_body or \
       "fb_hStrDelTempImpl(" not in str_len_body:
        raise AssertionError("str_len C2FB candidate did not reuse the RTLIB string helper")
    str_fill_body = (
        candidate_directory / "strings/str_fill_candidates.bas"
    ).read_text(encoding="utf-8")
    if "fb_hStrAllocTempImpl(" not in str_fill_body or \
       "FB_RTLIB_CTX_PREFIX" not in str_fill_body:
        raise AssertionError("str_fill C2FB candidate did not reuse the RTLIB string context")
    for stem in ("str_left", "str_right", "str_ltrim", "str_ltrimex",
                 "str_rtrim", "str_rtrimex", "str_trim", "str_trimex"):
        body = (candidate_directory / f"strings/{stem}_candidates.bas").read_text(
            encoding="utf-8"
        )
        if '"strings/fb_string_runtime.bi"' not in body:
            raise AssertionError(f"{stem} C2FB candidate did not reuse shared string helpers")
    for candidate in candidates:
        run(fbc + [
            "-w", "all", "-c", str(candidate),
            "-mt", "-d", "ENABLE_MT",
            "-o", str(candidate.with_suffix(".o")),
            "-i", str(candidate.parent),
            "-i", str(source_root.parent / "inc"),
            "-i", str(rtlib_directory),
        ], cwd=candidate.parent)
    print(
        f"RTLIB C2FB candidates: {len(candidates)} C files, "
        f"{sum(expected_functions.values())} procedures translated, "
        "0 skipped; all candidate objects compiled"
    )
    return {
        candidate.stem.removesuffix("_candidates"): candidate.with_suffix(".o")
        for candidate in candidates
    }


def check_c2fb_wide_bool_candidate(converter, fbc, cc, source_root,
                                  profile_directory, work):
    rtlib_directory = source_root / "rtlib"
    candidate_directory = work / "rtlib-wide-bool-candidate"
    report_path = work / "rtlib-wide-bool-report.json"
    source_unit_tool = Path(__file__).resolve().parents[1] / "c2fb_source_unit.py"
    summary = run([
        sys.executable, str(source_unit_tool),
        str(rtlib_directory), str(candidate_directory), "--tree",
        "--source-pattern=strings/wide/strw_convto_bool.c",
        "--converter", converter, "--compiler", cc[0],
        "--unit-manifest", str(
            profile_directory / "freebasic-rtlib-linux-x86_64-units.json"),
        "--fb-source-directory", str(rtlib_directory),
        "--header-option=@" + str(
            profile_directory / "freebasic-linux-glibc-x86_64.rsp"),
        "--body-option=@" + str(
            profile_directory / "freebasic-linux-glibc-x86_64-body.rsp"),
        "--header-option=--emit-source=*fb.h",
        "--header-option=--emit-source=*fb_*.h",
        "--body-option=--rename-proc-prefix=c2fbRtl_",
        "--header-compiler-option=" + f"-I{rtlib_directory}",
        "--body-compiler-option=" + f"-I{rtlib_directory}",
        "--header-compiler-option=-DENABLE_MT",
        "--body-compiler-option=-DENABLE_MT",
        "--report-json", str(report_path),
    ])
    if "processed 1 C files; failed 0" not in summary:
        raise AssertionError(summary)

    report = json.loads(report_path.read_text())
    if report["totals"]["failed_source_files"] != 0 or \
       report["totals"]["unsupported_or_duplicate_candidates"] != 0:
        raise AssertionError(report)
    if report["totals"]["translated_simple_functions"] < 2:
        raise AssertionError(report)

    candidate = (
        candidate_directory / "strings/wide/strw_convto_bool_candidates.bas"
    )
    generated = candidate.read_text()
    for procedure in ("fb_hBoolToWstr", "fb_BoolToWstr"):
        if f"Function c2fbRtl_{procedure}" not in generated:
            raise AssertionError(
                f"wide boolean string candidate omitted {procedure}"
            )

    reference_object = work / "rtlib-wide-bool-reference.o"
    run(cc + [
        "-std=c99", "-O2", "-DENABLE_MT", "-include", "sys/types.h",
        "-I" + str(rtlib_directory),
        "-Dfb_hBoolToWstr=fbRef_hBoolToWstr",
        "-Dfb_BoolToWstr=fbRef_BoolToWstr",
        "-c", str(rtlib_directory / "strings/wide/strw_convto_bool.c"),
        "-o", str(reference_object),
    ], cwd=work)
    driver = work / "rtlib-wide-bool-check.bas"
    driver.write_text(
        f'#include once "{candidate.as_posix()}"\n'
        'Declare Function fbRef_hBoolToWstr CDecl Alias "fbRef_hBoolToWstr" '
        "(ByVal num As Byte) As Long Ptr\n"
        'Declare Function fbRef_BoolToWstr CDecl Alias "fbRef_BoolToWstr" '
        "(ByVal num As Byte) As Long Ptr\n"
        'Declare Sub FreeWide CDecl Alias "free" (ByVal value As Any Ptr)\n'
        "For value As Long = 0 To 1\n"
        "    Dim actual As Long Ptr = c2fbRtl_fb_hBoolToWstr(value)\n"
        "    Dim expected As Long Ptr = fbRef_hBoolToWstr(value)\n"
        "    For index As Long = 0 To 5\n"
        "        If actual[index] <> expected[index] Then End 1\n"
        "        If actual[index] = 0 Then Exit For\n"
        "    Next\n"
        "    actual = c2fbRtl_fb_BoolToWstr(value)\n"
        "    expected = fbRef_BoolToWstr(value)\n"
        "    For index As Long = 0 To 5\n"
        "        If actual[index] <> expected[index] Then End 2\n"
        "        If actual[index] = 0 Then Exit For\n"
        "    Next\n"
        "    FreeWide(actual)\n"
        "    FreeWide(expected)\n"
        "Next\n"
    )
    executable = work / "rtlib-wide-bool-check"
    run(fbc + [
        "-w", "all", "-mt", "-d", "ENABLE_MT",
        "-i", str(source_root.parent / "inc"),
        "-i", str(rtlib_directory), "-i", str(candidate.parent),
        str(driver), str(reference_object), "-x", str(executable),
    ], cwd=work)
    run([str(executable)], cwd=work)

    integrated_source = (
        rtlib_directory / "strings/wide/linux/strw_convto_bool.bas"
    )
    if not integrated_source.is_file():
        raise AssertionError("Linux C2FB wide boolean string module is missing")
    if "translated with c2fb" not in integrated_source.read_text().lower():
        raise AssertionError("wide boolean string module lost its C2FB provenance")

    integrated_object = work / "rtlib-wide-bool-integrated.o"
    run(fbc + [
        "-w", "all", "-mt", "-d", "ENABLE_MT", "-c",
        "-o", str(integrated_object),
        "-i", str(source_root.parent / "inc"), "-i", str(rtlib_directory),
        str(integrated_source),
    ], cwd=work)

    integrated_driver = work / "rtlib-wide-bool-integrated-check.bas"
    integrated_driver.write_text(
        'Declare Function module_hBoolToWstr CDecl Alias "fb_hBoolToWstr" '
        "(ByVal num As Byte) As Long Ptr\n"
        'Declare Function module_BoolToWstr CDecl Alias "fb_BoolToWstr" '
        "(ByVal num As Byte) As Long Ptr\n"
        'Declare Function fbRef_hBoolToWstr CDecl Alias "fbRef_hBoolToWstr" '
        "(ByVal num As Byte) As Long Ptr\n"
        'Declare Function fbRef_BoolToWstr CDecl Alias "fbRef_BoolToWstr" '
        "(ByVal num As Byte) As Long Ptr\n"
        'Declare Sub FreeWide CDecl Alias "free" (ByVal value As Any Ptr)\n'
        "For value As Long = 0 To 1\n"
        "    Dim actual As Long Ptr = module_hBoolToWstr(value)\n"
        "    Dim expected As Long Ptr = fbRef_hBoolToWstr(value)\n"
        "    For index As Long = 0 To 5\n"
        "        If actual[index] <> expected[index] Then End 3\n"
        "        If actual[index] = 0 Then Exit For\n"
        "    Next\n"
        "    actual = module_BoolToWstr(value)\n"
        "    expected = fbRef_BoolToWstr(value)\n"
        "    For index As Long = 0 To 5\n"
        "        If actual[index] <> expected[index] Then End 4\n"
        "        If actual[index] = 0 Then Exit For\n"
        "    Next\n"
        "    FreeWide(actual)\n"
        "    FreeWide(expected)\n"
        "Next\n"
    )
    integrated_executable = work / "rtlib-wide-bool-integrated-check"
    run(fbc + [
        "-w", "all", "-mt", "-d", "ENABLE_MT",
        "-i", str(source_root.parent / "inc"), "-i", str(rtlib_directory),
        str(integrated_driver), str(integrated_object), str(reference_object),
        "-x", str(integrated_executable),
    ], cwd=work)
    run([str(integrated_executable)], cwd=work)
    print(
        "RTLIB wide boolean strings: two procedures translated and integrated; "
        "C2FB candidate and FreeBASIC module match C"
    )


def check_c2fb_math_rnd(converter, fbc, cc, source_root,
                        profile_directory, work):
    rtlib_directory = source_root / "rtlib"
    candidate_directory = work / "rtlib-math-rnd-candidates"
    report_path = work / "rtlib-math-rnd-report.json"
    source_unit_tool = Path(__file__).resolve().parents[1] / "c2fb_source_unit.py"
    summary = run([
        sys.executable, str(source_unit_tool),
        str(rtlib_directory), str(candidate_directory), "--tree",
        "--source-pattern=math/math_rnd.c",
        "--converter", converter, "--compiler", cc[0],
        "--unit-manifest", str(
            profile_directory / "freebasic-rtlib-linux-x86_64-units.json"),
        "--header-option=@" + str(
            profile_directory / "freebasic-linux-glibc-x86_64.rsp"),
        "--body-option=@" + str(
            profile_directory / "freebasic-linux-glibc-x86_64-body.rsp"),
        "--header-option=--emit-source=*fb.h",
        "--header-option=--emit-source=*fb_*.h",
        "--body-option=--rename-proc-prefix=c2fbRtl_",
        "--header-compiler-option=" + f"-I{rtlib_directory}",
        "--body-compiler-option=" + f"-I{rtlib_directory}",
        "--header-compiler-option=-DENABLE_MT",
        "--body-compiler-option=-DENABLE_MT",
        "--report-json", str(report_path),
    ])
    if "processed 1 C files; failed 0" not in summary:
        raise AssertionError(summary)

    report = json.loads(report_path.read_text())
    if report["totals"] != {
        "source_files": 1,
        "generated_candidate_files": 1,
        "failed_source_files": 0,
        "files_with_translated_functions": 1,
        "translated_simple_functions": 26,
        "unsupported_or_duplicate_candidates": 0,
        "body_diagnostic_counts": {},
    }:
        raise AssertionError(report)

    candidate = candidate_directory / "math/math_rnd_candidates.bas"
    generated = candidate.read_text()
    if "c2fb_global_ctx" not in generated or "ProcPtr(" not in generated:
        raise AssertionError("RTLIB random-state callbacks were not preserved")
    if "c2fb_global_ftoi" in generated:
        raise AssertionError("a function-local union escaped into module storage")

    reference_stub = work / "rtlib-math-rnd-reference-support.c"
    reference_stub.write_text(
        '#include "fb.h"\n'
        "FB_RTLIB_CTX __fb_ctx = {0};\n"
        "void fb_MathLock(void) {}\n"
        "void fb_MathUnlock(void) {}\n"
        "double fb_Timer(void) { return 1.0; }\n"
    )
    reference_path = work / "rtlib-math-rnd-reference.so"
    renamed_symbols = (
        "fb_Randomize=fbRef_Randomize",
        "fb_Rnd=fbRef_Rnd",
        "fb_Rnd32=fbRef_Rnd32",
        "fb_RndGetState=fbRef_RndGetState",
    )
    run(cc + [
        "-std=gnu99", "-O2", "-DENABLE_MT", "-DHOST_LINUX=1",
        "-include", "sys/types.h", "-I" + str(rtlib_directory),
        "-shared", "-fPIC", *("-D" + symbol for symbol in renamed_symbols),
        str(rtlib_directory / "math/math_rnd.c"), str(reference_stub),
        "-o", str(reference_path),
    ], cwd=work)
    reference = ctypes.CDLL(str(reference_path))
    for backend, flags in (("native", []), ("gcc", ["-gen", "gcc"])):
        converted_paths = {
            "candidate": work / f"rtlib-math-rnd-candidate-{backend}.so",
            "integrated": work / f"rtlib-math-rnd-integrated-{backend}.so",
        }
        integrated_source = (
            rtlib_directory / "math/linux/math_rnd.bas"
        )
        if not integrated_source.is_file():
            raise AssertionError("Linux C2FB math_rnd module is missing")
        if "translated with c2fb" not in integrated_source.read_text().lower():
            raise AssertionError("math_rnd module lost its C2FB provenance")

        for kind, source in (
            ("candidate", candidate), ("integrated", integrated_source),
        ):
            run(fbc + flags + [
                "-w", "all", "-mt", "-d", "ENABLE_MT", "-dll",
                str(source), "-x", str(converted_paths[kind]),
                "-i", str(source_root.parent / "inc"),
                "-i", str(rtlib_directory),
                "-i", str(source.parent),
            ], cwd=work)

            converted = ctypes.CDLL(str(converted_paths[kind]))
            for library, prefix in ((reference, "fbRef"), (converted, "fb")):
                randomize = getattr(library, prefix + "_Randomize")
                randomize.argtypes = [ctypes.c_double, ctypes.c_int]
                rnd = getattr(library, prefix + "_Rnd")
                rnd.argtypes = [ctypes.c_float]
                rnd.restype = ctypes.c_double
                rnd32 = getattr(library, prefix + "_Rnd32")
                rnd32.argtypes = []
                rnd32.restype = ctypes.c_uint32

            for algorithm in (2, 3, 4):
                for seed in (1.0, 123.0, 65535.0):
                    reference.fbRef_Randomize(seed, algorithm)
                    converted.fb_Randomize(seed, algorithm)
                    for value in (0.0, 1.0, 0.25, -1.0, 2.0):
                        actual = converted.fb_Rnd(value)
                        expected = reference.fbRef_Rnd(value)
                        if actual != expected:
                            raise AssertionError(
                                f"{kind}/{backend} RND mismatch for "
                                f"algorithm={algorithm}, seed={seed}, input={value}: "
                                f"{actual} != {expected}"
                            )

                    reference.fbRef_Randomize(seed, algorithm)
                    converted.fb_Randomize(seed, algorithm)
                    for _ in range(6):
                        actual = converted.fb_Rnd32()
                        expected = reference.fbRef_Rnd32()
                        if actual != expected:
                            raise AssertionError(
                                f"{kind}/{backend} RND32 mismatch for "
                                f"algorithm={algorithm}, seed={seed}: "
                                f"{actual} != {expected}"
                            )

    lock_source = rtlib_directory / "math/linux/math_rnd.bas"
    for variant, flags in (
        ("single", []), ("mt", ["-mt", "-d", "ENABLE_MT"]),
    ):
        lock_object = work / f"rtlib-math-rnd-locks-{variant}.o"
        run(fbc + flags + [
            "-w", "all", "-c", str(lock_source), "-o", str(lock_object),
            "-i", str(source_root.parent / "inc"), "-i", str(rtlib_directory),
            "-i", str(lock_source.parent),
        ], cwd=work)
        undefined = run(["nm", "-u", str(lock_object)])
        has_locks = "fb_MathLock" in undefined and "fb_MathUnlock" in undefined
        if variant == "single" and has_locks:
            raise AssertionError("single-thread C2FB math_rnd imports MT-only locks")
        if variant == "mt" and not has_locks:
            raise AssertionError("MT C2FB math_rnd omitted the runtime locks")
    print(
        "RTLIB math_rnd: 26 procedures translated with no skips; "
        "single-thread and MT lock imports match the runtime; "
        "candidate and integrated module match C for FAST, MTWIST, and QB"
    )


def check_c2fb_wide_numeric_candidates(converter, fbc, cc, source_root,
                                       profile_directory, work):
    rtlib_directory = source_root / "rtlib"
    candidate_directory = work / "rtlib-wide-numeric-candidates"
    report_path = work / "rtlib-wide-numeric-report.json"
    source_patterns = (
        "strings/wide/strw_convto.c",
        "strings/wide/strw_convto_flt.c",
        "strings/wide/strw_convto_lng.c",
        "strings/wide/strw_ftoa.c",
    )
    source_unit_tool = Path(__file__).resolve().parents[1] / "c2fb_source_unit.py"
    summary = run([
        sys.executable, str(source_unit_tool),
        str(rtlib_directory), str(candidate_directory), "--tree", "--jobs=4",
        *(f"--source-pattern={source}" for source in source_patterns),
        "--converter", converter, "--compiler", cc[0],
        "--unit-manifest", str(
            profile_directory / "freebasic-rtlib-linux-x86_64-units.json"),
        "--header-option=@" + str(
            profile_directory / "freebasic-linux-glibc-x86_64.rsp"),
        "--body-option=@" + str(
            profile_directory / "freebasic-linux-glibc-x86_64-body.rsp"),
        "--header-option=--emit-source=*fb.h",
        "--header-option=--emit-source=*fb_*.h",
        "--body-option=--rename-proc-prefix=c2fbRtl_",
        "--header-compiler-option=" + f"-I{rtlib_directory}",
        "--body-compiler-option=" + f"-I{rtlib_directory}",
        "--header-compiler-option=-DENABLE_MT",
        "--body-compiler-option=-DENABLE_MT",
        "--report-json", str(report_path),
    ])
    if f"processed {len(source_patterns)} C files; failed 0" not in summary:
        raise AssertionError(summary)

    report = json.loads(report_path.read_text())
    if report["totals"] != {
        "source_files": 4,
        "generated_candidate_files": 4,
        "failed_source_files": 0,
        "files_with_translated_functions": 4,
        "translated_simple_functions": 12,
        "unsupported_or_duplicate_candidates": 0,
        "body_diagnostic_counts": {},
    }:
        raise AssertionError(report)

    candidates = sorted(candidate_directory.glob("strings/wide/*_candidates.bas"))
    if len(candidates) != 4:
        raise AssertionError(f"expected four wide numeric candidates, found {candidates}")
    candidate_objects = []
    for candidate in candidates:
        object_path = candidate.with_suffix(".o")
        run(fbc + [
            "-w", "all", "-mt", "-d", "ENABLE_MT", "-c",
            "-o", str(object_path),
            "-i", str(source_root.parent / "inc"),
            "-i", str(rtlib_directory), "-i", str(candidate.parent),
            str(candidate),
        ], cwd=work)
        candidate_objects.append(object_path)

    integrated_sources = [
        rtlib_directory / "strings/wide/linux" / f"{stem}.bas"
        for stem in (
            "strw_convto", "strw_convto_flt", "strw_convto_lng", "strw_ftoa",
        )
    ]
    if any(not source.is_file() for source in integrated_sources):
        raise AssertionError("Linux wide numeric FreeBASIC modules are missing")
    integrated_objects = []
    for source in integrated_sources:
        object_path = work / f"integrated-{source.stem}.o"
        run(fbc + [
            "-w", "all", "-mt", "-d", "ENABLE_MT", "-c",
            "-o", str(object_path),
            "-i", str(source_root.parent / "inc"),
            "-i", str(rtlib_directory), "-i", str(source.parent),
            str(source),
        ], cwd=work)
        integrated_objects.append(object_path)

    renamed_symbols = {
        "strw_convto.c": (
            "fb_IntToWstr=fbRef_IntToWstr",
            "fb_UIntToWstr=fbRef_UIntToWstr",
        ),
        "strw_convto_flt.c": (
            "fb_FloatToWstr=fbRef_FloatToWstr",
            "fb_DoubleToWstr=fbRef_DoubleToWstr",
        ),
        "strw_convto_lng.c": (
            "fb_LongintToWstr=fbRef_LongintToWstr",
            "fb_ULongintToWstr=fbRef_ULongintToWstr",
        ),
        "strw_ftoa.c": ("fb_FloatExToWstr=fbRef_FloatExToWstr",),
    }
    reference_objects = []
    for source_name, defines in renamed_symbols.items():
        reference_object = work / f"{source_name}.reference.o"
        run(cc + [
            "-std=c99", "-O2", "-DENABLE_MT", "-include", "sys/types.h",
            "-I" + str(rtlib_directory),
            *("-D" + define for define in defines),
            "-c", str(rtlib_directory / "strings/wide" / source_name),
            "-o", str(reference_object),
        ], cwd=work)
        reference_objects.append(reference_object)

    driver = work / "rtlib-wide-numeric-check.bas"
    driver.write_text(
        '#include once "crt/stdlib.bi"\n'
        'Declare Function fb_IntToWstrCandidate CDecl Alias "fb_IntToWstr" '
        "(ByVal value As Long) As Long Ptr\n"
        'Declare Function fb_UIntToWstrCandidate CDecl Alias "fb_UIntToWstr" '
        "(ByVal value As ULong) As Long Ptr\n"
        'Declare Function fb_FloatToWstrCandidate CDecl Alias "fb_FloatToWstr" '
        "(ByVal value As Single) As Long Ptr\n"
        'Declare Function fb_DoubleToWstrCandidate CDecl Alias "fb_DoubleToWstr" '
        "(ByVal value As Double) As Long Ptr\n"
        'Declare Function fb_LongintToWstrCandidate CDecl Alias "fb_LongintToWstr" '
        "(ByVal value As LongInt) As Long Ptr\n"
        'Declare Function fb_ULongintToWstrCandidate CDecl Alias "fb_ULongintToWstr" '
        "(ByVal value As ULongInt) As Long Ptr\n"
        'Declare Function fb_FloatExToWstrCandidate CDecl Alias "fb_FloatExToWstr" '
        "(ByVal value As Double, ByVal buffer As Long Ptr, "
        "ByVal digits As Long, ByVal mask As Long) As Long Ptr\n"
        'Declare Function fbRef_IntToWstr CDecl Alias "fbRef_IntToWstr" '
        "(ByVal value As Long) As Long Ptr\n"
        'Declare Function fbRef_UIntToWstr CDecl Alias "fbRef_UIntToWstr" '
        "(ByVal value As ULong) As Long Ptr\n"
        'Declare Function fbRef_FloatToWstr CDecl Alias "fbRef_FloatToWstr" '
        "(ByVal value As Single) As Long Ptr\n"
        'Declare Function fbRef_DoubleToWstr CDecl Alias "fbRef_DoubleToWstr" '
        "(ByVal value As Double) As Long Ptr\n"
        'Declare Function fbRef_LongintToWstr CDecl Alias "fbRef_LongintToWstr" '
        "(ByVal value As LongInt) As Long Ptr\n"
        'Declare Function fbRef_ULongintToWstr CDecl Alias "fbRef_ULongintToWstr" '
        "(ByVal value As ULongInt) As Long Ptr\n"
        'Declare Function fbRef_FloatExToWstr CDecl Alias "fbRef_FloatExToWstr" '
        "(ByVal value As Double, ByVal buffer As Long Ptr, "
        "ByVal digits As Long, ByVal mask As Long) As Long Ptr\n"
        'Declare Sub FreeWide CDecl Alias "free" (ByVal value As Any Ptr)\n'
        "Function SameWide(ByVal actual As Long Ptr, "
        "ByVal expected As Long Ptr) As Long\n"
        "    If actual = 0 OrElse expected = 0 Then Return 0\n"
        "    For index As Long = 0 To 31\n"
        "        If actual[index] <> expected[index] Then Return 0\n"
        "        If actual[index] = 0 Then Return -1\n"
        "    Next\n"
        "    Return 0\n"
        "End Function\n"
        "Sub CheckWide(ByVal actual As Long Ptr, "
        "ByVal expected As Long Ptr)\n"
        "    If SameWide(actual, expected) = 0 Then End 1\n"
        "    FreeWide(actual)\n"
        "    FreeWide(expected)\n"
        "End Sub\n"
        "Dim signedValues(0 To 4) As Long = "
        "{-2147483647, -1234567, 0, 1234567, 2147483647}\n"
        "For index As Long = 0 To UBound(signedValues)\n"
        "    CheckWide(fb_IntToWstrCandidate(signedValues(index)), "
        "fbRef_IntToWstr(signedValues(index)))\n"
        "Next\n"
        "Dim unsignedValues(0 To 3) As ULong\n"
        "unsignedValues(0) = 0\n"
        "unsignedValues(1) = 1\n"
        "unsignedValues(2) = 123456789\n"
        "unsignedValues(3) = &HFFFFFFFF\n"
        "For index As Long = 0 To UBound(unsignedValues)\n"
        "    CheckWide(fb_UIntToWstrCandidate(unsignedValues(index)), "
        "fbRef_UIntToWstr(unsignedValues(index)))\n"
        "Next\n"
        "Dim longValues(0 To 4) As LongInt\n"
        "longValues(0) = (-9223372036854775807ll - 1ll)\n"
        "longValues(1) = -1234567890123ll\n"
        "longValues(2) = 0\n"
        "longValues(3) = 1234567890123ll\n"
        "longValues(4) = 9223372036854775807ll\n"
        "For index As Long = 0 To UBound(longValues)\n"
        "    CheckWide(fb_LongintToWstrCandidate(longValues(index)), "
        "fbRef_LongintToWstr(longValues(index)))\n"
        "Next\n"
        "Dim ulongValues(0 To 3) As ULongInt\n"
        "ulongValues(0) = 0\n"
        "ulongValues(1) = 4294967295ull\n"
        "ulongValues(2) = 9223372036854775808ull\n"
        "ulongValues(3) = 18446744073709551615ull\n"
        "For index As Long = 0 To UBound(ulongValues)\n"
        "    CheckWide(fb_ULongintToWstrCandidate(ulongValues(index)), "
        "fbRef_ULongintToWstr(ulongValues(index)))\n"
        "Next\n"
        "Dim singleValues(0 To 5) As Single\n"
        "singleValues(0) = 0\n"
        "singleValues(1) = -0.0\n"
        "singleValues(2) = 1.25\n"
        "singleValues(3) = -3.5\n"
        "singleValues(4) = 1.0e-25\n"
        "singleValues(5) = 3.1415927\n"
        "For index As Long = 0 To UBound(singleValues)\n"
        "    CheckWide(fb_FloatToWstrCandidate(singleValues(index)), "
        "fbRef_FloatToWstr(singleValues(index)))\n"
        "Next\n"
        "Dim doubleValues(0 To 5) As Double\n"
        "doubleValues(0) = 0\n"
        "doubleValues(1) = -0.0\n"
        "doubleValues(2) = 1.0 / 3.0\n"
        "doubleValues(3) = -1.0e200\n"
        "doubleValues(4) = 1.0e-200\n"
        "doubleValues(5) = 3.141592653589793\n"
        "For index As Long = 0 To UBound(doubleValues)\n"
        "    CheckWide(fb_DoubleToWstrCandidate(doubleValues(index)), "
        "fbRef_DoubleToWstr(doubleValues(index)))\n"
        "Next\n"
        "Dim digitsValues(0 To 2) As Long = {1, 7, 16}\n"
        "For valueIndex As Long = 0 To UBound(doubleValues)\n"
        "    For digitsIndex As Long = 0 To UBound(digitsValues)\n"
        "        For mask As Long = 0 To 1\n"
        "            Dim actualBuffer(0 To 31) As Long\n"
        "            Dim expectedBuffer(0 To 31) As Long\n"
        "            For index As Long = 0 To 31\n"
        "                actualBuffer(index) = &H5A5A5A5A\n"
        "                expectedBuffer(index) = &H5A5A5A5A\n"
        "            Next\n"
        "            Dim actual As Long Ptr = fb_FloatExToWstrCandidate( "
        "doubleValues(valueIndex), @actualBuffer(0), "
        "digitsValues(digitsIndex), mask)\n"
        "            Dim expected As Long Ptr = fbRef_FloatExToWstr( "
        "doubleValues(valueIndex), @expectedBuffer(0), "
        "digitsValues(digitsIndex), mask)\n"
        "            If CULngInt(actual) - CULngInt(@actualBuffer(0)) <> "
        "CULngInt(expected) - CULngInt(@expectedBuffer(0)) Then End 2\n"
        "            For index As Long = 0 To 31\n"
        "                If actualBuffer(index) <> expectedBuffer(index) Then End 3\n"
        "            Next\n"
        "        Next\n"
        "    Next\n"
        "Next\n"
    )
    for label, implementation_objects in (
        ("candidate", candidate_objects),
        ("integrated", integrated_objects),
    ):
        executable = work / f"rtlib-wide-numeric-{label}-check"
        run(fbc + [
            "-w", "all", "-mt", "-d", "ENABLE_MT",
            "-i", str(source_root.parent / "inc"),
            "-i", str(rtlib_directory), str(driver),
            *(str(path) for path in implementation_objects),
            *(str(path) for path in reference_objects),
            "-x", str(executable),
        ], cwd=work)
        run([str(executable)], cwd=work)
    print(
        "RTLIB wide numeric strings: 12 procedures translated; candidate and "
        "integrated Linux modules match C for integer and floating edge cases"
    )


def check_basic_wrappers(fbc, cc, source_root, work):
    rtlib_directory = source_root / "rtlib"
    module_directory = work / "rtlib-basic-objects"
    module_directory.mkdir()
    module_objects = []
    for stem in ("legacy_str_lcase", "legacy_str_ucase"):
        source = rtlib_directory / "legacy" / f"{stem}.bas"
        object_path = module_directory / f"{stem}.o"
        run(fbc + [
            "-w", "all", "-c", str(source), "-o", str(object_path),
            "-i", str(source_root.parent / "inc"),
        ], cwd=module_directory)
        if not object_path.is_file() or object_path.stat().st_size == 0:
            raise AssertionError(f"FreeBASIC produced no object for {source}")
        module_objects.append(object_path)

    c_source = work / "rtlib_string_case_abi.c"
    c_source.write_text(
        "#include <stdlib.h>\n"
        "static int lower_calls;\n"
        "static int upper_calls;\n"
        "void *fb_StrLcase2(void *source, int fill_remainder) {\n"
        "    ++lower_calls;\n"
        "    if (fill_remainder != 0) abort();\n"
        "    return source;\n"
        "}\n"
        "void *fb_StrUcase2(void *source, int fill_remainder) {\n"
        "    ++upper_calls;\n"
        "    if (fill_remainder != 0) abort();\n"
        "    return source;\n"
        "}\n"
        "void *fb_LCASE(void *source);\n"
        "void *fb_UCASE(void *source);\n"
        "int main(void) {\n"
        "    int lower_string;\n"
        "    int upper_string;\n"
        "    if (fb_LCASE(&lower_string) != &lower_string) return 1;\n"
        "    if (fb_UCASE(&upper_string) != &upper_string) return 2;\n"
        "    if (lower_calls != 1 || upper_calls != 1) return 3;\n"
        "    return 0;\n"
        "}\n"
    )
    executable = work / "rtlib_string_case_abi"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        str(c_source), *(str(path) for path in module_objects),
        "-o", str(executable),
    ], cwd=work)
    run([str(executable)], cwd=work)
    print("passed 2 FreeBASIC RTLIB C ABI wrappers")


def check_c2fb_numeric_strings(fbc, cc, source_root, candidate_objects, work):
    rtlib_directory = source_root / "rtlib"
    include_directory = source_root.parent / "inc"
    module_directory = work / "rtlib-numeric-string-check"
    module_directory.mkdir()

    prototypes = {
        "fb_BIN_b": ["UByte"],
        "fb_BIN_s": ["UShort"],
        "fb_BIN_i": ["UInteger"],
        "fb_BIN_l": ["ULongInt"],
        "fb_BIN_p": ["Any Ptr"],
        "fb_BINEx_b": ["UByte", "Long"],
        "fb_BINEx_s": ["UShort", "Long"],
        "fb_BINEx_i": ["UInteger", "Long"],
        "fb_BINEx_l": ["ULongInt", "Long"],
        "fb_BINEx_p": ["Any Ptr", "Long"],
        "fb_HEX_b": ["UByte"],
        "fb_HEX_s": ["UShort"],
        "fb_HEX_i": ["UInteger"],
        "fb_HEX_l": ["ULongInt"],
        "fb_HEX_p": ["Any Ptr"],
        "fb_HEXEx_b": ["UByte", "Long"],
        "fb_HEXEx_s": ["UShort", "Long"],
        "fb_HEXEx_i": ["UInteger", "Long"],
        "fb_HEXEx_l": ["ULongInt", "Long"],
        "fb_HEXEx_p": ["Any Ptr", "Long"],
        "fb_OCT_b": ["UByte"],
        "fb_OCT_s": ["UShort"],
        "fb_OCT_i": ["UInteger"],
        "fb_OCT_l": ["ULongInt"],
        "fb_OCT_p": ["Any Ptr"],
        "fb_OCTEx_b": ["UByte", "Long"],
        "fb_OCTEx_s": ["UShort", "Long"],
        "fb_OCTEx_i": ["UInteger", "Long"],
        "fb_OCTEx_l": ["ULongInt", "Long"],
        "fb_OCTEx_p": ["Any Ptr", "Long"],
    }
    cases = (
        ("BIN_b", ["Cast(UByte, 0)"], "0"),
        ("BIN_s", ["Cast(UShort, 5)"], "101"),
        ("BIN_i", ["Cast(UInteger, &hA5)"], "10100101"),
        ("BINEx_b", ["Cast(UByte, 5)", "8"], "00000101"),
        ("BINEx_s", ["Cast(UShort, &h1234)", "16"], "0001001000110100"),
        ("BINEx_i", ["Cast(UInteger, &hF0)", "8"], "11110000"),
        ("BIN_l", ["CULngInt(5)"], "101"),
        ("BINEx_l", ["CULngInt(5)", "4"], "0101"),
        ("BINEx_l", ["CULngInt(&h100000000)", "0"], "1" + "0" * 32),
        ("BIN_p", ["CPtr(Any Ptr, &h123)"], "100100011"),
        ("BINEx_p", ["CPtr(Any Ptr, &h123)", "16"], "0000000100100011"),
        ("HEX_b", ["Cast(UByte, &hAB)"], "AB"),
        ("HEX_s", ["Cast(UShort, &h1234)"], "1234"),
        ("HEX_i", ["Cast(UInteger, &hDEADBEEF)"], "DEADBEEF"),
        ("HEXEx_b", ["Cast(UByte, &hAB)", "1"], "B"),
        ("HEXEx_s", ["Cast(UShort, &h12)", "4"], "0012"),
        ("HEXEx_i", ["Cast(UInteger, &hDEADBEEF)", "10"], "00DEADBEEF"),
        ("HEX_l", ["CULngInt(&h100000000)"], "100000000"),
        ("HEXEx_l", ["CULngInt(&hABC)", "8"], "00000ABC"),
        ("HEX_p", ["CPtr(Any Ptr, &h123)"], "123"),
        ("HEXEx_p", ["CPtr(Any Ptr, &h123)", "16"], "0000000000000123"),
        ("OCT_b", ["Cast(UByte, 0)"], "0"),
        ("OCT_s", ["Cast(UShort, 64)"], "100"),
        ("OCT_i", ["Cast(UInteger, &h1234)"], "11064"),
        ("OCTEx_b", ["Cast(UByte, 5)", "4"], "0005"),
        ("OCTEx_s", ["Cast(UShort, 8)", "6"], "000010"),
        ("OCTEx_i", ["Cast(UInteger, &h1FF)", "8"], "00000777"),
        ("OCT_l", ["CULngInt(&h100000000)"], "40000000000"),
        ("OCTEx_l", ["CULngInt(5)", "5"], "00005"),
        ("OCT_p", ["CPtr(Any Ptr, &h123)"], "443"),
        ("OCTEx_p", ["CPtr(Any Ptr, &h123)", "12"], "000000000443"),
    )

    symbols = tuple(prototypes)
    reference_objects = []
    for stem in (
        "str_bin", "str_bin_lng", "str_bin_ptr",
        "str_hex", "str_hex_lng", "str_hex_ptr",
        "str_oct", "str_oct_lng", "str_oct_ptr",
    ):
        source = rtlib_directory / "strings" / f"{stem}.c"
        object_path = module_directory / f"{stem}-reference.o"
        run(cc + [
            "-std=c99", "-DENABLE_MT", "-include", "sys/types.h",
            "-I" + str(rtlib_directory),
            *(f"-D{name}={name}C" for name in symbols),
            "-c", str(source), "-o", str(object_path),
        ], cwd=module_directory)
        reference_objects.append(object_path)

    port_objects = []
    for stem in (
        "str_bin", "str_bin_lng", "str_bin_ptr",
        "str_hex", "str_hex_lng", "str_hex_ptr",
        "str_oct", "str_oct_lng", "str_oct_ptr",
    ):
        source = rtlib_directory / "strings/linux/x86_64" / f"{stem}.bas"
        object_path = module_directory / f"{stem}-port.o"
        run(fbc + [
            "-w", "all", "-mt", "-d", "ENABLE_MT", "-c", str(source),
            "-o", str(object_path), "-i", str(include_directory),
            "-i", str(rtlib_directory),
        ], cwd=module_directory)
        port_objects.append(object_path)

    declarations = [
        '#include once "strings/fb_string.bi"',
        '#include once "strings/fb_string_runtime.bi"',
    ]
    for symbol, arguments in prototypes.items():
        argument_list = ", ".join(
            f"ByVal arg{index} As {argument}"
            for index, argument in enumerate(arguments)
        )
        declarations.append(
            f'Declare Function Ref_{symbol} CDecl Alias "{symbol}C" '
            f"({argument_list}) As FBSTRING Ptr"
        )
        declarations.append(
            f'Declare Function Port_{symbol} CDecl Alias "{symbol}" '
            f"({argument_list}) As FBSTRING Ptr"
        )
    declarations.extend([
        "Dim Shared savedBytes(0 To 127) As UByte",
        "Dim Shared savedLength As Long",
        "Sub SaveResult(ByVal result As FBSTRING Ptr)",
        "    If result = 0 Then End 200",
        "    savedLength = fbStringGetLength(result)",
        "    If savedLength < 0 OrElse savedLength > 128 Then End 201",
        "    For index As Long = 0 To savedLength - 1",
        "        savedBytes(index) = CUInt(Asc(result->data[index])) And &hFF",
        "    Next",
        "End Sub",
        "Function Matches(ByVal result As FBSTRING Ptr, ByRef expected As String) As Long",
        "    If result = 0 Then Return 0",
        "    If fbStringGetLength(result) <> savedLength OrElse savedLength <> Len(expected) Then Return 0",
        "    For index As Long = 0 To savedLength - 1",
        "        If (CUInt(Asc(result->data[index])) And &hFF) <> savedBytes(index) Then Return 0",
        "        If savedBytes(index) <> Asc(expected, index + 1) Then Return 0",
        "    Next",
        "    Return -1",
        "End Function",
    ])
    calls = ["SaveResult(Ref_fb_" + name + "(" + ", ".join(arguments) + "))\n"
             f"If Matches(Port_fb_{name}({', '.join(arguments)}), \"{expected}\") = 0 Then End {index + 1}"
             for index, (name, arguments, expected) in enumerate(cases)]
    probe = module_directory / "numeric-string-parity.bas"
    probe.write_text("\n".join(declarations + calls + ["End 0", ""]))

    for implementation, objects in (
        ("C2FB candidate", [candidate_objects[stem] for stem in (
            "str_bin", "str_bin_lng", "str_bin_ptr",
            "str_hex", "str_hex_lng", "str_hex_ptr",
            "str_oct", "str_oct_lng", "str_oct_ptr",
        )]),
        ("FreeBASIC port", port_objects),
    ):
        executable = module_directory / (
            f"numeric-string-{implementation.lower().replace(' ', '-')}-check"
        )
        run(fbc + [
            "-w", "all", "-mt", "-d", "ENABLE_MT",
            "-i", str(include_directory), "-i", str(rtlib_directory),
            str(probe), *(str(path) for path in reference_objects),
            *(str(path) for path in objects), "-x", str(executable),
        ], cwd=module_directory)
        run([str(executable)], cwd=module_directory)
    print(
        "RTLIB BIN/HEX/OCT: 31 numeric formatting cases matched C references, "
        "C2FB candidates, and integrated FreeBASIC ports"
    )


def check_basic_string_routines(fbc, cc, source_root, candidate_objects, work):
    rtlib_directory = source_root / "rtlib"
    include_directory = source_root.parent / "inc"
    module_directory = work / "rtlib-string-objects"
    module_directory.mkdir()

    string_stems = (
        "str_asc", "str_chr", "str_reverse", "str_len", "str_fill", "str_left",
        "str_right", "str_hskip",
        "str_ltrim", "str_ltrimex", "str_rtrim", "str_rtrimex",
        "str_trim", "str_trimex",
    )
    for stem in string_stems:
        source = rtlib_directory / "strings/linux/x86_64" / f"{stem}.bas"
        for variant, flags in (
            ("single", []),
            ("mt", ["-mt", "-d", "ENABLE_MT"]),
        ):
            object_path = module_directory / f"{stem}-{variant}.o"
            run(fbc + [
                "-w", "all", *flags, "-c", str(source), "-o", str(object_path),
                "-i", str(include_directory), "-i", str(rtlib_directory),
            ], cwd=module_directory)
            if not object_path.is_file() or object_path.stat().st_size == 0:
                raise AssertionError(f"FreeBASIC produced no object for {source}")

    for stem in ("str_left", "str_right", "str_reverse"):
        single_thread_symbols = run([
            "nm", "-u", str(module_directory / f"{stem}-single.o"),
        ])
        multi_thread_symbols = run([
            "nm", "-u", str(module_directory / f"{stem}-mt.o"),
        ])
        if (
            "fb_StrLock" in single_thread_symbols
            or "fb_StrUnlock" in single_thread_symbols
        ):
            raise AssertionError(f"single-thread {stem} object unexpectedly imports locks")
        if (
            "fb_StrLock" not in multi_thread_symbols
            or "fb_StrUnlock" not in multi_thread_symbols
        ):
            raise AssertionError(f"multithreaded {stem} object omitted string locks")

    reference_objects = {}
    for stem in string_stems:
        source = rtlib_directory / "strings" / f"{stem}.c"
        object_path = module_directory / f"{stem}-reference.o"
        run(cc + [
            "-std=c99", "-DENABLE_MT", "-include", "sys/types.h",
            "-I" + str(rtlib_directory), "-c", str(source),
            "-o", str(object_path),
        ], cwd=module_directory)
        reference_objects[stem] = object_path

    trim_caller_stems = (
        "str_ltrim", "str_ltrimex", "str_rtrim", "str_rtrimex",
        "str_trim", "str_trimex",
    )
    trim_caller_objects = []
    for stem in trim_caller_stems:
        source = rtlib_directory / "strings" / f"{stem}.c"
        object_path = module_directory / f"{stem}-caller.o"
        run(cc + [
            "-std=c99", "-DENABLE_MT", "-include", "sys/types.h",
            "-I" + str(rtlib_directory), "-c", str(source),
            "-o", str(object_path),
        ], cwd=module_directory)
        trim_caller_objects.append(object_path)

    context_layout = module_directory / "context-layout.c"
    context_layout.write_text(
        "#include <stddef.h>\n"
        "#include <sys/types.h>\n"
        '#include "fb.h"\n'
        "size_t c2fbRtlibNullDescriptorOffset(void) {\n"
        "    return offsetof(FB_RTLIB_CTX, null_desc);\n"
        "}\n"
    )
    context_layout_object = module_directory / "context-layout.o"
    run(cc + [
        "-std=c99", "-I" + str(rtlib_directory), "-c",
        str(context_layout), "-o", str(context_layout_object),
    ], cwd=module_directory)
    layout_check = module_directory / "context-layout-check.bas"
    layout_check.write_text(
        '#include once "crt/stddef.bi"\n'
        "Type TestFBSTRING\n"
        "    data As ZString Ptr\n"
        "    len As ssize_t\n"
        "    size As ssize_t\n"
        "End Type\n"
        "Type TestFB_RTLIB_CTX_PREFIX\n"
        "    argc As Long\n"
        "    argv As ZString Ptr Ptr\n"
        "    null_desc As TestFBSTRING\n"
        "End Type\n"
        "Declare Function c2fbRtlibNullDescriptorOffset CDecl "
        'Alias "c2fbRtlibNullDescriptorOffset" () As size_t\n'
        "If OffsetOf(TestFB_RTLIB_CTX_PREFIX, null_desc) <> "
        "c2fbRtlibNullDescriptorOffset() Then End 1\n"
    )
    layout_executable = module_directory / "context-layout-check"
    run(fbc + [
        "-w", "all", "-i", str(include_directory), str(layout_check),
        str(context_layout_object), "-x", str(layout_executable),
    ], cwd=module_directory)
    run([str(layout_executable)], cwd=module_directory)

    string_length_probe = module_directory / "string-length-check.bas"
    string_length_probe.write_text(
        '#include once "crt/stddef.bi"\n'
        "Type TestFBSTRING\n"
        "    data As ZString Ptr\n"
        "    len As ssize_t\n"
        "    size As ssize_t\n"
        "End Type\n"
        "Declare Function ProbeAllocTemp CDecl Alias \"fb_hStrAllocTemp\" ("
        "ByVal descriptor As TestFBSTRING Ptr, ByVal size As ssize_t) As TestFBSTRING Ptr\n"
        "Declare Function ProbeStrLen CDecl Alias \"fb_StrLen\" ("
        "ByVal source As Any Ptr, ByVal sourceSize As ssize_t) As ssize_t\n"
        "Dim text As ZString * 7 = \"sqlite\"\n"
        "If ProbeStrLen(0, -1) <> 0 Then End 1\n"
        "If ProbeStrLen(@text, 0) <> 6 Then End 2\n"
        "If ProbeStrLen(@text, 6) <> 6 Then End 3\n"
        "Dim descriptorText As ZString * 5 = \"fbc\"\n"
        "Dim descriptor As TestFBSTRING\n"
        "descriptor.data = @descriptorText\n"
        "descriptor.len = 3\n"
        "descriptor.size = 4\n"
        "If ProbeStrLen(@descriptor, -1) <> 3 Then End 4\n"
        "Dim As TestFBSTRING Ptr temporaryDescriptor = ProbeAllocTemp(0, 3)\n"
        "If temporaryDescriptor = 0 Then End 5\n"
        "Cast(UByte Ptr, temporaryDescriptor->data)[0] = Asc(\"t\")\n"
        "Cast(UByte Ptr, temporaryDescriptor->data)[1] = Asc(\"m\")\n"
        "Cast(UByte Ptr, temporaryDescriptor->data)[2] = Asc(\"p\")\n"
        "Cast(UByte Ptr, temporaryDescriptor->data)[3] = 0\n"
        "If ProbeStrLen(temporaryDescriptor, -1) <> 3 Then End 6\n"
        "End 0\n"
    )

    string_fill_probe = module_directory / "string-fill-check.bas"
    string_fill_probe.write_text(
        '#include once "crt/stddef.bi"\n'
        "Type TestFBSTRING\n"
        "    data As ZString Ptr\n"
        "    len As ssize_t\n"
        "    size As ssize_t\n"
        "End Type\n"
        "Declare Function ProbeAllocTemp CDecl Alias \"fb_hStrAllocTemp\" ("
        "ByVal descriptor As TestFBSTRING Ptr, ByVal size As ssize_t) As TestFBSTRING Ptr\n"
        "Declare Function ProbeStrFill1 CDecl Alias \"fb_StrFill1\" ("
        "ByVal count As ssize_t, ByVal fillCharacter As Long) As TestFBSTRING Ptr\n"
        "Declare Function ProbeStrFill2 CDecl Alias \"fb_StrFill2\" ("
        "ByVal count As ssize_t, ByVal source As TestFBSTRING Ptr) As TestFBSTRING Ptr\n"
        "Const tempBit As ULongInt = &H8000000000000000ULL\n"
        "Dim As TestFBSTRING Ptr emptyResult = ProbeStrFill1(0, 65)\n"
        "If emptyResult = 0 Then End 1\n"
        "If ProbeStrFill1(-1, 65) <> emptyResult Then End 2\n"
        "Dim As TestFBSTRING Ptr result = ProbeStrFill1(5, &H141)\n"
        "If result = 0 Then End 3\n"
        "If (Cast(ULongInt, result->len) And Not tempBit) <> 5 Then End 4\n"
        "For index As Long = 0 To 4\n"
        "    If Cast(UByte, Cast(UByte Ptr, result->data)[index]) <> 65 Then End 5\n"
        "Next\n"
        "If Cast(UByte, Cast(UByte Ptr, result->data)[5]) <> 0 Then End 6\n"
        "Dim sourceText As ZString * 2 = \"Q\"\n"
        "Dim source As TestFBSTRING\n"
        "source.data = @sourceText\n"
        "source.len = 1\n"
        "source.size = 2\n"
        "result = ProbeStrFill2(3, @source)\n"
        "If result = 0 Then End 7\n"
        "If (Cast(ULongInt, result->len) And Not tempBit) <> 3 Then End 8\n"
        "For index As Long = 0 To 2\n"
        "    If Cast(UByte, Cast(UByte Ptr, result->data)[index]) <> Asc(\"Q\") Then End 9\n"
        "Next\n"
        "Dim highBytes(0 To 1) As UByte\n"
        "highBytes(0) = &HFF\n"
        "Dim highSource As TestFBSTRING\n"
        "highSource.data = Cast(ZString Ptr, @highBytes(0))\n"
        "highSource.len = 1\n"
        "highSource.size = 2\n"
        "result = ProbeStrFill2(2, @highSource)\n"
        "If result = 0 Then End 10\n"
        "For index As Long = 0 To 1\n"
        "    If Cast(UByte, Cast(UByte Ptr, result->data)[index]) <> &HFF Then End 11\n"
        "Next\n"
        "Dim As TestFBSTRING Ptr temporarySource = ProbeAllocTemp(0, 1)\n"
        "If temporarySource = 0 Then End 12\n"
        "Cast(UByte Ptr, temporarySource->data)[0] = Asc(\"T\")\n"
        "Cast(UByte Ptr, temporarySource->data)[1] = 0\n"
        "result = ProbeStrFill2(2, temporarySource)\n"
        "If result = 0 Then End 13\n"
        "If (Cast(ULongInt, result->len) And Not tempBit) <> 2 Then End 14\n"
        "For index As Long = 0 To 1\n"
        "    If Cast(UByte, Cast(UByte Ptr, result->data)[index]) <> Asc(\"T\") Then End 15\n"
        "Next\n"
        "If ProbeStrFill2(2, 0) <> emptyResult Then End 16\n"
        "End 0\n"
    )

    string_slice_probe = module_directory / "string-slice-check.bas"
    string_slice_probe.write_text(
        '#include once "crt/stddef.bi"\n'
        "Type TestFBSTRING\n"
        "    data As ZString Ptr\n"
        "    len As ssize_t\n"
        "    size As ssize_t\n"
        "End Type\n"
        "Type TestFB_RTLIB_CTX_PREFIX\n"
        "    argc As Long\n"
        "    argv As ZString Ptr Ptr\n"
        "    null_desc As TestFBSTRING\n"
        "End Type\n"
        "Extern fbContext Alias \"__fb_ctx\" As TestFB_RTLIB_CTX_PREFIX\n"
        "Declare Function ProbeAllocTemp CDecl Alias \"fb_hStrAllocTemp\" ("
        "ByVal descriptor As TestFBSTRING Ptr, ByVal size As ssize_t) As TestFBSTRING Ptr\n"
        "Declare Function ProbeDeleteTemp CDecl Alias \"fb_hStrDelTemp\" ("
        "ByVal descriptor As TestFBSTRING Ptr) As Long\n"
        "Declare Function ProbeStrLeft CDecl Alias \"fb_LEFT\" ("
        "ByVal source As TestFBSTRING Ptr, ByVal characters As ssize_t) As TestFBSTRING Ptr\n"
        "Declare Function ProbeStrRight CDecl Alias \"fb_RIGHT\" ("
        "ByVal source As TestFBSTRING Ptr, ByVal characters As ssize_t) As TestFBSTRING Ptr\n"
        "Const tempBit As ULongInt = &H8000000000000000ULL\n"
        "Private Function DescriptorLength(ByVal descriptor As TestFBSTRING Ptr) As ssize_t\n"
        "    Return Cast(ssize_t, Cast(size_t, descriptor->len) And Not tempBit)\n"
        "End Function\n"
        "Private Function NewAlphabetSource() As TestFBSTRING Ptr\n"
        "    Dim As TestFBSTRING Ptr source = ProbeAllocTemp(0, 6)\n"
        "    If source = 0 Then Return 0\n"
        "    For index As Long = 0 To 5\n"
        "        Cast(UByte Ptr, source->data)[index] = Asc(\"a\") + index\n"
        "    Next\n"
        "    Cast(UByte Ptr, source->data)[6] = 0\n"
        "    Return source\n"
        "End Function\n"
        "Dim As TestFBSTRING Ptr emptyResult = @fbContext.null_desc\n"
        "If ProbeStrLeft(0, 2) <> emptyResult Then End 1\n"
        "If ProbeStrRight(0, 2) <> emptyResult Then End 2\n"
        "Dim As TestFBSTRING Ptr source = NewAlphabetSource()\n"
        "If source = 0 Then End 3\n"
        "Dim As TestFBSTRING Ptr result = ProbeStrLeft(source, 3)\n"
        "If result = 0 OrElse DescriptorLength(result) <> 3 Then End 4\n"
        "For index As Long = 0 To 2\n"
        "    If Cast(UByte Ptr, result->data)[index] <> Asc(\"a\") + index Then End 5\n"
        "Next\n"
        "If Cast(UByte Ptr, result->data)[3] <> 0 Then End 6\n"
        "ProbeDeleteTemp(result)\n"
        "source = NewAlphabetSource()\n"
        "If source = 0 Then End 7\n"
        "result = ProbeStrRight(source, 3)\n"
        "If result = 0 OrElse DescriptorLength(result) <> 3 Then End 8\n"
        "For index As Long = 0 To 2\n"
        "    If Cast(UByte Ptr, result->data)[index] <> Asc(\"d\") + index Then End 9\n"
        "Next\n"
        "If Cast(UByte Ptr, result->data)[3] <> 0 Then End 10\n"
        "ProbeDeleteTemp(result)\n"
        "source = NewAlphabetSource()\n"
        "If source = 0 Then End 11\n"
        "result = ProbeStrLeft(source, 20)\n"
        "If result = 0 OrElse DescriptorLength(result) <> 6 Then End 12\n"
        "For index As Long = 0 To 5\n"
        "    If Cast(UByte Ptr, result->data)[index] <> Asc(\"a\") + index Then End 13\n"
        "Next\n"
        "ProbeDeleteTemp(result)\n"
        "source = NewAlphabetSource()\n"
        "If source = 0 Then End 14\n"
        "result = ProbeStrRight(source, 20)\n"
        "If result = 0 OrElse DescriptorLength(result) <> 6 Then End 15\n"
        "For index As Long = 0 To 5\n"
        "    If Cast(UByte Ptr, result->data)[index] <> Asc(\"a\") + index Then End 16\n"
        "Next\n"
        "ProbeDeleteTemp(result)\n"
        "source = ProbeAllocTemp(0, 3)\n"
        "If source = 0 Then End 17\n"
        "Cast(UByte Ptr, source->data)[0] = Asc(\"A\")\n"
        "Cast(UByte Ptr, source->data)[1] = 0\n"
        "Cast(UByte Ptr, source->data)[2] = Asc(\"B\")\n"
        "Cast(UByte Ptr, source->data)[3] = 0\n"
        "result = ProbeStrLeft(source, 3)\n"
        "If result = 0 OrElse DescriptorLength(result) <> 3 Then End 18\n"
        "If Cast(UByte Ptr, result->data)[0] <> Asc(\"A\") Then End 19\n"
        "If Cast(UByte Ptr, result->data)[1] <> 0 Then End 20\n"
        "If Cast(UByte Ptr, result->data)[2] <> Asc(\"B\") Then End 21\n"
        "ProbeDeleteTemp(result)\n"
        "source = ProbeAllocTemp(0, 3)\n"
        "If source = 0 Then End 22\n"
        "Cast(UByte Ptr, source->data)[0] = Asc(\"A\")\n"
        "Cast(UByte Ptr, source->data)[1] = 0\n"
        "Cast(UByte Ptr, source->data)[2] = Asc(\"B\")\n"
        "Cast(UByte Ptr, source->data)[3] = 0\n"
        "result = ProbeStrRight(source, 2)\n"
        "If result = 0 OrElse DescriptorLength(result) <> 2 Then End 23\n"
        "If Cast(UByte Ptr, result->data)[0] <> 0 Then End 24\n"
        "If Cast(UByte Ptr, result->data)[1] <> Asc(\"B\") Then End 25\n"
        "ProbeDeleteTemp(result)\n"
        "If ProbeStrLeft(@fbContext.null_desc, 4) <> emptyResult Then End 26\n"
        "If ProbeStrRight(@fbContext.null_desc, 4) <> emptyResult Then End 27\n"
        "' The runtime temporary-descriptor pool has 256 entries; 301 rounds catch leaks.\n"
        "For index As Long = 0 To 300\n"
        "    source = ProbeAllocTemp(0, 1)\n"
        "    If source = 0 Then End 28\n"
        "    Cast(UByte Ptr, source->data)[0] = Asc(\"x\")\n"
        "    Cast(UByte Ptr, source->data)[1] = 0\n"
        "    result = ProbeStrLeft(source, 1)\n"
        "    If result = 0 OrElse DescriptorLength(result) <> 1 Then End 29\n"
        "    ProbeDeleteTemp(result)\n"
        "Next\n"
        "For index As Long = 0 To 300\n"
        "    source = ProbeAllocTemp(0, 1)\n"
        "    If source = 0 Then End 30\n"
        "    Cast(UByte Ptr, source->data)[0] = Asc(\"y\")\n"
        "    Cast(UByte Ptr, source->data)[1] = 0\n"
        "    result = ProbeStrRight(source, 1)\n"
        "    If result = 0 OrElse DescriptorLength(result) <> 1 Then End 31\n"
        "    ProbeDeleteTemp(result)\n"
        "Next\n"
        "End 0\n"
    )

    string_skip_probe = module_directory / "string-skip-check.bas"
    string_skip_probe.write_text(
        '#include once "crt/stddef.bi"\n'
        "Declare Function ProbeSkipChar CDecl Alias \"fb_hStrSkipChar\" ("
        "ByVal source As Byte Ptr, ByVal byteCount As ssize_t, "
        "ByVal character As Long) As Byte Ptr\n"
        "Declare Function ProbeSkipCharRev CDecl Alias \"fb_hStrSkipCharRev\" ("
        "ByVal source As Byte Ptr, ByVal byteCount As ssize_t, "
        "ByVal character As Long) As Byte Ptr\n"
        "Dim bytes(0 To 5) As Byte\n"
        "bytes(0) = 32\n"
        "bytes(1) = 32\n"
        "bytes(2) = Asc(\"A\")\n"
        "bytes(3) = Asc(\"B\")\n"
        "bytes(4) = 32\n"
        "bytes(5) = 32\n"
        "If ProbeSkipChar(0, 4, 32) <> 0 Then End 1\n"
        "If ProbeSkipChar(@bytes(0), 0, 32) <> @bytes(0) Then End 2\n"
        "If ProbeSkipChar(@bytes(0), -1, 32) <> @bytes(0) Then End 3\n"
        "If ProbeSkipChar(@bytes(0), 2, 32) <> @bytes(2) Then End 4\n"
        "If ProbeSkipChar(@bytes(0), 6, 32) <> @bytes(2) Then End 5\n"
        "Dim minLength As ssize_t = Cast(ssize_t, &H8000000000000000ULL)\n"
        "If ProbeSkipChar(@bytes(0), minLength, 32) <> @bytes(0) Then End 6\n"
        "If ProbeSkipCharRev(0, 4, 32) <> 0 Then End 7\n"
        "If ProbeSkipCharRev(@bytes(0), 0, 32) <> @bytes(0) Then End 8\n"
        "If ProbeSkipCharRev(@bytes(0), -1, 32) <> @bytes(0) Then End 9\n"
        "If ProbeSkipCharRev(@bytes(0), 6, 32) <> @bytes(3) Then End 10\n"
        "If ProbeSkipCharRev(@bytes(0), 2, 32) <> 0 Then End 11\n"
        "Dim padded(0 To 2) As Byte\n"
        "padded(0) = Asc(\"A\")\n"
        "padded(1) = 0\n"
        "padded(2) = 0\n"
        "If ProbeSkipCharRev(@padded(0), 3, 32) <> @padded(0) Then End 12\n"
        "Dim allNul(0 To 2) As Byte\n"
        "If ProbeSkipCharRev(@allNul(0), 3, 32) <> 0 Then End 13\n"
        "Dim highByte(0 To 0) As Byte\n"
        "highByte(0) = -1\n"
        "If ProbeSkipChar(@highByte(0), 1, -1) <> @highByte(0) + 1 Then End 14\n"
        "If ProbeSkipCharRev(@highByte(0), 1, -1) <> 0 Then End 15\n"
        "End 0\n"
    )

    trim_callers_probe = module_directory / "trim-callers-check.bas"
    trim_callers_probe.write_text(
        '#include once "crt/stddef.bi"\n'
        "Type TestFBSTRING\n"
        "    data As ZString Ptr\n"
        "    len As ssize_t\n"
        "    size As ssize_t\n"
        "End Type\n"
        "Type TestFB_RTLIB_CTX_PREFIX\n"
        "    argc As Long\n"
        "    argv As ZString Ptr Ptr\n"
        "    null_desc As TestFBSTRING\n"
        "End Type\n"
        "Extern fbContext Alias \"__fb_ctx\" As TestFB_RTLIB_CTX_PREFIX\n"
        "Declare Function ProbeAllocTemp CDecl Alias \"fb_hStrAllocTemp\" ("
        "ByVal descriptor As TestFBSTRING Ptr, ByVal size As ssize_t) As TestFBSTRING Ptr\n"
        "Declare Function ProbeDeleteTemp CDecl Alias \"fb_hStrDelTemp\" ("
        "ByVal descriptor As TestFBSTRING Ptr) As Long\n"
        "Declare Function ProbeLTrim CDecl Alias \"fb_LTRIM\" ("
        "ByVal source As TestFBSTRING Ptr) As TestFBSTRING Ptr\n"
        "Declare Function ProbeRTrim CDecl Alias \"fb_RTRIM\" ("
        "ByVal source As TestFBSTRING Ptr) As TestFBSTRING Ptr\n"
        "Declare Function ProbeTrim CDecl Alias \"fb_TRIM\" ("
        "ByVal source As TestFBSTRING Ptr) As TestFBSTRING Ptr\n"
        "Declare Function ProbeLTrimEx CDecl Alias \"fb_LTrimEx\" ("
        "ByVal source As TestFBSTRING Ptr, ByVal pattern As TestFBSTRING Ptr) As TestFBSTRING Ptr\n"
        "Declare Function ProbeRTrimEx CDecl Alias \"fb_RTrimEx\" ("
        "ByVal source As TestFBSTRING Ptr, ByVal pattern As TestFBSTRING Ptr) As TestFBSTRING Ptr\n"
        "Declare Function ProbeTrimEx CDecl Alias \"fb_TrimEx\" ("
        "ByVal source As TestFBSTRING Ptr, ByVal pattern As TestFBSTRING Ptr) As TestFBSTRING Ptr\n"
        "Const tempBit As ULongInt = &H8000000000000000ULL\n"
        "Private Function DescriptorLength(ByVal descriptor As TestFBSTRING Ptr) As ssize_t\n"
        "    Return Cast(ssize_t, Cast(size_t, descriptor->len) And Not tempBit)\n"
        "End Function\n"
        "Private Function NewTemp(ByVal bytes As Byte Ptr, ByVal byteCount As ssize_t) As TestFBSTRING Ptr\n"
        "    Dim As TestFBSTRING Ptr descriptor = ProbeAllocTemp(0, byteCount)\n"
        "    If descriptor = 0 Then Return 0\n"
        "    For index As Long = 0 To byteCount - 1\n"
        "        Cast(UByte Ptr, descriptor->data)[index] = Cast(UByte, bytes[index])\n"
        "    Next\n"
        "    Cast(UByte Ptr, descriptor->data)[byteCount] = 0\n"
        "    Return descriptor\n"
        "End Function\n"
        "Private Sub CheckResult(ByVal result As TestFBSTRING Ptr, ByVal expected As Byte Ptr, "
        "ByVal byteCount As Long, ByVal failureCode As Long)\n"
        "    If result = 0 OrElse DescriptorLength(result) <> byteCount Then End failureCode\n"
        "    For index As Long = 0 To byteCount - 1\n"
        "        If Cast(UByte Ptr, result->data)[index] <> Cast(UByte, expected[index]) Then End failureCode + 1\n"
        "    Next\n"
        "    If result->data <> 0 Then\n"
        "        If Cast(UByte Ptr, result->data)[byteCount] <> 0 Then End failureCode + 2\n"
        "    End If\n"
        "    If result <> @fbContext.null_desc Then ProbeDeleteTemp(result)\n"
        "End Sub\n"
        "Dim alphabet(0 To 5) As Byte\n"
        "For index As Long = 0 To 5\n"
        "    alphabet(index) = Asc(\"a\") + index\n"
        "Next\n"
        "Dim expectedAB(0 To 1) As Byte\n"
        "expectedAB(0) = Asc(\"a\")\n"
        "expectedAB(1) = Asc(\"b\")\n"
        "Dim expectedBC(0 To 1) As Byte\n"
        "expectedBC(0) = Asc(\"b\")\n"
        "expectedBC(1) = Asc(\"c\")\n"
        "Dim As TestFBSTRING Ptr result\n"
        "result = ProbeLTrim(NewTemp(@alphabet(0), 6))\n"
        "CheckResult(result, @alphabet(0), 6, 1)\n"
        "Dim spaces(0 To 3) As Byte\n"
        "For index As Long = 0 To 3\n"
        "    spaces(index) = 32\n"
        "Next\n"
        "result = ProbeLTrim(NewTemp(@spaces(0), 4))\n"
        "CheckResult(result, 0, 0, 4)\n"
        "Dim leftTrim(0 To 3) As Byte\n"
        "leftTrim(0) = 32\n"
        "leftTrim(1) = 32\n"
        "leftTrim(2) = Asc(\"a\")\n"
        "leftTrim(3) = Asc(\"b\")\n"
        "result = ProbeLTrim(NewTemp(@leftTrim(0), 4))\n"
        "CheckResult(result, @expectedAB(0), 2, 7)\n"
        "Dim rightTrim(0 To 3) As Byte\n"
        "rightTrim(0) = Asc(\"a\")\n"
        "rightTrim(1) = Asc(\"b\")\n"
        "rightTrim(2) = 32\n"
        "rightTrim(3) = 32\n"
        "result = ProbeRTrim(NewTemp(@rightTrim(0), 4))\n"
        "CheckResult(result, @expectedAB(0), 2, 10)\n"
        "result = ProbeRTrim(NewTemp(@spaces(0), 4))\n"
        "CheckResult(result, 0, 0, 13)\n"
        "Dim bothTrim(0 To 5) As Byte\n"
        "bothTrim(0) = 32\n"
        "bothTrim(1) = 32\n"
        "bothTrim(2) = Asc(\"a\")\n"
        "bothTrim(3) = Asc(\"b\")\n"
        "bothTrim(4) = 32\n"
        "bothTrim(5) = 32\n"
        "result = ProbeTrim(NewTemp(@bothTrim(0), 6))\n"
        "CheckResult(result, @expectedAB(0), 2, 16)\n"
        "result = ProbeTrim(NewTemp(@spaces(0), 4))\n"
        "CheckResult(result, 0, 0, 19)\n"
        "Dim patternByte(0 To 0) As Byte\n"
        "patternByte(0) = Asc(\"x\")\n"
        "Dim rtrimExInput(0 To 4) As Byte\n"
        "rtrimExInput(0) = Asc(\"a\")\n"
        "rtrimExInput(1) = Asc(\"b\")\n"
        "rtrimExInput(2) = Asc(\"x\")\n"
        "rtrimExInput(3) = Asc(\"x\")\n"
        "rtrimExInput(4) = Asc(\"x\")\n"
        "result = ProbeRTrimEx(NewTemp(@rtrimExInput(0), 5), NewTemp(@patternByte(0), 1))\n"
        "CheckResult(result, @expectedAB(0), 2, 22)\n"
        "Dim allPattern(0 To 3) As Byte\n"
        "For index As Long = 0 To 3\n"
        "    allPattern(index) = Asc(\"x\")\n"
        "Next\n"
        "result = ProbeRTrimEx(NewTemp(@allPattern(0), 4), NewTemp(@patternByte(0), 1))\n"
        "CheckResult(result, 0, 0, 25)\n"
        "Dim trimExInput(0 To 5) As Byte\n"
        "trimExInput(0) = Asc(\"x\")\n"
        "trimExInput(1) = Asc(\"x\")\n"
        "trimExInput(2) = Asc(\"a\")\n"
        "trimExInput(3) = Asc(\"b\")\n"
        "trimExInput(4) = Asc(\"x\")\n"
        "trimExInput(5) = Asc(\"x\")\n"
        "result = ProbeTrimEx(NewTemp(@trimExInput(0), 6), NewTemp(@patternByte(0), 1))\n"
        "CheckResult(result, @expectedAB(0), 2, 28)\n"
        "Dim ltrimExInput(0 To 3) As Byte\n"
        "ltrimExInput(0) = Asc(\"x\")\n"
        "ltrimExInput(1) = Asc(\"x\")\n"
        "ltrimExInput(2) = Asc(\"b\")\n"
        "ltrimExInput(3) = Asc(\"c\")\n"
        "result = ProbeLTrimEx(NewTemp(@ltrimExInput(0), 4), NewTemp(@patternByte(0), 1))\n"
        "CheckResult(result, @expectedBC(0), 2, 31)\n"
        "Dim patternPair(0 To 1) As Byte\n"
        "patternPair(0) = Asc(\"x\")\n"
        "patternPair(1) = Asc(\"y\")\n"
        "Dim multiRight(0 To 7) As Byte\n"
        "multiRight(0) = Asc(\"a\")\n"
        "multiRight(1) = Asc(\"b\")\n"
        "For index As Long = 2 To 7\n"
        "    multiRight(index) = patternPair((index - 2) Mod 2)\n"
        "Next\n"
        "result = ProbeRTrimEx(NewTemp(@multiRight(0), 8), NewTemp(@patternPair(0), 2))\n"
        "CheckResult(result, @expectedAB(0), 2, 37)\n"
        "result = ProbeTrimEx(NewTemp(@multiRight(0), 8), NewTemp(@patternPair(0), 2))\n"
        "CheckResult(result, @expectedAB(0), 2, 38)\n"
        "Dim multiLeft(0 To 5) As Byte\n"
        "For index As Long = 0 To 3\n"
        "    multiLeft(index) = patternPair(index Mod 2)\n"
        "Next\n"
        "multiLeft(4) = Asc(\"b\")\n"
        "multiLeft(5) = Asc(\"c\")\n"
        "result = ProbeLTrimEx(NewTemp(@multiLeft(0), 6), NewTemp(@patternPair(0), 2))\n"
        "CheckResult(result, @expectedBC(0), 2, 40)\n"
        "Dim multiBoth(0 To 7) As Byte\n"
        "For index As Long = 0 To 7\n"
        "    multiBoth(index) = patternPair(index Mod 2)\n"
        "Next\n"
        "result = ProbeTrimEx(NewTemp(@multiBoth(0), 8), NewTemp(@patternPair(0), 2))\n"
        "CheckResult(result, 0, 0, 43)\n"
        "result = ProbeRTrimEx(NewTemp(@multiBoth(0), 8), NewTemp(@patternPair(0), 2))\n"
        "CheckResult(result, 0, 0, 46)\n"
        "Dim nulPadded(0 To 2) As Byte\n"
        "nulPadded(0) = Asc(\"A\")\n"
        "nulPadded(1) = 0\n"
        "nulPadded(2) = 0\n"
        "result = ProbeRTrim(NewTemp(@nulPadded(0), 3))\n"
        "CheckResult(result, @nulPadded(0), 1, 34)\n"
        "End 0\n"
    )

    string_chr_probe = module_directory / "string-chr-check.bas"
    string_chr_probe.write_text(
        '#include once "crt/stddef.bi"\n'
        '#include once "crt/sys/types.bi"\n'
        "Type TestFBSTRING\n"
        "    data As ZString Ptr\n"
        "    len As ssize_t\n"
        "    size As ssize_t\n"
        "End Type\n"
        "Declare Function ProbeChr CDecl Alias \"fb_CHR\" (ByVal count As Long, ...) As TestFBSTRING Ptr\n"
        "Declare Function ProbeDeleteTemp CDecl Alias \"fb_hStrDelTemp\" ("
        "ByVal descriptor As TestFBSTRING Ptr) As Long\n"
        "Const tempBit As ULongInt = &H8000000000000000ULL\n"
        "Private Function DescriptorLength(ByVal descriptor As TestFBSTRING Ptr) As ssize_t\n"
        "    Return Cast(ssize_t, Cast(size_t, descriptor->len) And Not tempBit)\n"
        "End Function\n"
        "Private Sub CheckChr(ByVal descriptor As TestFBSTRING Ptr, "
        "ByVal expected As UByte Ptr, ByVal length As Long, ByVal code As Long)\n"
        "    If descriptor = 0 Then End code\n"
        "    If DescriptorLength(descriptor) <> length Then End (code + 1)\n"
        "    For index As Long = 0 To length - 1\n"
        "        If Cast(UByte Ptr, descriptor->data)[index] <> expected[index] Then End (code + 2)\n"
        "    Next\n"
        "    If Cast(UByte Ptr, descriptor->data)[length] <> 0 Then End (code + 3)\n"
        "    ProbeDeleteTemp(descriptor)\n"
        "End Sub\n"
        "Dim As TestFBSTRING Ptr emptyResult = ProbeChr(0)\n"
        "If emptyResult = 0 OrElse DescriptorLength(emptyResult) <> 0 Then End 1\n"
        "Dim one(0 To 0) As UByte = {65}\n"
        "CheckChr(ProbeChr(1, CULng(65)), @one(0), 1, 10)\n"
        "Dim mixed(0 To 3) As UByte = {0, 65, 0, 255}\n"
        "CheckChr(ProbeChr(4, CULng(0), CULng(65), CULng(256), CULng(511)), "
        "@mixed(0), 4, 20)\n"
        "Dim thirtyTwo(0 To 31) As UByte\n"
        "For index As Long = 0 To 31\n"
        "    thirtyTwo(index) = Cast(UByte, index)\n"
        "Next\n"
        "CheckChr(ProbeChr(32, _\n"
        "    CULng(0), CULng(1), CULng(2), CULng(3), CULng(4), CULng(5), CULng(6), CULng(7), _\n"
        "    CULng(8), CULng(9), CULng(10), CULng(11), CULng(12), CULng(13), CULng(14), CULng(15), _\n"
        "    CULng(16), CULng(17), CULng(18), CULng(19), CULng(20), CULng(21), CULng(22), CULng(23), _\n"
        "    CULng(24), CULng(25), CULng(26), CULng(27), CULng(28), CULng(29), CULng(30), CULng(31)), _\n"
        "    @thirtyTwo(0), 32, 30)\n"
        "End 0\n"
    )

    string_asc_probe = module_directory / "string-asc-check.bas"
    string_asc_probe.write_text(
        '#include once "crt/stddef.bi"\n'
        '#include once "crt/sys/types.bi"\n'
        "Type TestFBSTRING\n"
        "    data As ZString Ptr\n"
        "    len As ssize_t\n"
        "    size As ssize_t\n"
        "End Type\n"
        "Declare Function ProbeAsc CDecl Alias \"fb_ASC\" ("
        "ByVal source As TestFBSTRING Ptr, ByVal position As ssize_t) As ULong\n"
        "Dim bytes(0 To 4) As UByte\n"
        "bytes(0) = 65\n"
        "bytes(1) = 0\n"
        "bytes(2) = 66\n"
        "bytes(3) = 255\n"
        "bytes(4) = 0\n"
        "Dim descriptor As TestFBSTRING\n"
        "descriptor.data = CPtr(ZString Ptr, @bytes(0))\n"
        "descriptor.len = 4\n"
        "descriptor.size = 4\n"
        "If ProbeAsc(0, 1) <> 0 Then End 1\n"
        "If ProbeAsc(@descriptor, -1) <> 0 Then End 2\n"
        "If ProbeAsc(@descriptor, 0) <> 0 Then End 3\n"
        "If ProbeAsc(@descriptor, 1) <> 65 Then End 4\n"
        "If ProbeAsc(@descriptor, 2) <> 0 Then End 5\n"
        "If ProbeAsc(@descriptor, 3) <> 66 Then End 6\n"
        "If ProbeAsc(@descriptor, 4) <> 255 Then End 7\n"
        "If ProbeAsc(@descriptor, 5) <> 0 Then End 8\n"
        "descriptor.data = 0\n"
        "If ProbeAsc(@descriptor, 1) <> 0 Then End 9\n"
        "descriptor.data = CPtr(ZString Ptr, @bytes(0))\n"
        "descriptor.len = 0\n"
        "If ProbeAsc(@descriptor, 1) <> 0 Then End 10\n"
        "End 0\n"
    )

    string_reverse_probe = module_directory / "string-reverse-check.bas"
    string_reverse_probe.write_text(
        '#include once "crt/stddef.bi"\n'
        '#include once "crt/sys/types.bi"\n'
        "Type TestFBSTRING\n"
        "    data As ZString Ptr\n"
        "    len As ssize_t\n"
        "    size As ssize_t\n"
        "End Type\n"
        "Declare Function ProbeReverse CDecl Alias \"fb_StrReverse\" ("
        "ByVal source As TestFBSTRING Ptr) As TestFBSTRING Ptr\n"
        "Declare Function ProbeAllocTemp CDecl Alias \"fb_hStrAllocTemp\" ("
        "ByVal descriptor As TestFBSTRING Ptr, ByVal size As ssize_t) As TestFBSTRING Ptr\n"
        "Declare Function ProbeDeleteTemp CDecl Alias \"fb_hStrDelTemp\" ("
        "ByVal descriptor As TestFBSTRING Ptr) As Long\n"
        "Const tempBit As ULongInt = &H8000000000000000ULL\n"
        "Private Function DescriptorLength(ByVal descriptor As TestFBSTRING Ptr) As ssize_t\n"
        "    Return Cast(ssize_t, Cast(size_t, descriptor->len) And Not tempBit)\n"
        "End Function\n"
        "Dim As TestFBSTRING Ptr result = ProbeReverse(0)\n"
        "If result = 0 OrElse result->data <> 0 OrElse DescriptorLength(result) <> 0 Then End 1\n"
        "Dim emptyBytes(0 To 0) As UByte\n"
        "Dim emptySource As TestFBSTRING\n"
        "emptySource.data = CPtr(ZString Ptr, @emptyBytes(0))\n"
        "emptySource.len = 0\n"
        "emptySource.size = 0\n"
        "If ProbeReverse(@emptySource) <> result Then End 2\n"
        "Dim sourceBytes(0 To 3) As UByte = {65, 0, 66, 255}\n"
        "Dim source As TestFBSTRING\n"
        "source.data = CPtr(ZString Ptr, @sourceBytes(0))\n"
        "source.len = 4\n"
        "source.size = 4\n"
        "result = ProbeReverse(@source)\n"
        "If result = 0 OrElse DescriptorLength(result) <> 4 Then End 3\n"
        "If Cast(UByte Ptr, result->data)[0] <> 255 Then End 4\n"
        "If Cast(UByte Ptr, result->data)[1] <> 66 Then End 5\n"
        "If Cast(UByte Ptr, result->data)[2] <> 0 Then End 6\n"
        "If Cast(UByte Ptr, result->data)[3] <> 65 Then End 7\n"
        "If Cast(UByte Ptr, result->data)[4] <> 0 Then End 8\n"
        "ProbeDeleteTemp(result)\n"
        "For index As Long = 0 To 300\n"
        "    Dim As TestFBSTRING Ptr temporarySource = ProbeAllocTemp(0, 1)\n"
        "    If temporarySource = 0 Then End 9\n"
        "    Cast(UByte Ptr, temporarySource->data)[0] = Asc(\"x\")\n"
        "    Cast(UByte Ptr, temporarySource->data)[1] = 0\n"
        "    result = ProbeReverse(temporarySource)\n"
        "    If result = 0 OrElse DescriptorLength(result) <> 1 Then End 10\n"
        "    If Cast(UByte Ptr, result->data)[0] <> Asc(\"x\") Then End 11\n"
        "    ProbeDeleteTemp(result)\n"
        "Next\n"
        "End 0\n"
    )

    string_reverse_probe = module_directory / "string-reverse-check.bas"
    string_reverse_probe.write_text(
        '#include once "crt/stddef.bi"\n'
        '#include once "crt/sys/types.bi"\n'
        "Type TestFBSTRING\n"
        "    data As ZString Ptr\n"
        "    len As ssize_t\n"
        "    size As ssize_t\n"
        "End Type\n"
        "Declare Function ProbeReverse CDecl Alias \"fb_StrReverse\" ("
        "ByVal source As TestFBSTRING Ptr) As TestFBSTRING Ptr\n"
        "Declare Function ProbeAllocTemp CDecl Alias \"fb_hStrAllocTemp\" ("
        "ByVal descriptor As TestFBSTRING Ptr, ByVal size As ssize_t) As TestFBSTRING Ptr\n"
        "Declare Function ProbeDeleteTemp CDecl Alias \"fb_hStrDelTemp\" ("
        "ByVal descriptor As TestFBSTRING Ptr) As Long\n"
        "Const tempBit As ULongInt = &H8000000000000000ULL\n"
        "Private Function DescriptorLength(ByVal descriptor As TestFBSTRING Ptr) As ssize_t\n"
        "    Return Cast(ssize_t, Cast(size_t, descriptor->len) And Not tempBit)\n"
        "End Function\n"
        "Dim As TestFBSTRING Ptr emptyResult = ProbeReverse(0)\n"
        "If emptyResult = 0 OrElse emptyResult->data <> 0 OrElse "
        "DescriptorLength(emptyResult) <> 0 Then End 1\n"
        "Dim emptyBytes(0 To 0) As UByte = {0}\n"
        "Dim emptySource As TestFBSTRING\n"
        "emptySource.data = CPtr(ZString Ptr, @emptyBytes(0))\n"
        "emptySource.len = 0\n"
        "emptySource.size = 0\n"
        "If ProbeReverse(@emptySource) <> emptyResult Then End 2\n"
        "Dim sourceBytes(0 To 4) As UByte = {65, 0, 66, 255, 0}\n"
        "Dim source As TestFBSTRING\n"
        "source.data = CPtr(ZString Ptr, @sourceBytes(0))\n"
        "source.len = 4\n"
        "source.size = 4\n"
        "Dim As TestFBSTRING Ptr result = ProbeReverse(@source)\n"
        "If result = 0 OrElse DescriptorLength(result) <> 4 Then End 3\n"
        "If Cast(UByte Ptr, result->data)[0] <> 255 Then End 4\n"
        "If Cast(UByte Ptr, result->data)[1] <> 66 Then End 5\n"
        "If Cast(UByte Ptr, result->data)[2] <> 0 Then End 6\n"
        "If Cast(UByte Ptr, result->data)[3] <> 65 Then End 7\n"
        "If Cast(UByte Ptr, result->data)[4] <> 0 Then End 8\n"
        "ProbeDeleteTemp(result)\n"
        "For index As Long = 0 To 300\n"
        "    Dim As TestFBSTRING Ptr temporarySource = ProbeAllocTemp(0, 1)\n"
        "    If temporarySource = 0 Then End 9\n"
        "    Cast(UByte Ptr, temporarySource->data)[0] = Asc(\"x\")\n"
        "    Cast(UByte Ptr, temporarySource->data)[1] = 0\n"
        "    result = ProbeReverse(temporarySource)\n"
        "    If result = 0 OrElse DescriptorLength(result) <> 1 Then End 10\n"
        "    If Cast(UByte Ptr, result->data)[0] <> Asc(\"x\") Then End 11\n"
        "    ProbeDeleteTemp(result)\n"
        "Next\n"
        "End 0\n"
    )

    probes = {
        "str_chr": string_chr_probe,
        "str_asc": string_asc_probe,
        "str_reverse": string_reverse_probe,
        "str_len": string_length_probe,
        "str_fill": string_fill_probe,
        "string-slice": string_slice_probe,
        "string-skip": string_skip_probe,
        "trim-callers": trim_callers_probe,
        "trim-ports": trim_callers_probe,
    }
    implementations = {
        "C reference": reference_objects,
        "FreeBASIC port": {
            stem: module_directory / f"{stem}-mt.o"
            for stem in string_stems
        },
        "C2FB candidate": candidate_objects,
    }
    for implementation, objects in implementations.items():
        for stem, probe in probes.items():
            executable = module_directory / f"{stem}-{implementation.replace(' ', '-')}-check"
            if stem == "string-slice":
                linked_objects = [objects["str_left"], objects["str_right"]]
            elif stem == "string-skip":
                linked_objects = [objects["str_hskip"]]
            elif stem == "trim-callers":
                linked_objects = [objects["str_hskip"], *trim_caller_objects]
            elif stem == "trim-ports":
                linked_objects = [
                    objects["str_hskip"],
                    objects["str_ltrim"], objects["str_ltrimex"],
                    objects["str_rtrim"], objects["str_rtrimex"],
                    objects["str_trim"], objects["str_trimex"],
                ]
            else:
                linked_objects = [objects[stem]]
            run(fbc + [
                "-w", "all", "-mt", "-d", "ENABLE_MT",
                "-i", str(include_directory), str(probe),
                *(str(object_path) for object_path in linked_objects),
                "-x", str(executable),
            ], cwd=module_directory)
            run([str(executable)], cwd=module_directory)
    print(
        "RTLIB strings: C, FreeBASIC ports, and C2FB candidates passed "
        "ASC byte boundaries, CHR$ varargs, StrReverse byte and temporary ownership, "
        "length, fill, LEFT$/RIGHT$, skip/trim edges, "
        "and ABI checks"
    )


def main():
    parser = argparse.ArgumentParser(
        description="Run focused FreeBASIC RTLIB source checks."
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
        parser.error("the current RTLIB C2FB profile requires Linux x86-64")

    fbc = shlex.split(args.fbc)
    cc = shlex.split(args.cc)
    if not fbc or not cc:
        parser.error("--fbc and --cc must each contain a command")
    source_root = Path(args.source_directory).resolve()
    rtlib_directory = source_root / "rtlib"
    if not rtlib_directory.is_dir():
        parser.error(f"FreeBASIC RTLIB source directory is missing: {rtlib_directory}")

    with tempfile.TemporaryDirectory(prefix="c2fb-freebasic-rtlib-") as temp:
        work = Path(temp)
        check_rtlib_source_graph(source_root)
        check_rtlib_graph_precedence(source_root, work)
        check_basic_wrappers(fbc, cc, source_root, work)
        candidate_objects = check_c2fb_candidates(
            args.converter, fbc, cc, source_root,
            Path(args.profile_directory).resolve(), work,
        )
        check_c2fb_wide_bool_candidate(
            args.converter, fbc, cc, source_root,
            Path(args.profile_directory).resolve(), work,
        )
        check_c2fb_math_rnd(
            args.converter, fbc, cc, source_root,
            Path(args.profile_directory).resolve(), work,
        )
        check_c2fb_wide_numeric_candidates(
            args.converter, fbc, cc, source_root,
            Path(args.profile_directory).resolve(), work,
        )
        check_basic_string_routines(
            fbc, cc, source_root, candidate_objects, work,
        )
        check_c2fb_numeric_strings(
            fbc, cc, source_root, candidate_objects, work,
        )


if __name__ == "__main__":
    main()

# end of test_freebasic_rtlib.py
