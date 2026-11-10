#!/usr/bin/env python3
"""
Project: GNU Coreutils FreeBASIC port
File: build_fbc_support_archive.py
Purpose: Assemble the translated objects for the reference libcoreutils.a.
Responsibilities: Match archive members to audited C2FB objects, preserve C
linkage ownership for shared header helpers, and verify the resulting symbols.
This file intentionally does NOT contain: C parsing, translation rules, or
changes to the reference C archive.
"""

from collections import Counter, defaultdict
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


PORT = Path(__file__).resolve().parents[1]
REFERENCE_ARCHIVE = PORT / "build/reference/lib/libcoreutils.a"
AUDIT_REPORT = PORT / "build/conversion-audit-context.json"
OBJECT_DIRECTORY = PORT / "build/objects-context"
OUTPUT_DIRECTORY = PORT / "build/fbc-support-library"
OUTPUT_ARCHIVE = OUTPUT_DIRECTORY / "libcoreutils.a"
OUTPUT_MANIFEST = OUTPUT_DIRECTORY / "manifest.json"


def load_port_module():
    sys.path.insert(0, str(PORT))
    spec = importlib.util.spec_from_file_location("coreutils_port_archive", PORT / "port.py")
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load fb_port/port.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def run(command, *, cwd=None):
    subprocess.run(command, cwd=cwd, check=True)


def archive_members(archive_path):
    result = subprocess.run(
        ["ar", "t", str(archive_path)],
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.splitlines()


def verify_duplicate_archive_members(archive_path, members):
    counts = Counter(members)
    duplicates = {name: count for name, count in counts.items() if count > 1}
    if not duplicates:
        return {}

    hashes = {}
    with tempfile.TemporaryDirectory(prefix="coreutils-archive-duplicates-") as temp:
        temp_root = Path(temp)
        for member, count in duplicates.items():
            member_hashes = []
            for occurrence in range(1, count + 1):
                occurrence_directory = temp_root / f"{member}-{occurrence}"
                occurrence_directory.mkdir()
                run(["ar", "xN", str(occurrence), str(archive_path), member],
                    cwd=occurrence_directory)
                extracted = occurrence_directory / member
                if not extracted.is_file():
                    raise RuntimeError(
                        f"archive member {member} occurrence {occurrence} was not extracted"
                    )
                member_hashes.append(hashlib.sha256(extracted.read_bytes()).hexdigest())
            if len(set(member_hashes)) != 1:
                raise RuntimeError(
                    f"duplicate archive member {member} has different object contents"
                )
            hashes[member] = member_hashes[0]
    return hashes


def collect_archive_objects(port):
    report = json.loads(AUDIT_REPORT.read_text(encoding="utf-8"))
    if (report["missing_candidates"] != 0 or
            report["compiled_units"] != report["units"] or
            report["missing_link_symbols"] != 0):
        raise RuntimeError("the full source-unit audit must pass before archiving")

    audit_by_candidate = {
        row["candidate"]: row for row in report["candidates"]
    }
    units = port.conversion_units(contexts=True)
    candidates_by_member = defaultdict(list)
    reference_by_member = defaultdict(list)
    for candidate, unit in units.items():
        for reference_object in unit["reference_objects"]:
            reference_path = Path(reference_object).resolve()
            member = reference_path.name
            if not member.startswith("libcoreutils_a-"):
                continue
            candidates_by_member[member].append(candidate)
            reference_by_member[member].append(reference_path)

    original_members = archive_members(REFERENCE_ARCHIVE)
    duplicate_hashes = verify_duplicate_archive_members(
        REFERENCE_ARCHIVE, original_members)
    unique_members = sorted(set(original_members))

    member_records = {}
    for member in unique_members:
        candidates = sorted(set(candidates_by_member.get(member, [])))
        reference_paths = sorted(set(reference_by_member.get(member, [])))
        if len(candidates) != 1 or len(reference_paths) != 1:
            raise RuntimeError(
                f"{member}: expected one C2FB context and C object, found "
                f"{len(candidates)} and {len(reference_paths)}"
            )

        candidate = candidates[0]
        audit_key = f"generated-context/{candidate}"
        record = audit_by_candidate.get(audit_key)
        if record is None or record["compile_status"] != 0:
            raise RuntimeError(f"{member}: audited FreeBASIC object is not compiled")
        freebasic_object = OBJECT_DIRECTORY / (Path(candidate).stem + ".o")
        reference_object = reference_paths[0]
        if not freebasic_object.is_file() or not reference_object.is_file():
            raise RuntimeError(f"{member}: a required object file is missing")
        member_records[member] = {
            "candidate": candidate,
            "source": unit_source(units, candidate),
            "freebasic_object": freebasic_object,
            "reference_object": reference_object,
        }

    extra_context_members = sorted(set(candidates_by_member) - set(unique_members))
    if extra_context_members:
        raise RuntimeError(
            "the source inventory contains library members absent from the C archive: "
            + ", ".join(extra_context_members)
        )
    return report, original_members, duplicate_hashes, member_records


def unit_source(units, candidate):
    for filename, unit in units.items():
        if filename == candidate:
            return unit["source"]
    raise RuntimeError(f"no source path is registered for {candidate}")


def parse_nm_object_output(output, member_by_path):
    symbol_owners = defaultdict(set)
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 3:
            continue
        object_field = fields[0]
        if not object_field.endswith(":"):
            continue
        object_path = str(Path(object_field[:-1]).resolve())
        member = member_by_path.get(object_path)
        if member is None:
            continue
        symbol_owners[fields[1]].add(member)
    return symbol_owners


def symbols_for_objects(objects_by_member):
    member_by_path = {
        str(Path(path).resolve()): member
        for member, path in objects_by_member.items()
    }
    result = subprocess.run(
        ["nm", "-A", "-g", "--defined-only", "--format=posix",
         *objects_by_member.values()],
        capture_output=True,
        text=True,
        check=True,
    )
    return parse_nm_object_output(result.stdout, member_by_path)


def local_symbols_to_match_reference(fbc_symbols, c_symbols):
    reference_names = set(c_symbols)
    freebasic_names = set(fbc_symbols)
    missing = sorted(reference_names - freebasic_names)
    extra = sorted(freebasic_names - reference_names)
    if missing or extra:
        raise RuntimeError(
            f"global symbol sets differ: missing={missing[:20]}, extra={extra[:20]}"
        )

    localizations = defaultdict(list)
    for symbol, freebasic_owners in fbc_symbols.items():
        c_owners = c_symbols[symbol]
        if not c_owners.issubset(freebasic_owners):
            raise RuntimeError(
                f"{symbol}: translated definitions do not retain C owner(s) "
                f"{sorted(c_owners)}"
            )
        for member in freebasic_owners - c_owners:
            localizations[member].append(symbol)
    return {member: sorted(symbols) for member, symbols in localizations.items()}


def prepare_member_objects(member_records, localizations):
    OUTPUT_DIRECTORY.mkdir(parents=True, exist_ok=True)
    object_directory = OUTPUT_DIRECTORY / "objects"
    object_directory.mkdir(parents=True, exist_ok=True)
    prepared = {}
    for member, record in sorted(member_records.items()):
        object_path = object_directory / member
        shutil.copy2(record["freebasic_object"], object_path)
        symbols = localizations.get(member, [])
        if symbols:
            temporary_object = object_path.with_name(object_path.name + ".localized")
            command = ["objcopy"]
            command.extend(f"--localize-symbol={symbol}" for symbol in symbols)
            command.extend((str(object_path), str(temporary_object)))
            run(command)
            temporary_object.replace(object_path)
        prepared[member] = object_path
    return prepared


def build_archive(prepared_objects):
    temporary_archive = OUTPUT_DIRECTORY / "libcoreutils.a.tmp"
    temporary_archive.unlink(missing_ok=True)
    run(["ar", "crs", str(temporary_archive),
         *[path.name for path in prepared_objects.values()]],
        cwd=OUTPUT_DIRECTORY / "objects")
    run(["ranlib", str(temporary_archive)])

    result = subprocess.run(
        ["nm", "-g", "--defined-only", "--format=posix", str(temporary_archive)],
        capture_output=True,
        text=True,
        check=True,
    )
    final_counts = Counter()
    for line in result.stdout.splitlines():
        fields = line.split()
        if not fields or fields[0].endswith(":"):
            continue
        final_counts[fields[0]] += 1
    if any(count > 1 for count in final_counts.values()):
        duplicates = sorted(name for name, count in final_counts.items() if count > 1)
        raise RuntimeError(f"duplicate global definitions remain: {duplicates}")
    OUTPUT_ARCHIVE.parent.mkdir(parents=True, exist_ok=True)
    temporary_archive.replace(OUTPUT_ARCHIVE)
    return final_counts


def main():
    port = load_port_module()
    if not REFERENCE_ARCHIVE.is_file() or not AUDIT_REPORT.is_file():
        raise RuntimeError("reference archive or current conversion audit is missing")
    (report, original_members, duplicate_hashes,
     member_records) = collect_archive_objects(port)

    reference_objects = {
        member: str(record["reference_object"])
        for member, record in member_records.items()
    }
    freebasic_objects = {
        member: str(record["freebasic_object"])
        for member, record in member_records.items()
    }
    reference_symbols = symbols_for_objects(reference_objects)
    freebasic_symbols = symbols_for_objects(freebasic_objects)
    localizations = local_symbols_to_match_reference(
        freebasic_symbols, reference_symbols)
    prepared_objects = prepare_member_objects(member_records, localizations)
    final_symbols = build_archive(prepared_objects)
    if set(final_symbols) != set(reference_symbols):
        raise RuntimeError("assembled archive symbol set differs from the C reference")

    manifest = {
        "reference_archive": str(REFERENCE_ARCHIVE),
        "freebasic_archive": str(OUTPUT_ARCHIVE),
        "reference_member_occurrences": len(original_members),
        "unique_members": len(member_records),
        "duplicate_reference_members": duplicate_hashes,
        "global_symbols": len(reference_symbols),
        "localized_duplicate_symbols": localizations,
        "audit": {
            "units": report["units"],
            "compiled_units": report["compiled_units"],
            "missing_candidates": report["missing_candidates"],
            "missing_link_symbols": report["missing_link_symbols"],
            "emitted_functions": report["emitted_functions"],
            "generated_helper_functions": report["generated_helper_functions"],
            "skipped_functions": report["skipped_functions"],
        },
    }
    temporary_manifest = OUTPUT_MANIFEST.with_suffix(".json.tmp")
    temporary_manifest.write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    temporary_manifest.replace(OUTPUT_MANIFEST)
    print(f"Built {OUTPUT_ARCHIVE}")
    print(f"  translated members: {len(member_records)}")
    print(f"  global symbols: {len(final_symbols)}")
    print(f"  symbols localized to preserve C owner scope: "
          f"{sum(len(names) for names in localizations.values())}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"FreeBASIC support archive: {error}", file=sys.stderr)
        raise SystemExit(1)

# end of build_fbc_support_archive.py
