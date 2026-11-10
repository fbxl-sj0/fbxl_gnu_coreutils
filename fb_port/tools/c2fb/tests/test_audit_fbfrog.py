"""
Project: C2FB FBFrog audit tests
File: test_audit_fbfrog.py
Purpose: Verify focused helpers used by the FBFrog parity audit.
Responsibilities: Exercise fixture detection, compile-failure filtering, and
  embedded-NUL string macro selection.
This file intentionally does NOT contain: converter integration tests.
"""

from pathlib import Path
import subprocess
import sys
import tempfile


TOOLS_DIRECTORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS_DIRECTORY))

from audit_fbfrog import (
    c_string_literal_has_embedded_nul,
    compile_failures_for_kind,
    fbfrog_fixture_uses_cpp,
    integer_function_macro_definitions,
    is_safe_integer_macro_expression,
    noninteger_object_macro_kinds,
    run_c_macro_value_probe_with_isolation,
    simple_c_float_macro_kind,
    simple_c_string_macro_literal,
)


def check_cpp_fixture_detection():
    with tempfile.TemporaryDirectory(prefix="c2fb-fbfrog-cxx-test-") as temp:
        tests_root = Path(temp) / "tests"

        def fixture(relative_path, source_text="extern int value;\n"):
            source = tests_root / relative_path
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(source_text, encoding="utf-8")
            return source

        assert fbfrog_fixture_uses_cpp(
            fixture("cxx/refs/good.h"), tests_root)
        assert fbfrog_fixture_uses_cpp(
            fixture("cpp/refs/good.h"), tests_root)
        assert fbfrog_fixture_uses_cpp(
            fixture("c/refs/good.hpp"), tests_root)
        assert fbfrog_fixture_uses_cpp(
            fixture("c/refs/default-argument.h", "void f(int value = 0);\n"),
            tests_root)
        assert not fbfrog_fixture_uses_cpp(
            fixture("c/refs/good.h"), tests_root)


def check_compile_failure_filter():
    records = [
        ("good.h", "fbfrog baseline", True, ""),
        ("bad-baseline.h", "fbfrog baseline", False, "baseline error"),
        ("bad-c2fb.h", "C2FB binding", False, "C2FB error"),
        ("good-c2fb.h", "C2FB binding", True, ""),
    ]
    assert compile_failures_for_kind(records, "fbfrog baseline") == [records[1]]
    assert compile_failures_for_kind(records, "C2FB binding") == [records[2]]
    assert compile_failures_for_kind(records, "unknown") == []


def check_embedded_nul_macro_selection():
    source = (
        r'#define embedded "a\0b"' + "\n" +
        r'#define slash_zero "\\0"' + "\n" +
        r'#define ordinary "abc"' + "\n" +
        r'#define wide L"abc"' + "\n"
    )
    assert simple_c_string_macro_literal(r'"a\0b"') == "string-nul"
    assert c_string_literal_has_embedded_nul(r'"a\0b"')
    assert not c_string_literal_has_embedded_nul(r'"\\0"')
    assert simple_c_string_macro_literal('L"abc"') == "wide-string"
    assert noninteger_object_macro_kinds(source) == {
        "embedded": "string-nul",
        "slash_zero": "string",
        "ordinary": "string",
        "wide": "wide-string",
    }
    assert simple_c_float_macro_kind("0x.800002p+1f") == "single"
    assert simple_c_float_macro_kind("0X1.0000000000001P0") == "double"
    assert simple_c_float_macro_kind("(-0x1.8p+1)") == "double"
    assert simple_c_float_macro_kind("0x1.8p0L") is None


def check_function_like_conditional_integer_macros():
    expression = "((x > 0) && (x % 2)) ? ((x + 4) / 2) : (x - 1)"
    assert is_safe_integer_macro_expression(expression, {"x"})
    assert not is_safe_integer_macro_expression("x ? 1", {"x"})
    assert not is_safe_integer_macro_expression("call(x)", {"x"})
    definitions = integer_function_macro_definitions(
        "#define C2FB_SELECT(x) " + expression + "\n"
    )
    assert definitions["C2FB_SELECT"] == (["x"], expression)
    four_parameter_definitions = integer_function_macro_definitions(
        "#define C2FB_QUAD(a,b,c,d) ((a + b + c + d) / 2)\n"
    )
    assert four_parameter_definitions["C2FB_QUAD"][0] == [
        "a", "b", "c", "d",
    ]


def check_integer_c_oracle_isolates_invalid_macros():
    with tempfile.TemporaryDirectory(prefix="c2fb-fbfrog-c-oracle-test-") as temp:
        output_root = Path(temp)
        source = output_root / "macro-values.h"
        source.write_text(
            "#define C2FB_VALID 7\n"
            "#define C2FB_ALSO_VALID (C2FB_VALID + 2)\n"
            "#define C2FB_INVALID 1i8\n",
            encoding="utf-8",
        )
        macro_dump = subprocess.run(
            ["cc", "-E", "-dM", "-x", "c", str(source)],
            capture_output=True, text=True, check=True,
        ).stdout
        expressions = [
            ("valid", "C2FB_VALID"),
            ("also_valid", "C2FB_ALSO_VALID"),
            ("invalid", "C2FB_INVALID"),
        ]
        values, skipped = run_c_macro_value_probe_with_isolation(
            macro_dump, {name for _, name in expressions}, expressions,
            "isolation", output_root, "cc", False, source, [],
        )
        assert values == {"valid": 7, "also_valid": 9}, values
        assert len(skipped) == 1 and skipped[0][0] == "invalid", skipped


def main():
    check_cpp_fixture_detection()
    check_compile_failure_filter()
    check_embedded_nul_macro_selection()
    check_function_like_conditional_integer_macros()
    check_integer_c_oracle_isolates_invalid_macros()
    print("FBFrog audit helper checks: PASS")


if __name__ == "__main__":
    main()

# end of test_audit_fbfrog.py
