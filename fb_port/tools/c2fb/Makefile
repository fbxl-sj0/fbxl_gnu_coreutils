# SQLite FreeBASIC port tools
# File: Makefile
# Build C2FB and the standalone frontend for its API-table adapter.
# This file does not build the SQLite engine.

FBC ?= fbc
CC ?= cc
PYTHON ?= python3
TARGET ?= build/c2fb
API_ROUTINES_TARGET ?= build/api_routines
CANDIDATE_DIR ?= build/candidates
SQLITE_EXPR_CANDIDATE_DIR ?= $(CANDIDATE_DIR)/sqlite-expr-source-unit
SQLITE_EXPR_UNIT_MANIFEST ?= profiles/sqlite-expr-source-unit-linux-x86_64-units.json
THREADSAFE ?= 1
FB_SOURCE_DIR ?= ../../fb_src
SQLITE_SOURCE_DIR ?= ../..
FBC_SOURCE_DIR ?=
FBFROG_TESTS ?=

# Any C2FB include module change must rebuild the composed converter.
C2FB_MODULES := $(wildcard c2fb_*.bi)

.PHONY: all converter api-routines test check-candidates check-procedures \
	sqlite-expr-candidates check-sqlite-expr-candidates check-freebasic-sfx \
	check-freebasic-rtlib check-freebasic-gfx check-freebasic-gfx3 \
	check-fbfrog-parity report-library-coverage clean

all: converter api-routines

converter: $(TARGET)

$(TARGET): c2fb.bas $(C2FB_MODULES)
	mkdir -p $(dir $@)
	$(FBC) -w all -x $@ $<

$(API_ROUTINES_TARGET): api_routines.bas c2fb_api_routines.bi c2fb_file_input.bi c2fb_output.bi c2fb_generated_file_output.bi c2fb_csv_output.bi c2fb_model.bi c2fb_limits.bi
	mkdir -p $(dir $@)
	$(FBC) -w all -x $@ $<

api-routines: $(API_ROUTINES_TARGET)

sqlite-expr-candidates: $(TARGET)
	mkdir -p '$(SQLITE_EXPR_CANDIDATE_DIR)'
	$(PYTHON) c2fb_source_unit.py '$(abspath $(SQLITE_SOURCE_DIR))/src' \
		'$(abspath $(SQLITE_EXPR_CANDIDATE_DIR))' --tree --source-pattern=expr.c \
		--converter '$(abspath $(TARGET))' --compiler '$(CC)' --include-header-types \
		--fb-source-directory '$(abspath $(FB_SOURCE_DIR))' \
		--unit-manifest '$(abspath $(SQLITE_EXPR_UNIT_MANIFEST))' \
		--header-compiler-option='-I$(abspath $(SQLITE_SOURCE_DIR))/src' \
		--body-compiler-option='-I$(abspath $(SQLITE_SOURCE_DIR))/src' \
		--header-compiler-option='-I$(abspath $(SQLITE_SOURCE_DIR))' \
		--body-compiler-option='-I$(abspath $(SQLITE_SOURCE_DIR))' \
		--header-compiler-option='-DSQLITE_THREADSAFE=$(THREADSAFE)' \
		--body-compiler-option='-DSQLITE_THREADSAFE=$(THREADSAFE)'

check-sqlite-expr-candidates: sqlite-expr-candidates
	$(PYTHON) check_candidates.py '$(abspath $(SQLITE_EXPR_CANDIDATE_DIR))' \
		--recursive --fb-source '$(abspath $(FB_SOURCE_DIR))' --fbc '$(FBC)' \
		--threadsafe '$(THREADSAFE)'

# Validate FreeBASIC SFX modules and the C2FB root-source sweep in temp output.
check-freebasic-sfx: $(TARGET)
	$(PYTHON) tests/test_freebasic_sfx.py --converter '$(abspath $(TARGET))' \
		--fbc '$(FBC)' --cc '$(CC)' \
		--source-directory '$(FBC_SOURCE_DIR)' \
		--profile-directory '$(abspath profiles)'

# Validate integrated RTLIB wrappers and the C2FB candidates they replace.
check-freebasic-rtlib: $(TARGET)
	$(PYTHON) tests/test_freebasic_rtlib.py --converter '$(abspath $(TARGET))' \
		--fbc '$(FBC)' --cc '$(CC)' \
		--source-directory '$(FBC_SOURCE_DIR)' \
		--profile-directory '$(abspath profiles)'

# Validate a GFXLIB2 body candidate against its C behavior on Linux x86-64.
check-freebasic-gfx: $(TARGET)
	$(PYTHON) tests/test_freebasic_gfx.py --converter '$(abspath $(TARGET))' \
		--fbc '$(FBC)' --cc '$(CC)' \
		--source-directory '$(FBC_SOURCE_DIR)' \
		--profile-directory '$(abspath profiles)'
	$(PYTHON) tests/test_freebasic_gfx_png.py --converter '$(abspath $(TARGET))' \
		--fbc '$(FBC)' --cc '$(CC)' \
		--source-directory '$(FBC_SOURCE_DIR)' \
		--profile-directory '$(abspath profiles)'
	$(PYTHON) tests/test_freebasic_gfx_palette.py --converter '$(abspath $(TARGET))' \
		--fbc '$(FBC)' --cc '$(CC)' \
		--source-directory '$(FBC_SOURCE_DIR)' \
		--profile-directory '$(abspath profiles)'
	$(PYTHON) tests/test_freebasic_gfx_palette_mutation.py --converter '$(abspath $(TARGET))' \
		--fbc '$(FBC)' --cc '$(CC)' \
		--source-directory '$(FBC_SOURCE_DIR)' \
		--profile-directory '$(abspath profiles)'
	$(PYTHON) tests/test_freebasic_gfx_vgaemu.py --converter '$(abspath $(TARGET))' \
		--fbc '$(FBC)' --cc '$(CC)' \
		--source-directory '$(FBC_SOURCE_DIR)' \
		--profile-directory '$(abspath profiles)'
	$(PYTHON) tests/test_freebasic_gfx_screeninfo.py --converter '$(abspath $(TARGET))' \
		--fbc '$(FBC)' --cc '$(CC)' \
		--source-directory '$(FBC_SOURCE_DIR)' \
		--profile-directory '$(abspath profiles)'

# Validate a GFXLIB3 platform logger candidate and its reviewed Basic port.
check-freebasic-gfx3: $(TARGET)
	$(PYTHON) tests/test_freebasic_gfx3.py --converter '$(abspath $(TARGET))' \
		--fbc '$(FBC)' --cc '$(CC)' \
		--source-directory '$(FBC_SOURCE_DIR)' \
		--profile-directory '$(abspath profiles)'

# Compare generic C2FB bindings, body candidates, and record layouts against
# an external FBFrog checkout without copying or modifying its fixtures.
check-fbfrog-parity: $(TARGET)
	@test -n '$(strip $(FBFROG_TESTS))' || { \
		echo 'ERROR: set FBFROG_TESTS to the FBFrog tests directory'; exit 1; \
	}
	$(PYTHON) audit_fbfrog.py --converter '$(abspath $(TARGET))' \
		--fbfrog-tests '$(abspath $(FBFROG_TESTS))' --cc '$(CC)' \
		--fbc '$(FBC)' --scope declarations --compile-bindings \
		--compile-body-candidates --strict
	$(PYTHON) audit_fbfrog.py --converter '$(abspath $(TARGET))' \
		--fbfrog-tests '$(abspath $(FBFROG_TESTS))' --cc '$(CC)' \
		--fbc '$(FBC)' --scope macros --compile-bindings \
		--compare-macro-values --strict
	$(PYTHON) audit_fbfrog.py --converter '$(abspath $(TARGET))' \
		--fbfrog-tests '$(abspath $(FBFROG_TESTS))' --cc '$(CC)' \
		--fbc '$(FBC)' --scope declarations --compile-bindings \
		--compare-record-layouts --fail-on-c2fb-layout-mismatch

# Report only modules selected by the current FBC Make source graph.
report-library-coverage:
	@test -n '$(strip $(FBC_SOURCE_DIR))' || { \
		echo 'ERROR: set FBC_SOURCE_DIR to the FBC src directory'; exit 1; \
	}
	$(PYTHON) report_fbc_library_coverage.py \
		--fbc-root '$(abspath $(FBC_SOURCE_DIR))/..' --fail-on-c2fb-peer

test: $(TARGET)
	$(PYTHON) tests/test_library_coverage.py
	$(PYTHON) tests/test_fbc_archive_overlay.py --cc '$(CC)'
	$(PYTHON) tests/test_audit_fbfrog.py
	$(PYTHON) tests/test_c2fb.py --converter '$(abspath $(TARGET))' --fbc '$(FBC)' --cc '$(CC)' \
		--sqlite-source-directory '$(abspath $(SQLITE_SOURCE_DIR))' \
		$(if $(strip $(FBC_SOURCE_DIR)),--fbc-source-directory '$(abspath $(FBC_SOURCE_DIR))',)
	$(PYTHON) tests/test_coreutils_c2fb_regressions.py \
		--converter '$(abspath $(TARGET))' --fbc '$(FBC)' --cc '$(CC)'

check-candidates:
	$(PYTHON) check_candidates.py '$(CANDIDATE_DIR)' --recursive --fb-source '$(FB_SOURCE_DIR)' --fbc '$(FBC)' --threadsafe '$(THREADSAFE)'

check-procedures:
	$(PYTHON) check_candidates.py '$(CANDIDATE_DIR)' --recursive --fb-source '$(FB_SOURCE_DIR)' --fbc '$(FBC)' --threadsafe '$(THREADSAFE)' --per-procedure

clean:
	rm -rf build

# end of fb_tools/c2fb/Makefile
