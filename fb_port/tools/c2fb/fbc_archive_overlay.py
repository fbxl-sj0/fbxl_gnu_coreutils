#!/usr/bin/env python3
"""
Project: C2FB FreeBASIC port tools
File: fbc_archive_overlay.py
Purpose: Stage symbol- and machine-checked C2FB objects into isolated archives.
Responsibilities: Validate object exports and machine format, replace exact
archive members in a new library directory, and preserve the source archives.
This file intentionally does NOT contain: C conversion, object compilation, or
FreeBASIC test-suite execution.
"""

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


OBJECT_SUFFIXES = {".o", ".obj"}
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")


class OverlayError(Exception):
    """An archive overlay failed before its staged directory was published."""


@dataclass(frozen=True)
class Replacement:
    archive: str
    member: str
    object_path: Path
    expected_sha256: str


def run_tool(command, label, cwd=None):
    try:
        result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    except OSError as error:
        raise OverlayError(f"could not start {label}: {error}") from error
    if result.returncode != 0:
        diagnostic = (result.stdout + result.stderr).strip()
        raise OverlayError(
            f"{label} failed with status {result.returncode}: {diagnostic}"
        )
    return result.stdout


def safe_archive_name(value, label):
    if not isinstance(value, str) or not value or "\0" in value:
        raise OverlayError(f"{label} must be a non-empty archive basename")
    if value in {".", ".."} or "/" in value or "\\" in value:
        raise OverlayError(f"{label} must be a basename: {value!r}")
    return value


def object_path_from_record(record, manifest_directory):
    value = record.get("object")
    if value is None:
        value = record.get("candidate_object")
    if value is None:
        candidate = record.get("candidate")
        if isinstance(candidate, str) and Path(candidate).suffix.lower() in OBJECT_SUFFIXES:
            value = candidate
    if not isinstance(value, str) or not value.strip() or "\0" in value:
        raise OverlayError(
            "replacement must provide object, candidate_object, or an object-valued candidate"
        )
    path = Path(value)
    if not path.is_absolute():
        path = manifest_directory / path
    try:
        path = path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise OverlayError(f"cannot resolve replacement object {path}: {error}") from error
    if not path.is_file():
        raise OverlayError(f"replacement object is not a regular file: {path}")
    return path


def load_replacements(manifest_path):
    try:
        document = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise OverlayError(f"cannot read manifest {manifest_path}: {error}") from error
    if not isinstance(document, dict) or document.get("version") != 1:
        raise OverlayError("manifest must be a JSON object with version 1")
    entries = document.get("members")
    if not isinstance(entries, list) or not entries:
        raise OverlayError("manifest members must be a non-empty array")

    replacements = []
    seen = set()
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise OverlayError(f"manifest member {index} must be an object")
        archive = safe_archive_name(entry.get("archive"), f"member {index} archive")
        member = safe_archive_name(entry.get("member"), f"member {index} name")
        key = (archive, member)
        if key in seen:
            raise OverlayError(f"duplicate replacement for {archive}({member})")
        seen.add(key)

        object_path = object_path_from_record(entry, manifest_path.parent)
        expected_hash = entry.get("sha256", "")
        if expected_hash:
            if not isinstance(expected_hash, str) or not SHA256_RE.fullmatch(expected_hash):
                raise OverlayError(f"invalid SHA-256 for {object_path}")
            actual_hash = hashlib.sha256(object_path.read_bytes()).hexdigest()
            if actual_hash.lower() != expected_hash.lower():
                raise OverlayError(f"SHA-256 mismatch for {object_path}")
        replacements.append(Replacement(archive, member, object_path, expected_hash))
    return replacements


def archive_members(ar, archive_path):
    output = run_tool([ar, "t", str(archive_path)], f"archive listing for {archive_path}")
    return output.splitlines()


def extract_member(ar, archive_path, member, output_path):
    try:
        result = subprocess.run(
            [ar, "p", str(archive_path), member], capture_output=True
        )
    except OSError as error:
        raise OverlayError(f"could not start {ar}: {error}") from error
    if result.returncode != 0 or not result.stdout:
        diagnostic = result.stderr.decode("utf-8", errors="replace").strip()
        raise OverlayError(
            f"cannot extract {archive_path}({member}): {diagnostic or 'empty member'}"
        )
    output_path.write_bytes(result.stdout)


def symbol_exports(nm, object_path):
    output = run_tool(
        [nm, "-g", "--defined-only", "--format=posix", str(object_path)],
        f"symbol listing for {object_path}",
    )
    symbols = set()
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 2:
            symbols.add((fields[0], fields[1]))
    if not symbols:
        raise OverlayError(f"object has no externally defined symbols: {object_path}")
    return symbols


def object_machine(objdump, object_path):
    output = run_tool([objdump, "-f", str(object_path)], f"object header for {object_path}")
    file_format = re.search(r"(?m)^.*\bfile format\s+(\S+)\s*$", output)
    architecture = re.search(r"(?m)^\s*architecture:\s*([^,\r\n]+)", output)
    if file_format is None or architecture is None:
        raise OverlayError(f"could not determine object format and architecture: {object_path}")
    return file_format.group(1).lower(), architecture.group(1).strip().lower()


def validate_replacement(ar, nm, objdump, archive_path, replacement, temp_directory):
    if not archive_path.is_file():
        raise OverlayError(f"library archive does not exist: {archive_path}")
    members = archive_members(ar, archive_path)
    if members.count(replacement.member) != 1:
        raise OverlayError(
            f"expected one {replacement.member} member in {archive_path}; "
            f"found {members.count(replacement.member)}"
        )
    native_member_path = temp_directory / f"native-{replacement.archive}-{replacement.member}"
    extract_member(ar, archive_path, replacement.member, native_member_path)

    native_machine = object_machine(objdump, native_member_path)
    candidate_machine = object_machine(objdump, replacement.object_path)
    if candidate_machine != native_machine:
        raise OverlayError(
            f"object format mismatch for {replacement.archive}({replacement.member}): "
            f"native={native_machine}, candidate={candidate_machine}"
        )

    native_symbols = symbol_exports(nm, native_member_path)
    candidate_symbols = symbol_exports(nm, replacement.object_path)
    if candidate_symbols != native_symbols:
        missing = sorted(native_symbols - candidate_symbols)
        extra = sorted(candidate_symbols - native_symbols)
        raise OverlayError(
            f"export mismatch for {replacement.archive}({replacement.member}); "
            f"missing={missing}, extra={extra}"
        )
    return native_symbols


def stage_overlay(source_directory, output_directory, replacements, ar, nm, objdump):
    try:
        source_directory = source_directory.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise OverlayError(f"cannot resolve source library directory: {error}") from error
    if not source_directory.is_dir():
        raise OverlayError(f"source library directory is not a directory: {source_directory}")

    output_directory = output_directory.resolve()
    try:
        output_directory.relative_to(source_directory)
    except ValueError:
        pass
    else:
        raise OverlayError("output library directory must not be inside the source directory")
    if output_directory.exists() or output_directory.is_symlink():
        raise OverlayError(f"output library directory already exists: {output_directory}")

    archive_names = {item.archive for item in replacements}
    for archive_name in archive_names:
        if not (source_directory / archive_name).is_file():
            raise OverlayError(f"library archive does not exist: {source_directory / archive_name}")

    with tempfile.TemporaryDirectory(prefix="c2fb-archive-validation-") as temp_name:
        temp_directory = Path(temp_name)
        for replacement in replacements:
            validate_replacement(
                ar, nm, objdump, source_directory / replacement.archive,
                replacement, temp_directory,
            )

        output_parent = output_directory.parent
        output_parent.mkdir(parents=True, exist_ok=True)
        stage_directory = Path(tempfile.mkdtemp(prefix=".c2fb-overlay-", dir=output_parent))
        try:
            for item in source_directory.iterdir():
                destination = stage_directory / item.name
                if item.name in archive_names:
                    shutil.copy2(item, destination)
                else:
                    destination.symlink_to(item.resolve(strict=True),
                                           target_is_directory=item.is_dir())

            replacements_by_archive = {}
            for replacement in replacements:
                replacements_by_archive.setdefault(replacement.archive, []).append(
                    replacement
                )

            for archive_name, archive_replacements in replacements_by_archive.items():
                archive_path = stage_directory / archive_name
                member_directory = temp_directory / f"replacement-{archive_name}"
                member_directory.mkdir()
                for replacement in archive_replacements:
                    shutil.copy2(
                        replacement.object_path,
                        member_directory / replacement.member,
                    )

                # Reindex once after updating all selected members. Reindexing
                # the whole archive for every object makes large library sweeps
                # needlessly slow.
                run_tool(
                    [ar, "r", str(archive_path),
                     *(replacement.member for replacement in archive_replacements)],
                    f"replacements in {archive_name}", cwd=member_directory,
                )
                run_tool([ar, "s", str(archive_path)],
                         f"symbol index update for {archive_name}")

                # Export and machine checks were completed before staging. Verify
                # that the archive tool installed each exact candidate object.
                # Byte equality also confirms its symbol table and relocations.
                member_names = [
                    replacement.member for replacement in archive_replacements
                ]
                staged_member_names = archive_members(ar, archive_path)
                for member in member_names:
                    if staged_member_names.count(member) != 1:
                        raise OverlayError(
                            f"expected one {member} member after update in {archive_name}; "
                            f"found {staged_member_names.count(member)}"
                        )
                final_directory = temp_directory / f"final-{archive_name}"
                final_directory.mkdir()
                for replacement in archive_replacements:
                    final_member_path = final_directory / replacement.member
                    extract_member(
                        ar, archive_path, replacement.member, final_member_path
                    )
                    if final_member_path.read_bytes() != replacement.object_path.read_bytes():
                        raise OverlayError(
                            f"archive update did not install {archive_name}({replacement.member})"
                        )

            os.rename(stage_directory, output_directory)
        except Exception:
            shutil.rmtree(stage_directory, ignore_errors=True)
            raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_library_dir", type=Path)
    parser.add_argument("output_library_dir", type=Path)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--ar", default="ar", help="archive utility")
    parser.add_argument("--nm", default="nm", help="symbol utility")
    parser.add_argument("--objdump", default="objdump", help="object metadata utility")
    args = parser.parse_args(argv)

    try:
        replacements = load_replacements(args.manifest.resolve())
        stage_overlay(
            args.source_library_dir, args.output_library_dir, replacements,
            args.ar, args.nm, args.objdump,
        )
    except OverlayError as error:
        print(f"C2FB archive overlay failed: {error}", file=sys.stderr)
        return 1

    print(f"staged {len(replacements)} symbol- and machine-checked archive member(s) in {args.output_library_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

# end of fbc_archive_overlay.py
