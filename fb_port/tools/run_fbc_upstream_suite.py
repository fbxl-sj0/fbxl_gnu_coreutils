#!/usr/bin/env python3
"""
Project: GNU Coreutils FreeBASIC port
File: run_fbc_upstream_suite.py
Purpose: Run the unchanged configured upstream tests against a FreeBASIC build.
Responsibilities: Use the reference Makefile test list and environment,
select the FreeBASIC command directory ahead of reference binaries, preserve
the shell/Perl test languages, and save per-test results.
This file intentionally does NOT contain: translated test cases or port code.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


PORT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = PORT.parent
REFERENCE = PORT / "build/reference"
DEFAULT_BUILD = (
    PORT / "build/hybrid-current-audit-candidates-104-no-project-c-archives"
)
DEFAULT_LOG = PORT / "logs/coreutils-current-audit-candidates-104-upstream-20261031.log"


def load_link_tools():
    spec = importlib.util.spec_from_file_location(
        "coreutils_command_link", PORT / "tools/link_fbc_command_set.py"
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load the Coreutils Makefile reader")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def make_test_environment(variables, build_directory, reference_directory):
    expand = load_link_tools().expand_make_variable
    built_programs = expand(variables, variables.get("built_programs", "")).strip()
    reference_src = reference_directory / "src"
    current_src = build_directory / "src"

    for helper in ("getlimits", "libstdbuf.so"):
        destination = current_src / helper
        if destination.exists() or destination.is_symlink():
            continue
        source = reference_src / helper
        if source.is_file():
            destination.symlink_to(source)

    locale_names = (
        "LOCALE_EN_UTF8", "LOCALE_FR", "LOCALE_FR_UTF8", "LOCALE_JA",
        "LOCALE_TR_UTF8", "LOCALE_ZH_CN",
    )
    environment = os.environ.copy()
    environment.update({
        "srcdir": str(SOURCE_ROOT),
        "abs_srcdir": str(SOURCE_ROOT),
        "top_srcdir": str(SOURCE_ROOT),
        "abs_top_srcdir": str(SOURCE_ROOT),
        "builddir": str(build_directory),
        "abs_builddir": str(build_directory),
        "top_builddir": str(build_directory),
        "abs_top_builddir": str(build_directory),
        "CONFIG_HEADER": str(reference_directory / "lib/config.h"),
        "built_programs": built_programs,
        "host_os": expand(variables, variables.get("host_os", "linux-gnu")),
        "EXEEXT": expand(variables, variables.get("EXEEXT", "")),
        "VERSION": expand(variables, variables.get("VERSION", "")),
        "PACKAGE_VERSION": expand(variables, variables.get("PACKAGE_VERSION", "")),
        "CC": expand(variables, variables.get("CC", "cc")),
        "AWK": expand(variables, variables.get("AWK", "awk")),
        "PERL": "/usr/bin/perl",
        "SHELL": "/bin/bash",
        "CONFIG_SHELL": "/bin/bash",
        "MAKE": "make",
        "PATH": os.pathsep.join((str(current_src), str(reference_src),
                                 environment.get("PATH", ""))),
        "LC_ALL": "C",
        "LANG": "C",
        "LANGUAGE": "C",
    })
    for name in locale_names:
        environment[name] = expand(variables, variables.get(name, "none"))
    return environment, built_programs.split()


def test_command(script, environment):
    if script.suffix == ".sh":
        return [
            "/bin/bash", "-c", 'exec 9>&2; sh "$1"', "upstream-test",
            str(script),
        ]
    if script.suffix == ".pl":
        return [
            environment["PERL"], "-w", f"-I{SOURCE_ROOT / 'tests'}",
            "-MCuSkip", "-MCoreutils", str(script),
        ]
    raise ValueError(f"unsupported upstream test format: {script}")


def baseline_status(relative_path, reference_directory):
    baseline = reference_directory / relative_path.with_suffix(".trs")
    if not baseline.is_file():
        return "unrecorded"
    for line in baseline.read_text(errors="replace").splitlines():
        if line.startswith(":test-result:"):
            return line.split(":", 2)[2].strip()
    return "unrecorded"


def run_one(script, relative_path, environment, reference_directory,
            timeout_seconds, working_directory):
    try:
        completed = subprocess.run(
            test_command(script, environment),
            cwd=working_directory,
            env=environment,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout_seconds,
            check=False,
        )
        if completed.returncode == 0:
            status = "PASS"
        elif completed.returncode == 77:
            status = "SKIP"
        else:
            status = "FAIL"
        output = completed.stdout
        return {
            "test": relative_path.as_posix(),
            "baseline": baseline_status(relative_path, reference_directory),
            "status": status,
            "return_code": completed.returncode,
            "output": output[-4000:] if status == "FAIL" else "",
        }
    except subprocess.TimeoutExpired as error:
        output = error.stdout or b""
        if isinstance(output, bytes):
            output = output.decode(errors="replace")
        return {
            "test": relative_path.as_posix(),
            "baseline": baseline_status(relative_path, reference_directory),
            "status": "TIMEOUT",
            "return_code": None,
            "output": output[-4000:],
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-directory", type=Path, default=DEFAULT_BUILD)
    parser.add_argument("--reference-build-directory", type=Path, default=REFERENCE)
    parser.add_argument("--log", type=Path, default=DEFAULT_LOG)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--limit", type=int, default=0,
                        help="run only the first N scripts for a focused check")
    arguments = parser.parse_args()

    if arguments.timeout <= 0 or arguments.limit < 0:
        parser.error("--timeout must be positive and --limit non-negative")
    build_directory = arguments.build_directory.resolve()
    reference_directory = arguments.reference_build_directory.resolve()
    if not (build_directory / "src").is_dir():
        parser.error(f"FreeBASIC command directory is missing: {build_directory / 'src'}")
    if not (reference_directory / "Makefile").is_file():
        parser.error(f"reference Makefile is missing: {reference_directory / 'Makefile'}")

    link_tools = load_link_tools()
    variables = link_tools.makefile_variables(reference_directory / "Makefile")
    environment, built_programs = make_test_environment(
        variables, build_directory, reference_directory)
    program_binaries = [build_directory / "src" / program for program in built_programs]
    missing_programs = [str(path) for path in program_binaries if not path.is_file()]
    if missing_programs:
        parser.error("FreeBASIC binaries are missing: " + ", ".join(missing_programs))

    all_tests = link_tools.expand_make_variable(
        variables, variables.get("all_tests", "")
    ).split()
    if arguments.limit:
        all_tests = all_tests[:arguments.limit]
    tests = [(SOURCE_ROOT / name, Path(name)) for name in all_tests]
    missing_tests = [str(relative) for source, relative in tests if not source.is_file()]
    if missing_tests:
        parser.error("upstream test files are missing: " + ", ".join(missing_tests))

    arguments.log.parent.mkdir(parents=True, exist_ok=True)
    work_directory_root = build_directory / "upstream-test-work"
    work_directory_root.mkdir(parents=True, exist_ok=True)
    results = []
    with arguments.log.open("w", encoding="utf-8") as log:
        log.write(
            "GNU Coreutils unchanged upstream suite against the refreshed "
            "FreeBASIC command set\n"
            f"File: {arguments.log}\n\n"
            f"Scripts from the reference Makefile: {len(tests)}\n"
            "The test sources remain in their original shell and Perl formats.\n\n"
            "Each script runs in its own temporary working directory.\n\n"
        )
        log.flush()
        for index, (source, relative) in enumerate(tests, 1):
            with tempfile.TemporaryDirectory(
                prefix=f"{index:04d}-", dir=work_directory_root
            ) as working_directory:
                result = run_one(
                    source, relative, environment, reference_directory,
                    arguments.timeout, working_directory)
            results.append(result)
            line = (
                f"{result['status']}: {result['test']} "
                f"(C baseline: {result['baseline']})"
            )
            print(line, flush=True)
            log.write(line + "\n")
            if result["output"]:
                log.write(result["output"] + "\n")
            if index % 25 == 0:
                log.flush()
        counts = {name: sum(item["status"] == name for item in results)
                  for name in ("PASS", "SKIP", "FAIL", "TIMEOUT")}
        log.write(
            "\n" + ", ".join(f"{name}: {count}" for name, count in counts.items())
            + "\n\n/* end of upstream test log */\n"
        )

    manifest_path = arguments.log.with_suffix(".json")
    manifest_path.write_text(
        json.dumps({"counts": counts, "results": results}, indent=2) + "\n",
        encoding="utf-8",
    )
    print("Summary: " + ", ".join(
        f"{name.lower()}={count}" for name, count in counts.items()
    ), flush=True)
    return 1 if counts["FAIL"] or counts["TIMEOUT"] else 0


if __name__ == "__main__":
    raise SystemExit(main())

# end of run_fbc_upstream_suite.py
