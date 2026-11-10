#!/usr/bin/env python3
"""
Project: GNU Coreutils FreeBASIC port
File: check.py
Purpose: Run the focused converter regressions used during this port.
Responsibilities: Build the selected converter and exercise its existing
regressions with C reference comparisons where available.
This file intentionally does NOT contain: Converter test implementations,
SQLite integration fixtures, or upstream Coreutils utility tests.
"""

import argparse
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

import port


def check_coreutils_oputs(converter, fbc, cc, work):
    # Keep ANSI option formatting byte-for-byte compatible with system.h.
    source_path = (port.SOURCE / "src/basename.c").resolve()
    compile_commands = json.loads(
        (port.PORT / "build/compile_commands.json").read_text(encoding="utf-8")
    )
    entries = [
        entry for entry in compile_commands
        if (Path(entry["directory"]) / entry["file"]).resolve() == source_path
    ]
    assert len(entries) == 1, f"expected one basename compile command, got {len(entries)}"

    source_directory = work / "coreutils-oputs"
    source_directory.mkdir()
    database = source_directory / "compile_commands.json"
    database.write_text(json.dumps(entries), encoding="utf-8")
    output_directory = source_directory / "generated"

    spec = importlib.util.spec_from_file_location(
        "coreutils_oputs_compile_commands",
        port.TOOLS / "c2fb_compile_commands.py",
    )
    driver = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = driver
    spec.loader.exec_module(driver)
    result = driver.run_compile_database(
        database,
        output_directory,
        converter,
        port.BODY_OPTIONS,
        source_unit_context=True,
        header_options=port.HEADER_OPTIONS,
        jobs=1,
        body_compiler_options=port.BODY_COMPILER_OPTIONS,
    )
    assert result == 0, "C2FB failed to translate the basename source unit"
    candidates = list(output_directory.glob("*_candidates.bas"))
    assert len(candidates) == 1, f"expected one basename candidate, got {len(candidates)}"
    candidate = candidates[0]
    generated = candidate.read_text(encoding="utf-8")
    assert "Private Sub oputs_" in generated, "system.h oputs_ was not emitted"
    assert "CoreutilsIsSpaceAtPointer" in generated, "isspace replacement was not used"
    assert (
        "CoreutilsFwriteUnlocked" in generated or "fwrite_unlocked" in generated
    ), "stdout fwrite path was not emitted"
    assert (
        "CoreutilsStdout()" in generated or "c2fb_global_stdout" in generated
    ), "stdout storage was not emitted"

    # This harness calls oputs_ directly, so keep the translated C entrypoint
    # out of the executable that FreeBASIC builds with its own main routine.
    main_declaration = 'Function main CDecl Alias "main"'
    assert generated.count(main_declaration) == 2
    local_candidate = source_directory / candidate.name
    local_candidate.write_text(
        generated.replace(
            main_declaration,
            'Function c2fb_basename_main CDecl Alias "c2fb_basename_main"',
        ),
        encoding="utf-8",
    )
    type_context = candidate.with_name(candidate.stem + "_types.bi")
    shutil.copy2(type_context, source_directory / type_context.name)

    version_candidates = sorted(
        candidate
        for candidate in (port.PORT / "generated-context").glob("*_candidates.bas")
        if "c2fb global definition Version=c2fb_global_Version"
        in candidate.read_text(encoding="utf-8")
    )
    assert version_candidates, "no generated candidate defines Version"
    # Version is only a link fixture here; body-option changes can change its
    # candidate hash without changing this source-global string definition.
    version_candidate = version_candidates[0]

    reference_source = source_directory / "reference.c"
    reference_source.write_text(
        "#include <config.h>\n"
        '#include "system.h"\n'
        "int main(int argc, char **argv) {\n"
        '    const char *option = argc > 1 ? argv[1] : "";\n'
        '    oputs_("basename", option);\n'
        "    return 0;\n"
        "}\n",
        encoding="utf-8",
    )
    compiler_arguments = entries[0].get("arguments")
    assert compiler_arguments, "basename compile command has no argument vector"
    compile_flags = []
    argument_index = 1
    while argument_index < len(compiler_arguments):
        argument = compiler_arguments[argument_index]
        if argument in {"-I", "-D", "-U"}:
            assert argument_index + 1 < len(compiler_arguments)
            compile_flags.extend(compiler_arguments[argument_index:argument_index + 2])
            argument_index += 2
            continue
        if argument.startswith(("-I", "-D", "-U", "-std=")):
            compile_flags.append(argument)
        argument_index += 1
    reference = source_directory / "reference"
    reference_library = port.REFERENCE / "lib/libcoreutils.a"
    assert reference_library.is_file(), f"Coreutils reference library is missing: {reference_library}"
    reference_result = subprocess.run(
        cc + compile_flags + [
            str(reference_source), str(reference_library), "-o", str(reference),
        ],
        cwd=entries[0]["directory"], capture_output=True, text=True, check=False,
    )
    assert reference_result.returncode == 0, (
        reference_result.stdout + reference_result.stderr
    )

    freebasic_source = source_directory / "converted.bas"
    freebasic_source.write_text(
        f'#include once "{local_candidate.as_posix()}"\n'
        f'#include once "{version_candidate.as_posix()}"\n'
        'Dim programName As ZString * 16 = "basename"\n'
        "Dim optionText As String = Command(1)\n"
        "oputs_(@programName, StrPtr(optionText))\n",
        encoding="utf-8",
    )
    converted = source_directory / "converted"
    reference_library = port.REFERENCE / "lib/libcoreutils.a"
    assert reference_library.is_file(), f"Coreutils reference library is missing: {reference_library}"
    converted_result = subprocess.run(
        fbc + [
            "-w", "all", "-i", str(port.SOURCE), "-i", str(source_directory),
            str(freebasic_source), str(reference_library), "-x", str(converted),
        ],
        cwd=port.SOURCE, capture_output=True, text=True, check=False,
    )
    assert converted_result.returncode == 0, (
        converted_result.stdout + converted_result.stderr
    )

    option_texts = (
        "  --help  option description\n",
        "before -x option description\n",
        "before  -x option description\n",
        "before\t -x option description\n",
        "  -a, --alpha[=VALUE] description\n",
    )
    for term in ("xterm", "dumb", None):
        environment = os.environ.copy()
        if term is None:
            environment.pop("TERM", None)
        else:
            environment["TERM"] = term
        for option_text in option_texts:
            expected = subprocess.run(
                [str(reference), option_text], cwd=entries[0]["directory"],
                env=environment, capture_output=True, check=False,
            )
            actual = subprocess.run(
                [str(converted), option_text], cwd=port.SOURCE,
                env=environment, capture_output=True, check=False,
            )
            assert expected.returncode == 0, expected.stderr
            assert actual.returncode == 0, actual.stderr
            assert actual.stdout == expected.stdout, (
                term, repr(option_text), expected.stdout, actual.stdout
            )


def check_coreutils_fortified_fwrite(converter, fbc, cc, work):
    # Keep glibc's inline fwrite path on source APIs while retaining project
    # branches selected by the production compiler's __OPTIMIZE__ definition.
    source_directory = work / "coreutils-fortified-fwrite"
    source_directory.mkdir()
    source = source_directory / "dired_outbuf.c"
    source.write_text(
        f'#include "{port.REFERENCE / "lib/config.h"}"\n'
        "#include <stdio.h>\n"
        '#include "unlocked-io.h"\n'
        "#include <stddef.h>\n"
        "struct c2fb_bin_str { const char *string; size_t len; };\n"
        "void c2fbDiredOutbuf(const char *s, size_t s_len) {\n"
        "    fwrite(s, sizeof *s, s_len, stdout);\n"
        "}\n"
        "void c2fbPutIndicator(const struct c2fb_bin_str *ind) {\n"
        "    fwrite(ind->string, ind->len, 1, stdout);\n"
        "}\n"
        "void c2fbWriteStdout(const char *buffer, size_t n_bytes) {\n"
        "    if (n_bytes > 0 && fwrite(buffer, 1, n_bytes, stdout) < n_bytes)\n"
        "        clearerr_unlocked(stdout);\n"
        "}\n"
        "#if defined __OPTIMIZE__\n"
        "int c2fbOptimizeBranch(void) { return 1; }\n"
        "#else\n"
        "int c2fbOptimizeBranch(void) { return 2; }\n"
        "#endif\n",
        encoding="utf-8",
    )
    compile_commands = json.loads(
        (port.PORT / "build/compile_commands.json").read_text(encoding="utf-8")
    )
    ls_source = (port.SOURCE / "src/ls.c").resolve()
    entries = [
        entry for entry in compile_commands
        if (Path(entry["directory"]) / entry["file"]).resolve() == ls_source
    ]
    assert len(entries) == 1, f"expected one ls compile command, got {len(entries)}"
    entry = dict(entries[0])
    arguments = list(entry["arguments"])
    arguments[-1] = str(source)
    entry["file"] = str(source)
    entry["arguments"] = arguments
    entry["output"] = "dired_outbuf.o"
    database = source_directory / "compile_commands.json"
    database.write_text(json.dumps([entry]), encoding="utf-8")
    output_directory = source_directory / "generated"

    spec = importlib.util.spec_from_file_location(
        "coreutils_fortified_fwrite_compile_commands",
        port.TOOLS / "c2fb_compile_commands.py",
    )
    driver = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = driver
    spec.loader.exec_module(driver)
    result = driver.run_compile_database(
        database,
        output_directory,
        converter,
        port.BODY_OPTIONS,
        source_unit_context=True,
        header_options=port.HEADER_OPTIONS,
        jobs=1,
        body_compiler_options=port.BODY_COMPILER_OPTIONS,
    )
    assert result == 0, "C2FB failed to translate the fortified fwrite fixture"
    candidates = list(output_directory.glob("*_candidates.bas"))
    assert len(candidates) == 1, f"expected one fwrite candidate, got {len(candidates)}"
    candidate = candidates[0]
    generated = candidate.read_text(encoding="utf-8")
    assert "fwrite_unlocked" in generated, (
        "optimized glibc fwrite did not reduce to its source API call", generated
    )
    assert "c2fbDiredOutbuf" in generated
    assert "c2fbPutIndicator" in generated
    assert "c2fbWriteStdout" in generated
    assert "c2fbOptimizeBranch" in generated
    write_start = generated.rfind("Sub c2fbWriteStdout")
    if write_start < 0:
        write_start = generated.rfind("Function c2fbWriteStdout")
    assert write_start >= 0, "nested stdout write helper was not emitted"
    write_end = generated.find("End Sub", write_start)
    if write_end < 0:
        write_end = generated.find("End Function", write_start)
    write_body = generated[write_start:write_end]
    assert "fwrite_unlocked" in write_body, write_body
    assert "__extension__" not in write_body, write_body
    assert "__builtin_constant_p" not in write_body, write_body

    main_source = source_directory / "main.c"
    main_source.write_text(
        f'#include "{port.REFERENCE / "lib/config.h"}"\n'
        "#include <stddef.h>\n"
        "void c2fbDiredOutbuf(const char *text, size_t length);\n"
        "void c2fbWriteStdout(const char *text, size_t length);\n"
        "int c2fbOptimizeBranch(void);\n"
        "int main(void) {\n"
        '    static const char text[] = "dired-output";\n'
        "    c2fbDiredOutbuf(text, sizeof text - 1);\n"
        "    c2fbWriteStdout(text, sizeof text - 1);\n"
        "    return c2fbOptimizeBranch() != 1;\n"
        "}\n",
        encoding="utf-8",
    )
    reference = source_directory / "reference"
    include_flags = [
        "-O2",
        "-I" + str(port.REFERENCE),
        "-I" + str(port.REFERENCE / "lib"),
        "-I" + str(port.SOURCE),
        "-I" + str(port.SOURCE / "lib"),
        "-I" + str(port.SOURCE / "src"),
    ]
    reference_compile = subprocess.run(
        cc + include_flags + [str(source), str(main_source), "-o", str(reference)],
        cwd=port.REFERENCE, capture_output=True, text=True, check=False,
    )
    assert reference_compile.returncode == 0, (
        reference_compile.stdout + reference_compile.stderr
    )
    expected = subprocess.run(
        [str(reference)], capture_output=True, check=False,
    )
    assert expected.returncode == 0, expected.stderr

    wrapper = source_directory / "converted.bas"
    wrapper.write_text(
        f'#include once "{candidate.as_posix()}"\n'
        'Dim text As ZString * 13 = "dired-output"\n'
        "If c2fbOptimizeBranch() <> 1 Then End 1\n"
        "c2fbDiredOutbuf(@text, 12)\n"
        "c2fbWriteStdout(@text, 12)\n",
        encoding="utf-8",
    )
    converted = source_directory / "converted"
    converted_compile = subprocess.run(
        fbc + [
            "-w", "all", "-i", str(port.SOURCE), "-i", str(port.SOURCE.parent),
            "-i", str(source_directory), str(wrapper), "-x", str(converted),
        ],
        cwd=port.SOURCE, capture_output=True, text=True, check=False,
    )
    assert converted_compile.returncode == 0, (
        converted_compile.stdout + converted_compile.stderr
    )
    actual = subprocess.run(
        [str(converted)], capture_output=True, check=False,
    )
    assert actual.returncode == 0, actual.stderr
    assert actual.stdout == expected.stdout, (expected.stdout, actual.stdout)


def check_coreutils_color_indicator_source(converter, fbc, cc, work):
    # Keep the file-scope byte sequences used by ls's color table intact.
    source_text = (port.SOURCE / "src/ls.c").read_text(encoding="utf-8")

    def extract_declaration(match):
        start = match.start()
        opening = source_text.find("{", start)
        if opening < 0:
            raise AssertionError("C declaration has no initializer body")
        depth = 0
        quote = None
        escaped = False
        block_comment = False
        line_comment = False
        position = opening
        while position < len(source_text):
            char = source_text[position]
            next_char = source_text[position + 1] if position + 1 < len(source_text) else ""
            if line_comment:
                if char == "\n":
                    line_comment = False
            elif block_comment:
                if char == "*" and next_char == "/":
                    block_comment = False
                    position += 1
            elif quote is not None:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == quote:
                    quote = None
            elif char == "/" and next_char == "*":
                block_comment = True
                position += 1
            elif char == "/" and next_char == "/":
                line_comment = True
                position += 1
            elif char in ('"', "'"):
                quote = char
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    semicolon = source_text.find(";", position + 1)
                    if semicolon < 0:
                        raise AssertionError("C declaration has no terminator")
                    return source_text[start:semicolon + 1]
            position += 1
        raise AssertionError("C declaration has unbalanced braces")

    record_match = re.search(r"struct\s+bin_str\s*\{", source_text)
    array_match = re.search(
        r"static\s+struct\s+bin_str\s+color_indicator\s*\[\s*\]\s*=\s*\{",
        source_text,
    )
    assert record_match is not None, "ls.c bin_str record was not found"
    assert array_match is not None, "ls.c color_indicator array was not found"

    source_directory = work / "coreutils-color-indicator-source"
    source_directory.mkdir()
    source = source_directory / "probe.c"
    source.write_text(
        "#include <stddef.h>\n"
        + extract_declaration(record_match) + "\n"
        + extract_declaration(array_match) + "\n"
        + "int c2fbColorIndicatorByte(int index, int offset) {\n"
        + "    if (index < 0 || index >= 24) return -1;\n"
        + "    if (offset < 0 || (size_t) offset >= color_indicator[index].len) return -2;\n"
        + "    return (unsigned char) color_indicator[index].string[offset];\n"
        + "}\n",
        encoding="utf-8",
    )
    candidate = source_directory / "probe_candidates.bas"
    translation = subprocess.run(
        [converter, "translate-simple-generic-c", str(source),
         str(candidate), cc[0], "--include-global-definitions"],
        cwd=source_directory, capture_output=True, text=True, check=False,
    )
    assert translation.returncode == 0, (
        translation.stdout + translation.stderr
    )
    assert "translated 1 simple functions; skipped 0" in translation.stdout, (
        translation.stdout, translation.stderr
    )
    generated = candidate.read_text(encoding="utf-8")
    assert "c2fb_internal_static_char_array_" in generated, generated

    reference_path = source_directory / "reference.so"
    reference_compile = subprocess.run(
        cc + ["-std=gnu11", "-shared", "-fPIC", str(source),
              "-o", str(reference_path)],
        cwd=source_directory, capture_output=True, text=True, check=False,
    )
    assert reference_compile.returncode == 0, (
        reference_compile.stdout + reference_compile.stderr
    )
    wrapper = source_directory / "check.bas"
    wrapper.write_text(
        '#include once "probe_candidates.bas"\n', encoding="utf-8"
    )
    converted_path = source_directory / "converted.so"
    converted_compile = subprocess.run(
        fbc + ["-dll", "-w", "all", "-i", str(port.FBC_INCLUDE_DIR),
               str(wrapper), "-x", str(converted_path)],
        cwd=source_directory, capture_output=True, text=True, check=False,
    )
    assert converted_compile.returncode == 0, (
        converted_compile.stdout + converted_compile.stderr
    )

    reference = ctypes.CDLL(str(reference_path))
    converted = ctypes.CDLL(str(converted_path))
    for library in (reference, converted):
        function = library.c2fbColorIndicatorByte
        function.argtypes = [ctypes.c_int, ctypes.c_int]
        function.restype = ctypes.c_int
    for index in range(-1, 25):
        for offset in range(-1, 7):
            expected = reference.c2fbColorIndicatorByte(index, offset)
            actual = converted.c2fbColorIndicatorByte(index, offset)
            assert actual == expected, (index, offset, expected, actual)


def check_coreutils_local_array_declaration_limit(converter, fbc, cc, work):
    # Keep the production timestamp enum and long local buffer bound intact.
    source_directory = work / "coreutils-local-array-declaration-limit"
    source_directory.mkdir()
    source = source_directory / "local_array_declaration_limit.c"
    source.write_text(
        f'#include "{port.REFERENCE / "lib/config.h"}"\n'
        "#include <stdint.h>\n"
        "#include <time.h>\n"
        '#include "human.h"\n'
        '#include "intprops.h"\n'
        '#include "minmax.h"\n'
        "enum { TIME_STAMP_LEN_MAXIMUM = MAX(1000, INT_STRLEN_BOUND(time_t)) };\n"
        "void c2fbPrintLongBufferProbe(void) {\n"
        "    char modebuf[12];\n"
        "    char buf[LONGEST_HUMAN_READABLE + 1 + LONGEST_HUMAN_READABLE + 1 + "
        "sizeof(modebuf) - 1 + 1 + INT_BUFSIZE_BOUND(uintmax_t) + "
        "LONGEST_HUMAN_READABLE + 2 + LONGEST_HUMAN_READABLE + 1 + "
        "TIME_STAMP_LEN_MAXIMUM + 1];\n"
        "    buf[0] = 1;\n"
        "}\n",
        encoding="utf-8",
    )
    compile_commands = json.loads(
        (port.PORT / "build/compile_commands.json").read_text(encoding="utf-8")
    )
    ls_source = (port.SOURCE / "src/ls.c").resolve()
    entries = [
        entry for entry in compile_commands
        if (Path(entry["directory"]) / entry["file"]).resolve() == ls_source
    ]
    assert len(entries) == 1, f"expected one ls compile command, got {len(entries)}"
    entry = dict(entries[0])
    entry["arguments"] = list(entry["arguments"])
    entry["arguments"][-1] = str(source)
    entry["file"] = str(source)
    entry["output"] = "local_array_declaration_limit.o"
    database = source_directory / "compile_commands.json"
    database.write_text(json.dumps([entry]), encoding="utf-8")
    output_directory = source_directory / "generated"

    spec = importlib.util.spec_from_file_location(
        "coreutils_local_array_declaration_limit_compile_commands",
        port.TOOLS / "c2fb_compile_commands.py",
    )
    driver = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = driver
    spec.loader.exec_module(driver)
    result = driver.run_compile_database(
        database,
        output_directory,
        converter,
        port.BODY_OPTIONS,
        source_unit_context=True,
        header_options=port.HEADER_OPTIONS,
        jobs=1,
        body_compiler_options=port.BODY_COMPILER_OPTIONS,
    )
    assert result == 0, "C2FB failed to translate the large local array fixture"
    candidates = list(output_directory.glob("*_candidates.bas"))
    assert len(candidates) == 1, f"expected one local array candidate, got {len(candidates)}"
    generated = candidates[0].read_text(encoding="utf-8")
    assert 'Sub c2fbPrintLongBufferProbe CDecl Alias "c2fbPrintLongBufferProbe"' in generated
    assert "c2fb skipped c2fbPrintLongBufferProbe" not in generated
    compile_result = subprocess.run(
        fbc + [
            "-c", "-w", "all", "-maxerr", "10",
            "-i", str(port.SOURCE.parent), str(candidates[0]),
            "-o", str(source_directory / "local_array_declaration_limit.o"),
        ],
        cwd=port.SOURCE, capture_output=True, text=True, check=False,
    )
    assert compile_result.returncode == 0, (
        compile_result.stdout + compile_result.stderr
    )


def check_coreutils_select_plural(converter, fbc, cc, work):
    # Keep the selected helper body exact while avoiding unrelated system.h code.
    header_source = (port.SOURCE / "src/system.h").read_text(encoding="utf-8")
    signature = "static inline unsigned long int\nselect_plural (uintmax_t n)"
    start = header_source.index(signature)
    closing = header_source.index("\n}\n", start)
    helper = header_source[start:closing + 2]

    source_directory = work / "coreutils-select-plural"
    source_directory.mkdir()
    header = source_directory / "probe.h"
    header.write_text(
        "#include <stdint.h>\n#include <limits.h>\n" + helper + "\n",
        encoding="utf-8",
    )
    source = source_directory / "probe.c"
    source.write_text(
        '#include "probe.h"\n'
        "unsigned long int c2fb_select_plural_probe(uintmax_t n) {\n"
        "    return select_plural(n);\n"
        "}\n",
        encoding="utf-8",
    )

    binding = source_directory / "probe.bi"
    header_result = subprocess.run(
        [converter, "generic-header", str(header), str(binding), cc[0],
         f"-I{source_directory}"],
        cwd=source_directory, capture_output=True, text=True, check=False,
    )
    assert header_result.returncode == 0, (
        header_result.stdout + header_result.stderr
    )

    assert "--include-header-inline-body=select_plural" in port.BODY_OPTIONS
    candidate = source_directory / "probe_candidates.bas"
    body_result = subprocess.run(
        [converter, "translate-simple-generic-c", str(source), str(candidate),
         cc[0], f"-I{source_directory}",
         f"--fb-source-directory={source_directory}",
         "--include-header-inline-body=select_plural"],
        cwd=source_directory, capture_output=True, text=True, check=False,
    )
    assert body_result.returncode == 0, body_result.stdout + body_result.stderr
    assert "translated 2 simple functions; skipped 0" in body_result.stdout, (
        body_result.stdout
    )
    assert "select_plural" in candidate.read_text(encoding="utf-8")

    values = (0, 999999, 1000000, 1234567)
    wrapper = source_directory / "check.bas"
    wrapper.write_text(
        '#include once "probe.bi"\n'
        '#include once "probe_candidates.bas"\n'
        + "".join(
            f"Print c2fb_select_plural_probe({value}ULL)\n"
            for value in values
        ),
        encoding="utf-8",
    )
    reference_source = source_directory / "reference.c"
    reference_source.write_text(
        '#include <stdio.h>\n#include "probe.h"\n'
        "int main(void) {\n"
        "    uintmax_t values[] = { 0, 999999, 1000000, 1234567 };\n"
        "    for (unsigned int i = 0; i < sizeof values / sizeof values[0]; i++)\n"
        '        printf("%lu\\n", select_plural(values[i]));\n'
        "    return 0;\n"
        "}\n",
        encoding="utf-8",
    )
    reference = source_directory / "reference"
    reference_compile = subprocess.run(
        cc + [str(reference_source), "-o", str(reference)],
        cwd=source_directory, capture_output=True, text=True, check=False,
    )
    assert reference_compile.returncode == 0, (
        reference_compile.stdout + reference_compile.stderr
    )
    expected = subprocess.run(
        [str(reference)], cwd=source_directory,
        capture_output=True, text=True, check=False,
    )
    assert expected.returncode == 0, expected.stdout + expected.stderr
    for backend, backend_flags in (
        ("native", []),
        ("gcc", ["-gen", "gcc"]),
    ):
        executable = source_directory / f"check-{backend}"
        compile_result = subprocess.run(
            fbc + backend_flags + ["-w", "all", str(wrapper),
                   "-x", str(executable)],
            cwd=source_directory, capture_output=True, text=True, check=False,
        )
        assert compile_result.returncode == 0, (
            backend, compile_result.stdout + compile_result.stderr
        )
        translated = subprocess.run(
            [str(executable)], cwd=source_directory,
            capture_output=True, text=True, check=False,
        )
        assert translated.returncode == 0, (
            backend, translated.stdout + translated.stderr
        )
        assert translated.stdout.splitlines() == expected.stdout.splitlines(), (
            backend, expected.stdout, translated.stdout
        )


def check_coreutils_basename_entrypoint(fbc, work):
    # Exercise the translated basename command line with the C support archive.
    candidates = port.conversion_units(contexts=True)
    main_matches = [
        port.PORT / "generated-context" / filename
        for filename, unit in candidates.items()
        if unit["source"].endswith("/src/basename.c")
    ]
    version_matches = [
        port.PORT / "generated-context" / filename
        for filename in candidates
        if (port.PORT / "generated-context" / filename).is_file()
        and "c2fb global definition Version=c2fb_global_Version"
        in (port.PORT / "generated-context" / filename).read_text(
            encoding="utf-8")
    ]
    assert len(main_matches) == 1, f"expected one basename candidate, got {main_matches}"
    assert len(version_matches) == 1, f"expected one Version candidate, got {version_matches}"
    main_candidate = main_matches[0]
    version_candidate = version_matches[0]

    source_directory = work / "coreutils-basename-entrypoint"
    source_directory.mkdir()
    local_main = source_directory / main_candidate.name
    candidate_text = main_candidate.read_text(encoding="utf-8")
    function_declaration = 'Function main CDecl Alias "main"'
    assert candidate_text.count(function_declaration) == 2
    local_main.write_text(
        candidate_text.replace(
            function_declaration,
            'Function c2fb_basename_main CDecl Alias "c2fb_basename_main"',
        ),
        encoding="utf-8",
    )
    type_context = main_candidate.with_name(main_candidate.stem + "_types.bi")
    shutil.copy2(type_context, source_directory / type_context.name)

    freebasic_source = source_directory / "driver.bas"
    freebasic_source.write_text(
        f'#include once "{local_main.as_posix()}"\n'
        'Dim programName As ZString * 16 = "basename"\n'
        "Dim argumentText(1 To 4) As String\n"
        "Dim argv(0 To 4) As ZString Ptr\n"
        "Dim argumentCount As c2fb_c_int = 1\n"
        "argv(0) = @programName\n"
        "For index As Long = 1 To 4\n"
        "    argumentText(index) = Command(index)\n"
        "    If Len(argumentText(index)) = 0 Then Exit For\n"
        "    argv(index) = StrPtr(argumentText(index))\n"
        "    argumentCount += 1\n"
        "Next\n"
        "Dim result As c2fb_c_int = c2fb_basename_main(argumentCount, @argv(0))\n"
        "End result\n",
        encoding="utf-8",
    )

    reference_library = port.REFERENCE / "lib/libcoreutils.a"
    assert reference_library.is_file(), f"Coreutils reference library is missing: {reference_library}"
    reference = port.REFERENCE / "src/basename"
    assert reference.is_file(), f"Coreutils basename reference is missing: {reference}"
    converted = source_directory / "basename"
    compile_result = subprocess.run(
        fbc + [
            "-w", "all", "-i", str(port.SOURCE), "-i", str(source_directory),
            str(freebasic_source), str(version_candidate), str(reference_library),
            "-x", str(converted),
        ],
        cwd=port.SOURCE, capture_output=True, text=True, check=False,
    )
    assert compile_result.returncode == 0, (
        compile_result.stdout + compile_result.stderr
    )

    environment = os.environ.copy()
    environment["TERM"] = "dumb"
    environment["LC_ALL"] = "C"
    environment["LANG"] = "C"
    arguments_to_test = (
        (), ("dir/name.txt",), ("dir/name.txt", ".txt"),
        ("-s", ".txt", "dir/name.txt"), ("-a", "dir/a", "dir/b"),
        ("-z", "dir/name"), ("--help",), ("--version",),
    )
    for arguments in arguments_to_test:
        actual = subprocess.run(
            [str(converted), *arguments], cwd=source_directory,
            env=environment, capture_output=True, check=False,
        )
        expected = subprocess.run(
            ["basename", *arguments], executable=str(reference),
            cwd=source_directory, env=environment,
            capture_output=True, check=False,
        )
        assert actual.returncode == expected.returncode, (
            arguments, expected.returncode, actual.returncode
        )
        assert actual.stdout == expected.stdout, (
            arguments, expected.stdout, actual.stdout
        )
        assert actual.stderr == expected.stderr, (
            arguments, expected.stderr, actual.stderr
        )


def check_coreutils_true_false(fbc, work):
    # Exercise translated entrypoints while retaining the existing C support archive.
    candidates = []
    for filename, unit in port.conversion_units(contexts=True).items():
        candidate = port.PORT / "generated-context" / filename
        candidates.append((unit["source"], candidate))

    def source_candidate(suffix):
        matches = [candidate for source, candidate in candidates
                   if source.endswith(suffix)]
        assert len(matches) == 1, f"expected one {suffix} candidate, got {matches}"
        return matches[0]

    main_candidate = source_candidate("/src/true.c")
    true_mode_candidate = source_candidate("/src/true-true.c")
    false_mode_candidate = source_candidate("/src/true-false.c")
    version_candidates = [
        candidate for _, candidate in candidates
        if candidate.is_file()
        and "c2fb global definition Version=c2fb_global_Version"
        in candidate.read_text(encoding="utf-8")
    ]
    assert len(version_candidates) == 1, (
        f"expected one Version candidate, got {version_candidates}"
    )
    version_candidate = version_candidates[0]
    reference_library = port.REFERENCE / "lib/libcoreutils.a"
    assert reference_library.is_file(), f"Coreutils reference library is missing: {reference_library}"

    for program_name, mode_candidate in (
        ("true", true_mode_candidate),
        ("false", false_mode_candidate),
    ):
        source_directory = work / f"coreutils-{program_name}"
        source_directory.mkdir()
        local_main = source_directory / main_candidate.name
        candidate_text = main_candidate.read_text(encoding="utf-8")
        function_declaration = 'Function main CDecl Alias "main"'
        assert candidate_text.count(function_declaration) == 2
        local_main.write_text(
            candidate_text.replace(
                function_declaration,
                'Function c2fb_main CDecl Alias "c2fb_main"',
            ),
            encoding="utf-8",
        )
        type_context = main_candidate.with_name(main_candidate.stem + "_types.bi")
        shutil.copy2(
            type_context,
            source_directory / type_context.name,
        )

        freebasic_source = source_directory / "driver.bas"
        freebasic_source.write_text(
            f'#include once "{local_main.as_posix()}"\n'
            f'Dim programName As ZString * 7 = "{program_name}"\n'
            "Dim firstArgument As String = Command(1)\n"
            "Dim secondArgument As String = Command(2)\n"
            "Dim argv(0 To 2) As ZString Ptr\n"
            "argv(0) = @programName\n"
            "Dim argumentCount As c2fb_c_int = 1\n"
            "If Len(firstArgument) > 0 Then\n"
            "    argv(1) = StrPtr(firstArgument)\n"
            "    argumentCount = 2\n"
            "End If\n"
            "If Len(secondArgument) > 0 Then\n"
            "    argv(2) = StrPtr(secondArgument)\n"
            "    argumentCount = 3\n"
            "End If\n"
            "Dim result As c2fb_c_int = c2fb_main(argumentCount, @argv(0))\n"
            "End result\n",
            encoding="utf-8",
        )
        converted = source_directory / program_name
        compile_result = subprocess.run(
            fbc + [
                "-w", "all", "-i", str(port.SOURCE), "-i",
                str(source_directory), str(freebasic_source),
                str(mode_candidate), str(version_candidate),
                str(reference_library), "-x", str(converted),
            ],
            cwd=port.SOURCE, capture_output=True, text=True, check=False,
        )
        assert compile_result.returncode == 0, (
            compile_result.stdout + compile_result.stderr
        )

        environment = os.environ.copy()
        environment["TERM"] = "dumb"
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        reference = port.REFERENCE / "src" / program_name
        for arguments in ((), ("ignored",), ("--help",), ("--version",)):
            actual = subprocess.run(
                [str(converted), *arguments], cwd=source_directory,
                env=environment, capture_output=True, text=True, check=False,
            )
            expected = subprocess.run(
                [program_name, *arguments], executable=str(reference),
                cwd=source_directory, env=environment,
                capture_output=True, text=True, check=False,
            )
            assert actual.returncode == expected.returncode, (
                program_name, arguments, expected.returncode, actual.returncode
            )
            assert actual.stdout == expected.stdout, (
                program_name, arguments, expected.stdout, actual.stdout
            )
            assert actual.stderr == expected.stderr, (
                program_name, arguments, expected.stderr, actual.stderr
            )


def check_coreutils_mcel(converter, fbc, cc, work):
    # Verify the selected inline multibyte helper chain against C in both locales.
    source_path = (port.SOURCE / "lib/mbslen.c").resolve()
    compile_commands = json.loads(
        (port.PORT / "build/compile_commands.json").read_text(encoding="utf-8")
    )
    entries = [
        entry for entry in compile_commands
        if (Path(entry["directory"]) / entry["file"]).resolve() == source_path
    ]
    assert len(entries) == 1, f"expected one mbslen compile command, got {len(entries)}"

    source_directory = work / "coreutils-mcel"
    source_directory.mkdir()
    database = source_directory / "compile_commands.json"
    database.write_text(json.dumps(entries), encoding="utf-8")
    output_directory = source_directory / "generated"
    spec = importlib.util.spec_from_file_location(
        "coreutils_mcel_compile_commands",
        port.TOOLS / "c2fb_compile_commands.py",
    )
    driver = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = driver
    spec.loader.exec_module(driver)
    result = driver.run_compile_database(
        database,
        output_directory,
        converter,
        port.BODY_OPTIONS,
        source_unit_context=True,
        header_options=port.HEADER_OPTIONS,
        jobs=1,
        body_compiler_options=port.BODY_COMPILER_OPTIONS,
    )
    assert result == 0, "C2FB failed to translate the mbslen source unit"
    candidates = list(output_directory.glob("*_candidates.bas"))
    assert len(candidates) == 1, f"expected one mbslen candidate, got {candidates}"
    candidate = candidates[0]
    generated = candidate.read_text(encoding="utf-8")
    for function_name in (
        "mcel_ch", "mcel_err", "mcel_isbasic", "mcel_scan",
        "mcel_scant", "mcel_scanz", "mbslen",
    ):
        assert f"Function {function_name} " in generated, function_name
    assert "c2fb skipped mbslen:" not in generated, generated
    assert "c2fb skipped mcel_scanz:" not in generated, generated

    reference_source = source_directory / "reference.c"
    reference_source.write_text(
        "#include <config.h>\n"
        "#include <locale.h>\n"
        "#include <stdio.h>\n"
        "#include <stddef.h>\n"
        "size_t mbslen(const char *text);\n"
        "int main(int argc, char **argv) {\n"
        "    unsigned char text[256] = {0};\n"
        "    size_t index = 0;\n"
        "    if (argc != 3 || !setlocale(LC_ALL, argv[1])) return 2;\n"
        "    for (size_t position = 0; argv[2][position]; position += 2) {\n"
        "        unsigned int byte;\n"
        "        if (!argv[2][position + 1] || "
        "sscanf(argv[2] + position, \"%2x\", &byte) != 1 || "
        "index >= sizeof text - 1) return 3;\n"
        "        text[index++] = (unsigned char) byte;\n"
        "    }\n"
        '    printf("%zu\\n", mbslen((const char *) text));\n'
        "    return 0;\n"
        "}\n",
        encoding="utf-8",
    )
    compiler_arguments = entries[0].get("arguments")
    assert compiler_arguments, "mbslen compile command has no argument vector"
    compile_flags = []
    argument_index = 1
    while argument_index < len(compiler_arguments):
        argument = compiler_arguments[argument_index]
        if argument in {"-I", "-D", "-U"}:
            assert argument_index + 1 < len(compiler_arguments)
            compile_flags.extend(compiler_arguments[argument_index:argument_index + 2])
            argument_index += 2
            continue
        if argument.startswith(("-I", "-D", "-U", "-std=")):
            compile_flags.append(argument)
        argument_index += 1
    reference_library = port.REFERENCE / "lib/libcoreutils.a"
    assert reference_library.is_file(), f"Coreutils reference library is missing: {reference_library}"
    reference = source_directory / "reference"
    reference_result = subprocess.run(
        cc + compile_flags + [
            str(reference_source), str(reference_library), "-o", str(reference),
        ],
        cwd=entries[0]["directory"], capture_output=True, text=True, check=False,
    )
    assert reference_result.returncode == 0, (
        reference_result.stdout + reference_result.stderr
    )

    freebasic_source = source_directory / "driver.bas"
    freebasic_source.write_text(
        '#include once "crt/locale.bi"\n'
        f'#include once "{candidate.as_posix()}"\n'
        "Dim localeName As String = Command(1)\n"
        "Dim hexText As String = Command(2)\n"
        "If setlocale(LC_ALL, StrPtr(localeName)) = 0 Then End 2\n"
        "If Len(hexText) Mod 2 <> 0 Then End 3\n"
        "Dim textBytes(0 To 255) As UByte\n"
        "Dim byteIndex As Long = 0\n"
        "For position As Long = 1 To Len(hexText) Step 2\n"
        "    If byteIndex >= 255 Then End 4\n"
        # Hex text keeps arbitrary input bytes intact in subprocess arguments.
        # The bound leaves room for the terminating NUL byte.
        # Val accepts the explicit hexadecimal prefix for this test harness.
        "    textBytes(byteIndex) = CUByte(Val(\"&H\" & Mid(hexText, position, 2)))\n"
        "    byteIndex += 1\n"
        "Next\n"
        "Print mbslen(CPtr(Const ZString Ptr, @textBytes(0)))\n",
        encoding="utf-8",
    )
    converted = source_directory / "converted"
    converted_result = subprocess.run(
        fbc + [
            "-w", "all", "-i", str(port.SOURCE), "-i",
            str(candidate.parent), str(freebasic_source),
            str(reference_library), "-x", str(converted),
        ],
        cwd=port.SOURCE, capture_output=True, text=True, check=False,
    )
    assert converted_result.returncode == 0, (
        converted_result.stdout + converted_result.stderr
    )

    cases = {
        "empty": "",
        "ascii": "616263",
        "utf8-two": "41c3a9",
        "utf8-four": "f09f8c8d",
        "bad-continuation": "e228a1",
        "embedded-nul": "610062",
    }
    for locale_name in ("C", "C.utf8"):
        environment = os.environ.copy()
        environment["LC_ALL"] = locale_name
        environment["LANG"] = locale_name
        for label, hex_text in cases.items():
            arguments = [locale_name, hex_text]
            expected = subprocess.run(
                [str(reference), *arguments], cwd=source_directory,
                env=environment, capture_output=True, text=True, check=False,
            )
            actual = subprocess.run(
                [str(converted), *arguments], cwd=source_directory,
                env=environment, capture_output=True, text=True, check=False,
            )
            assert expected.returncode == 0, expected.stderr
            assert actual.returncode == 0, actual.stderr
            assert actual.stdout == expected.stdout, (
                locale_name, label, expected.stdout, actual.stdout
            )
            assert actual.stderr == expected.stderr, (
                locale_name, label, expected.stderr, actual.stderr
            )


def check_glibc_max_align_layout(converter, fbc, cc, work):
    # scratch_buffer must keep glibc's 16-byte max_align_t alignment.
    source_directory = work / "glibc-max-align-layout"
    source_directory.mkdir()
    header = source_directory / "probe.h"
    header.write_text(
        "#include <stddef.h>\n"
        "typedef struct scratch_buffer {\n"
        "    void *data;\n"
        "    size_t length;\n"
        "    union { max_align_t align; char bytes[1024]; } space;\n"
        "} scratch_buffer;\n"
        "struct Holder { char prefix; scratch_buffer value; char suffix; };\n"
    )
    binding = source_directory / "probe.bi"
    result = subprocess.run(
        [
            converter, "generic-header", str(header), str(binding), *cc,
            "-std=gnu11", "--emit-source=*",
            "--fb-include=fb_port/coreutils_glibc_abi.bi",
            "--type-map=max_align_t=CoreutilsGlibcMaxAlign",
            "--type-alignment=max_align_t=16",
        ],
        cwd=source_directory, capture_output=True, text=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    generated = binding.read_text()
    assert "CoreutilsGlibcMaxAlign" in generated, generated
    assert "Type c2fb_scratch_buffer" in generated, generated
    assert "Type c2fb_Holder" in generated, generated

    c_source = source_directory / "layout.c"
    c_source.write_text(
        "#include <stddef.h>\n"
        "#include <stdio.h>\n"
        '#include "probe.h"\n'
        "int main(void) {\n"
        '    printf("%zu %zu %zu %zu %zu %zu %zu\\n", '
        "sizeof(max_align_t), _Alignof(max_align_t), "
        "sizeof(scratch_buffer), offsetof(scratch_buffer, space), "
        "sizeof(struct Holder), offsetof(struct Holder, value), "
        "offsetof(struct Holder, suffix));\n"
        "    return 0;\n"
        "}\n"
    )
    c_executable = source_directory / "layout-c"
    c_result = subprocess.run(
        cc + ["-std=gnu11", str(c_source), "-o", str(c_executable)],
        cwd=source_directory, capture_output=True, text=True, check=False,
    )
    assert c_result.returncode == 0, c_result.stdout + c_result.stderr
    c_layout = subprocess.run(
        [str(c_executable)], cwd=source_directory,
        capture_output=True, text=True, check=False,
    )
    assert c_layout.returncode == 0, c_layout.stdout + c_layout.stderr

    fb_source = source_directory / "layout.bas"
    fb_source.write_text(
        '#include once "probe.bi"\n'
        "Type AlignmentHolder\n"
        "    prefix As Byte\n"
        "    value As CoreutilsGlibcMaxAlign\n"
        "End Type\n"
        "Dim scratch As c2fb_scratch_buffer\n"
        "Dim holder As c2fb_Holder\n"
        "Dim alignmentHolder As AlignmentHolder\n"
        'Print SizeOf(CoreutilsGlibcMaxAlign); " "; '
        'CULngInt(@alignmentHolder.value)-CULngInt(@alignmentHolder); " "; '
        'SizeOf(c2fb_scratch_buffer); " "; '
        'CULngInt(@scratch.space)-CULngInt(@scratch); " "; '
        'SizeOf(c2fb_Holder); " "; '
        'CULngInt(@holder.value)-CULngInt(@holder); " "; '
        'CULngInt(@holder.suffix)-CULngInt(@holder)\n'
    )
    expected = tuple(int(value) for value in c_layout.stdout.split())
    for backend, flags in (("native", []), ("gcc", ["-gen", "gcc"])):
        executable = source_directory / f"layout-{backend}"
        compile_result = subprocess.run(
            fbc + flags + [
                "-w", "all", "-i", str(port.SOURCE), "-i",
                str(source_directory), str(fb_source), "-x", str(executable),
            ],
            cwd=source_directory, capture_output=True, text=True, check=False,
        )
        assert compile_result.returncode == 0, (
            compile_result.stdout + compile_result.stderr
        )
        fb_layout = subprocess.run(
            [str(executable)], cwd=source_directory,
            capture_output=True, text=True, check=False,
        )
        assert fb_layout.returncode == 0, fb_layout.stdout + fb_layout.stderr
        actual = tuple(int(value) for value in fb_layout.stdout.split())
        assert actual == expected, (backend, expected, actual)


def check_coreutils_xstrtol_runtime(fbc, cc, work):
    # Both parser variants must keep suffix, overflow, and end-pointer behavior.
    units = port.conversion_units(contexts=True)
    cases = (
        ("12k", "kM"),
        ("5M", "kM"),
        ("  -3k", "kM"),
        ("k", "kM"),
        ("12x", "kM"),
        ("12", "kM"),
        ("9223372036854775807k", "kM"),
    )
    base_directory = work / "coreutils-xstrtol-runtime"
    base_directory.mkdir()
    for source_name, function_name, value_type in (
        ("xstrtol.c", "xstrtol", "long"),
        ("xstrtoimax.c", "xstrtoimax", "intmax_t"),
    ):
        candidate_name = next(
            name for name, unit in units.items()
            if unit["source"].endswith("/lib/" + source_name)
        )
        candidate = port.PORT / "generated-context" / candidate_name
        reference_object = (
            port.REFERENCE / "lib" /
            ("libcoreutils_a-" + source_name.removesuffix(".c") + ".o")
        )
        assert candidate.is_file(), f"translated candidate is missing: {candidate}"
        assert reference_object.is_file(), (
            f"C reference object is missing: {reference_object}"
        )

        source_directory = base_directory / function_name
        source_directory.mkdir()
        reference_source = source_directory / "reference.c"
        reference_lines = [
            "#include <inttypes.h>",
            "#include <stddef.h>",
            "#include <stdio.h>",
            '#include "xstrtol.h"',
            "static void run_case(const char *input, const char *suffixes)",
            "{",
            "    char *end = 0;",
            f"    {value_type} value = 0;",
            f"    enum strtol_error status = {function_name}(input, &end, 10, &value, suffixes);",
            '    printf("%d %jd %td\\n", status, (intmax_t) value, end - input);',
            "}",
            "int main(void)",
            "{",
        ]
        reference_lines.extend(
            f'    run_case("{input_text}", "{suffixes}");'
            for input_text, suffixes in cases
        )
        reference_lines.extend(("    return 0;", "}"))
        reference_source.write_text("\n".join(reference_lines) + "\n")
        reference = source_directory / "reference"
        reference_result = subprocess.run(
            cc + ["-std=c11", "-O2", "-I", str(port.SOURCE / "lib"),
                  str(reference_source), str(reference_object), "-o", str(reference)],
            cwd=source_directory, capture_output=True, text=True, check=False,
        )
        assert reference_result.returncode == 0, (
            reference_result.stdout + reference_result.stderr
        )

        freebasic_lines = [
            f'#include once "{candidate.as_posix()}"',
            "Sub run_case(ByVal inputText As Const ZString Ptr, ByVal suffixText As Const ZString Ptr)",
            "    Dim endText As ZString Ptr",
            "    Dim value As c2fb_c_long = 0",
            f"    Dim status As c2fb_strtol_error = {function_name}(inputText, @endText, 10, @value, suffixText)",
            "    Dim offset As LongInt = Cast(LongInt, Cast(ULongInt, endText) - Cast(ULongInt, inputText))",
            '    Print CInt(status); " "; value; " "; offset',
            "End Sub",
        ]
        freebasic_lines.extend(
            f'Dim input{index} As ZString * 64 = "{input_text}"'
            for index, (input_text, _) in enumerate(cases)
        )
        freebasic_lines.append('Dim suffixes As ZString * 8 = "kM"')
        freebasic_lines.extend(
            f"run_case(@input{index}, @suffixes)"
            for index in range(len(cases))
        )
        freebasic_source = source_directory / "translated.bas"
        freebasic_source.write_text("\n".join(freebasic_lines) + "\n")
        converted = source_directory / "translated"
        converted_result = subprocess.run(
            fbc + ["-w", "all", "-i", str(port.SOURCE), "-i",
                   str(candidate.parent), "-i", str(port.PORT),
                   str(freebasic_source), "-x", str(converted)],
            cwd=source_directory, capture_output=True, text=True, check=False,
        )
        assert converted_result.returncode == 0, (
            converted_result.stdout + converted_result.stderr
        )
        expected = subprocess.run(
            [str(reference)], cwd=source_directory,
            capture_output=True, text=True, check=False,
        )
        actual = subprocess.run(
            [str(converted)], cwd=source_directory,
            capture_output=True, text=True, check=False,
        )
        assert expected.returncode == actual.returncode == 0, (
            expected.stderr, actual.stderr
        )
        assert actual.stdout.split() == expected.stdout.split(), (
            function_name, expected.stdout, actual.stdout
        )


def check_coreutils_xstrtol_upstream(fbc, cc, work):
    # Keep the gnulib test scripts unchanged while replacing one C entrypoint.
    units = port.conversion_units(contexts=True)
    reference_tests = port.REFERENCE / "gnulib-tests"
    coreutils_library = port.REFERENCE / "lib/libcoreutils.a"
    tests_library = reference_tests / "libtests.a"
    source_tests = port.SOURCE / "gnulib-tests"
    base_directory = work / "coreutils-xstrtol-upstream"
    base_directory.mkdir()

    for source_name, test_name in (
        ("xstrtol.c", "test-xstrtol"),
        ("xstrtoimax.c", "test-xstrtoimax"),
    ):
        candidate_name = next(
            name for name, unit in units.items()
            if unit["source"].endswith("/lib/" + source_name)
        )
        candidate = port.PORT / "generated-context" / candidate_name
        assert candidate.is_file(), f"translated candidate is missing: {candidate}"
        error_name = next(
            name for name, unit in units.items()
            if unit["source"].endswith("/lib/xstrtol-error.c")
        )
        error_candidate = port.PORT / "generated-context" / error_name
        assert error_candidate.is_file(), (
            f"translated candidate is missing: {error_candidate}"
        )
        candidate_sources = [candidate, error_candidate]

        test_directory = base_directory / test_name
        test_directory.mkdir()
        shared_name = "lib" + test_name + "-freebasic.so"
        shared_library = test_directory / shared_name
        compile_result = subprocess.run(
            fbc + ["-w", "all", "-dll", "-i", str(port.SOURCE), "-i",
                   str(candidate.parent), "-i", str(port.PORT),
                   *(str(source) for source in candidate_sources),
                   "-x", str(shared_library)],
            cwd=test_directory, capture_output=True, text=True, check=False,
        )
        assert compile_result.returncode == 0, (
            compile_result.stdout + compile_result.stderr
        )

        test_object = reference_tests / (test_name + ".o")
        test_executable = test_directory / test_name
        link_result = subprocess.run(
            cc + [str(test_object), "-L" + str(test_directory),
                  "-Wl,-rpath," + str(test_directory), "-l" + test_name + "-freebasic",
                  str(tests_library), str(coreutils_library),
                  str(tests_library), str(coreutils_library), "-o", str(test_executable)],
            cwd=test_directory, capture_output=True, text=True, check=False,
        )
        assert link_result.returncode == 0, (
            link_result.stdout + link_result.stderr
        )

        reference_helpers = ("test-xstrtoul",) if test_name == "test-xstrtol" else ()
        for other_test in reference_helpers:
            reference_executable = reference_tests / other_test
            assert reference_executable.is_file(), (
                f"C reference test executable is missing: {reference_executable}"
            )
            (test_directory / other_test).symlink_to(reference_executable)

        environment = os.environ.copy()
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["srcdir"] = str(source_tests)
        environment["PATH"] = (
            str(test_directory) + os.pathsep + environment.get("PATH", "")
        )
        script = source_tests / (test_name + ".sh")
        result = subprocess.run(
            ["sh", str(script)], cwd=test_directory,
            env=environment, capture_output=True, text=True, check=False,
        )
        assert result.returncode == 0, (
            test_name, result.stdout, result.stderr,
            (test_directory / "out").read_text(encoding="utf-8", errors="replace")
            if (test_directory / "out").exists() else "",
        )


def check_coreutils_cp_context(converter, fbc, cc, work):
    # Preserve the newly supported tagged local enum path in cp.c.
    source_path = (port.SOURCE / "src/cp.c").resolve()
    compile_commands = json.loads(
        (port.PORT / "build/compile_commands.json").read_text(encoding="utf-8")
    )
    entries = [
        entry for entry in compile_commands
        if (Path(entry["directory"]) / entry["file"]).resolve() == source_path
    ]
    assert len(entries) == 1, f"expected one cp compile command, got {len(entries)}"

    source_directory = work / "coreutils-cp-context"
    source_directory.mkdir()
    database = source_directory / "compile_commands.json"
    database.write_text(json.dumps(entries), encoding="utf-8")
    output_directory = source_directory / "generated"
    spec = importlib.util.spec_from_file_location(
        "coreutils_cp_compile_commands", port.TOOLS / "c2fb_compile_commands.py"
    )
    driver = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = driver
    spec.loader.exec_module(driver)
    result = driver.run_compile_database(
        database,
        output_directory,
        converter,
        port.BODY_OPTIONS,
        source_unit_context=True,
        header_options=port.HEADER_OPTIONS,
        jobs=1,
        body_compiler_options=port.BODY_COMPILER_OPTIONS,
    )
    assert result == 0, "C2FB failed to translate the cp source unit"
    candidates = list(output_directory.glob("*_candidates.bas"))
    assert len(candidates) == 1, f"expected one cp candidate, got {len(candidates)}"
    candidate = candidates[0]
    candidate_text = candidate.read_text(encoding="utf-8")
    assert re.search(r"^(?:Private\s+)?(?:Function|Sub) decode_preserve_arg\b",
                     candidate_text, re.M), candidate_text
    object_path = source_directory / "cp_candidates.o"
    compile_result = subprocess.run(
        fbc + ["-w", "all", "-c", "-i", str(port.SOURCE), "-i",
               str(output_directory), "-i", str(port.PORT),
               "-o", str(object_path), str(candidate)],
        cwd=source_directory, capture_output=True, text=True, check=False,
    )
    assert compile_result.returncode == 0, (
        compile_result.stdout + compile_result.stderr
    )


def check_coreutils_seq_context(converter, fbc, cc, work):
    # The CLongDouble ABI must cover seq's variadic formatting path as well as
    # its argument parser and generated default format.
    source_path = (port.SOURCE / "src/seq.c").resolve()
    compile_commands = json.loads(
        (port.PORT / "build/compile_commands.json").read_text(encoding="utf-8")
    )
    entries = [
        entry for entry in compile_commands
        if (Path(entry["directory"]) / entry["file"]).resolve() == source_path
    ]
    assert len(entries) == 1, f"expected one seq compile command, got {len(entries)}"

    source_directory = work / "coreutils-seq-context"
    source_directory.mkdir()
    database = source_directory / "compile_commands.json"
    database.write_text(json.dumps(entries), encoding="utf-8")
    output_directory = source_directory / "generated"
    spec = importlib.util.spec_from_file_location(
        "coreutils_seq_compile_commands", port.TOOLS / "c2fb_compile_commands.py"
    )
    driver = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = driver
    spec.loader.exec_module(driver)
    result = driver.run_compile_database(
        database,
        output_directory,
        converter,
        port.BODY_OPTIONS,
        source_unit_context=True,
        header_options=port.HEADER_OPTIONS,
        jobs=1,
        body_compiler_options=port.BODY_COMPILER_OPTIONS,
    )
    assert result == 0, "C2FB failed to translate the seq source unit"
    candidates = list(output_directory.glob("*_candidates.bas"))
    assert len(candidates) == 1, f"expected one seq candidate, got {len(candidates)}"
    candidate = candidates[0]
    candidate_text = candidate.read_text(encoding="utf-8")
    for function_name in (
        "scan_arg", "long_double_format", "print_numbers",
        "get_default_format", "main",
    ):
        assert re.search(
            rf"^(?:Private\s+)?(?:Function|Sub) {function_name}\b",
            candidate_text, re.M,
        ), f"{function_name} was not translated from seq.c"
    assert "unsupported-longdouble-variadic-argument" not in candidate_text, candidate_text

    object_path = source_directory / "seq_candidates.o"
    compile_command = fbc + [
        "-w", "all", "-c", "-i", str(port.SOURCE), "-i",
        str(output_directory), "-i", str(port.PORT),
        "-o", str(object_path), str(candidate),
    ]
    compile_result = subprocess.run(
        compile_command, cwd=source_directory, capture_output=True, text=True,
        check=False,
    )
    assert compile_result.returncode == 0, (
        compile_result.stdout + compile_result.stderr
    )


def check_coreutils_sort_context(converter, fbc, cc, work):
    # The header and local array declarations must share one FreeBASIC md5_ctx type.
    source_path = (port.SOURCE / "src/sort.c").resolve()
    compile_commands = json.loads(
        (port.PORT / "build/compile_commands.json").read_text(encoding="utf-8")
    )
    entries = [
        entry for entry in compile_commands
        if (Path(entry["directory"]) / entry["file"]).resolve() == source_path
    ]
    assert len(entries) == 1, f"expected one sort compile command, got {len(entries)}"

    source_directory = work / "coreutils-sort-context"
    source_directory.mkdir()
    database = source_directory / "compile_commands.json"
    database.write_text(json.dumps(entries), encoding="utf-8")
    output_directory = source_directory / "generated"
    spec = importlib.util.spec_from_file_location(
        "coreutils_sort_compile_commands", port.TOOLS / "c2fb_compile_commands.py"
    )
    driver = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = driver
    spec.loader.exec_module(driver)
    result = driver.run_compile_database(
        database,
        output_directory,
        converter,
        port.BODY_OPTIONS,
        source_unit_context=True,
        header_options=port.HEADER_OPTIONS,
        jobs=1,
        body_compiler_options=port.BODY_COMPILER_OPTIONS,
    )
    assert result == 0, "C2FB failed to translate the sort source unit"
    candidates = list(output_directory.glob("*_candidates.bas"))
    assert len(candidates) == 1, f"expected one sort candidate, got {len(candidates)}"
    candidate = candidates[0]
    candidate_text = candidate.read_text(encoding="utf-8")
    assert "c2fb_md5_ctx_" in candidate_text, candidate_text

    object_path = source_directory / "sort_candidates.o"
    compile_result = subprocess.run(
        fbc + ["-w", "all", "-c", "-i", str(port.SOURCE), "-i",
               str(output_directory), "-i", str(port.PORT),
               "-o", str(object_path), str(candidate)],
        cwd=source_directory, capture_output=True, text=True, check=False,
    )
    assert compile_result.returncode == 0, (
        compile_result.stdout + compile_result.stderr
    )


def check_coreutils_dtimespec_bound(converter, fbc, work):
    # The gnulib contract permits any small positive bound after underflow.
    source_path = (port.SOURCE / "src/sleep.c").resolve()
    compile_commands = json.loads(
        (port.PORT / "build/compile_commands.json").read_text(encoding="utf-8")
    )
    entries = [
        entry for entry in compile_commands
        if (Path(entry["directory"]) / entry["file"]).resolve() == source_path
    ]
    assert len(entries) == 1, f"expected one sleep compile command, got {len(entries)}"

    source_directory = work / "coreutils-dtimespec-bound"
    source_directory.mkdir()
    database = source_directory / "compile_commands.json"
    database.write_text(json.dumps(entries), encoding="utf-8")
    output_directory = source_directory / "generated"
    spec = importlib.util.spec_from_file_location(
        "coreutils_dtimespec_compile_commands",
        port.TOOLS / "c2fb_compile_commands.py",
    )
    driver = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = driver
    spec.loader.exec_module(driver)
    result = driver.run_compile_database(
        database,
        output_directory,
        converter,
        port.BODY_OPTIONS,
        source_unit_context=True,
        header_options=port.HEADER_OPTIONS,
        jobs=1,
        body_compiler_options=port.BODY_COMPILER_OPTIONS,
    )
    assert result == 0, "C2FB failed to translate the sleep source unit"
    candidates = list(output_directory.glob("*_candidates.bas"))
    assert len(candidates) == 1, f"expected one sleep candidate, got {len(candidates)}"
    candidate = candidates[0]
    generated = candidate.read_text(encoding="utf-8")
    for function_name in ("dtimespec_bound", "apply_suffix", "main"):
        assert re.search(
            rf"^(?:Private\s+)?Function {function_name}\b", generated, re.M
        ), f"{function_name} was not translated from sleep.c"
    skips = re.findall(r"^' c2fb skipped ([^:]+): (.*)$", generated, re.M)
    assert not skips, f"sleep source unit still has skipped functions: {skips}"

    object_path = source_directory / "sleep_candidates.o"
    compile_result = subprocess.run(
        fbc + ["-w", "all", "-c", "-i", str(port.SOURCE), "-i",
               str(output_directory), "-i", str(port.PORT),
               "-o", str(object_path), str(candidate)],
        cwd=source_directory, capture_output=True, text=True, check=False,
    )
    assert compile_result.returncode == 0, (
        compile_result.stdout + compile_result.stderr
    )

    function_match = re.search(
        r"^Function dtimespec_bound\b.*?^End Function", generated, re.M | re.S
    )
    assert function_match, "generated dtimespec_bound body was not found"
    runtime_source = source_directory / "dtimespec-runtime.bas"
    runtime_source.write_text(
        "Type c2fb_c_int As Long\n"
        '#include once "coreutils_dtimespec_support.bi"\n'
        + function_match.group(0)
        + "\n"
        + "Dim positive As Double = dtimespec_bound(0.0, ERANGE)\n"
        + "Dim negativeZero As Double = -0.0\n"
        + "Dim negative As Double = dtimespec_bound(negativeZero, ERANGE)\n"
        + "If positive <= 0 OrElse positive >= 1.0e-9 Then End 1\n"
        + "If negative >= 0 OrElse negative <= -1.0e-9 Then End 2\n"
        + "If CoreutilsDtimespecSignBit(positive) <> 0 Then End 3\n"
        + "If CoreutilsDtimespecSignBit(negative) = 0 Then End 4\n"
        + "If dtimespec_bound(1.0, 0) <= 1.0 Then End 5\n"
        + "If dtimespec_bound(-1.0, 0) >= -1.0 Then End 6\n",
        encoding="utf-8",
    )
    executable = source_directory / "dtimespec-runtime"
    runtime_compile = subprocess.run(
        fbc + ["-w", "all", "-i", str(port.PORT),
               str(runtime_source), "-x", str(executable)],
        cwd=source_directory, capture_output=True, text=True, check=False,
    )
    assert runtime_compile.returncode == 0, (
        runtime_compile.stdout + runtime_compile.stderr
    )
    runtime_result = subprocess.run(
        [str(executable)], cwd=source_directory, check=False
    )
    assert runtime_result.returncode == 0, (
        f"dtimespec runtime probe failed with status {runtime_result.returncode}"
    )


def check_lp64_size_t_vararg(converter, fbc, cc, work):
    # On the captured Linux x86-64 ABI, size_t is unsigned long in varargs.
    source_directory = work / "lp64-size-t-vararg"
    source_directory.mkdir()
    source = source_directory / "size_t_vararg.c"
    source.write_text(
        "#include <stddef.h>\n"
        "#include <stdio.h>\n"
        "int c2fbFormatSizeT(char *buffer, size_t value) {\n"
        "    return snprintf(buffer, 64, \"%zu\", value);\n"
        "}\n",
        encoding="utf-8",
    )
    candidate = source_directory / "size_t_vararg_candidates.bas"
    source_unit_tool = port.TOOLS / "c2fb_source_unit.py"
    command = [
        sys.executable, str(source_unit_tool), str(source), str(candidate),
        "--converter", converter, "--compiler", cc[0], "--include-header-types",
    ]
    command.extend(
        "--header-option=" + option for option in port.HEADER_OPTIONS
    )
    command.extend(
        "--body-option=" + option for option in port.BODY_OPTIONS
    )
    translation = subprocess.run(
        command, cwd=source_directory, capture_output=True, text=True,
        check=False,
    )
    assert translation.returncode == 0, (
        translation.stdout + translation.stderr
    )
    assert "translated 1 simple functions; skipped 0" in translation.stdout, (
        translation.stdout
    )
    type_context = candidate.with_name(candidate.stem + "_types.bi")
    assert "Type c2fb_size_t As CULong" in type_context.read_text(encoding="utf-8")

    reference_path = source_directory / "reference.so"
    reference_compile = subprocess.run(
        cc + ["-std=c99", "-shared", "-fPIC", str(source), "-o", str(reference_path)],
        cwd=source_directory, capture_output=True, text=True, check=False,
    )
    assert reference_compile.returncode == 0, (
        reference_compile.stdout + reference_compile.stderr
    )

    wrapper = source_directory / "check.bas"
    wrapper.write_text(
        '#include once "size_t_vararg_candidates.bas"\n',
        encoding="utf-8",
    )
    converted_path = source_directory / "converted.so"
    converted_compile = subprocess.run(
        fbc + ["-gen", "gcc", "-w", "all", "-dll", "-i", str(port.SOURCE),
               str(wrapper), "-x", str(converted_path)],
        cwd=source_directory, capture_output=True, text=True, check=False,
    )
    assert converted_compile.returncode == 0, (
        converted_compile.stdout + converted_compile.stderr
    )
    assert "expects argument of type" not in converted_compile.stderr, (
        converted_compile.stderr
    )

    reference = ctypes.CDLL(str(reference_path))
    converted = ctypes.CDLL(str(converted_path))
    for library in (reference, converted):
        library.c2fbFormatSizeT.argtypes = [
            ctypes.POINTER(ctypes.c_char), ctypes.c_ulong,
        ]
        library.c2fbFormatSizeT.restype = ctypes.c_int

    for value in (0, 1, 0xFFFFFFFF, 0x100000001,
                  0xFEDCBA9876543210, 0xFFFFFFFFFFFFFFFF):
        reference_buffer = ctypes.create_string_buffer(64)
        converted_buffer = ctypes.create_string_buffer(64)
        reference_length = reference.c2fbFormatSizeT(reference_buffer, value)
        converted_length = converted.c2fbFormatSizeT(converted_buffer, value)
        assert converted_length == reference_length
        assert converted_buffer.value == reference_buffer.value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fbc", type=Path, default=port.FBC)
    parser.add_argument("--cc", default="cc")
    arguments = parser.parse_args()
    compiler = arguments.fbc.resolve()
    cc = shlex.split(arguments.cc)
    if not compiler.is_file():
        parser.error(f"FreeBASIC compiler is unavailable: {compiler}")
    if not cc:
        parser.error("--cc must name a C compiler")
    try:
        port.require_coreutils_source()
    except RuntimeError as error:
        parser.error(str(error))

    if port.C2FB_CONVERTER_OVERRIDE is None:
        subprocess.run(["make", "converter", f"FBC={compiler}"],
                       cwd=port.TOOLS, check=True)
    elif not port.C2FB_CONVERTER.is_file():
        parser.error(
            f"C2FB converter is unavailable: {port.C2FB_CONVERTER}"
        )
    spec = importlib.util.spec_from_file_location(
        "coreutils_converter_tests", port.TOOLS / "tests/test_c2fb.py")
    tests = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tests)
    converter = str(port.C2FB_CONVERTER)
    fbc = [str(compiler)]
    fbc.extend(["-i", str(port.PORT.parent)])
    if port.FBC_RUNTIME_LIBDIR.is_dir():
        fbc.extend(["-p", str(port.FBC_RUNTIME_LIBDIR)])
    compiler_include_directory = compiler.parent.parent / "inc"
    if compiler_include_directory.is_dir():
        fbc.extend(["-i", str(compiler_include_directory)])

    # The original suite also covers SQLite integration. These checks use
    # independent fixtures and therefore run from this repository alone.
    comparison_names = (
        "check_generic_gnu_signed_types",
        "check_generic_header_large_static_array_initializer",
        "check_generic_header_sizeof_conditional_array_bound",
        "check_generic_body_ptrdiff_t_width",
        "check_generic_body_call_statement_braced_string",
        "check_generic_body_static_assert_statement",
        "check_generic_body_sizeof_array_bound_without_header_plans",
        "check_generic_body_named_local_enum_static_array",
        "check_generic_header_longdouble_record_layout",
        "check_generic_header_longdouble_record_dependencies",
        "check_generic_body_longdouble_field_arithmetic",
        "check_generic_body_parameter_matches_tag",
        "check_generic_body_partial_bitfield_aligned_scalar",
        "check_generic_body_external_header_inline",
        "check_generic_body_included_c_source_bodies",
        "check_generic_body_gcc_diagnostic_pragmas",
        "check_generic_body_runtime_abs_intrinsic",
        "check_generic_body_automatic_unsized_character_array",
        "check_generic_body_builtin_popcount",
        "check_generic_body_infinite_loop_termination",
        "check_generic_body_selected_header_inline_body",
        "check_compile_commands_workflow",
        "check_generic_body_global_definitions",
        "check_generic_body_source_unit_anonymous_header_static_record",
        "check_generic_body_object_pointer_conversion",
        "check_generic_body_pointer_conditional_string_array_decay",
        "check_generic_body_static_initializer_object_dependencies",
    )
    compile_check_names = (
        "check_generic_body_nested_bitfields",
        "check_generic_body_included_inline_functions",
        "check_generic_body_header_root",
        "check_generic_header_mixed_typedef_specifiers",
        "check_generic_header_gnu_extension_typedef",
        "check_generic_body_noreturn_function_specifier",
        "check_generic_body_skips_callers_of_unconverted_static_function",
    )
    comparisons = []
    compile_checks = []
    stale_check_names = []
    # C2FB's shared tests evolve independently; report removed names while
    # continuing with the tests that still exist in the current module.
    for check_name in comparison_names:
        check = getattr(tests, check_name, None)
        if check is None:
            stale_check_names.append(check_name)
        else:
            comparisons.append(check)
    for check_name in compile_check_names:
        check = getattr(tests, check_name, None)
        if check is None:
            stale_check_names.append(check_name)
        else:
            compile_checks.append(check)
    with tempfile.TemporaryDirectory(prefix="coreutils-converter-tests-") as directory:
        work = Path(directory)
        for check_name in stale_check_names:
            print(f"SKIP stale C2FB check name: {check_name}", flush=True)
        print("check_coreutils_oputs", flush=True)
        check_coreutils_oputs(converter, fbc, cc, work)
        print("PASS", flush=True)
        print("check_coreutils_fortified_fwrite", flush=True)
        check_coreutils_fortified_fwrite(converter, fbc, cc, work)
        print("PASS", flush=True)
        print("check_coreutils_color_indicator_source", flush=True)
        check_coreutils_color_indicator_source(converter, fbc, cc, work)
        print("PASS", flush=True)
        print("check_coreutils_local_array_declaration_limit", flush=True)
        check_coreutils_local_array_declaration_limit(converter, fbc, cc, work)
        print("PASS", flush=True)
        print("check_coreutils_select_plural", flush=True)
        check_coreutils_select_plural(converter, fbc, cc, work)
        print("PASS", flush=True)
        print("check_coreutils_basename_entrypoint", flush=True)
        check_coreutils_basename_entrypoint(fbc, work)
        print("PASS", flush=True)
        print("check_coreutils_true_false", flush=True)
        check_coreutils_true_false(fbc, work)
        print("PASS", flush=True)
        print("check_coreutils_mcel", flush=True)
        check_coreutils_mcel(converter, fbc, cc, work)
        print("PASS", flush=True)
        print("check_glibc_max_align_layout", flush=True)
        check_glibc_max_align_layout(converter, fbc, cc, work)
        print("PASS", flush=True)
        print("check_coreutils_xstrtol_runtime", flush=True)
        check_coreutils_xstrtol_runtime(fbc, cc, work)
        print("PASS", flush=True)
        print("check_coreutils_xstrtol_upstream", flush=True)
        check_coreutils_xstrtol_upstream(fbc, cc, work)
        print("PASS", flush=True)
        print("check_coreutils_cp_context", flush=True)
        check_coreutils_cp_context(converter, fbc, cc, work)
        print("PASS", flush=True)
        print("check_coreutils_seq_context", flush=True)
        check_coreutils_seq_context(converter, fbc, cc, work)
        print("PASS", flush=True)
        print("check_coreutils_sort_context", flush=True)
        check_coreutils_sort_context(converter, fbc, cc, work)
        print("PASS", flush=True)
        print("check_coreutils_dtimespec_bound", flush=True)
        check_coreutils_dtimespec_bound(converter, fbc, work)
        print("PASS", flush=True)
        print("check_lp64_size_t_vararg", flush=True)
        check_lp64_size_t_vararg(converter, fbc, cc, work)
        print("PASS", flush=True)
        for check in comparisons:
            print(check.__name__, flush=True)
            check(converter, fbc, cc, work)
            print("PASS", flush=True)
        for check in compile_checks:
            print(check.__name__, flush=True)
            check(converter, fbc, work)
            print("PASS", flush=True)
    passed_count = len(comparisons) + len(compile_checks) + 16
    print(
        f"All {passed_count} available focused checks passed; "
        f"{len(stale_check_names)} legacy C2FB checks are not present "
        "in the current test module."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

# end of check.py
