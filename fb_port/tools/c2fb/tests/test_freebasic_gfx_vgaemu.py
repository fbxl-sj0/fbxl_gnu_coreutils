#!/usr/bin/env python3
'''
Project: C2FB FreeBASIC GFXLIB2 tests
File: test_freebasic_gfx_vgaemu.py
Purpose: Compare translated VGA palette-port routines with C.
Responsibilities: Validate persistent register state, palette access, and callbacks.
This file intentionally does NOT contain: Graphics port implementation code.
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

int fb_GfxInC(unsigned short);
int fb_GfxOutC(unsigned short, unsigned char);
FBGFX *__fb_gfx;
void *(*fb_hMemSet)(void *, int, size_t) = memset;

double fb_FIXDouble(double value)
{
    return trunc(value);
}

#define EVENT_CAPACITY 64
#define DIRTY_CAPACITY 32

typedef struct PALETTE_EVENT {
    int index;
    int red;
    int green;
    int blue;
} PALETTE_EVENT;

typedef struct GFX_SNAPSHOT {
    unsigned int palette[256];
    unsigned int device_palette[256];
    unsigned char color_association[256];
    char dirty[DIRTY_CAPACITY];
} GFX_SNAPSHOT;

typedef struct EFFECT_SNAPSHOT {
    int event_count;
    int wait_count;
    PALETTE_EVENT events[EVENT_CAPACITY];
} EFFECT_SNAPSHOT;

typedef struct PORT_OPERATION {
    int output;
    unsigned short port;
    unsigned char value;
} PORT_OPERATION;

static unsigned char default_palette_data[4][768];
static unsigned int palette_values[256];
static unsigned int device_palette_values[256];
static unsigned char color_association_values[256];
static char dirty_lines[DIRTY_CAPACITY];
static FBGFX graphics_state;
static GFXDRIVER graphics_driver;
static PALETTE_EVENT palette_events[EVENT_CAPACITY];
static int palette_event_count;
static int wait_count;

const PALETTE __fb_palette[FB_PALETTE_COUNT] = {
    { 2, default_palette_data[0] },
    { 16, default_palette_data[1] },
    { 64, default_palette_data[2] },
    { 256, default_palette_data[3] }
};

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

static void record_wait_vsync(void)
{
    wait_count++;
}

static void reset_effects(void)
{
    memset(palette_events, 0, sizeof(palette_events));
    palette_event_count = 0;
    wait_count = 0;
}

static void configure_graphics(int depth, int palette_index,
    int mode, int with_graphics, int with_callback, int with_wait)
{
    unsigned int i, table, channel;
    memset(&graphics_state, 0, sizeof(graphics_state));
    memset(&graphics_driver, 0, sizeof(graphics_driver));
    for (i = 0; i < 256u; i++) {
        palette_values[i] = ((i * 0x010305u) ^ 0x00556677u) & 0x00ffffffu;
        device_palette_values[i] = ((i * 0x030507u) ^ 0x00123456u) & 0x00ffffffu;
        color_association_values[i] = (unsigned char)(i & 15u);
    }
    for (table = 0; table < 4u; table++) {
        for (i = 0; i < 256u; i++) {
            for (channel = 0; channel < 3u; channel++) {
                default_palette_data[table][i * 3u + channel] =
                    (unsigned char)((i * 5u + channel * 23u + table * 7u + 3u) & 63u);
            }
        }
    }
    for (i = 0; i < DIRTY_CAPACITY; i++)
        dirty_lines[i] = (char)((i * 3u + 1u) & 1u);
    graphics_driver.set_palette = with_callback ? record_palette : NULL;
    graphics_driver.wait_vsync = with_wait ? record_wait_vsync : NULL;
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
    reset_effects();
}

static void capture_state(GFX_SNAPSHOT *snapshot)
{
    memcpy(snapshot->palette, palette_values, sizeof(palette_values));
    memcpy(snapshot->device_palette, device_palette_values, sizeof(device_palette_values));
    memcpy(snapshot->color_association, color_association_values,
        sizeof(color_association_values));
    memcpy(snapshot->dirty, dirty_lines, sizeof(dirty_lines));
}

static void restore_state(const GFX_SNAPSHOT *snapshot)
{
    memcpy(palette_values, snapshot->palette, sizeof(palette_values));
    memcpy(device_palette_values, snapshot->device_palette,
        sizeof(device_palette_values));
    memcpy(color_association_values, snapshot->color_association,
        sizeof(color_association_values));
    memcpy(dirty_lines, snapshot->dirty, sizeof(dirty_lines));
}

static void capture_effects(EFFECT_SNAPSHOT *snapshot)
{
    snapshot->event_count = palette_event_count;
    snapshot->wait_count = wait_count;
    memcpy(snapshot->events, palette_events, sizeof(palette_events));
}

static int snapshots_match(const GFX_SNAPSHOT *left, const GFX_SNAPSHOT *right)
{
    if (memcmp(left->palette, right->palette, sizeof(left->palette)) != 0) return 1;
    if (memcmp(left->device_palette, right->device_palette,
        sizeof(left->device_palette)) != 0) return 2;
    if (memcmp(left->color_association, right->color_association,
        sizeof(left->color_association)) != 0) return 3;
    if (memcmp(left->dirty, right->dirty, sizeof(left->dirty)) != 0) return 4;
    return 0;
}

static int effects_match(const EFFECT_SNAPSHOT *left, const EFFECT_SNAPSHOT *right)
{
    if (left->event_count != right->event_count) return 5;
    if (left->wait_count != right->wait_count) return 6;
    if (memcmp(left->events, right->events, sizeof(left->events)) != 0) return 7;
    return 0;
}

static int run_operation(const PORT_OPERATION *operation,
    GFX_SNAPSHOT *reference_state, GFX_SNAPSHOT *basic_state)
{
    EFFECT_SNAPSHOT c_effects, fb_effects;
    int c_result, fb_result;
    restore_state(reference_state);
    reset_effects();
    if (operation->output)
        c_result = fb_GfxOutC(operation->port, operation->value);
    else
        c_result = fb_GfxInC(operation->port);
    capture_effects(&c_effects);
    capture_state(reference_state);

    restore_state(basic_state);
    reset_effects();
    if (operation->output)
        fb_result = fb_GfxOut(operation->port, operation->value);
    else
        fb_result = fb_GfxIn(operation->port);
    capture_effects(&fb_effects);
    capture_state(basic_state);

    if (c_result != fb_result) return 8;
    if (snapshots_match(reference_state, basic_state) != 0) return 9;
    if (effects_match(&c_effects, &fb_effects) != 0) return 10;
    return 0;
}

static int compare_sequence(int depth, int palette_index, int mode,
    int with_graphics, int with_callback, int with_wait,
    const PORT_OPERATION *operations, unsigned int operation_count)
{
    GFX_SNAPSHOT reference_state, basic_state;
    unsigned int i;
    int result;
    configure_graphics(depth, palette_index, mode,
        with_graphics, with_callback, with_wait);
    capture_state(&reference_state);
    basic_state = reference_state;
    for (i = 0; i < operation_count; i++) {
        result = run_operation(&operations[i], &reference_state, &basic_state);
        if (result != 0) return (int)(20u + i * 11u + (unsigned int)result);
    }
    return 0;
}

int main(void)
{
    static const PORT_OPERATION indexed_operations[] = {
        { 1, 0x3C8, 4 },
        { 1, 0x3C9, 63 }, { 1, 0x3C9, 32 }, { 1, 0x3C9, 15 },
        { 1, 0x3C7, 4 },
        { 0, 0x3C9, 0 }, { 0, 0x3C9, 0 }, { 0, 0x3C9, 0 },
        { 0, 0x3DA, 0 }, { 0, 0x3C0, 0 }, { 1, 0x3C0, 0 }
    };
    static const PORT_OPERATION truecolor_operations[] = {
        { 1, 0x3C8, 9 },
        { 1, 0x3C9, 63 }, { 1, 0x3C9, 32 }, { 1, 0x3C9, 15 },
        { 1, 0x3C7, 9 },
        { 0, 0x3C9, 0 }, { 0, 0x3C9, 0 }, { 0, 0x3C9, 0 },
        { 0, 0x3DA, 0 }
    };
    static const PORT_OPERATION absent_operations[] = {
        { 0, 0x3C9, 0 }, { 1, 0x3C8, 4 }, { 0, 0x3DA, 0 }
    };
    static const PORT_OPERATION deep_operations[] = {
        { 1, 0x3C8, 4 }, { 1, 0x3C9, 12 },
        { 0, 0x3C9, 0 }, { 0, 0x3DA, 0 }
    };
    int result;
    result = compare_sequence(4, FB_PALETTE_16, 13, 1, 1, 1,
        indexed_operations, sizeof(indexed_operations) / sizeof(indexed_operations[0]));
    if (result) return result;
    result = compare_sequence(8, FB_PALETTE_256, 13, 1, 1, 1,
        truecolor_operations, sizeof(truecolor_operations) / sizeof(truecolor_operations[0]));
    if (result) return 50 + result;
    result = compare_sequence(4, FB_PALETTE_16, 13, 0, 1, 1,
        absent_operations, sizeof(absent_operations) / sizeof(absent_operations[0]));
    if (result) return 100 + result;
    result = compare_sequence(16, FB_PALETTE_16, 13, 1, 1, 1,
        deep_operations, sizeof(deep_operations) / sizeof(deep_operations[0]));
    if (result) return 150 + result;
    puts("GFX_VGAEMU_C2FB_PARITY_PASS");
    return 0;
}
'''


def check_vgaemu(fbc, cc, converter, source_root, profile_directory, work):
    helpers = gfx_tests.load_c2fb_tests()
    context, header_profile = gfx_tests.build_gfx_binding(
        converter, cc, source_root, profile_directory, work,
    )
    body_profile = profile_directory / "freebasic-linux-glibc-x86_64-body.rsp"
    candidate = work / "gfx_vgaemu_candidates.bas"
    summary = helpers.run_freebasic_gfx_source_unit(
        converter, fbc, cc, source_root, "palette/gfx_vgaemu.c", candidate,
        context, header_profile, body_profile,
        extra_body_options=("--rename-proc-prefix=c2fbGfx_",),
    )
    if "translated 2 simple functions; skipped 0" not in summary:
        raise AssertionError(summary)

    reference_source = work / "gfx_vgaemu_c_reference.c"
    reference_source.write_text(
        "#define fb_hMakeColor fb_hMakeColorC\n"
        "#define fb_hFixColor fb_hFixColorC\n"
        "#define fb_hRestorePalette fb_hRestorePaletteC\n"
        "#define fb_hSetPaletteColorRgb fb_hSetPaletteColorRgbC\n"
        "#define fb_hSetPaletteColor fb_hSetPaletteColorC\n"
        "#define fb_GfxPalette fb_GfxPaletteC\n"
        '#include "palette/gfx_palette.c"\n'
        "#define fb_GfxIn fb_GfxInC\n"
        "#define fb_GfxOut fb_GfxOutC\n"
        '#include "palette/gfx_vgaemu.c"\n',
        encoding="utf-8",
    )
    support_source = work / "gfx_vgaemu_probe.c"
    support_source.write_text(PROBE_SOURCE, encoding="utf-8")
    compile_flags = [
        "-std=c99", "-DFB_NO_GFXLIB", "-DENABLE_MT", "-include",
        "sys/types.h", "-I", str(source_root / "rtlib"),
        "-I", str(source_root / "gfxlib2"),
        "-I", str(source_root / "gfxlib2/palette"),
    ]
    reference_object = work / "gfx_vgaemu_c_reference.o"
    run(cc + compile_flags + [
        "-c", str(reference_source), "-o", str(reference_object),
    ], cwd=work)
    support_object = work / "gfx_vgaemu_probe.o"
    run(cc + compile_flags + [
        "-c", str(support_source), "-o", str(support_object),
    ], cwd=work)

    palette_source = source_root / "gfxlib2/arch/linux/x86_64/gfx_palette.bas"
    palette_object = work / "gfx_palette_integrated_basic.o"
    run(fbc + [
        "-mt", "-w", "all", "-d", "FB_NO_GFXLIB",
        "-i", str(source_root.parent / "inc"),
        "-i", str(palette_source.parent),
        "-c", str(palette_source), "-o", str(palette_object),
    ], cwd=work)

    integrated_source = source_root / "gfxlib2/arch/linux/x86_64/gfx_vgaemu.bas"
    integrated_object = work / "gfx_vgaemu_integrated_basic.o"
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
        executable = work / ("gfx_vgaemu_" + name)
        run(cc + [
            str(support_object), str(reference_object),
            str(palette_object), str(module_object), "-lm", "-o", str(executable),
        ], cwd=work)
        output = run([str(executable)], cwd=work)
        if "GFX_VGAEMU_C2FB_PARITY_PASS" not in output:
            raise AssertionError(output)
    print(
        "GFXLIB2 VGA palette ports: C2FB candidate and Basic port match C "
        "for persistent register sequences, palette writes, reads, and callbacks"
    )


def main():
    parser = argparse.ArgumentParser(
        description="Compare C2FB GFXLIB2 VGA palette ports with C."
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
    source = source_root / "gfxlib2/palette/gfx_vgaemu.c"
    module = source_root / "gfxlib2/arch/linux/x86_64/gfx_vgaemu.bas"
    if not source.is_file() or not module.is_file():
        parser.error("GFXLIB2 VGA C source or Basic port is missing")
    gfx_tests.check_gfx_source_graph(source_root)
    with tempfile.TemporaryDirectory(prefix="c2fb-freebasic-gfx-vgaemu-") as temp:
        check_vgaemu(
            fbc, cc, str(Path(args.converter).resolve()), source_root,
            Path(args.profile_directory).resolve(), Path(temp),
        )


if __name__ == "__main__":
    main()

# end of test_freebasic_gfx_vgaemu.py
