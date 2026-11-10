#!/usr/bin/env python3
"""
Project: SQLite FreeBASIC port tools
File: check_candidates.py
Purpose: Compile bulk candidates and record the remaining integration work.
Responsibilities: Report procedure names, source origins, empty candidate
files, compiler status, and diagnostics without adding bodies to the port.
This file intentionally does NOT contain: Semantic approval or engine linking.
"""

import argparse
import csv
from dataclasses import dataclass
import json
from pathlib import Path
import re
import shlex
import subprocess
import tempfile


FREEBASIC_STRING_RE = re.compile(r'"(?:[^"]|"")*"')
FREEBASIC_APOSTROPHE_COMMENT_RE = re.compile(r"'[^\r\n]*")
FREEBASIC_REM_COMMENT_RE = re.compile(
    r"(?m)(^|:)([ \t]*)REM\b[^\r\n]*", re.IGNORECASE
)
SOURCE_PATH_RE = re.compile(r"(?m)^\s*' c2fb source-path: (.*)$")
SOURCE_LINE_RE = re.compile(r"(?m)^\s*' c2fb source-line: ([0-9]+)$")
SOURCE_COLUMN_RE = re.compile(r"(?m)^\s*' c2fb source-column: ([0-9]+)$")
CANDIDATE_SOURCE_RE = re.compile(r"(?m)^\s*Source:\s*(.+)$")
SKIPPED_PROCEDURE_RE = re.compile(
    r"(?m)^\s*' c2fb skipped ([A-Za-z_]\w*): (.*)$"
)
BODY_DIAGNOSTIC_RE = re.compile(
    r"(?m)^\s*' c2fb body diagnostic \[([^\]]+)\] line ([0-9]+)"
    r"(?::([0-9]+))?: ([A-Za-z_]\w*): (.*)$"
)


def split_procedures(source):
    """Split converter output while retaining declarations and includes."""
    pattern = re.compile(
        r"^(?:Private )?(?:Function|Sub) (\w+)[^\n]*\n.*?^End (?:Function|Sub)[^\n]*\n?",
        re.M | re.S,
    )
    procedures = {match.group(1): match.group(0) for match in pattern.finditer(source)}
    return pattern.sub("", source), procedures


def executable_source(source):
    """Mask strings, apostrophe comments, and statement-start REM comments."""
    source = FREEBASIC_STRING_RE.sub(
        lambda match: " " * len(match.group()),
        source,
    )
    source = FREEBASIC_APOSTROPHE_COMMENT_RE.sub(
        lambda match: " " * len(match.group()),
        source,
    )
    source = FREEBASIC_REM_COMMENT_RE.sub(
        lambda match: match.group(1) + match.group(2) + " " * (
            len(match.group(0)) - len(match.group(1)) - len(match.group(2))
        ),
        source,
    )
    return source


def referenced_procedures(source, names):
    executable = executable_source(source)
    return {
        name for name in names
        if re.search(
            rf"\b{re.escape(name)}\s*\(|\bProcPtr\(\s*{re.escape(name)}\s*\)",
            executable,
        )
    }


def procedure_source(preamble, procedures, target):
    # A target may use other generated procedures, including recursive groups.
    # Retain the full reachable group rather than replacing helpers with stubs.
    selected = {target}
    pending = [target]
    while pending:
        name = pending.pop()
        for dependency in referenced_procedures(procedures[name], procedures):
            if dependency not in selected:
                selected.add(dependency)
                pending.append(dependency)
    bodies = "\n".join(body for name, body in procedures.items() if name in selected)
    return preamble + "\n" + bodies, sorted(selected - {target})


def source_location(procedure):
    path_match = SOURCE_PATH_RE.search(procedure)
    line_match = SOURCE_LINE_RE.search(procedure)
    column_match = SOURCE_COLUMN_RE.search(procedure)
    return (
        path_match.group(1) if path_match else "",
        line_match.group(1) if line_match else "",
        column_match.group(1) if column_match else "",
    )


def source_location_summary(names, procedures):
    locations = []
    for name in names:
        path, line, column = source_location(procedures[name])
        if path == "":
            continue
        locations.append({
            "function": name,
            "source_path": path,
            "source_line": int(line) if line else None,
            "source_column": int(column) if column else None,
        })
    return json.dumps(locations, ensure_ascii=False, separators=(",", ":"))


def skipped_procedures(source, translated_names):
    """Read procedure skips so per-procedure reports include rejected work."""
    source_match = CANDIDATE_SOURCE_RE.search(source)
    candidate_source = source_match.group(1).strip() if source_match else ""
    diagnostics = {}
    for match in BODY_DIAGNOSTIC_RE.finditer(source):
        diagnostics.setdefault(match.group(4), []).append(match)
    skipped = {}
    for match in SKIPPED_PROCEDURE_RE.finditer(source):
        name = match.group(1)
        if name in translated_names or name in skipped:
            continue
        reason = match.group(2).strip()
        procedure_diagnostics = diagnostics.get(name, [])
        line = ""
        column = ""
        details = reason
        if procedure_diagnostics:
            line = procedure_diagnostics[0].group(2)
            column = procedure_diagnostics[0].group(3) or ""
            details += "; " + "; ".join(
                f"{diagnostic.group(1)}: {diagnostic.group(5)}"
                for diagnostic in procedure_diagnostics
            )
        skipped[name] = {
            "source_path": candidate_source,
            "source_line": line,
            "source_column": column,
            "diagnostics": details,
        }
    return skipped


@dataclass(frozen=True)
class CandidateCompileResultModel:
    candidate_file: str
    function_name: str
    source_path: str
    source_line: str
    source_column: str
    helper_names: tuple
    status: str
    diagnostics: str
    return_code: int


def compile_candidate(compiler_command, fb_source, threadsafe, input_path,
                      output_path, candidate_file, function_name="", source=None,
                      helper_names=(), candidate_directory=None):
    if source is None:
        source = ("", "", "")
    command = compiler_command + [
        "-w", "all", "-d", f"SQLITE_THREADSAFE={threadsafe}",
        "-i", str(fb_source),
    ]
    if candidate_directory is not None:
        command.extend(("-i", str(candidate_directory)))
    command.extend(("-c", str(input_path), "-o", str(output_path)))
    try:
        result = subprocess.run(command, capture_output=True, text=True)
    except OSError as error:
        return CandidateCompileResultModel(
            candidate_file, function_name, source[0], source[1], source[2],
            tuple(helper_names), "Compile failed",
            f"could not start FreeBASIC compiler: {error}", 127)
    diagnostics = (result.stdout + result.stderr).strip()
    status = "Compile passed" if result.returncode == 0 else "Compile failed"
    return CandidateCompileResultModel(
        candidate_file, function_name, source[0], source[1], source[2],
        tuple(helper_names), status, diagnostics, result.returncode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--fb-source", type=Path,
                        default=Path(__file__).resolve().parents[2] / "fb_src")
    parser.add_argument("--fbc", default="fbc")
    parser.add_argument("--threadsafe", choices=("0", "1"), default="1")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--recursive", action="store_true",
                        help="include candidate files in nested source directories")
    parser.add_argument("--per-procedure", action="store_true",
                        help="Check each procedure with its reachable generated helpers")
    args = parser.parse_args()
    if not args.directory.is_dir():
        parser.error(f"Candidate directory does not exist: {args.directory}")
    if not args.fb_source.is_dir():
        parser.error(f"FreeBASIC source directory does not exist: {args.fb_source}")
    fb_source = args.fb_source.resolve()
    try:
        compiler_command = shlex.split(args.fbc)
    except ValueError as error:
        parser.error(f"Invalid FreeBASIC compiler command: {error}")
    if not compiler_command:
        parser.error("FreeBASIC compiler command is empty")
    candidate_paths = (
        args.directory.rglob("*_candidates.bas") if args.recursive else
        args.directory.glob("*_candidates.bas")
    )
    files = sorted(candidate_paths)
    if not files:
        parser.error(f"No candidate files found in {args.directory}")
    report = args.report or args.directory / ("procedure-compile-report.csv" if args.per_procedure else "compile-report.csv")
    try:
        report.parent.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        parser.error(f"Cannot create compile report directory {report.parent}: {error}")
    passed = 0
    failed = 0
    skipped_count = 0
    checked_bodies = 0
    with tempfile.TemporaryDirectory(prefix="c2fb-check-") as directory:
        with report.open("w", newline="", encoding="utf-8") as output:
            writer = csv.writer(output)
            columns = (
                "CandidateFile", "Function", "SourcePath", "SourceLine",
                "SourceColumn", "Helpers", "Status", "Diagnostics",
            ) if args.per_procedure else (
                "CandidateFile", "Functions", "SourceLocations", "Status", "Diagnostics")
            writer.writerow(columns)
            for index, candidate in enumerate(files):
                candidate_name = candidate.relative_to(args.directory).as_posix()
                original = candidate.read_text(encoding="utf-8")
                preamble, procedures = split_procedures(original)
                names = list(procedures)
                names = [name for name in names if not name.startswith("__c2fb_")]
                skipped = skipped_procedures(original, set(names)) \
                    if args.per_procedure else {}
                if not names and not skipped:
                    if args.per_procedure:
                        writer.writerow((candidate_name, "", "", "", "", "[]",
                                         "No new bodies", ""))
                    else:
                        writer.writerow((candidate_name, "[]", "[]", "No new bodies", ""))
                    continue
                targets = names if args.per_procedure else [None]
                for target_index, target in enumerate(targets):
                    helpers = []
                    input_path = candidate.resolve()
                    if target is not None:
                        text, helpers = procedure_source(preamble, procedures, target)
                        input_path = Path(directory) / f"candidate-{index}-{target_index}.bas"
                        input_path.write_text(text, encoding="utf-8")
                        helper_descriptions = []
                        for helper in helpers:
                            helper_location = source_location(procedures[helper])
                            helper_descriptions.append({
                                "function": helper,
                                "source_path": helper_location[0],
                                "source_line": int(helper_location[1]) if helper_location[1] else None,
                                "source_column": int(helper_location[2]) if helper_location[2] else None,
                            })
                        helpers = helper_descriptions
                    result = compile_candidate(
                        compiler_command, fb_source, args.threadsafe, input_path,
                        Path(directory) / f"candidate-{index}-{target_index}.o",
                        candidate_name, target or "",
                        source_location(procedures[target]) if target is not None else None,
                        helpers, candidate.resolve().parent)
                    if target is not None:
                        writer.writerow((result.candidate_file, result.function_name,
                                         result.source_path, result.source_line,
                                         result.source_column,
                                         json.dumps(result.helper_names, ensure_ascii=False,
                                                    separators=(",", ":")), result.status,
                                         result.diagnostics))
                    else:
                        writer.writerow((result.candidate_file,
                                         json.dumps(names, ensure_ascii=False,
                                                    separators=(",", ":")),
                                         source_location_summary(names, procedures),
                                         result.status, result.diagnostics))
                    checked_bodies += 1 if target is not None else len(names)
                    if result.return_code == 0:
                        passed += 1
                    else:
                        failed += 1
                        if not args.per_procedure:
                            print(f"{candidate_name}: compile failed")
                            print(result.diagnostics)
                if args.per_procedure:
                    for name, item in skipped.items():
                        writer.writerow((
                            candidate_name, name, item["source_path"],
                            item["source_line"], item["source_column"], "[]",
                            "Translation skipped", item["diagnostics"],
                        ))
                    checked_bodies += len(skipped)
                    skipped_count += len(skipped)
    if args.per_procedure:
        print(f"{checked_bodies} procedures checked across {len(files)} candidate files: "
              f"{passed} compiled, {failed} failed, {skipped_count} skipped")
    else:
        print(f"{checked_bodies} bodies across {len(files)} candidate files: "
              f"{passed} files compiled, {failed} failed")
    print(f"Compiler report: {report}")
    return 1 if failed or skipped_count else 0


if __name__ == "__main__":
    raise SystemExit(main())

# end of check_candidates.py
