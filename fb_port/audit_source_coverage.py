#!/usr/bin/env python3
"""
    Project: GNU Coreutils FreeBASIC port
    File: audit_source_coverage.py

    Purpose:

        Reconcile unselected C sources with current FreeBASIC translation evidence.

    Responsibilities:

        - Scan FreeBASIC source artifacts for their originating C source paths.
        - Count unselected translation units that emit at least one function body.
        - Preserve provenance for bodies emitted from included C and header files.
        - Validate sidecar evidence for sources that emit globals or constants.
        - Keep the remaining-source count tied to verified translation evidence.

    This file intentionally does NOT contain:

        - A C2FB translation or FreeBASIC compilation step.
        - Assertions about runtime correctness of generated functions.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REPORT = ROOT / "fb_port/reports/coreutils-source-coverage-linux-x86_64-20261031.json"
HEADER_SOURCE_PATTERN = re.compile(r"\bSource:\s*([^\r\n]+?\.c)", re.IGNORECASE)
FUNCTION_SOURCE_PATTERN = re.compile(
    r"^\s*'\s*c2fb source-path:\s*([^\r\n]+?)\s*$",
    re.IGNORECASE | re.MULTILINE,
)
FUNCTION_PATTERN = re.compile(
    r"^\s*(?:Private\s+)?(?:Function|Sub)\s+[^\r\n]+",
    re.IGNORECASE | re.MULTILINE,
)
FUNCTION_DECLARATION_PATTERN = re.compile(
    r"^\s*(?:Private\s+)?(?:Function|Sub)\s+([^\s(]+)",
    re.IGNORECASE | re.MULTILINE,
)
NON_FUNCTION_TRANSLATION_REPORTS = {
    "lib/byteswap.c": "fb_port/reports/byteswap-inline-current-toolchain-ba0e-fbc15a-20261103-r2.json",
    "lib/float.c": "fb_port/reports/float-fallback-current-toolchain-ba0e-fbc15a-20261103.json",
    "src/termios.c": "fb_port/reports/termios-speed-constants-port-audit-ba0e-20261102.json",
}


def verify_non_function_translation(
    source: str,
    report_path: str,
    current_converter_sha256: str,
) -> dict[str, object]:
    evidence_path = ROOT / report_path
    if not evidence_path.is_file():
        raise FileNotFoundError(evidence_path)
    evidence = json.loads(evidence_path.read_text(encoding="utf-8"))

    if source == "lib/byteswap.c":
        valid = (
            evidence.get("status") == "byteswap-inline-current-C2FB-and-FBC-runtime-tested"
            and evidence.get("converter_sha256") == current_converter_sha256
            and evidence.get("translated_functions") == 6
            and evidence.get("skipped_functions") == 0
        )
        details = {
            "translation_role": "inline functions included by lib/byteswap.c",
            "implementation_source": evidence.get("source"),
            "source_adapter": evidence.get("source_adapter"),
            "translated_functions": evidence.get("translated_functions"),
            "skipped_functions": evidence.get("skipped_functions"),
        }
    elif source == "lib/float.c":
        valid = (
            evidence.get("status") == "float-fallback-current-C2FB-and-FBC-runtime-tested"
            and evidence.get("converter_sha256") == current_converter_sha256
            and evidence.get("translated_functions") == 0
            and evidence.get("translated_global_objects") == 3
            and evidence.get("skipped_functions_or_objects") == 0
        )
        details = {
            "translation_role": "fallback global data; no function definitions",
            "translated_global_objects": evidence.get("translated_global_objects"),
            "skipped_functions_or_objects": evidence.get("skipped_functions_or_objects"),
        }
    elif source == "src/termios.c":
        converter = evidence.get("converter", {})
        verification = evidence.get("verification", {})
        valid = (
            converter.get("sha256") == current_converter_sha256
            and verification.get("status") == "passed"
            and verification.get("constants_checked") == 41
            and "42 integer macros emitted, zero unsupported declarations or macro expressions skipped"
            in converter.get("summary", "")
        )
        details = {
            "translation_role": "build-time baud-rate macro input",
            "verified_constants": verification.get("constants_checked"),
            "generated_binding": evidence.get("generated_binding", {}).get("path"),
        }
    else:
        raise ValueError(f"no non-function translation rule for {source}")

    if not valid:
        raise ValueError(
            f"non-function translation evidence for {source} does not match "
            f"the current C2FB converter: {evidence_path}"
        )
    return {
        "report": report_path,
        "report_sha256": hashlib.sha256(evidence_path.read_bytes()).hexdigest(),
        "converter_sha256": current_converter_sha256,
        **details,
    }


def relative_source(source: str) -> str | None:
    source_path = Path(source.strip().rstrip("*/ "))
    if source_path.is_absolute():
        candidate_paths = [source_path]
    else:
        # Preprocessor line markers can retain include paths relative to the
        # configured build directory. Resolve those from the same build roots
        # used by the captured Linux and Windows compiler contexts.
        candidate_paths = [
            ROOT / source_path,
            ROOT / "fb_port/build/reference" / source_path,
            ROOT / "fb_port/build/reference-windows" / source_path,
        ]
    for candidate_path in candidate_paths:
        try:
            resolved_path = candidate_path.resolve()
            relative_path = resolved_path.relative_to(ROOT)
        except ValueError:
            continue
        if resolved_path.is_file():
            return str(relative_path)
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()
    report_path = args.report.resolve()
    if not report_path.is_file():
        parser.error(f"coverage report does not exist: {report_path}")

    report = json.loads(report_path.read_text(encoding="utf-8"))
    unselected_sources = set(report["source_inventory"]["unselected_files"])
    artifacts: dict[str, list[dict[str, object]]] = {}
    translated_names: dict[str, set[str]] = {}
    unmapped_bodies: dict[str, int] = {}
    for artifact in (ROOT / "fb_port").rglob("*.bas"):
        try:
            text = artifact.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        lines = text.splitlines()
        function_count = len(FUNCTION_PATTERN.findall(text))
        source_function_counts: dict[str, int] = {}
        source_function_names: dict[str, set[str]] = {}
        source_path_markers: set[str] = set()
        marked_function_count = 0
        for match in FUNCTION_SOURCE_PATTERN.finditer(text):
            line_number = text.count("\n", 0, match.start())
            preceding_lines = lines[max(0, line_number - 8) : line_number]
            declaration = next(
                (FUNCTION_DECLARATION_PATTERN.match(line)
                 for line in reversed(preceding_lines)
                 if FUNCTION_DECLARATION_PATTERN.match(line)),
                None,
            )
            if declaration is None:
                continue
            marked_function_count += 1
            source = relative_source(match.group(1))
            if source is not None:
                source_path_markers.add(source)
            if source not in unselected_sources:
                continue
            function_name = declaration.group(1)
            source_function_counts[source] = source_function_counts.get(source, 0) + 1
            source_function_names.setdefault(source, set()).add(function_name)

        header_match = HEADER_SOURCE_PATTERN.search(text[:12000])
        translation_unit_source = (
            relative_source(header_match.group(1)) if header_match else None
        )
        function_names = set(FUNCTION_DECLARATION_PATTERN.findall(text))
        if translation_unit_source in unselected_sources and function_count:
            # The top-level C source owns this translation unit even when its
            # implementation is expanded from an included C template or header.
            source_function_counts[translation_unit_source] = function_count
            source_function_names[translation_unit_source] = function_names
            unmarked_count = max(0, function_count - marked_function_count)
            if unmarked_count:
                unmapped_bodies[translation_unit_source] = (
                    unmapped_bodies.get(translation_unit_source, 0) + unmarked_count
                )

        for source, source_count in source_function_counts.items():
            if source == translation_unit_source:
                continue
            names = sorted(source_function_names.get(source, set()))
            artifacts.setdefault(source, []).append(
                {
                    "path": str(artifact.relative_to(ROOT)),
                    "function_bodies": source_count,
                    "function_names": names,
                    "provenance": "function source-path marker",
                    "translation_unit_source": translation_unit_source,
                    "function_source_paths": sorted(source_path_markers),
                }
            )
            translated_names.setdefault(source, set()).update(names)

        if translation_unit_source in unselected_sources and function_count:
            names = sorted(source_function_names[translation_unit_source])
            artifacts.setdefault(translation_unit_source, []).append(
                {
                    "path": str(artifact.relative_to(ROOT)),
                    "function_bodies": function_count,
                    "function_names": names,
                    "provenance": "C translation unit; bodies may come from included sources",
                    "translation_unit_source": translation_unit_source,
                    "function_source_paths": sorted(source_path_markers),
                }
            )
            translated_names.setdefault(translation_unit_source, set()).update(names)

    with_functions = {
        source
        for source, entries in artifacts.items()
        if max(entry["function_bodies"] for entry in entries) > 0
    }
    without_functions = sorted(unselected_sources - with_functions)
    current_converter_sha256 = report.get("c2fb_converter_current_sha256")
    non_function_evidence: dict[str, dict[str, object]] = {}
    if current_converter_sha256:
        converter_path = Path(report["c2fb_converter"])
        if not converter_path.is_file():
            raise FileNotFoundError(converter_path)
        actual_converter_sha256 = hashlib.sha256(converter_path.read_bytes()).hexdigest()
        if actual_converter_sha256 != current_converter_sha256:
            raise ValueError(
                "coverage report's C2FB hash does not match the current converter: "
                f"{converter_path}"
            )
        for source in without_functions:
            evidence_report = NON_FUNCTION_TRANSLATION_REPORTS.get(source)
            if evidence_report is not None:
                non_function_evidence[source] = verify_non_function_translation(
                    source, evidence_report, current_converter_sha256
                )

    accounted_sources = with_functions | set(non_function_evidence)
    unaccounted_sources = sorted(unselected_sources - accounted_sources)
    report["remaining_unselected_sources_not_yet_translated"] = len(unaccounted_sources)
    report["unselected_source_translation_coverage"] = {
        "inventory_source_count": len(unselected_sources),
        "sources_with_function_body_artifacts": len(with_functions),
        "sources_with_verified_non_function_artifacts": len(non_function_evidence),
        "sources_with_any_translation_evidence": len(accounted_sources),
        "sources_without_translation_evidence": len(unaccounted_sources),
        "sources_without_translation_evidence_list": unaccounted_sources,
        "current_converter_sha256": current_converter_sha256,
    }
    if "unselected_but_not_yet_translated_c_files" in report["source_inventory"]:
        report["source_inventory"]["unselected_but_not_yet_translated_c_files"] = len(
            unaccounted_sources
        )
    report["unselected_source_artifact_audit"] = {
        "inventory_source_count": len(unselected_sources),
        "sources_with_persistent_freebasic_function_provenance": len(artifacts),
        "sources_with_at_least_one_emitted_function_body": len(with_functions),
        "sources_without_an_emitted_function_body": len(without_functions),
        "sources_without_an_emitted_function_body_list": without_functions,
        "sources_with_verified_non_function_translation_evidence": len(non_function_evidence),
        "non_function_translation_evidence_by_source": non_function_evidence,
        "sources_without_any_translation_evidence": len(unaccounted_sources),
        "sources_without_any_translation_evidence_list": unaccounted_sources,
        "distinct_translated_function_bodies": sum(
            len(names) for names in translated_names.values()
        ),
        "distinct_translated_function_names_by_source": {
            source: sorted(names)
            for source, names in sorted(translated_names.items())
        },
        "unmapped_function_body_count": sum(unmapped_bodies.values()),
        "unmapped_function_bodies_by_source": dict(sorted(unmapped_bodies.items())),
        "unmapped_function_body_count_note": (
            "Counts emitted FreeBASIC bodies in unselected translation units that "
            "lack an explicit c2fb source-path marker. It is not a count of C "
            "functions missing a FreeBASIC body."
        ),
        "function_artifacts": {
            source: entries for source, entries in sorted(artifacts.items())
        },
        "provenance_policy": (
            "Function bodies are attributed to an unselected C translation unit "
            "using the C2FB Source header, including bodies expanded from included "
            "C or header implementations. Separate unselected function source-path "
            "markers are retained as additional provenance. The byteswap, float, "
            "and termios inputs have explicit current-C2FB reports because their "
            "translation outputs are inline functions, global objects, or constants."
        ),
        "artifact_root": "fb_port",
        "audit_script": "fb_port/audit_source_coverage.py",
    }
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        "unselected C source inventory: "
        f"{len(unselected_sources)}; persistent translated function artifacts: "
        f"{len(with_functions)}; verified non-function artifacts: "
        f"{len(non_function_evidence)}; without translation evidence: "
        f"{len(unaccounted_sources)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


# end of audit_source_coverage.py
