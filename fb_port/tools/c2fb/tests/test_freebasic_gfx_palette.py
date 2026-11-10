#!/usr/bin/env python3
'''
Project: C2FB FreeBASIC GFXLIB2 tests
File: test_freebasic_gfx_palette.py
Purpose: Compare translated palette lookup modules with their C implementations.
Responsibilities: Translate, compile, link, and test the 32-bit and 64-bit APIs.
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


def check_palette_lookup(fbc, cc, converter, source_root, profile_directory, work):
    helpers = gfx_tests.load_c2fb_tests()
    context, header_profile = gfx_tests.build_gfx_binding(
        converter, cc, source_root, profile_directory, work,
    )
    body_profile = profile_directory / "freebasic-linux-glibc-x86_64-body.rsp"
    units = (
        ("palette/gfx_paletteget.c", "gfx_paletteget.bas"),
        ("palette/gfx_paletteget64.c", "gfx_paletteget64.bas"),
        ("palette/gfx_palettegetusing.c", "gfx_palettegetusing.bas"),
        ("palette/gfx_palettegetusing64.c", "gfx_palettegetusing64.bas"),
    )
    candidate_objects = []
    for source_name, module_name in units:
        candidate = work / (Path(source_name).stem + "_candidates.bas")
        summary = helpers.run_freebasic_gfx_source_unit(
            converter, fbc, cc, source_root, source_name, candidate,
            context, header_profile, body_profile,
            extra_body_options=("--rename-proc-prefix=c2fbGfx_",),
        )
        if "translated 1 simple functions; skipped 0" not in summary:
            raise AssertionError(summary)
        candidate_objects.append(candidate.with_suffix(".o"))

    gfx_directory = source_root / "gfxlib2"
    reference_source = work / "gfx_palette_reference.c"
    reference_source.write_text(
        "#define fb_GfxPaletteGet fb_GfxPaletteGetC\n"
        '#include "palette/gfx_paletteget.c"\n'
        "#undef fb_GfxPaletteGet\n"
        "#define fb_GfxPaletteGet64 fb_GfxPaletteGet64C\n"
        '#include "palette/gfx_paletteget64.c"\n'
        "#undef fb_GfxPaletteGet64\n"
        "#define fb_GfxPaletteGetUsing fb_GfxPaletteGetUsingC\n"
        '#include "palette/gfx_palettegetusing.c"\n'
        "#undef fb_GfxPaletteGetUsing\n"
        "#define fb_GfxPaletteGetUsing64 fb_GfxPaletteGetUsing64C\n"
        '#include "palette/gfx_palettegetusing64.c"\n',
        encoding="utf-8",
    )
    support_source = work / "gfx_palette_probe.c"
    support_source.write_text(r'''#include <stdio.h>
#include <string.h>
#include "fb_gfx.h"

void fb_GfxPaletteGetC(int, int *, int *, int *);
void fb_GfxPaletteGet64C(int, long long *, long long *, long long *);
void fb_GfxPaletteGetUsingC(int *);
void fb_GfxPaletteGetUsing64C(long long *);
FBGFX *__fb_gfx;

void fb_GraphicsLock(void) {}
void fb_GraphicsUnlock(void) {}

static unsigned int palette_colors[256];
static PALETTE default_palette16 = { 16, NULL };
static PALETTE default_palette256 = { 256, NULL };
static FBGFX graphics_state;

static void configure_graphics(int depth, int palette_size)
{
    unsigned int i;
    memset(&graphics_state, 0, sizeof(graphics_state));
    for (i = 0; i < 256; i++)
        palette_colors[i] = ((i * 37u + 0x123456u) ^ (i << 17)) & 0x00ffffffu;
    graphics_state.depth = depth;
    graphics_state.device_palette = palette_colors;
    graphics_state.default_palette = (palette_size == 256) ?
        &default_palette256 : &default_palette16;
    __fb_gfx = &graphics_state;
}

static int compare_32(int index, int grayscale)
{
    int c_r = 0x13579bdf, c_g = 0x2468ace0, c_b = 0x11223344;
    int f_r = c_r, f_g = c_g, f_b = c_b;
    unsigned int color;
    fb_GfxPaletteGetC(index, &c_r, grayscale ? NULL : &c_g, &c_b);
    fb_GfxPaletteGet(index, &f_r, grayscale ? NULL : &f_g, &f_b);
    if (c_r != f_r || c_g != f_g || c_b != f_b) return 1;
    color = palette_colors[(unsigned int)index & 15u];
    if (grayscale) {
        if (f_r != (int)((color & 0x00fcfcfcu) >> 2)) return 2;
        if (f_g != 0x2468ace0 || f_b != 0x11223344) return 3;
    } else if (f_r != (int)(color & 0xffu) ||
               f_g != (int)((color >> 8) & 0xffu) ||
               f_b != (int)((color >> 16) & 0xffu)) {
        return 4;
    }
    return 0;
}

static int compare_64(int index, int grayscale)
{
    long long c_r = 0x123456789LL, c_g = 0x23456789aLL, c_b = 0x3456789abLL;
    long long f_r = c_r, f_g = c_g, f_b = c_b;
    unsigned int color;
    fb_GfxPaletteGet64C(index, &c_r, grayscale ? NULL : &c_g, &c_b);
    fb_GfxPaletteGet64(index, &f_r, grayscale ? NULL : &f_g, &f_b);
    if (c_r != f_r || c_g != f_g || c_b != f_b) return 5;
    color = palette_colors[(unsigned int)index & 15u];
    if (grayscale) {
        if (f_r != (long long)((color & 0x00fcfcfcu) >> 2)) return 6;
        if (f_g != 0x23456789aLL || f_b != 0x3456789abLL) return 7;
    } else if (f_r != (long long)(color & 0xffu) ||
               f_g != (long long)((color >> 8) & 0xffu) ||
               f_b != (long long)((color >> 16) & 0xffu)) {
        return 8;
    }
    return 0;
}

static int compare_using_32(int depth, int palette_size)
{
    int c_data[260], f_data[260];
    int limit = palette_size;
    int i;
    if (limit > (1 << depth)) limit = 1 << depth;
    for (i = 0; i < 260; i++)
        c_data[i] = f_data[i] = -100000 - i;
    configure_graphics(depth, palette_size);
    fb_GfxPaletteGetUsingC(c_data);
    fb_GfxPaletteGetUsing(f_data);
    for (i = 0; i < 260; i++) {
        int expected = (i < limit) ?
            (int)((palette_colors[i] & 0x00fcfcfcu) >> 2) : -100000 - i;
        if (c_data[i] != f_data[i] || f_data[i] != expected) return 9;
    }
    return 0;
}

static int compare_using_64(int depth, int palette_size)
{
    long long c_data[260], f_data[260];
    int limit = palette_size;
    int i;
    if (limit > (1 << depth)) limit = 1 << depth;
    for (i = 0; i < 260; i++)
        c_data[i] = f_data[i] = -0x123456789LL - i;
    configure_graphics(depth, palette_size);
    fb_GfxPaletteGetUsing64C(c_data);
    fb_GfxPaletteGetUsing64(f_data);
    for (i = 0; i < 260; i++) {
        long long expected = (i < limit) ?
            (long long)((palette_colors[i] & 0x00fcfcfcu) >> 2) :
            -0x123456789LL - i;
        if (c_data[i] != f_data[i] || f_data[i] != expected) return 10;
    }
    return 0;
}

int main(void)
{
    int r = 11, g = 22, b = 33;
    long long r64 = 44, g64 = 55, b64 = 66;
    int null_data[260], null_data_fb[260];
    long long null_data64[260], null_data64_fb[260];
    int i;
    int result;
    __fb_gfx = NULL;
    fb_GfxPaletteGetC(3, &r, &g, &b);
    fb_GfxPaletteGet(3, &r, &g, &b);
    fb_GfxPaletteGet64C(3, &r64, &g64, &b64);
    fb_GfxPaletteGet64(3, &r64, &g64, &b64);
    for (i = 0; i < 260; i++) {
        null_data[i] = null_data_fb[i] = -2000 - i;
        null_data64[i] = null_data64_fb[i] = -0x555555555LL - i;
    }
    fb_GfxPaletteGetUsingC(null_data);
    fb_GfxPaletteGetUsing(null_data_fb);
    fb_GfxPaletteGetUsing64C(null_data64);
    fb_GfxPaletteGetUsing64(null_data64_fb);
    if (r != 11 || g != 22 || b != 33 || r64 != 44 || g64 != 55 || b64 != 66)
        return 10;
    for (i = 0; i < 260; i++)
        if (null_data[i] != null_data_fb[i] ||
            null_data_fb[i] != -2000 - i ||
            null_data64[i] != null_data64_fb[i] ||
            null_data64_fb[i] != -0x555555555LL - i)
            return 11;

    configure_graphics(4, 16);
    if ((result = compare_32(0, 0)) != 0) return result;
    if ((result = compare_32(15, 0)) != 0) return result;
    if ((result = compare_32(16, 0)) != 0) return result;
    if ((result = compare_32(-1, 0)) != 0) return result;
    if ((result = compare_32(17, 1)) != 0) return result;
    if ((result = compare_64(0, 0)) != 0) return result;
    if ((result = compare_64(15, 0)) != 0) return result;
    if ((result = compare_64(16, 0)) != 0) return result;
    if ((result = compare_64(-1, 0)) != 0) return result;
    if ((result = compare_64(17, 1)) != 0) return result;
    if ((result = compare_using_32(4, 256)) != 0) return result;
    if ((result = compare_using_32(8, 16)) != 0) return result;
    if ((result = compare_using_32(2, 16)) != 0) return result;
    if ((result = compare_using_64(4, 256)) != 0) return result;
    if ((result = compare_using_64(8, 16)) != 0) return result;
    if ((result = compare_using_64(2, 16)) != 0) return result;
    puts("GFX_PALETTE_C2FB_PARITY_PASS");
    return 0;
}
''', encoding="utf-8")

    compile_flags = [
        "-std=c99", "-DFB_NO_GFXLIB", "-DENABLE_MT", "-include",
        "sys/types.h", "-I", str(source_root / "rtlib"),
        "-I", str(gfx_directory), "-I", str(gfx_directory / "palette"),
    ]
    reference_object = work / "gfx_palette_reference.o"
    run(cc + compile_flags + [
        "-c", str(reference_source), "-o", str(reference_object),
    ], cwd=work)
    support_object = work / "gfx_palette_probe.o"
    run(cc + compile_flags + [
        "-c", str(support_source), "-o", str(support_object),
    ], cwd=work)

    integrated_objects = []
    for _, module_name in units:
        module_source = source_root / "gfxlib2/arch/linux/x86_64" / module_name
        module_object = work / (Path(module_name).stem + ".o")
        run(fbc + [
            "-mt", "-w", "all", "-d", "FB_NO_GFXLIB",
            "-i", str(source_root.parent / "inc"),
            "-i", str(module_source.parent),
            "-c", str(module_source), "-o", str(module_object),
        ], cwd=work)
        integrated_objects.append(module_object)

    for name, module_objects in (
        ("candidate", candidate_objects),
        ("integrated_basic", integrated_objects),
    ):
        executable = work / ("gfx_palette_" + name)
        run(cc + [
            str(support_object), str(reference_object),
            *(str(path) for path in module_objects), "-o", str(executable),
        ], cwd=work)
        output = run([str(executable)], cwd=work)
        if "GFX_PALETTE_C2FB_PARITY_PASS" not in output:
            raise AssertionError(output)
    print(
        "GFXLIB2 palette lookup: C2FB candidates and Basic ports match C for "
        "null graphics state, index masking, scalar RGB, whole-palette bounds, "
        "and grayscale output"
    )


def main():
    parser = argparse.ArgumentParser(
        description="Compare C2FB GFXLIB2 palette lookup ports with C."
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
    for source_name, module_name in (
        ("gfxlib2/palette/gfx_paletteget.c", "gfx_paletteget.bas"),
        ("gfxlib2/palette/gfx_paletteget64.c", "gfx_paletteget64.bas"),
        ("gfxlib2/palette/gfx_palettegetusing.c", "gfx_palettegetusing.bas"),
        ("gfxlib2/palette/gfx_palettegetusing64.c", "gfx_palettegetusing64.bas"),
    ):
        if not (source_root / source_name).is_file():
            parser.error("GFXLIB2 palette source is missing: " + source_name)
        if not (source_root / "gfxlib2/arch/linux/x86_64" / module_name).is_file():
            parser.error("Linux x86-64 Basic palette port is missing: " + module_name)
    profile_directory = Path(args.profile_directory).resolve()
    gfx_tests.check_gfx_source_graph(source_root)
    with tempfile.TemporaryDirectory(prefix="c2fb-freebasic-gfx-palette-") as temp:
        check_palette_lookup(
            fbc, cc, str(Path(args.converter).resolve()), source_root,
            profile_directory, Path(temp),
        )


if __name__ == "__main__":
    main()

# end of test_freebasic_gfx_palette.py
