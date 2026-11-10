#!/usr/bin/env python3
"""
Project: C2FB Coreutils integration regressions
File: test_coreutils_c2fb_regressions.py
Purpose: Verify C2FB fixes found while translating GNU Coreutils.
Responsibilities: Compare focused C source units with native and GCC
FreeBASIC output, including file-scope data, runtime callbacks, width-sensitive
C23 builtins, checked-overflow predicates, integer rotations,
constant-expression queries, local type declarations, and array layout.
This file intentionally does NOT contain: GNU Coreutils upstream tests or
the general C2FB regression suite.
"""

import argparse
import ctypes
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


def run(command, *, cwd):
    result = subprocess.run(
        list(map(str, command)), cwd=cwd, capture_output=True, text=True,
        check=False,
    )
    if result.returncode:
        raise AssertionError(
            f"Command failed: {shlex.join(map(str, command))}\n"
            f"{result.stdout}{result.stderr}"
        )
    return result.stdout


def translate_source_unit(converter, cc, source_directory, source, candidate,
                          options=()):
    source_unit_tool = Path(__file__).resolve().parents[1] / "c2fb_source_unit.py"
    return run([
        sys.executable, source_unit_tool, source, candidate,
        "--converter", converter, "--compiler", cc[0], *options,
    ], cwd=source_directory)


def compile_and_compare(name, source_directory, candidate, reference_path,
                        fbc, check):
    reference = ctypes.CDLL(str(reference_path))
    for backend, flags in (("native", []), ("gcc", ["-gen", "gcc"])):
        output = source_directory / f"{name}-{backend}.so"
        run(fbc + flags + ["-w", "all", "-dll", candidate, "-x", output],
            cwd=source_directory)
        check(reference, ctypes.CDLL(str(output)), backend)
    print(f"{name}: PASS on native and GCC backends")


def check_c23_static_booleans(converter, fbc, cc, work):
    source_directory = work / "c23-static-booleans"
    source_directory.mkdir()
    source = source_directory / "static_booleans.c"
    source.write_text(
        "#include <stdbool.h>\n"
        "static bool c2fb_enabled = true;\n"
        "static bool c2fb_disabled = false;\n"
        "int c2fbReadStaticBooleans(void) {\n"
        "    return c2fb_enabled * 10 + c2fb_disabled;\n"
        "}\n"
    )
    candidate = source_directory / "static_booleans_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        (
            "--header-option=--emit-source=*",
            "--body-option=--include-global-definitions",
            "--body-option=--include-included-c-source-bodies",
            "--header-compiler-option=-std=gnu2x",
            "--body-compiler-option=-std=gnu2x",
        ),
    )
    assert "translated 1 simple functions; skipped 0" in summary, summary
    types = candidate.with_name(candidate.stem + "_types.bi").read_text()
    assert "As Byte = 1" in types and "As Byte = 0" in types, types

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu2x", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbReadStaticBooleans.restype = ctypes.c_int
        expected = reference.c2fbReadStaticBooleans()
        actual = converted.c2fbReadStaticBooleans()
        assert actual == expected == 10, (backend, expected, actual)

    compile_and_compare("c23-static-booleans", source_directory, candidate,
                        reference_path, fbc, check)


def check_pointer_array_assignment(converter, fbc, cc, work):
    source_directory = work / "pointer-array-assignment"
    source_directory.mkdir()
    source = source_directory / "pointer_array.c"
    source.write_text(
        "struct c2fb_node { int value; };\n"
        "static struct c2fb_node *c2fb_nodes[1];\n"
        "void c2fbStoreNode(struct c2fb_node *node) {\n"
        "    c2fb_nodes[0] = node;\n"
        "}\n"
        "int c2fbReadNode(void) { return c2fb_nodes[0]->value; }\n"
    )
    candidate = source_directory / "pointer_array_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        ("--body-option=--include-global-definitions",),
    )
    assert "translated 2 simple functions; skipped 0" in summary, summary

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    class Node(ctypes.Structure):
        _fields_ = [("value", ctypes.c_int)]

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbStoreNode.argtypes = [ctypes.POINTER(Node)]
            library.c2fbReadNode.restype = ctypes.c_int
        for value in (-31, 0, 47):
            node = Node(value)
            reference.c2fbStoreNode(ctypes.byref(node))
            converted.c2fbStoreNode(ctypes.byref(node))
            expected = reference.c2fbReadNode()
            actual = converted.c2fbReadNode()
            assert actual == expected == value, (
                backend, value, expected, actual
            )

    compile_and_compare("pointer-array-assignment", source_directory,
                        candidate, reference_path, fbc, check)


def check_file_scope_allocator_callbacks(converter, fbc, cc, work):
    source_directory = work / "file-scope-allocator-callbacks"
    source_directory.mkdir()
    source = source_directory / "allocator.c"
    source.write_text(
        "#include <stddef.h>\n"
        "#include <stdlib.h>\n"
        "struct allocator {\n"
        "    void *(*allocate)(size_t);\n"
        "    void *(*reallocate)(void *, size_t);\n"
        "    void (*free)(void *);\n"
        "    void (*die)(size_t);\n"
        "};\n"
        "const struct allocator stdlib_allocator = {\n"
        "    malloc, realloc, free, 0\n"
        "};\n"
    )
    candidate = source_directory / "allocator_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        ("--body-option=--include-global-definitions",),
    )
    assert "translated 0 simple functions; skipped 0" in summary, summary
    generated = candidate.read_text()
    for declaration in (
        'Declare Function c2fb_crt_malloc CDecl Alias "malloc"',
        'Declare Function c2fb_crt_realloc CDecl Alias "realloc"',
        'Declare Sub c2fb_crt_free CDecl Alias "free"',
    ):
        assert declaration in generated, generated

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            callbacks = (ctypes.c_void_p * 4).in_dll(
                library, "stdlib_allocator"
            )
            assert callbacks[0] and callbacks[1] and callbacks[2]
            assert callbacks[3] is None
            allocate = ctypes.CFUNCTYPE(
                ctypes.c_void_p, ctypes.c_size_t
            )(callbacks[0])
            reallocate = ctypes.CFUNCTYPE(
                ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t
            )(callbacks[1])
            release = ctypes.CFUNCTYPE(None, ctypes.c_void_p)(callbacks[2])
            address = allocate(8)
            assert address
            try:
                ctypes.memmove(address, b"c2fb", 4)
                resized = reallocate(address, 32)
                assert resized
                address = resized
                assert ctypes.string_at(address, 4) == b"c2fb"
            finally:
                release(address)

    compile_and_compare("file-scope-allocator-callbacks", source_directory,
                        candidate, reference_path, fbc, check)


def check_generic_typedef_array_bound(converter, fbc, cc, work):
    source_directory = work / "generic-typedef-array-bound"
    source_directory.mkdir()
    source = source_directory / "generic_bound.c"
    source.write_text(
        "#include <stdint.h>\n"
        "int c2fbReadGenericTypedefArrayBound(void) {\n"
        "    char buffer[_Generic(((__typeof__(intmax_t)){0}),\n"
        "        long int: 21, default: 22)];\n"
        "    return sizeof buffer;\n"
        "}\n"
    )
    candidate = source_directory / "generic_bound_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        (
            "--header-option=--emit-source=*",
            "--header-compiler-option=-std=gnu2x",
            "--body-compiler-option=-std=gnu2x",
        ),
    )
    assert "translated 1 simple functions; skipped 0" in summary, summary

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu2x", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)
    reference = ctypes.CDLL(str(reference_path))
    reference.c2fbReadGenericTypedefArrayBound.restype = ctypes.c_int
    expected = reference.c2fbReadGenericTypedefArrayBound()
    assert expected > 0

    def check(reference, converted, backend):
        reference.c2fbReadGenericTypedefArrayBound.restype = ctypes.c_int
        converted.c2fbReadGenericTypedefArrayBound.restype = ctypes.c_int
        expected = reference.c2fbReadGenericTypedefArrayBound()
        actual = converted.c2fbReadGenericTypedefArrayBound()
        assert actual == expected, (backend, expected, actual)

    compile_and_compare("generic-typedef-array-bound", source_directory,
                        candidate, reference_path, fbc, check)


def check_generic_enum_constant(converter, fbc, cc, work):
    source_directory = work / "generic-enum-constant"
    source_directory.mkdir()
    source = source_directory / "generic_enum.c"
    source.write_text(
        "#include <stdint.h>\n"
        "enum { c2fb_generic_enum_bound = sizeof(intmax_t) +\n"
        "    _Generic(((__typeof__(intmax_t)){0}),\n"
        "        long int: 17, default: 99) };\n"
        "int c2fbReadGenericEnumBound(void) {\n"
        "    char buffer[c2fb_generic_enum_bound];\n"
        "    return sizeof buffer;\n"
        "}\n"
    )
    candidate = source_directory / "generic_enum_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        (
            "--header-option=--emit-source=*",
            "--header-compiler-option=-std=gnu2x",
            "--body-compiler-option=-std=gnu2x",
        ),
    )
    assert "translated 1 simple functions; skipped 0" in summary, summary

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu2x", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbReadGenericEnumBound.restype = ctypes.c_int
        expected = reference.c2fbReadGenericEnumBound()
        actual = converted.c2fbReadGenericEnumBound()
        assert actual == expected == 25, (backend, expected, actual)

    compile_and_compare("generic-enum-constant", source_directory,
                        candidate, reference_path, fbc, check)


def check_scalar_compound_literal_expression(converter, fbc, cc, work):
    source_directory = work / "scalar-compound-literal-expression"
    source_directory.mkdir()
    source = source_directory / "scalar_compound_literal.c"
    source.write_text(
        "#include <stdint.h>\n"
        "uintmax_t c2fbReadScalarCompoundLiteral(\n"
        "    uintmax_t value, uintmax_t divisor) {\n"
        "    return (uintmax_t) { value } % divisor;\n"
        "}\n"
    )
    candidate = source_directory / "scalar_compound_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        (
            "--header-option=--emit-source=*",
            "--header-compiler-option=-std=gnu2x",
            "--body-compiler-option=-std=gnu2x",
        ),
    )
    assert "translated 1 simple functions; skipped 0" in summary, summary

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu2x", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbReadScalarCompoundLiteral.argtypes = [
                ctypes.c_ulong, ctypes.c_ulong,
            ]
            library.c2fbReadScalarCompoundLiteral.restype = ctypes.c_ulong
        for value, divisor in ((0, 1), (0xFFFFFFFFFFFF, 97),
                               (123456789, 1000)):
            expected = reference.c2fbReadScalarCompoundLiteral(value, divisor)
            actual = converted.c2fbReadScalarCompoundLiteral(value, divisor)
            assert actual == expected == value % divisor, (
                backend, value, divisor, expected, actual
            )

    compile_and_compare("scalar-compound-literal-expression", source_directory,
                        candidate, reference_path, fbc, check)


def check_record_compound_literal_value(converter, fbc, cc, work):
    source_directory = work / "record-compound-literal-value"
    source_directory.mkdir()
    source = source_directory / "record_compound_literal.c"
    source.write_text(
        "typedef struct { unsigned long uu[2]; } c2fb_uuint;\n"
        "c2fb_uuint c2fbMakeRecordCompoundLiteral(\n"
        "    unsigned long high, unsigned long low) {\n"
        "    return (c2fb_uuint) {{ low, high }};\n"
        "}\n"
        "unsigned long c2fbAssignRecordCompoundLiteral(\n"
        "    unsigned long high, unsigned long low) {\n"
        "    return ((c2fb_uuint) {{ low, high }}).uu[0] = low ^ high;\n"
        "}\n"
    )
    candidate = source_directory / "record_compound_literal_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        ("--header-option=--emit-source=*",),
    )
    assert "translated 2 simple functions; skipped 0" in summary, summary
    generated = candidate.read_text()
    assert "c2fb skipped" not in generated, generated
    assert "Dim c2fb_temp_" in generated, generated

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    class Uuint(ctypes.Structure):
        _fields_ = [("uu", ctypes.c_ulong * 2)]

    def check(reference, converted, backend):
        for library in (reference, converted):
            make_value = library.c2fbMakeRecordCompoundLiteral
            make_value.argtypes = [ctypes.c_ulong, ctypes.c_ulong]
            make_value.restype = Uuint
            assign_value = library.c2fbAssignRecordCompoundLiteral
            assign_value.argtypes = [ctypes.c_ulong, ctypes.c_ulong]
            assign_value.restype = ctypes.c_ulong
        values = (
            (0, 0), (1, 2), (0xFFFFFFFFFFFFFFFF, 0x0123456789ABCDEF),
        )
        for high, low in values:
            expected = reference.c2fbMakeRecordCompoundLiteral(high, low)
            actual = converted.c2fbMakeRecordCompoundLiteral(high, low)
            assert tuple(actual.uu) == tuple(expected.uu) == (low, high), (
                backend, high, low, tuple(expected.uu), tuple(actual.uu)
            )
            expected_value = reference.c2fbAssignRecordCompoundLiteral(
                high, low)
            actual_value = converted.c2fbAssignRecordCompoundLiteral(
                high, low)
            assert actual_value == expected_value == (low ^ high), (
                backend, high, low, expected_value, actual_value
            )

    compile_and_compare("record-compound-literal-value", source_directory,
                        candidate, reference_path, fbc, check)


def check_stdc_zero_count_builtins(converter, fbc, cc, work):
    source_directory = work / "stdc-zero-count-builtins"
    source_directory.mkdir()
    source = source_directory / "stdc_zero_count.c"
    source.write_text(
        "unsigned int c2fbLeadingZeros8(unsigned char value) {\n"
        "    return __builtin_stdc_leading_zeros(value);\n"
        "}\n"
        "unsigned int c2fbTrailingZeros8(unsigned char value) {\n"
        "    return __builtin_stdc_trailing_zeros(value);\n"
        "}\n"
        "unsigned int c2fbLeadingZeros16(unsigned short value) {\n"
        "    return __builtin_stdc_leading_zeros(value);\n"
        "}\n"
        "unsigned int c2fbTrailingZeros16(unsigned short value) {\n"
        "    return __builtin_stdc_trailing_zeros(value);\n"
        "}\n"
        "unsigned int c2fbLeadingZeros32(unsigned int value) {\n"
        "    return __builtin_stdc_leading_zeros(value);\n"
        "}\n"
        "unsigned int c2fbTrailingZeros32(unsigned int value) {\n"
        "    return __builtin_stdc_trailing_zeros(value);\n"
        "}\n"
        "unsigned int c2fbLeadingZeros64(unsigned long value) {\n"
        "    return __builtin_stdc_leading_zeros(value);\n"
        "}\n"
        "unsigned int c2fbTrailingZeros64(unsigned long value) {\n"
        "    return __builtin_stdc_trailing_zeros(value);\n"
        "}\n"
        "unsigned int c2fbTrailingZerosAndIncrement(unsigned long *value) {\n"
        "    return __builtin_stdc_trailing_zeros((*value)++);\n"
        "}\n"
    )
    candidate = source_directory / "stdc_zero_count_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        (
            "--header-option=--emit-source=*",
            "--header-compiler-option=-std=gnu2x",
            "--body-compiler-option=-std=gnu2x",
        ),
    )
    assert "translated 9 simple functions; skipped 0" in summary, summary
    generated = candidate.read_text()
    assert "c2fb skipped" not in generated, generated
    assert "c2fb_builtin_stdc_leading_zeros_8" in generated, generated
    assert "c2fb_builtin_stdc_trailing_zeros_64" in generated, generated

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu2x", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        widths = (
            (8, ctypes.c_ubyte, "8"),
            (16, ctypes.c_ushort, "16"),
            (32, ctypes.c_uint, "32"),
            (ctypes.sizeof(ctypes.c_ulong) * 8, ctypes.c_ulong, "64"),
        )
        for library in (reference, converted):
            for width, argument_type, suffix in widths:
                for prefix in ("Leading", "Trailing"):
                    function = getattr(
                        library, f"c2fb{prefix}Zeros{suffix}")
                    function.argtypes = [argument_type]
                    function.restype = ctypes.c_uint
            library.c2fbTrailingZerosAndIncrement.argtypes = [
                ctypes.POINTER(ctypes.c_ulong),
            ]
            library.c2fbTrailingZerosAndIncrement.restype = ctypes.c_uint

        for width, argument_type, suffix in widths:
            for value in (0, 1, 1 << (width - 1),
                          (1 << (width - 1)) | (1 << max(0, width - 4))):
                expected_leading = width if value == 0 else \
                    width - value.bit_length()
                expected_trailing = width if value == 0 else \
                    (value & -value).bit_length() - 1
                for prefix, expected in (
                    ("Leading", expected_leading),
                    ("Trailing", expected_trailing),
                ):
                    function_name = f"c2fb{prefix}Zeros{suffix}"
                    expected_value = getattr(reference, function_name)(value)
                    actual_value = getattr(converted, function_name)(value)
                    assert actual_value == expected_value == expected, (
                        backend, width, value, function_name,
                        expected_value, actual_value, expected,
                    )

        for library in (reference, converted):
            value = ctypes.c_ulong(16)
            result = library.c2fbTrailingZerosAndIncrement(
                ctypes.byref(value))
            assert result == 4 and value.value == 17, (
                backend, result, value.value,
            )

    compile_and_compare("stdc-zero-count-builtins", source_directory,
                        candidate, reference_path, fbc, check)


def check_file_scope_countof_enum(converter, fbc, cc, work):
    source_directory = work / "file-scope-countof-enum"
    source_directory.mkdir()
    source = source_directory / "countof_enum.c"
    source.write_text(
        "#include <stddef.h>\n"
        "#include <stdint.h>\n"
        "#define c2fb_countof(array) \\\n"
        "    ((size_t) (sizeof(array) / sizeof(array)[0] + \\\n"
        "       0 * sizeof(struct { unsigned int check : \\\n"
        "           __builtin_types_compatible_p( \\\n"
        "               __typeof__(array), __typeof__(&*(array))) ? -1 : 1; })))\n"
        "static const int_least16_t c2fb_countof_values[] = {\n"
        "    3, 5, 7, 11, 13, 17, 19, 23, 29, 31\n"
        "};\n"
        "enum { C2FB_COUNTOF_VALUES = \\\n"
        "    c2fb_countof(c2fb_countof_values) - 8 + 1 };\n"
        "int c2fbReadFileScopeCountofEnum(void) {\n"
        "    return C2FB_COUNTOF_VALUES;\n"
        "}\n"
    )
    candidate = source_directory / "countof_enum_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        (
            "--header-option=--emit-source=*",
            "--body-option=--include-global-definitions",
            "--header-compiler-option=-std=gnu11",
            "--body-compiler-option=-std=gnu11",
        ),
    )
    assert "translated 1 simple functions; skipped 0" in summary, summary
    generated = candidate.read_text()
    assert "Return 3" in generated, generated

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbReadFileScopeCountofEnum.restype = ctypes.c_int
        expected = reference.c2fbReadFileScopeCountofEnum()
        actual = converted.c2fbReadFileScopeCountofEnum()
        assert actual == expected == 3, (backend, expected, actual)

    compile_and_compare("file-scope-countof-enum", source_directory,
                        candidate, reference_path, fbc, check)


def check_builtin_constant_p(converter, fbc, cc, work):
    source_directory = work / "builtin-constant-p"
    source_directory.mkdir()
    source = source_directory / "builtin_constant_p.c"
    source.write_text(
        "static int c2fb_constant_p_calls;\n"
        "static unsigned long c2fbConstantRuntimeCall(void) {\n"
        "    c2fb_constant_p_calls++;\n"
        "    return (unsigned long) c2fb_constant_p_calls;\n"
        "}\n"
        "int c2fbConstantPOfLiteral(void) {\n"
        "    return __builtin_constant_p(1);\n"
        "}\n"
        "int c2fbConstantPOfParameter(unsigned long value) {\n"
        "    return __builtin_constant_p(value * value);\n"
        "}\n"
        "int c2fbConstantPDoesNotEvaluateCall(void) {\n"
        "    c2fb_constant_p_calls = 0;\n"
        "    return 10 * __builtin_constant_p(c2fbConstantRuntimeCall()) +\n"
        "           c2fb_constant_p_calls;\n"
        "}\n"
    )
    candidate = source_directory / "builtin_constant_p_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        (
            "--header-option=--emit-source=*",
            "--body-option=--include-global-definitions",
            "--header-compiler-option=-std=gnu11",
            "--body-compiler-option=-std=gnu11",
        ),
    )
    assert "translated 4 simple functions; skipped 0" in summary, summary
    generated = candidate.read_text()
    assert "c2fb skipped" not in generated, generated
    assert "c2fbConstantRuntimeCall()" not in generated, generated

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbConstantPOfLiteral.restype = ctypes.c_int
            library.c2fbConstantPOfParameter.argtypes = [ctypes.c_ulong]
            library.c2fbConstantPOfParameter.restype = ctypes.c_int
            library.c2fbConstantPDoesNotEvaluateCall.restype = ctypes.c_int
        assert reference.c2fbConstantPOfLiteral() == \
            converted.c2fbConstantPOfLiteral() == 1, backend
        for value in (0, 1, 0xFFFFFFFFFFFFFFFF):
            assert reference.c2fbConstantPOfParameter(value) == \
                converted.c2fbConstantPOfParameter(value) == 0, (
                    backend, value)
        assert reference.c2fbConstantPDoesNotEvaluateCall() == \
            converted.c2fbConstantPDoesNotEvaluateCall() == 0, backend

    compile_and_compare("builtin-constant-p", source_directory, candidate,
                        reference_path, fbc, check)


def check_checked_overflow_builtins(converter, fbc, cc, work):
    source_directory = work / "checked-overflow-builtins"
    source_directory.mkdir()
    source = source_directory / "checked_overflow.c"
    source.write_text(
        "int c2fbUnsignedAddOverflow(\n"
        "    unsigned long left, unsigned long right, unsigned long *result) {\n"
        "    return __builtin_add_overflow(left, right, result);\n"
        "}\n"
        "int c2fbUnsignedSubOverflow(\n"
        "    unsigned long left, unsigned long right, unsigned long *result) {\n"
        "    return __builtin_sub_overflow(left, right, result);\n"
        "}\n"
        "int c2fbUnsignedMulOverflow(\n"
        "    unsigned long left, unsigned long right, unsigned long *result) {\n"
        "    return __builtin_mul_overflow(left, right, result);\n"
        "}\n"
        "int c2fbSignedAddOverflow(int left, int right, int *result) {\n"
        "    return __builtin_add_overflow(left, right, result);\n"
        "}\n"
    )
    candidate = source_directory / "checked_overflow_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        ("--header-option=--emit-source=*",),
    )
    assert "translated 4 simple functions; skipped 0" in summary, summary

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        unsigned_cases = (
            ("Add", ((0, 0, 0, 0), (0xFFFFFFFFFFFFFFFF, 1, 1, 0),
                     (0xFFFFFFFFFFFFFFFE, 1, 0, 0xFFFFFFFFFFFFFFFF),
                     (0x8000000000000000, 0x8000000000000000, 1, 0))),
            ("Sub", ((0, 1, 1, 0xFFFFFFFFFFFFFFFF), (7, 3, 0, 4),
                     (0xFFFFFFFFFFFFFFFF, 0, 0, 0xFFFFFFFFFFFFFFFF))),
            ("Mul", ((0, 0xFFFFFFFFFFFFFFFF, 0, 0), (3, 7, 0, 21),
                     (0x8000000000000000, 2, 1, 0),
                     (0xFFFFFFFFFFFFFFFF, 2, 1, 0xFFFFFFFFFFFFFFFE))),
        )
        for library in (reference, converted):
            for operation, _ in unsigned_cases:
                function = getattr(library, f"c2fbUnsigned{operation}Overflow")
                function.argtypes = [
                    ctypes.c_ulong, ctypes.c_ulong,
                    ctypes.POINTER(ctypes.c_ulong),
                ]
                function.restype = ctypes.c_int
            signed = library.c2fbSignedAddOverflow
            signed.argtypes = [
                ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_int),
            ]
            signed.restype = ctypes.c_int

        for operation, cases in unsigned_cases:
            for left, right, expected_overflow, expected_result in cases:
                outputs = []
                for library in (reference, converted):
                    result = ctypes.c_ulong()
                    overflow = getattr(
                        library, f"c2fbUnsigned{operation}Overflow")(
                            left, right, ctypes.byref(result))
                    outputs.append((overflow, result.value))
                assert outputs[0] == outputs[1] == (
                    expected_overflow, expected_result), (
                        backend, operation, left, right, outputs,
                        expected_overflow, expected_result,
                    )

        signed_cases = (
            (1, 2, 0, 3),
            (0x7FFFFFFF, 1, 1, -0x80000000),
            (-0x80000000, -1, 1, 0x7FFFFFFF),
        )
        for left, right, expected_overflow, expected_result in signed_cases:
            outputs = []
            for library in (reference, converted):
                result = ctypes.c_int()
                overflow = library.c2fbSignedAddOverflow(
                    left, right, ctypes.byref(result))
                outputs.append((overflow, result.value))
            assert outputs[0] == outputs[1] == (
                expected_overflow, expected_result), (
                    backend, "signed add", left, right, outputs,
                )

    compile_and_compare("checked-overflow-builtins", source_directory,
                        candidate, reference_path, fbc, check)


def check_checked_overflow_predicate_builtins(converter, fbc, cc, work):
    source_directory = work / "checked-overflow-predicate-builtins"
    source_directory.mkdir()
    source = source_directory / "checked_overflow_predicate.c"
    source.write_text(
        "struct c2fbOverflowBitField { unsigned char value : 3; };\n"
        "int c2fbAddOverflowPUnsignedChar(unsigned long left, unsigned long right) {\n"
        "    return __builtin_add_overflow_p(left, right, (unsigned char) 0);\n"
        "}\n"
        "int c2fbSubOverflowPUnsignedChar(unsigned long left, unsigned long right) {\n"
        "    return __builtin_sub_overflow_p(left, right, (unsigned char) 0);\n"
        "}\n"
        "int c2fbMulOverflowPUnsignedChar(unsigned long left, unsigned long right) {\n"
        "    return __builtin_mul_overflow_p(left, right, (unsigned char) 0);\n"
        "}\n"
        "int c2fbAddOverflowPSignedChar(int left, int right) {\n"
        "    return __builtin_add_overflow_p(left, right, (signed char) 0);\n"
        "}\n"
        "int c2fbMulOverflowPUnsignedLong(unsigned long left, unsigned long right) {\n"
        "    return __builtin_mul_overflow_p(left, right, (unsigned long) 0);\n"
        "}\n"
        "int c2fbAddOverflowPDoesNotEvaluateThird(int left, int right) {\n"
        "    int count = 0;\n"
        "    int overflow = __builtin_add_overflow_p(left, right, count++);\n"
        "    return overflow * 10 + count;\n"
        "}\n"
        "int c2fbOverflowPBitField(struct c2fbOverflowBitField *result,\n"
        "    unsigned int left, unsigned int right) {\n"
        "    return __builtin_add_overflow_p(left, right, result->value);\n"
        "}\n"
    )
    candidate = source_directory / "checked_overflow_predicate_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        ("--header-option=--emit-source=*",),
    )
    assert "translated 6 simple functions; skipped 1" in summary, summary
    candidate_text = candidate.read_text()
    assert "c2fb skipped c2fbOverflowPBitField:" in candidate_text, candidate_text
    assert "Function c2fbOverflowPBitField CDecl Alias" not in candidate_text

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    unsigned_cases = {
        "c2fbAddOverflowPUnsignedChar": (
            (0, 0, 0), (250, 5, 0), (250, 6, 1), (1000, 0, 1),
        ),
        "c2fbSubOverflowPUnsignedChar": (
            (250, 249, 0), (300, 100, 0), (0, 1, 1),
            (1000, 0, 1), (0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0),
        ),
        "c2fbMulOverflowPUnsignedChar": (
            (12, 20, 0), (16, 16, 1), (0, 0xFFFFFFFFFFFFFFFF, 0),
            (0xFFFFFFFFFFFFFFFF, 2, 1),
        ),
        "c2fbMulOverflowPUnsignedLong": (
            (3, 7, 0), (0xFFFFFFFFFFFFFFFF, 0, 0),
            (0x8000000000000000, 2, 1),
            (0x7FFFFFFFFFFFFFFF, 2, 0),
        ),
    }

    def check(reference, converted, backend):
        for library in (reference, converted):
            for function_name in unsigned_cases:
                function = getattr(library, function_name)
                function.argtypes = [ctypes.c_ulong, ctypes.c_ulong]
                function.restype = ctypes.c_int
            signed = library.c2fbAddOverflowPSignedChar
            signed.argtypes = [ctypes.c_int, ctypes.c_int]
            signed.restype = ctypes.c_int
            no_evaluation = library.c2fbAddOverflowPDoesNotEvaluateThird
            no_evaluation.argtypes = [ctypes.c_int, ctypes.c_int]
            no_evaluation.restype = ctypes.c_int

        for function_name, cases in unsigned_cases.items():
            function_pair = (
                getattr(reference, function_name),
                getattr(converted, function_name),
            )
            for left, right, expected in cases:
                outputs = tuple(function(left, right) for function in function_pair)
                assert outputs == (expected, expected), (
                    backend, function_name, left, right, outputs, expected,
                )

        signed_cases = (
            (120, 7, 0), (120, 8, 1), (-100, -20, 0),
            (-100, -30, 1), (1000, -1000, 0),
        )
        for left, right, expected in signed_cases:
            outputs = tuple(
                library.c2fbAddOverflowPSignedChar(left, right)
                for library in (reference, converted)
            )
            assert outputs == (expected, expected), (
                backend, "signed char add", left, right, outputs, expected,
            )

        outputs = tuple(
            library.c2fbAddOverflowPDoesNotEvaluateThird(2147483647, 1)
            for library in (reference, converted)
        )
        assert outputs == (11, 11), (
            backend, "third argument side effects were not preserved", outputs)

    compile_and_compare(
        "checked-overflow-predicate-builtins", source_directory, candidate,
        reference_path, fbc, check,
    )


def check_stdc_rotate_builtins(converter, fbc, cc, work):
    source_directory = work / "stdc-rotate-builtins"
    source_directory.mkdir()
    source = source_directory / "stdc_rotate.c"
    source.write_text(
        "unsigned char c2fbRotateRightU8(unsigned char value, unsigned int count) {\n"
        "    return __builtin_stdc_rotate_right(value, count);\n"
        "}\n"
        "unsigned short c2fbRotateLeftU16(unsigned short value, unsigned int count) {\n"
        "    return __builtin_stdc_rotate_left(value, count);\n"
        "}\n"
        "unsigned int c2fbRotateRightU32(unsigned int value, unsigned int count) {\n"
        "    return __builtin_stdc_rotate_right(value, count);\n"
        "}\n"
        "unsigned long c2fbRotateLeftU64(unsigned long value, unsigned int count) {\n"
        "    return __builtin_stdc_rotate_left(value, count);\n"
        "}\n"
        "static unsigned char c2fbRotateNextValue(unsigned int *calls) {\n"
        "    (*calls)++;\n"
        "    return 0x95;\n"
        "}\n"
        "static unsigned int c2fbRotateNextCount(unsigned int *calls) {\n"
        "    (*calls)++;\n"
        "    return 3;\n"
        "}\n"
        "unsigned int c2fbRotateSideEffects(unsigned int *valueCalls,\n"
        "    unsigned int *countCalls) {\n"
        "    return __builtin_stdc_rotate_right(\n"
        "        c2fbRotateNextValue(valueCalls), c2fbRotateNextCount(countCalls));\n"
        "}\n"
    )
    candidate = source_directory / "stdc_rotate_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        (
            "--header-option=--emit-source=*",
            "--header-compiler-option=-std=gnu2x",
            "--body-compiler-option=-std=gnu2x",
        ),
    )
    assert "translated 7 simple functions; skipped 0" in summary, summary

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu2x", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    rotations = {
        "c2fbRotateRightU8": (ctypes.c_ubyte, 8, "right", 0x95),
        "c2fbRotateLeftU16": (ctypes.c_ushort, 16, "left", 0x92D1),
        "c2fbRotateRightU32": (ctypes.c_uint, 32, "right", 0x89ABCDEF),
        "c2fbRotateLeftU64": (
            ctypes.c_ulong, 64, "left", 0x8123456789ABCDEF,
        ),
    }

    def check(reference, converted, backend):
        for library in (reference, converted):
            for function_name, (value_type, _width, _direction, _value) in rotations.items():
                function = getattr(library, function_name)
                function.argtypes = [value_type, ctypes.c_uint]
                function.restype = value_type
            side_effects = library.c2fbRotateSideEffects
            side_effects.argtypes = [
                ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint),
            ]
            side_effects.restype = ctypes.c_uint

        for function_name, (value_type, width, direction, value) in rotations.items():
            mask = (1 << width) - 1
            counts = (0, 1, width - 1, width, width + 1,
                      2 * width + 3, 0xFFFFFFFF)
            for count in counts:
                amount = count % width
                if direction == "right":
                    expected = ((value >> amount) | (value << (width - amount))) & mask
                else:
                    expected = ((value << amount) | (value >> (width - amount))) & mask
                outputs = tuple(
                    getattr(library, function_name)(value, count)
                    for library in (reference, converted)
                )
                assert outputs == (expected, expected), (
                    backend, function_name, value, count, outputs, expected,
                )

        for library in (reference, converted):
            value_calls = ctypes.c_uint(0)
            count_calls = ctypes.c_uint(0)
            result = library.c2fbRotateSideEffects(
                ctypes.byref(value_calls), ctypes.byref(count_calls))
            assert result == 0xB2, (backend, "rotate result", result)
            assert (value_calls.value, count_calls.value) == (1, 1), (
                backend, "rotate argument count", value_calls.value,
                count_calls.value,
            )

    compile_and_compare("stdc-rotate-builtins", source_directory, candidate,
                        reference_path, fbc, check)


def check_local_array_sizeof_bound(converter, fbc, cc, work):
    source_directory = work / "local-array-sizeof-bound"
    source_directory.mkdir()
    size_header = source_directory / "large_static_array_size.h"
    size_header.write_text(
        "enum { c2fb_large_static_buffer_size = 262144 };\n"
    )
    vector_header = source_directory / "wide_vector.h"
    vector_header.write_text(
        "/*\n"
        "    Project: C2FB Coreutils integration regressions\n"
        "    File: wide_vector.h\n"
        "    Purpose: Define a fixed-size record used in a local array bound.\n"
        "    Responsibilities: Provide an alias whose C size is 32 bytes.\n"
        "    This file intentionally does NOT contain: vector operations.\n"
        "*/\n"
        "typedef struct c2fb_wide_vector {\n"
        "    unsigned char bytes[32];\n"
        "} c2fb_wide_vector;\n"
        "typedef c2fb_wide_vector c2fb_wide_vector_alias;\n"
        "/* end of wide_vector.h */\n"
    )
    source = source_directory / "local_sizeof.c"
    source.write_text(
        "/*\n"
        "    Project: C2FB Coreutils integration regressions\n"
        "    File: local_sizeof.c\n"
        "    Purpose: Exercise sizeof in local array bounds.\n"
        "    Responsibilities: Compare scalar and record-sized arrays.\n"
        "    This file intentionally does NOT contain: vector operations.\n"
        "*/\n"
        "#include <stdint.h>\n"
        '#include "large_static_array_size.h"\n'
        '#include "wide_vector.h"\n'
        "int c2fbReadLocalArraySizeofBound(void) {\n"
        "    char prefix[12];\n"
        "    char buffer[sizeof prefix + sizeof(uintmax_t) +\n"
        "        _Generic(((__typeof__(uintmax_t)){0}),\n"
        "            unsigned long int: 3, default: 4)];\n"
        "    return sizeof buffer;\n"
        "}\n"
        "int c2fbReadLargeStaticArray(void) {\n"
        "    static unsigned char buffer[c2fb_large_static_buffer_size];\n"
        "    buffer[0] = 17;\n"
        "    buffer[c2fb_large_static_buffer_size - 1] = 29;\n"
        "    return buffer[0] + buffer[c2fb_large_static_buffer_size - 1]\n"
        "        + sizeof buffer;\n"
        "}\n"
        "/* end of local_sizeof.c */\n"
        "int c2fbReadRecordArraySizeofBound(void) {\n"
        "    c2fb_wide_vector_alias buffer[(1 << 16) /\n"
        "        sizeof(c2fb_wide_vector_alias)];\n"
        "    return sizeof buffer;\n"
        "}\n"
    )
    candidate = source_directory / "local_sizeof_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        (
            "--header-option=--emit-source=*",
            "--header-option=--type-map=c2fb_wide_vector_alias=c2fb_c2fb_wide_vector",
            "--body-option=--type-map=c2fb_wide_vector_alias=c2fb_c2fb_wide_vector",
            "--header-compiler-option=-std=gnu2x",
            "--body-compiler-option=-std=gnu2x",
        ),
    )
    assert "translated 3 simple functions; skipped 0" in summary, summary

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu2x", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbReadLocalArraySizeofBound.restype = ctypes.c_int
            library.c2fbReadRecordArraySizeofBound.restype = ctypes.c_int
            library.c2fbReadLargeStaticArray.restype = ctypes.c_int
        expected = reference.c2fbReadLocalArraySizeofBound()
        actual = converted.c2fbReadLocalArraySizeofBound()
        assert actual == expected == 23, (backend, expected, actual)
        expected = reference.c2fbReadRecordArraySizeofBound()
        actual = converted.c2fbReadRecordArraySizeofBound()
        assert actual == expected == 65536, (backend, expected, actual)
        expected = reference.c2fbReadLargeStaticArray()
        actual = converted.c2fbReadLargeStaticArray()
        assert actual == expected == 262190, (backend, expected, actual)

    compile_and_compare("local-array-sizeof-bound", source_directory,
                        candidate, reference_path, fbc, check)


def check_local_alignas_array(converter, fbc, cc, work):
    source_directory = work / "local-alignas-array"
    source_directory.mkdir()
    source = source_directory / "local_alignas.c"
    source.write_text(
        "#include <stdalign.h>\n"
        "#include <stdint.h>\n"
        "int c2fbReadAlignedLocalArray(void) {\n"
        "    alignas(16) unsigned char bytes[32];\n"
        "    bytes[0] = 18;\n"
        "    bytes[31] = 52;\n"
        "    return (int)(((uintptr_t) bytes & 15) * 10000)\n"
        "        + bytes[0] * 100 + bytes[31] + sizeof bytes;\n"
        "}\n"
        "int c2fbReadAlignedLargeLocalArray(void) {\n"
        "    alignas(16) unsigned char bytes[262144];\n"
        "    bytes[0] = 18;\n"
        "    bytes[262143] = 52;\n"
        "    return (int)(((uintptr_t) bytes & 15) * 10000)\n"
        "        + bytes[0] * 100 + bytes[262143] + sizeof bytes;\n"
        "}\n"
    )
    candidate = source_directory / "local_alignas_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        (
            "--header-option=--type-map=size_t=CULong",
            "--body-option=--type-map=size_t=CULong",
            "--header-compiler-option=-std=gnu11",
            "--body-compiler-option=-std=gnu11",
        ),
    )
    assert "translated 2 simple functions" in summary and \
        "skipped 0" in summary, summary
    generated = candidate.read_text(encoding="utf-8")
    assert "c2fb_local_alignment_storage_" in generated, generated

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbReadAlignedLocalArray.restype = ctypes.c_int
            library.c2fbReadAlignedLargeLocalArray.restype = ctypes.c_int
        expected = reference.c2fbReadAlignedLocalArray()
        actual = converted.c2fbReadAlignedLocalArray()
        assert expected == actual == 1884, (backend, expected, actual)
        expected = reference.c2fbReadAlignedLargeLocalArray()
        actual = converted.c2fbReadAlignedLargeLocalArray()
        assert expected == actual == 263996, (backend, expected, actual)

    compile_and_compare("local-alignas-array", source_directory,
                        candidate, reference_path, fbc, check)


def check_file_scope_anonymous_enum_object(converter, fbc, cc, work):
    source_directory = work / "file-scope-anonymous-enum-object"
    source_directory.mkdir()
    source = source_directory / "anonymous_enum.c"
    source.write_text(
        "static enum {\n"
        "    C2FB_MODE_DEFAULT = 0,\n"
        "    C2FB_MODE_DOT_AND_DOTDOT,\n"
        "    C2FB_MODE_MINIMAL\n"
        "} c2fb_mode;\n"
        "void c2fbSetAnonymousEnumMode(void) {\n"
        "    c2fb_mode = C2FB_MODE_MINIMAL;\n"
        "}\n"
        "int c2fbReadAnonymousEnumMode(void) { return c2fb_mode; }\n"
    )
    candidate = source_directory / "anonymous_enum_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        (
            "--header-option=--emit-source=*",
            "--body-option=--include-global-definitions",
            "--body-option=--include-included-c-source-bodies",
        ),
    )
    assert "translated 2 simple functions; skipped 0" in summary, summary

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbSetAnonymousEnumMode.restype = None
            library.c2fbReadAnonymousEnumMode.restype = ctypes.c_int
            library.c2fbSetAnonymousEnumMode()
        expected = reference.c2fbReadAnonymousEnumMode()
        actual = converted.c2fbReadAnonymousEnumMode()
        assert actual == expected == 2, (backend, expected, actual)

    compile_and_compare("file-scope-anonymous-enum-object", source_directory,
                        candidate, reference_path, fbc, check)


def check_static_record_array_compound_literals(converter, fbc, cc, work):
    source_directory = work / "static-record-array-compound-literals"
    source_directory.mkdir()
    source = source_directory / "record_array.c"
    source.write_text(
        "#include <stddef.h>\n"
        "struct c2fb_bin_str { size_t length; const char *text; };\n"
        "static struct c2fb_bin_str c2fb_color_table[] = {\n"
        "    { 2, (char const []) { '\\033', '[' } },\n"
        "    { 1, (char const []) { 'm' } },\n"
        "    { 0, (void *) 0 }\n"
        "};\n"
        "int c2fbReadColorByte(int index, int offset) {\n"
        "    if (index < 0 || index >= 3) return -1;\n"
        "    if (offset < 0 || (size_t) offset >= c2fb_color_table[index].length)\n"
        "        return -2;\n"
        "    return (unsigned char) c2fb_color_table[index].text[offset];\n"
        "}\n"
    )
    candidate = source_directory / "record_array_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        (
            "--header-option=--emit-source=*",
            "--body-option=--include-global-definitions",
            "--body-option=--include-included-c-source-bodies",
        ),
    )
    assert "translated 1 simple functions; skipped 0" in summary, summary

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbReadColorByte.argtypes = [ctypes.c_int, ctypes.c_int]
            library.c2fbReadColorByte.restype = ctypes.c_int
        for index, offset in ((0, 0), (0, 1), (1, 0), (2, 0), (3, 0), (0, -1)):
            expected = reference.c2fbReadColorByte(index, offset)
            actual = converted.c2fbReadColorByte(index, offset)
            assert actual == expected, (
                backend, index, offset, expected, actual
            )

    compile_and_compare("static-record-array-compound-literals",
                        source_directory, candidate, reference_path, fbc, check)


def check_multidimensional_array_parameter(converter, fbc, cc, work):
    source_directory = work / "multidimensional-array-parameter"
    source_directory.mkdir()
    source = source_directory / "array_parameter.c"
    source.write_text(
        "unsigned char c2fbStoreAndReadMatrix(\n"
        "    unsigned char matrix[3][5], int row, int column,\n"
        "    unsigned char value) {\n"
        "    matrix[row][column] = value;\n"
        "    return matrix[row][column];\n"
        "}\n"
    )
    candidate = source_directory / "array_parameter_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        ("--header-option=--emit-source=*",),
    )
    assert "translated 1 simple functions; skipped 0" in summary, summary

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbStoreAndReadMatrix.argtypes = [
                ctypes.POINTER(ctypes.c_ubyte), ctypes.c_int, ctypes.c_int,
                ctypes.c_ubyte,
            ]
            library.c2fbStoreAndReadMatrix.restype = ctypes.c_ubyte
        positions = ((0, 0), (1, 4), (2, 3))
        reference_matrix = (ctypes.c_ubyte * 15)()
        converted_matrix = (ctypes.c_ubyte * 15)()
        for value, (row, column) in zip((13, 97, 241), positions):
            expected = reference.c2fbStoreAndReadMatrix(
                reference_matrix, row, column, value
            )
            actual = converted.c2fbStoreAndReadMatrix(
                converted_matrix, row, column, value
            )
            assert actual == expected == value, (
                backend, row, column, expected, actual
            )
            assert converted_matrix[row * 5 + column] == value, (
                backend, row, column, converted_matrix[row * 5 + column]
            )

    compile_and_compare("multidimensional-array-parameter", source_directory,
                        candidate, reference_path, fbc, check)


def check_local_array_passed_to_multidimensional_parameter(
        converter, fbc, cc, work):
    source_directory = work / "local-array-to-multidimensional-parameter"
    source_directory.mkdir()
    source = source_directory / "array_parameter_call.c"
    source.write_text(
        "static unsigned char c2fbReadMatrix(unsigned char matrix[3][5]) {\n"
        "    matrix[1][4] = 73;\n"
        "    return matrix[1][4];\n"
        "}\n"
        "int c2fbCallMatrix(void) {\n"
        "    unsigned char matrix[3][5];\n"
        "    return c2fbReadMatrix(matrix);\n"
        "}\n"
    )
    candidate = source_directory / "array_parameter_call_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        ("--header-option=--emit-source=*",),
    )
    assert "translated 2 simple functions; skipped 0" in summary, summary

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbCallMatrix.restype = ctypes.c_int
        expected = reference.c2fbCallMatrix()
        actual = converted.c2fbCallMatrix()
        assert actual == expected == 73, (backend, expected, actual)

    compile_and_compare("local-array-to-multidimensional-parameter",
                        source_directory, candidate, reference_path, fbc, check)


def check_named_header_inline_body(converter, fbc, cc, work):
    source_directory = work / "named-header-inline-body"
    source_directory.mkdir()
    header = source_directory / "helper.h"
    header.write_text(
        "static inline int c2fbHeaderInlineHelper(int value) {\n"
        "    return value * 3 + 1;\n"
        "}\n"
    )
    source = source_directory / "inline_body.c"
    source.write_text(
        '#include "helper.h"\n'
        "int c2fbReadHeaderInline(int value) {\n"
        "    return c2fbHeaderInlineHelper(value);\n"
        "}\n"
    )
    candidate = source_directory / "inline_body_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        (
            "--header-option=--emit-source=*",
            "--body-option=--include-header-inline-body=c2fbHeaderInlineHelper",
            "--body-option=--include-global-definitions",
            "--body-option=--include-included-c-source-bodies",
        ),
    )
    assert "translated 2 simple functions; skipped 0" in summary, summary

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbReadHeaderInline.argtypes = [ctypes.c_int]
            library.c2fbReadHeaderInline.restype = ctypes.c_int
        for value in (-23, 0, 14):
            expected = reference.c2fbReadHeaderInline(value)
            actual = converted.c2fbReadHeaderInline(value)
            assert actual == expected == value * 3 + 1, (
                backend, value, expected, actual
            )

    compile_and_compare("named-header-inline-body", source_directory,
                        candidate, reference_path, fbc, check)


def check_multidimensional_array_storage(converter, fbc, cc, work):
    source_text = (
        "{storage}unsigned char c2fb_matrix[2][3][4];\n"
        "void c2fbWriteMatrix(int i, int j, int k, unsigned char value) {\n"
        "    c2fb_matrix[i][j][k] = value;\n"
        "}\n"
        "unsigned char c2fbReadMatrix(int i, int j, int k) {\n"
        "    return c2fb_matrix[i][j][k];\n"
        "}\n"
        "unsigned char *c2fbMatrixRow(int i, int j) {\n"
        "    return c2fb_matrix[i][j];\n"
        "}\n"
    )

    for storage, body_options in (
        ("", ("--body-option=--include-global-definitions",)),
        ("static ", (
            "--body-option=--include-global-definitions",
            "--body-option=--include-included-c-source-bodies",
        )),
    ):
        name = "body-global-multidimensional" if storage == "" \
            else "header-static-multidimensional"
        source_directory = work / name
        source_directory.mkdir()
        source = source_directory / "matrix.c"
        source.write_text(source_text.replace("{storage}", storage))
        candidate = source_directory / "matrix_candidates.bas"
        summary = translate_source_unit(
            converter, cc, source_directory, source, candidate, body_options,
        )
        assert "translated 3 simple functions; skipped 0" in summary, summary
        reference_path = source_directory / "reference.so"
        run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
                  "-o", reference_path], cwd=source_directory)

        def check(reference, converted, backend):
            for library in (reference, converted):
                library.c2fbWriteMatrix.argtypes = [
                    ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ubyte
                ]
                library.c2fbReadMatrix.argtypes = [
                    ctypes.c_int, ctypes.c_int, ctypes.c_int
                ]
                library.c2fbReadMatrix.restype = ctypes.c_ubyte
                library.c2fbMatrixRow.argtypes = [ctypes.c_int, ctypes.c_int]
                library.c2fbMatrixRow.restype = ctypes.POINTER(ctypes.c_ubyte)
            for row in range(2):
                for column in range(3):
                    for item in range(4):
                        value = (row * 37 + column * 11 + item * 3) & 255
                        reference.c2fbWriteMatrix(row, column, item, value)
                        converted.c2fbWriteMatrix(row, column, item, value)
                        assert reference.c2fbReadMatrix(row, column, item) == \
                            converted.c2fbReadMatrix(row, column, item) == value
                    expected_row = bytes(
                        reference.c2fbMatrixRow(row, column)[item]
                        for item in range(4)
                    )
                    actual_row = bytes(
                        converted.c2fbMatrixRow(row, column)[item]
                        for item in range(4)
                    )
                    assert actual_row == expected_row, (backend, row, column)

        compile_and_compare(name, source_directory, candidate, reference_path,
                            fbc, check)

    source_directory = work / "local-multidimensional"
    source_directory.mkdir()
    source = source_directory / "local_matrix.c"
    source.write_text(
        "int c2fbLocalMatrix(int row, int column) {\n"
        "    int values[2][3];\n"
        "    values[row][column] = 42;\n"
        "    return values[row][column];\n"
        "}\n"
    )
    candidate = source_directory / "local_matrix_candidates.bas"
    run([converter, "translate-simple-generic-c", str(source),
         str(candidate), *cc], cwd=source_directory)
    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check_local(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbLocalMatrix.argtypes = [ctypes.c_int, ctypes.c_int]
            library.c2fbLocalMatrix.restype = ctypes.c_int
        for row, column in ((0, 0), (1, 2)):
            assert reference.c2fbLocalMatrix(row, column) == \
                converted.c2fbLocalMatrix(row, column) == 42, (backend, row, column)

    compile_and_compare("local-multidimensional", source_directory,
                        candidate, reference_path, fbc, check_local)


def check_gnu_pointer_alias_statement_expression(converter, fbc, cc, work):
    source_directory = work / "gnu-pointer-alias-statement-expression"
    source_directory.mkdir()
    source = source_directory / "pointer_alias_statement_expression.c"
    source.write_text(
        "#include <stddef.h>\n"
        "struct c2fb_obstack_view { char *next_free; char *object_base; };\n"
        "size_t c2fbObjectSize(struct c2fb_obstack_view *h) {\n"
        "    return __extension__ ({\n"
        "        struct c2fb_obstack_view const *__o = (h);\n"
        "        (size_t) (__o->next_free - __o->object_base);\n"
        "    });\n"
        "}\n"
        "size_t c2fbObjectSizeDivided(struct c2fb_obstack_view *h) {\n"
        "    size_t count;\n"
        "    count = __extension__ ({\n"
        "        struct c2fb_obstack_view const *__o = (h);\n"
        "        (size_t) (__o->next_free - __o->object_base);\n"
        "    }) / 2;\n"
        "    return count;\n"
        "}\n"
        "struct c2fb_token_context { struct c2fb_obstack_view o_data; };\n"
        "size_t c2fbObjectSizeFromMember(struct c2fb_token_context *t) {\n"
        "    return __extension__ ({\n"
        "        struct c2fb_obstack_view const *__o = (&t->o_data);\n"
        "        (size_t) (__o->next_free - __o->object_base);\n"
        "    }) - 1;\n"
        "}\n"
    )
    candidate = source_directory / "pointer_alias_statement_expression_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
    )
    assert "translated 3 simple functions" in summary and \
        "skipped 0" in summary, summary
    assert "__extension__" not in candidate.read_text()
    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check_object_size(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbObjectSize.argtypes = [ctypes.c_void_p]
            library.c2fbObjectSize.restype = ctypes.c_size_t
            library.c2fbObjectSizeDivided.argtypes = [ctypes.c_void_p]
            library.c2fbObjectSizeDivided.restype = ctypes.c_size_t
            library.c2fbObjectSizeFromMember.argtypes = [ctypes.c_void_p]
            library.c2fbObjectSizeFromMember.restype = ctypes.c_size_t
        storage = ctypes.create_string_buffer(64)
        for start, end in ((0, 1), (3, 19), (42, 63)):
            view = (ctypes.c_void_p * 2)(
                ctypes.addressof(storage) + end,
                ctypes.addressof(storage) + start,
            )
            reference_value = reference.c2fbObjectSize(ctypes.byref(view))
            converted_value = converted.c2fbObjectSize(ctypes.byref(view))
            assert reference_value == converted_value == end - start, (
                backend, start, end, reference_value, converted_value)
            reference_divided_value = reference.c2fbObjectSizeDivided(
                ctypes.byref(view))
            divided_value = converted.c2fbObjectSizeDivided(ctypes.byref(view))
            assert reference_divided_value == divided_value == \
                (end - start) // 2, (
                    backend, start, end, reference_divided_value,
                    divided_value)
            member_view = (ctypes.c_void_p * 2)(
                ctypes.addressof(storage) + end,
                ctypes.addressof(storage) + start,
            )
            reference_member_value = reference.c2fbObjectSizeFromMember(
                ctypes.byref(member_view))
            converted_member_value = converted.c2fbObjectSizeFromMember(
                ctypes.byref(member_view))
            assert reference_member_value == converted_member_value == \
                end - start - 1, (
                    backend, start, end, reference_member_value,
                    converted_member_value)

    compile_and_compare("gnu-pointer-alias-statement-expression",
                        source_directory, candidate, reference_path, fbc,
                        check_object_size)

    side_effect_directory = work / "gnu-statement-expression-side-effect"
    side_effect_directory.mkdir()
    side_effect_source = side_effect_directory / "side_effect.c"
    side_effect_source.write_text(
        "#include <stddef.h>\n"
        "struct c2fb_obstack_view { char *next_free; char *object_base; };\n"
        "extern struct c2fb_obstack_view *c2fbNextView(\n"
        "    struct c2fb_obstack_view *);\n"
        "size_t c2fbObjectSizeWithCall(struct c2fb_obstack_view *h) {\n"
        "    return __extension__ ({\n"
        "        struct c2fb_obstack_view const *__o = c2fbNextView(h);\n"
        "        (size_t) (__o->next_free - __o->object_base);\n"
        "    });\n"
        "}\n"
    )
    side_effect_candidate = side_effect_directory / "side_effect_candidates.bas"
    side_effect_summary = translate_source_unit(
        converter, cc, side_effect_directory, side_effect_source,
        side_effect_candidate,
    )
    assert "translated 0 simple functions; skipped 1" in side_effect_summary, \
        side_effect_summary
    assert "c2fb skipped c2fbObjectSizeWithCall:" in \
        side_effect_candidate.read_text()

    ignored_result_directory = work / "gnu-ignore-value-statement-expression"
    ignored_result_directory.mkdir()
    ignored_result_source = ignored_result_directory / "ignore_value.c"
    ignored_result_source.write_text(
        "#define ignore_value(x) (__extension__ ({ "
        "__typeof__ (x) __x = (x); (void) __x; }))\n"
        "int c2fbNextWithCounter(int *counter) "
        "__attribute__ ((__warn_unused_result__));\n"
        "int c2fbNextWithCounter(int *counter) { return ++*counter; }\n"
        "int c2fbIgnoreResult(int *counter) {\n"
        "    ignore_value(c2fbNextWithCounter(counter));\n"
        "    return *counter;\n"
        "}\n"
    )
    ignored_result_candidate = ignored_result_directory / \
        "ignore_value_candidates.bas"
    ignored_result_summary = translate_source_unit(
        converter, cc, ignored_result_directory, ignored_result_source,
        ignored_result_candidate,
    )
    assert "translated 2 simple functions" in ignored_result_summary and \
        "skipped 0" in ignored_result_summary, ignored_result_summary

    ignored_result_reference = ignored_result_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", ignored_result_source,
              "-o", ignored_result_reference], cwd=ignored_result_directory)

    def check_ignored_result(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbIgnoreResult.argtypes = [ctypes.POINTER(ctypes.c_int)]
            library.c2fbIgnoreResult.restype = ctypes.c_int
        for initial_count in (-9, 0, 27):
            reference_count = ctypes.c_int(initial_count)
            converted_count = ctypes.c_int(initial_count)
            reference_value = reference.c2fbIgnoreResult(
                ctypes.byref(reference_count))
            converted_value = converted.c2fbIgnoreResult(
                ctypes.byref(converted_count))
            expected = initial_count + 1
            assert (reference_value, reference_count.value) == \
                (converted_value, converted_count.value) == (expected, expected), (
                    backend, initial_count, reference_value, reference_count.value,
                    converted_value, converted_count.value,
                )

    compile_and_compare(
        "gnu-ignore-value-statement-expression", ignored_result_directory,
        ignored_result_candidate, ignored_result_reference, fbc,
        check_ignored_result,
    )


def check_unused_local_attribute(converter, fbc, cc, work):
    source_directory = work / "unused-local-attribute"
    source_directory.mkdir()
    source = source_directory / "unused_local_attribute.c"
    source.write_text(
        "int c2fbUnusedLocalAttribute(void) {\n"
        "    __attribute__ ((__unused__)) int local_value = 7;\n"
        "    return 42;\n"
        "}\n"
        "int c2fbStaticNonstringArray(void) {\n"
        "    static const char letters[4] "
        "__attribute__ ((__nonstring__)) = \"WXYZ\";\n"
        "    return letters[0] + letters[3];\n"
        "}\n"
        "int c2fbAutomaticNonstringArray(void) {\n"
        "    char padbuf[8] __attribute__ ((__nonstring__)) = \"========\";\n"
        "    return padbuf[0] + padbuf[7];\n"
        "}\n"
    )
    candidate = source_directory / "unused_local_attribute_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
    )
    assert "translated 3 simple functions" in summary and \
        "skipped 0" in summary, summary
    assert "__attribute__" not in candidate.read_text()
    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbUnusedLocalAttribute.argtypes = []
            library.c2fbUnusedLocalAttribute.restype = ctypes.c_int
            library.c2fbStaticNonstringArray.argtypes = []
            library.c2fbStaticNonstringArray.restype = ctypes.c_int
            library.c2fbAutomaticNonstringArray.argtypes = []
            library.c2fbAutomaticNonstringArray.restype = ctypes.c_int
        assert reference.c2fbUnusedLocalAttribute() == \
            converted.c2fbUnusedLocalAttribute() == 42, backend
        assert reference.c2fbStaticNonstringArray() == \
            converted.c2fbStaticNonstringArray() == ord("W") + ord("Z"), backend
        assert reference.c2fbAutomaticNonstringArray() == \
            converted.c2fbAutomaticNonstringArray() == 2 * ord("="), backend

    compile_and_compare("unused-local-attribute", source_directory,
                        candidate, reference_path, fbc, check)


def check_obstack_finish_statement_expression(converter, fbc, cc, work):
    source_directory = work / "obstack-finish-statement-expression"
    source_directory.mkdir()
    source = source_directory / "obstack_finish.c"
    source.write_text(
        "struct obstack {\n"
        "    char *object_base;\n"
        "    char *next_free;\n"
        "    unsigned long alignment_mask;\n"
        "    unsigned int maybe_empty_object;\n"
        "};\n"
        "void *c2fbObstackFinish(struct obstack *os) {\n"
        "    return __extension__ ({\n"
        "        struct obstack *__o1 = (os);\n"
        "        void *__value = (void *) __o1->object_base;\n"
        "        if (__o1->next_free == __value)\n"
        "            __o1->maybe_empty_object = 1;\n"
        "        __o1->next_free = ((__o1->next_free) +\n"
        "            ((- (long unsigned int) (__o1->next_free)) &\n"
        "             (__o1->alignment_mask)));\n"
        "        __o1->object_base = __o1->next_free;\n"
        "        __value;\n"
        "    });\n"
        "}\n"
        "struct c2fb_obstack_record {\n"
        "    char *object_base;\n"
        "    char *next_free;\n"
        "    unsigned long alignment_mask;\n"
        "    unsigned int maybe_empty_object;\n"
        "};\n"
        "typedef struct c2fb_obstack_record c2fb_obstack;\n"
        "void *c2fbObstackFinishCanonical(c2fb_obstack *os) {\n"
        "    return __extension__ ({\n"
        "        c2fb_obstack *__o1 = (os);\n"
        "        void *__value = (void *) __o1->object_base;\n"
        "        if (__o1->next_free == __value)\n"
        "            __o1->maybe_empty_object = 1;\n"
        "        __o1->next_free = ((__o1->next_free) +\n"
        "            ((- (long unsigned int) (__o1->next_free)) &\n"
        "             (__o1->alignment_mask)));\n"
        "        __o1->object_base = __o1->next_free;\n"
        "        __value;\n"
        "    });\n"
        "}\n"
    )
    candidate = source_directory / "obstack_finish_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
    )
    assert "translated 2 simple functions" in summary and \
        "skipped 0" in summary, summary
    assert "Private Function c2fb_obstack_finish_c2fbObstackFinish" in \
        candidate.read_text()
    assert "Private Function " \
        "c2fb_obstack_finish_c2fbObstackFinishCanonical" in \
        candidate.read_text()
    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    class Obstack(ctypes.Structure):
        _fields_ = [
            ("object_base", ctypes.c_void_p),
            ("next_free", ctypes.c_void_p),
            ("alignment_mask", ctypes.c_ulong),
            ("maybe_empty_object", ctypes.c_uint),
        ]

    def check(reference, converted, backend):
        function_names = (
            "c2fbObstackFinish",
            "c2fbObstackFinishCanonical",
        )
        for library in (reference, converted):
            for function_name in function_names:
                function = getattr(library, function_name)
                function.argtypes = [ctypes.POINTER(Obstack)]
                function.restype = ctypes.c_void_p
        storage = ctypes.create_string_buffer(128)
        base_address = ctypes.addressof(storage)
        for base_offset, next_offset, alignment_mask, initially_empty in (
            (5, 10, 15, 0),
            (20, 20, 15, 0),
            (33, 39, 7, 0),
        ):
            for function_name in function_names:
                reference_state = Obstack(
                    base_address + base_offset, base_address + next_offset,
                    alignment_mask, initially_empty)
                converted_state = Obstack(
                    base_address + base_offset, base_address + next_offset,
                    alignment_mask, initially_empty)
                reference_value = getattr(reference, function_name)(
                    ctypes.byref(reference_state))
                converted_value = getattr(converted, function_name)(
                    ctypes.byref(converted_state))
                expected_next = (base_address + next_offset + alignment_mask) & \
                    ~alignment_mask
                assert reference_value == converted_value == \
                    base_address + base_offset, (backend, function_name, "value")
                assert reference_state.next_free == \
                    converted_state.next_free == expected_next, (
                        backend, function_name, "next_free",
                        reference_state.next_free, converted_state.next_free,
                        expected_next)
                assert reference_state.object_base == \
                    converted_state.object_base == expected_next, (
                        backend, function_name, "base")
                assert reference_state.maybe_empty_object == \
                    converted_state.maybe_empty_object == \
                    int(base_offset == next_offset), (
                        backend, function_name, "empty")

    compile_and_compare("obstack-finish-statement-expression",
                        source_directory, candidate, reference_path, fbc, check)


def check_obstack_blank_statement_expression(converter, fbc, cc, work):
    source_directory = work / "obstack-blank-statement-expression"
    source_directory.mkdir()
    source = source_directory / "obstack_blank.c"
    source.write_text(
        "#include <stddef.h>\n"
        "#include <string.h>\n"
        "struct obstack {\n"
        "    char *object_base;\n"
        "    char *next_free;\n"
        "    char *chunk_limit;\n"
        "    unsigned long alignment_mask;\n"
        "    unsigned int maybe_empty_object;\n"
        "};\n"
        "void rpl_obstack_newchunk(struct obstack *h, size_t length) {\n"
        "    h->chunk_limit = h->next_free + length + 16;\n"
        "}\n"
        "void c2fbObstackBlank(struct obstack *h, size_t length) {\n"
        "    __extension__ ({\n"
        "        struct obstack *__o = (h);\n"
        "        size_t __len = length;\n"
        "        if (__extension__ ({\n"
        "            struct obstack const *__o1 = (__o);\n"
        "            (size_t) (__o1->chunk_limit - __o1->next_free);\n"
        "        }) < __len)\n"
        "            rpl_obstack_newchunk(__o, __len);\n"
        "        ((__o)->next_free += (__len));\n"
        "        (void) 0;\n"
        "    });\n"
        "}\n"
    )
    candidate = source_directory / "obstack_blank_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
    )
    assert "translated 2 simple functions" in summary and \
        "skipped 0" in summary, summary
    assert "Private Function c2fb_obstack_blank_c2fbObstackBlank" in \
        candidate.read_text()
    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    class Obstack(ctypes.Structure):
        _fields_ = [
            ("object_base", ctypes.c_void_p),
            ("next_free", ctypes.c_void_p),
            ("chunk_limit", ctypes.c_void_p),
            ("alignment_mask", ctypes.c_ulong),
            ("maybe_empty_object", ctypes.c_uint),
        ]

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbObstackBlank.argtypes = [
                ctypes.POINTER(Obstack), ctypes.c_size_t
            ]
            library.c2fbObstackBlank.restype = None
        storage = ctypes.create_string_buffer(160)
        base_address = ctypes.addressof(storage)
        for available, length in ((40, 4), (2, 8)):
            reference_state = Obstack(
                base_address + 2, base_address + 10,
                base_address + 10 + available, 15, 0)
            converted_state = Obstack(
                base_address + 2, base_address + 10,
                base_address + 10 + available, 15, 0)
            reference.c2fbObstackBlank(ctypes.byref(reference_state), length)
            converted.c2fbObstackBlank(ctypes.byref(converted_state), length)
            assert converted_state.object_base == reference_state.object_base, (
                backend, "object_base")
            assert converted_state.next_free == reference_state.next_free, (
                backend, available, length, "next_free",
                reference_state.next_free, converted_state.next_free)
            assert converted_state.chunk_limit == reference_state.chunk_limit, (
                backend, available, length, "chunk_limit",
                reference_state.chunk_limit, converted_state.chunk_limit)

    compile_and_compare("obstack-blank-statement-expression",
                        source_directory, candidate, reference_path, fbc, check)


def check_obstack_grow_statement_expression(converter, fbc, cc, work):
    source_directory = work / "obstack-grow-statement-expression"
    source_directory.mkdir()
    source = source_directory / "obstack_grow.c"
    source.write_text(
        "#include <stddef.h>\n"
        "#include <string.h>\n"
        "struct obstack {\n"
        "    char *object_base;\n"
        "    char *next_free;\n"
        "    char *chunk_limit;\n"
        "    unsigned long alignment_mask;\n"
        "    unsigned int maybe_empty_object;\n"
        "};\n"
        "struct c2fbObstackOwner { struct obstack obs; };\n"
        "static long c2fbDiredPosition = 987654321;\n"
        "void rpl_obstack_newchunk(struct obstack *h, size_t length) {\n"
        "    h->chunk_limit = h->next_free + length + 16;\n"
        "}\n"
        "void c2fbObstackGrow(struct obstack *h) {\n"
        "    __extension__ ({\n"
        "        struct obstack *__o = (h);\n"
        "        size_t __len = sizeof c2fbDiredPosition;\n"
        "        if (__extension__ ({\n"
        "            struct obstack const *__o1 = (__o);\n"
        "            (size_t) (__o1->chunk_limit - __o1->next_free);\n"
        "        }) < __len)\n"
        "            rpl_obstack_newchunk(__o, __len);\n"
        "        memcpy(__o->next_free, &c2fbDiredPosition, __len);\n"
        "        __o->next_free += __len;\n"
        "        (void) 0;\n"
        "    });\n"
        "}\n"
        "void c2fbObstackGrowLocal(struct obstack *h) {\n"
        "    size_t localValue = 305419896;\n"
        "    __extension__ ({\n"
        "        struct obstack *__o = (h);\n"
        "        size_t __len = sizeof localValue;\n"
        "        if (__extension__ ({\n"
        "            struct obstack const *__o1 = (__o);\n"
        "            (size_t) (__o1->chunk_limit - __o1->next_free);\n"
        "        }) < __len)\n"
        "            rpl_obstack_newchunk(__o, __len);\n"
        "        memcpy(__o->next_free, &localValue, __len);\n"
        "        __o->next_free += __len;\n"
        "        (void) 0;\n"
        "    });\n"
        "}\n"
        "void c2fbObstackGrowMember(struct c2fbObstackOwner *owner) {\n"
        "    long localValue = 7654321;\n"
        "    __extension__ ({\n"
        "        struct obstack *__o = ((&(owner->obs)));\n"
        "        size_t __len = sizeof localValue;\n"
        "        if (__extension__ ({\n"
        "            struct obstack const *__o1 = (__o);\n"
        "            (size_t) (__o1->chunk_limit - __o1->next_free);\n"
        "        }) < __len)\n"
        "            rpl_obstack_newchunk(__o, __len);\n"
        "        memcpy(__o->next_free, &localValue, __len);\n"
        "        __o->next_free += __len;\n"
        "        (void) 0;\n"
        "    });\n"
        "}\n"
    )
    candidate = source_directory / "obstack_grow_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
        ("--body-option=--include-global-definitions",),
    )
    assert "translated 4 simple functions" in summary and \
        "skipped 0" in summary, summary
    assert "Private Function c2fb_obstack_grow_c2fbObstackGrow" in \
        candidate.read_text()
    assert "Private Function c2fb_obstack_grow_c2fbObstackGrowLocal" in \
        candidate.read_text()
    assert "Private Function c2fb_obstack_grow_c2fbObstackGrowMember" in \
        candidate.read_text()
    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    class Obstack(ctypes.Structure):
        _fields_ = [
            ("object_base", ctypes.c_void_p),
            ("next_free", ctypes.c_void_p),
            ("chunk_limit", ctypes.c_void_p),
            ("alignment_mask", ctypes.c_ulong),
            ("maybe_empty_object", ctypes.c_uint),
        ]

    class ObstackOwner(ctypes.Structure):
        _fields_ = [("obs", Obstack)]

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbObstackGrow.argtypes = [ctypes.POINTER(Obstack)]
            library.c2fbObstackGrow.restype = None
            library.c2fbObstackGrowLocal.argtypes = [ctypes.POINTER(Obstack)]
            library.c2fbObstackGrowLocal.restype = None
            library.c2fbObstackGrowMember.argtypes = [
                ctypes.POINTER(ObstackOwner)
            ]
            library.c2fbObstackGrowMember.restype = None
        storage = ctypes.create_string_buffer(160)
        base_address = ctypes.addressof(storage)
        object_bytes = ctypes.string_at(
            ctypes.byref(ctypes.c_long(987654321)), ctypes.sizeof(ctypes.c_long))
        for available in (32, 2):
            reference_state = Obstack(
                base_address + 1, base_address + 32,
                base_address + 32 + available, 15, 0)
            converted_state = Obstack(
                base_address + 1, base_address + 32,
                base_address + 32 + available, 15, 0)
            reference.c2fbObstackGrow(ctypes.byref(reference_state))
            converted.c2fbObstackGrow(ctypes.byref(converted_state))
            assert reference_state.next_free == converted_state.next_free == \
                base_address + 32 + ctypes.sizeof(ctypes.c_long), (
                    backend, available, "next_free")
            assert reference_state.chunk_limit == converted_state.chunk_limit, (
                backend, available, "chunk_limit")
            target_offset = 32
            assert storage.raw[target_offset:target_offset + len(object_bytes)] == \
                object_bytes, (backend, available, "copied bytes")

            reference_local = Obstack(
                base_address + 1, base_address + 32,
                base_address + 32 + available, 15, 0)
            converted_local = Obstack(
                base_address + 1, base_address + 32,
                base_address + 32 + available, 15, 0)
            reference.c2fbObstackGrowLocal(ctypes.byref(reference_local))
            converted.c2fbObstackGrowLocal(ctypes.byref(converted_local))
            local_bytes = ctypes.string_at(
                ctypes.byref(ctypes.c_size_t(305419896)),
                ctypes.sizeof(ctypes.c_size_t))
            expected_next = base_address + 32 + ctypes.sizeof(ctypes.c_size_t)
            assert reference_local.next_free == converted_local.next_free == \
                expected_next, (backend, available, "local next_free")
            assert reference_local.chunk_limit == converted_local.chunk_limit, (
                backend, available, "local chunk_limit")
            assert storage.raw[target_offset:target_offset + len(local_bytes)] == \
                local_bytes, (backend, available, "local bytes")

        member_storage = ctypes.create_string_buffer(160)
        member_base = ctypes.addressof(member_storage)
        member_reference = ObstackOwner(Obstack(
            member_base + 1, member_base + 32, member_base + 33, 15, 0))
        member_converted = ObstackOwner(Obstack(
            member_base + 1, member_base + 32, member_base + 33, 15, 0))
        reference.c2fbObstackGrowMember(ctypes.byref(member_reference))
        converted.c2fbObstackGrowMember(ctypes.byref(member_converted))
        member_bytes = ctypes.string_at(
            ctypes.byref(ctypes.c_long(7654321)), ctypes.sizeof(ctypes.c_long))
        member_next = member_base + 32 + ctypes.sizeof(ctypes.c_long)
        assert member_reference.obs.next_free == \
            member_converted.obs.next_free == member_next, (backend, "member next_free")
        assert member_reference.obs.chunk_limit == \
            member_converted.obs.chunk_limit == member_next + 16, (
                backend, "member chunk_limit")
        assert member_storage.raw[32:32 + len(member_bytes)] == member_bytes, (
            backend, "member bytes")

    compile_and_compare("obstack-grow-statement-expression",
                        source_directory, candidate, reference_path, fbc, check)


def check_obstack_free_statement_expression(converter, fbc, cc, work):
    source_directory = work / "obstack-free-statement-expression"
    source_directory.mkdir()
    source = source_directory / "obstack_free.c"
    source.write_text(
        "struct obstack {\n"
        "    char *chunk;\n"
        "    char *object_base;\n"
        "    char *next_free;\n"
        "    char *chunk_limit;\n"
        "    int free_calls;\n"
        "};\n"
        "struct c2fbObstackOwner { struct obstack obs; };\n"
        "void rpl_obstack_free(struct obstack *h, void *obj) {\n"
        "    h->free_calls++;\n"
        "    h->object_base = (char *) obj;\n"
        "    h->next_free = (char *) obj;\n"
        "}\n"
        "#define _OBSTACK_CPTR char *\n"
        "#define obstack_free(OBSTACK, OBJ) __extension__ ({ \\\n"
        "    struct obstack *__o = (OBSTACK); \\\n"
        "    void *__obj = (OBJ); \\\n"
        "    if ((_OBSTACK_CPTR) __o->chunk < (_OBSTACK_CPTR) __obj \\\n"
        "        && (_OBSTACK_CPTR) __obj < (_OBSTACK_CPTR) __o->chunk_limit) \\\n"
        "        __o->next_free = __o->object_base = (char *) __obj; \\\n"
        "    else rpl_obstack_free (__o, __obj); })\n"
        "void c2fbObstackFree(struct obstack *h, void *obj) {\n"
        "    obstack_free(h, obj);\n"
        "}\n"
        "void c2fbObstackFreeField(struct c2fbObstackOwner *owner, void *obj) {\n"
        "    obstack_free((&(owner->obs)), obj);\n"
        "}\n"
    )
    candidate = source_directory / "obstack_free_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
    )
    assert "translated 3 simple functions" in summary and \
        "skipped 0" in summary, summary
    generated = candidate.read_text()
    assert "Private Function c2fb_obstack_free_c2fbObstackFree" in generated
    assert "Private Function c2fb_obstack_free_c2fbObstackFreeField" in generated
    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    class Obstack(ctypes.Structure):
        _fields_ = [
            ("chunk", ctypes.c_void_p),
            ("object_base", ctypes.c_void_p),
            ("next_free", ctypes.c_void_p),
            ("chunk_limit", ctypes.c_void_p),
            ("free_calls", ctypes.c_int),
        ]

    class ObstackOwner(ctypes.Structure):
        _fields_ = [("obs", Obstack)]

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbObstackFree.argtypes = [
                ctypes.POINTER(Obstack), ctypes.c_void_p,
            ]
            library.c2fbObstackFree.restype = None
            library.c2fbObstackFreeField.argtypes = [
                ctypes.POINTER(ObstackOwner), ctypes.c_void_p,
            ]
            library.c2fbObstackFreeField.restype = None
        storage = ctypes.create_string_buffer(160)
        base_address = ctypes.addressof(storage)
        for object_offset, expected_calls in ((32, 0), (96, 1)):
            reference_state = Obstack(
                base_address + 8, base_address + 16, base_address + 24,
                base_address + 64, 0,
            )
            converted_state = Obstack(
                base_address + 8, base_address + 16, base_address + 24,
                base_address + 64, 0,
            )
            object_value = base_address + object_offset
            reference.c2fbObstackFree(
                ctypes.byref(reference_state), object_value)
            converted.c2fbObstackFree(
                ctypes.byref(converted_state), object_value)
            assert converted_state.free_calls == \
                reference_state.free_calls == expected_calls, (backend, "free_calls")
            assert converted_state.object_base == reference_state.object_base == \
                object_value, (backend, "object_base")
            assert converted_state.next_free == reference_state.next_free == \
                object_value, (backend, "next_free")
            reference_owner = ObstackOwner(Obstack(
                base_address + 8, base_address + 16, base_address + 24,
                base_address + 64, 0,
            ))
            converted_owner = ObstackOwner(Obstack(
                base_address + 8, base_address + 16, base_address + 24,
                base_address + 64, 0,
            ))
            reference.c2fbObstackFreeField(
                ctypes.byref(reference_owner), object_value)
            converted.c2fbObstackFreeField(
                ctypes.byref(converted_owner), object_value)
            assert converted_owner.obs.free_calls == \
                reference_owner.obs.free_calls == expected_calls, (backend, "field free_calls")
            assert converted_owner.obs.object_base == \
                reference_owner.obs.object_base == object_value, (backend, "field object_base")
            assert converted_owner.obs.next_free == \
                reference_owner.obs.next_free == object_value, (backend, "field next_free")

    compile_and_compare("obstack-free-statement-expression", source_directory,
                        candidate, reference_path, fbc, check)


def check_obstack_pointer_and_single_grow_statement_expressions(
    converter, fbc, cc, work
):
    source_directory = work / "obstack-pointer-single-grow-statement-expressions"
    source_directory.mkdir()
    source = source_directory / "obstack_pointer_single_grow.c"
    source.write_text(
        "#include <stddef.h>\n"
        "#include <string.h>\n"
        "struct obstack {\n"
        "    char *object_base;\n"
        "    char *next_free;\n"
        "    char *chunk_limit;\n"
        "    unsigned long alignment_mask;\n"
        "    unsigned int maybe_empty_object;\n"
        "};\n"
        "void rpl_obstack_newchunk(struct obstack *h, size_t length) {\n"
        "    h->chunk_limit = h->next_free + length + 16;\n"
        "}\n"
        "void c2fbObstackPointerGrow(struct obstack *h, const void *value) {\n"
        "    __extension__ ({\n"
        "        struct obstack *__o = (h);\n"
        "        if (__extension__ ({\n"
        "            struct obstack const *__o1 = (__o);\n"
        "            (size_t) (__o1->chunk_limit - __o1->next_free);\n"
        "        }) < sizeof (void *))\n"
        "            rpl_obstack_newchunk(__o, sizeof (void *));\n"
        "        __extension__ ({\n"
        "            struct obstack *__o1 = (__o);\n"
        "            void *__p1 = __o1->next_free;\n"
        "            *(const void **) __p1 = (value);\n"
        "            __o1->next_free += sizeof (const void *);\n"
        "            (void) 0;\n"
        "        });\n"
        "    });\n"
        "}\n"
        "void c2fbObstackSingleGrow(struct obstack *h, int datum) {\n"
        "    __extension__ ({\n"
        "        struct obstack *__o = (h);\n"
        "        if (__extension__ ({\n"
        "            struct obstack const *__o1 = (__o);\n"
        "            (size_t) (__o1->chunk_limit - __o1->next_free);\n"
        "        }) < 1)\n"
        "            rpl_obstack_newchunk(__o, 1);\n"
        "        (*((__o)->next_free)++ = (datum));\n"
        "        (void) 0;\n"
        "    });\n"
        "}\n"
    )
    candidate = source_directory / "obstack_pointer_single_grow_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
    )
    assert "translated 3 simple functions" in summary and \
        "skipped 0" in summary, summary
    generated = candidate.read_text()
    assert "Private Function c2fb_obstack_ptr_grow_c2fbObstackPointerGrow" \
        in generated
    assert "Private Function c2fb_obstack_1grow_c2fbObstackSingleGrow" \
        in generated
    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    class Obstack(ctypes.Structure):
        _fields_ = [
            ("object_base", ctypes.c_void_p),
            ("next_free", ctypes.c_void_p),
            ("chunk_limit", ctypes.c_void_p),
            ("alignment_mask", ctypes.c_ulong),
            ("maybe_empty_object", ctypes.c_uint),
        ]

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbObstackPointerGrow.argtypes = [
                ctypes.POINTER(Obstack), ctypes.c_void_p,
            ]
            library.c2fbObstackPointerGrow.restype = None
            library.c2fbObstackSingleGrow.argtypes = [
                ctypes.POINTER(Obstack), ctypes.c_int,
            ]
            library.c2fbObstackSingleGrow.restype = None

        storage = ctypes.create_string_buffer(160)
        base_address = ctypes.addressof(storage)
        pointer_value = base_address + 120
        pointer_bytes = ctypes.sizeof(ctypes.c_void_p)
        for available in (32, 2):
            reference_state = Obstack(
                base_address + 8, base_address + 32,
                base_address + 32 + available, 15, 0,
            )
            converted_state = Obstack(
                base_address + 8, base_address + 32,
                base_address + 32 + available, 15, 0,
            )
            reference.c2fbObstackPointerGrow(
                ctypes.byref(reference_state), pointer_value)
            converted.c2fbObstackPointerGrow(
                ctypes.byref(converted_state), pointer_value)
            assert reference_state.next_free == converted_state.next_free == \
                base_address + 32 + pointer_bytes, (backend, available, "pointer next_free")
            assert reference_state.chunk_limit == converted_state.chunk_limit, (
                backend, available, "pointer chunk_limit")
            assert ctypes.c_void_p.from_address(base_address + 32).value == \
                pointer_value, (backend, available, "stored pointer")

        for available in (16, 0):
            reference_state = Obstack(
                base_address + 8, base_address + 80,
                base_address + 80 + available, 15, 0,
            )
            converted_state = Obstack(
                base_address + 8, base_address + 80,
                base_address + 80 + available, 15, 0,
            )
            reference.c2fbObstackSingleGrow(
                ctypes.byref(reference_state), 0x123)
            converted.c2fbObstackSingleGrow(
                ctypes.byref(converted_state), 0x123)
            assert reference_state.next_free == converted_state.next_free == \
                base_address + 81, (backend, available, "byte next_free")
            assert reference_state.chunk_limit == converted_state.chunk_limit, (
                backend, available, "byte chunk_limit")
            assert storage.raw[80] == 0x23, (backend, available, "stored byte")

    compile_and_compare(
        "obstack-pointer-single-grow-statement-expressions",
        source_directory, candidate, reference_path, fbc, check,
    )


def check_local_enum_object_declaration(converter, fbc, cc, work):
    source_directory = work / "local-enum-object-declaration"
    source_directory.mkdir()
    source = source_directory / "local_enum_object.c"
    source.write_text(
        "int c2fbLocalEnumObject(int input) {\n"
        "    enum { ST_GND, ST_BACKSLASH, ST_ERROR } state = ST_BACKSLASH;\n"
        "    enum { OTHER_ZERO, OTHER_ONE } other;\n"
        "    if (input < 0) state = ST_GND;\n"
        "    other = input > 0 ? OTHER_ONE : OTHER_ZERO;\n"
        "    return (state == ST_BACKSLASH) * 2 + (other == OTHER_ONE);\n"
        "}\n"
    )
    candidate = source_directory / "local_enum_object_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
    )
    assert "translated 1 simple function" in summary and \
        "skipped 0" in summary, summary
    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbLocalEnumObject.argtypes = [ctypes.c_int]
            library.c2fbLocalEnumObject.restype = ctypes.c_int
        for input_value, expected in ((-1, 0), (0, 2), (1, 3)):
            assert reference.c2fbLocalEnumObject(input_value) == \
                converted.c2fbLocalEnumObject(input_value) == \
                expected, (backend, input_value, expected)

    compile_and_compare("local-enum-object-declaration", source_directory,
                        candidate, reference_path, fbc, check)


def check_record_array_member_designators(converter, fbc, cc, work):
    source_directory = work / "record-array-member-designators"
    source_directory.mkdir()
    source = source_directory / "record_array.c"
    source.write_text(
        "struct c2fb_timespec { long tv_sec; int tv_nsec; };\n"
        "long c2fbTimespecDesignators(long sec0, int nsec0,\n"
        "                             long sec1, int nsec1) {\n"
        "    struct c2fb_timespec values[2] = {\n"
        "        [0].tv_sec = sec0, [0].tv_nsec = nsec0,\n"
        "        [1].tv_sec = sec1, [1].tv_nsec = nsec1\n"
        "    };\n"
        "    return values[0].tv_sec * 10000 +\n"
        "           values[0].tv_nsec * 100 +\n"
        "           values[1].tv_sec * 2 + values[1].tv_nsec;\n"
        "}\n"
    )
    candidate = source_directory / "record_array_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
    )
    assert "translated 1 simple function" in summary and \
        "skipped 0" in summary, summary
    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            function = library.c2fbTimespecDesignators
            function.argtypes = [ctypes.c_long, ctypes.c_int,
                                 ctypes.c_long, ctypes.c_int]
            function.restype = ctypes.c_long
        for values in ((-2, 3, 5, -7), (0, 0, 1, 2), (7, -9, -3, 11)):
            expected = reference.c2fbTimespecDesignators(*values)
            actual = converted.c2fbTimespecDesignators(*values)
            assert actual == expected, (backend, values, expected, actual)

    compile_and_compare("record-array-member-designators", source_directory,
                        candidate, reference_path, fbc, check)


def check_block_local_record_tag_sizeof(converter, fbc, cc, work):
    source_directory = work / "block-local-record-tag-sizeof"
    source_directory.mkdir()
    source = source_directory / "local_record_size.c"
    source.write_text(
        "#include <stddef.h>\n"
        "size_t c2fbBlockLocalStructTagSize(void) {\n"
        "    struct LocalSizeRecord { char prefix; long value; char suffix; };\n"
        "    return sizeof(struct LocalSizeRecord);\n"
        "}\n"
        "size_t c2fbBlockLocalDifferentStructTagSize(void) {\n"
        "    struct LocalDifferentSizeRecord { double value; char suffix; };\n"
        "    return sizeof(struct LocalDifferentSizeRecord);\n"
        "}\n"
    )
    candidate = source_directory / "local_record_size_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
    )
    assert "translated 2 simple functions; skipped 0" in summary, summary

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbBlockLocalStructTagSize.restype = ctypes.c_size_t
            library.c2fbBlockLocalDifferentStructTagSize.restype = ctypes.c_size_t
        for name in ("c2fbBlockLocalStructTagSize",
                     "c2fbBlockLocalDifferentStructTagSize"):
            expected = getattr(reference, name)()
            actual = getattr(converted, name)()
            assert actual == expected, (backend, name, expected, actual)

    compile_and_compare("block-local-record-tag-sizeof", source_directory,
                        candidate, reference_path, fbc, check)


def check_pointer_cast_member_access(converter, fbc, cc, work):
    source_directory = work / "pointer-cast-member-access"
    source_directory.mkdir()
    source = source_directory / "cast_member_access.c"
    source.write_text(
        "struct c2fb_probe_address { unsigned int value; };\n"
        "struct c2fb_probe_socket { struct c2fb_probe_address address; };\n"
        "unsigned int c2fbCastMemberValue(const void *opaque) {\n"
        "    return ((const struct c2fb_probe_socket *) opaque)->address.value;\n"
        "}\n"
        "const struct c2fb_probe_address *c2fbCastMemberAddress(\n"
        "    const void *opaque) {\n"
        "    return &(((const struct c2fb_probe_socket *) opaque)->address);\n"
        "}\n"
    )
    candidate = source_directory / "cast_member_access_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
    )
    assert "translated 2 simple functions; skipped 0" in summary, summary

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    class Address(ctypes.Structure):
        _fields_ = [("value", ctypes.c_uint)]

    class Socket(ctypes.Structure):
        _fields_ = [("address", Address)]

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbCastMemberValue.argtypes = [ctypes.c_void_p]
            library.c2fbCastMemberValue.restype = ctypes.c_uint
            library.c2fbCastMemberAddress.argtypes = [ctypes.c_void_p]
            library.c2fbCastMemberAddress.restype = ctypes.POINTER(Address)
        for input_value in (0, 1, 0x7FFFFFFF, 0xFFFFFFFF):
            record = Socket(Address(input_value))
            address = ctypes.byref(record)
            expected_value = reference.c2fbCastMemberValue(address)
            actual_value = converted.c2fbCastMemberValue(address)
            expected_pointer = reference.c2fbCastMemberAddress(address)
            actual_pointer = converted.c2fbCastMemberAddress(address)
            expected_address = ctypes.addressof(expected_pointer.contents)
            actual_address = ctypes.addressof(actual_pointer.contents)
            assert actual_value == expected_value == input_value, (
                backend, input_value, expected_value, actual_value)
            assert actual_address == expected_address == ctypes.addressof(record.address), (
                backend, input_value, expected_address, actual_address)

    compile_and_compare("pointer-cast-member-access", source_directory,
                        candidate, reference_path, fbc, check)


def check_block_local_scalar_typedef(converter, fbc, cc, work):
    source_directory = work / "block-local-scalar-typedef"
    source_directory.mkdir()
    source = source_directory / "local_scalar_typedef.c"
    source.write_text(
        "int c2fbBlockLocalScalarTypedef(unsigned int input) {\n"
        "    unsigned int small = input;\n"
        "    unsigned long large = input;\n"
        "    switch (input & 1U) {\n"
        "    case 0: {\n"
        "        typedef unsigned int LocalWord;\n"
        "        LocalWord const *word = &small;\n"
        "        return (int)(_Alignof(LocalWord) * 100 +\n"
        "                    sizeof(LocalWord) + sizeof(*word));\n"
        "    }\n"
        "    default: {\n"
        "        typedef unsigned long LocalWord;\n"
        "        const LocalWord *word = &large;\n"
        "        return (int)(_Alignof(LocalWord) * 100 +\n"
        "                    sizeof(LocalWord) + sizeof(*word));\n"
        "    }\n"
        "    }\n"
        "}\n"
    )
    candidate = source_directory / "local_scalar_typedef_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
    )
    assert "translated 1 simple function" in summary and \
        "skipped 0" in summary, summary
    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbBlockLocalScalarTypedef.argtypes = [ctypes.c_uint]
            library.c2fbBlockLocalScalarTypedef.restype = ctypes.c_int
        for input_value in (0, 1, 2, 3):
            expected = reference.c2fbBlockLocalScalarTypedef(input_value)
            actual = converted.c2fbBlockLocalScalarTypedef(input_value)
            assert actual == expected, (
                backend, input_value, expected, actual)

    compile_and_compare("block-local-scalar-typedef", source_directory,
                        candidate, reference_path, fbc, check)


def check_record_array_sizeof_string_macro(converter, fbc, cc, work):
    source_directory = work / "record-array-sizeof-string-macro"
    source_directory.mkdir()
    source = source_directory / "symbol_value.c"
    source.write_text(
        '#define LONGEST_SYMBOL "count_bytes"\n'
        "struct c2fb_symbol_value {\n"
        "    char symbol[sizeof LONGEST_SYMBOL];\n"
        "    int value;\n"
        "};\n"
        "int c2fbReadSymbolValue(struct c2fb_symbol_value const *entry) {\n"
        "    return entry->value * 100 + (unsigned char) entry->symbol[0] +\n"
        "           (unsigned char) entry->symbol[11];\n"
        "}\n"
    )
    candidate = source_directory / "symbol_value_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
    )
    assert "translated 1 simple function" in summary and \
        "skipped 0" in summary, summary
    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    class SymbolValue(ctypes.Structure):
        _fields_ = [("symbol", ctypes.c_char * 12), ("value", ctypes.c_int)]

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbReadSymbolValue.argtypes = [ctypes.POINTER(SymbolValue)]
            library.c2fbReadSymbolValue.restype = ctypes.c_int
        item = SymbolValue(b"count_bytes", 73)
        expected = reference.c2fbReadSymbolValue(ctypes.byref(item))
        actual = converted.c2fbReadSymbolValue(ctypes.byref(item))
        assert actual == expected == 7399, (backend, expected, actual)

    compile_and_compare("record-array-sizeof-string-macro", source_directory,
                        candidate, reference_path, fbc, check)


def check_static_char_array_escape_initializer(converter, fbc, cc, work):
    source_directory = work / "static-char-array-escape-initializer"
    source_directory.mkdir()
    source = source_directory / "char_table.c"
    source.write_text(
        "static char const table[] = { '\\000', '\\001', '\\377' };\n"
        "char const *c2fbGetCharTable(void) { return table; }\n"
    )
    candidate = source_directory / "char_table_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
    )
    assert "translated 1 simple function" in summary and \
        "skipped 0" in summary, summary
    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbGetCharTable.argtypes = []
            library.c2fbGetCharTable.restype = ctypes.c_void_p
        expected = ctypes.string_at(reference.c2fbGetCharTable(), 3)
        actual = ctypes.string_at(converted.c2fbGetCharTable(), 3)
        assert actual == expected == b"\x00\x01\xff", (
            backend, expected, actual)

    compile_and_compare("static-char-array-escape-initializer",
                        source_directory, candidate, reference_path, fbc, check)


def check_global_record_array_sizeof_element(converter, fbc, cc, work):
    source_directory = work / "global-record-array-sizeof-element"
    source_directory.mkdir()
    source = source_directory / "record_array_sizeof.c"
    source.write_text(
        "#include <stddef.h>\n"
        "static struct {\n"
        "    size_t size;\n"
        "    int option;\n"
        "    char const *argument;\n"
        "} options[3];\n"
        "size_t c2fbOptionCount(void) {\n"
        "    return (size_t) (sizeof options / sizeof options[0] * 1000 +\n"
        "                    sizeof options[0]);\n"
        "}\n"
    )
    candidate = source_directory / "record_array_sizeof_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
    )
    assert "translated 1 simple function" in summary and \
        "skipped 0" in summary, summary
    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbOptionCount.restype = ctypes.c_size_t
        expected = reference.c2fbOptionCount()
        actual = converted.c2fbOptionCount()
        assert actual == expected == 3024, (backend, expected, actual)

    compile_and_compare("global-record-array-sizeof-element",
                        source_directory, candidate, reference_path, fbc, check)


def check_static_anonymous_record_array_members(converter, fbc, cc, work):
    source_directory = work / "static-anonymous-record-array-members"
    source_directory.mkdir()
    source = source_directory / "record_array_members.c"
    source.write_text(
        "static struct { int value; int next; } records[2];\n"
        "int c2fbRecordArrayMemberUpdate(int index, int value) {\n"
        "    records[index].value = value;\n"
        "    records[index].next = value + 1;\n"
        "    return records[index].value * 100 + records[index].next;\n"
        "}\n"
    )
    candidate = source_directory / "record_array_members_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
    )
    assert "translated 1 simple function" in summary and \
        "skipped 0" in summary, summary
    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbRecordArrayMemberUpdate.argtypes = [
                ctypes.c_int, ctypes.c_int]
            library.c2fbRecordArrayMemberUpdate.restype = ctypes.c_int
        for index, value in ((0, 0), (1, 7), (0, -12)):
            expected = reference.c2fbRecordArrayMemberUpdate(index, value)
            actual = converted.c2fbRecordArrayMemberUpdate(index, value)
            assert actual == expected == value * 101 + 1, (
                backend, index, value, expected, actual)

    compile_and_compare("static-anonymous-record-array-members",
                        source_directory, candidate, reference_path, fbc, check)


def check_va_list_copy(converter, fbc, cc, work):
    source_directory = work / "va-list-copy"
    source_directory.mkdir()
    source = source_directory / "va_list_copy.c"
    source.write_text(
        "#include <stdarg.h>\n"
        "int c2fbReadCopiedArguments(const char *format, ...) {\n"
        "    va_list original;\n"
        "    va_list copied;\n"
        "    va_start(original, format);\n"
        "    va_copy(copied, original);\n"
        "    int first = va_arg(original, int);\n"
        "    int copied_first = va_arg(copied, int);\n"
        "    int second = va_arg(original, int);\n"
        "    va_end(copied);\n"
        "    va_end(original);\n"
        "    return first * 10000 + copied_first * 100 + second;\n"
        "}\n"
    )
    candidate = source_directory / "va_list_copy_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
    )
    assert "translated 1 simple function" in summary and \
        "skipped 0" in summary, summary
    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbReadCopiedArguments.argtypes = [
                ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
            library.c2fbReadCopiedArguments.restype = ctypes.c_int
        expected = reference.c2fbReadCopiedArguments(b"%d%d", 7, 9)
        actual = converted.c2fbReadCopiedArguments(b"%d%d", 7, 9)
        assert actual == expected == 70709, (backend, expected, actual)

    compile_and_compare("va-list-copy", source_directory, candidate,
                        reference_path, fbc, check)


def check_va_arg_long_double(converter, fbc, cc, work):
    source_directory = work / "va-arg-long-double"
    source_directory.mkdir()
    source = source_directory / "va_arg_long_double.c"
    source.write_text(
        "#include <stdarg.h>\n"
        "double c2fbReadLongDouble(const char *format, ...) {\n"
        "    va_list args;\n"
        "    va_start(args, format);\n"
        "    long double value = va_arg(args, long double);\n"
        "    va_end(args);\n"
        "    return (double)value;\n"
        "}\n"
    )
    candidate = source_directory / "va_arg_long_double_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
    )
    assert "translated 1 simple function" in summary and \
        "skipped 0" in summary, summary
    generated = candidate.read_text(encoding="utf-8")
    assert "fb_LongDoubleVaArg(" in generated, generated

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbReadLongDouble.argtypes = [ctypes.c_char_p]
            library.c2fbReadLongDouble.restype = ctypes.c_double
        for value in (ctypes.c_longdouble(12.5), ctypes.c_longdouble(-3.75)):
            expected = reference.c2fbReadLongDouble(b"%Lf", value)
            actual = converted.c2fbReadLongDouble(b"%Lf", value)
            assert actual == expected == value.value, (
                backend, value.value, expected, actual)

    compile_and_compare("va-arg-long-double", source_directory, candidate,
                        reference_path, fbc, check)


def check_long_double_record_initializer(converter, fbc, cc, work):
    source_directory = work / "long-double-record-initializer"
    source_directory.mkdir()
    source = source_directory / "long_double_record_initializer.c"
    source.write_text(
        "struct c2fb_operand {\n"
        "    long double value;\n"
        "    unsigned int width;\n"
        "    int precision;\n"
        "};\n"
        "double c2fbReadLongDoubleRecord(int input) {\n"
        "    struct c2fb_operand first = { input + 0.5L, 7, 2 };\n"
        "    struct c2fb_operand second = {\n"
        "        first.value + 1.25L, first.width + 1, first.precision + 3\n"
        "    };\n"
        "    return (double)(second.value + first.width + second.precision);\n"
        "}\n"
    )
    candidate = source_directory / "long_double_record_initializer_candidates.bas"
    summary = translate_source_unit(
        converter, cc, source_directory, source, candidate,
    )
    assert "translated 1 simple function" in summary and \
        "skipped 0" in summary, summary
    generated = candidate.read_text(encoding="utf-8")
    assert "c2fb_record_initializer_" in generated, generated

    reference_path = source_directory / "reference.so"
    run(cc + ["-std=gnu11", "-shared", "-fPIC", source,
              "-o", reference_path], cwd=source_directory)

    def check(reference, converted, backend):
        for library in (reference, converted):
            library.c2fbReadLongDoubleRecord.argtypes = [ctypes.c_int]
            library.c2fbReadLongDoubleRecord.restype = ctypes.c_double
        for value in (-17, 0, 23):
            expected = reference.c2fbReadLongDoubleRecord(value)
            actual = converted.c2fbReadLongDoubleRecord(value)
            assert actual == expected, (backend, value, expected, actual)

    compile_and_compare("long-double-record-initializer", source_directory,
                        candidate, reference_path, fbc, check)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    tools_directory = Path(__file__).resolve().parents[1]
    parser.add_argument("--converter", default=str(tools_directory / "build/c2fb"))
    parser.add_argument("--cc", default="cc")
    parser.add_argument("--fbc", default="fbc")
    arguments = parser.parse_args()
    converter = str(Path(arguments.converter).resolve())
    fbc = shlex.split(arguments.fbc)
    cc = shlex.split(arguments.cc)
    with tempfile.TemporaryDirectory(prefix="c2fb-coreutils-regressions-") as temp:
        work = Path(temp)
        check_c23_static_booleans(converter, fbc, cc, work)
        check_pointer_array_assignment(converter, fbc, cc, work)
        check_file_scope_allocator_callbacks(converter, fbc, cc, work)
        check_generic_typedef_array_bound(converter, fbc, cc, work)
        check_generic_enum_constant(converter, fbc, cc, work)
        check_scalar_compound_literal_expression(converter, fbc, cc, work)
        check_record_compound_literal_value(converter, fbc, cc, work)
        check_stdc_zero_count_builtins(converter, fbc, cc, work)
        check_file_scope_countof_enum(converter, fbc, cc, work)
        check_builtin_constant_p(converter, fbc, cc, work)
        check_checked_overflow_builtins(converter, fbc, cc, work)
        check_checked_overflow_predicate_builtins(
            converter, fbc, cc, work)
        check_stdc_rotate_builtins(converter, fbc, cc, work)
        check_local_array_sizeof_bound(converter, fbc, cc, work)
        check_local_alignas_array(converter, fbc, cc, work)
        check_file_scope_anonymous_enum_object(converter, fbc, cc, work)
        check_static_record_array_compound_literals(converter, fbc, cc, work)
        check_multidimensional_array_parameter(converter, fbc, cc, work)
        check_local_array_passed_to_multidimensional_parameter(
            converter, fbc, cc, work)
        check_named_header_inline_body(converter, fbc, cc, work)
        check_multidimensional_array_storage(converter, fbc, cc, work)
        check_gnu_pointer_alias_statement_expression(
            converter, fbc, cc, work)
        check_unused_local_attribute(converter, fbc, cc, work)
        check_obstack_finish_statement_expression(converter, fbc, cc, work)
        check_obstack_blank_statement_expression(converter, fbc, cc, work)
        check_obstack_grow_statement_expression(converter, fbc, cc, work)
        check_obstack_free_statement_expression(converter, fbc, cc, work)
        check_obstack_pointer_and_single_grow_statement_expressions(
            converter, fbc, cc, work)
        check_local_enum_object_declaration(converter, fbc, cc, work)
        check_record_array_member_designators(converter, fbc, cc, work)
        check_block_local_record_tag_sizeof(converter, fbc, cc, work)
        check_pointer_cast_member_access(converter, fbc, cc, work)
        check_block_local_scalar_typedef(converter, fbc, cc, work)
        check_record_array_sizeof_string_macro(converter, fbc, cc, work)
        check_static_char_array_escape_initializer(converter, fbc, cc, work)
        check_global_record_array_sizeof_element(converter, fbc, cc, work)
        check_static_anonymous_record_array_members(converter, fbc, cc, work)
        check_va_list_copy(converter, fbc, cc, work)
        check_va_arg_long_double(converter, fbc, cc, work)
        check_long_double_record_initializer(converter, fbc, cc, work)
        print("All forty-two Coreutils C2FB regressions passed.")


if __name__ == "__main__":
    main()

# end of test_coreutils_c2fb_regressions.py
