#!/usr/bin/env python3
'''
Project: C2FB FreeBASIC GFXLIB2 tests
File: test_freebasic_gfx_screeninfo.py
Purpose: Compare translated screen-info ABI wrappers with their C implementation.
Responsibilities: Test graphics and no-graphics results, string handling, and wrappers.
This file intentionally does NOT contain: Screen mode or driver selection code.
'''

import argparse
from pathlib import Path
import platform
import shlex
import subprocess
import sys
import tempfile

TEST_DIRECTORY = Path(__file__).resolve().parent
sys.path.insert(0, str(TEST_DIRECTORY))

import test_freebasic_gfx as gfx_tests


def run(command, **options):
    result = subprocess.run(
        command, capture_output=True, text=True, **options
    )
    if result.returncode:
        raise RuntimeError(
            f"Command failed with status {result.returncode}: "
            f"{shlex.join(map(str, command))}\n"
            f"{result.stdout}{result.stderr}"
        )
    return result.stdout


PROBE_SOURCE = r'''#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fb_gfx.h"

void fb_GfxScreenInfoC(ssize_t *, ssize_t *, ssize_t *, ssize_t *, ssize_t *, ssize_t *, FBSTRING *);
void fb_GfxScreenInfo32C(int *, int *, int *, int *, int *, int *, FBSTRING *);
void fb_GfxScreenInfo64C(long long *, long long *, long long *, long long *, long long *, long long *, FBSTRING *);

FBGFX *__fb_gfx;
static FBGFX graphics_state;
static GFXDRIVER graphics_driver;
static int pending_resize_count;
static int fallback_info_count;

void fb_GraphicsLock(void) {}
void fb_GraphicsUnlock(void) {}

int fb_hApplyPendingResize(void)
{
    pending_resize_count++;
    return 0;
}

void fb_hScreenInfo(ssize_t *width, ssize_t *height, ssize_t *depth,
    ssize_t *refresh)
{
    fallback_info_count++;
    *width = 1024;
    *height = 768;
    *depth = 32;
    *refresh = 60;
}

int fb_hStrDelTemp(FBSTRING *string)
{
    return string != NULL;
}

FBSTRING *fb_hStrRealloc(FBSTRING *string, ssize_t size, int preserve)
{
    char *new_data;
    (void)preserve;
    if (size < 0) return NULL;
    new_data = (char *)realloc(string->data, (size_t)size + 1u);
    if (new_data == NULL) return NULL;
    string->data = new_data;
    string->len = size;
    string->size = size;
    return string;
}

static void configure_graphics(int with_graphics)
{
    memset(&graphics_state, 0, sizeof(graphics_state));
    memset(&graphics_driver, 0, sizeof(graphics_driver));
    graphics_driver.name = "Probe VGA driver";
    graphics_state.driver = &graphics_driver;
    graphics_state.w = 640;
    graphics_state.h = 480;
    graphics_state.depth = 8;
    graphics_state.bpp = 1;
    graphics_state.pitch = 640;
    graphics_state.refresh_rate = 75;
    __fb_gfx = with_graphics ? &graphics_state : NULL;
    pending_resize_count = 0;
    fallback_info_count = 0;
}

static int initialize_string(FBSTRING *string)
{
    const char initial[] = "old driver value";
    string->data = (char *)malloc(sizeof(initial));
    if (string->data == NULL) return 1;
    memcpy(string->data, initial, sizeof(initial));
    string->len = (ssize_t)(sizeof(initial) - 1u);
    string->size = (ssize_t)(sizeof(initial) - 1u);
    return 0;
}

static int compare_string(const FBSTRING *left, const FBSTRING *right)
{
    if (left->len != right->len || left->size != right->size) return 1;
    if (left->data == NULL || right->data == NULL) return 2;
    if (memcmp(left->data, right->data, (size_t)left->len + 1u) != 0) return 3;
    return 0;
}

static int compare_native_info(int with_graphics)
{
    ssize_t c_values[6] = { -1, -2, -3, -4, -5, -6 };
    ssize_t fb_values[6] = { -1, -2, -3, -4, -5, -6 };
    FBSTRING c_string, fb_string;
    int c_pending, c_fallback, fb_pending, fb_fallback, result;
    if (initialize_string(&c_string) || initialize_string(&fb_string)) return 10;
    configure_graphics(with_graphics);
    fb_GfxScreenInfoC(&c_values[0], &c_values[1], &c_values[2],
        &c_values[3], &c_values[4], &c_values[5], &c_string);
    c_pending = pending_resize_count;
    c_fallback = fallback_info_count;
    configure_graphics(with_graphics);
    fb_GfxScreenInfo(&fb_values[0], &fb_values[1], &fb_values[2],
        &fb_values[3], &fb_values[4], &fb_values[5], &fb_string);
    fb_pending = pending_resize_count;
    fb_fallback = fallback_info_count;
    result = memcmp(c_values, fb_values, sizeof(c_values)) != 0 ? 11 : 0;
    if (!result && (c_pending != fb_pending || c_fallback != fb_fallback)) result = 12;
    if (!result) {
        int string_result = compare_string(&c_string, &fb_string);
        if (string_result) result = string_result + 20;
    }
    if (!result && with_graphics && strcmp(fb_string.data, "Probe VGA driver") != 0) result = 24;
    if (!result && !with_graphics && strcmp(fb_string.data, "") != 0) result = 25;
    free(c_string.data);
    free(fb_string.data);
    return result;
}

static int compare_32_info(int with_graphics)
{
    int c_values[6] = { -1, -2, -3, -4, -5, -6 };
    int fb_values[6] = { -1, -2, -3, -4, -5, -6 };
    FBSTRING c_string, fb_string;
    int result;
    if (initialize_string(&c_string) || initialize_string(&fb_string)) return 30;
    configure_graphics(with_graphics);
    fb_GfxScreenInfo32C(&c_values[0], &c_values[1], &c_values[2],
        &c_values[3], &c_values[4], &c_values[5], &c_string);
    configure_graphics(with_graphics);
    fb_GfxScreenInfo32(&fb_values[0], &fb_values[1], &fb_values[2],
        &fb_values[3], &fb_values[4], &fb_values[5], &fb_string);
    result = memcmp(c_values, fb_values, sizeof(c_values)) != 0 ? 31 : 0;
    if (!result) {
        int string_result = compare_string(&c_string, &fb_string);
        if (string_result) result = string_result + 32;
    }
    free(c_string.data);
    free(fb_string.data);
    return result;
}

static int compare_64_info(int with_graphics)
{
    long long c_values[6] = { -1, -2, -3, -4, -5, -6 };
    long long fb_values[6] = { -1, -2, -3, -4, -5, -6 };
    FBSTRING c_string, fb_string;
    int result;
    if (initialize_string(&c_string) || initialize_string(&fb_string)) return 40;
    configure_graphics(with_graphics);
    fb_GfxScreenInfo64C(&c_values[0], &c_values[1], &c_values[2],
        &c_values[3], &c_values[4], &c_values[5], &c_string);
    configure_graphics(with_graphics);
    fb_GfxScreenInfo64(&fb_values[0], &fb_values[1], &fb_values[2],
        &fb_values[3], &fb_values[4], &fb_values[5], &fb_string);
    result = memcmp(c_values, fb_values, sizeof(c_values)) != 0 ? 41 : 0;
    if (!result) {
        int string_result = compare_string(&c_string, &fb_string);
        if (string_result) result = string_result + 42;
    }
    free(c_string.data);
    free(fb_string.data);
    return result;
}

int main(void)
{
    int result;
    result = compare_native_info(0); if (result) return result;
    result = compare_native_info(1); if (result) return result;
    result = compare_32_info(0); if (result) return result;
    result = compare_32_info(1); if (result) return result;
    result = compare_64_info(0); if (result) return result;
    result = compare_64_info(1); if (result) return result;
    puts("GFX_SCREENINFO_C2FB_PARITY_PASS");
    return 0;
}
'''


def check_screeninfo(fbc, cc, converter, source_root, profile_directory, work):
    helpers = gfx_tests.load_c2fb_tests()
    context, header_profile = gfx_tests.build_gfx_binding(
        converter, cc, source_root, profile_directory, work,
    )
    body_profile = profile_directory / "freebasic-linux-glibc-x86_64-body.rsp"
    candidate = work / "gfx_screeninfo_candidates.bas"
    summary = helpers.run_freebasic_gfx_source_unit(
        converter, fbc, cc, source_root, "core/gfx_screeninfo.c", candidate,
        context, header_profile, body_profile,
        extra_body_options=("--rename-proc-prefix=c2fbGfx_",),
    )
    if "translated 3 simple functions; skipped 0" not in summary:
        raise AssertionError(summary)

    reference_source = work / "gfx_screeninfo_c_reference.c"
    reference_source.write_text(
        "#define fb_GfxScreenInfo fb_GfxScreenInfoC\n"
        "#define fb_GfxScreenInfo32 fb_GfxScreenInfo32C\n"
        "#define fb_GfxScreenInfo64 fb_GfxScreenInfo64C\n"
        '#include "core/gfx_screeninfo.c"\n',
        encoding="utf-8",
    )
    support_source = work / "gfx_screeninfo_probe.c"
    support_source.write_text(PROBE_SOURCE, encoding="utf-8")
    compile_flags = [
        "-std=c99", "-DFB_NO_GFXLIB", "-DENABLE_MT", "-include",
        "sys/types.h", "-I", str(source_root / "rtlib"),
        "-I", str(source_root / "gfxlib2"),
        "-I", str(source_root / "gfxlib2/core"),
    ]
    reference_object = work / "gfx_screeninfo_c_reference.o"
    run(cc + compile_flags + [
        "-c", str(reference_source), "-o", str(reference_object),
    ], cwd=work)
    support_object = work / "gfx_screeninfo_probe.o"
    run(cc + compile_flags + [
        "-c", str(support_source), "-o", str(support_object),
    ], cwd=work)

    integrated_source = source_root / "gfxlib2/arch/linux/x86_64/gfx_screeninfo.bas"
    integrated_object = work / "gfx_screeninfo_integrated_basic.o"
    run(fbc + [
        "-mt", "-w", "all", "-d", "FB_NO_GFXLIB",
        "-i", str(source_root.parent / "inc"),
        "-i", str(integrated_source.parent),
        "-c", str(integrated_source), "-o", str(integrated_object),
    ], cwd=work)

    for name, module_object in (
        ("candidate", candidate.with_suffix(".o")),
        ("integrated_basic", integrated_object),
    ):
        executable = work / ("gfx_screeninfo_" + name)
        run(cc + [
            str(support_object), str(reference_object),
            str(module_object), "-o", str(executable),
        ], cwd=work)
        output = run([str(executable)], cwd=work)
        if "GFX_SCREENINFO_C2FB_PARITY_PASS" not in output:
            raise AssertionError(output)
    print(
        "GFXLIB2 screen info: C2FB candidate and Basic port match C for "
        "graphics/no-graphics results, driver strings, and 32/64-bit wrappers"
    )


def main():
    parser = argparse.ArgumentParser(
        description="Compare C2FB GFXLIB2 screen-info routines with C."
    )
    parser.add_argument("--converter", required=True)
    parser.add_argument("--fbc", default="fbc")
    parser.add_argument("--cc", default="cc")
    parser.add_argument("--source-directory", required=True)
    parser.add_argument(
        "--profile-directory",
        default=str(Path(__file__).resolve().parents[1] / "profiles"),
    )
    args = parser.parse_args()
    if platform.system() != "Linux" or platform.machine().lower() not in (
        "x86_64", "amd64",
    ):
        parser.error("the current GFX ABI probe requires Linux x86-64")
    fbc = shlex.split(args.fbc)
    cc = shlex.split(args.cc)
    if not fbc or not cc:
        parser.error("--fbc and --cc must each contain a command")
    source_root = Path(args.source_directory).resolve()
    source = source_root / "gfxlib2/core/gfx_screeninfo.c"
    module = source_root / "gfxlib2/arch/linux/x86_64/gfx_screeninfo.bas"
    if not source.is_file() or not module.is_file():
        parser.error("GFXLIB2 screen-info C source or Basic port is missing")
    gfx_tests.check_gfx_source_graph(source_root)
    with tempfile.TemporaryDirectory(prefix="c2fb-freebasic-gfx-screeninfo-") as temp:
        check_screeninfo(
            fbc, cc, str(Path(args.converter).resolve()), source_root,
            Path(args.profile_directory).resolve(), Path(temp),
        )


if __name__ == "__main__":
    main()

# end of test_freebasic_gfx_screeninfo.py
