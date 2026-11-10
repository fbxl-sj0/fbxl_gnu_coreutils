#!/usr/bin/env python3
"""
Project: SQLite FreeBASIC port tools
File: c2fb_source_unit.py

Purpose:

    Generate body candidates with record layouts declared privately in a C
    implementation file available to the body translator.

    Responsibilities:

    - Build a type-only generic-header binding for the selected C source.
    - Apply shared and per-source compiler options in tree mode.
    - Bound concurrent work while keeping per-file outputs independent.
    - Report completed source units in an optional streaming progress mode.
    - Filter tree inputs by source-relative patterns when requested.
    - Filter indexed FreeBASIC bindings by source-relative patterns when requested.
    - Combine that binding with an optional FreeBASIC source index in a
      temporary overlay.
    - Include unique FreeBASIC implementations that own selected interface
      declarations, even when the implementation filename differs.
    - Translate and publish a C body candidate plus its type context.

This file intentionally does NOT contain:

    - C parsing or FreeBASIC lowering.
    - The C2FB target matrix or compilation database workflows.
"""

import argparse
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
import fnmatch
import json
import os
from collections import Counter
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time


BODY_SOURCE_SUFFIXES = {".bas", ".bi"}
SKIP_DIRECTORY_NAMES = {"build", "out", ".git", "node_modules"}
MAX_SOURCE_TREE_FILES = 32768
MAX_INDEXED_BODY_SOURCE_FILES = 32768
# Bound compiler fan-out so large trees cannot launch unbounded workers.
MAX_SOURCE_TREE_JOBS = 32
SOURCE_UNIT_SUMMARY_RE = re.compile(
    r"translated (\d+) simple functions; skipped (\d+) "
    r"unsupported or duplicate candidates"
)
BODY_DIAGNOSTIC_REASON_RE = re.compile(
    r"^\s*'\s*c2fb body diagnostic \[([^\]\r\n]+)\]",
    re.MULTILINE,
)
FREEBASIC_INCLUDE_RE = re.compile(
    r'^\s*#\s*include(?:\s+once)?\s+"([^"\r\n]+)"', re.IGNORECASE
)
FREEBASIC_PROCEDURE_INTERFACE_RE = re.compile(
    r'^\s*(?:(?:private|public|static)\s+)?(?:declare\s+)?'
    r'(?:function|sub)\s+([A-Za-z_][A-Za-z_0-9]*)\b',
    re.IGNORECASE,
)
FREEBASIC_PROCEDURE_DEFINITION_RE = re.compile(
    r'^\s*(?:(?:private|public|static)\s+)?'
    r'(?:function|sub)\s+([A-Za-z_][A-Za-z_0-9]*)\b',
    re.IGNORECASE,
)
FREEBASIC_PROCEDURE_ALIAS_RE = re.compile(
    r'\balias\s+"([^"\r\n]+)"', re.IGNORECASE
)
UNIT_OPTION_KEYS = (
    "header_options",
    "body_options",
    "header_compiler_options",
    "body_compiler_options",
)
SOURCE_INDEX_PROFILE_KEYS = (
    "fb_source_patterns",
    "fb_source_recursive",
    "fb_source_include_closure",
)
SOURCE_UNIT_PROFILE_KEYS = ("no_forward_declarations",)
MANAGED_BODY_OPTIONS = (
    "--fb-source-directory",
    "--fb-source-dir",
    "--fb-source-recursive",
    "--fb-source-pattern",
    "--fb-source-include-closure",
)
STATIC_OBJECT_BINDING = re.compile(
    r"^' c2fb static-object: ([A-Za-z_][A-Za-z_0-9]*)="
    r"([A-Za-z_][A-Za-z_0-9]*)$",
    re.MULTILINE,
)
STATIC_OBJECT_ARRAY_DECLARATION = re.compile(
    r"^\s*(?:Private\s+)?Dim\s+Shared\s+"
    r"([A-Za-z_][A-Za-z_0-9]*)\s*\(\s*(\d+)\s+To\s+(\d+)\s*\)"
    r"\s+As\s+(.+?)(?:\s*=\s*.*)?\s*$",
    re.IGNORECASE,
)
FREEBASIC_CALLBACK_TYPE = re.compile(
    r"^\s*Type\s+([A-Za-z_][A-Za-z_0-9]*)\s+As\s+(?:Function|Sub)\b",
    re.IGNORECASE | re.MULTILINE,
)
THREAD_LOCAL_OBJECT_SKIP = re.compile(
    r"^' c2fb skipped [^\r\n]*thread-local[^\r\n]*: "
    r"([A-Za-z_][A-Za-z_0-9]*):",
    re.MULTILINE,
)


def resolve_existing_file(value, label):
    path = Path(value)
    try:
        path = path.resolve()
    except (OSError, RuntimeError) as error:
        raise ValueError(f"cannot resolve {label} path {path}: {error}") from error
    if not path.is_file():
        raise ValueError(f"{label} does not exist: {path}")
    return path


def resolve_output_file(value, label):
    path = Path(value)
    try:
        return path.resolve()
    except (OSError, RuntimeError) as error:
        raise ValueError(f"cannot resolve {label} path {path}: {error}") from error


def path_is_within(path, root):
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def normalize_binding_pattern(value, label):
    normalized = value.replace("\\", "/").strip()
    if not normalized or normalized.startswith("/") or \
       re.match(r"^[A-Za-z]:", normalized) is not None or \
       ".." in normalized.split("/"):
        raise ValueError(
            f"{label} must be a non-empty path relative to the indexed "
            "FreeBASIC source directory"
        )
    return normalized


def load_unit_manifest(value):
    if value is None:
        return []
    path = resolve_existing_file(value, "source-unit manifest")
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read source-unit manifest {path}: {error}") from error
    if not isinstance(manifest, dict) or manifest.get("version") != 1:
        raise ValueError("source-unit manifest must be an object with version 1")
    if set(manifest) != {"version", "profiles"}:
        raise ValueError(
            "source-unit manifest accepts only version and profiles fields"
        )
    profiles = manifest["profiles"]
    if not isinstance(profiles, list):
        raise ValueError("source-unit manifest profiles must be a list")

    normalized_profiles = []
    allowed_keys = {
        "pattern", *UNIT_OPTION_KEYS, *SOURCE_INDEX_PROFILE_KEYS,
        *SOURCE_UNIT_PROFILE_KEYS,
    }
    for profile_index, profile in enumerate(profiles):
        label = f"source-unit profile {profile_index}"
        if not isinstance(profile, dict) or "pattern" not in profile:
            raise ValueError(f"{label} must contain a source pattern")
        if set(profile) - allowed_keys:
            raise ValueError(f"{label} contains an unknown field")
        pattern = profile["pattern"]
        if not isinstance(pattern, str) or not pattern.strip():
            raise ValueError(f"{label} pattern must be a non-empty path pattern")
        pattern = pattern.replace("\\", "/").strip()
        if pattern.startswith("/") or ".." in pattern.split("/"):
            raise ValueError(f"{label} pattern must be relative to the source tree")
        normalized = {"pattern": pattern}
        source_patterns = profile.get("fb_source_patterns", [])
        if not isinstance(source_patterns, list) or any(
            not isinstance(item, str) or not item or
            "\0" in item or "\n" in item or "\r" in item
            for item in source_patterns
        ):
            raise ValueError(
                f"{label} fb_source_patterns must be a list of path patterns"
            )
        normalized["fb_source_patterns"] = [
            normalize_binding_pattern(item, f"{label} FreeBASIC source pattern")
            for item in source_patterns
        ]
        for option_key in (
            "fb_source_recursive", "fb_source_include_closure",
        ):
            option_value = profile.get(option_key, False)
            if not isinstance(option_value, bool):
                raise ValueError(f"{label} {option_key} must be true or false")
            normalized[option_key] = option_value
        option_value = profile.get("no_forward_declarations", False)
        if not isinstance(option_value, bool):
            raise ValueError(f"{label} no_forward_declarations must be true or false")
        normalized["no_forward_declarations"] = option_value
        for option_key in UNIT_OPTION_KEYS:
            values = profile.get(option_key, [])
            if not isinstance(values, list) or any(
                not isinstance(item, str) or not item or
                "\0" in item or "\n" in item or "\r" in item
                for item in values
            ):
                raise ValueError(f"{label} {option_key} must be a list of arguments")
            if option_key == "body_options":
                for item in values:
                    if any(
                        item == reserved or item.startswith(reserved + "=")
                        for reserved in MANAGED_BODY_OPTIONS
                    ):
                        raise ValueError(
                            f"{label} cannot set {item}; use the source-unit "
                            "FreeBASIC source-directory options"
                        )
            normalized[option_key] = values
        normalized_profiles.append(normalized)
    return normalized_profiles


def options_for_source_unit(relative_path, profiles):
    source_name = relative_path.as_posix()
    options = {key: [] for key in UNIT_OPTION_KEYS}
    source_index_options = {
        "fb_source_patterns": [],
        "fb_source_recursive": False,
        "fb_source_include_closure": False,
        "no_forward_declarations": False,
    }
    for profile in profiles:
        if not fnmatch.fnmatchcase(source_name, profile["pattern"]):
            continue
        for option_key in UNIT_OPTION_KEYS:
            options[option_key].extend(profile[option_key])
        source_index_options["fb_source_patterns"].extend(
            profile["fb_source_patterns"]
        )
        for option_key in (
            "fb_source_recursive", "fb_source_include_closure",
        ):
            source_index_options[option_key] = (
                source_index_options[option_key] or profile[option_key]
            )
        source_index_options["no_forward_declarations"] = (
            source_index_options["no_forward_declarations"] or
            profile["no_forward_declarations"]
        )
    return options, source_index_options


def resolve_converter(value):
    text = str(value)
    path = Path(text)
    if path.is_absolute() or len(path.parts) > 1:
        return resolve_existing_file(text, "C2FB converter")
    located = shutil.which(text)
    if located is None:
        raise ValueError(f"C2FB converter is not on PATH: {text}")
    return Path(located).resolve()


def command_output(result, output_messages=None):
    if output_messages is not None:
        output_messages.append((result.stdout, result.stderr))
        return result.returncode
    if result.stdout:
        sys.stdout.write(result.stdout)
        sys.stdout.flush()
    if result.stderr:
        sys.stderr.write(result.stderr)
        sys.stderr.flush()
    return result.returncode


def run_converter_phase(command, phase, output_messages, progress_callback):
    started = time.monotonic()
    if progress_callback is not None:
        progress_callback(phase, "started")
    try:
        result = subprocess.run(
            command, capture_output=True, text=True, check=False
        )
    except OSError:
        if progress_callback is not None:
            elapsed = time.monotonic() - started
            progress_callback(phase, f"failed to start after {elapsed:.1f}s")
        raise

    if progress_callback is not None:
        elapsed = time.monotonic() - started
        if result.returncode == 0:
            status = "complete"
        else:
            status = f"failed with exit code {result.returncode}"
        progress_callback(phase, f"{status} after {elapsed:.1f}s")
    return command_output(result, output_messages)


def copy_or_link(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.symlink(source.resolve(), target)
    except (NotImplementedError, OSError):
        shutil.copy2(source, target)


def binding_source_matches(relative_path, patterns):
    if not patterns:
        return True
    relative_name = relative_path.as_posix()
    return any(fnmatch.fnmatchcase(relative_name, pattern) for pattern in patterns)


def indexed_body_source_path(path, base_directory):
    try:
        indexed_path = Path(os.path.abspath(os.fspath(path)))
        resolved = indexed_path.resolve(strict=True)
        relative = indexed_path.relative_to(base_directory)
        resolved_relative = resolved.relative_to(base_directory)
    except (OSError, RuntimeError, ValueError):
        return None
    if not resolved.is_file() or indexed_path.suffix.lower() not in BODY_SOURCE_SUFFIXES:
        return None
    if any(part in SKIP_DIRECTORY_NAMES for part in relative.parts) or \
       any(part in SKIP_DIRECTORY_NAMES for part in resolved_relative.parts):
        return None
    return indexed_path


def freebasic_include_dependencies(source, base_directory):
    try:
        source_text = source.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        raise ValueError(
            f"cannot read indexed FreeBASIC source {source}: {error}"
        ) from error

    dependencies = []
    for line in source_text.splitlines():
        match = FREEBASIC_INCLUDE_RE.match(line)
        if match is None:
            continue
        include_path = Path(match.group(1))
        if include_path.is_absolute():
            candidates = (include_path,)
        else:
            candidates = (source.parent / include_path, base_directory / include_path)
        for candidate in candidates:
            dependency = indexed_body_source_path(candidate, base_directory)
            if dependency is not None:
                dependencies.append(dependency)
                break
    return dependencies


def freebasic_module_body(interface, base_directory):
    """Return the matching implementation when an interface owns one."""
    if interface.suffix.casefold() != ".bi":
        return None
    implementation = indexed_body_source_path(
        interface.with_suffix(".bas"), base_directory
    )
    if implementation is None:
        return None
    if interface not in freebasic_include_dependencies(
        implementation, base_directory
    ):
        return None
    return implementation


def freebasic_procedure_names(source, definitions_only):
    """Read procedure names and aliases from interface or implementation lines."""
    pattern = (
        FREEBASIC_PROCEDURE_DEFINITION_RE if definitions_only
        else FREEBASIC_PROCEDURE_INTERFACE_RE
    )
    try:
        lines = source.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as error:
        raise ValueError(
            f"cannot read indexed FreeBASIC source {source}: {error}"
        ) from error

    names = set()
    for line in lines:
        match = pattern.match(line)
        if match is None:
            continue
        names.add(match.group(1).casefold())
        alias = FREEBASIC_PROCEDURE_ALIAS_RE.search(line)
        if alias is not None:
            names.add(alias.group(1).casefold())
    return names


def freebasic_procedure_owners(body_sources, base_directory):
    """Map interface declarations to unique implementations that include them."""
    owners = {}
    name_cache = {}
    include_cache = {}

    def procedure_names(source, definitions_only):
        cache_key = (source, definitions_only)
        if cache_key not in name_cache:
            name_cache[cache_key] = freebasic_procedure_names(
                source, definitions_only
            )
        return name_cache[cache_key]

    def included_sources(source):
        if source not in include_cache:
            include_cache[source] = freebasic_include_dependencies(
                source, base_directory
            )
        return include_cache[source]

    for source in body_sources:
        definitions = procedure_names(source, definitions_only=True)
        if not definitions:
            continue

        pending = [source]
        visited = {source}
        while pending:
            included_source = pending.pop()
            for dependency in included_sources(included_source):
                if dependency in visited:
                    continue
                visited.add(dependency)
                pending.append(dependency)
                if dependency.suffix.casefold() != ".bi":
                    continue
                for name in definitions & procedure_names(
                    dependency, definitions_only=False
                ):
                    owners.setdefault(name, set()).add(source)
    return {
        name: next(iter(source_paths))
        for name, source_paths in owners.items()
        if len(source_paths) == 1
    }


def collect_binding_sources(base_directory, recursive, patterns=(), include_closure=False):
    if base_directory is None:
        return (), 0, 0

    base_directory = Path(base_directory).resolve()
    iterator = (
        base_directory.rglob("*")
        if recursive or include_closure else base_directory.iterdir()
    )
    selected = {}
    body_sources = []
    pattern_match_count = 0
    for source in iterator:
        indexed_source = indexed_body_source_path(source, base_directory)
        if indexed_source is None:
            continue
        if indexed_source.suffix.lower() == ".bas":
            body_sources.append(indexed_source)
            if len(body_sources) > MAX_INDEXED_BODY_SOURCE_FILES:
                raise ValueError(
                    "FreeBASIC procedure-owner index exceeds the configured "
                    f"source limit of {MAX_INDEXED_BODY_SOURCE_FILES}"
                )
        relative = indexed_source.relative_to(base_directory)
        if not binding_source_matches(relative, patterns):
            continue
        selected[relative.as_posix()] = indexed_source
        pattern_match_count += 1
        if len(selected) > MAX_INDEXED_BODY_SOURCE_FILES:
            raise ValueError(
                "indexed FreeBASIC sources exceed the configured source limit "
                f"of {MAX_INDEXED_BODY_SOURCE_FILES}"
            )

    if patterns and pattern_match_count == 0:
        raise ValueError(
            "--fb-source-pattern did not match any indexed .bas or .bi files"
        )

    initial_count = len(selected)
    if include_closure:
        procedure_owners = freebasic_procedure_owners(
            body_sources, base_directory
        )
        pending = list(selected.values())
        visited = set(selected.values())
        while pending:
            source = pending.pop()
            dependencies = freebasic_include_dependencies(source, base_directory)
            module_body = freebasic_module_body(source, base_directory)
            if module_body is not None:
                dependencies.append(module_body)
            if source.suffix.casefold() == ".bi":
                for procedure_name in freebasic_procedure_names(
                    source, definitions_only=False
                ):
                    owner = procedure_owners.get(procedure_name)
                    if owner is not None:
                        dependencies.append(owner)
            for dependency in dependencies:
                if dependency in visited:
                    continue
                visited.add(dependency)
                relative = dependency.relative_to(base_directory)
                selected[relative.as_posix()] = dependency
                pending.append(dependency)
                if len(selected) > MAX_INDEXED_BODY_SOURCE_FILES:
                    raise ValueError(
                        "FreeBASIC include closure exceeds the configured source limit "
                        f"of {MAX_INDEXED_BODY_SOURCE_FILES}"
                    )

    ordered_sources = tuple(selected[name] for name in sorted(selected))
    return ordered_sources, initial_count, len(ordered_sources) - initial_count


def stage_binding_sources(base_directory, overlay_directory,
                          local_type_context, recursive, patterns=(),
                          include_closure=False,
                          include_local_type_context=True):
    overlay_directory.mkdir(parents=True, exist_ok=True)
    selected_sources, selected_count, dependency_count = collect_binding_sources(
        base_directory, recursive, patterns, include_closure
    )
    if base_directory is not None:
        base_directory = Path(base_directory).resolve()
        for source in selected_sources:
            relative = source.relative_to(base_directory)
            if source.name == local_type_context.name:
                raise ValueError(
                    "local type-context filename conflicts with an existing "
                    f"FreeBASIC source: {source}"
                )
            copy_or_link(source, overlay_directory / relative)

    if include_local_type_context:
        local_target = overlay_directory / local_type_context.name
        if local_target.exists():
            raise ValueError(
                f"local type-context filename conflicts in the source overlay: "
                f"{local_target.name}"
            )
        copy_or_link(local_type_context, local_target)
    return selected_count, dependency_count


def ensure_type_context_include(candidate_path, type_context_name):
    source = candidate_path.read_text(encoding="utf-8", errors="replace")
    include_line = f'#include once "{type_context_name}"'
    if include_line in source:
        return

    lines = source.splitlines(keepends=True)
    include_positions = [
        index for index, line in enumerate(lines)
        if line.lstrip().startswith("#include once ")
    ]
    if include_positions:
        include_position = include_positions[-1] + 1
    else:
        comment_end = next(
            (
                index for index, line in enumerate(lines)
                if line.strip() == "'/"
            ),
            -1,
        )
        include_position = comment_end + 1
    lines.insert(include_position, include_line + "\n")
    candidate_path.write_text("".join(lines), encoding="utf-8")


def ensure_crt_stdio_include(candidate_path):
    """Resolve mapped C fpos_t through FreeBASIC's CRT ABI declaration."""
    source = candidate_path.read_text(encoding="utf-8", errors="replace")
    include_line = '#include once "crt/stdio.bi"'
    if re.search(r"\bfpos_t\b", source) is None or include_line in source:
        return

    lines = source.splitlines(keepends=True)
    include_positions = [
        index for index, line in enumerate(lines)
        if line.lstrip().startswith("#include once ")
    ]
    if include_positions:
        include_position = max(include_positions) + 1
    else:
        include_position = 0
    lines.insert(include_position, include_line + "\n")
    candidate_path.write_text("".join(lines), encoding="utf-8")


def move_callback_static_objects_to_body(type_context_path):
    """Move private callback tables to bodies that define their callbacks.

    A type-context initializer is compiled before the body module's Declare
    statements. Callback addresses therefore cannot refer to private functions
    defined by that body. Keep the callback typedef in the type context, and
    let the body emitter place the table after its forward declarations.
    """
    source = type_context_path.read_text(encoding="utf-8", errors="replace")
    callback_types = {
        name.lower() for name in FREEBASIC_CALLBACK_TYPE.findall(source)
    }
    if not callback_types:
        return ()

    lines = source.splitlines(keepends=True)
    removed_lines = set()
    moved_names = []
    for marker_index, line in enumerate(lines):
        marker = STATIC_OBJECT_BINDING.match(line.rstrip("\r\n"))
        if marker is None:
            continue
        source_name, freebasic_name = marker.groups()
        declaration_index = None
        declaration_type = None
        is_direct_callback = False
        for candidate_index in range(marker_index + 1, len(lines)):
            candidate_line = lines[candidate_index].strip()
            if not candidate_line or candidate_line.startswith("'"):
                continue
            declaration_prefix = re.compile(
                r"^(?:Private\s+)?Dim\s+Shared\s+"
                + re.escape(freebasic_name)
                + r"(?:\s*\(|\s)"
            )
            if declaration_prefix.match(candidate_line) is None:
                break
            is_direct_callback = re.search(
                r"\bAs\s+(?:Const\s+)?(?:Function|Sub)\b",
                candidate_line,
                re.IGNORECASE,
            ) is not None
            type_match = re.search(
                r"\bAs\s+(?:Const\s+)?([A-Za-z_][A-Za-z_0-9]*)\b",
                candidate_line,
                re.IGNORECASE,
            )
            if type_match is not None:
                declaration_index = candidate_index
                declaration_type = type_match.group(1).lower()
            break

        if declaration_index is None or not (
                is_direct_callback or declaration_type in callback_types):
            continue

        removed_lines.add(marker_index)
        removed_lines.add(declaration_index)
        for candidate_index, candidate_line in enumerate(lines):
            if candidate_index == marker_index:
                continue
            if ("c2fb skipped unsupported module-static initializer" in candidate_line
                    and source_name in candidate_line):
                removed_lines.add(candidate_index)
        moved_names.append(source_name)

    if removed_lines:
        type_context_path.write_text(
            "".join(line for index, line in enumerate(lines)
                    if index not in removed_lines),
            encoding="utf-8",
        )
    return tuple(moved_names)


def static_object_bindings(type_context_path):
    source = type_context_path.read_text(encoding="utf-8", errors="replace")
    lines = source.splitlines()
    bindings = {}
    for line_index, line in enumerate(lines):
        marker = STATIC_OBJECT_BINDING.match(line)
        if marker is None:
            continue
        source_name, freebasic_name = marker.groups()
        previous = bindings.get(source_name)
        if previous is not None and previous[0] != freebasic_name:
            raise ValueError(
                "local type context maps one C static object to multiple "
                f"FreeBASIC names: {source_name}"
            )
        freebasic_type = ""
        array_count = 0
        for declaration_line in lines[line_index + 1:]:
            if STATIC_OBJECT_BINDING.match(declaration_line):
                break
            declaration = STATIC_OBJECT_ARRAY_DECLARATION.match(
                declaration_line
            )
            if declaration is None:
                continue
            declared_name, lower_bound, upper_bound, declared_type = (
                declaration.groups()
            )
            if declared_name != freebasic_name or int(lower_bound) != 0:
                continue
            array_count = int(upper_bound) + 1
            freebasic_type = declared_type.strip()
            break
        bindings[source_name] = (
            freebasic_name, freebasic_type, array_count
        )
    return tuple(
        (source_name, *binding)
        for source_name, binding in sorted(bindings.items())
    )


def unsupported_thread_local_objects(type_context_path):
    source = type_context_path.read_text(encoding="utf-8", errors="replace")
    return tuple(sorted(set(THREAD_LOCAL_OBJECT_SKIP.findall(source))))


def run_source_unit(
    arguments, output_messages=None, progress_callback=None
):
    source = resolve_existing_file(arguments.source, "C source")
    converter = resolve_converter(arguments.converter)
    candidate = resolve_output_file(arguments.candidate, "candidate output")
    type_context = resolve_output_file(
        arguments.type_context
        if arguments.type_context
        else candidate.with_name(candidate.stem + "_types.bi"),
        "local type-context output",
    )

    if candidate == source or type_context == source:
        raise ValueError("generated outputs must not overwrite the C input")
    if candidate == type_context:
        raise ValueError("candidate and local type-context outputs must differ")
    if candidate.parent != type_context.parent:
        raise ValueError(
            "candidate and local type-context outputs must share a directory"
        )

    base_directory = None
    if arguments.fb_source_directory:
        base_directory = Path(arguments.fb_source_directory).resolve()
        if not base_directory.is_dir():
            raise ValueError(
                f"FreeBASIC source directory does not exist: {base_directory}"
            )
        for output_path in (candidate, type_context):
            try:
                output_path.relative_to(base_directory)
            except ValueError:
                continue
            raise ValueError(
                "generated outputs must be outside the indexed FreeBASIC "
                f"source directory: {base_directory}"
            )

    candidate.parent.mkdir(parents=True, exist_ok=True)
    source_pattern = arguments.emit_source_pattern or str(source)
    type_context_name = type_context.name

    try:
        with tempfile.TemporaryDirectory(
            prefix=".c2fb-source-unit-", dir=candidate.parent
        ) as temporary:
            staging = Path(temporary)
            staged_type_context = staging / type_context_name
            staged_candidate = staging / candidate.name
            overlay = staging / "fb-source"

            header_command = [
                str(converter),
                "generic-header",
                str(source),
                str(staged_type_context),
                *arguments.header_options,
                "--exclude=*",
                "--exclude-proc=*",
                "--preserve-type-dependencies",
            ]
            # Included C bodies can refer to file-static objects that do not
            # belong to the root source's body index. Keep their private
            # storage in the shared type context; reuse bindings prevent the
            # body pass from emitting duplicate objects.
            include_static_objects_in_header = (
                "--include-global-definitions" not in arguments.body_options
                or "--include-included-c-source-bodies" in arguments.body_options
            )
            if include_static_objects_in_header:
                header_command.extend([
                    "--include-static-objects",
                    "--private-static-objects",
                ])
            header_command.append("--emit-source=" + source_pattern)
            if not arguments.no_forward_declarations:
                # Keep pointer fields in selected records valid when their
                # tags are completed in a filtered or unselected header.
                header_command.append("--forward-decl=*")
            header_command.extend([
                arguments.compiler,
                *arguments.header_compiler_options,
            ])
            if arguments.include_header_types:
                # Body candidates can access records defined by included
                # headers. The default source filter keeps unrelated header
                # declarations out, so opt in to their type layouts only.
                # Keep procedure prototypes out of the local type context so
                # they cannot collide with generated procedure definitions.
                header_command.extend([
                    "--exclude-proc=*",
                    "--emit-source=*",
                ])
            header_return_code = run_converter_phase(
                header_command, "generic-header", output_messages,
                progress_callback,
            )
            if header_return_code != 0:
                return header_return_code
            if not staged_type_context.is_file() or \
               staged_type_context.stat().st_size == 0:
                raise ValueError("C2FB produced no local type context")
            if ("--include-global-definitions" in arguments.body_options and
                    "--include-included-c-source-bodies" in arguments.body_options):
                moved_callback_objects = move_callback_static_objects_to_body(
                    staged_type_context
                )
                if moved_callback_objects:
                    message = (
                        "c2fb source unit: moved private callback tables to body: "
                        + ", ".join(moved_callback_objects)
                        + "\n"
                    )
                    if output_messages is None:
                        sys.stdout.write(message)
                        sys.stdout.flush()
                    else:
                        output_messages.append((message, ""))
            object_bindings = static_object_bindings(staged_type_context)
            unsupported_thread_locals = unsupported_thread_local_objects(
                staged_type_context
            )
            if unsupported_thread_locals:
                message = (
                    "c2fb source unit: unsupported thread-local C objects: "
                    + ", ".join(unsupported_thread_locals)
                    + "\n"
                )
                if output_messages is None:
                    sys.stdout.write(message)
                    sys.stdout.flush()
                else:
                    output_messages.append((message, ""))

            selected_source_count, dependency_source_count = stage_binding_sources(
                base_directory, overlay, staged_type_context,
                arguments.fb_source_recursive,
                arguments.fb_source_patterns,
                arguments.fb_source_include_closure,
                include_local_type_context=True,
            )
            if arguments.fb_source_include_closure:
                message = (
                    "c2fb source unit: indexed "
                    f"{selected_source_count} selected and "
                    f"{dependency_source_count} included FreeBASIC source files\n"
                )
                if output_messages is None:
                    sys.stdout.write(message)
                    sys.stdout.flush()
                else:
                    output_messages.append((message, ""))
            body_command = [
                str(converter),
                "translate-simple-generic-c",
                str(source),
                str(staged_candidate),
                *arguments.body_options,
                *(
                    "--reuse-static-object=" + source_name + "=" + freebasic_name
                    for source_name, freebasic_name, _, _ in object_bindings
                ),
                *(
                    "--reuse-static-object-layout=" + source_name + "=" +
                    freebasic_type + "," + str(array_count)
                    for source_name, _, freebasic_type, array_count in object_bindings
                    if freebasic_type and array_count > 0
                ),
                arguments.compiler,
                *arguments.body_compiler_options,
                "--fb-source-directory=" + str(overlay),
            ]
            if arguments.fb_source_recursive or arguments.fb_source_include_closure:
                body_command.append("--fb-source-recursive")
            body_return_code = run_converter_phase(
                body_command, "body", output_messages, progress_callback
            )
            if body_return_code != 0:
                return body_return_code
            if not staged_candidate.is_file() or staged_candidate.stat().st_size == 0:
                raise ValueError("C2FB produced no body candidate")
            ensure_type_context_include(staged_candidate, type_context_name)
            ensure_crt_stdio_include(staged_candidate)

            backup_type_context = staging / "previous-type-context"
            type_context_was_present = (
                type_context.exists() or type_context.is_symlink()
            )
            if type_context_was_present:
                shutil.copy2(
                    type_context, backup_type_context, follow_symlinks=False
                )

            type_context_published = False
            try:
                os.replace(staged_type_context, type_context)
                type_context_published = True
                os.replace(staged_candidate, candidate)
            except OSError:
                if type_context_published:
                    if type_context_was_present:
                        os.replace(backup_type_context, type_context)
                    elif type_context.exists() or type_context.is_symlink():
                        type_context.unlink()
                raise
    except OSError as error:
        raise ValueError(f"cannot stage C2FB source-unit outputs: {error}") from error

    if output_messages is None:
        print(f"c2fb source unit: wrote {type_context}")
        print(f"c2fb source unit: wrote {candidate}")
    else:
        output_messages.append((
            f"c2fb source unit: wrote {type_context}\n"
            f"c2fb source unit: wrote {candidate}\n",
            "",
        ))
    return 0


def run_source_tree(arguments):
    source_directory = Path(arguments.source).resolve()
    output_directory = resolve_output_file(arguments.candidate, "candidate directory")
    report_path = None
    if arguments.report_json is not None:
        report_path = resolve_output_file(arguments.report_json, "JSON report")
    if not source_directory.is_dir():
        raise ValueError(f"C source directory does not exist: {source_directory}")
    source_patterns = []
    for pattern in arguments.source_patterns:
        normalized = pattern.replace("\\", "/").strip()
        if not normalized or normalized.startswith("/") or \
           re.match(r"^[A-Za-z]:", normalized) is not None or \
           ".." in normalized.split("/"):
            raise ValueError(
                "source patterns must be non-empty paths relative to the source tree"
            )
        source_patterns.append(normalized)
    unit_profiles = load_unit_manifest(arguments.unit_manifest)
    if path_is_within(output_directory, source_directory) or \
       path_is_within(source_directory, output_directory):
        raise ValueError(
            "candidate and source directories must not overlap"
        )
    if report_path is not None and path_is_within(report_path, source_directory):
        raise ValueError("JSON report must be outside the C source directory")
    if report_path == output_directory:
        raise ValueError("JSON report path must name a file outside the candidate directory")

    base_directory = None
    if arguments.fb_source_directory:
        base_directory = Path(arguments.fb_source_directory).resolve()
        if not base_directory.is_dir():
            raise ValueError(
                f"FreeBASIC source directory does not exist: {base_directory}"
            )
        if path_is_within(output_directory, base_directory):
            raise ValueError(
                "candidate directory must be outside the indexed FreeBASIC "
                f"source directory: {base_directory}"
            )
        if report_path is not None and path_is_within(report_path, base_directory):
            raise ValueError(
                "JSON report must be outside the indexed FreeBASIC source "
                f"directory: {base_directory}"
            )

    source_files = []
    for source in source_directory.rglob("*.c"):
        relative = source.relative_to(source_directory)
        if any(part in SKIP_DIRECTORY_NAMES for part in relative.parts):
            continue
        if source_patterns and not any(
            fnmatch.fnmatchcase(relative.as_posix(), pattern)
            for pattern in source_patterns
        ):
            continue
        if source.is_file():
            source_files.append(source)
    source_files.sort()
    if not source_files:
        if source_patterns:
            raise ValueError(
                "no C sources matched the selected source patterns in "
                f"{source_directory}: {', '.join(source_patterns)}"
            )
        raise ValueError(f"no C source files found in {source_directory}")
    if len(source_files) > MAX_SOURCE_TREE_FILES:
        raise ValueError(
            f"source tree contains more than {MAX_SOURCE_TREE_FILES} C files"
        )

    has_source_index_profile = False
    for source in source_files:
        _, source_options = options_for_source_unit(
            source.relative_to(source_directory), unit_profiles
        )
        if source_options["fb_source_patterns"] or \
           source_options["fb_source_recursive"] or \
           source_options["fb_source_include_closure"]:
            has_source_index_profile = True
            break
    if has_source_index_profile and not arguments.fb_source_directory:
        raise ValueError(
            "selected source-unit profile options require "
            "--fb-source-directory"
        )

    output_paths = set()
    for source in source_files:
        relative = source.relative_to(source_directory)
        candidate = (
            output_directory / relative.parent /
            f"{relative.stem}_candidates.bas"
        ).resolve()
        type_context = candidate.with_name(
            candidate.stem + "_types.bi"
        )
        if candidate in output_paths or type_context in output_paths:
            raise ValueError(f"multiple C sources map to candidate {candidate}")
        output_paths.add(candidate)
        output_paths.add(type_context)
    if report_path is not None and report_path in output_paths:
        raise ValueError("JSON report path conflicts with a source-unit output")

    output_directory.mkdir(parents=True, exist_ok=True)
    progress_lock = threading.Lock()

    def process_source(source):
        relative = source.relative_to(source_directory)
        candidate = (
            output_directory / relative.parent /
            f"{relative.stem}_candidates.bas"
        )
        unit_arguments = argparse.Namespace(**vars(arguments))
        unit_arguments.source = source
        unit_arguments.candidate = candidate
        unit_arguments.type_context = None
        profile_options, profile_source_index_options = options_for_source_unit(
            relative, unit_profiles
        )
        for option_key in UNIT_OPTION_KEYS:
            setattr(
                unit_arguments, option_key,
                [*getattr(arguments, option_key), *profile_options[option_key]],
            )
        unit_arguments.fb_source_patterns = [
            *arguments.fb_source_patterns,
            *profile_source_index_options["fb_source_patterns"],
        ]
        unit_arguments.fb_source_recursive = (
            arguments.fb_source_recursive or
            profile_source_index_options["fb_source_recursive"]
        )
        unit_arguments.fb_source_include_closure = (
            arguments.fb_source_include_closure or
            profile_source_index_options["fb_source_include_closure"]
        )
        unit_arguments.no_forward_declarations = (
            arguments.no_forward_declarations or
            profile_source_index_options["no_forward_declarations"]
        )
        output_messages = []
        progress_callback = None
        if arguments.progress:
            def report_phase(phase, status):
                with progress_lock:
                    sys.stderr.write(
                        "c2fb source tree: "
                        f"{relative.as_posix()}: {phase} {status}\n"
                    )
                    sys.stderr.flush()

            progress_callback = report_phase
        try:
            result = run_source_unit(
                unit_arguments, output_messages, progress_callback
            )
        except (OSError, ValueError) as error:
            output_messages.append((
                "",
                f"c2fb source unit: {relative}: {error}\n",
            ))
            result = 1
        return relative, result, output_messages

    unit_reports = {}
    body_diagnostic_counts = Counter()

    def report_result(result):
        nonlocal failures, translated_function_count, skipped_candidate_count
        nonlocal progress_completed
        relative, return_code, output_messages = result
        translated_count = 0
        skipped_count = 0
        error_messages = []
        for output_text, error_text in output_messages:
            for match in SOURCE_UNIT_SUMMARY_RE.finditer(output_text):
                translated_count += int(match.group(1))
                skipped_count += int(match.group(2))
            if error_text.strip():
                error_messages.append(error_text.strip())
        candidate_relative = relative.with_name(
            relative.stem + "_candidates.bas"
        )
        candidate_path = output_directory / candidate_relative
        unit_body_diagnostic_counts = Counter()
        if return_code == 0 and candidate_path.is_file():
            candidate_text = candidate_path.read_text(
                encoding="utf-8", errors="replace"
            )
            unit_body_diagnostic_counts.update(
                BODY_DIAGNOSTIC_REASON_RE.findall(candidate_text)
            )
        body_diagnostic_counts.update(unit_body_diagnostic_counts)
        type_context_relative = relative.with_name(
            relative.stem + "_candidates_types.bi"
        )
        unit_report = {
            "source": relative.as_posix(),
            "candidate": candidate_relative.as_posix(),
            "type_context": type_context_relative.as_posix(),
            "status": "generated" if return_code == 0 else "failed",
            "return_code": return_code,
            "translated_simple_functions": translated_count,
            "unsupported_or_duplicate_candidates": skipped_count,
            "body_diagnostic_counts": dict(
                sorted(unit_body_diagnostic_counts.items())
            ),
        }
        if error_messages:
            unit_report["errors"] = error_messages
        unit_reports[relative.as_posix()] = unit_report
        translated_function_count += translated_count
        skipped_candidate_count += skipped_count
        if arguments.progress:
            progress_completed += 1
            status = "complete" if return_code == 0 else "failed"
            sys.stderr.write(
                f"c2fb source tree: {progress_completed}/"
                f"{len(source_files)} {status}: {relative.as_posix()}\n"
            )
        for output_text, error_text in output_messages:
            if output_text:
                sys.stdout.write(output_text)
            if error_text:
                sys.stderr.write(error_text)
        sys.stdout.flush()
        sys.stderr.flush()
        if return_code != 0:
            failures += 1

    failures = 0
    translated_function_count = 0
    skipped_candidate_count = 0
    progress_completed = 0
    jobs = min(arguments.jobs, len(source_files))
    if arguments.progress:
        sys.stderr.write(
            f"c2fb source tree: starting {len(source_files)} C files; "
            f"jobs {jobs}\n"
        )
        sys.stderr.flush()

    if jobs == 1:
        for source in source_files:
            report_result(process_source(source))
    else:
        with ThreadPoolExecutor(max_workers=jobs) as executor:
            if arguments.progress:
                pending = {}
                next_source = 0
                while next_source < min(jobs, len(source_files)):
                    future = executor.submit(
                        process_source, source_files[next_source])
                    pending[future] = next_source
                    next_source += 1

                while pending:
                    completed, _ = wait(
                        pending, return_when=FIRST_COMPLETED)
                    for future in sorted(completed, key=pending.get):
                        result = future.result()
                        del pending[future]
                        report_result(result)
                        if next_source < len(source_files):
                            next_future = executor.submit(
                                process_source, source_files[next_source])
                            pending[next_future] = next_source
                            next_source += 1
            else:
                for offset in range(0, len(source_files), jobs):
                    batch = source_files[offset:offset + jobs]
                    for result in executor.map(process_source, batch):
                        report_result(result)

    if report_path is not None:
        ordered_units = [
            unit_reports[source.relative_to(source_directory).as_posix()]
            for source in source_files
        ]
        generated_count = sum(
            unit["status"] == "generated" for unit in ordered_units
        )
        units_with_translations = sum(
            unit["translated_simple_functions"] > 0 for unit in ordered_units
        )
        report = {
            "version": 1,
            "totals": {
                "source_files": len(source_files),
                "generated_candidate_files": generated_count,
                "failed_source_files": failures,
                "files_with_translated_functions": units_with_translations,
                "translated_simple_functions": translated_function_count,
                "unsupported_or_duplicate_candidates": skipped_candidate_count,
                "body_diagnostic_counts": dict(
                    sorted(body_diagnostic_counts.items())
                ),
            },
            "units": ordered_units,
        }
        report_path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{report_path.name}.", suffix=".tmp",
            dir=report_path.parent,
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
                json.dump(report, stream, indent=2, ensure_ascii=False)
                stream.write("\n")
            os.replace(temporary_name, report_path)
        except BaseException:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass
            raise
        print(f"c2fb source tree: wrote JSON report {report_path}")

    if body_diagnostic_counts:
        ranked_diagnostics = sorted(
            body_diagnostic_counts.items(),
            key=lambda item: (-item[1], item[0]),
        )
        diagnostic_summary = ", ".join(
            f"{reason}={count}" for reason, count in ranked_diagnostics
        )
        print(f"c2fb source tree: body diagnostic reasons: {diagnostic_summary}")

    print(
        f"c2fb source tree: processed {len(source_files)} C files; "
        f"failed {failures}; totals: {translated_function_count} translated "
        f"simple functions; {skipped_candidate_count} unsupported or duplicate "
        f"candidates skipped; jobs {jobs}"
    )
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--converter", required=True)
    parser.add_argument("--compiler", default="cc")
    parser.add_argument(
        "--tree", action="store_true",
        help="convert each .c file under source into a separate candidate",
    )
    parser.add_argument(
        "--source-pattern", dest="source_patterns", action="append", default=[],
        help="with --tree, select source-relative paths matching this pattern; repeat to add patterns",
    )
    parser.add_argument(
        "--jobs", type=int, default=1,
        help=(
            "with --tree, run this many independent C source units concurrently "
            f"(1-{MAX_SOURCE_TREE_JOBS}; default: 1)"
        ),
    )
    parser.add_argument(
        "--progress", action="store_true",
        help=(
            "with --tree, report converter phases and completed source units "
            "on stderr as work finishes"
        ),
    )
    parser.add_argument(
        "--report-json", type=Path,
        help=(
            "with --tree, write per-source candidate counts, body diagnostic "
            "histograms, and failures as a versioned JSON report"
        ),
    )
    parser.add_argument("--fb-source-directory")
    parser.add_argument(
        "--no-forward-declarations", action="store_true",
        help=(
            "omit the default --forward-decl=* request from the local type "
            "context; use --header-option=--forward-decl=Pattern when only "
            "specific incomplete tags are needed"
        ),
    )
    parser.add_argument("--fb-source-recursive", action="store_true")
    parser.add_argument(
        "--fb-source-pattern", dest="fb_source_patterns", action="append",
        default=[], metavar="GLOB",
        help=(
            "with --fb-source-directory, index only matching .bas/.bi paths "
            "relative to that directory; repeat to add patterns"
        ),
    )
    parser.add_argument(
        "--fb-source-include-closure", action="store_true",
        help="index local .bas/.bi files included transitively by selected sources",
    )
    parser.add_argument(
        "--unit-manifest", type=Path,
        help="JSON per-C-file options used with --tree",
    )
    parser.add_argument("--type-context", type=Path)
    parser.add_argument("--emit-source-pattern")
    parser.add_argument(
        "--include-header-types", action="store_true",
        help=(
            "include record, typedef, and enum definitions from all headers "
            "in the type-only context"
        ),
    )
    parser.add_argument(
        "--header-option", dest="header_options", action="append", default=[]
    )
    parser.add_argument(
        "--body-option", dest="body_options", action="append", default=[]
    )
    parser.add_argument(
        "--header-compiler-option", dest="header_compiler_options",
        action="append", default=[],
    )
    parser.add_argument(
        "--body-compiler-option", dest="body_compiler_options",
        action="append", default=[],
    )
    arguments = parser.parse_args()

    for option in arguments.body_options:
        if any(
            option == reserved or option.startswith(reserved + "=")
            for reserved in MANAGED_BODY_OPTIONS
        ):
            parser.error(
                f"{option} is managed by c2fb_source_unit.py; use its "
                "FreeBASIC source-directory options"
            )
    if arguments.source_patterns and not arguments.tree:
        parser.error("--source-pattern requires --tree")
    if arguments.progress and not arguments.tree:
        parser.error("--progress requires --tree")
    if arguments.report_json is not None and not arguments.tree:
        parser.error("--report-json requires --tree")
    if arguments.jobs < 1 or arguments.jobs > MAX_SOURCE_TREE_JOBS:
        parser.error(f"--jobs must be between 1 and {MAX_SOURCE_TREE_JOBS}")
    if arguments.jobs != 1 and not arguments.tree:
        parser.error("--jobs greater than 1 requires --tree")
    if arguments.fb_source_patterns and not arguments.fb_source_directory:
        parser.error("--fb-source-pattern requires --fb-source-directory")
    if arguments.fb_source_include_closure and not arguments.fb_source_directory:
        parser.error("--fb-source-include-closure requires --fb-source-directory")
    try:
        arguments.fb_source_patterns = [
            normalize_binding_pattern(pattern, "--fb-source-pattern")
            for pattern in arguments.fb_source_patterns
        ]
    except ValueError as error:
        parser.error(str(error))
    try:
        if arguments.tree:
            if arguments.type_context is not None:
                parser.error("--type-context is not available with --tree")
            return run_source_tree(arguments)
        if arguments.unit_manifest is not None:
            parser.error("--unit-manifest requires --tree")
        return run_source_unit(arguments)
    except ValueError as error:
        print(f"c2fb source unit: {error}", file=sys.stderr)
        return 2
    except OSError as error:
        print(f"c2fb source unit: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())


# end of c2fb_source_unit.py
