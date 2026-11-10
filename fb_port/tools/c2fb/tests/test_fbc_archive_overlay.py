#!/usr/bin/env python3
"""
Project: C2FB FreeBASIC port tools
File: test_fbc_archive_overlay.py
Purpose: Test isolated archive replacement and exported-symbol guards.
Responsibilities: Verify symbol, machine, archive-member, and source-preservation
checks using small compiled objects.
This file intentionally does NOT contain: FreeBASIC source conversion or FBC tests.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


OVERLAY_TOOL = Path(__file__).resolve().parents[1] / "fbc_archive_overlay.py"


def run(command, cwd=None):
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    if result.returncode:
        raise AssertionError(
            f"Command failed: {shlex.join(map(str, command))}\n"
            f"{result.stdout}{result.stderr}"
        )
    return result.stdout


class ArchiveOverlayTests(unittest.TestCase):
    compiler = "cc"

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="c2fb-archive-overlay-test-")
        self.root = Path(self.temporary.name)
        self.source_library = self.root / "native-library"
        self.source_library.mkdir()
        self.output_library = self.root / "overlay-library"
        self.cc = shlex.split(self.compiler)
        self.ar = shutil.which(os.environ.get("AR", "ar")) or os.environ.get("AR", "ar")
        self.nm = shutil.which(os.environ.get("NM", "nm")) or os.environ.get("NM", "nm")
        self.objdump = shutil.which(os.environ.get("OBJDUMP", "objdump")) or os.environ.get("OBJDUMP", "objdump")

        native_source = self.root / "native.c"
        native_source.write_text("int fb_TestValue(void) { return 1; }\n", encoding="utf-8")
        native_object = self.root / "native.o"
        run(self.cc + ["-c", str(native_source), "-o", str(native_object)])
        self.native_archive = self.source_library / "libfb.a"
        run([self.ar, "rcs", str(self.native_archive), str(native_object)])
        (self.source_library / "libfbgfx.a").write_bytes(b"unmodified library placeholder\n")

        translated_source = self.root / "translated.c"
        translated_source.write_text("int fb_TestValue(void) { return 2; }\n", encoding="utf-8")
        self.translated_object = self.root / "translated.o"
        run(self.cc + ["-c", str(translated_source), "-o", str(self.translated_object)])
        self.manifest = self.root / "replacements.json"
        self.write_manifest(self.translated_object)

    def tearDown(self):
        self.temporary.cleanup()

    def write_manifest(self, object_path, expected_hash=None):
        record = {
            "archive": "libfb.a",
            "member": "native.o",
            "object": str(object_path),
        }
        if expected_hash is not None:
            record["sha256"] = expected_hash
        self.manifest.write_text(
            json.dumps({"version": 1, "members": [record]}, indent=2) + "\n",
            encoding="utf-8",
        )

    def run_overlay(self, output_directory=None):
        output_directory = output_directory or self.output_library
        return subprocess.run(
            [
                sys.executable, str(OVERLAY_TOOL),
                str(self.source_library), str(output_directory), str(self.manifest),
                "--ar", self.ar, "--nm", self.nm, "--objdump", self.objdump,
            ],
            capture_output=True,
            text=True,
        )

    def test_replaces_the_named_member_and_keeps_other_files_linked(self):
        native_hash = hashlib.sha256(self.native_archive.read_bytes()).hexdigest()
        self.write_manifest(
            self.translated_object,
            hashlib.sha256(self.translated_object.read_bytes()).hexdigest(),
        )
        result = self.run_overlay()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        overlay_archive = self.output_library / "libfb.a"
        members = run([self.ar, "t", str(overlay_archive)]).splitlines()
        self.assertEqual(members.count("native.o"), 1)
        self.assertNotIn("translated.o", members)
        extracted = subprocess.run(
            [self.ar, "p", str(overlay_archive), "native.o"],
            check=True, capture_output=True,
        ).stdout
        self.assertEqual(extracted, self.translated_object.read_bytes())
        self.assertTrue((self.output_library / "libfbgfx.a").is_symlink())
        self.assertEqual(
            hashlib.sha256(self.native_archive.read_bytes()).hexdigest(),
            native_hash,
        )

        main_source = self.root / "main.c"
        main_source.write_text(
            "extern int fb_TestValue(void);\n"
            "int main(void) { return fb_TestValue() == 2 ? 0 : 1; }\n",
            encoding="utf-8",
        )
        overlay_executable = self.root / "overlay-test"
        run(self.cc + [
            str(main_source), "-L" + str(self.output_library), "-lfb",
            "-o", str(overlay_executable),
        ])
        run([str(overlay_executable)])

        native_executable = self.root / "native-test"
        run(self.cc + [
            str(main_source), "-L" + str(self.source_library), "-lfb",
            "-o", str(native_executable),
        ])
        self.assertNotEqual(subprocess.run([str(native_executable)]).returncode, 0)

    def test_batches_multiple_members_from_one_archive(self):
        second_native_source = self.root / "second-native.c"
        second_native_source.write_text(
            "int fb_SecondValue(void) { return 3; }\n", encoding="utf-8")
        second_native_object = self.root / "second-native.o"
        run(self.cc + ["-c", str(second_native_source), "-o",
                       str(second_native_object)])
        run([self.ar, "r", str(self.native_archive), str(second_native_object)])

        second_translated_source = self.root / "second-translated.c"
        second_translated_source.write_text(
            "int fb_SecondValue(void) { return 4; }\n", encoding="utf-8")
        second_translated_object = self.root / "second-translated.o"
        run(self.cc + ["-c", str(second_translated_source), "-o",
                       str(second_translated_object)])

        replacements = [
            {
                "archive": "libfb.a",
                "member": "native.o",
                "object": str(self.translated_object),
                "sha256": hashlib.sha256(self.translated_object.read_bytes()).hexdigest(),
            },
            {
                "archive": "libfb.a",
                "member": "second-native.o",
                "object": str(second_translated_object),
                "sha256": hashlib.sha256(second_translated_object.read_bytes()).hexdigest(),
            },
        ]
        self.manifest.write_text(
            json.dumps({"version": 1, "members": replacements}, indent=2) + "\n",
            encoding="utf-8",
        )
        native_hash = hashlib.sha256(self.native_archive.read_bytes()).hexdigest()
        result = self.run_overlay()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        overlay_archive = self.output_library / "libfb.a"
        members = run([self.ar, "t", str(overlay_archive)]).splitlines()
        self.assertEqual(members.count("native.o"), 1)
        self.assertEqual(members.count("second-native.o"), 1)
        for member, candidate in (
            ("native.o", self.translated_object),
            ("second-native.o", second_translated_object),
        ):
            extracted = subprocess.run(
                [self.ar, "p", str(overlay_archive), member],
                check=True, capture_output=True,
            ).stdout
            self.assertEqual(extracted, candidate.read_bytes())

        main_source = self.root / "main-batched.c"
        main_source.write_text(
            "extern int fb_TestValue(void);\n"
            "extern int fb_SecondValue(void);\n"
            "int main(void) { return fb_TestValue() + fb_SecondValue() == 6 ? 0 : 1; }\n",
            encoding="utf-8",
        )
        executable = self.root / "overlay-batched-test"
        run(self.cc + [
            str(main_source), "-L" + str(self.output_library), "-lfb",
            "-o", str(executable),
        ])
        run([str(executable)])
        self.assertEqual(
            hashlib.sha256(self.native_archive.read_bytes()).hexdigest(),
            native_hash,
        )

    def test_rejects_export_mismatch_without_publishing(self):
        mismatch_source = self.root / "mismatch.c"
        mismatch_source.write_text("int fb_OtherValue(void) { return 2; }\n", encoding="utf-8")
        mismatch_object = self.root / "mismatch.o"
        run(self.cc + ["-c", str(mismatch_source), "-o", str(mismatch_object)])
        self.write_manifest(mismatch_object)
        original_hash = hashlib.sha256(self.native_archive.read_bytes()).hexdigest()
        result = self.run_overlay()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("export mismatch", result.stderr)
        self.assertFalse(self.output_library.exists())
        self.assertEqual(
            hashlib.sha256(self.native_archive.read_bytes()).hexdigest(),
            original_hash,
        )

    def test_rejects_machine_mismatch_when_i386_objects_are_available(self):
        probe_object = self.root / "i386-probe.o"
        probe = subprocess.run(
            self.cc + ["-m32", "-c", str(self.root / "translated.c"),
                       "-o", str(probe_object)],
            capture_output=True,
            text=True,
        )
        if probe.returncode != 0:
            self.skipTest("C compiler has no i386 object support")
        self.write_manifest(probe_object)
        result = self.run_overlay()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("object format mismatch", result.stderr)
        self.assertFalse(self.output_library.exists())


if __name__ == "__main__":
    argument_parser = argparse.ArgumentParser()
    argument_parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    args = argument_parser.parse_args()
    ArchiveOverlayTests.compiler = args.cc
    unittest.main(argv=[sys.argv[0]])

# end of test_fbc_archive_overlay.py
