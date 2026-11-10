#!/usr/bin/env python3
"""
Project: GNU Coreutils FreeBASIC port
File: link_fbc_command_set.py
Purpose: Link the configured Coreutils command set against the refreshed archive.
Responsibilities: Match Makefile object lists to current audited FreeBASIC
candidates, localize translated symbols whose C definitions are object-local,
preserve configured helper libraries, and record every link result.
This file intentionally does NOT contain: C translation or upstream test logic.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys


PORT = Path(__file__).resolve().parents[1]
REFERENCE = PORT / "build/reference"
OBJECT_DIRECTORY = PORT / "build/objects-context"
SUPPORT_ARCHIVE = PORT / "build/fbc-support-library/libcoreutils.a"
OUTPUT_DIRECTORY = (
    PORT / "build/hybrid-current-audit-candidates-104-no-project-c-archives"
)
LINK_LOG = (
    PORT / "logs/coreutils-current-audit-candidates-104-no-project-c-archives-link-20261031.log"
)
CURRENT_EXTRA_SOURCES_BY_PROGRAM = {
    "wc": ("src/wc_avx2.c", "src/wc_avx512.c"),
    "cksum": (
        "src/cksum_avx2.c",
        "src/cksum_avx512.c",
        "src/cksum_pclmul.c",
    ),
}
def current_version_object():
    candidates = sorted((PORT / "generated-context").glob(
        "version_*_candidates.bas"))
    if len(candidates) != 1:
        raise RuntimeError(
            f"expected one current version candidate, found {len(candidates)}"
        )
    return OBJECT_DIRECTORY / (candidates[0].stem + ".o")


def current_command_object(program, object_stem):
    if program != "[" or object_stem != "test-lbracket":
        return None
    candidates = sorted(OBJECT_DIRECTORY.glob(
        "test-lbracket_*_candidates.o"))
    if len(candidates) != 1:
        raise RuntimeError(
            f"expected one current test-lbracket object, found {len(candidates)}"
        )
    return candidates[0]


def make_target_name(program):
    if program == "[":
        return "_"
    return program


def makefile_variables(path):
    logical_lines = []
    continuation = ""
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if continuation:
            line = continuation + line.lstrip()
            continuation = ""
        if line.rstrip().endswith("\\"):
            continuation = line.rstrip()[:-1] + " "
        else:
            logical_lines.append(line)

    variables = {}
    assignment = re.compile(r"^([A-Za-z0-9_]+)\s*([:+?]?=)\s*(.*)$")
    for line in logical_lines:
        if not line or line.startswith("#"):
            continue
        match = assignment.match(line)
        if match is None:
            continue
        name, operator, value = match.groups()
        if operator == "+=":
            variables[name] = (variables.get(name, "") + " " + value).strip()
        elif operator == "?=" and name in variables:
            continue
        else:
            variables[name] = value
    return variables


def current_candidate_maps():
    """Map C reference objects and sources to the matching audited objects."""
    spec = importlib.util.spec_from_file_location(
        "coreutils_port_for_current_links", PORT / "port.py")
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load the Coreutils port driver")
    port = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = port
    spec.loader.exec_module(port)

    audit_path = PORT / "build/conversion-audit-context.json"
    report = json.loads(audit_path.read_text(encoding="utf-8"))
    records_by_candidate = {
        Path(record["candidate"]).name: record
        for record in report["candidates"]
    }
    reference_map = {}
    source_map = {}
    for candidate_name, unit in port.conversion_units(True).items():
        record = records_by_candidate.get(Path(candidate_name).name)
        if record is None or record["compile_status"] != 0 or record["missing_candidate"]:
            raise RuntimeError(
                f"current audited object is not compiled: {candidate_name}")
        candidate = OBJECT_DIRECTORY / (Path(candidate_name).stem + ".o")
        if not candidate.is_file():
            raise FileNotFoundError(candidate)
        source = Path(unit["source"]).resolve()
        for reference in unit["reference_objects"]:
            reference = Path(reference).resolve()
            if reference in reference_map and reference_map[reference][0] != candidate:
                raise RuntimeError(
                    f"multiple candidates map to one C object: {reference}")
            pair = (candidate, reference)
            reference_map[reference] = pair
            source_map.setdefault(source, []).append(pair)
    return reference_map, source_map


def global_defined_symbols(object_path):
    result = subprocess.run(
        ["nm", "-g", "--defined-only", "--format=posix", str(object_path)],
        capture_output=True,
        text=True,
        check=True,
    )
    return {
        line.split()[0]
        for line in result.stdout.splitlines()
        if line.split() and not line.split()[0].endswith(":")
    }


def localize_candidate(candidate, reference, localized_directory, cache):
    """Match C object visibility while retaining the audited FBC implementation."""
    key = (candidate.resolve(), reference.resolve())
    if key in cache:
        return cache[key]

    reference_symbols = global_defined_symbols(reference)
    candidate_symbols = global_defined_symbols(candidate)
    missing = sorted(reference_symbols - candidate_symbols)
    if missing:
        raise RuntimeError(
            f"{candidate.name} misses C object globals: {', '.join(missing[:20])}")
    extras = sorted(candidate_symbols - reference_symbols)
    if not extras:
        cache[key] = candidate
        return candidate

    localized_directory.mkdir(parents=True, exist_ok=True)
    suffix = hashlib.sha1(str(reference.resolve()).encode()).hexdigest()[:10]
    localized = localized_directory / f"{candidate.stem}-{suffix}.o"
    temporary = localized.with_name(localized.stem + ".tmp.o")
    command = [
        "objcopy",
        *("--localize-symbol=" + symbol for symbol in extras),
        str(candidate),
        str(temporary),
    ]
    subprocess.run(command, capture_output=True, text=True, check=True)
    if global_defined_symbols(temporary) != reference_symbols:
        temporary.unlink(missing_ok=True)
        raise RuntimeError(
            f"{candidate.name}: localized symbols still differ from the C object")
    temporary.replace(localized)
    cache[key] = localized
    return localized


def expand_make_variable(variables, value, active=()):
    variable_reference = re.compile(r"\$\(([^)]+)\)")
    for _ in range(64):
        previous = value

        def replace(match):
            name = match.group(1)
            if name in active:
                raise ValueError("cyclic Make variable: " + " -> ".join(active + (name,)))
            return expand_make_variable(
                variables, variables.get(name, ""), active + (name,)
            )

        value = variable_reference.sub(replace, value)
        if value == previous:
            return value
    raise ValueError("Make variable expansion exceeded its recursion limit")


def configured_programs(variables):
    value = expand_make_variable(variables, variables.get("built_programs", ""))
    programs = shlex.split(value)
    if not programs:
        raise ValueError("the reference Makefile has no built_programs list")
    return programs


def command_object_inputs(
    program, variables, reference_map, source_map, localized_directory, cache
):
    target_name = make_target_name(program)
    object_variable = f"src_{target_name}_OBJECTS"
    object_names = shlex.split(expand_make_variable(
        variables, variables.get(object_variable, "")
    ))
    if not object_names:
        raise ValueError(f"Makefile has no objects for command {program}")

    command_objects = []
    for object_name in object_names:
        object_path = Path(object_name)
        if object_path.suffix != ".o":
            raise ValueError(
                f"unexpected non-object entry for {program}: {object_name}"
            )
        reference = (REFERENCE / object_path).resolve()
        candidate_pair = reference_map.get(reference)
        if candidate_pair is None:
            candidate = current_command_object(program, object_path.stem)
            if candidate is None:
                raise RuntimeError(
                    f"no current audited candidate maps to {reference}")
            candidate_pair = (candidate, reference)
        command_objects.append(localize_candidate(
            candidate_pair[0], candidate_pair[1], localized_directory, cache))

    for source in CURRENT_EXTRA_SOURCES_BY_PROGRAM.get(program, ()):
        source_path = (PORT.parent / source).resolve()
        candidates = source_map.get(source_path, [])
        if len(candidates) != 1:
            raise RuntimeError(
                f"expected one current audited candidate for {source}, found {len(candidates)}")
        command_objects.append(localize_candidate(
            candidates[0][0], candidates[0][1], localized_directory, cache))
    return command_objects


def command_link_inputs(program, variables):
    target_name = make_target_name(program)
    link_variable = f"src_{target_name}_LDADD"
    link_value = variables.get(link_variable, variables.get("LDADD", ""))
    tokens = shlex.split(expand_make_variable(variables, link_value))
    archives = []
    link_flags = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        index += 1
        if program == "wc" and token in (
            "src/libwc_avx2.a", "src/libwc_avx512.a",
        ):
            continue
        if token in (
            "src/libcksum_avx2.a",
            "src/libcksum_avx512.a",
            "src/libcksum_pclmul.a",
        ):
            continue
        if token in ("src/libver.a", "lib/libcoreutils.a", "src/libcoreutils.a"):
            continue
        if token == "-l":
            if index >= len(tokens):
                raise ValueError(f"incomplete -l option for command {program}")
            link_flags.extend(("-l", tokens[index]))
            index += 1
            continue
        if token.startswith("-l") and len(token) > 2:
            link_flags.extend(("-l", token[2:]))
            continue
        if token.startswith("-L") and len(token) > 2:
            link_flags.extend(("-p", token[2:]))
            continue
        if token.startswith("-Wl,"):
            link_flags.extend(("-Wl", token[4:]))
            continue
        if token.endswith(".a") or token.endswith(".o"):
            path = REFERENCE / token
            if not path.is_file():
                raise FileNotFoundError(
                    f"Makefile link input for {program} is missing: {path}"
                )
            archives.append(path)
            continue
        if token.startswith("-"):
            raise ValueError(
                f"unsupported Makefile link option for {program}: {token}"
            )
        raise ValueError(f"unrecognized Makefile link input for {program}: {token}")
    return archives, link_flags


def link_command(program, objects, archives, link_flags, version_object,
                 fbc, output_directory):
    destination = output_directory / "src" / program
    command = [
        str(fbc),
        *(str(path) for path in objects),
        str(version_object),
        *(str(path) for path in archives),
        str(SUPPORT_ARCHIVE),
        str(SUPPORT_ARCHIVE),
        *link_flags,
        "-x",
        str(destination),
    ]
    result = subprocess.run(
        command, cwd=PORT.parent, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    return {
        "program": program,
        "exit_code": result.returncode,
        "output": result.stdout[-3000:],
        "objects": [str(path) for path in objects],
        "archives": [str(path) for path in archives],
        "link_flags": link_flags,
        "binary": str(destination),
    }


def write_results(output_directory, results, configured_count, link_log):
    manifest = {
        "configured_programs": configured_count,
        "linked_programs": sum(item["exit_code"] == 0 for item in results),
        "failed_programs": sum(item["exit_code"] != 0 for item in results),
        "object_source": (
            "current audited C2FB objects, with extra globals localized to match "
            "their corresponding C object visibility"
        ),
        "results": results,
    }
    (output_directory / "link-manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    lines = [
        "GNU Coreutils command set linked from current audited FreeBASIC objects",
        f"File: {link_log}",
        "",
        f"Configured names: {configured_count}; linked: {manifest['linked_programs']}; "
        f"failed: {manifest['failed_programs']}.",
        "Each command's source objects come from the current conversion audit.",
        "Extra generated globals are localized to the visibility of their C",
        "reference object. The wc and cksum SIMD entrypoints use scalar FBC",
        "objects. No C project archive is linked; configured external system",
        "libraries remain.",
        "",
    ]
    for item in results:
        lines.append(
            ("PASS" if item["exit_code"] == 0 else "FAIL") + ": " + item["program"]
        )
        if item["exit_code"] != 0 and item["output"]:
            lines.extend(item["output"].splitlines())
    lines.extend(["", f"/* end of {link_log} */"])
    link_log.parent.mkdir(parents=True, exist_ok=True)
    link_log.write_text(
        "\n".join(lines) + "\n", encoding="utf-8"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument(
        "--output-directory", type=Path, default=OUTPUT_DIRECTORY
    )
    parser.add_argument("--log", type=Path, default=LINK_LOG)
    parser.add_argument(
        "--fbc", type=Path,
        default=PORT / "build/toolchain/freebasic/bin/fbc",
    )
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    version_object = current_version_object()
    for required in (REFERENCE / "Makefile", SUPPORT_ARCHIVE, version_object,
                     args.fbc,
                     PORT / "build/conversion-audit-context.json"):
        if not required.is_file():
            parser.error(f"required build input does not exist: {required}")

    variables = makefile_variables(REFERENCE / "Makefile")
    programs = configured_programs(variables)
    reference_map, source_map = current_candidate_maps()
    args.output_directory.mkdir(parents=True, exist_ok=True)
    (args.output_directory / "src").mkdir(parents=True, exist_ok=True)
    localized_directory = args.output_directory / "localized-objects"
    localized_cache = {}

    plans = []
    for program in programs:
        objects = command_object_inputs(
            program, variables, reference_map, source_map,
            localized_directory, localized_cache,
        )
        archives, link_flags = command_link_inputs(program, variables)
        plans.append((program, objects, archives, link_flags))

    results = []
    with ThreadPoolExecutor(max_workers=args.jobs) as executor:
        futures = [executor.submit(
            link_command, program, objects, archives, link_flags,
            version_object, args.fbc.resolve(), args.output_directory.resolve(),
        ) for program, objects, archives, link_flags in plans]
        for future in as_completed(futures):
            results.append(future.result())
    results.sort(key=lambda item: item["program"])
    write_results(args.output_directory, results, len(programs), args.log.resolve())
    linked_count = sum(item["exit_code"] == 0 for item in results)
    failed_count = len(results) - linked_count
    print(
        f"Linked {linked_count} of {len(programs)} configured commands; "
        f"{failed_count} failed."
    )
    for item in results:
        if item["exit_code"] != 0:
            print(f"FAIL {item['program']}: {item['output']}")
    return 0 if failed_count == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())

# end of link_fbc_command_set.py
