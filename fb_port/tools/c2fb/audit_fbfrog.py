#!/usr/bin/env python3
"""
Project: SQLite FreeBASIC port tools
File: audit_fbfrog.py
Purpose: Compare C2FB output against an external fbfrog fixture tree.
Responsibilities: Read paired C headers and FreeBASIC outputs, invoke C2FB in
  a temporary directory, and compare names, macro values, and record layouts.
This file intentionally does NOT contain: fbfrog code or copied test fixtures.
"""

import argparse
import functools
from fnmatch import fnmatchcase
import importlib.util
import itertools
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


SOURCE_DEFINE = re.compile(
    r"^[ \t]*#[ \t]*define[ \t]+([A-Za-z_][A-Za-z_0-9]*)", re.M)
C_IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
PREPROCESSOR_DIRECTIVE = re.compile(
    r"^[ \t]*#[ \t]*([A-Za-z_][A-Za-z_0-9]*)\b(.*)$")
INTEGER_MACRO_LITERAL = re.compile(
    r"[+-]?(?:0[xX][0-9A-Fa-f]+|0[0-7]*|[1-9][0-9]*)"
    r"(?:[uU](?:ll|LL|[lL])?|(?:ll|LL|[lL])[uU]?)?")
FLOAT_MACRO_LITERAL = re.compile(
    r"[+-]?(?:(?:[0-9]+\.[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?|"
    r"[0-9]+[eE][+-]?[0-9]+)([fF]?)")
HEX_FLOAT_MACRO_LITERAL = re.compile(
    r"[+-]?0[xX](?:[0-9A-Fa-f]+(?:\.[0-9A-Fa-f]*)?|"
    r"\.[0-9A-Fa-f]+)[pP][+-]?[0-9]+([fF]?)")
C_STRING_LITERAL_TOKEN = re.compile(r'(?:L)?"(?:\\.|[^"\\])*"')
FREEBASIC_INTEGER_LITERAL = re.compile(
    r"[+-]?(?:&[hH][0-9A-Fa-f]+|&[oO][0-7]+|&[bB][01]+|"
    r"(?:0|[1-9][0-9]*))(?:[uU](?:ll|LL|[lL])?|(?:ll|LL|[lL])[uU]?)?")
FREEBASIC_MACRO_PARAMETER_KEYWORDS = {
    "and", "or", "andalso", "orelse", "xor", "eqv", "imp",
    "not", "mod", "shl", "shr",
}
INTEGER_MACRO_EXPRESSION_TOKEN = re.compile(
    r"\s*(<<|>>|<=|>=|==|!=|&&|\|\||[A-Za-z_][A-Za-z_0-9]*|"
    r"0[xX][0-9A-Fa-f]+(?:[uU](?:ll|LL|[lL])?|(?:ll|LL|[lL])[uU]?)?|"
    r"0[0-7]*(?:[uU](?:ll|LL|[lL])?|(?:ll|LL|[lL])[uU]?)?|"
    r"[1-9][0-9]*(?:[uU](?:ll|LL|[lL])?|(?:ll|LL|[lL])[uU]?)?|"
    r"[()+*/%?:\-&|^~!<>])")
# Parentheses and unary chains recurse in the expression checker below.
MAX_INTEGER_MACRO_EXPRESSION_TOKENS = 512
C_NON_CODE_TEXT = re.compile(
    r"/\*.*?\*/|//[^\r\n]*|\"(?:\\.|[^\"\\])*\"|"
    r"'(?:\\.|[^'\\])*'",
    re.S,
)
TOP_LEVEL_BINDING = re.compile(
    r"^[ \t]*(?:(?:private[ \t]+)?const[ \t]+|"
    r"#[ \t]*(?:define|macro)[ \t]+|"
    r"(?:private[ \t]+)?declare[ \t]+(?:sub|function)[ \t]+|"
    r"(?:private[ \t]+)?(?:sub|function)[ \t]+|"
    r"(?:private[ \t]+)?extern[ \t]+|"
    r"(?:private[ \t]+)?dim[ \t]+shared[ \t]+|"
    r"(?:private[ \t]+)?(?:type|union)[ \t]+)"
    r"([A-Za-z_][A-Za-z_0-9]*)",
    re.I | re.M,
)
RECORD_BLOCK_START = re.compile(
    r"^[ \t]*(?:private[ \t]+)?(?:type|union)[ \t]+"
    r"[A-Za-z_][A-Za-z_0-9]*(?:[ \t]+field[ \t]*=[^\r\n]*)?[ \t]*$",
    re.I,
)
RECORD_BLOCK_END = re.compile(r"^[ \t]*end[ \t]+(?:type|union)\b", re.I)
BASIC_RECORD_ALIAS = re.compile(
    r"^[ \t]*(?:private[ \t]+)?type[ \t]+"
    r"([A-Za-z_][A-Za-z_0-9]*)[ \t]+as[ \t]+"
    r"([A-Za-z_][A-Za-z_0-9]*)[ \t]*$",
    re.I | re.M,
)
BASIC_TYPE_MACRO_ALIAS = re.compile(
    r"^[ \t]*#define[ \t]+([A-Za-z_][A-Za-z_0-9]*)[ \t]+"
    r"([A-Za-z_][A-Za-z_0-9]*)[ \t]*$",
    re.I | re.M,
)
BASIC_RECORD_FIELD = re.compile(
    r"^[ \t]*([A-Za-z_][A-Za-z_0-9]*)(?:[ \t]*\([^\r\n)]*\))?"
    r"[ \t]+as[ \t]+",
    re.I,
)


def strip_basic_comments(text: str) -> str:
    """Remove FreeBASIC and fbfrog C-style comments without changing strings."""
    result: list[str] = []
    position = 0
    while position < len(text):
        if text[position] == '"':
            result.append(text[position])
            position += 1
            while position < len(text):
                result.append(text[position])
                if text[position] == '"':
                    if position + 1 < len(text) and text[position + 1] == '"':
                        result.append(text[position + 1])
                        position += 2
                        continue
                    position += 1
                    break
                position += 1
            continue

        comment_end = ""
        if text.startswith("/*", position):
            comment_end = "*/"
            position += 2
        elif text.startswith("/'", position):
            comment_end = "'/"
            position += 2
        elif text[position] == "'":
            newline = text.find("\n", position)
            if newline < 0:
                result.append("\n" if text.endswith("\n") else "")
                break
            result.append("\n")
            position = newline + 1
            continue

        if comment_end:
            end_position = text.find(comment_end, position)
            if end_position < 0:
                result.extend("\n" for char in text[position:] if char == "\n")
                break
            result.extend("\n" for char in text[position:end_position] if char == "\n")
            position = end_position + len(comment_end)
            continue

        result.append(text[position])
        position += 1
    return "".join(result)


def emitted_binding_names(text: str) -> set[str]:
    """Collect emitted module bindings, excluding comments and record members."""
    names: set[str] = set()
    in_record = 0
    for line in freebasic_module_scope_lines(
        text, keep_procedure_names=True, skip_macro_scopes=False):
        if in_record:
            if RECORD_BLOCK_START.match(line):
                in_record += 1
            elif RECORD_BLOCK_END.match(line):
                in_record -= 1
            continue

        match = TOP_LEVEL_BINDING.match(line)
        if match is None:
            continue
        names.add(match.group(1))
        if RECORD_BLOCK_START.match(line):
            in_record = 1
    return names


def freebasic_record_layout_types(
    text: str,
) -> tuple[dict[str, dict[str, object]], dict[str, str]]:
    """Read module-scope records, excluding procedure- and macro-local types."""
    lines = freebasic_module_scope_lines(text)
    records: dict[str, dict[str, object]] = {}
    aliases = {
        alias.casefold(): target.casefold()
        for alias, target in BASIC_RECORD_ALIAS.findall("\n".join(lines))
    }
    for alias, target in BASIC_TYPE_MACRO_ALIAS.findall("\n".join(lines)):
        aliases.setdefault(alias.casefold(), target.casefold())
    line_index = 0
    while line_index < len(lines):
        start = RECORD_BLOCK_START.match(lines[line_index])
        if start is None:
            line_index += 1
            continue
        declaration = re.match(
            r"^[ \t]*(?:private[ \t]+)?(type|union)[ \t]+"
            r"([A-Za-z_][A-Za-z_0-9]*)",
            lines[line_index], re.I,
        )
        if declaration is None:
            line_index += 1
            continue
        kind = declaration.group(1).casefold()
        name = declaration.group(2)
        c2fb_record_layout = (
            kind == "union" and name.casefold().startswith("_c2fb_record_")
        )
        fields: list[str] = []
        depth = 1
        line_index += 1
        while line_index < len(lines) and depth > 0:
            line = lines[line_index]
            if RECORD_BLOCK_START.match(line) or re.match(
                r"^[ \t]*(?:private[ \t]+)?(?:type|union)[ \t]*$",
                line, re.I,
            ):
                depth += 1
            elif RECORD_BLOCK_END.match(line):
                depth -= 1
            elif depth == 1 or (c2fb_record_layout and depth > 1):
                field = BASIC_RECORD_FIELD.match(line)
                if field is not None and field.group(1).casefold() not in {
                    existing.casefold() for existing in fields
                }:
                    fields.append(field.group(1))
            line_index += 1
        records[name.casefold()] = {
            "name": name,
            "kind": kind,
            "fields": fields,
        }
    return records, aliases


def freebasic_module_scope_lines(
    text: str, keep_procedure_names: bool = False,
    skip_macro_scopes: bool = True,
) -> list[str]:
    """Remove procedure, macro, and Scope bodies while retaining module declarations."""
    lines = strip_basic_comments(text).splitlines()
    module_lines: list[str] = []
    local_scopes: list[str] = []
    for line in lines:
        stripped = line.strip()
        scope_start = None
        if skip_macro_scopes and re.match(r"^#macro\b", stripped, re.I):
            scope_start = "macro"
        elif re.match(r"^scope\b", stripped, re.I):
            scope_start = "scope"
        else:
            procedure_start = re.match(
                r"^(?:(?:private|public|protected|static)[ \t]+)*"
                r"(sub|function)\b",
                stripped, re.I,
            )
            if procedure_start is not None:
                scope_start = procedure_start.group(1).casefold()

        scope_end = None
        if skip_macro_scopes and re.match(r"^#endmacro\b", stripped, re.I):
            scope_end = "macro"
        elif re.match(r"^end[ \t]+scope\b", stripped, re.I):
            scope_end = "scope"
        else:
            procedure_end = re.match(
                r"^end[ \t]+(sub|function)\b", stripped, re.I)
            if procedure_end is not None:
                scope_end = procedure_end.group(1).casefold()

        if local_scopes:
            if scope_start is not None:
                local_scopes.append(scope_start)
            elif scope_end is not None:
                if scope_end in local_scopes:
                    while local_scopes:
                        ended_scope = local_scopes.pop()
                        if ended_scope == scope_end:
                            break
            continue
        if scope_start is not None:
            local_scopes.append(scope_start)
            if keep_procedure_names and scope_start in {"sub", "function"}:
                module_lines.append(line)
            continue
        if scope_end is not None:
            continue
        module_lines.append(line)
    return module_lines


def resolve_freebasic_record_layout_type(
    source_name: str,
    records: dict[str, dict[str, object]],
    aliases: dict[str, str],
) -> dict[str, object] | None:
    """Resolve a record alias without following pointer or scalar aliases."""
    name = source_name.casefold()
    visited: set[str] = set()
    while name not in visited:
        visited.add(name)
        record = records.get(name)
        if record is not None:
            return record
        alias_target = aliases.get(name, "")
        if alias_target.casefold() == "any":
            return {"name": source_name, "kind": "struct", "fields": []}
        name = alias_target
        if name == "":
            return None
    return None


def emitted_object_macro_names(text: str) -> set[str]:
    """Collect value-bearing object macros and constants, not procedures."""
    names: set[str] = set()
    for line in strip_basic_comments(text).splitlines():
        constant = re.match(
            r"^[ \t]*(?:private[ \t]+)?const[ \t]+"
            r"([A-Za-z_][A-Za-z_0-9]*)"
            r"(?:[ \t]+as[ \t]+[^=]+)?[ \t]*=[ \t]*(\S.*)$",
            line, re.I,
        )
        if constant is not None:
            names.add(constant.group(1))
            continue
        macro = re.match(
            r"^[ \t]*#[ \t]*(?:define|macro)[ \t]+"
            r"([A-Za-z_][A-Za-z_0-9]*)(.*)$",
            line, re.I,
        )
        if macro is None:
            continue
        name, suffix = macro.groups()
        if suffix.startswith("(") or not suffix.strip():
            continue
        names.add(name)
    return names


def emitted_function_macro_names(text: str) -> set[str]:
    """Collect function-like preprocessor macro and block-macro names."""
    names: set[str] = set()
    for line in strip_basic_comments(text).splitlines():
        macro = re.match(
            r"^[ \t]*#[ \t]*(?:define|macro)[ \t]+"
            r"([A-Za-z_][A-Za-z_0-9]*)(.*)$",
            line, re.I,
        )
        if macro is not None and macro.group(2).startswith("("):
            names.add(macro.group(1))
    return names


def freebasic_macro_rhs_by_name(text: str) -> dict[str, list[str]]:
    """Collect constant/object-macro right-hand sides for alias checking."""
    definitions: dict[str, list[str]] = {}
    for line in strip_basic_comments(text).splitlines():
        constant = re.match(
            r"^[ \t]*(?:private[ \t]+)?const[ \t]+"
            r"([A-Za-z_][A-Za-z_0-9]*)\b.*?=[ \t]*(\S.*)$",
            line, re.I,
        )
        if constant is not None:
            definitions.setdefault(constant.group(1).casefold(), []).append(
                constant.group(2).strip())
            continue
        macro = re.match(
            r"^[ \t]*#[ \t]*define[ \t]+"
            r"([A-Za-z_][A-Za-z_0-9]*)(.*)$",
            line, re.I,
        )
        if macro is None:
            continue
        name, suffix = macro.groups()
        if suffix.startswith("(") or not suffix.strip():
            continue
        definitions.setdefault(name.casefold(), []).append(suffix.strip())
    return definitions


def freebasic_noninteger_macro_probe_kind(
    text: str, name: str, c_kind: str,
) -> str:
    """Choose a FreeBASIC probe that respects string-value versus pointer bindings."""
    if c_kind.startswith("wide-string"):
        return c_kind
    if c_kind not in {"string", "string-nul"}:
        return c_kind
    nul_suffix = "-nul" if c_kind == "string-nul" else ""

    folded_name = name.casefold()
    if re.search(
        r"^[ \t]*(?:private[ \t]+)?const[ \t]+" + re.escape(name) +
        r"[ \t]+as[ \t]+(?:const[ \t]+)?zstring[ \t]+ptr\b",
        strip_basic_comments(text), re.I | re.M,
    ):
        return "string" + nul_suffix

    definitions = freebasic_macro_rhs_by_name(text)

    def expression_is_pointer(expression: str, seen: set[str]) -> bool:
        expression = expression.strip()
        while has_outer_parentheses(expression):
            expression = expression[1:-1].strip()
        if re.match(r"(?i)^(?:strptr)[ \t]*\(", expression):
            return True
        if re.match(
            r"(?i)^(?:cptr|cast)[ \t]*\([^)]*\bzstring[ \t]+ptr\b",
            expression,
        ):
            return True
        if expression.startswith("@"):
            return True
        if C_IDENTIFIER.fullmatch(expression) is None:
            return False
        dependency = expression.casefold()
        if dependency in seen:
            return False
        if dependency in definitions:
            seen.add(dependency)
            return any(
                expression_is_pointer(value, seen)
                for value in definitions[dependency]
            )
        pointer_declaration = re.search(
            r"^[ \t]*(?:private[ \t]+)?(?:const|dim)[ \t]+"
            + re.escape(expression) +
            r"[ \t]+as[ \t]+(?:const[ \t]+)?zstring[ \t]+ptr\b",
            strip_basic_comments(text), re.I | re.M,
        )
        return pointer_declaration is not None

    expressions = definitions.get(folded_name, [])
    if expressions and all(
        expression_is_pointer(expression, {folded_name})
        for expression in expressions
    ):
        return "string" + nul_suffix
    return "string-value" + nul_suffix


def freebasic_macro_expression_is_integer(
    expression: str, definitions: dict[str, list[str]],
    known_integer_names: set[str], visited: set[str] | None = None,
) -> bool:
    """Follow simple constant aliases to an integer macro value."""
    expression = expression.strip()
    while has_outer_parentheses(expression):
        expression = expression[1:-1].strip()
    if FREEBASIC_INTEGER_LITERAL.fullmatch(expression) is not None:
        return True
    if C_IDENTIFIER.fullmatch(expression) is None:
        return False
    folded = expression.casefold()
    if folded in known_integer_names:
        return True
    visited_names = set(visited or ())
    if folded in visited_names:
        return False
    visited_names.add(folded)
    targets = definitions.get(folded, [])
    return bool(targets) and all(
        freebasic_macro_expression_is_integer(
            target, definitions, known_integer_names, visited_names)
        for target in targets
    )


def macro_value_constant_dependencies(
    name: str, definitions: dict[str, list[str]],
    visited: set[str] | None = None,
) -> set[str]:
    """Return simple constant aliases needed to evaluate one macro value."""
    visited_names = set(visited or ())
    folded = name.casefold()
    if folded in visited_names:
        return set()
    visited_names.add(folded)
    dependencies: set[str] = set()
    for expression in definitions.get(folded, []):
        expression = expression.strip()
        while has_outer_parentheses(expression):
            expression = expression[1:-1].strip()
        if C_IDENTIFIER.fullmatch(expression) is None:
            continue
        dependencies.add(expression)
        dependencies.update(
            macro_value_constant_dependencies(
                expression, definitions, visited_names)
        )
    return dependencies


def emitted_preprocessor_macro_names(text: str) -> set[str]:
    """Collect all FreeBASIC preprocessor macro names, including empty defines."""
    names: set[str] = set()
    for line in strip_basic_comments(text).splitlines():
        macro = re.match(
            r"^[ \t]*#[ \t]*(?:define|macro)[ \t]+"
            r"([A-Za-z_][A-Za-z_0-9]*)",
            line, re.I,
        )
        if macro is not None:
            names.add(macro.group(1))
    return names


def empty_object_macro_names(text: str) -> set[str]:
    """Find active C object-like macros with no replacement body."""
    names: set[str] = set()
    for line in text.splitlines():
        directive = PREPROCESSOR_DIRECTIVE.match(line)
        if directive is None or directive.group(1).casefold() != "define":
            continue
        definition = re.match(
            r"[ \t]+([A-Za-z_][A-Za-z_0-9]*)(.*)$",
            directive.group(2),
        )
        if definition is None:
            continue
        name, suffix = definition.groups()
        if not suffix.startswith("(") and not suffix.strip():
            names.add(name)
    return names


def macro_value_binding_subset(
    text: str, names: set[str], include_roots: list[Path] | None = None,
) -> str:
    """Keep macro values and their preprocessor context, dropping unrelated declarations."""
    selected_names = {name.casefold() for name in names}
    output: list[str] = []
    in_selected_macro_block = False
    continuation = False
    for line in strip_basic_comments(text).splitlines():
        if in_selected_macro_block:
            output.append(line)
            directive = PREPROCESSOR_DIRECTIVE.match(line)
            if directive is not None and directive.group(1).casefold() == "endmacro":
                in_selected_macro_block = False
            continue
        if continuation:
            output.append(line)
            continuation = line.rstrip().endswith(("_", "\\"))
            continue

        directive = PREPROCESSOR_DIRECTIVE.match(line)
        if directive is not None:
            command = directive.group(1).casefold()
            tail = directive.group(2)
            if command in {
                "if", "ifdef", "ifndef", "elif", "elseif", "else", "endif",
                "undef", "pragma",
            }:
                output.append(line)
                continue
            if command == "include":
                include = re.match(
                    r"[ \t]+(?:once[ \t]+)?[\"<]([^\">]+)[\">]",
                    tail, re.I,
                )
                if include is None:
                    continue
                include_name = include.group(1).replace("\\", "/")
                include_path = Path(include_name)
                if include_path.is_absolute() and include_path.is_file():
                    output.append(line)
                    continue
                if include_name.startswith("crt/") or any(
                    (root / include_path).is_file()
                    for root in include_roots or []
                ):
                    output.append(line)
                continue
            if command in {"define", "macro"}:
                definition = re.match(r"[ \t]+([A-Za-z_][A-Za-z_0-9]*)(.*)$", tail)
                if definition is None or definition.group(1).casefold() not in selected_names:
                    continue
                output.append(line)
                in_selected_macro_block = command == "macro"
                continuation = line.rstrip().endswith(("_", "\\"))
                continue
            if command == "endmacro":
                continue
            continue

        constant = re.match(
            r"^[ \t]*(?:private[ \t]+)?const[ \t]+"
            r"([A-Za-z_][A-Za-z_0-9]*)\b",
            line, re.I,
        )
        if constant is not None and constant.group(1).casefold() in selected_names:
            output.append(line)
            continuation = line.rstrip().endswith("_")

    return "\n".join(output) + ("\n" if output else "")


def has_outer_parentheses(expression: str) -> bool:
    """Return whether one parenthesis pair encloses the whole expression."""
    if len(expression) < 2 or expression[0] != "(" or expression[-1] != ")":
        return False
    depth = 0
    for index, character in enumerate(expression):
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth < 0 or (depth == 0 and index != len(expression) - 1):
                return False
    return depth == 0


def is_integer_macro_literal(value: str) -> bool:
    """Recognize an integer literal without interpreting target-dependent types."""
    value = re.sub(r"/\*.*?\*/|//.*$", "", value, flags=re.S).strip()
    while has_outer_parentheses(value):
        value = value[1:-1].strip()
    return INTEGER_MACRO_LITERAL.fullmatch(value) is not None


def integer_object_macro_names(source_text: str) -> set[str]:
    """Select unique, unconditional object-like macros with integer literals."""
    definitions: dict[str, list[str | None]] = {}
    conditional_names: set[str] = set()
    conditional_depth = 0
    for line in source_text.splitlines():
        directive = PREPROCESSOR_DIRECTIVE.match(line)
        if directive is None:
            continue
        command = directive.group(1).casefold()
        tail = directive.group(2)
        if command in {"if", "ifdef", "ifndef"}:
            conditional_depth += 1
            continue
        if command == "endif":
            conditional_depth = max(0, conditional_depth - 1)
            continue
        if command != "define":
            continue

        definition = re.match(r"[ \t]+([A-Za-z_][A-Za-z_0-9]*)(.*)$", tail)
        if definition is None:
            continue
        name, value = definition.groups()
        if conditional_depth:
            conditional_names.add(name)
            continue

        # A function-like macro has no space before its opening parenthesis.
        if value.startswith("(") or not value or not value[0].isspace():
            definitions.setdefault(name, []).append(None)
            continue
        value = value.rstrip()
        if value.endswith("\\"):
            definitions.setdefault(name, []).append(None)
            continue
        definitions.setdefault(name, []).append(
            value if is_integer_macro_literal(value) else None)

    casefold_counts: dict[str, int] = {}
    for name in definitions:
        folded = name.casefold()
        casefold_counts[folded] = casefold_counts.get(folded, 0) + 1
    return {
        name for name, values in definitions.items()
        if len(values) == 1 and values[0] is not None and
        name not in conditional_names and casefold_counts[name.casefold()] == 1
    }


def simple_c_float_macro_kind(value: str) -> str | None:
    """Classify a direct C floating literal by its default type."""
    value = value.strip()
    while has_outer_parentheses(value):
        value = value[1:-1].strip()
    match = FLOAT_MACRO_LITERAL.fullmatch(value)
    if match is None:
        match = HEX_FLOAT_MACRO_LITERAL.fullmatch(value)
    if match is None:
        return None
    return "single" if match.group(1) else "double"


def simple_c_string_macro_literal(value: str) -> str | None:
    """Classify adjacent narrow or wide literals, including embedded NUL bytes."""
    value = value.strip()
    while has_outer_parentheses(value):
        value = value[1:-1].strip()
    position = 0
    literal_kind: str | None = None
    while position < len(value):
        while position < len(value) and value[position].isspace():
            position += 1
        if position >= len(value):
            break
        match = C_STRING_LITERAL_TOKEN.match(value, position)
        if match is None:
            return None
        current_kind = "wide-string" if match.group(0).startswith("L") else "string"
        if literal_kind is not None and literal_kind != current_kind:
            return None
        literal_kind = current_kind
        position = match.end()
    if literal_kind is None:
        return None
    if c_string_literal_has_embedded_nul(value):
        return literal_kind + "-nul"
    return literal_kind


def c_string_literal_has_embedded_nul(value: str) -> bool:
    """Detect zero-valued C escapes without confusing escaped backslashes."""
    value = value.strip()
    while has_outer_parentheses(value):
        value = value[1:-1].strip()
    position = 0
    while position < len(value):
        while position < len(value) and value[position].isspace():
            position += 1
        if position >= len(value):
            break
        match = C_STRING_LITERAL_TOKEN.match(value, position)
        if match is None:
            return False
        literal = match.group(0)
        for escape in re.finditer(
            r"\\(?:x[0-9A-Fa-f]+|u[0-9A-Fa-f]{4}|"
            r"U[0-9A-Fa-f]{8}|[0-7]{1,3}|.)",
            literal,
        ):
            spelling = escape.group(0)[1:]
            if spelling.startswith("x") and int(spelling[1:], 16) == 0:
                return True
            if spelling.startswith("u") and int(spelling[1:], 16) == 0:
                return True
            if spelling.startswith("U") and int(spelling[1:], 16) == 0:
                return True
            if spelling[0] in "01234567" and int(spelling, 8) == 0:
                return True
        position = match.end()
    return False


def noninteger_object_macro_kinds(source_text: str) -> dict[str, str]:
    """Select unique unconditional direct float and string macros."""
    definitions: dict[str, list[str | None]] = {}
    conditional_names: set[str] = set()
    conditional_depth = 0
    for line in source_text.splitlines():
        directive = PREPROCESSOR_DIRECTIVE.match(line)
        if directive is None:
            continue
        command = directive.group(1).casefold()
        tail = directive.group(2)
        if command in {"if", "ifdef", "ifndef"}:
            conditional_depth += 1
            continue
        if command == "endif":
            conditional_depth = max(0, conditional_depth - 1)
            continue
        if command != "define":
            continue

        definition = re.match(r"[ \t]+([A-Za-z_][A-Za-z_0-9]*)(.*)$", tail)
        if definition is None:
            continue
        name, suffix = definition.groups()
        if conditional_depth:
            conditional_names.add(name)
            continue
        if suffix.startswith("(") or not suffix or not suffix[0].isspace():
            definitions.setdefault(name, []).append(None)
            continue
        value = suffix.strip()
        if value.endswith("\\"):
            definitions.setdefault(name, []).append(None)
            continue
        kind = simple_c_float_macro_kind(value)
        if kind is None:
            kind = simple_c_string_macro_literal(value)
        definitions.setdefault(name, []).append(kind)

    casefold_counts: dict[str, int] = {}
    for name in definitions:
        folded = name.casefold()
        casefold_counts[folded] = casefold_counts.get(folded, 0) + 1
    return {
        name: values[0]
        for name, values in definitions.items()
        if len(values) == 1 and values[0] is not None and
        name not in conditional_names and casefold_counts[name.casefold()] == 1
    }


def is_safe_integer_macro_expression(value: str, parameters: set[str]) -> bool:
    """Accept syntactically complete integer expressions over macro parameters."""
    value = re.sub(r"/\*.*?\*/|//.*$", "", value, flags=re.S).strip()
    if not value or "\\" in value or "++" in value or "--" in value:
        return False
    position = 0
    tokens: list[str] = []
    while position < len(value):
        match = INTEGER_MACRO_EXPRESSION_TOKEN.match(value, position)
        if match is None:
            return False
        token = match.group(1)
        if C_IDENTIFIER.fullmatch(token) and token not in parameters:
            return False
        tokens.append(token)
        if len(tokens) > MAX_INTEGER_MACRO_EXPRESSION_TOKENS:
            return False
        position = match.end()

    binary_precedence = {
        "||": 1,
        "&&": 2,
        "|": 3,
        "^": 4,
        "&": 5,
        "==": 6,
        "!=": 6,
        "<": 7,
        ">": 7,
        "<=": 7,
        ">=": 7,
        "<<": 8,
        ">>": 8,
        "+": 9,
        "-": 9,
        "*": 10,
        "/": 10,
        "%": 10,
    }
    token_index = 0

    def parse_primary() -> bool:
        nonlocal token_index
        if token_index >= len(tokens):
            return False
        token = tokens[token_index]
        if token in {"+", "-", "!", "~"}:
            token_index += 1
            return parse_primary()
        if token == "(":
            token_index += 1
            if not parse_expression(1):
                return False
            if token_index >= len(tokens) or tokens[token_index] != ")":
                return False
            token_index += 1
            return True
        if C_IDENTIFIER.fullmatch(token) or \
           INTEGER_MACRO_LITERAL.fullmatch(token):
            token_index += 1
            return True
        return False

    def parse_expression(minimum_precedence: int) -> bool:
        nonlocal token_index
        if not parse_primary():
            return False
        while token_index < len(tokens):
            if tokens[token_index] == "?" and minimum_precedence <= 1:
                token_index += 1
                if not parse_expression(1):
                    return False
                if token_index >= len(tokens) or tokens[token_index] != ":":
                    return False
                token_index += 1
                if not parse_expression(1):
                    return False
                continue
            precedence = binary_precedence.get(tokens[token_index], 0)
            if precedence < minimum_precedence:
                break
            token_index += 1
            if not parse_expression(precedence + 1):
                return False
        return True

    return parse_expression(1) and token_index == len(tokens)


def integer_function_macro_definitions(
    source_text: str,
) -> dict[str, tuple[list[str], str]]:
    """Select unique, unconditional numeric function macros with simple bodies."""
    definitions: dict[str, list[tuple[list[str], str] | None]] = {}
    conditional_names: set[str] = set()
    conditional_depth = 0
    for line in source_text.splitlines():
        directive = PREPROCESSOR_DIRECTIVE.match(line)
        if directive is None:
            continue
        command = directive.group(1).casefold()
        tail = directive.group(2)
        if command in {"if", "ifdef", "ifndef"}:
            conditional_depth += 1
            continue
        if command == "endif":
            conditional_depth = max(0, conditional_depth - 1)
            continue
        if command != "define":
            continue

        definition = re.match(r"[ \t]+([A-Za-z_][A-Za-z_0-9]*)(.*)$", tail)
        if definition is None:
            continue
        name, suffix = definition.groups()
        if conditional_depth:
            conditional_names.add(name)
            continue
        if not suffix.startswith("("):
            definitions.setdefault(name, []).append(None)
            continue

        close_parenthesis = suffix.find(")")
        if close_parenthesis < 0:
            definitions.setdefault(name, []).append(None)
            continue
        raw_parameters = suffix[1:close_parenthesis].strip()
        body = suffix[close_parenthesis + 1:].strip()
        if raw_parameters:
            parameters = [item.strip() for item in raw_parameters.split(",")]
            if any(
                C_IDENTIFIER.fullmatch(parameter) is None or
                parameter.casefold() in FREEBASIC_MACRO_PARAMETER_KEYWORDS
                for parameter in parameters
            ) or len(set(parameters)) != len(parameters):
                definitions.setdefault(name, []).append(None)
                continue
        else:
            parameters = []
        if len(parameters) > 4 or not is_safe_integer_macro_expression(
            body, set(parameters)
        ):
            definitions.setdefault(name, []).append(None)
            continue
        definitions.setdefault(name, []).append((parameters, body))

    casefold_counts: dict[str, int] = {}
    for name in definitions:
        folded = name.casefold()
        casefold_counts[folded] = casefold_counts.get(folded, 0) + 1
    return {
        name: values[0]
        for name, values in definitions.items()
        if len(values) == 1 and values[0] is not None and
        name not in conditional_names and casefold_counts[name.casefold()] == 1
    }


def prefixed_binding_name(
    source_name: str, generated_names: set[str], prefix: str,
) -> str | None:
    """Find the emitted C2FB name for one source binding, including safe suffixes."""
    folded_prefix = prefix.casefold()
    exact = [
        name for name in generated_names
        if name.casefold() == (prefix + source_name).casefold()
    ]
    if len(exact) == 1:
        return exact[0]

    matches: list[str] = []
    for generated_name in generated_names:
        folded_name = generated_name.casefold()
        if not folded_name.startswith(folded_prefix):
            continue
        suffix = generated_name[len(prefix):]
        while suffix.endswith("_"):
            suffix = suffix[:-1]
            if suffix.casefold() == source_name.casefold():
                matches.append(generated_name)
                break
    return matches[0] if len(matches) == 1 else None


def emitted_macro_binding_name(
    source_name: str, generated_names: set[str], prefix: str,
) -> str | None:
    """Resolve prefixed C2FB names and explicit unprefixed rename targets."""
    generated_name = prefixed_binding_name(source_name, generated_names, prefix)
    if generated_name is not None:
        return generated_name
    exact = [
        name for name in generated_names
        if name.casefold() == source_name.casefold()
    ]
    return exact[0] if len(exact) == 1 else None


def safe_macro_value_options(options: list[str]) -> bool:
    """Allow options that change names or C long width, not macro expressions."""
    return all(
        option == "--clong32" or option.startswith("--rename=") or
        option.startswith("--rename-")
        for option in options
    )


def baseline_macro_binding_name(
    source_name: str, baseline_names: set[str], options: list[str],
) -> str | None:
    """Map a C macro through explicit renames and fbfrog's reserved-name suffix."""
    rename_targets: dict[str, list[str]] = {}
    for option in options:
        if option.startswith("--rename-define="):
            rename = option[len("--rename-define="):]
        elif option.startswith("--rename="):
            rename = option[len("--rename="):]
        else:
            continue
        if "=" not in rename:
            continue
        original, target = rename.split("=", 1)
        rename_targets.setdefault(original, []).append(target)

    target_name = source_name
    seen_targets: set[str] = set()
    while target_name in rename_targets:
        if target_name in seen_targets:
            return None
        seen_targets.add(target_name)
        targets = set(rename_targets[target_name])
        if len(targets) != 1:
            return None
        target_name = next(iter(targets))

    for candidate in (target_name, source_name):
        exact = [
            name for name in baseline_names
            if name.casefold() == candidate.casefold()
        ]
        if len(exact) == 1:
            return exact[0]
        if len(exact) > 1:
            return None

    folded_candidates = {target_name.casefold(), source_name.casefold()}
    suffixed = [
        name for name in baseline_names
        if name.rstrip("_").casefold() in folded_candidates
    ]
    return suffixed[0] if len(suffixed) == 1 else None


def run_freebasic_macro_value_probe(
    binding: Path, macro_names: list[tuple[str, str]], label: str,
    output_root: Path, tests_root: Path, fbc_command: list[str],
    preamble: list[str] | None = None,
    additional_include_directories: list[Path] | None = None,
) -> tuple[dict[str, str] | None, str | None]:
    """Compile and run a small value probe against one generated binding."""
    binding_name = str(binding.resolve())
    if any(character in binding_name for character in ('"', "\n", "\r", "\0")):
        return None, "binding path contains characters unsupported by the include wrapper"

    wrapper = output_root / f"macro-values-{label}.bas"
    executable = output_root / f"macro-values-{label}"
    lines = list(preamble or [])
    lines.append(f'#include once "{binding_name}"')
    lines.extend(f"Print Str({binding_name_text})" for _, binding_name_text in macro_names)
    wrapper.write_text("\n".join(lines) + "\n", encoding="utf-8")
    command = [
        *fbc_command, "-w", "all", str(wrapper), "-x", str(executable),
        "-i", str(tests_root), "-i", str(binding.parent.resolve()),
    ]
    for include_directory in additional_include_directories or []:
        command.extend(("-i", str(include_directory.resolve())))
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = (result.stdout + result.stderr).strip()
        return None, detail[:500]

    result = subprocess.run([str(executable)], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = (result.stdout + result.stderr).strip()
        return None, detail[:500]
    values = result.stdout.splitlines()
    if len(values) != len(macro_names):
        return None, (
            f"probe printed {len(values)} values for {len(macro_names)} macros"
        )
    return {
        source_name: value.strip()
        for (source_name, _), value in zip(macro_names, values)
    }, None


def run_freebasic_noninteger_macro_value_probe(
    binding: Path, macro_expressions: list[tuple[str, str, str]], label: str,
    output_root: Path, tests_root: Path, fbc_command: list[str],
    preamble: list[str] | None = None,
    additional_include_directories: list[Path] | None = None,
    string_byte_lengths: dict[str, int] | None = None,
    wide_string_unit_lengths: dict[str, tuple[int, int]] | None = None,
) -> tuple[dict[str, str] | None, str | None]:
    """Compare floating, narrow-string, and wide-string macro values."""
    binding_name = str(binding.resolve())
    if any(character in binding_name for character in ('"', "\n", "\r", "\0")):
        return None, "binding path contains characters unsupported by the include wrapper"

    wrapper = output_root / f"macro-noninteger-values-{label}.bas"
    executable = output_root / f"macro-noninteger-values-{label}"
    lines = list(preamble or [])
    if any(kind.startswith("wide-string") for _, _, kind in macro_expressions):
        lines.append('#include once "crt/wchar.bi"')
    lines.append(f'#include once "{binding_name}"')
    for index, (probe_name, expression, kind) in enumerate(macro_expressions):
        value_name = f"__c2fb_audit_value_{index}"
        if kind == "single":
            bits_name = f"__c2fb_audit_bits_{index}"
            lines.extend((
                f"Dim {value_name} As Single = {expression}",
                f"Dim {bits_name} As ULong = "
                f"*CPtr(ULong Ptr, @{value_name})",
                f'Print "{probe_name} " & Hex({bits_name}, 8)',
            ))
        elif kind == "double":
            bits_name = f"__c2fb_audit_bits_{index}"
            lines.extend((
                f"Dim {value_name} As Double = {expression}",
                f"Dim {bits_name} As ULongInt = "
                f"*CPtr(ULongInt Ptr, @{value_name})",
                f'Print "{probe_name} " & Hex({bits_name}, 16)',
            ))
        elif kind in {
            "string", "string-value", "string-nul", "string-value-nul",
        }:
            pointer_name = f"__c2fb_audit_string_{index}"
            length_name = f"__c2fb_audit_length_{index}"
            line_name = f"__c2fb_audit_line_{index}"
            byte_index_name = f"__c2fb_audit_byte_index_{index}"
            if kind == "string-value-nul":
                lines.append(
                    f"Dim {pointer_name} As ZString Ptr = StrPtr({expression})"
                )
            elif kind == "string-value":
                lines.extend((
                    f"Dim {value_name} As String = {expression}",
                    f"Dim {pointer_name} As ZString Ptr = StrPtr({value_name})",
                ))
            else:
                lines.extend((
                    f"Dim {pointer_name} As ZString Ptr = "
                    f"CPtr(ZString Ptr, {expression})",
                ))
            string_byte_length = (string_byte_lengths or {}).get(probe_name)
            if string_byte_length is not None:
                lines.append(
                    f"Dim {length_name} As Long = {string_byte_length}"
                )
            elif kind.endswith("-nul"):
                return None, (
                    f"embedded-NUL string {probe_name} needs a C-derived length"
                )
            elif kind.startswith("string-value"):
                lines.append(f"Dim {length_name} As Long = Len({value_name})")
            else:
                lines.append(f"Dim {length_name} As Long = Len(*{pointer_name})")
            lines.extend((
                f"Dim {line_name} As String = "
                f'"{probe_name} " & LTrim(Str({length_name}))',
                f"For {byte_index_name} As Long = 0 To {length_name}",
                f"    {line_name} &= \" \" & Hex( "
                f"Cast(UByte Ptr, {pointer_name})[{byte_index_name}], 2)",
                "Next",
                f"Print {line_name}",
            ))
        elif kind in {"wide-string", "wide-string-nul"}:
            wide_string_info = (wide_string_unit_lengths or {}).get(probe_name)
            if wide_string_info is None:
                return None, (
                    f"wide string {probe_name} needs C-derived unit length and width"
                )
            unit_count, unit_width = wide_string_info
            if unit_width not in {2, 4}:
                return None, f"unsupported C wchar_t width {unit_width}"
            pointer_name = f"__c2fb_audit_wstring_{index}"
            line_name = f"__c2fb_audit_wstring_line_{index}"
            unit_index_name = f"__c2fb_audit_wstring_index_{index}"
            lines.extend((
                f"Dim {pointer_name} As wchar_t Ptr = StrPtr({expression})",
                f"If SizeOf(wchar_t) <> {unit_width} Then",
                '    Print "__c2fb_wchar_width_mismatch"',
                "    End",
                "End If",
                f"Dim {line_name} As String = "
                f'"{probe_name} " & LTrim(Str({unit_count})) & " " & '
                f'LTrim(Str({unit_width}))',
            ))
            for_loop_value_type = "UShort" if unit_width == 2 else "ULong"
            for_loop_hex_width = unit_width * 2
            lines.extend((
                f"For {unit_index_name} As Long = 0 To {unit_count}",
                f"    {line_name} &= \" \" & Hex( "
                f"Cast({for_loop_value_type} Ptr, {pointer_name})"
                f"[{unit_index_name}], {for_loop_hex_width})",
                "Next",
                f"Print {line_name}",
            ))
        else:
            return None, f"unsupported noninteger macro probe kind {kind!r}"
    wrapper.write_text("\n".join(lines) + "\n", encoding="utf-8")
    command = [
        *fbc_command, "-w", "all", str(wrapper), "-x", str(executable),
        "-i", str(tests_root), "-i", str(binding.parent.resolve()),
    ]
    for include_directory in additional_include_directories or []:
        command.extend(("-i", str(include_directory.resolve())))
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = (result.stdout + result.stderr).strip()
        return None, detail[:500]
    result = subprocess.run([str(executable)], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = (result.stdout + result.stderr).strip()
        return None, detail[:500]
    if "__c2fb_wchar_width_mismatch" in result.stdout:
        return None, "C and FreeBASIC wchar_t widths differ; wide-string probe skipped"

    expressions_by_probe = {
        probe_name: kind for probe_name, _, kind in macro_expressions
    }
    values: dict[str, str] = {}
    for line in result.stdout.splitlines():
        parts = line.split()
        if not parts or parts[0] not in expressions_by_probe:
            continue
        kind = expressions_by_probe[parts[0]]
        if kind == "single":
            if len(parts) != 2 or re.fullmatch(r"[0-9A-Fa-f]{8}", parts[1]) is None:
                return None, f"invalid Single probe result {line!r}"
            values[parts[0]] = "single:" + parts[1].upper()
        elif kind == "double":
            if len(parts) != 2 or re.fullmatch(r"[0-9A-Fa-f]{16}", parts[1]) is None:
                return None, f"invalid Double probe result {line!r}"
            values[parts[0]] = "double:" + parts[1].upper()
        elif kind in {"string", "string-value", "string-nul", "string-value-nul"}:
            if len(parts) < 2 or re.fullmatch(r"[0-9]+", parts[1]) is None:
                return None, f"invalid string probe result {line!r}"
            byte_length = int(parts[1], 10)
            byte_values = parts[2:]
            if len(byte_values) != byte_length + 1 or any(
                re.fullmatch(r"[0-9A-Fa-f]{2}", value) is None
                for value in byte_values
            ):
                return None, f"invalid string byte probe result {line!r}"
            values[parts[0]] = (
                "string:" + str(byte_length) + ":" +
                "".join(value.upper() for value in byte_values)
            )
        else:
            if len(parts) < 4 or any(
                re.fullmatch(r"[0-9]+", value) is None for value in parts[1:3]
            ):
                return None, f"invalid wide-string probe result {line!r}"
            unit_count = int(parts[1], 10)
            unit_width = int(parts[2], 10)
            unit_values = parts[3:]
            if unit_width not in {2, 4} or len(unit_values) != unit_count + 1 or any(
                re.fullmatch(rf"[0-9A-Fa-f]{{{unit_width * 2}}}", value) is None
                for value in unit_values
            ):
                return None, f"invalid wide-string code units {line!r}"
            values[parts[0]] = (
                "wide-string:" + str(unit_count) + ":" + str(unit_width) + ":" +
                "".join(value.upper() for value in unit_values)
            )
    if len(values) != len(macro_expressions):
        return None, (
            f"probe printed {len(values)} values for "
            f"{len(macro_expressions)} macros"
        )
    return values, None


def run_c_noninteger_macro_value_probe(
    macro_dump: str, macro_expressions: list[tuple[str, str, str]],
    label: str, output_root: Path, compiler: str, cpp_mode: bool,
    source_path: Path | None = None,
    compiler_options: list[str] | None = None,
) -> tuple[dict[str, str] | None, str | None]:
    """Read floating, narrow-string, and wide-string macro values from C."""
    try:
        compiler_parts = shlex.split(compiler)
    except ValueError as error:
        return None, f"invalid C compiler command: {error}"
    if not compiler_parts:
        return None, "empty C compiler command"

    safe_label = re.sub(r"[^A-Za-z0-9_-]", "_", label)
    source_include: str | None = None
    if source_path is not None:
        source_include = str(source_path.resolve())
        if any(character in source_include for character in ('"', "\n", "\r", "\0")):
            source_include = None

    active_definitions: dict[str, str] = {}
    for line in macro_dump.splitlines():
        directive = PREPROCESSOR_DIRECTIVE.match(line)
        if directive is None or directive.group(1).casefold() != "define":
            continue
        definition = re.match(
            r"[ \t]+([A-Za-z_][A-Za-z_0-9]*)(.*)$", directive.group(2))
        if definition is None:
            continue
        name, suffix = definition.groups()
        if suffix.startswith("(") or not suffix or not suffix[0].isspace():
            continue
        if suffix.rstrip().endswith("\\"):
            continue
        active_definitions[name] = line

    def make_source_wrapper(include_source: bool) -> tuple[Path, Path, str | None]:
        wrapper = output_root / (
            f"c-macro-noninteger-values-{safe_label}.cpp" if cpp_mode else
            f"c-macro-noninteger-values-{safe_label}.c"
        )
        executable = output_root / f"c-macro-noninteger-values-{safe_label}"
        lines = [
            "#include <limits.h>", "#include <stdint.h>",
            "#include <stdio.h>", "#include <string.h>", "#include <wchar.h>",
        ]
        if include_source:
            assert source_include is not None
            lines.append(f'#include "{source_include}"')
        else:
            selected_names = {expression for _, expression, _ in macro_expressions}
            for name in sorted(selected_names):
                definition = active_definitions.get(name)
                if definition is None:
                    return wrapper, executable, f"active C macro dump has no definition for {name}"
                lines.extend(("#undef " + name, definition))
        lines.extend(("#undef printf", "#undef main", "int main(void)", "{"))
        lines.append(
            "    if (CHAR_BIT != 8 || sizeof(float) != sizeof(uint32_t) || "
            "sizeof(double) != sizeof(uint64_t)) return 1;"
        )
        for index, (probe_name, expression, kind) in enumerate(macro_expressions):
            if kind == "single":
                lines.extend((
                    "    {",
                    f"        float value_{index} = (float)({expression});",
                    f"        uint32_t bits_{index};",
                    f"        memcpy(&bits_{index}, &value_{index}, sizeof(bits_{index}));",
                    f'        printf("{probe_name} single %08X\\n", (unsigned int)bits_{index});',
                    "    }",
                ))
            elif kind == "double":
                lines.extend((
                    "    {",
                    f"        double value_{index} = (double)({expression});",
                    f"        uint64_t bits_{index};",
                    f"        memcpy(&bits_{index}, &value_{index}, sizeof(bits_{index}));",
                    f'        printf("{probe_name} double %016llX\\n", (unsigned long long)bits_{index});',
                    "    }",
                ))
            elif kind in {"string", "string-nul"}:
                lines.extend((
                    "    {",
                    f"        const unsigned char *value_{index} = ",
                    f"            (const unsigned char *)({expression});",
                    f"        size_t length_{index} = sizeof({expression}) - 1;",
                    f'        printf("{probe_name} %zu", length_{index});',
                    f"        for (size_t byte_{index} = 0; byte_{index} <= length_{index}; ++byte_{index}) {{",
                    f'            printf(" %02X", (unsigned int)value_{index}[byte_{index}]);',
                    "        }",
                    "        putchar('\\n');",
                    "    }",
                ))
            elif kind in {"wide-string", "wide-string-nul"}:
                lines.extend((
                    "    {",
                    f"        const wchar_t *value_{index} = ",
                    f"            (const wchar_t *)({expression});",
                    f"        size_t units_{index} = "
                    f"sizeof({expression}) / sizeof(wchar_t) - 1;",
                    f'        printf("{probe_name} %zu %zu", units_{index}, sizeof(wchar_t));',
                    f"        for (size_t unit_{index} = 0; unit_{index} <= units_{index}; ++unit_{index}) {{",
                    f'            printf(" %0*X", (int)(sizeof(wchar_t) * 2), (unsigned int)value_{index}[unit_{index}]);',
                    "        }",
                    "        putchar('\\n');",
                    "    }",
                ))
            else:
                return wrapper, executable, f"unsupported noninteger macro probe kind {kind!r}"
        lines.extend(("    return 0;", "}", ""))
        wrapper.write_text("\n".join(lines), encoding="utf-8")
        return wrapper, executable, None

    def compile_and_read(wrapper: Path, executable: Path) -> tuple[str | None, str | None]:
        command = [*compiler_parts, *(compiler_options or [])]
        command.extend((
            "-x", "c++" if cpp_mode else "c", "-ffunction-sections",
            "-fdata-sections", str(wrapper), "-Wl,--gc-sections", "-o",
            str(executable),
        ))
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        if result.returncode != 0 and cpp_mode:
            compiler_basename = Path(compiler_parts[0]).name.casefold()
            clang_compiler = shutil.which("clang++")
            if clang_compiler and compiler_basename not in {"clang", "clang++"}:
                fallback_command = [
                    clang_compiler, *compiler_parts[1:], *(compiler_options or []),
                    "-x", "c++", "-ffunction-sections", "-fdata-sections",
                    str(wrapper), "-Wl,--gc-sections", "-o", str(executable),
                ]
                result = subprocess.run(
                    fallback_command, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            detail = (result.stdout + result.stderr).strip()
            return None, detail[:500]
        result = subprocess.run(
            [str(executable)], capture_output=True, text=True, check=False)
        if result.returncode != 0:
            detail = (result.stdout + result.stderr).strip()
            return None, detail[:500]
        return result.stdout, None

    result_text: str | None = None
    source_error: str | None = None
    if source_include is not None:
        wrapper, executable, wrapper_error = make_source_wrapper(True)
        if wrapper_error is None:
            result_text, source_error = compile_and_read(wrapper, executable)
        else:
            source_error = wrapper_error
        if source_error is not None and source_path is not None:
            try:
                original_text = source_path.read_text(
                    encoding="utf-8", errors="replace")
            except OSError:
                original_text = ""
            if re.search(r"\b(?:push_macro|pop_macro)\b", original_text):
                return None, (
                    "source-context C probe failed for a stateful macro pragma: "
                    + source_error[:400]
                )

    if result_text is None:
        wrapper, executable, wrapper_error = make_source_wrapper(False)
        if wrapper_error is not None:
            if source_error is not None:
                return None, source_error
            return None, wrapper_error
        result_text, fallback_error = compile_and_read(wrapper, executable)
        if fallback_error is not None:
            return None, fallback_error

    assert result_text is not None
    kinds_by_name = {probe_name: kind for probe_name, _, kind in macro_expressions}
    values: dict[str, str] = {}
    for line in result_text.splitlines():
        parts = line.split()
        if not parts or parts[0] not in kinds_by_name:
            continue
        kind = kinds_by_name[parts[0]]
        if kind == "single":
            if len(parts) != 3 or parts[1] != "single" or \
               re.fullmatch(r"[0-9A-Fa-f]{8}", parts[2]) is None:
                return None, f"invalid C Single probe result {line!r}"
            values[parts[0]] = "single:" + parts[2].upper()
        elif kind == "double":
            if len(parts) != 3 or parts[1] != "double" or \
               re.fullmatch(r"[0-9A-Fa-f]{16}", parts[2]) is None:
                return None, f"invalid C Double probe result {line!r}"
            values[parts[0]] = "double:" + parts[2].upper()
        elif kind in {"string", "string-nul"}:
            if len(parts) < 2 or re.fullmatch(r"[0-9]+", parts[1]) is None:
                return None, f"invalid C string probe result {line!r}"
            byte_length = int(parts[1], 10)
            byte_values = parts[2:]
            if len(byte_values) != byte_length + 1 or any(
                re.fullmatch(r"[0-9A-Fa-f]{2}", value) is None
                for value in byte_values
            ):
                return None, f"invalid C string byte probe result {line!r}"
            values[parts[0]] = (
                "string:" + str(byte_length) + ":" +
                "".join(value.upper() for value in byte_values)
            )
        elif kind in {"wide-string", "wide-string-nul"}:
            if len(parts) < 3 or any(
                re.fullmatch(r"[0-9]+", value) is None for value in parts[1:3]
            ):
                return None, f"invalid C wide-string probe result {line!r}"
            unit_count = int(parts[1], 10)
            unit_width = int(parts[2], 10)
            unit_values = parts[3:]
            if unit_width not in {2, 4} or len(unit_values) != unit_count + 1 or any(
                re.fullmatch(rf"[0-9A-Fa-f]{{{unit_width * 2}}}", value) is None
                for value in unit_values
            ):
                return None, f"invalid C wide-string code units {line!r}"
            values[parts[0]] = (
                "wide-string:" + str(unit_count) + ":" + str(unit_width) + ":" +
                "".join(value.upper() for value in unit_values)
            )
        else:
            return None, f"unsupported C noninteger macro kind {kind!r}"
    if len(values) != len(macro_expressions):
        return None, (
            f"C probe printed {len(values)} values for "
            f"{len(macro_expressions)} macros"
        )
    return values, None


def run_freebasic_macro_presence_probe(
    binding: Path, macro_names: list[tuple[str, str]], label: str,
    output_root: Path, tests_root: Path, fbc_command: list[str],
    preamble: list[str] | None = None,
    additional_include_directories: list[Path] | None = None,
) -> tuple[dict[str, bool] | None, str | None]:
    """Compile and run definedness probes for selected preprocessor macros."""
    binding_name = str(binding.resolve())
    if any(character in binding_name for character in ('"', "\n", "\r", "\0")):
        return None, "binding path contains characters unsupported by the include wrapper"

    wrapper = output_root / f"macro-presence-{label}.bas"
    executable = output_root / f"macro-presence-{label}"
    lines = list(preamble or [])
    lines.append(f'#include once "{binding_name}"')
    for _, macro_name in macro_names:
        lines.extend((
            f"#ifdef {macro_name}", "Print 1", "#else", "Print 0", "#endif",
        ))
    wrapper.write_text("\n".join(lines) + "\n", encoding="utf-8")
    command = [
        *fbc_command, "-w", "all", str(wrapper), "-x", str(executable),
        "-i", str(tests_root), "-i", str(binding.parent.resolve()),
    ]
    for include_directory in additional_include_directories or []:
        command.extend(("-i", str(include_directory.resolve())))
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = (result.stdout + result.stderr).strip()
        return None, detail[:500]

    result = subprocess.run([str(executable)], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = (result.stdout + result.stderr).strip()
        return None, detail[:500]
    values = result.stdout.splitlines()
    if len(values) != len(macro_names):
        return None, (
            f"probe printed {len(values)} presence values for "
            f"{len(macro_names)} macros"
        )
    return {
        source_name: value.strip() == "1"
        for (source_name, _), value in zip(macro_names, values)
    }, None


def run_c_macro_value_wrapper(
    wrapper: Path, executable: Path,
    macro_expressions: list[tuple[str, str]],
    compiler_parts: list[str], cpp_mode: bool,
    compiler_options: list[str] | None = None,
) -> tuple[dict[str, int] | None, str | None]:
    command = [*compiler_parts, *(compiler_options or [])]
    command.extend(("-x", "c++" if cpp_mode else "c"))
    command.extend((
        "-ffunction-sections", "-fdata-sections", str(wrapper),
        "-Wl,--gc-sections", "-o", str(executable),
    ))
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0 and cpp_mode:
        compiler_basename = Path(compiler_parts[0]).name.casefold()
        clang_compiler = shutil.which("clang++")
        if clang_compiler and compiler_basename not in {"clang", "clang++"}:
            fallback_command = [
                clang_compiler, *compiler_parts[1:], *(compiler_options or []),
                "-x", "c++", "-ffunction-sections", "-fdata-sections",
                str(wrapper), "-Wl,--gc-sections", "-o", str(executable),
            ]
            result = subprocess.run(
                fallback_command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = (result.stdout + result.stderr).strip()
        return None, detail[:500]

    result = subprocess.run([str(executable)], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = (result.stdout + result.stderr).strip()
        return None, detail[:500]
    values = result.stdout.splitlines()
    if len(values) != len(macro_expressions):
        return None, (
            f"C probe printed {len(values)} values for "
            f"{len(macro_expressions)} macros"
        )
    parsed_values: dict[str, int] = {}
    for (macro_name, _), value in zip(macro_expressions, values):
        value = value.strip()
        if re.fullmatch(r"[0-9A-Fa-f]{16}", value) is None:
            return None, f"C probe printed invalid integer value {value!r}"
        parsed_values[macro_name] = int(value, 16)
    return parsed_values, None


def run_c_record_layout_probe(
    source: Path, c_types: list[str], fields: list[str], label: str,
    output_root: Path, compiler: str, compiler_options: list[str],
    cpp_mode: bool,
) -> tuple[dict[str, int] | None, str | None]:
    """Measure C record sizes and field offsets using the selected C compiler."""
    try:
        compiler_parts = shlex.split(compiler)
    except ValueError as error:
        return None, f"invalid C compiler command: {error}"
    if not compiler_parts:
        return None, "empty C compiler command"
    source_path = str(source.resolve())
    if any(character in source_path for character in ('"', "\n", "\r", "\0")):
        return None, "C source path cannot be included in a layout probe"
    safe_label = re.sub(r"[^A-Za-z0-9_-]", "_", label)
    last_error = "C compiler could not identify the record type"
    field_probe_index = 0

    def run_for_type(type_name: str, probe_fields: list[str], suffix: str):
        wrapper = output_root / f"c-record-layout-{safe_label}-{suffix}.cpp" \
            if cpp_mode else output_root / f"c-record-layout-{safe_label}-{suffix}.c"
        executable = output_root / f"c-record-layout-{safe_label}-{suffix}"
        lines = [
            f"#include {json.dumps(source_path)}",
            "#undef printf",
            "#include <stddef.h>",
            "#include <stdio.h>",
            "int main(void)",
            "{",
            '    printf("%llu\\n", (unsigned long long)sizeof(' +
                type_name + "));",
        ]
        for field_name in probe_fields:
            lines.append(
                '    printf("%llu\\n", '
                f"(unsigned long long)offsetof({type_name}, {field_name}));"
            )
        lines.extend(("    return 0;", "}"))
        wrapper.write_text("\n".join(lines) + "\n", encoding="utf-8")
        command = [*compiler_parts, *compiler_options]
        command.extend(("-x", "c++" if cpp_mode else "c"))
        command.extend((str(wrapper), "-o", str(executable)))
        result = subprocess.run(
            command, capture_output=True, text=True, check=False)
        if result.returncode != 0 and cpp_mode:
            compiler_basename = Path(compiler_parts[0]).name.casefold()
            clang_compiler = shutil.which("clang++")
            if clang_compiler and compiler_basename not in {"clang", "clang++"}:
                fallback_command = [
                    clang_compiler, *compiler_parts[1:], *compiler_options,
                    "-x", "c++", str(wrapper), "-o", str(executable),
                ]
                result = subprocess.run(
                    fallback_command, capture_output=True, text=True,
                    check=False,
                )
        if result.returncode != 0:
            detail = " ".join((result.stdout + result.stderr).split())
            return None, detail[:400]
        result = subprocess.run(
            [str(executable)], capture_output=True, text=True, check=False)
        if result.returncode != 0:
            detail = " ".join((result.stdout + result.stderr).split())
            return None, detail[:400]
        values = result.stdout.splitlines()
        if len(values) != len(probe_fields) + 1:
            return None, "C layout probe returned an unexpected value count"
        try:
            parsed_values = [int(value.strip(), 10) for value in values]
        except ValueError:
            return None, "C layout probe returned a non-integer value"
        return parsed_values, None

    for candidate_index, type_name in enumerate(c_types):
        values, error = run_for_type(
            type_name, fields, f"{candidate_index}-full")
        if error is None:
            assert values is not None
            return {
                "sizeof": values[0],
                **{
                    field_name.casefold(): value
                    for field_name, value in zip(fields, values[1:])
                },
            }, None
        last_error = error
        if not fields:
            continue
        values, error = run_for_type(
            type_name, [], f"{candidate_index}-size")
        if error is not None:
            last_error = error
            continue
        assert values is not None
        metrics = {"sizeof": values[0]}

        def probe_field_group(field_names: list[str]) -> None:
            nonlocal field_probe_index
            if not field_names:
                return
            suffix = f"{candidate_index}-fields-{field_probe_index}"
            field_probe_index += 1
            group_values, group_error = run_for_type(
                type_name, field_names, suffix)
            if group_error is None and group_values is not None:
                for field_name, value in zip(field_names, group_values[1:]):
                    metrics[field_name.casefold()] = value
                return
            if len(field_names) == 1:
                return
            middle = len(field_names) // 2
            probe_field_group(field_names[:middle])
            probe_field_group(field_names[middle:])

        probe_field_group(fields)
        return metrics, None
    type_source, type_source_error = preprocessed_c_type_declarations(
        str(source.resolve()), tuple(compiler_parts),
        tuple(compiler_options), cpp_mode)
    if type_source is not None:
        for candidate_index, type_name in enumerate(c_types):
            values, error = run_c_type_slice_layout_probe(
                type_source, type_name, fields,
                f"{safe_label}-{candidate_index}-full", output_root,
                compiler_parts, compiler_options, cpp_mode,
            )
            if error is None and values is not None:
                return {
                    "sizeof": values[0],
                    **{
                        field_name.casefold(): value
                        for field_name, value in zip(fields, values[1:])
                    },
                }, None
            if not fields:
                continue
            values, error = run_c_type_slice_layout_probe(
                type_source, type_name, [],
                f"{safe_label}-{candidate_index}-size", output_root,
                compiler_parts, compiler_options, cpp_mode,
            )
            if error is not None or values is None:
                continue
            metrics = {"sizeof": values[0]}

            def probe_type_slice_field_group(field_names: list[str]) -> None:
                nonlocal field_probe_index
                if not field_names:
                    return
                suffix = (
                    f"{safe_label}-{candidate_index}-fields-"
                    f"{field_probe_index}"
                )
                field_probe_index += 1
                group_values, group_error = run_c_type_slice_layout_probe(
                    type_source, type_name, field_names, suffix, output_root,
                    compiler_parts, compiler_options, cpp_mode,
                )
                if group_error is None and group_values is not None:
                    for field_name, value in zip(
                        field_names, group_values[1:]):
                        metrics[field_name.casefold()] = value
                    return
                if len(field_names) == 1:
                    return
                middle = len(field_names) // 2
                probe_type_slice_field_group(field_names[:middle])
                probe_type_slice_field_group(field_names[middle:])

            probe_type_slice_field_group(fields)
            return metrics, None
    elif type_source_error:
        last_error = type_source_error
    clang_layouts = clang_record_layouts_for_source(
        source, compiler_parts, compiler_options, cpp_mode)
    for type_name in c_types:
        tag = re.fullmatch(r"(struct|union|class)[ \t]+(.+)", type_name)
        if tag is None:
            continue
        record_layout = clang_layouts.get((
            tag.group(1).casefold(), tag.group(2).casefold()))
        if record_layout is None:
            continue
        metrics = {"sizeof": int(record_layout["sizeof"])}
        field_offsets = record_layout["fields"]
        for field_name in fields:
            if field_name.casefold() in field_offsets:
                metrics[field_name.casefold()] = int(
                    field_offsets[field_name.casefold()])
        return metrics, None
    return None, last_error


def run_freebasic_record_layout_probe(
    binding: Path, type_name: str, fields: list[str], label: str,
    output_root: Path, tests_root: Path, fbc_command: list[str],
    preamble: list[str] | None = None,
) -> tuple[dict[str, int] | None, str | None]:
    """Measure a FreeBASIC record's size and addressable member offsets."""
    binding_name = str(binding.resolve())
    if any(character in binding_name for character in ('"', "\n", "\r", "\0")):
        return None, "binding path contains characters unsupported by the layout wrapper"
    safe_label = re.sub(r"[^A-Za-z0-9_-]", "_", label)
    last_error = "FreeBASIC compiler could not measure the record type"

    def run_for_fields(probe_fields: list[str], suffix: str):
        wrapper = output_root / f"fb-record-layout-{safe_label}-{suffix}.bas"
        executable = output_root / f"fb-record-layout-{safe_label}-{suffix}"
        lines = list(preamble or [])
        lines.extend((
            f'#include once "{binding_name}"',
            f"Dim c2fbLayoutValue As {type_name}",
            f"Print SizeOf({type_name})",
        ))
        for field_name in probe_fields:
            lines.append(
                f"Print CULngInt(@c2fbLayoutValue.{field_name})-"
                "CULngInt(@c2fbLayoutValue)"
            )
        wrapper.write_text("\n".join(lines) + "\n", encoding="utf-8")
        command = [
            *fbc_command, "-w", "all", str(wrapper), "-x", str(executable),
            "-i", str(tests_root), "-i", str(binding.parent.resolve()),
        ]
        result = subprocess.run(
            command, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            detail = " ".join((result.stdout + result.stderr).split())
            return None, detail[:400]
        result = subprocess.run(
            [str(executable)], capture_output=True, text=True, check=False)
        if result.returncode != 0:
            detail = " ".join((result.stdout + result.stderr).split())
            return None, detail[:400]
        values = result.stdout.splitlines()
        if len(values) != len(probe_fields) + 1:
            return None, "FreeBASIC layout probe returned an unexpected value count"
        try:
            parsed_values = [int(value.strip(), 10) for value in values]
        except ValueError:
            return None, "FreeBASIC layout probe returned a non-integer value"
        return parsed_values, None

    values, error = run_for_fields(fields, "full")
    if error is None:
        assert values is not None
        return {
            "sizeof": values[0],
            **{
                field_name.casefold(): value
                for field_name, value in zip(fields, values[1:])
            },
        }, None
    last_error = error
    if not fields:
        return None, last_error
    values, error = run_for_fields([], "size")
    if error is not None:
        return None, error
    assert values is not None
    metrics = {"sizeof": values[0]}

    def probe_field_group(field_names: list[str]) -> None:
        nonlocal last_error
        if not field_names:
            return
        suffix = f"fields-{len(metrics)}-{field_names[0]}"
        values, error = run_for_fields(field_names, suffix)
        if error is None and values is not None:
            for field_name, value in zip(field_names, values[1:]):
                metrics[field_name.casefold()] = value
            return
        last_error = error
        if len(field_names) == 1:
            return
        middle = len(field_names) // 2
        probe_field_group(field_names[:middle])
        probe_field_group(field_names[middle:])

    probe_field_group(fields)
    return metrics, None


def c_record_type_candidates(
    freebasic_name: str, record_kind: str, options: list[str],
    prefer_tag: bool = False,
) -> list[str]:
    """Map a FreeBASIC record name back to likely C typedefs and tags."""
    source_names: list[str] = []
    rename_prefixes = (
        "--rename=", "--rename-tag=", "--rename-typedef=",
    )
    for option in options:
        for prefix in rename_prefixes:
            if not option.startswith(prefix):
                continue
            mapping = option[len(prefix):]
            if "=" not in mapping:
                continue
            source_name, target_name = mapping.split("=", 1)
            if target_name.casefold() == freebasic_name.casefold():
                source_names.append(source_name)
            break
    source_names.append(freebasic_name)
    while source_names[-1].endswith("_"):
        source_names.append(source_names[-1][:-1])

    candidates: list[str] = []
    for source_name in source_names:
        if not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", source_name):
            continue
        tag_names = (
            ["union", "struct", "class"]
            if record_kind == "union" else
            ["struct", "union", "class"]
        )
        tagged_candidates = [
            f"{tag_name} {source_name}" for tag_name in tag_names
        ]
        ordered_candidates = (
            [*tagged_candidates, source_name]
            if prefer_tag else
            [source_name, *tagged_candidates]
        )
        for candidate in ordered_candidates:
            if candidate not in candidates:
                candidates.append(candidate)
    return candidates


def parse_clang_record_layout_dump(
    text: str,
) -> dict[tuple[str, str], dict[str, object]]:
    """Read sizes and addressable member offsets from Clang's layout dump."""
    layouts: dict[tuple[str, str], dict[str, object]] = {}
    for block in text.split("*** Dumping AST Record Layout"):
        lines = block.splitlines()
        header_index = -1
        record_kind = ""
        record_name = ""
        for line_index, line in enumerate(lines):
            match = re.match(
                r"^[ \t]*\d+[ \t]*\|[ \t]*(struct|union|class)[ \t]+"
                r"([^\r\n]+?)\s*$",
                line,
            )
            if match is not None:
                record_kind = match.group(1).casefold()
                record_name = match.group(2).strip()
                header_index = line_index
                break
        if header_index < 0 or "(anonymous" in record_name:
            continue
        size_match = re.search(r"\[sizeof=(\d+),[ \t]*align=\d+\]", block)
        if size_match is None:
            continue
        member_offsets: dict[str, int] = {}
        for line in lines[header_index + 1:]:
            member_line = re.match(
                r"^[ \t]*(\d+)[ \t]*\|[ \t]{2,}(.+?)\s*$", line)
            if member_line is None:
                continue
            member_text = member_line.group(2)
            if "(anonymous" in member_text:
                continue
            identifiers = C_IDENTIFIER.findall(member_text)
            if not identifiers:
                continue
            member_offsets[identifiers[-1].casefold()] = int(
                member_line.group(1), 10)
        layouts[(record_kind, record_name.casefold())] = {
            "sizeof": int(size_match.group(1), 10),
            "fields": member_offsets,
        }
    return layouts


def clang_record_layouts_for_source(
    source: Path, compiler_parts: list[str], compiler_options: list[str],
    cpp_mode: bool,
) -> dict[tuple[str, str], dict[str, object]]:
    """Ask a host-matching Clang frontend for layouts despite unrelated errors."""
    try:
        source_text = C_NON_CODE_TEXT.sub(
            " ", source.read_text(encoding="utf-8", errors="replace"))
    except OSError:
        return {}
    if re.search(
        r"__attribute(?:__)?[ \t]*\([ \t]*\([^)]*"
        r"\b(?:packed|aligned|gcc_struct|ms_struct)\b|"
        r"__declspec[ \t]*\([ \t]*align[ \t]*\(|"
        r"__pragma[ \t]*\([ \t]*pack[ \t]*\(|"
        r"#[ \t]*pragma[ \t]+(?:pack|options[ \t]+align)\b",
        source_text, re.I,
    ):
        # GCC and Clang disagree on some source placements for packing and
        # alignment attributes. Do not turn that frontend difference into a
        # false ABI report; the configured C compiler remains authoritative.
        return {}
    clang_compiler = shutil.which("clang++" if cpp_mode else "clang")
    if clang_compiler is None:
        return {}
    target_options = {
        "-target", "--target", "-m32", "-m64", "-mabi", "-arch",
    }
    has_explicit_target = any(
        option in target_options or
        any(option.startswith(prefix + "=") for prefix in ("-target", "--target", "-mabi", "-arch"))
        for option in compiler_options
    )
    compiler_name = Path(compiler_parts[0]).name.casefold()
    if not has_explicit_target and any(
        token in compiler_name
        for token in ("mingw", "aarch64", "arm-", "i686", "i386", "wasm")
    ):
        return {}
    source_path = str(source.resolve())
    if any(character in source_path for character in ('"', "\n", "\r", "\0")):
        return {}
    language = "c++" if cpp_mode else "c"
    command = [
        clang_compiler, *compiler_options, "-x", language,
        "-Xclang", "-fdump-record-layouts-complete",
        "-fsyntax-only", source_path,
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    return parse_clang_record_layout_dump(result.stdout + result.stderr)


def extend_c_record_declaration(source_text: str, end: int) -> int:
    """Keep trailing type attributes attached to a record declaration."""
    position = end
    while position < len(source_text) and source_text[position].isspace():
        position += 1
    if re.match(
        r"(?:__attribute(?:__)?|__declspec|alignas|\[\[)",
        source_text[position:], re.I,
    ) is None:
        return end
    parenthesis_depth = 0
    bracket_depth = 0
    quote_character: str | None = None
    escaped = False
    while position < len(source_text):
        character = source_text[position]
        if quote_character is not None:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote_character:
                quote_character = None
        elif character in {'"', "'"}:
            quote_character = character
        elif character == "(":
            parenthesis_depth += 1
        elif character == ")":
            parenthesis_depth = max(0, parenthesis_depth - 1)
        elif character == "[":
            bracket_depth += 1
        elif character == "]":
            bracket_depth = max(0, bracket_depth - 1)
        elif character == ";" and parenthesis_depth == 0 and bracket_depth == 0:
            return position + 1
        position += 1
    return end


def compiler_options_for_preprocessed_types(
    compiler_options: list[str],
) -> list[str]:
    """Drop preprocessor-only options after their effects have been captured."""
    filtered: list[str] = []
    skip_next = False
    for option in compiler_options:
        if skip_next:
            skip_next = False
            continue
        if option in {"-D", "-U", "-include", "-imacros"}:
            skip_next = True
            continue
        if option.startswith(("-D", "-U", "-include=", "-imacros=")):
            continue
        filtered.append(option)
    return filtered


@functools.lru_cache(maxsize=24)
def preprocessed_c_type_declarations(
    source_path: str, compiler_parts: tuple[str, ...],
    compiler_options: tuple[str, ...], cpp_mode: bool,
) -> tuple[str | None, str | None]:
    """Extract type-only declarations after the configured compiler preprocesses them."""
    try:
        language = "c++" if cpp_mode else "c"
        preprocess_command = [
            *compiler_parts, *compiler_options, "-x", language,
            "-E", "-P", source_path,
        ]
        result = subprocess.run(
            preprocess_command, capture_output=True, text=True, check=False)
    except OSError as error:
        return None, f"cannot run C preprocessor for record types: {error}"
    if result.returncode != 0 or result.stdout == "":
        detail = " ".join((result.stdout + result.stderr).split())
        return None, "C preprocessor could not isolate record types: " + detail[:300]

    clang_name = shutil.which("clang++" if cpp_mode else "clang")
    if clang_name is None:
        return None, "Clang is unavailable for C type declaration extraction"
    with tempfile.TemporaryDirectory(prefix="c2fb-record-types-") as directory:
        preprocessed_path = Path(directory) / (
            "preprocessed.cpp" if cpp_mode else "preprocessed.c")
        preprocessed_path.write_text(result.stdout, encoding="utf-8")
        ast_command = [
            clang_name, "-x", language, "-Xclang", "-ast-dump=json",
            "-fsyntax-only", str(preprocessed_path),
        ]
        try:
            ast_result = subprocess.run(
                ast_command, capture_output=True, text=True, check=False)
        except OSError as error:
            return None, f"cannot run Clang AST parser for record types: {error}"
        json_start = ast_result.stdout.find("{")
        if json_start < 0:
            detail = " ".join((ast_result.stdout + ast_result.stderr).split())
            return None, "Clang could not identify C record declarations: " + detail[:300]
        try:
            translation_unit = json.loads(ast_result.stdout[json_start:])
        except json.JSONDecodeError as error:
            return None, f"Clang returned an invalid AST for record declarations: {error}"

    preprocessed_text = result.stdout
    declaration_kinds = {
        "RecordDecl", "EnumDecl", "TypedefDecl", "CXXRecordDecl",
        "TypeAliasDecl", "ClassTemplateDecl", "ClassTemplateSpecializationDecl",
    }
    spans: list[tuple[int, int]] = []

    def collect_declarations(node: object) -> None:
        if not isinstance(node, dict):
            return
        if node.get("kind") in declaration_kinds:
            source_range = node.get("range", {})
            begin = source_range.get("begin", {})
            end = source_range.get("end", {})
            begin_offset = begin.get("offset")
            end_offset = end.get("offset")
            if isinstance(begin_offset, int) and isinstance(end_offset, int):
                declaration_end = end_offset + int(end.get("tokLen", 0))
                if declaration_end > begin_offset:
                    declaration_end = extend_c_record_declaration(
                        preprocessed_text, declaration_end)
                    spans.append((begin_offset, declaration_end))
        for child in node.get("inner", []):
            collect_declarations(child)

    collect_declarations(translation_unit)
    for pragma in re.finditer(
        r"(?m)^[ \t]*#[ \t]*pragma[ \t]+"
        r"(?:pack|ms_struct|scalar_storage_order|options[ \t]+align)\b"
        r"[^\r\n]*",
        preprocessed_text, re.I,
    ):
        spans.append((pragma.start(), pragma.end()))
    spans.sort()

    merged_spans: list[tuple[int, int]] = []
    for begin_offset, end_offset in spans:
        if merged_spans and begin_offset <= merged_spans[-1][1]:
            merged_spans[-1] = (
                merged_spans[-1][0], max(merged_spans[-1][1], end_offset))
        else:
            merged_spans.append((begin_offset, end_offset))

    declarations: list[str] = []
    for begin_offset, end_offset in merged_spans:
        declaration = preprocessed_text[begin_offset:end_offset].strip()
        if declaration == "":
            continue
        if not declaration.startswith("#") and not declaration.endswith(";"):
            declaration += ";"
        declarations.append(declaration)
    if not declarations:
        return None, "Clang AST contained no C record, enum, or typedef declarations"
    return "\n".join(declarations), None


def run_c_type_slice_layout_probe(
    type_declarations: str, type_name: str, fields: list[str], suffix: str,
    output_root: Path, compiler_parts: list[str],
    compiler_options: list[str], cpp_mode: bool,
) -> tuple[list[int] | None, str | None]:
    """Compile an isolated C type slice so unrelated prototypes cannot block ABI checks."""
    wrapper = output_root / f"c-record-type-slice-{suffix}.cpp" \
        if cpp_mode else output_root / f"c-record-type-slice-{suffix}.c"
    executable = output_root / f"c-record-type-slice-{suffix}"
    printf_declaration = (
        'extern "C" int printf(const char *, ...);'
        if cpp_mode else "extern int printf(const char *, ...);"
    )
    lines = [
        type_declarations,
        printf_declaration,
        "int main(void)",
        "{",
        '    printf("%llu\\n", (unsigned long long)sizeof(' +
            type_name + "));",
    ]
    for field_name in fields:
        lines.append(
            '    printf("%llu\\n", '
            f"(unsigned long long)__builtin_offsetof({type_name}, {field_name}));"
        )
    lines.extend(("    return 0;", "}"))
    wrapper.write_text("\n".join(lines) + "\n", encoding="utf-8")
    type_options = compiler_options_for_preprocessed_types(compiler_options)
    command = [*compiler_parts, *type_options, "-x", "c++" if cpp_mode else "c"]
    command.extend((str(wrapper), "-o", str(executable)))
    try:
        result = subprocess.run(
            command, capture_output=True, text=True, check=False)
    except OSError as error:
        return None, f"cannot run C compiler on isolated record types: {error}"
    if result.returncode != 0:
        detail = " ".join((result.stdout + result.stderr).split())
        return None, detail[:400]
    result = subprocess.run(
        [str(executable)], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = " ".join((result.stdout + result.stderr).split())
        return None, detail[:400]
    values = result.stdout.splitlines()
    if len(values) != len(fields) + 1:
        return None, "isolated C type probe returned an unexpected value count"
    try:
        return [int(value.strip(), 10) for value in values], None
    except ValueError:
        return None, "isolated C type probe returned a non-integer value"


def compare_fbfrog_record_layouts(
    fixture_name: str, source: Path, baseline: Path, generated: Path,
    options: list[str], prefix: str, label: str, output_root: Path,
    tests_root: Path, fbc_command: list[str], compiler: str,
    compiler_options: list[str], cpp_mode: bool,
    fbc_preamble: list[str] | None = None,
) -> dict[str, object]:
    """Compare usable FBFrog and C2FB record layouts with the C compiler."""
    baseline_text = baseline.read_text(encoding="utf-8", errors="replace")
    generated_text = generated.read_text(encoding="utf-8", errors="replace")
    baseline_records, baseline_aliases = freebasic_record_layout_types(baseline_text)
    generated_records, generated_aliases = freebasic_record_layout_types(generated_text)
    baseline_alias_names = {
        alias.casefold(): alias
        for alias, _ in BASIC_RECORD_ALIAS.findall(
            strip_basic_comments(baseline_text))
    }
    source_names = declaration_source_names(source)
    type_names = sorted(set(baseline_records) | set(baseline_aliases))
    result: dict[str, object] = {
        "records": 0,
        "values": 0,
        "fbfrog_divergences": [],
        "c2fb_mismatches": [],
        "skips": [],
    }
    for type_key in type_names:
        baseline_type = baseline_records.get(type_key, {}).get("name")
        if baseline_type is None:
            baseline_type = baseline_alias_names.get(type_key, type_key)
        if baseline_type not in source_names and not any(
            option.endswith("=" + baseline_type) for option in options
        ):
            continue
        baseline_layout = resolve_freebasic_record_layout_type(
            baseline_type, baseline_records, baseline_aliases)
        if baseline_layout is None:
            continue
        baseline_fields = list(baseline_layout["fields"])

        generated_type_candidates = [prefix + baseline_type]
        if prefix == "":
            generated_type_candidates.append(baseline_type)
        for option in options:
            if not option.startswith((
                "--rename=", "--rename-tag=", "--rename-typedef=",
            )):
                continue
            mapping = option.split("=", 1)[1]
            if "=" not in mapping:
                continue
            _, target_name = mapping.split("=", 1)
            if target_name.casefold() == baseline_type.casefold():
                generated_type_candidates.append(target_name)
        generated_type_candidates = list(dict.fromkeys(generated_type_candidates))
        generated_type = next((
            candidate for candidate in generated_type_candidates
            if resolve_freebasic_record_layout_type(
                candidate, generated_records, generated_aliases) is not None
        ), None)
        if generated_type is None:
            baseline_layout_values, baseline_error = run_freebasic_record_layout_probe(
                baseline, baseline_type, baseline_fields,
                f"{label}-{baseline_type}-fbfrog", output_root, tests_root,
                fbc_command, fbc_preamble,
            )
            if baseline_layout_values is None:
                result["skips"].append((
                    fixture_name, baseline_type, label,
                    "FBFrog layout probe failed: " + str(baseline_error),
                ))
            else:
                result["skips"].append((
                    fixture_name, baseline_type, label,
                    "C2FB output has no matching record type",
                ))
            continue
        generated_layout = resolve_freebasic_record_layout_type(
            generated_type, generated_records, generated_aliases)
        assert generated_layout is not None

        generated_fields = {
            field.casefold(): field
            for field in generated_layout["fields"]
        }
        common_fields = [
            field for field in baseline_fields
            if field.casefold() in generated_fields
        ]
        array_size_override_fields = {
            option[len("--array-size="):].partition("=")[0].casefold()
            for option in options
            if option.startswith("--array-size=") and
            "=" in option[len("--array-size="):]
        }
        size_is_overridden = any(
            field.casefold() in array_size_override_fields
            for field in common_fields
        )
        generated_alias_target = generated_aliases.get(
            generated_type.casefold(), "")
        if "__c2fb_anonymous_" in generated_alias_target.casefold() and \
           re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", baseline_type):
            # Anonymous aggregate names are borrowed from their direct object
            # or function result. Recover the C type from that use site instead
            # of measuring a same-named variable or function designator.
            type_candidates = [
                f"__typeof__({baseline_type}())",
                f"__typeof__({baseline_type})",
            ]
        else:
            type_candidates = c_record_type_candidates(
                baseline_type, str(baseline_layout["kind"]), options,
                prefer_tag=type_key in baseline_records,
            )
        record_definition_name = str(baseline_layout["name"])
        if record_definition_name.casefold() != baseline_type.casefold():
            type_candidates.extend(c_record_type_candidates(
                record_definition_name, str(baseline_layout["kind"]),
                options, prefer_tag=True,
            ))
        c_layout, c_error = run_c_record_layout_probe(
            source, type_candidates, common_fields,
            f"{label}-{baseline_type}", output_root, compiler,
            compiler_options, cpp_mode,
        )
        if c_layout is None:
            result["skips"].append((
                fixture_name, baseline_type, label,
                "C layout probe failed: " + str(c_error),
            ))
            continue

        baseline_layout_values, baseline_error = run_freebasic_record_layout_probe(
            baseline, baseline_type, common_fields,
            f"{label}-{baseline_type}-fbfrog", output_root, tests_root,
            fbc_command, fbc_preamble,
        )
        if baseline_layout_values is None:
            result["skips"].append((
                fixture_name, baseline_type, label,
                "FBFrog layout probe failed: " + str(baseline_error),
            ))
        generated_layout_values, generated_error = run_freebasic_record_layout_probe(
            generated, generated_type, common_fields,
            f"{label}-{baseline_type}-c2fb", output_root, tests_root,
            fbc_command, fbc_preamble,
        )
        if generated_layout_values is None:
            result["skips"].append((
                fixture_name, baseline_type, label,
                "C2FB layout probe failed: " + str(generated_error),
            ))
            continue

        result["records"] += 1
        for value_name in ("sizeof", *(field.casefold() for field in common_fields)):
            if value_name == "sizeof" and size_is_overridden:
                continue
            if value_name not in c_layout or \
               value_name not in generated_layout_values:
                continue
            result["values"] += 1
            c_value = c_layout[value_name]
            generated_value = generated_layout_values[value_name]
            if generated_value != c_value:
                result["c2fb_mismatches"].append((
                    fixture_name, baseline_type, value_name,
                    generated_value, c_value,
                ))
            if baseline_layout_values is not None and \
               value_name in baseline_layout_values:
                baseline_value = baseline_layout_values[value_name]
                if baseline_value != c_value:
                    result["fbfrog_divergences"].append((
                        fixture_name, baseline_type, value_name,
                        baseline_value, c_value,
                    ))
    return result


def record_layout_skip_category(reason: str) -> str:
    """Group layout skips by the converter or probe stage that failed."""
    if reason.startswith("C layout probe failed:"):
        return "C source probe failed"
    if reason.startswith("FBFrog layout probe failed:"):
        return "FBFrog baseline probe failed"
    if reason.startswith("C2FB layout probe failed:"):
        return "C2FB output probe failed"
    if reason == "C2FB output has no matching record type":
        return "C2FB output has no usable record layout"
    return "Other: " + reason.partition(":")[0]


def run_c_macro_value_probe(
    macro_dump: str, source_macro_names: set[str],
    macro_expressions: list[tuple[str, str]], label: str,
    output_root: Path, compiler: str, cpp_mode: bool,
    source_path: Path | None = None,
    compiler_options: list[str] | None = None,
) -> tuple[dict[str, int] | None, str | None]:
    """Compile selected preprocessed macros to provide a C semantic oracle."""
    try:
        compiler_parts = shlex.split(compiler)
    except ValueError as error:
        return None, f"invalid C compiler command: {error}"
    if not compiler_parts:
        return None, "empty C compiler command"

    safe_label = re.sub(r"[^A-Za-z0-9_-]", "_", label)
    if source_path is not None:
        source_wrapper = output_root / (
            f"c-macro-source-values-{safe_label}.cpp" if cpp_mode else
            f"c-macro-source-values-{safe_label}.c"
        )
        source_executable = output_root / f"c-macro-source-values-{safe_label}"
        include_path = str(source_path.resolve())
        if not any(character in include_path for character in ('"', "\n", "\r", "\0")):
            source_lines = [
                f'#include "{include_path}"',
                "#undef printf",
                "#undef main",
            ]
            if cpp_mode:
                source_lines.append('extern "C" int printf(const char *, ...);')
            else:
                source_lines.append("extern int printf(const char *, ...);")
            source_lines.extend(("int main(void)", "{"))
            source_lines.extend(
                f'printf("%016llX\\n", '
                f"(unsigned long long)({expression}));"
                for _, expression in macro_expressions
            )
            source_lines.extend(("return 0;", "}"))
            source_wrapper.write_text(
                "\n".join(source_lines) + "\n", encoding="utf-8")
            source_values, source_error = run_c_macro_value_wrapper(
                source_wrapper, source_executable, macro_expressions,
                compiler_parts, cpp_mode, compiler_options,
            )
            if source_error is None:
                return source_values, None

            try:
                source_text = source_path.read_text(
                    encoding="utf-8", errors="replace")
            except OSError:
                source_text = ""
            if re.search(r"\b(?:push_macro|pop_macro)\b", source_text):
                return None, (
                    "source-context C probe failed for a stateful macro pragma: "
                    + source_error[:400]
                )

    wrapper = output_root / (
        f"c-macro-values-{safe_label}.cpp" if cpp_mode else
        f"c-macro-values-{safe_label}.c"
    )
    executable = output_root / f"c-macro-values-{safe_label}"
    definitions: dict[str, tuple[str, set[str], str]] = {}
    definition_order: list[str] = []
    macro_lines = macro_dump.splitlines()
    macro_index = 0
    while macro_index < len(macro_lines):
        directive = PREPROCESSOR_DIRECTIVE.match(macro_lines[macro_index])
        if directive is None or directive.group(1).casefold() != "define":
            macro_index += 1
            continue

        definition_lines = [macro_lines[macro_index]]
        while definition_lines[-1].rstrip().endswith("\\") and \
              macro_index + 1 < len(macro_lines):
            macro_index += 1
            definition_lines.append(macro_lines[macro_index])
        definition_text = "\n".join(definition_lines)
        definition_tail = directive.group(2)
        parsed_definition = re.match(
            r"[ \t]+([A-Za-z_][A-Za-z_0-9]*)(.*)$", definition_tail)
        if parsed_definition is None:
            macro_index += 1
            continue
        name, suffix = parsed_definition.groups()
        parameters: set[str] = set()
        body = suffix
        if suffix.startswith("("):
            closing = suffix.find(")")
            if closing < 0:
                macro_index += 1
                continue
            parameters = {
                parameter.strip()
                for parameter in suffix[1:closing].split(",")
                if parameter.strip()
            }
            body = suffix[closing + 1:]
        body = re.sub(r"\\\r?\n[ \t]*", " ", body)
        definitions[name] = (definition_text, parameters, body)
        definition_order.append(name)
        macro_index += 1

    c_keywords = {
        "auto", "break", "case", "char", "const", "continue", "default",
        "do", "double", "else", "enum", "extern", "float", "for", "goto",
        "if", "inline", "int", "long", "register", "restrict", "return",
        "short", "signed", "sizeof", "static", "struct", "switch", "typedef",
        "union", "unsigned", "void", "volatile", "while", "_alignas",
        "_alignof", "_atomic", "_bool", "_complex", "_generic", "_imaginary",
        "_noreturn", "_static_assert", "_thread_local", "main", "printf",
    }
    if cpp_mode:
        c_keywords.update({
            "alignas", "alignof", "and", "and_eq", "asm", "bitand", "bitor",
            "bool", "catch", "char16_t", "char32_t", "class", "compl",
            "concept", "const_cast", "constexpr", "consteval", "constinit",
            "co_await", "co_return", "co_yield", "decltype", "delete",
            "dynamic_cast", "explicit", "export", "false", "friend", "mutable",
            "namespace", "new", "noexcept", "not", "not_eq", "nullptr",
            "operator", "or", "or_eq", "private", "protected", "public",
            "reinterpret_cast", "requires", "static_assert", "static_cast",
            "template", "this", "thread_local", "throw", "true", "try",
            "typeid", "typename", "using", "virtual", "wchar_t", "xor", "xor_eq",
        })

    expression_names = {
        identifier
        for _, expression in macro_expressions
        for identifier in C_IDENTIFIER.findall(expression)
    }
    forbidden_macro_names = {
        name for name in expression_names
        if name.casefold() in c_keywords
    }
    if forbidden_macro_names:
        return None, (
            "C value probe cannot isolate macro names that are C/C++ keywords: "
            + ", ".join(sorted(forbidden_macro_names))
        )

    selected_names = {
        name for name in source_macro_names
        if name in definitions and name.casefold() not in c_keywords
    }
    selected_names.update(
        name for name in expression_names
        if name in definitions and name.casefold() not in c_keywords
    )
    pending_names = list(selected_names)
    while pending_names:
        name = pending_names.pop()
        definition = definitions.get(name)
        if definition is None:
            continue
        _, parameters, body = definition
        for dependency in C_IDENTIFIER.findall(body):
            if dependency in parameters or dependency.casefold() in c_keywords:
                continue
            if dependency in definitions and dependency not in selected_names:
                selected_names.add(dependency)
                pending_names.append(dependency)

    selected_lines: list[str] = []
    for name in definition_order:
        if name not in selected_names:
            continue
        selected_lines.extend(("#undef " + name, definitions[name][0]))

    lines = ["#include <stdio.h>", *selected_lines]
    lines.extend(("#undef main", "#undef printf", "int main(void)", "{"))
    lines.extend(
        f'printf("%016llX\\n", '
        f"(unsigned long long)({expression}));"
        for _, expression in macro_expressions
    )
    lines.extend(("return 0;", "}"))
    wrapper.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return run_c_macro_value_wrapper(
        wrapper, executable, macro_expressions, compiler_parts, cpp_mode)


def run_c_macro_value_probe_with_isolation(
    macro_dump: str, source_macro_names: set[str],
    macro_expressions: list[tuple[str, str]], label: str,
    output_root: Path, compiler: str, cpp_mode: bool,
    source_path: Path | None = None,
    compiler_options: list[str] | None = None,
) -> tuple[dict[str, int], list[tuple[str, str]]]:
    """Keep one invalid C macro from hiding other usable integer values."""
    values, error = run_c_macro_value_probe(
        macro_dump, source_macro_names, macro_expressions, label,
        output_root, compiler, cpp_mode, source_path, compiler_options,
    )
    if values is not None:
        return values, []

    if source_path is not None:
        try:
            source_text = source_path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            source_text = ""
        if re.search(r"\b(?:push_macro|pop_macro)\b", source_text):
            return {}, [("", error or "stateful macro source probe failed")]
        if re.search(
            r"\b(?:__LINE__|__FILE__|__COUNTER__|__BASE_FILE__)\b",
            "\n".join(expression for _, expression in macro_expressions),
        ):
            return {}, [("", error or "source-location macro probe failed")]

    isolated_values: dict[str, int] = {}
    skipped: list[tuple[str, str]] = []
    attempt_count = 0
    maximum_attempts = 128

    def probe_subset(expressions: list[tuple[str, str]]) -> None:
        nonlocal attempt_count
        if not expressions:
            return
        if attempt_count >= maximum_attempts:
            skipped.extend((
                name, "C macro value isolation reached its probe limit"
            ) for name, _ in expressions)
            return

        attempt_count += 1
        subset_names = {name for _, name in expressions}
        subset_values, subset_error = run_c_macro_value_probe(
            macro_dump, subset_names, expressions,
            f"{label}-isolated-{attempt_count:03d}",
            output_root, compiler, cpp_mode, None, compiler_options,
        )
        if subset_values is not None:
            isolated_values.update(subset_values)
            return
        if len(expressions) == 1:
            skipped.append((expressions[0][0], subset_error or "C probe failed"))
            return

        middle = len(expressions) // 2
        probe_subset(expressions[:middle])
        probe_subset(expressions[middle:])

    probe_subset(macro_expressions)
    return isolated_values, skipped


def freebasic_macro_value_bits(value: str) -> int | None:
    """Normalize a FreeBASIC decimal integer result to the C probe's 64 bits."""
    value = value.strip()
    if re.fullmatch(r"[+-]?[0-9]+", value) is None:
        return None
    return int(value, 10) & ((1 << 64) - 1)


def preprocessor_condition_names(*texts: str) -> set[str]:
    names: set[str] = set()
    for text in texts:
        for line in strip_basic_comments(text).splitlines():
            directive = PREPROCESSOR_DIRECTIVE.match(line)
            if directive is None or directive.group(1).casefold() not in {
                "if", "ifdef", "ifndef", "elif",
            }:
                continue
            names.update(C_IDENTIFIER.findall(directive.group(2)))
    names.discard("defined")
    return names


def freebasic_macro_preamble(
    compiler_options: list[str], *binding_texts: str,
) -> list[str]:
    """Mirror target C -D/-U settings for FreeBASIC conditional sections."""
    conditional_names = preprocessor_condition_names(*binding_texts)
    operations: list[tuple[str, str, str]] = []
    option_index = 0
    while option_index < len(compiler_options):
        option = compiler_options[option_index]
        if option in {"-D", "-U"}:
            option_index += 1
            if option_index >= len(compiler_options):
                break
            argument = compiler_options[option_index]
            operation = option[1:]
        elif option.startswith(("-D", "-U")) and len(option) > 2:
            operation = option[1]
            argument = option[2:]
        else:
            option_index += 1
            continue
        option_index += 1

        name, separator, value = argument.partition("=")
        if C_IDENTIFIER.fullmatch(name) is None or name not in conditional_names:
            continue
        if any(character in value for character in ("\n", "\r", "\0")):
            continue
        if operation == "U":
            operations.append((name, "undef", ""))
        else:
            operations.append((name, "define", value if separator else "1"))

    configured_names = sorted({name for name, _, _ in operations})
    preamble = [f"#undef {name}" for name in configured_names]
    for name, operation, value in operations:
        if operation == "undef":
            preamble.append(f"#undef {name}")
        elif value:
            preamble.append(f"#define {name} {value}")
        else:
            preamble.append(f"#define {name}")
    return preamble


def freebasic_target_feature_preamble(target: dict[str, object]) -> list[str]:
    """Override host compiler features that FreeBASIC exposes to conditional code."""
    features = {
        "__FB_UNIX__": bool(target.get("is_unix")),
        "__FB_64BIT__": bool(target.get("is_64bit")),
        "__FB_ARM__": bool(target.get("is_arm")),
    }
    preamble = [f"#undef {name}" for name in features]
    preamble.extend(
        f"#define {name} 1"
        for name, is_enabled in features.items()
        if is_enabled
    )
    return preamble


def preprocess_profile_macros(
    source: Path, compiler: str, compiler_options: list[str],
    cpp_mode: bool,
) -> tuple[str | None, str | None]:
    """Collect the active C macro table for one selected target profile."""
    try:
        compiler_parts = shlex.split(compiler)
    except ValueError as error:
        return None, f"invalid profile compiler command: {error}"
    if not compiler_parts:
        return None, "empty profile compiler command"

    language_option = ["-x", "c++" if cpp_mode else "c"]
    command = [
        *compiler_parts, *compiler_options, *language_option,
        "-E", "-dM", str(source),
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0 and cpp_mode:
        compiler_basename = Path(compiler_parts[0]).name.casefold()
        clang_compiler = shutil.which("clang++")
        if clang_compiler and compiler_basename not in {"clang", "clang++"}:
            fallback_command = [
                clang_compiler, *compiler_parts[1:], *compiler_options,
                *language_option, "-E", "-dM", str(source),
            ]
            result = subprocess.run(
                fallback_command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = (result.stdout + result.stderr).strip()
        return result.stdout, detail[:500]
    return result.stdout, None


def fbfrog_options(header: Path) -> list[str] | None:
    """Read test-header options and ignore fbfrog's verbosity flag."""
    with header.open(encoding="utf-8", errors="replace") as stream:
        first_line = stream.readline().strip()
    marker = "@fbfrog "
    marker_position = first_line.find(marker)
    if marker_position < 0:
        return []
    try:
        options = shlex.split(first_line[marker_position + len(marker):])
    except ValueError:
        return None
    directory = str(header.parent) + "/"
    return [option.replace("<dir>", directory) for option in options if option != "-v"]


def translate_fbfrog_options(options: list[str]) -> list[str] | None:
    """Translate fbfrog fixture options used by the C declaration corpus."""
    translated: list[str] = []
    rename_options = {"-rename"}
    exclude_options = {
        "-removedefine": "--exclude-define",
        "-removeproc": "--exclude-proc",
        "-removevar": "--exclude-variable",
        "-remove": "--exclude",
    }
    index = 0
    while index < len(options):
        option = options[index]
        if option in rename_options:
            if index + 2 >= len(options):
                return None
            translated.append(
                f"--rename={options[index + 1]}={options[index + 2]}")
            index += 3
        elif option in {"-renameproc", "-renamedefine", "-renamemacroparam"}:
            if index + 2 >= len(options):
                return None
            rename_option = {
                "-renameproc": "--rename-proc",
                "-renamedefine": "--rename-define",
                "-renamemacroparam": "--rename-macro-param",
            }[option]
            translated.append(
                f"{rename_option}={options[index + 1]}={options[index + 2]}")
            index += 3
        elif option in {"-renametag", "-renametypedef"}:
            if index + 2 >= len(options):
                return None
            rename_option = "--rename-tag" if option == "-renametag" else "--rename-typedef"
            translated.append(
                f"{rename_option}={options[index + 1]}={options[index + 2]}")
            index += 3
        elif option == "-rename_":
            if index + 1 >= len(options):
                return None
            source_name = options[index + 1]
            translated.append(f"--rename={source_name}={source_name}_")
            index += 2
        elif option == "-define":
            if index + 1 >= len(options):
                return None
            macro_name = options[index + 1]
            if C_IDENTIFIER.fullmatch(macro_name) is None:
                return None
            definition = f"-D{macro_name}"
            if index + 2 < len(options):
                body = options[index + 2]
                if not body.startswith("-") or re.fullmatch(
                    r"-?(?:0|[1-9][0-9]*)", body
                ):
                    definition += "=" + body
                    index += 1
            translated.append(definition)
            index += 2
        elif option in exclude_options:
            if index + 1 >= len(options):
                return None
            translated.append(
                f"{exclude_options[option]}={options[index + 1]}")
            index += 2
        elif option in {"-typedefhint", "-addforwarddecl", "-dropprocbody"}:
            if index + 1 >= len(options):
                return None
            option_map = {
                "-typedefhint": "--typedef-hint",
                "-addforwarddecl": "--forward-decl",
                "-dropprocbody": "--drop-inline-body",
            }
            translated.append(f"{option_map[option]}={options[index + 1]}")
            index += 2
        elif option in {"-addinclude", "-inclib", "-undef"}:
            if index + 1 >= len(options):
                return None
            option_map = {
                "-addinclude": "--fb-include",
                "-inclib": "--fb-library",
                "-undef": "--undef",
            }
            translated.append(f"{option_map[option]}={options[index + 1]}")
            index += 2
            if index < len(options) and options[index].casefold().endswith(".bi"):
                # The name audit compares all fbfrog emit destinations together.
                index += 1
        elif option == "-fbfroginclude":
            if index + 1 >= len(options):
                return None
            included_header = options[index + 1]
            translated.extend((
                f"--c-include={included_header}",
                f"--exclude-source={included_header}",
            ))
            index += 2
        elif option == "-moveabove":
            if index + 2 >= len(options):
                return None
            translated.append(
                f"--move-above={options[index + 1]}={options[index + 2]}")
            index += 3
        elif option == "-setarraysize":
            if index + 2 >= len(options):
                return None
            translated.append(
                f"--array-size={options[index + 1]}={options[index + 2]}")
            index += 3
        elif option == "-emit":
            if index + 2 >= len(options):
                return None
            translated.append(f"--emit-source={options[index + 1]}")
            index += 3
        elif option == "-title":
            if index + 3 >= len(options):
                return None
            translated.extend((
                f"--title={options[index + 1]}",
                f"--license-file={options[index + 2]}",
                f"--translators-file={options[index + 3]}",
            ))
            index += 4
            if index < len(options) and options[index].casefold().endswith(".bi"):
                # Name coverage ignores destination-specific metadata placement.
                index += 1
        elif option == "-dontemit":
            if index + 1 >= len(options):
                return None
            translated.append(f"--exclude-source={options[index + 1]}")
            index += 2
        elif option in {"-string", "-nostring", "-expand", "-expandindefine",
                        "-noexpand", "-forcefunction2macro"}:
            if index + 1 >= len(options):
                return None
            option_map = {
                "-string": "--string",
                "-nostring": "--no-string",
                "-expand": "--expand-type",
                "-expandindefine": "--expand-in-define",
                "-noexpand": "--no-expand-macro",
                "-forcefunction2macro": "--force-inline-macro",
            }
            translated.append(f"{option_map[option]}={options[index + 1]}")
            index += 2
        elif option in {
            "-ifndefdecl", "-undefbeforedecl", "-convbodytokens",
            "-addinclude", "-inclib", "-undef",
            "-removeinclude", "-replacements", "-incdir", "-include",
        }:
            if index + 1 >= len(options):
                return None
            option_map = {
                "-ifndefdecl": "--ifndef-decl",
                "-undefbeforedecl": "--undef-before-decl",
                "-convbodytokens": "--convert-macro-tokens",
                "-addinclude": "--fb-include",
                "-fbfroginclude": "--fb-include",
                "-inclib": "--fb-library",
                "-undef": "--undef",
                "-removeinclude": "--remove-include",
                "-replacements": "--replacement-file",
            }
            if option == "-incdir":
                translated.append("-I" + options[index + 1])
            elif option == "-include":
                translated.extend(["-include", options[index + 1]])
            else:
                translated.append(
                    f"{option_map[option]}={options[index + 1]}")
            index += 2
        elif option == "-removeEmptyReservedDefines":
            translated.append("--remove-empty-reserved-defines")
            index += 1
        elif option == "-windowsms":
            translated.append("--windows-ms")
            index += 1
        elif option == "-fixunsizedarrays":
            translated.append("--fix-unsized-arrays")
            index += 1
        elif option == "-nofunctionbodies":
            translated.append("--no-inline-bodies")
            index += 1
        elif option == "-dropmacrobodyscopes":
            translated.append("--drop-macro-body-scopes")
            index += 1
        elif option == "-clong32":
            translated.append("--clong32")
            index += 1
        elif option in {"-remove1st", "-remove2nd"}:
            if index + 1 >= len(options):
                return None
            translated.extend(options[index:index + 2])
            index += 2
        else:
            return None
    return translated


def parse_fbfrog_version_script(
    options: list[str], base_directory: Path
) -> dict[str, object] | None:
    """Read the simple declareversions/selectversion subset used by tests."""
    if len(options) != 1 or not options[0].lower().endswith(".fbfrog"):
        return None
    script_path = Path(options[0])
    if not script_path.is_absolute():
        script_path = base_directory / script_path
    try:
        lines = script_path.read_text(
            encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None

    macro = ""
    values: list[str] = []
    selected_cases: dict[str, list[tuple[str, str]]] = {}
    inside_select = False
    saw_select = False
    active_case = ""

    def parse_define_commands(tokens: list[str]) -> list[tuple[str, str]] | None:
        commands: list[tuple[str, str]] = []
        index = 0
        while index < len(tokens):
            if tokens[index] != "-define" or index + 2 >= len(tokens):
                return None
            name = tokens[index + 1]
            value = tokens[index + 2]
            if C_IDENTIFIER.fullmatch(name) is None or not value:
                return None
            commands.append((name, value))
            index += 3
        return commands

    for line in lines:
        try:
            tokens = shlex.split(line, comments=True)
        except ValueError:
            return None
        if not tokens:
            continue

        if tokens[0] == "-declareversions":
            if macro or inside_select or len(tokens) < 3:
                return None
            macro = tokens[1]
            values = tokens[2:]
            if C_IDENTIFIER.fullmatch(macro) is None or not values:
                return None
            if any(re.fullmatch(r"(?:0|[1-9][0-9]*)", value) is None
                   for value in values):
                return None
            if len(set(values)) != len(values):
                return None
        elif tokens[0] == "-selectversion":
            if not macro or inside_select or saw_select or len(tokens) != 1:
                return None
            inside_select = True
            saw_select = True
        elif tokens[0] == "-case":
            if not inside_select or len(tokens) < 2:
                return None
            active_case = tokens[1]
            if active_case not in values or active_case in selected_cases:
                return None
            selected_cases[active_case] = []
            commands = parse_define_commands(tokens[2:])
            if commands is None:
                return None
            selected_cases[active_case].extend(commands)
        elif tokens[0] == "-endselect":
            if not inside_select or len(tokens) != 1:
                return None
            inside_select = False
            active_case = ""
        elif inside_select and active_case:
            commands = parse_define_commands(tokens)
            if commands is None:
                return None
            selected_cases[active_case].extend(commands)
        else:
            return None

    if not macro or inside_select:
        return None
    if saw_select:
        if set(selected_cases) != set(values):
            return None
        for value in values:
            if not any(name == macro and definition == value
                       for name, definition in selected_cases[value]):
                return None
    return {
        "macro": macro,
        "values": values,
        "selected_cases": selected_cases,
    }


def audit_fbfrog_version_matrix(
    converter: Path,
    tests_root: Path,
    source: Path,
    output_root: Path,
    prefix: str,
    compiler_text: str,
    scope: str,
    script: dict[str, object],
    compile_output=None,
    compile_body_candidates: bool = False,
    macro_profile_callback=None,
    record_layout_callback=None,
) -> tuple[set[str], str | None]:
    """Compare a simple fbfrog declareversions script through C2FB profiles."""
    try:
        compiler_parts = shlex.split(compiler_text)
    except ValueError as error:
        return set(), f"invalid C compiler command: {error}"
    if not compiler_parts:
        return set(), "empty C compiler command"

    relative_name = source.relative_to(tests_root).as_posix()
    matrix_name = relative_name.replace("/", "_")
    output_directory_name = matrix_name + "_matrix"
    cpp_mode_options = ["--cxx", "--traditional-cpp-fallback"] \
        if fbfrog_fixture_uses_cpp(source, tests_root) else []
    profiles: list[dict[str, object]] = []
    macro = str(script["macro"])
    values = script["values"]
    selected_cases = script["selected_cases"]
    if not isinstance(values, list) or not isinstance(selected_cases, dict):
        return set(), "invalid parsed fbfrog version matrix"
    for value in values:
        compiler_options = [
            *compiler_parts[1:],
            f"-D{macro}={value}",
            "-I" + str(source.parent),
            "-I" + str(tests_root),
        ]
        for name, definition in selected_cases.get(value, []):
            if name == macro:
                if definition != value:
                    return set(), f"{relative_name}: conflicting version define"
                continue
            compiler_options.append(f"-D{name}={definition}")
        profiles.append({
            "name": f"version-{value}",
            "compiler": compiler_parts[0],
            "compiler_options": compiler_options,
            "c2fb_options": [
                "--include-static-objects",
                "--private-static-objects",
                *cpp_mode_options,
            ],
            "freebasic_condition": f"{macro} = {value}",
        })

    matrix_tool = Path(__file__).resolve().with_name("c2fb_target_matrix.py")
    manifest = output_root / (matrix_name + "_matrix.json")
    output_directory = output_root / output_directory_name
    try:
        manifest.write_text(json.dumps({
            "input": str(source.resolve()),
            "output_directory": output_directory_name,
            "combined_binding": "combined.bi",
            "converter": str(converter.resolve()),
            "c2fb_options": ["--prefix=" + prefix],
            "profiles": profiles,
        }), encoding="utf-8")
    except OSError as error:
        return set(), f"{relative_name}: cannot write matrix manifest: {error}"
    result = subprocess.run(
        [sys.executable, str(matrix_tool), str(manifest)],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        detail = (result.stdout + result.stderr).strip()
        return set(), f"{relative_name}: {detail[:400]}"

    generated_names: set[str] = set()
    for profile in profiles:
        profile_name = str(profile["name"])
        binding = output_directory / f"{profile_name}.bi"
        if not binding.is_file():
            return set(), f"{relative_name}: matrix did not publish {profile_name}.bi"
        if compile_output is not None:
            compile_output(binding, relative_name, "C2FB profile")
        if record_layout_callback is not None:
            record_layout_callback(binding, profile)
        if macro_profile_callback is not None:
            macro_profile_callback(binding, profile)
        generated_names.update(emitted_binding_names(
            binding.read_text(encoding="utf-8", errors="replace")))

        if scope == "declarations" and not cpp_mode_options and \
           source_contains_function_definition(source):
            candidate = output_directory / f"{profile_name}_candidates.bas"
            body_command = [
                str(converter), "translate-simple-generic-c", str(source),
                str(candidate), compiler_parts[0], *profile["compiler_options"],
            ]
            body_result = subprocess.run(
                body_command, capture_output=True, text=True, check=False)
            if body_result.returncode != 0 or not candidate.is_file():
                detail = (body_result.stdout + body_result.stderr).strip()
                return set(), f"{relative_name}: {detail[:400]}"
            if compile_body_candidates and compile_output is not None:
                compile_output(
                    binding, relative_name, "C2FB binding+body", (candidate,))
            generated_names.update(emitted_binding_names(
                candidate.read_text(encoding="utf-8", errors="replace")))
    return generated_names, None


def audit_fbfrog_script_matrix(
    converter: Path,
    tests_copy: Path,
    source_copy: Path,
    output_root: Path,
    prefix: str,
    compiler_text: str,
    scope: str,
    options: list[str],
    compile_output=None,
    compile_body_candidates: bool = False,
    macro_value_callback=None,
    record_layout_callback=None,
) -> tuple[set[str], list[str], str | None]:
    """Audit fbfrog selectors using C2FB's script and target matrix adapter."""
    try:
        compiler_parts = shlex.split(compiler_text)
    except ValueError as error:
        return set(), [], f"invalid C compiler command: {error}"
    if not compiler_parts:
        return set(), [], "empty C compiler command"

    matrix_path = Path(__file__).resolve().with_name("c2fb_target_matrix.py")
    spec = importlib.util.spec_from_file_location(
        "c2fb_target_matrix_audit", matrix_path
    )
    if spec is None or spec.loader is None:
        return set(), [], "cannot load C2FB target-matrix adapter"
    matrix = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(matrix)
    except Exception as error:
        return set(), [], f"cannot load C2FB target-matrix adapter: {error}"

    relative_name = source_copy.relative_to(tests_copy).as_posix()
    matrix_name = relative_name.replace("/", "_")
    cpp_mode_options = ["--cxx", "--traditional-cpp-fallback"] \
        if fbfrog_fixture_uses_cpp(source_copy, tests_copy) else []
    if len(options) == 1 and Path(options[0]).suffix.casefold() == ".fbfrog":
        script_path = Path(options[0])
        if not script_path.is_absolute():
            script_path = source_copy.parent / script_path
        script_path = script_path.resolve()
    else:
        script_path = source_copy.with_suffix(".c2fb-audit.fbfrog")
        try:
            script_path.write_text(shlex.join(options) + "\n", encoding="utf-8")
        except OSError as error:
            return set(), [], f"{relative_name}: cannot write temporary script: {error}"

    try:
        parsed_script = matrix.read_fbfrog_script(script_path)
        all_targets = []
        seen_targets = set()
        for operating_system in matrix.FBFROG_OS_MACROS:
            for architecture in sorted(matrix.FBFROG_ARCHITECTURES):
                try:
                    target = matrix.parse_fbfrog_target(
                        f"{operating_system}-{architecture}",
                        "audit fbfrog target",
                    )
                except ValueError:
                    continue
                if target["fbfrog_target"] in seen_targets:
                    continue
                seen_targets.add(target["fbfrog_target"])
                all_targets.append(target)
        selected_targets = matrix.filter_fbfrog_targets(
            all_targets, parsed_script["target_filters"]
        )
    except (OSError, ValueError) as error:
        return set(), [], f"{relative_name}: {error}"

    matrix_tool = Path(__file__).resolve().with_name("c2fb_target_matrix.py")
    generated_names: set[str] = set()
    effective_options: list[str] = []
    for target in selected_targets:
        target_name = str(target["fbfrog_target"])
        target_output_name = matrix_name + "_" + target_name.replace("/", "_")
        output_directory_name = target_output_name + "_bindings"
        manifest_path = output_root / (target_output_name + ".json")
        target_script = {
            "path": str(script_path),
            "name_prefix": "audit",
            "compiler": compiler_parts[0],
            "compiler_options": [
                *compiler_parts[1:],
                "-I" + str(source_copy.parent),
                "-I" + str(tests_copy),
            ],
            "targets": [{
                "name": target_name,
                "fbfrog_target": target_name,
                "compiler": compiler_parts[0],
            }],
        }
        manifest: dict[str, object] = {
            "input": str(source_copy.resolve()),
            "output_directory": output_directory_name,
            "converter": str(converter.resolve()),
            "c2fb_options": [
                "--prefix=" + prefix,
                "--include-static-objects",
                "--private-static-objects",
                *cpp_mode_options,
            ],
            "fbfrog_version_script": target_script,
        }
        if not parsed_script["emit_groups"] and \
           parsed_script["output_path"] is None:
            manifest["combined_binding"] = "audit.bi"
        try:
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            matrix_config = matrix.read_matrix_config(manifest_path)
        except (OSError, ValueError) as error:
            return set(), [], f"{relative_name}: {error}"

        result = subprocess.run(
            [sys.executable, str(matrix_tool), str(manifest_path)],
            capture_output=True, text=True, check=False,
        )
        if result.returncode != 0:
            detail = (result.stdout + result.stderr).strip()
            return set(), [], f"{relative_name}: {detail[:400]}"

        output_directory = matrix_config["output_directory"]
        profile_bindings = []
        for profile in matrix_config["profiles"]:
            profile_binding = output_directory / f"{profile['name']}.bi"
            if not profile_binding.is_file():
                return set(), [], (
                    f"{relative_name}: matrix did not publish {profile_binding.name}"
                )
            profile_bindings.append(profile_binding)
            if compile_output is not None:
                compile_output(profile_binding, relative_name, "C2FB profile")
            if record_layout_callback is not None:
                record_layout_callback(profile_binding, target, profile)
            if macro_value_callback is not None:
                macro_value_callback(profile_binding, target, profile)
            effective_options.extend(profile["c2fb_options"])
            if scope == "declarations" and not cpp_mode_options and \
               source_contains_function_definition(source_copy):
                candidate = output_root / (
                    target_output_name + "_" + profile["name"] + "_candidates.bas"
                )
                profile_compiler = shlex.split(profile["compiler"])
                body_command = [
                    str(converter), "translate-simple-generic-c", str(source_copy),
                    str(candidate), *profile_compiler,
                    *body_options(profile["c2fb_options"]),
                    *profile["compiler_options"],
                ]
                body_result = subprocess.run(
                    body_command, capture_output=True, text=True, check=False,
                )
                if body_result.returncode != 0 or not candidate.is_file():
                    detail = (body_result.stdout + body_result.stderr).strip()
                    return set(), [], f"{relative_name}: {detail[:400]}"
                if compile_body_candidates and compile_output is not None:
                    compile_output(
                        profile_binding, relative_name,
                        "C2FB binding+body", (candidate,))
                generated_names.update(emitted_binding_names(
                    candidate.read_text(encoding="utf-8", errors="replace")))
        generated_names.update(effective_binding_names(profile_bindings))

        if matrix_config["combined_binding"] is not None:
            selector = output_directory / matrix_config["combined_binding"]
            if not selector.is_file():
                return set(), [], f"{relative_name}: matrix did not publish {selector.name}"
            generated_names.update(emitted_binding_names(
                selector.read_text(encoding="utf-8", errors="replace")))
        for binding in matrix_config["combined_bindings"]:
            selector = output_directory / binding["name"]
            if not selector.is_file():
                return set(), [], f"{relative_name}: matrix did not publish {selector.name}"
            generated_names.update(emitted_binding_names(
                selector.read_text(encoding="utf-8", errors="replace")))
    return generated_names, effective_options, None


def effective_binding_names(binding_paths: list[Path]) -> set[str]:
    """Collect names from profile bindings without assuming selector text."""
    names: set[str] = set()
    for binding_path in binding_paths:
        names.update(emitted_binding_names(
            binding_path.read_text(encoding="utf-8", errors="replace")))
    return names


def body_options(options: list[str]) -> list[str]:
    """Keep only generic-C options that the body converter understands."""
    return [
        option for option in options
        if option.startswith("--rename=") or option.startswith("--rename-proc=")
        or option.startswith("--typedef-hint=")
        or option.startswith("--replacement-file=")
    ]


def split_compiler_options(
    options: list[str],
) -> tuple[list[str], list[str]]:
    """Keep C compiler flags after the compiler executable in audit commands."""
    converter_options: list[str] = []
    compiler_options: list[str] = []
    index = 0
    while index < len(options):
        option = options[index]
        if option == "-include":
            if index + 1 >= len(options):
                return options, []
            compiler_options.extend(options[index:index + 2])
            index += 2
        elif option.startswith("-I") or option.startswith("-D") or \
             option.startswith("-U"):
            compiler_options.append(option)
            index += 1
        else:
            converter_options.append(option)
            index += 1
    return converter_options, compiler_options


def declaration_source_names(source: Path) -> set[str]:
    """Read C identifiers without letting comments or literal contents count."""
    text = source.read_text(encoding="utf-8", errors="replace")
    return set(C_IDENTIFIER.findall(C_NON_CODE_TEXT.sub(" ", text)))


def expected_declaration_names(
    baseline_names: set[str], source_names: set[str], options: list[str]
) -> set[str]:
    """Keep source bindings and explicit renames, dropping fbfrog-only helpers."""
    renamed_names = {
        option.rsplit("=", 1)[1]
        for option in options
        if option.startswith((
            "--rename=", "--rename-tag=", "--rename-typedef=",
            "--rename-proc=", "--rename-define=",
        )) and "=" in option
    }
    expected: set[str] = set()
    for baseline_name in baseline_names:
        if baseline_name in source_names or baseline_name in renamed_names:
            expected.add(baseline_name)
            continue
        candidate = baseline_name
        while candidate.endswith("_"):
            candidate = candidate[:-1]
            if candidate in source_names or candidate in renamed_names:
                expected.add(candidate)
                break
    return expected


def fbfrog_fixture_matches(path: str, patterns: list[str]) -> bool:
    """Select fixture paths by POSIX-style glob without changing the tree."""
    return not patterns or any(fnmatchcase(path, pattern) for pattern in patterns)


def fbfrog_fixture_uses_cpp(source: Path, tests_root: Path) -> bool:
    """Match C++ fixtures from their path, suffix, or declaration syntax."""
    try:
        relative_parts = source.relative_to(tests_root).parts
    except ValueError:
        relative_parts = source.parts
    if any(part.casefold() in {"cpp", "cxx"} for part in relative_parts[:-1]):
        return True
    cpp_suffixes = {".cc", ".cpp", ".cxx", ".hh", ".hpp", ".hxx"}
    if source.suffix.casefold() in cpp_suffixes:
        return True
    try:
        source_text = source.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    source_text = C_NON_CODE_TEXT.sub(" ", source_text)
    return re.search(
        r"\b(?!(?:if|while|for|switch|sizeof)\b)"
        r"[A-Za-z_][A-Za-z_0-9]*\s*\([^;{}]*"
        r"\b[A-Za-z_][A-Za-z_0-9]*\s*=\s*[^=;{}]*\)\s*;",
        source_text,
    ) is not None


def fbfrog_fixture_target_filters(source: Path, tests_root: Path) -> list[str]:
    """Select representative fbfrog targets for conditional C declarations."""
    try:
        source_text = source.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    source_text = C_NON_CODE_TEXT.sub(" ", source_text)
    conditional_lines = re.findall(
        r"^[ \t]*#[ \t]*(?:if|ifdef|ifndef|elif)\b([^\r\n]*)",
        source_text,
        re.M,
    )
    conditional_macros = {
        macro
        for line in conditional_lines
        for macro in C_IDENTIFIER.findall(line)
    }
    target_groups = {
        "windows": {
            "_WIN32", "WIN32", "WINNT", "__WIN32", "__WIN32__",
            "__WINNT", "__WINNT__", "_WIN64", "WIN64", "__WIN64__",
            "__FB_WIN32__",
        },
        "dos": {
            "DJGPP", "__DJGPP", "__DJGPP__", "GO32", "__GO32",
            "__GO32__", "MSDOS", "__MSDOS", "__MSDOS__", "__FB_DOS__",
        },
        "linux": {"linux", "__linux", "__linux__", "__gnu_linux__", "__FB_LINUX__"},
        "freebsd": {"__FreeBSD__", "__FB_FREEBSD__"},
        "openbsd": {"__OpenBSD__", "__FB_OPENBSD__"},
        "netbsd": {"__NetBSD__", "__FB_NETBSD__"},
        "darwin": {"__APPLE__", "__MACH__", "__FB_DARWIN__"},
        "cygwin": {"__CYGWIN__", "__FB_CYGWIN__"},
    }
    selected_os = {
        operating_system
        for operating_system, macros in target_groups.items()
        if conditional_macros.intersection(macros)
    }
    generic_unix_macros = {"unix", "__unix", "__unix__"}
    has_generic_unix_condition = bool(
        conditional_macros.intersection(generic_unix_macros))
    architecture_macros = {
        "__LP64__", "_LP64", "__x86_64", "__x86_64__", "__amd64",
        "__amd64__", "__i386", "__i386__", "i386", "_M_IX86",
        "__FB_64BIT__",
    }
    has_architecture_condition = bool(
        conditional_macros.intersection(architecture_macros))
    if not selected_os and not has_architecture_condition and \
       not has_generic_unix_condition:
        return []

    targets = {"linux-x86_64"}
    if "windows" in selected_os:
        targets.update({"win32", "win64"})
    if "dos" in selected_os:
        targets.add("dos")
    if has_generic_unix_condition:
        targets.add("freebsd-x86_64")
    for operating_system in selected_os - {"windows", "dos", "linux"}:
        targets.add(f"{operating_system}-x86_64")
    if "linux" in selected_os and has_architecture_condition:
        targets.add("linux-x86")
    if has_architecture_condition:
        targets.update({"linux-x86", "win32", "win64", "dos"})
    return sorted(targets)


def source_contains_function_definition(source: Path) -> bool:
    """Avoid invoking the body translator for headers with declarations only."""
    try:
        source_text = source.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    source_text = C_NON_CODE_TEXT.sub(" ", source_text)
    source_text = re.sub(
        r"(?m)^[ \t]*#[^\r\n]*(?:\\[ \t]*\r?\n[^\r\n]*)*",
        " ",
        source_text,
    )
    return re.search(
        r"\b(?!(?:if|for|while|switch|sizeof)\b)"
        r"[A-Za-z_][A-Za-z_0-9]*\s*\([^;{}]*\)\s*\{",
        source_text,
    ) is not None


def inferred_missing_include_options(
    source: Path, baseline: Path, tests_root: Path
) -> list[str]:
    """Reuse fbfrog's explicit .bi imports for absent C header counterparts."""
    try:
        baseline_text = baseline.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    options: list[str] = []
    seen_headers: set[str] = set()
    for match in re.finditer(
        r'^[ \t]*#include[ \t]+once[ \t]+"([^"\r\n]+\.bi)"',
        baseline_text,
        re.I | re.M,
    ):
        freebasic_include = match.group(1).replace("\\", "/")
        include_path = Path(freebasic_include)
        if include_path.is_absolute() or ".." in include_path.parts:
            continue
        c_header = include_path.with_suffix(".h").as_posix()
        if c_header in seen_headers:
            continue
        if (source.parent / c_header).is_file() or (tests_root / c_header).is_file():
            continue
        seen_headers.add(c_header)
        options.append(f"--preserve-include={c_header}={freebasic_include}")
    if options:
        options.insert(0, "--preserve-missing-includes")
    return options


def expected_macro_names(
    baseline_names: set[str], source_names: set[str], options: list[str]
) -> set[str]:
    """Keep C macro names and explicit macro-renamed targets from fbfrog output."""
    renamed_names: set[str] = set()
    for option in options:
        if option.startswith("--rename-define="):
            source_name, target_name = option[len("--rename-define="):].split("=", 1)
            if source_name in source_names:
                renamed_names.add(target_name)
        elif option.startswith("--rename="):
            source_name, target_name = option[len("--rename="):].split("=", 1)
            if source_name in source_names:
                renamed_names.add(target_name)
    expected: set[str] = set()
    for baseline_name in baseline_names:
        if baseline_name in source_names or baseline_name in renamed_names:
            expected.add(baseline_name)
            continue
        candidate = baseline_name
        while candidate.endswith("_"):
            candidate = candidate[:-1]
            if candidate in source_names or candidate in renamed_names:
                expected.add(candidate)
                break
    return expected


def match_generated_names(
    expected_names: set[str], generated_names: set[str], prefix: str
) -> set[str]:
    """Match C2FB's prefix and collision suffixes back to source names."""
    candidates: list[list[str]] = []
    for generated_name in sorted(generated_names):
        if not generated_name.startswith(prefix):
            continue
        source_name = generated_name[len(prefix):]
        names_for_output: list[str] = []
        while source_name:
            if source_name in expected_names:
                names_for_output.append(source_name)
            if not source_name.endswith("_"):
                break
            source_name = source_name[:-1]
        if names_for_output:
            candidates.append(names_for_output)

    matched_output: dict[str, int] = {}

    def assign(output_index: int, visited: set[str]) -> bool:
        for source_name in candidates[output_index]:
            if source_name in visited:
                continue
            visited.add(source_name)
            previous_output = matched_output.get(source_name)
            if previous_output is None or assign(previous_output, visited):
                matched_output[source_name] = output_index
                return True
        return False

    for output_index in range(len(candidates)):
        assign(output_index, set())
    return set(matched_output)


def matched_emitted_names(
    expected_names: set[str], generated_names: set[str], prefix: str
) -> set[str]:
    """Match prefixed C2FB names and explicit unprefixed rename targets."""
    matched = match_generated_names(expected_names, generated_names, prefix)
    matched.update(expected_names.intersection(generated_names))
    return matched


def missing_name_counts_by_baseline_status(
    missing: list[tuple[str, int, int, list[str]]],
    baseline_compile_status: dict[str, bool],
) -> tuple[int, int, int]:
    """Count name gaps by whether their fbfrog baseline compiles with FBC."""
    compilable = 0
    noncompilable = 0
    unchecked = 0
    for fixture, _, _, names in missing:
        status = baseline_compile_status.get(fixture)
        if status is True:
            compilable += len(names)
        elif status is False:
            noncompilable += len(names)
        else:
            unchecked += len(names)
    return compilable, noncompilable, unchecked


def missing_names_with_comparable_baselines(
    missing: list[tuple[str, int, int, list[str]]],
    baseline_compile_status: dict[str, bool],
) -> list[tuple[str, int, int, list[str]]]:
    """Keep gaps whose FBFrog baseline compiles or has not been checked."""
    return [
        gap for gap in missing
        if baseline_compile_status.get(gap[0]) is not False
    ]


def c2fb_compile_failures_by_baseline_status(
    compile_records: list[tuple[str, str, bool, str]],
    baseline_compile_status: dict[str, bool],
) -> tuple[
    list[tuple[str, str, bool, str]],
    list[tuple[str, str, bool, str]],
    list[tuple[str, str, bool, str]],
]:
    """Separate C2FB compile failures by the paired baseline's FBC status."""
    compilable: list[tuple[str, str, bool, str]] = []
    noncompilable: list[tuple[str, str, bool, str]] = []
    unchecked: list[tuple[str, str, bool, str]] = []
    for record in compile_records:
        fixture, kind, success, _ = record
        if kind == "fbfrog baseline" or success:
            continue
        baseline_status = baseline_compile_status.get(fixture)
        if baseline_status is True:
            compilable.append(record)
        elif baseline_status is False:
            noncompilable.append(record)
        else:
            unchecked.append(record)
    return compilable, noncompilable, unchecked


def compile_failures_for_kind(
    compile_records: list[tuple[str, str, bool, str]], kind: str
) -> list[tuple[str, str, bool, str]]:
    """Return failed compile records for one named output kind."""
    return [
        record for record in compile_records
        if record[1] == kind and not record[2]
    ]


def macro_value_mismatches_not_explained_by_source(
    fbfrog_mismatches: list[tuple[str, str, str, str, str]],
    fbfrog_source_divergences: list[tuple[str, str, str, int, int]],
    c2fb_source_mismatches: list[tuple[str, str, str, int, int]],
) -> list[tuple[str, str, str, str, str]]:
    """Keep mismatches unless C2FB matches C and FBFrog diverges from C."""
    fbfrog_divergence_keys = {
        (fixture, name, profile)
        for fixture, name, profile, _, _ in fbfrog_source_divergences
    }
    c2fb_mismatch_keys = {
        (fixture, name, profile)
        for fixture, name, profile, _, _ in c2fb_source_mismatches
    }
    return [
        mismatch
        for mismatch in fbfrog_mismatches
        if (mismatch[0], mismatch[1], mismatch[2]) not in fbfrog_divergence_keys
        or (mismatch[0], mismatch[1], mismatch[2]) in c2fb_mismatch_keys
    ]


def fbc_source_include_directory(fbc_command: list[str]) -> Path | None:
    executable_name = fbc_command[0]
    executable_path = shutil.which(executable_name)
    if executable_path is None:
        path = Path(executable_name)
        if not path.is_file():
            return None
        executable_path = str(path.resolve())

    executable = Path(executable_path).resolve()
    candidates = (
        executable.parent.parent / "inc",
        executable.parent / "inc",
    )
    for directory in candidates:
        if (directory / "crt" / "stddef.bi").is_file() and \
           (directory / "fbc-int" / "fbcall.bi").is_file():
            return directory
    return None


def audit(args: argparse.Namespace) -> int:
    tests_root = args.fbfrog_tests.resolve()
    if not tests_root.is_dir():
        raise SystemExit(f"fbfrog test directory does not exist: {tests_root}")
    converter = args.converter.resolve()
    if not converter.is_file():
        raise SystemExit(f"C2FB executable does not exist: {converter}")

    fbc_command: list[str] = []
    compile_records: list[tuple[str, str, bool, str]] = []
    baseline_compile_status: dict[str, bool] = {}
    compile_failures_on_valid_baselines: list[tuple[str, str, bool, str]] = []
    literal_macro_value_count = 0
    literal_macro_value_probe_count = 0
    literal_macro_value_mismatches: list[
        tuple[str, str, str, str, str]
    ] = []
    strict_literal_macro_value_mismatches: list[
        tuple[str, str, str, str, str]
    ] = []
    strict_noninteger_macro_value_mismatches: list[
        tuple[str, str, str, str, str]
    ] = []
    literal_macro_value_errors: list[tuple[str, str, str]] = []
    literal_macro_value_skips: list[tuple[str, str]] = []
    noninteger_macro_value_count = 0
    noninteger_macro_value_probe_count = 0
    noninteger_macro_value_mismatches: list[
        tuple[str, str, str, str, str]
    ] = []
    noninteger_macro_value_errors: list[tuple[str, str, str]] = []
    noninteger_macro_value_skips: list[tuple[str, str]] = []
    c_source_noninteger_macro_value_count = 0
    c_source_noninteger_macro_probe_count = 0
    c2fb_source_noninteger_macro_mismatches: list[
        tuple[str, str, str, str, str]
    ] = []
    fbfrog_source_noninteger_macro_divergences: list[
        tuple[str, str, str, str, str]
    ] = []
    c_source_noninteger_macro_probe_skips: list[tuple[str, str]] = []
    c_source_macro_value_count = 0
    c_source_macro_probe_count = 0
    c2fb_source_macro_mismatches: list[
        tuple[str, str, str, int, int]
    ] = []
    fbfrog_source_macro_divergences: list[
        tuple[str, str, str, int, int]
    ] = []
    c_source_macro_probe_skips: list[tuple[str, str]] = []
    macro_presence_case_count = 0
    macro_presence_probe_count = 0
    macro_presence_mismatches: list[tuple[str, str, bool, bool]] = []
    macro_presence_errors: list[tuple[str, str, str]] = []
    macro_presence_skips: list[tuple[str, str]] = []
    record_layout_record_count = 0
    record_layout_value_count = 0
    record_layout_fbfrog_divergences: list[tuple[str, str, str, int, int]] = []
    record_layout_c2fb_mismatches: list[tuple[str, str, str, int, int]] = []
    record_layout_skips: list[tuple[str, str, str, str]] = []
    compile_index = 0
    if args.compile_bindings:
        try:
            fbc_command = shlex.split(args.fbc)
        except ValueError as error:
            raise SystemExit(f"invalid FreeBASIC compiler command: {error}") from error
        if not fbc_command:
            raise SystemExit("empty FreeBASIC compiler command")
        include_directories = [
            Path(path).resolve() for path in args.fbc_include_directories
        ]
        if not include_directories:
            inferred_directory = fbc_source_include_directory(fbc_command)
            if inferred_directory is not None:
                include_directories.append(inferred_directory)
        for directory in include_directories:
            if not directory.is_dir():
                raise SystemExit(
                    f"FreeBASIC include directory does not exist: {directory}"
                )
            fbc_command.extend(("-i", str(directory)))

    def compile_output(
        binding_path: Path, fixture_name: str, kind: str,
        additional_bindings: tuple[Path, ...] = (),
    ) -> bool:
        nonlocal compile_index
        compile_index += 1
        label = f"{compile_index:04d}"
        wrapper = output_root / f"fbc-check-{label}.bas"
        object_path = output_root / f"fbc-check-{label}.o"
        binding_paths = (binding_path, *additional_bindings)
        binding_names = tuple(str(path.resolve()) for path in binding_paths)
        if any(
            character in binding_name
            for binding_name in binding_names
            for character in ('"', "\n", "\r", "\0")
        ):
            detail = "binding path contains characters unsupported by the include wrapper"
            compile_records.append((fixture_name, kind, False, detail))
            return False
        wrapper.write_text("".join(
            f'#include once "{binding_name}"\n'
            for binding_name in binding_names
        ), encoding="utf-8")
        include_directories = list(dict.fromkeys(
            str(path.resolve().parent) for path in binding_paths
        ))
        fixture_source_directory = (tests_root / Path(fixture_name)).parent
        if fixture_source_directory.is_dir():
            source_include_directory = str(fixture_source_directory.resolve())
            if source_include_directory not in include_directories:
                include_directories.append(source_include_directory)
        command = [
            *fbc_command, "-w", "all", "-c", str(wrapper), "-o", str(object_path),
            "-i", str(tests_root),
        ]
        for include_directory in include_directories:
            command.extend(("-i", include_directory))
        result = subprocess.run(
            command, capture_output=True, text=True, check=False)
        detail = (result.stdout + result.stderr).strip()
        compile_records.append((
            fixture_name, kind, result.returncode == 0, detail[:500]))
        return result.returncode == 0

    def compare_record_layouts(
        fixture_name: str, source_path: Path, baseline_path: Path,
        generated_path: Path, options: list[str], compiler_text: str,
        compiler_options: list[str], cpp_mode: bool,
        fbc_preamble: list[str] | None = None,
        profile_label: str = "direct",
    ) -> None:
        nonlocal record_layout_record_count, record_layout_value_count
        if not args.compare_record_layouts:
            return
        label = re.sub(r"[^A-Za-z0-9_-]", "_", fixture_name)
        if profile_label:
            label += "_" + re.sub(r"[^A-Za-z0-9_-]", "_", profile_label)
        result = compare_fbfrog_record_layouts(
            fixture_name, source_path, baseline_path, generated_path,
            options, args.prefix, label, output_root, tests_root,
            fbc_command, compiler_text, compiler_options, cpp_mode,
            fbc_preamble,
        )
        record_layout_record_count += int(result["records"])
        record_layout_value_count += int(result["values"])
        record_layout_fbfrog_divergences.extend(
            result["fbfrog_divergences"])
        record_layout_c2fb_mismatches.extend(
            result["c2fb_mismatches"])
        record_layout_skips.extend(result["skips"])

    def skip_literal_macro_values(fixture_name: str, reason: str) -> None:
        if args.compare_macro_values:
            literal_macro_value_skips.append((fixture_name, reason))

    def compare_noninteger_macro_values(
        fixture_name: str, source_names: set[str], baseline_path: Path,
        generated_path: Path, options: list[str],
        source_text_override: str | None = None,
        fbc_preamble: list[str] | None = None,
        profile_label: str = "",
        c_source: Path | None = None,
        c_compiler: str | None = None,
        c_compiler_options: list[str] | None = None,
        c_cpp_mode: bool = False,
    ) -> None:
        nonlocal noninteger_macro_value_count
        nonlocal noninteger_macro_value_probe_count
        nonlocal c_source_noninteger_macro_value_count
        nonlocal c_source_noninteger_macro_probe_count
        source_text = (
            source_text_override
            if source_text_override is not None
            else source_names_by_fixture[fixture_name]
        )
        macro_kinds = noninteger_object_macro_kinds(source_text)
        candidates = sorted(set(macro_kinds).intersection(source_names))
        if not candidates:
            return

        value_label_suffix = f" [{profile_label}]" if profile_label else ""
        baseline_text = baseline_path.read_text(encoding="utf-8", errors="replace")
        generated_text = generated_path.read_text(
            encoding="utf-8", errors="replace")
        baseline_names = emitted_object_macro_names(baseline_text)
        generated_names = emitted_object_macro_names(generated_text)
        baseline_probe_names: set[str] = set()
        generated_probe_names: set[str] = set()
        baseline_expressions: list[tuple[str, str, str]] = []
        generated_expressions: list[tuple[str, str, str]] = []
        c_expressions: list[tuple[str, str, str]] = []
        probe_labels: dict[str, str] = {}
        missing_baseline_macro_binding = False
        missing_generated_macro_binding = False

        for index, source_name in enumerate(candidates):
            baseline_name = baseline_macro_binding_name(
                source_name, baseline_names, options)
            if baseline_name is None:
                missing_baseline_macro_binding = True
                if emitted_macro_binding_name(
                    source_name, generated_names, args.prefix) is None:
                    missing_generated_macro_binding = True
                continue
            generated_name = emitted_macro_binding_name(
                baseline_name, generated_names, args.prefix)
            if generated_name is None:
                missing_generated_macro_binding = True
                continue

            probe_name = f"__c2fb_noninteger_{index:04d}"
            kind = macro_kinds[source_name]
            baseline_kind = freebasic_noninteger_macro_probe_kind(
                baseline_text, baseline_name, kind)
            generated_kind = freebasic_noninteger_macro_probe_kind(
                generated_text, generated_name, kind)
            value_name = source_name + value_label_suffix
            probe_labels[probe_name] = value_name
            baseline_probe_names.add(baseline_name)
            generated_probe_names.add(generated_name)
            baseline_expressions.append((probe_name, baseline_name, baseline_kind))
            generated_expressions.append((probe_name, generated_name, generated_kind))
            c_expressions.append((probe_name, source_name, kind))

        if not baseline_expressions:
            if missing_baseline_macro_binding and not missing_generated_macro_binding:
                reason = "FBFrog baseline has no matching noninteger macro binding"
            elif missing_generated_macro_binding and not missing_baseline_macro_binding:
                reason = "C2FB output has no matching noninteger macro binding"
            else:
                reason = "no paired FBFrog and C2FB noninteger macro bindings"
            noninteger_macro_value_skips.append((fixture_name, reason))
            return

        c_values: dict[str, str] | None = None
        c_error: str | None = None
        string_byte_lengths: dict[str, int] = {}
        wide_string_unit_lengths: dict[str, tuple[int, int]] = {}
        if c_source is not None and c_compiler is not None:
            c_macro_dump = source_text_override
            if c_macro_dump is None:
                c_macro_dump, c_preprocessing_error = preprocess_profile_macros(
                    c_source, c_compiler, c_compiler_options or [], c_cpp_mode)
                if c_preprocessing_error is not None and not c_macro_dump:
                    c_error = c_preprocessing_error
            if c_error is None:
                c_values, c_error = run_c_noninteger_macro_value_probe(
                    c_macro_dump, c_expressions,
                    f"{compile_index:04d}",
                    output_root, c_compiler, c_cpp_mode,
                    c_source, c_compiler_options,
                )
            if c_values is not None:
                for probe_name, _, kind in c_expressions:
                    if kind not in {"string", "string-nul"}:
                        if kind.startswith("wide-string"):
                            result = re.match(
                                r"^wide-string:([0-9]+):([0-9]+):",
                                c_values.get(probe_name, ""),
                            )
                            if result is not None:
                                wide_string_unit_lengths[probe_name] = (
                                    int(result.group(1)), int(result.group(2)))
                        continue
                    result = re.match(
                        r"^string:([0-9]+):", c_values.get(probe_name, ""))
                    if result is not None:
                        string_byte_lengths[probe_name] = int(result.group(1))

        needs_c_string_lengths = any(
            kind in {"string-nul", "wide-string", "wide-string-nul"}
            for _, _, kind in c_expressions
        )
        if needs_c_string_lengths and c_values is None:
            noninteger_macro_value_skips.append((
                fixture_name,
                "NUL or wide strings need a successful C length probe",
            ))
            return

        baseline_probe_binding = output_root / (
            f"macro-noninteger-values-{compile_index:04d}-fbfrog.bi"
        )
        generated_probe_binding = output_root / (
            f"macro-noninteger-values-{compile_index:04d}-c2fb.bi"
        )
        baseline_probe_binding.write_text(
            macro_value_binding_subset(
                baseline_text, baseline_probe_names,
                [baseline_path.parent, tests_root],
            ),
            encoding="utf-8",
        )
        generated_probe_binding.write_text(
            macro_value_binding_subset(
                generated_text, generated_probe_names,
                [generated_path.parent, tests_root],
            ),
            encoding="utf-8",
        )

        probe_label = f"{compile_index:04d}"
        baseline_probe, baseline_error = run_freebasic_noninteger_macro_value_probe(
            baseline_probe_binding, baseline_expressions,
            f"{probe_label}-fbfrog",
            output_root, tests_root, fbc_command, fbc_preamble,
            [baseline_path.parent], string_byte_lengths,
            wide_string_unit_lengths,
        )
        if baseline_error is not None:
            if "wchar_t widths differ" in baseline_error:
                noninteger_macro_value_skips.append((fixture_name, baseline_error))
                return
            profile_text = f" for {profile_label}" if profile_label else ""
            noninteger_macro_value_skips.append((
                fixture_name,
                f"the fbfrog noninteger macro subset does not compile{profile_text}: "
                f"{baseline_error[:160]}",
            ))
            return
        generated_probe, generated_error = run_freebasic_noninteger_macro_value_probe(
            generated_probe_binding, generated_expressions,
            f"{probe_label}-c2fb",
            output_root, tests_root, fbc_command, fbc_preamble,
            [generated_path.parent], string_byte_lengths,
            wide_string_unit_lengths,
        )
        if generated_error is not None:
            if "wchar_t widths differ" in generated_error:
                noninteger_macro_value_skips.append((fixture_name, generated_error))
                return
            noninteger_macro_value_errors.append((
                fixture_name, "C2FB output", generated_error))
            return

        assert baseline_probe is not None and generated_probe is not None
        noninteger_macro_value_probe_count += 1
        noninteger_macro_value_count += len(baseline_expressions)
        for probe_name, _, _ in baseline_expressions:
            baseline_value = baseline_probe[probe_name]
            generated_value = generated_probe[probe_name]
            if baseline_value != generated_value:
                noninteger_macro_value_mismatches.append((
                    fixture_name, probe_labels[probe_name], profile_label,
                    baseline_value, generated_value,
                ))

        if c_source is None or c_compiler is None:
            return
        if c_error is not None:
            c_source_noninteger_macro_probe_skips.append((fixture_name, c_error))
            return

        assert c_values is not None
        c_source_noninteger_macro_probe_count += 1
        c_source_noninteger_macro_value_count += len(c_expressions)
        for probe_name, _, _ in baseline_expressions:
            source_value = c_values[probe_name]
            baseline_value = baseline_probe[probe_name]
            generated_value = generated_probe[probe_name]
            value_name = probe_labels[probe_name]
            if baseline_value != source_value:
                fbfrog_source_noninteger_macro_divergences.append((
                    fixture_name, value_name, profile_label,
                    baseline_value, source_value,
                ))
            if generated_value != source_value:
                c2fb_source_noninteger_macro_mismatches.append((
                    fixture_name, value_name, profile_label,
                    generated_value, source_value,
                ))

    def compare_literal_macro_values(
        fixture_name: str, source_names: set[str], baseline_path: Path,
        generated_path: Path, options: list[str],
        source_text_override: str | None = None,
        fbc_preamble: list[str] | None = None,
        profile_label: str = "",
        c_source: Path | None = None,
        c_compiler: str | None = None,
        c_compiler_options: list[str] | None = None,
        c_cpp_mode: bool = False,
    ) -> None:
        nonlocal literal_macro_value_count, literal_macro_value_probe_count
        nonlocal c_source_macro_value_count, c_source_macro_probe_count
        source_text = (
            source_text_override
            if source_text_override is not None
            else source_names_by_fixture[fixture_name]
        )
        compare_noninteger_macro_values(
            fixture_name, source_names, baseline_path, generated_path, options,
            source_text_override, fbc_preamble, profile_label, c_source,
            c_compiler, c_compiler_options, c_cpp_mode,
        )
        value_label_suffix = f" [{profile_label}]" if profile_label else ""
        baseline_text = baseline_path.read_text(encoding="utf-8", errors="replace")
        generated_text = generated_path.read_text(encoding="utf-8", errors="replace")
        baseline_object_names = emitted_object_macro_names(baseline_text)
        generated_object_names = emitted_object_macro_names(generated_text)
        baseline_function_names = emitted_function_macro_names(baseline_text)
        generated_function_names = emitted_function_macro_names(generated_text)
        baseline_probe_names: set[str] = set()
        generated_probe_names: set[str] = set()
        object_candidates = sorted(
            integer_object_macro_names(source_text)
            .intersection(source_names)
        )
        direct_object_candidates = set(object_candidates)
        baseline_expressions: list[tuple[str, str]] = []
        generated_expressions: list[tuple[str, str]] = []
        c_expressions: list[tuple[str, str]] = []
        missing_baseline_macro_binding = False
        missing_generated_macro_binding = False
        for source_name in object_candidates:
            baseline_name = baseline_macro_binding_name(
                source_name, baseline_object_names, options)
            if baseline_name is None:
                missing_baseline_macro_binding = True
                if emitted_macro_binding_name(
                    source_name, generated_object_names, args.prefix) is None:
                    missing_generated_macro_binding = True
                continue
            generated_name = emitted_macro_binding_name(
                baseline_name, generated_object_names, args.prefix)
            if generated_name is None:
                missing_generated_macro_binding = True
                continue
            baseline_probe_names.add(baseline_name)
            generated_probe_names.add(generated_name)
            value_name = source_name + value_label_suffix
            baseline_expressions.append((value_name, baseline_name))
            generated_expressions.append((value_name, generated_name))
            c_expressions.append((value_name, source_name))

        baseline_rhs = freebasic_macro_rhs_by_name(baseline_text)
        generated_rhs = freebasic_macro_rhs_by_name(generated_text)
        baseline_integer_names = {
            name.casefold() for name in baseline_probe_names
        }
        generated_integer_names = {
            name.casefold() for name in generated_probe_names
        }
        for source_name in sorted(set(source_names) - direct_object_candidates):
            baseline_name = baseline_macro_binding_name(
                source_name, baseline_object_names, options)
            if baseline_name is None:
                missing_baseline_macro_binding = True
                if emitted_macro_binding_name(
                    source_name, generated_object_names, args.prefix) is None:
                    missing_generated_macro_binding = True
                continue
            generated_name = emitted_macro_binding_name(
                baseline_name, generated_object_names, args.prefix)
            if generated_name is None:
                missing_generated_macro_binding = True
                continue
            baseline_definitions = baseline_rhs.get(baseline_name.casefold(), [])
            generated_definitions = generated_rhs.get(generated_name.casefold(), [])
            if not baseline_definitions or not generated_definitions:
                continue
            if not all(
                freebasic_macro_expression_is_integer(
                    expression, baseline_rhs, baseline_integer_names)
                for expression in baseline_definitions
            ):
                continue
            if not all(
                freebasic_macro_expression_is_integer(
                    expression, generated_rhs, generated_integer_names)
                for expression in generated_definitions
            ):
                continue
            baseline_probe_names.update((
                baseline_name,
                *macro_value_constant_dependencies(
                    baseline_name, baseline_rhs),
            ))
            generated_probe_names.update((
                generated_name,
                *macro_value_constant_dependencies(
                    generated_name, generated_rhs),
            ))
            value_name = source_name + value_label_suffix
            baseline_expressions.append((value_name, baseline_name))
            generated_expressions.append((value_name, generated_name))
            c_expressions.append((value_name, source_name))

        function_definitions = integer_function_macro_definitions(source_text)
        function_candidates = sorted(
            set(function_definitions).intersection(source_names)
        )
        for source_name in function_candidates:
            baseline_name = baseline_macro_binding_name(
                source_name, baseline_function_names, options)
            if baseline_name is None:
                missing_baseline_macro_binding = True
                if emitted_macro_binding_name(
                    source_name, generated_function_names, args.prefix) is None:
                    missing_generated_macro_binding = True
                continue
            generated_name = emitted_macro_binding_name(
                baseline_name, generated_function_names, args.prefix)
            if generated_name is None:
                missing_generated_macro_binding = True
                continue
            baseline_probe_names.add(baseline_name)
            generated_probe_names.add(generated_name)
            parameters, _ = function_definitions[source_name]
            argument_values = itertools.product((1, 2, 3), repeat=len(parameters))
            for values in argument_values:
                arguments = ", ".join(str(value) for value in values)
                source_call = f"{source_name}({arguments})"
                call = source_call + value_label_suffix
                baseline_call = f"{baseline_name}({arguments})"
                generated_call = f"{generated_name}({arguments})"
                baseline_expressions.append((call, baseline_call))
                generated_expressions.append((call, generated_call))
                c_expressions.append((call, source_call))

        if not baseline_expressions:
            if object_candidates or function_candidates:
                if missing_baseline_macro_binding and not missing_generated_macro_binding:
                    skip_reason = "FBFrog baseline has no matching macro binding"
                elif missing_generated_macro_binding and not missing_baseline_macro_binding:
                    skip_reason = "C2FB output has no matching macro binding"
                else:
                    skip_reason = "no paired FBFrog and C2FB macro bindings"
                skip_literal_macro_values(
                    fixture_name, skip_reason)
            return

        baseline_probe_binding = output_root / (
            f"macro-values-{compile_index:04d}-fbfrog.bi"
        )
        generated_probe_binding = output_root / (
            f"macro-values-{compile_index:04d}-c2fb.bi"
        )
        baseline_probe_binding.write_text(
            macro_value_binding_subset(
                baseline_text, baseline_probe_names,
                [baseline_path.parent, tests_root],
            ),
            encoding="utf-8",
        )
        generated_probe_binding.write_text(
            macro_value_binding_subset(
                generated_text, generated_probe_names,
                [generated_path.parent, tests_root],
            ),
            encoding="utf-8",
        )

        baseline_probe, baseline_error = run_freebasic_macro_value_probe(
            baseline_probe_binding, baseline_expressions,
            f"{compile_index:04d}-fbfrog",
            output_root, tests_root, fbc_command, fbc_preamble,
            [baseline_path.parent],
        )
        if baseline_error is not None:
            profile_text = f" for {profile_label}" if profile_label else ""
            skip_literal_macro_values(
                fixture_name,
                f"the fbfrog macro subset does not compile{profile_text}: "
                f"{baseline_error[:160]}",
            )
            return
        generated_probe, generated_error = run_freebasic_macro_value_probe(
            generated_probe_binding, generated_expressions,
            f"{compile_index:04d}-c2fb",
            output_root, tests_root, fbc_command, fbc_preamble,
            [generated_path.parent],
        )
        if generated_error is not None:
            literal_macro_value_errors.append((
                fixture_name, "C2FB output", generated_error))
            return

        assert baseline_probe is not None and generated_probe is not None
        literal_macro_value_probe_count += 1
        literal_macro_value_count += len(baseline_expressions)
        for value_name, _ in baseline_expressions:
            baseline_value = baseline_probe[value_name]
            generated_value = generated_probe[value_name]
            if baseline_value != generated_value:
                literal_macro_value_mismatches.append((
                    fixture_name, value_name,
                    profile_label,
                    baseline_value, generated_value,
                ))

        if c_source is None or c_compiler is None:
            return
        c_macro_dump = source_text_override
        if c_macro_dump is None:
            c_macro_dump, c_preprocessing_error = preprocess_profile_macros(
                c_source, c_compiler, c_compiler_options or [], c_cpp_mode)
            if c_preprocessing_error is not None:
                c_source_macro_probe_skips.append((
                    fixture_name, c_preprocessing_error))
                return
        c_source_names = set(SOURCE_DEFINE.findall(c_macro_dump)) \
            .intersection(source_names)
        c_values, c_probe_skips = run_c_macro_value_probe_with_isolation(
            c_macro_dump, c_source_names, c_expressions,
            f"{compile_index:04d}-{profile_label or 'direct'}",
            output_root, c_compiler, c_cpp_mode,
            c_source, c_compiler_options,
        )
        for macro_name, reason in c_probe_skips:
            label = f"{macro_name}: " if macro_name else ""
            c_source_macro_probe_skips.append((fixture_name, label + reason))
        if not c_values:
            return
        c_source_macro_probe_count += 1
        c_source_macro_value_count += len(c_values)
        for value_name, _ in baseline_expressions:
            if value_name not in c_values:
                continue
            source_value = c_values[value_name]
            baseline_value = freebasic_macro_value_bits(
                baseline_probe[value_name])
            generated_value = freebasic_macro_value_bits(
                generated_probe[value_name])
            if baseline_value is None or generated_value is None:
                c_source_macro_probe_skips.append((
                    fixture_name,
                    f"FreeBASIC did not print an integer for {value_name}",
                ))
                continue
            if baseline_value != source_value:
                fbfrog_source_macro_divergences.append((
                    fixture_name, value_name, profile_label,
                    baseline_value, source_value,
                ))
            if generated_value != source_value:
                c2fb_source_macro_mismatches.append((
                    fixture_name, value_name, profile_label,
                    generated_value, source_value,
                ))

    def compare_profile_macro_presence(
        fixture_name: str, source_names: set[str], baseline_path: Path,
        generated_path: Path, active_macro_dump: str,
        options: list[str], fbc_preamble: list[str], profile_label: str,
    ) -> None:
        nonlocal macro_presence_case_count, macro_presence_probe_count
        active_empty_macros = sorted(
            empty_object_macro_names(active_macro_dump).intersection(source_names)
        )
        if not active_empty_macros:
            return

        baseline_text = baseline_path.read_text(encoding="utf-8", errors="replace")
        generated_text = generated_path.read_text(encoding="utf-8", errors="replace")
        baseline_names = emitted_preprocessor_macro_names(baseline_text)
        generated_names = emitted_preprocessor_macro_names(generated_text)
        probe_names: list[tuple[str, str, str]] = []
        for source_name in active_empty_macros:
            baseline_name = baseline_macro_binding_name(
                source_name, baseline_names, options)
            if baseline_name is None:
                continue
            generated_name = emitted_macro_binding_name(
                baseline_name, generated_names, args.prefix)
            if generated_name is None:
                explicitly_renamed = any(
                    option.startswith("--rename=" + source_name + "=") or
                    option.startswith("--rename-define=" + source_name + "=")
                    for option in options
                )
                generated_name = (
                    baseline_name if explicitly_renamed
                    else args.prefix + baseline_name
                )
            probe_names.append((source_name, baseline_name, generated_name))
        if not probe_names:
            return

        baseline_binding = output_root / (
            f"macro-presence-binding-{compile_index:04d}-fbfrog.bi"
        )
        generated_binding = output_root / (
            f"macro-presence-binding-{compile_index:04d}-c2fb.bi"
        )
        baseline_binding.write_text(
            macro_value_binding_subset(
                baseline_text, {baseline_name for _, baseline_name, _ in probe_names},
                [baseline_path.parent, tests_root],
            ),
            encoding="utf-8",
        )
        generated_binding.write_text(
            macro_value_binding_subset(
                generated_text, {generated_name for _, _, generated_name in probe_names},
                [generated_path.parent, tests_root],
            ),
            encoding="utf-8",
        )
        baseline_expressions = [
            (source_name, baseline_name)
            for source_name, baseline_name, _ in probe_names
        ]
        generated_expressions = [
            (source_name, generated_name)
            for source_name, _, generated_name in probe_names
        ]
        baseline_presence, baseline_error = run_freebasic_macro_presence_probe(
            baseline_binding, baseline_expressions,
            f"{compile_index:04d}-{profile_label}-fbfrog",
            output_root, tests_root, fbc_command, fbc_preamble,
            [baseline_path.parent],
        )
        if baseline_error is not None:
            macro_presence_skips.append((
                fixture_name,
                f"the fbfrog presence subset does not compile for {profile_label}: "
                f"{baseline_error[:160]}",
            ))
            return
        generated_presence, generated_error = run_freebasic_macro_presence_probe(
            generated_binding, generated_expressions,
            f"{compile_index:04d}-{profile_label}-c2fb",
            output_root, tests_root, fbc_command, fbc_preamble,
            [generated_path.parent],
        )
        if generated_error is not None:
            macro_presence_errors.append((
                fixture_name, profile_label, generated_error))
            return

        assert baseline_presence is not None and generated_presence is not None
        macro_presence_probe_count += 1
        macro_presence_case_count += len(probe_names)
        for source_name, _, _ in probe_names:
            baseline_defined = baseline_presence[source_name]
            generated_defined = generated_presence[source_name]
            if baseline_defined != generated_defined:
                macro_presence_mismatches.append((
                    fixture_name,
                    f"{source_name} [{profile_label}]",
                    baseline_defined,
                    generated_defined,
                ))

    paired_count = 0
    audited_fixture_count = 0
    version_matrix_fixture_count = 0
    script_matrix_fixture_count = 0
    target_matrix_fixture_count = 0
    clang_fallback_fixture_count = 0
    skipped_option_count = 0
    skipped_options: list[tuple[str, str]] = []
    expected_count = 0
    matched_count = 0
    failures: list[tuple[str, str]] = []
    missing: list[tuple[str, int, int, list[str]]] = []
    source_names_by_fixture: dict[str, str] = {}

    with tempfile.TemporaryDirectory(prefix="c2fb-fbfrog-audit-") as temporary:
        output_root = Path(temporary)
        copied_tests_root: Path | None = None
        for source in sorted(tests_root.rglob("*.h")):
            baseline = source.with_suffix(".bi")
            if not baseline.is_file():
                continue
            relative_name = source.relative_to(tests_root).as_posix()
            if not fbfrog_fixture_matches(relative_name, args.fixture_pattern):
                continue
            paired_count += 1
            if args.compile_bindings:
                baseline_compile_status[relative_name] = compile_output(
                    baseline, relative_name, "fbfrog baseline")

            source_text = source.read_text(encoding="utf-8", errors="replace")
            source_names_by_fixture[relative_name] = source_text
            source_names = set(SOURCE_DEFINE.findall(source_text))
            source_integer_macros = (
                integer_object_macro_names(source_text)
                if args.compare_macro_values else set()
            )
            baseline_names = emitted_binding_names(
                baseline.read_text(encoding="utf-8", errors="replace"))
            fbfrog_arguments = fbfrog_options(source)
            version_script = None if fbfrog_arguments is None else \
                parse_fbfrog_version_script(fbfrog_arguments, source.parent)
            options = None if fbfrog_arguments is None else \
                translate_fbfrog_options(fbfrog_arguments)
            if options is None and version_script is None:
                relative_name = source.relative_to(tests_root).as_posix()
                if fbfrog_arguments is None:
                    skipped_option_count += 1
                    skipped_options.append((
                        relative_name, "invalid fbfrog option annotation"))
                    if source_integer_macros:
                        skip_literal_macro_values(
                            relative_name, "invalid fbfrog option annotation")
                    continue
                if copied_tests_root is None:
                    copied_tests_root = output_root / "fbfrog-tests"
                    try:
                        shutil.copytree(tests_root, copied_tests_root, symlinks=True)
                    except OSError as error:
                        failures.append((relative_name, f"cannot stage fbfrog fixtures: {error}"))
                        continue
                source_copy = copied_tests_root / source.relative_to(tests_root)
                copied_arguments = fbfrog_options(source_copy)
                if copied_arguments is None:
                    failures.append((relative_name, "cannot parse staged fbfrog options"))
                    continue
                macro_value_profile_callback = None
                record_layout_profile_callback = None
                if args.compare_record_layouts:
                    baseline_text = baseline.read_text(
                        encoding="utf-8", errors="replace")
                    cpp_mode = fbfrog_fixture_uses_cpp(source, tests_root)

                    def compare_script_profile_record_layouts(
                        profile_binding, target, profile,
                    ):
                        profile_options = list(
                            profile.get("compiler_options", []))
                        compiler_text = str(profile.get("compiler", args.cc))
                        generated_text = profile_binding.read_text(
                            encoding="utf-8", errors="replace")
                        fbc_preamble = freebasic_macro_preamble(
                            profile_options, baseline_text, generated_text)
                        fbc_preamble.extend(
                            freebasic_target_feature_preamble(target))
                        profile_label = (
                            f"{target['fbfrog_target']}:"
                            f"{profile.get('name', 'profile')}"
                        )
                        compare_record_layouts(
                            relative_name, source_copy, baseline,
                            profile_binding,
                            list(profile.get("c2fb_options", [])),
                            compiler_text, profile_options, cpp_mode,
                            fbc_preamble, profile_label,
                        )

                    record_layout_profile_callback = \
                        compare_script_profile_record_layouts
                if args.compare_macro_values and args.scope == "macros":
                    is_fbfrog_script = (
                        len(copied_arguments) == 1 and
                        Path(copied_arguments[0]).suffix.casefold() == ".fbfrog"
                    )
                    if is_fbfrog_script:
                        baseline_text = baseline.read_text(
                            encoding="utf-8", errors="replace")
                        cpp_mode = fbfrog_fixture_uses_cpp(source, tests_root)

                        def compare_script_profile_macro_bindings(
                            profile_binding, target, profile,
                        ):
                            profile_options = list(
                                profile.get("compiler_options", []))
                            compiler_text = str(profile.get("compiler", args.cc))
                            macro_dump, preprocessing_error = \
                                preprocess_profile_macros(
                                    source_copy, compiler_text,
                                    profile_options, cpp_mode,
                                )
                            if preprocessing_error is not None:
                                skip_literal_macro_values(
                                    relative_name,
                                    "cannot preprocess script profile "
                                    f"{profile.get('name', 'profile')}: "
                                    f"{preprocessing_error[:160]}",
                                )
                                return
                            active_names = set(SOURCE_DEFINE.findall(macro_dump)) \
                                .intersection(source_names)
                            if not active_names:
                                return
                            generated_text = profile_binding.read_text(
                                encoding="utf-8", errors="replace")
                            fbc_preamble = freebasic_macro_preamble(
                                profile_options, baseline_text, generated_text)
                            fbc_preamble.extend(
                                freebasic_target_feature_preamble(target))
                            profile_label = (
                                f"{target['fbfrog_target']}:"
                                f"{profile.get('name', 'profile')}"
                            )
                            c2fb_options = list(profile.get("c2fb_options", []))
                            compare_literal_macro_values(
                                relative_name, active_names, baseline,
                                profile_binding, c2fb_options,
                                source_text_override=macro_dump,
                                fbc_preamble=fbc_preamble,
                                profile_label=profile_label,
                                c_source=source_copy,
                                c_compiler=compiler_text,
                                c_compiler_options=profile_options,
                                c_cpp_mode=cpp_mode,
                            )
                            compare_profile_macro_presence(
                                relative_name, active_names, baseline,
                                profile_binding, macro_dump, c2fb_options,
                                fbc_preamble, profile_label,
                            )

                        macro_value_profile_callback = \
                            compare_script_profile_macro_bindings
                    elif source_integer_macros:
                        skip_literal_macro_values(
                            relative_name,
                            "script options do not expose comparable profiles",
                        )
                generated_names, script_options, matrix_error = \
                    audit_fbfrog_script_matrix(
                        converter, copied_tests_root, source_copy, output_root,
                        args.prefix, args.cc, args.scope, copied_arguments,
                        compile_output if args.compile_bindings else None,
                        args.compile_body_candidates,
                        macro_value_profile_callback,
                        record_layout_profile_callback,
                    )
                if matrix_error is not None:
                    failures.append((relative_name, matrix_error))
                    continue
                expected_names = (
                    expected_macro_names(baseline_names, source_names, script_options)
                    if args.scope == "macros" else
                    expected_declaration_names(baseline_names, source_names, script_options)
                )
                script_matrix_fixture_count += 1
                if not expected_names:
                    continue
                audited_fixture_count += 1
                matched = matched_emitted_names(
                    expected_names, generated_names, args.prefix)
                absent = sorted(expected_names - matched)
                expected_count += len(expected_names)
                matched_count += len(matched)
                if absent:
                    missing.append((
                        relative_name, len(matched), len(expected_names), absent))
                continue
            if options is None:
                options = []
            if args.scope == "macros":
                expected_names = expected_macro_names(
                    baseline_names, source_names, options)
            else:
                expected_names = expected_declaration_names(
                    baseline_names, declaration_source_names(source), options)
            if not expected_names:
                continue
            audited_fixture_count += 1
            relative_name = source.relative_to(tests_root).as_posix()
            if version_script is not None:
                if source_integer_macros and not args.compare_macro_values:
                    skip_literal_macro_values(
                        relative_name, "fixture uses a version selector")
                version_matrix_fixture_count += 1
                macro_profile_callback = None
                record_layout_profile_callback = None
                if args.compare_record_layouts:
                    cpp_layout_mode = fbfrog_fixture_uses_cpp(
                        source, tests_root)
                    baseline_layout_text = baseline.read_text(
                        encoding="utf-8", errors="replace")

                    def compare_version_profile_record_layouts(
                        profile_binding, profile,
                    ):
                        profile_options = list(
                            profile.get("compiler_options", []))
                        compiler_text = str(profile.get("compiler", args.cc))
                        generated_text = profile_binding.read_text(
                            encoding="utf-8", errors="replace")
                        fbc_preamble = freebasic_macro_preamble(
                            profile_options, baseline_layout_text,
                            generated_text,
                        )
                        compare_record_layouts(
                            relative_name, source, baseline, profile_binding,
                            options, compiler_text, profile_options,
                            cpp_layout_mode, fbc_preamble,
                            str(profile.get("name", "version")),
                        )

                    record_layout_profile_callback = \
                        compare_version_profile_record_layouts
                if args.compare_macro_values and args.scope == "macros":
                    cpp_mode = fbfrog_fixture_uses_cpp(source, tests_root)
                    version_options = options or []

                    def compare_version_profile_macro_bindings(
                        profile_binding, profile,
                    ):
                        profile_options = list(
                            profile.get("compiler_options", []))
                        compiler_text = str(profile.get("compiler", args.cc))
                        macro_dump, preprocessing_error = \
                            preprocess_profile_macros(
                                source, compiler_text, profile_options, cpp_mode,
                            )
                        if preprocessing_error is not None:
                            skip_literal_macro_values(
                                relative_name,
                                "cannot preprocess version profile "
                                f"{profile.get('name', 'profile')}: "
                                f"{preprocessing_error[:160]}",
                            )
                            return
                        active_names = set(SOURCE_DEFINE.findall(macro_dump)) \
                            .intersection(source_names)
                        if not active_names:
                            return
                        generated_text = profile_binding.read_text(
                            encoding="utf-8", errors="replace")
                        fbc_preamble = freebasic_macro_preamble(
                            profile_options, baseline.read_text(
                                encoding="utf-8", errors="replace"),
                            generated_text,
                        )
                        profile_label = str(profile.get("name", "version"))
                        compare_literal_macro_values(
                            relative_name, active_names, baseline,
                            profile_binding, version_options,
                            source_text_override=macro_dump,
                            fbc_preamble=fbc_preamble,
                            profile_label=profile_label,
                            c_source=source,
                            c_compiler=compiler_text,
                            c_compiler_options=profile_options,
                            c_cpp_mode=cpp_mode,
                        )
                        compare_profile_macro_presence(
                            relative_name, active_names, baseline,
                            profile_binding, macro_dump, version_options,
                            fbc_preamble, profile_label,
                        )

                    macro_profile_callback = compare_version_profile_macro_bindings
                generated_names, matrix_error = audit_fbfrog_version_matrix(
                    converter, tests_root, source, output_root, args.prefix,
                    args.cc, args.scope, version_script,
                    compile_output if args.compile_bindings else None,
                    args.compile_body_candidates,
                    macro_profile_callback,
                    record_layout_profile_callback,
                )
                if matrix_error is not None:
                    failures.append((relative_name, matrix_error))
                    continue
                matched = matched_emitted_names(
                    expected_names, generated_names, args.prefix)
                absent = sorted(expected_names - matched)
                expected_count += len(expected_names)
                matched_count += len(matched)
                if absent:
                    missing.append((
                        relative_name, len(matched), len(expected_names), absent))
                continue

            target_filters = fbfrog_fixture_target_filters(source, tests_root)
            if target_filters:
                if source_integer_macros and not args.compare_macro_values:
                    skip_literal_macro_values(
                        relative_name, "fixture uses target-specific headers")
                target_matrix_fixture_count += 1
                if copied_tests_root is None:
                    copied_tests_root = output_root / "fbfrog-tests"
                    try:
                        shutil.copytree(tests_root, copied_tests_root, symlinks=True)
                    except OSError as error:
                        failures.append((
                            relative_name,
                            f"cannot stage fbfrog fixtures: {error}",
                        ))
                        continue
                source_copy = copied_tests_root / source.relative_to(tests_root)
                matrix_options = list(fbfrog_arguments or [])
                for target in target_filters:
                    matrix_options.extend(("-target", target))

                macro_value_profile_callback = None
                record_layout_profile_callback = None
                if args.compare_record_layouts:
                    baseline_text = baseline.read_text(
                        encoding="utf-8", errors="replace")
                    cpp_mode = fbfrog_fixture_uses_cpp(source, tests_root)

                    def compare_target_profile_record_layouts(
                        profile_binding, target, profile,
                    ):
                        profile_options = list(
                            profile.get("compiler_options", []))
                        compiler_text = str(profile.get("compiler", args.cc))
                        generated_text = profile_binding.read_text(
                            encoding="utf-8", errors="replace")
                        fbc_preamble = freebasic_macro_preamble(
                            profile_options, baseline_text, generated_text)
                        fbc_preamble.extend(
                            freebasic_target_feature_preamble(target))
                        profile_label = (
                            f"{target['fbfrog_target']}:"
                            f"{profile.get('name', 'profile')}"
                        )
                        compare_record_layouts(
                            relative_name, source_copy, baseline,
                            profile_binding,
                            list(options or profile.get("c2fb_options", [])),
                            compiler_text, profile_options, cpp_mode,
                            fbc_preamble, profile_label,
                        )

                    record_layout_profile_callback = \
                        compare_target_profile_record_layouts
                if args.compare_macro_values and args.scope == "macros":
                    if not safe_macro_value_options(options):
                        skip_literal_macro_values(
                            relative_name,
                            "target profile uses options that change macro values",
                        )
                    else:
                        baseline_text = baseline.read_text(
                            encoding="utf-8", errors="replace")
                        cpp_mode = fbfrog_fixture_uses_cpp(source, tests_root)

                        def compare_target_profile_macro_values(
                            profile_binding, target, profile,
                        ):
                            profile_options = list(
                                profile.get("compiler_options", []))
                            compiler_text = str(profile.get("compiler", args.cc))
                            macro_dump, preprocessing_error = \
                                preprocess_profile_macros(
                                    source_copy, compiler_text,
                                    profile_options, cpp_mode,
                                )
                            if preprocessing_error is not None:
                                skip_literal_macro_values(
                                    relative_name,
                                    "cannot preprocess target profile "
                                    f"{target['fbfrog_target']}: "
                                    f"{preprocessing_error[:160]}",
                                )
                                return
                            active_names = set(SOURCE_DEFINE.findall(macro_dump)) \
                                .intersection(source_names)
                            if not active_names:
                                return
                            generated_text = profile_binding.read_text(
                                encoding="utf-8", errors="replace")
                            fbc_preamble = freebasic_macro_preamble(
                                profile_options, baseline_text, generated_text)
                            fbc_preamble.extend(
                                freebasic_target_feature_preamble(target))
                            profile_label = (
                                f"{target['fbfrog_target']}:"
                                f"{profile.get('name', 'profile')}"
                            )
                            compare_literal_macro_values(
                                relative_name, active_names, baseline,
                                profile_binding, options,
                                source_text_override=macro_dump,
                                fbc_preamble=fbc_preamble,
                                profile_label=profile_label,
                                c_source=source_copy,
                                c_compiler=compiler_text,
                                c_compiler_options=profile_options,
                                c_cpp_mode=cpp_mode,
                            )
                            compare_profile_macro_presence(
                                relative_name, active_names, baseline,
                                profile_binding, macro_dump, options,
                                fbc_preamble, profile_label,
                            )

                        macro_value_profile_callback = \
                            compare_target_profile_macro_values
                generated_names, _, matrix_error = audit_fbfrog_script_matrix(
                    converter, copied_tests_root, source_copy, output_root,
                    args.prefix, args.cc, args.scope, matrix_options,
                    compile_output if args.compile_bindings else None,
                    args.compile_body_candidates,
                    macro_value_profile_callback,
                    record_layout_profile_callback,
                )
                if matrix_error is not None:
                    failures.append((relative_name, matrix_error))
                    continue
                matched = matched_emitted_names(
                    expected_names, generated_names, args.prefix)
                absent = sorted(expected_names - matched)
                expected_count += len(expected_names)
                matched_count += len(matched)
                if absent:
                    missing.append((
                        relative_name, len(matched), len(expected_names), absent))
                continue

            output = output_root / (relative_name.replace("/", "_") + ".bi")
            converter_options, compiler_options = split_compiler_options(options)
            missing_include_options = inferred_missing_include_options(
                source, baseline, tests_root)
            cpp_mode_options = ["--cxx", "--traditional-cpp-fallback"] \
                if fbfrog_fixture_uses_cpp(source, tests_root) else []
            command = [
                str(converter), "generic-header", str(source), str(output),
                "--prefix=" + args.prefix,
                "--include-static-objects", "--private-static-objects",
                "--fbfrog-string-defaults",
                *converter_options, *missing_include_options,
                *cpp_mode_options, args.cc,
                *compiler_options,
                "-I" + str(source.parent), "-I" + str(tests_root),
            ]
            result = subprocess.run(
                command, capture_output=True, text=True, check=False)
            if result.returncode != 0 and cpp_mode_options:
                try:
                    compiler_parts = shlex.split(args.cc)
                except ValueError:
                    compiler_parts = []
                compiler_basename = (
                    Path(compiler_parts[0]).name.casefold()
                    if compiler_parts else ""
                )
                clang_compiler = shutil.which("clang++")
                if clang_compiler and compiler_basename not in {"clang", "clang++"}:
                    fallback_command = list(command)
                    compiler_position = fallback_command.index(args.cc, 7)
                    fallback_command[compiler_position] = clang_compiler
                    if output.is_file():
                        output.unlink()
                    result = subprocess.run(
                        fallback_command, capture_output=True, text=True,
                        check=False)
                    if result.returncode == 0 and output.is_file():
                        clang_fallback_fixture_count += 1
            if result.returncode != 0 or not output.is_file():
                detail = (result.stdout + result.stderr).strip()
                failures.append((relative_name, detail[:400]))
                if source_integer_macros:
                    skip_literal_macro_values(
                        relative_name, "C2FB did not produce a direct binding")
                continue

            if args.compile_bindings:
                compile_output(output, relative_name, "C2FB binding")

            if args.compare_record_layouts:
                baseline_text = baseline.read_text(
                    encoding="utf-8", errors="replace")
                generated_text = output.read_text(
                    encoding="utf-8", errors="replace")
                layout_fbc_preamble = freebasic_macro_preamble(
                    compiler_options, baseline_text, generated_text)
                compare_record_layouts(
                    relative_name, source, baseline, output, options, args.cc,
                    [*compiler_options, "-I" + str(source.parent),
                     "-I" + str(tests_root)],
                    bool(cpp_mode_options), layout_fbc_preamble,
                )

            generated_names = emitted_binding_names(
                output.read_text(encoding="utf-8", errors="replace"))
            if args.compare_macro_values and args.scope == "macros":
                if not safe_macro_value_options(options):
                    if source_integer_macros:
                        skip_literal_macro_values(
                            relative_name, "fixture options change macro values")
                else:
                    compare_literal_macro_values(
                        relative_name, source_names, baseline, output, options,
                        c_source=source,
                        c_compiler=args.cc,
                        c_compiler_options=[
                            *compiler_options, "-I" + str(source.parent),
                            "-I" + str(tests_root),
                        ],
                        c_cpp_mode=bool(cpp_mode_options),
                    )
            if args.scope == "declarations" and not cpp_mode_options and \
               source_contains_function_definition(source):
                candidate = output_root / (
                    relative_name.replace("/", "_") + "_candidates.bas")
                body_command = [
                    str(converter), "translate-simple-generic-c", str(source),
                    str(candidate), *body_options(options), args.cc,
                    *compiler_options,
                    "-I" + str(source.parent), "-I" + str(tests_root),
                ]
                body_result = subprocess.run(
                    body_command, capture_output=True, text=True, check=False)
                if body_result.returncode != 0 or not candidate.is_file():
                    detail = (body_result.stdout + body_result.stderr).strip()
                    failures.append((relative_name, detail[:400]))
                    continue
                if args.compile_body_candidates and args.compile_bindings:
                    compile_output(
                        output, relative_name, "C2FB binding+body", (candidate,))
                generated_names.update(emitted_binding_names(
                    candidate.read_text(encoding="utf-8", errors="replace")))
            matched = matched_emitted_names(
                expected_names, generated_names, args.prefix)
            absent = sorted(expected_names - matched)
            expected_count += len(expected_names)
            matched_count += len(matched)
            if absent:
                missing.append((
                    relative_name, len(matched), len(expected_names), absent))

    percent = 100.0 if expected_count == 0 else 100.0 * matched_count / expected_count
    print(f"paired fbfrog fixtures: {paired_count}")
    if args.fixture_pattern:
        print("fixture patterns: " + ", ".join(args.fixture_pattern))
    print(f"fixture scope: {args.scope}")
    print(f"fixtures audited: {audited_fixture_count}")
    print(f"version-matrix script fixtures audited: {version_matrix_fixture_count}")
    print(f"fbfrog script-matrix fixtures audited: {script_matrix_fixture_count}")
    print(f"preprocessor target-matrix fixtures audited: {target_matrix_fixture_count}")
    print(f"C++ fixtures retried with clang++: {clang_fallback_fixture_count}")
    print(f"fixtures skipped for fbfrog-specific options: {skipped_option_count}")
    print(f"matched emitted {args.scope} names: {matched_count}/{expected_count} ({percent:.1f}%)")
    print(f"C2FB conversion failures: {len(failures)}")
    if args.compare_record_layouts:
        print(
            "C record layout values checked: "
            f"{record_layout_value_count} across "
            f"{record_layout_record_count} record/profile probes"
        )
        print(
            "C2FB/source record layout mismatches: "
            f"{len(record_layout_c2fb_mismatches)}"
        )
        print(
            "fbfrog/source record layout divergences: "
            f"{len(record_layout_fbfrog_divergences)}"
        )
        source_layout_skips = sum(
            reason.startswith("C layout probe failed:")
            for _, _, _, reason in record_layout_skips
        )
        fbfrog_layout_skips = sum(
            reason.startswith("FBFrog layout probe failed:")
            for _, _, _, reason in record_layout_skips
        )
        c2fb_layout_skips = sum(
            reason.startswith((
                "C2FB output has no matching record type",
                "C2FB layout probe failed:",
            ))
            for _, _, _, reason in record_layout_skips
        )
        print(f"C source layout probes skipped: {source_layout_skips}")
        print(f"FBFrog layout probes skipped: {fbfrog_layout_skips}")
        print(f"C2FB layout probes skipped: {c2fb_layout_skips}")
        fbfrog_profile_probe_failures = {
            (fixture, type_name, profile_label)
            for fixture, type_name, profile_label, reason in record_layout_skips
            if reason.startswith("FBFrog layout probe failed:")
        }
        c2fb_skips_with_compilable_baseline = 0
        c2fb_skips_with_profile_baseline_failure = 0
        c2fb_skips_with_usable_profile_baseline = 0
        c2fb_skips_with_failed_baseline = 0
        c2fb_skips_without_baseline_status = 0
        for fixture, type_name, profile_label, reason in record_layout_skips:
            if not reason.startswith((
                "C2FB output has no matching record type",
                "C2FB layout probe failed:",
            )):
                continue
            baseline_status = baseline_compile_status.get(fixture)
            if baseline_status is True:
                c2fb_skips_with_compilable_baseline += 1
                if (fixture, type_name, profile_label) in fbfrog_profile_probe_failures:
                    c2fb_skips_with_profile_baseline_failure += 1
                else:
                    c2fb_skips_with_usable_profile_baseline += 1
            elif baseline_status is False:
                c2fb_skips_with_failed_baseline += 1
            else:
                c2fb_skips_without_baseline_status += 1
        print(
            "C2FB layout skips with FBC-compilable FBFrog baseline: "
            f"{c2fb_skips_with_compilable_baseline}"
        )
        print(
            "C2FB layout skips with FBFrog profile-probe failure: "
            f"{c2fb_skips_with_profile_baseline_failure}"
        )
        print(
            "C2FB layout skips with usable FBFrog profile baseline: "
            f"{c2fb_skips_with_usable_profile_baseline}"
        )
        print(
            "C2FB layout skips with non-compilable FBFrog baseline: "
            f"{c2fb_skips_with_failed_baseline}"
        )
        print(
            "C2FB layout skips without baseline compile status: "
            f"{c2fb_skips_without_baseline_status}"
        )
        c2fb_skips_with_compilable_baseline = [
            skip for skip in record_layout_skips
            if skip[3].startswith((
                "C2FB output has no matching record type",
                "C2FB layout probe failed:",
            )) and baseline_compile_status.get(skip[0]) is True and
            (skip[0], skip[1], skip[2]) not in fbfrog_profile_probe_failures
        ]
        for fixture, type_name, profile_label, reason in \
                c2fb_skips_with_compilable_baseline[:20]:
            print(
                f"C2FB layout skip with compilable FBFrog baseline {fixture} "
                f"({type_name}, {profile_label}): {reason}"
            )
        c2fb_skips_with_failed_profile_baseline = [
            skip for skip in record_layout_skips
            if skip[3].startswith((
                "C2FB output has no matching record type",
                "C2FB layout probe failed:",
            )) and baseline_compile_status.get(skip[0]) is True and
            (skip[0], skip[1], skip[2]) in fbfrog_profile_probe_failures
        ]
        for fixture, type_name, profile_label, reason in \
                c2fb_skips_with_failed_profile_baseline[:20]:
            print(
                "C2FB layout skip with compilable FBFrog baseline but failed "
                f"FBFrog profile probe {fixture} ({type_name}, "
                f"{profile_label}): {reason}"
            )
        print(
            f"record layout probes skipped: {len(record_layout_skips)}"
        )
        skip_groups: dict[str, list[tuple[str, str, str, str]]] = {}
        for skip in record_layout_skips:
            category = record_layout_skip_category(skip[3])
            skip_groups.setdefault(category, []).append(skip)
        for category in sorted(skip_groups):
            print(f"record layout skip category {category}: {len(skip_groups[category])}")
        for fixture, type_name, member, generated_value, source_value in \
                record_layout_c2fb_mismatches:
            print(
                f"C2FB/source record layout mismatch {fixture} "
                f"({type_name}.{member}): C2FB={generated_value}, "
                f"C={source_value}"
            )
        for fixture, type_name, member, baseline_value, source_value in \
                record_layout_fbfrog_divergences:
            print(
                f"fbfrog/source record layout divergence {fixture} "
                f"({type_name}.{member}): fbfrog={baseline_value}, "
                f"C={source_value}"
            )
        for category in sorted(skip_groups):
            examples = skip_groups[category]
            example_limit = 10 if category.startswith("C2FB ") else 1
            for fixture, type_name, profile_label, reason in examples[:example_limit]:
                print(
                    f"record layout probe skipped {fixture} "
                    f"({type_name}, {profile_label}): {reason}"
                )
    if args.compare_macro_values:
        print(
            "matching evaluated integer macro values: "
            f"{literal_macro_value_count} across "
            f"{literal_macro_value_probe_count} fixture/profile probes"
        )
        print(f"macro value mismatches: {len(literal_macro_value_mismatches)}")
        print(f"macro value probe failures: {len(literal_macro_value_errors)}")
        print(f"macro value probe fixtures skipped: {len(literal_macro_value_skips)}")
        print(
            "C source macro values checked: "
            f"{c_source_macro_value_count} across "
            f"{c_source_macro_probe_count} fixture/profile probes"
        )
        print(
            "C2FB/source macro value mismatches: "
            f"{len(c2fb_source_macro_mismatches)}"
        )
        print(
            "fbfrog/source macro value divergences: "
            f"{len(fbfrog_source_macro_divergences)}"
        )
        strict_literal_macro_value_mismatches = \
            macro_value_mismatches_not_explained_by_source(
                literal_macro_value_mismatches,
                fbfrog_source_macro_divergences,
                c2fb_source_macro_mismatches,
            )
        print(
            "macro value mismatches not explained by C source results: "
            f"{len(strict_literal_macro_value_mismatches)}"
        )
        print(f"C source macro value probes skipped: {len(c_source_macro_probe_skips)}")
        for fixture, name, profile, baseline_value, generated_value in \
                literal_macro_value_mismatches:
            profile_suffix = f" [{profile}]" if profile else ""
            print(
                f"macro value mismatch {fixture} ({name}){profile_suffix}: "
                f"fbfrog={baseline_value}, C2FB={generated_value}"
            )
        for fixture, name, profile, generated_value, source_value in \
                c2fb_source_macro_mismatches:
            profile_suffix = f" [{profile}]" if profile else ""
            print(
                f"C2FB/source macro value mismatch {fixture} ({name}){profile_suffix}: "
                f"C2FB={generated_value:016X}, C={source_value:016X}"
            )
        for fixture, name, profile, baseline_value, source_value in \
                fbfrog_source_macro_divergences:
            profile_suffix = f" [{profile}]" if profile else ""
            print(
                f"fbfrog/source macro value divergence {fixture} ({name})"
                f"{profile_suffix}: "
                f"fbfrog={baseline_value:016X}, C={source_value:016X}"
            )
        for fixture, detail in c_source_macro_probe_skips:
            print(f"C source macro value probe skipped {fixture}: {detail}")
        print(
            "matching empty-macro presence cases: "
            f"{macro_presence_case_count} across "
            f"{macro_presence_probe_count} fixture/profile probes"
        )
        print(f"macro presence mismatches: {len(macro_presence_mismatches)}")
        print(f"macro presence probe failures: {len(macro_presence_errors)}")
        print(f"macro presence probe fixtures skipped: {len(macro_presence_skips)}")
        for fixture, name, baseline_defined, generated_defined in \
                macro_presence_mismatches:
            print(
                f"macro presence mismatch {fixture} ({name}): "
                f"fbfrog={int(baseline_defined)}, C2FB={int(generated_defined)}"
            )
        for fixture, kind, detail in literal_macro_value_errors:
            print(f"macro value probe failed {fixture} ({kind}): {detail}")
        for fixture, reason in literal_macro_value_skips:
            print(f"macro value probe skipped {fixture}: {reason}")

        print(
            "matching evaluated noninteger macro values: "
            f"{noninteger_macro_value_count} across "
            f"{noninteger_macro_value_probe_count} fixture/profile probes"
        )
        print(
            "noninteger macro value mismatches: "
            f"{len(noninteger_macro_value_mismatches)}"
        )
        print(
            "noninteger macro value probe failures: "
            f"{len(noninteger_macro_value_errors)}"
        )
        print(
            "noninteger macro value fixtures skipped: "
            f"{len(noninteger_macro_value_skips)}"
        )
        print(
            "C source noninteger macro values checked: "
            f"{c_source_noninteger_macro_value_count} across "
            f"{c_source_noninteger_macro_probe_count} fixture/profile probes"
        )
        print(
            "C2FB/source noninteger macro value mismatches: "
            f"{len(c2fb_source_noninteger_macro_mismatches)}"
        )
        print(
            "fbfrog/source noninteger macro value divergences: "
            f"{len(fbfrog_source_noninteger_macro_divergences)}"
        )
        fbfrog_noninteger_divergence_keys = {
            (fixture, name, profile)
            for fixture, name, profile, _, _ in
            fbfrog_source_noninteger_macro_divergences
        }
        c2fb_noninteger_mismatch_keys = {
            (fixture, name, profile)
            for fixture, name, profile, _, _ in
            c2fb_source_noninteger_macro_mismatches
        }
        strict_noninteger_macro_value_mismatches = [
            mismatch
            for mismatch in noninteger_macro_value_mismatches
            if (mismatch[0], mismatch[1], mismatch[2])
            not in fbfrog_noninteger_divergence_keys
            or (mismatch[0], mismatch[1], mismatch[2])
            in c2fb_noninteger_mismatch_keys
        ]
        print(
            "noninteger macro mismatches not explained by C source results: "
            f"{len(strict_noninteger_macro_value_mismatches)}"
        )
        print(
            f"C source noninteger macro probes skipped: "
            f"{len(c_source_noninteger_macro_probe_skips)}"
        )
        for fixture, name, profile, baseline_value, generated_value in \
                noninteger_macro_value_mismatches:
            profile_suffix = f" [{profile}]" if profile else ""
            print(
                f"noninteger macro value mismatch {fixture} ({name})"
                f"{profile_suffix}: fbfrog={baseline_value}, C2FB={generated_value}"
            )
        for fixture, name, profile, generated_value, source_value in \
                c2fb_source_noninteger_macro_mismatches:
            profile_suffix = f" [{profile}]" if profile else ""
            print(
                f"C2FB/source noninteger macro value mismatch {fixture} "
                f"({name}){profile_suffix}: C2FB={generated_value}, "
                f"C={source_value}"
            )
        for fixture, name, profile, baseline_value, source_value in \
                fbfrog_source_noninteger_macro_divergences:
            profile_suffix = f" [{profile}]" if profile else ""
            print(
                f"fbfrog/source noninteger macro value divergence {fixture} "
                f"({name}){profile_suffix}: fbfrog={baseline_value}, "
                f"C={source_value}"
            )
        for fixture, kind, detail in noninteger_macro_value_errors:
            print(
                f"noninteger macro value probe failed {fixture} ({kind}): "
                f"{detail}"
            )
        for fixture, reason in noninteger_macro_value_skips:
            print(f"noninteger macro value probe skipped {fixture}: {reason}")
        for fixture, detail in c_source_noninteger_macro_probe_skips:
            print(f"C source noninteger macro probe skipped {fixture}: {detail}")
        for fixture, kind, detail in macro_presence_errors:
            print(f"macro presence probe failed {fixture} ({kind}): {detail}")
        for fixture, reason in macro_presence_skips:
            print(f"macro presence probe skipped {fixture}: {reason}")
    if args.compile_bindings:
        compilable_gaps, noncompilable_gaps, unchecked_gaps = \
            missing_name_counts_by_baseline_status(
                missing, baseline_compile_status)
        baseline_results = [
            record for record in compile_records if record[1] == "fbfrog baseline"
        ]
        baseline_compile_failures = compile_failures_for_kind(
            compile_records, "fbfrog baseline")
        c2fb_results = [
            record for record in compile_records if record[1] != "fbfrog baseline"
        ]
        c2fb_header_results = [
            record for record in c2fb_results
            if record[1] != "C2FB binding+body"
        ]
        c2fb_body_results = [
            record for record in c2fb_results
            if record[1] == "C2FB binding+body"
        ]
        c2fb_valid_baseline_failures = [
            record for record in c2fb_results
            if not record[2] and baseline_compile_status.get(record[0], False)
        ]
        compile_failures_on_valid_baselines = c2fb_valid_baseline_failures
        print(
            "FBC-compilable fbfrog baselines: "
            f"{sum(record[2] for record in baseline_results)}/{len(baseline_results)}"
        )
        print(
            "FBFrog baseline compile failures: "
            f"{len(baseline_compile_failures)}/{len(baseline_results)}"
        )
        print(
            "FBC-compilable C2FB header outputs: "
            f"{sum(record[2] for record in c2fb_header_results)}/{len(c2fb_header_results)}"
        )
        if args.compile_body_candidates:
            print(
                "FBC-compilable C2FB binding+body outputs: "
                f"{sum(record[2] for record in c2fb_body_results)}/{len(c2fb_body_results)}"
            )
            c2fb_valid_body_failures = [
                record for record in c2fb_body_results
                if not record[2] and baseline_compile_status.get(record[0], False)
            ]
            print(
                "C2FB body compile failures where the fbfrog baseline compiles: "
                f"{len(c2fb_valid_body_failures)}"
            )
        print(
            "C2FB compile failures where the fbfrog baseline compiles: "
            f"{len(c2fb_valid_baseline_failures)}"
        )
        print(
            f"missing emitted {args.scope} names on FBC-compilable fbfrog baselines: "
            f"{compilable_gaps}"
        )
        print(
            f"missing emitted {args.scope} names on non-compilable fbfrog baselines: "
            f"{noncompilable_gaps}"
        )
        if unchecked_gaps:
            print(
                f"missing emitted {args.scope} names without a baseline compile result: "
                f"{unchecked_gaps}"
            )
        failure_limit = len(c2fb_valid_baseline_failures) \
            if args.report_all_compile_failures else 20
        for fixture, kind, _, detail in c2fb_valid_baseline_failures[:failure_limit]:
            print(f"FBC failure {fixture} ({kind}): {detail}")
        if args.report_all_compile_failures:
            for fixture, _, _, detail in baseline_compile_failures:
                print(f"FBFrog FBC failure {fixture}: {detail}")
            _, noncompilable_baseline_failures, unchecked_baseline_failures = \
                c2fb_compile_failures_by_baseline_status(
                    compile_records, baseline_compile_status)
            print(
                "C2FB compile failures where the fbfrog baseline also fails: "
                f"{len(noncompilable_baseline_failures)}"
            )
            print(
                "C2FB compile failures without a paired baseline result: "
                f"{len(unchecked_baseline_failures)}"
            )
            for fixture, kind, _, detail in (
                noncompilable_baseline_failures + unchecked_baseline_failures
            ):
                print(f"C2FB FBC failure {fixture} ({kind}): {detail}")
    for fixture, detail in skipped_options:
        print(f"skipped {fixture}: {detail}")
    for fixture, found, total, names in missing:
        print(f"missing {fixture}: {found}/{total}: {', '.join(names)}")
    for fixture, detail in failures:
        print(f"failed {fixture}: {detail}")

    strict_missing = missing
    if args.compile_bindings:
        strict_missing = missing_names_with_comparable_baselines(
            missing, baseline_compile_status)
    if args.strict:
        print(f"strict missing {args.scope} names: {len(strict_missing)}")

    if args.strict and (
        strict_missing or failures or skipped_option_count or
        compile_failures_on_valid_baselines or
        strict_literal_macro_value_mismatches or literal_macro_value_errors or
        strict_noninteger_macro_value_mismatches or
        noninteger_macro_value_errors or
        c2fb_source_macro_mismatches or
        c2fb_source_noninteger_macro_mismatches or
        macro_presence_mismatches or macro_presence_errors or
        record_layout_c2fb_mismatches or record_layout_skips
    ):
        return 1
    if args.fail_on_c2fb_layout_mismatch and record_layout_c2fb_mismatches:
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--converter", type=Path, required=True)
    parser.add_argument("--fbfrog-tests", type=Path, required=True)
    parser.add_argument("--cc", default="cc")
    parser.add_argument("--fbc", default="fbc")
    parser.add_argument(
        "--fbc-include-directory", dest="fbc_include_directories",
        action="append", default=[], metavar="DIR",
        help=(
            "add a FreeBASIC include directory when compiling bindings; "
            "source checkouts are detected automatically"
        ),
    )
    parser.add_argument("--prefix", default="c2fb_")
    parser.add_argument(
        "--fixture-pattern", action="append", default=[], metavar="GLOB",
        help="audit only paired fixture paths matching this POSIX glob; repeat to add patterns",
    )
    parser.add_argument(
        "--compile-bindings", action="store_true",
        help="compile fbfrog baselines and generated C2FB headers with FreeBASIC",
    )
    parser.add_argument(
        "--compile-body-candidates", action="store_true",
        help="also compile C2FB body candidates together with their generated bindings",
    )
    parser.add_argument(
        "--compare-macro-values", "--compare-literal-macro-values",
        dest="compare_macro_values", action="store_true",
        help="evaluate comparable object-like and function-like integer macros",
    )
    parser.add_argument(
        "--compare-record-layouts", action="store_true",
        help="compare record sizes and addressable field offsets against C",
    )
    parser.add_argument(
        "--fail-on-c2fb-layout-mismatch", action="store_true",
        help=(
            "return failure when a measured C2FB record layout differs from C; "
            "unavailable probes remain reported as skips"
        ),
    )
    parser.add_argument(
        "--report-all-compile-failures", action="store_true",
        help=(
            "report every FBFrog baseline and C2FB compile failure, including "
            "failures on non-compilable baselines"
        ),
    )
    parser.add_argument(
        "--scope", choices=("macros", "declarations"), default="macros",
        help="compare macro names only, or top-level binding and body names",
    )
    parser.add_argument(
        "--strict", action="store_true",
        help="return failure when any expected name is missing or skipped",
    )
    args = parser.parse_args()
    if args.compile_body_candidates and not args.compile_bindings:
        parser.error("--compile-body-candidates requires --compile-bindings")
    if args.compile_body_candidates and args.scope != "declarations":
        parser.error("--compile-body-candidates requires --scope declarations")
    if args.compare_macro_values and not args.compile_bindings:
        parser.error("--compare-macro-values requires --compile-bindings")
    if args.compare_macro_values and args.scope != "macros":
        parser.error("--compare-macro-values requires --scope macros")
    if args.compare_record_layouts and not args.compile_bindings:
        parser.error("--compare-record-layouts requires --compile-bindings")
    if args.compare_record_layouts and args.scope != "declarations":
        parser.error("--compare-record-layouts requires --scope declarations")
    if args.fail_on_c2fb_layout_mismatch and not args.compare_record_layouts:
        parser.error("--fail-on-c2fb-layout-mismatch requires --compare-record-layouts")
    if args.fbc_include_directories and not args.compile_bindings:
        parser.error("--fbc-include-directory requires --compile-bindings")
    if args.fixture_pattern and not any(
        fbfrog_fixture_matches(path.relative_to(args.fbfrog_tests.resolve()).as_posix(), args.fixture_pattern)
        for path in args.fbfrog_tests.resolve().rglob("*.h")
        if path.with_suffix(".bi").is_file()
    ):
        parser.error("--fixture-pattern did not match any paired header/binding fixtures")
    return audit(args)


if __name__ == "__main__":
    sys.exit(main())

# end of audit_fbfrog.py
