#!/usr/bin/env python3
'''
Project: C2FB FreeBASIC GFXLIB2 tests
File: test_freebasic_gfx_palette_mutation.py
Purpose: Compare translated palette mutation routines with their C implementation.
Responsibilities: Validate helper, driver callback, mode restore, and dirty-line behavior.
This file intentionally does NOT contain: Palette implementation code.
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
#include <math.h>
#include <string.h>
#include "fb_gfx.h"

unsigned int fb_hMakeColorC(int, unsigned int, int, int, int);
unsigned int fb_hFixColorC(int, unsigned int);
void fb_hRestorePaletteC(void);
void fb_hSetPaletteColorRgbC(int, int, int, int);
void fb_hSetPaletteColorC(int, unsigned int);
void fb_GfxPaletteC(int, int, int, int);
void fb_GfxPaletteUsingC(int *);
void fb_GfxPaletteUsing64C(long long *);

#define EVENT_CAPACITY 300
#define DIRTY_CAPACITY 32

typedef struct PALETTE_EVENT {
    int index;
    int red;
    int green;
    int blue;
} PALETTE_EVENT;

typedef struct PALETTE_SNAPSHOT {
    unsigned int palette[256];
    unsigned int device_palette[256];
    unsigned char color_association[256];
    char dirty[DIRTY_CAPACITY];
    int event_count;
    PALETTE_EVENT events[EVENT_CAPACITY];
} PALETTE_SNAPSHOT;

enum PALETTE_OPERATION {
    OP_GFX_PALETTE,
    OP_RESTORE_PALETTE,
    OP_SET_PALETTE_COLOR,
    OP_SET_PALETTE_COLOR_RGB
};

static unsigned char default_palette_data[4][768];
static unsigned int palette_values[256];
static unsigned int device_palette_values[256];
static unsigned char color_association_values[256];
static char dirty_lines[DIRTY_CAPACITY];
static FBGFX graphics_state;
static GFXDRIVER graphics_driver;
static PALETTE_EVENT palette_events[EVENT_CAPACITY];
static int palette_event_count;

const PALETTE __fb_palette[FB_PALETTE_COUNT] = {
    { 2, default_palette_data[0] },
    { 16, default_palette_data[1] },
    { 64, default_palette_data[2] },
    { 256, default_palette_data[3] }
};
FBGFX *__fb_gfx;
void *(*fb_hMemSet)(void *, int, size_t) = memset;

double fb_FIXDouble(double value)
{
    return trunc(value);
}

void fb_GraphicsLock(void) {}
void fb_GraphicsUnlock(void) {}
void fb_GfxLock(void) {}
void fb_GfxUnlock(int start_line, int end_line)
{
    (void)start_line;
    (void)end_line;
}

static void record_palette(int index, int red, int green, int blue)
{
    if (palette_event_count < EVENT_CAPACITY) {
        PALETTE_EVENT *event = &palette_events[palette_event_count];
        event->index = index;
        event->red = red;
        event->green = green;
        event->blue = blue;
    }
    palette_event_count++;
}

static void reset_fixture(int depth, int palette_index, int mode,
    int with_graphics, int with_callback)
{
    unsigned int i, palette_index_byte;
    memset(&graphics_state, 0, sizeof(graphics_state));
    memset(&graphics_driver, 0, sizeof(graphics_driver));
    memset(palette_events, 0, sizeof(palette_events));
    palette_event_count = 0;
    for (i = 0; i < 256u; i++) {
        palette_values[i] = ((i * 0x010305u) ^ 0x00556677u) & 0x00ffffffu;
        device_palette_values[i] = ((i * 0x030507u) ^ 0x00123456u) & 0x00ffffffu;
        color_association_values[i] = (unsigned char)((i * 7u + 3u) & 255u);
    }
    for (palette_index_byte = 0; palette_index_byte < 4u; palette_index_byte++) {
        for (i = 0; i < 768u; i++) {
            default_palette_data[palette_index_byte][i] =
                (unsigned char)((i * 11u + palette_index_byte * 17u + 9u) & 255u);
        }
    }
    for (i = 0; i < DIRTY_CAPACITY; i++)
        dirty_lines[i] = (char)((i * 3u + 1u) & 1u);
    graphics_driver.set_palette = with_callback ? record_palette : NULL;
    graphics_state.depth = depth;
    graphics_state.mode_num = mode;
    graphics_state.h = 11;
    graphics_state.palette = palette_values;
    graphics_state.device_palette = device_palette_values;
    graphics_state.color_association = color_association_values;
    graphics_state.dirty = dirty_lines;
    graphics_state.driver = &graphics_driver;
    graphics_state.default_palette = &__fb_palette[palette_index];
    __fb_gfx = with_graphics ? &graphics_state : NULL;
}

static void capture_snapshot(PALETTE_SNAPSHOT *snapshot)
{
    memcpy(snapshot->palette, palette_values, sizeof(palette_values));
    memcpy(snapshot->device_palette, device_palette_values, sizeof(device_palette_values));
    memcpy(snapshot->color_association, color_association_values,
        sizeof(color_association_values));
    memcpy(snapshot->dirty, dirty_lines, sizeof(dirty_lines));
    snapshot->event_count = palette_event_count;
    memcpy(snapshot->events, palette_events, sizeof(palette_events));
}

static void call_c(enum PALETTE_OPERATION operation,
    int index, int red, int green, int blue)
{
    switch (operation) {
    case OP_GFX_PALETTE:
        fb_GfxPaletteC(index, red, green, blue);
        break;
    case OP_RESTORE_PALETTE:
        fb_hRestorePaletteC();
        break;
    case OP_SET_PALETTE_COLOR:
        fb_hSetPaletteColorC(index, (unsigned int)red);
        break;
    case OP_SET_PALETTE_COLOR_RGB:
        fb_hSetPaletteColorRgbC(index, red, green, blue);
        break;
    }
}

static void call_basic(enum PALETTE_OPERATION operation,
    int index, int red, int green, int blue)
{
    switch (operation) {
    case OP_GFX_PALETTE:
        fb_GfxPalette(index, red, green, blue);
        break;
    case OP_RESTORE_PALETTE:
        fb_hRestorePalette();
        break;
    case OP_SET_PALETTE_COLOR:
        fb_hSetPaletteColor(index, (unsigned int)red);
        break;
    case OP_SET_PALETTE_COLOR_RGB:
        fb_hSetPaletteColorRgb(index, red, green, blue);
        break;
    }
}

static int snapshots_match(const PALETTE_SNAPSHOT *left,
    const PALETTE_SNAPSHOT *right)
{
    if (memcmp(left->palette, right->palette, sizeof(left->palette)) != 0) return 1;
    if (memcmp(left->device_palette, right->device_palette,
        sizeof(left->device_palette)) != 0) return 2;
    if (memcmp(left->color_association, right->color_association,
        sizeof(left->color_association)) != 0) return 3;
    if (memcmp(left->dirty, right->dirty, sizeof(left->dirty)) != 0) return 4;
    if (left->event_count != right->event_count) return 5;
    if (memcmp(left->events, right->events, sizeof(left->events)) != 0) return 6;
    return 0;
}

static int compare_operation(enum PALETTE_OPERATION operation,
    int index, int red, int green, int blue, int depth, int palette_index,
    int mode, int with_graphics, int with_callback)
{
    PALETTE_SNAPSHOT c_snapshot, fb_snapshot;
    reset_fixture(depth, palette_index, mode, with_graphics, with_callback);
    call_c(operation, index, red, green, blue);
    capture_snapshot(&c_snapshot);
    reset_fixture(depth, palette_index, mode, with_graphics, with_callback);
    call_basic(operation, index, red, green, blue);
    capture_snapshot(&fb_snapshot);
    return snapshots_match(&c_snapshot, &fb_snapshot);
}

static int compare_palette_using_32(int depth, int palette_index,
    int mode, int with_graphics, int with_callback)
{
    int data[256];
    PALETTE_SNAPSHOT c_snapshot, fb_snapshot;
    unsigned int i;
    for (i = 0; i < 256u; i++)
        data[i] = (i % 7u == 0u) ? -1 : (int)((i * 0x103u + 0x12345u) & 0x00ffffffu);
    reset_fixture(depth, palette_index, mode, with_graphics, with_callback);
    fb_GfxPaletteUsingC(data);
    capture_snapshot(&c_snapshot);
    reset_fixture(depth, palette_index, mode, with_graphics, with_callback);
    fb_GfxPaletteUsing(data);
    capture_snapshot(&fb_snapshot);
    return snapshots_match(&c_snapshot, &fb_snapshot);
}

static int compare_palette_using_64(int depth, int palette_index,
    int mode, int with_graphics, int with_callback)
{
    long long data[256];
    PALETTE_SNAPSHOT c_snapshot, fb_snapshot;
    unsigned int i;
    for (i = 0; i < 256u; i++)
        data[i] = (i % 9u == 0u) ? -1 : (long long)(i * 0x10101u + 0x654321u);
    reset_fixture(depth, palette_index, mode, with_graphics, with_callback);
    fb_GfxPaletteUsing64C(data);
    capture_snapshot(&c_snapshot);
    reset_fixture(depth, palette_index, mode, with_graphics, with_callback);
    fb_GfxPaletteUsing64(data);
    capture_snapshot(&fb_snapshot);
    return snapshots_match(&c_snapshot, &fb_snapshot);
}

int main(void)
{
    unsigned int c_color, fb_color;
    int result;
    if (fb_hMakeColorC(2, 7u, 0x12, 0x34, 0x56) !=
        fb_hMakeColor(2, 7u, 0x12, 0x34, 0x56)) return 1;
    if (fb_hMakeColorC(4, 7u, 0x12, 0x34, 0x56) !=
        fb_hMakeColor(4, 7u, 0x12, 0x34, 0x56)) return 2;
    c_color = fb_hFixColorC(2, 0x00a1b2c3u);
    fb_color = fb_hFixColor(2, 0x00a1b2c3u);
    if (c_color != fb_color) return 3;
    c_color = fb_hFixColorC(4, 0x00a1b2c3u);
    fb_color = fb_hFixColor(4, 0x00a1b2c3u);
    if (c_color != fb_color) return 4;

    result = compare_operation(OP_GFX_PALETTE, 2, 17, 88, 129,
        4, FB_PALETTE_16, 3, 0, 1);
    if (result) return 10 + result;
    result = compare_operation(OP_GFX_PALETTE, 1, 210, 88, 7,
        16, FB_PALETTE_16, 3, 1, 1);
    if (result) return 20 + result;
    result = compare_operation(OP_GFX_PALETTE, 17, 201, 88, 7,
        4, FB_PALETTE_16, 3, 1, 1);
    if (result) return 30 + result;
    result = compare_operation(OP_GFX_PALETTE, 17, 0x003f2010, -1, -1,
        8, FB_PALETTE_256, 13, 1, 1);
    if (result) return 40 + result;
    result = compare_operation(OP_GFX_PALETTE, 17, 8, -1, -1,
        4, FB_PALETTE_16, 3, 1, 1);
    if (result) return 50 + result;
    result = compare_operation(OP_GFX_PALETTE, -1, 0, 0, 0,
        2, FB_PALETTE_16, 1, 1, 1);
    if (result) return 60 + result;
    result = compare_operation(OP_GFX_PALETTE, -1, 0, 0, 0,
        2, FB_PALETTE_16, 2, 1, 0);
    if (result) return 70 + result;
    result = compare_operation(OP_GFX_PALETTE, -1, 0, 0, 0,
        4, FB_PALETTE_16, 7, 1, 1);
    if (result) return 80 + result;
    result = compare_operation(OP_GFX_PALETTE, -1, 0, 0, 0,
        4, FB_PALETTE_16, 8, 1, 1);
    if (result) return 90 + result;
    result = compare_operation(OP_GFX_PALETTE, -1, 0, 0, 0,
        4, FB_PALETTE_16, 9, 1, 1);
    if (result) return 100 + result;
    result = compare_operation(OP_GFX_PALETTE, -1, 0, 0, 0,
        4, FB_PALETTE_16, 3, 1, 1);
    if (result) return 110 + result;
    result = compare_operation(OP_GFX_PALETTE, -1, 0, 0, 0,
        8, FB_PALETTE_256, 13, 1, 1);
    if (result) return 120 + result;
    result = compare_operation(OP_RESTORE_PALETTE, 0, 0, 0, 0,
        8, FB_PALETTE_256, 13, 1, 1);
    if (result) return 130 + result;
    result = compare_operation(OP_RESTORE_PALETTE, 0, 0, 0, 0,
        8, FB_PALETTE_256, 13, 1, 0);
    if (result) return 140 + result;
    result = compare_operation(OP_SET_PALETTE_COLOR, 17, 8, 0, 0,
        4, FB_PALETTE_16, 3, 1, 1);
    if (result) return 150 + result;
    result = compare_operation(OP_SET_PALETTE_COLOR, 17, 0x003f2010, 0, 0,
        8, FB_PALETTE_256, 13, 1, 1);
    if (result) return 160 + result;
    result = compare_operation(OP_SET_PALETTE_COLOR_RGB, 17, 200, 100, 50,
        4, FB_PALETTE_16, 3, 1, 1);
    if (result) return 170 + result;
    result = compare_palette_using_32(4, FB_PALETTE_16, 3, 0, 1);
    if (result) return 180 + result;
    result = compare_palette_using_32(4, FB_PALETTE_16, 3, 1, 1);
    if (result) return 190 + result;
    result = compare_palette_using_32(16, FB_PALETTE_256, 13, 1, 1);
    if (result) return 200 + result;
    result = compare_palette_using_64(4, FB_PALETTE_16, 3, 1, 0);
    if (result) return 210 + result;
    result = compare_palette_using_64(8, FB_PALETTE_256, 13, 1, 1);
    if (result) return 220 + result;
    puts("GFX_PALETTE_MUTATION_C2FB_PARITY_PASS");
    return 0;
}
'''


def check_palette_mutation(fbc, cc, converter, source_root, profile_directory, work):
    helpers = gfx_tests.load_c2fb_tests()
    context, header_profile = gfx_tests.build_gfx_binding(
        converter, cc, source_root, profile_directory, work,
    )
    body_profile = profile_directory / "freebasic-linux-glibc-x86_64-body.rsp"
    units = (
        ("palette/gfx_palette.c", "gfx_palette.bas", 6),
        ("palette/gfx_paletteusing.c", "gfx_paletteusing.bas", 1),
        ("palette/gfx_paletteusing64.c", "gfx_paletteusing64.bas", 1),
    )
    candidate_objects = []
    for source_name, module_name, function_count in units:
        candidate = work / (Path(source_name).stem + "_candidates.bas")
        summary = helpers.run_freebasic_gfx_source_unit(
            converter, fbc, cc, source_root, source_name, candidate,
            context, header_profile, body_profile,
            extra_body_options=("--rename-proc-prefix=c2fbGfx_",),
        )
        expected = f"translated {function_count} simple functions; skipped 0"
        if expected not in summary:
            raise AssertionError(summary)
        candidate_objects.append(candidate.with_suffix(".o"))

    reference_source = work / "gfx_palette_c_reference.c"
    reference_source.write_text(
        "#define fb_hMakeColor fb_hMakeColorC\n"
        "#define fb_hFixColor fb_hFixColorC\n"
        "#define fb_hRestorePalette fb_hRestorePaletteC\n"
        "#define fb_hSetPaletteColorRgb fb_hSetPaletteColorRgbC\n"
        "#define fb_hSetPaletteColor fb_hSetPaletteColorC\n"
        "#define fb_GfxPalette fb_GfxPaletteC\n"
        '#include "palette/gfx_palette.c"\n'
        "#undef fb_GfxPalette\n"
        "#define fb_GfxPaletteUsing fb_GfxPaletteUsingC\n"
        '#include "palette/gfx_paletteusing.c"\n'
        "#undef fb_GfxPaletteUsing\n"
        "#define fb_GfxPaletteUsing64 fb_GfxPaletteUsing64C\n"
        '#include "palette/gfx_paletteusing64.c"\n',
        encoding="utf-8",
    )
    support_source = work / "gfx_palette_mutation_probe.c"
    support_source.write_text(PROBE_SOURCE, encoding="utf-8")
    compile_flags = [
        "-std=c99", "-DFB_NO_GFXLIB", "-DENABLE_MT", "-include",
        "sys/types.h", "-I", str(source_root / "rtlib"),
        "-I", str(source_root / "gfxlib2"),
        "-I", str(source_root / "gfxlib2/palette"),
    ]
    reference_object = work / "gfx_palette_c_reference.o"
    run(cc + compile_flags + [
        "-c", str(reference_source), "-o", str(reference_object),
    ], cwd=work)
    support_object = work / "gfx_palette_mutation_probe.o"
    run(cc + compile_flags + [
        "-c", str(support_source), "-o", str(support_object),
    ], cwd=work)

    integrated_source = source_root / "gfxlib2/arch/linux/x86_64/gfx_palette.bas"
    integrated_object = work / "gfx_palette_integrated_basic.o"
    run(fbc + [
        "-mt", "-w", "all", "-d", "FB_NO_GFXLIB",
        "-i", str(source_root.parent / "inc"),
        "-i", str(integrated_source.parent),
        "-c", str(integrated_source), "-o", str(integrated_object),
    ], cwd=work)

    integrated_using_objects = []
    for _, module_name, _ in units[1:]:
        module_source = source_root / "gfxlib2/arch/linux/x86_64" / module_name
        module_object = work / (Path(module_name).stem + "_integrated_basic.o")
        run(fbc + [
            "-mt", "-w", "all", "-d", "FB_NO_GFXLIB",
            "-i", str(source_root.parent / "inc"),
            "-i", str(module_source.parent),
            "-c", str(module_source), "-o", str(module_object),
        ], cwd=work)
        integrated_using_objects.append(module_object)

    for name, module_object in (
        ("candidate", [integrated_object, *candidate_objects[1:]]),
        ("integrated_basic", [integrated_object, *integrated_using_objects]),
    ):
        executable = work / ("gfx_palette_mutation_" + name)
        run(cc + [
            str(support_object), str(reference_object),
            *(str(path) for path in module_object),
            "-lm", "-o", str(executable),
        ], cwd=work)
        output = run([str(executable)], cwd=work)
        if "GFX_PALETTE_MUTATION_C2FB_PARITY_PASS" not in output:
            raise AssertionError(output)
    print(
        "GFXLIB2 palette mutation: C2FB candidate and Basic port match C for "
        "palette helpers, RGB and index updates, mode restores, callbacks, "
        "dirty lines, and 32-bit/64-bit whole-palette writes"
    )


def main():
    parser = argparse.ArgumentParser(
        description="Compare C2FB GFXLIB2 palette mutation with C."
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
    source = source_root / "gfxlib2/palette/gfx_palette.c"
    module = source_root / "gfxlib2/arch/linux/x86_64/gfx_palette.bas"
    if not source.is_file() or not module.is_file():
        parser.error("GFXLIB2 palette mutation C source or Basic port is missing")
    gfx_tests.check_gfx_source_graph(source_root)
    with tempfile.TemporaryDirectory(prefix="c2fb-freebasic-gfx-palette-mutation-") as temp:
        check_palette_mutation(
            fbc, cc, str(Path(args.converter).resolve()), source_root,
            Path(args.profile_directory).resolve(), Path(temp),
        )


if __name__ == "__main__":
    main()

# end of test_freebasic_gfx_palette_mutation.py
