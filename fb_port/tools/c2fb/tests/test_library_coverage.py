"""
Project: SQLite FreeBASIC port tools
File: test_library_coverage.py
Purpose: Test C2FB library-coverage accounting against a small Make graph.
Responsibilities: Check selected-source denominators, C2FB provenance marks,
  and detection of Basic modules whose C peers remain selected.
This file intentionally does NOT contain: FBC source-graph build logic.
"""

import tempfile
import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from report_fbc_library_coverage import build_report, parse_source_graph


class LibraryCoverageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.source_root = Path(self.temporary.name) / "src"
        self.rtlib = self.source_root / "rtlib"
        self.rtlib.mkdir(parents=True)

        self.translated_c = self.rtlib / "converted.c"
        self.translated_basic = self.rtlib / "converted.bas"
        self.translated_c.write_text("void converted(void) {}\n")
        self.translated_basic.write_text(
            "' C2FB translated from converted.c\n"
        )

        self.manual_c = self.rtlib / "manual.c"
        self.manual_basic = self.rtlib / "manual.bas"
        self.manual_c.write_text("void manual(void) {}\n")
        self.manual_basic.write_text("Sub manual()\nEnd Sub\n")

        self.variables = {
            "RTLIB_SRC": [str(self.translated_basic), str(self.manual_basic)],
            "RTLIB_SRC_FB": [str(self.translated_basic), str(self.manual_basic)],
            "RTLIB_SRC_C": [],
            "GFX_SRC": [],
            "GFX_SRC_FB": [],
            "GFX_SRC_C": [],
            "GFX3_SRC": [],
            "GFX3_SRC_FB": [],
            "GFX3_SRC_C": [],
            "SFX_SRC": [],
            "SFX_SRC_FB": [],
            "SFX_SRC_C": [],
        }

    def test_make_output_is_parsed_by_source_list_kind(self):
        output = "\n".join((
            "RTLIB_SRC := /tmp/src/rtlib/a.c /tmp/src/rtlib/b.bas",
            "RTLIB_SRC_FB := /tmp/src/rtlib/b.bas",
            "RTLIB_SRC_C := /tmp/src/rtlib/a.c",
            "GFX_SRC := /tmp/src/gfxlib2/gfx.c",
            "GFX3_SRC := /tmp/src/gfxlib3/gfx3.c",
            "SFX_SRC := /tmp/src/sfxlib/sfx.c",
        ))
        parsed = parse_source_graph(output)
        self.assertEqual(parsed["RTLIB_SRC"], [
            "/tmp/src/rtlib/a.c", "/tmp/src/rtlib/b.bas",
        ])
        self.assertEqual(parsed["RTLIB_SRC_FB"], ["/tmp/src/rtlib/b.bas"])
        self.assertEqual(parsed["RTLIB_SRC_C"], ["/tmp/src/rtlib/a.c"])

    def test_counts_only_selected_basic_and_c2fb_marked_units(self):
        report = build_report(self.source_root, self.variables)
        rtlib = report["libraries"]["RTLIB"]

        self.assertEqual(rtlib["selected_source_units"], 2)
        self.assertEqual(rtlib["selected_basic_units"], 2)
        self.assertEqual(rtlib["selected_c_units"], 0)
        self.assertEqual(rtlib["c2fb_marked_basic_units"], 1)
        self.assertEqual(rtlib["unmarked_basic_units"], 1)
        self.assertEqual(rtlib["c2fb_basic_units_with_c_peer_selected"], [])
        self.assertEqual(report["totals"]["selected_source_units"], 2)
        self.assertEqual(report["totals"]["c2fb_marked_percent"], 50.0)

    def test_reports_a_selected_c_peer_for_c2fb_basic(self):
        self.variables["RTLIB_SRC"].append(str(self.translated_c))
        self.variables["RTLIB_SRC_C"].append(str(self.translated_c))
        report = build_report(self.source_root, self.variables)

        self.assertEqual(
            report["libraries"]["RTLIB"]["c2fb_basic_units_with_c_peer_selected"],
            ["rtlib/converted.bas"],
        )


if __name__ == "__main__":
    unittest.main()


# end of test_library_coverage.py
