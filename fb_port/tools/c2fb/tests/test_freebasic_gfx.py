#!/usr/bin/env python3
"""
Project: SQLite FreeBASIC port tools
File: test_freebasic_gfx.py
Purpose: Validate GFXLIB2 C2FB candidates against their C implementations.
Responsibilities: Generate the shared graphics type context, translate and
  compile VSync and image-info procedures, and compare their ABI and behavior.
This file intentionally does NOT contain: Full graphics library or UI tests.
"""

import argparse
import importlib.util
import platform
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path


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


def load_c2fb_tests():
    sys.dont_write_bytecode = True
    test_path = Path(__file__).with_name("test_c2fb.py")
    spec = importlib.util.spec_from_file_location("c2fb_test_helpers", test_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load test helpers from {test_path}")
    helpers = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helpers)
    return helpers


def check_gfx_source_graph(source_root):
    make_output = run([
        "make", "-s", "-C", str(source_root.parent), "-pn",
    ])
    variables = {}
    for line in make_output.splitlines():
        match = re.match(r"^(GFX_SRC(?:_FB|_C)?) := (.*)$", line)
        if match is not None:
            variables[match.group(1)] = match.group(2).split()

    basic_source = str(
        (source_root / "gfxlib2/presentation/gfx_vsync.bas").resolve()
    )
    c_peer = str(
        (source_root / "gfxlib2/presentation/gfx_vsync.c").resolve()
    )
    selected = set(variables.get("GFX_SRC", ()))
    if basic_source not in variables.get("GFX_SRC_FB", ()) or \
       basic_source not in selected:
        raise AssertionError("GFX Make graph did not select gfx_vsync.bas")
    if c_peer in selected or c_peer in variables.get("GFX_SRC_C", ()):
        raise AssertionError("GFX Make graph retained the replaced C peer")
    image_info_basic = str(
        (source_root / "gfxlib2/arch/linux/x86_64/gfx_image_info.bas").resolve()
    )
    image_info_c = str(
        (source_root / "gfxlib2/image/gfx_image_info.c").resolve()
    )
    if image_info_basic not in variables.get("GFX_SRC_FB", ()) or \
       image_info_basic not in selected:
        raise AssertionError("GFX Make graph did not select the Linux x86-64 Basic image-info module")
    if image_info_c in selected or image_info_c in variables.get("GFX_SRC_C", ()):
        raise AssertionError("GFX Make graph retained the replaced image-info C peer")
    png_basic = str(
        (source_root / "gfxlib2/arch/linux/x86_64/gfx_png.bas").resolve()
    )
    png_c = str((source_root / "gfxlib2/image/gfx_png.c").resolve())
    if png_basic not in variables.get("GFX_SRC_FB", ()) or png_basic not in selected:
        raise AssertionError("GFX Make graph did not select the Linux x86-64 Basic PNG module")
    if png_c in selected or png_c in variables.get("GFX_SRC_C", ()):
        raise AssertionError("GFX Make graph retained the replaced PNG C peer")
    for stem in (
        "gfx_paletteget", "gfx_paletteget64",
        "gfx_palettegetusing", "gfx_palettegetusing64",
        "gfx_palette", "gfx_paletteusing", "gfx_paletteusing64",
        "gfx_vgaemu", "gfx_screeninfo",
    ):
        palette_basic = str(
            (source_root / "gfxlib2/arch/linux/x86_64" / (stem + ".bas")).resolve()
        )
        palette_c = str(
            (source_root / "gfxlib2/palette" / (stem + ".c")).resolve()
        )
        if palette_basic not in variables.get("GFX_SRC_FB", ()) or palette_basic not in selected:
            raise AssertionError("GFX Make graph did not select Linux x86-64 " + stem + ".bas")
        if palette_c in selected or palette_c in variables.get("GFX_SRC_C", ()):
            raise AssertionError("GFX Make graph retained the replaced " + stem + " C peer")
    print(
        "GFX source graph: Basic VSync, image-info, screen-info, PNG, palette "
        "mutation, VGA emulation, and palette lookup modules selected; C peers replaced"
    )


def build_gfx_binding(converter, cc, source_root, profile_directory, work):
    binding = work / "fb_gfx.bi"
    header_profile = profile_directory / "freebasic-linux-glibc-x86_64.rsp"
    source_patterns = (
        "gfxlib2/fb_gfx.h", "rtlib/fb_gfx_private.h", "rtlib/fb.h",
        "rtlib/fb_string.h", "rtlib/fb_array.h", "rtlib/fb_event.h",
        "rtlib/fb_drop.h", "rtlib/fb_hook.h", "rtlib/fb_thread.h",
        "rtlib/fb_file.h", "rtlib/fb_unicode.h",
    )
    command = [
        converter, "generic-header",
        str(source_root / "gfxlib2/fb_gfx.h"), str(binding), *cc,
        f"-I{source_root / 'rtlib'}",
        f"-I{source_root / 'gfxlib2'}",
        "-DFB_NO_GFXLIB", f"@{header_profile}", "--exclude=*",
    ]
    command.extend(
        "--emit-source=" + pattern for pattern in source_patterns
    )
    run(command, cwd=work)

    context = work / "gfx-type-context"
    context.mkdir()
    context_binding = context / binding.name
    context_binding.write_text(binding.read_text())
    return context, header_profile


def check_gfx_vsync_prefix_layout(fbc, cc, source_root, work):
    c_source = work / "gfx_vsync_prefix_layout.c"
    c_source.write_text(
        "#include <stddef.h>\n"
        "#include <stdio.h>\n"
        '#include "fb_gfx.h"\n'
        "int main(void) {\n"
        '    printf("%zu %zu %zu", offsetof(FBGFX, driver), '
        "offsetof(GFXDRIVER, wait_vsync), sizeof(void *));\n"
        "    return 0;\n"
        "}\n"
    )
    c_executable = work / "gfx_vsync_prefix_layout_c"
    run(cc + [
        "-std=c99", "-DFB_NO_GFXLIB", "-include", "sys/types.h",
        f"-I{source_root / 'rtlib'}", f"-I{source_root / 'gfxlib2'}",
        str(c_source), "-o", str(c_executable),
    ], cwd=work)

    basic_source = work / "gfx_vsync_prefix_layout.bas"
    basic_source.write_text(
        '#include once "fb_gfx_vsync_prefix.bi"\n'
        "Dim context As FbGfxContextVSyncPrefix\n"
        "Dim driver As FbGfxDriverVSyncPrefix\n"
        'Print CULngInt(@context.driver)-CULngInt(@context); " "; '
        'CULngInt(@driver.waitVSync)-CULngInt(@driver); " "; SizeOf(Any Ptr)\n'
    )
    basic_executable = work / "gfx_vsync_prefix_layout_basic"
    run(fbc + [
        "-w", "all", "-i", str(source_root.parent / "inc"),
        "-i", str(source_root / "gfxlib2/presentation"),
        str(basic_source), "-x", str(basic_executable),
    ], cwd=work)

    c_offsets = run([str(c_executable)], cwd=work).split()
    basic_offsets = run([str(basic_executable)], cwd=work).split()
    if c_offsets != basic_offsets:
        raise AssertionError(
            "GFX VSync prefix layout mismatch: "
            f"C={c_offsets}, FreeBASIC={basic_offsets}"
        )


def check_vsync_behavior(fbc, cc, source_root, candidate_object, work):
    reference_source = source_root / "gfxlib2/presentation/gfx_vsync.c"
    reference_object = work / "gfx_vsync_c_reference.o"
    run(cc + [
        "-std=c99", "-DFB_NO_GFXLIB", "-include", "sys/types.h",
        "-Dfb_GfxWaitVSync=fb_GfxWaitVSyncC",
        f"-I{source_root / 'rtlib'}", f"-I{source_root / 'gfxlib2'}",
        "-c", str(reference_source), "-o", str(reference_object),
    ], cwd=work)

    support_source = work / "gfx_vsync_support.c"
    support_source.write_text(
        '#include <string.h>\n'
        '#include "fb_gfx.h"\n'
        'FBGFX *__fb_gfx;\n'
        'static FBGFX context;\n'
        'static GFXDRIVER driver;\n'
        'static int callback_count;\n'
        'static void wait_vsync(void) { ++callback_count; }\n'
        'void gfxVsyncTestReset(void) {\n'
        '    callback_count = 0;\n'
        '    fb_ErrorSetNum(FB_RTERROR_OK);\n'
        '}\n'
        'void gfxVsyncTestSetState(int state) {\n'
        '    memset(&context, 0, sizeof(context));\n'
        '    memset(&driver, 0, sizeof(driver));\n'
        '    context.driver = &driver;\n'
        '    if (state == 2) driver.wait_vsync = wait_vsync;\n'
        '    __fb_gfx = (state == 0) ? NULL : &context;\n'
        '    gfxVsyncTestReset();\n'
        '}\n'
        'int gfxVsyncTestCallbackCount(void) { return callback_count; }\n'
        'int gfxVsyncTestErrorNumber(void) { return fb_ErrorGetNum(); }\n'
    )
    support_object = work / "gfx_vsync_support.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror", "-DFB_NO_GFXLIB",
        "-include", "sys/types.h",
        f"-I{source_root / 'rtlib'}", f"-I{source_root / 'gfxlib2'}",
        "-c", str(support_source), "-o", str(support_object),
    ], cwd=work)

    basic_module = source_root / "gfxlib2/presentation/gfx_vsync.bas"
    basic_object = work / "gfx_vsync_basic.o"
    run(fbc + [
        "-w", "all", "-c", "-i", str(source_root.parent / "inc"),
        "-i", str(basic_module.parent), str(basic_module),
        "-o", str(basic_object),
    ], cwd=work)

    basic_mt_object = work / "gfx_vsync_basic_mt.o"
    run(fbc + [
        "-mt", "-d", "ENABLE_MT", "-w", "all", "-c",
        "-i", str(source_root.parent / "inc"),
        "-i", str(basic_module.parent), str(basic_module),
        "-o", str(basic_mt_object),
    ], cwd=work)
    single_thread_symbols = run(
        ["nm", "-u", str(basic_object)], cwd=work,
    )
    if "fb_GraphicsLock" in single_thread_symbols or \
       "fb_GraphicsUnlock" in single_thread_symbols:
        raise AssertionError(
            "single-threaded VSync object imports graphics lock symbols"
        )
    multi_thread_symbols = run(
        ["nm", "-u", str(basic_mt_object)], cwd=work,
    )
    if "fb_GraphicsLock" not in multi_thread_symbols or \
       "fb_GraphicsUnlock" not in multi_thread_symbols:
        raise AssertionError(
            "multi-threaded VSync object does not import graphics lock symbols"
        )

    test_source = work / "gfx_vsync_behavior.bas"
    test_source.write_text(
        'Declare Function gfxWaitVSyncCandidate CDecl Alias "fb_GfxWaitVSync" () As Long\n'
        'Declare Function gfxWaitVSyncReference CDecl Alias "fb_GfxWaitVSyncC" () As Long\n'
        'Declare Sub gfxVsyncTestReset CDecl Alias "gfxVsyncTestReset" ()\n'
        'Declare Sub gfxVsyncTestSetState CDecl Alias "gfxVsyncTestSetState" (ByVal state As Long)\n'
        'Declare Function gfxVsyncTestCallbackCount CDecl Alias "gfxVsyncTestCallbackCount" () As Long\n'
        'Declare Function gfxVsyncTestErrorNumber CDecl Alias "gfxVsyncTestErrorNumber" () As Long\n'
        'Function main() As Integer\n'
        '    Dim state As Long\n'
        '    Dim cResult As Long\n'
        '    Dim cError As Long\n'
        '    Dim cCallbacks As Long\n'
        '    For state = 0 To 2\n'
        '        gfxVsyncTestSetState(state)\n'
        '        cResult = gfxWaitVSyncReference()\n'
        '        cError = gfxVsyncTestErrorNumber()\n'
        '        cCallbacks = gfxVsyncTestCallbackCount()\n'
        '        gfxVsyncTestReset()\n'
        '        If gfxWaitVSyncCandidate() <> cResult Then Return 1 + state * 5\n'
        '        If gfxVsyncTestErrorNumber() <> cError Then Return 2 + state * 5\n'
        '        If gfxVsyncTestCallbackCount() <> cCallbacks Then Return 3 + state * 5\n'
        '        If state = 0 And cResult <> 1 Then Return 4 + state * 5\n'
        '        If state > 0 And cResult <> 0 Then Return 5 + state * 5\n'
        '        If state = 2 And cCallbacks <> 1 Then Return 5 + state * 5\n'
        '    Next\n'
        '    Return 0\n'
        'End Function\n'
        'End main()\n'
    )
    for module_object, label in (
        (candidate_object, "candidate"),
        (basic_object, "reviewed_basic"),
        (basic_mt_object, "reviewed_basic_mt"),
    ):
        executable = work / ("gfx_vsync_behavior_" + label)
        run(fbc + [
            "-mt", "-w", "all", "-d", "FB_NO_GFXLIB",
            "-i", str(source_root.parent / "inc"),
            "-i", str(candidate_object.parent),
            str(test_source), str(module_object),
            str(reference_object), str(support_object),
            "-x", str(executable),
        ], cwd=work)
        run([str(executable)], cwd=work)


def check_gfx_image_info_behavior(
    fbc, cc, source_root, candidate_object, work,
):
    image_info_source = source_root / "gfxlib2/image/gfx_image_info.c"
    reference_source = work / "gfx_image_info_c_reference.c"
    reference_source.write_text(
        "#define fb_GfxImageInfo fb_GfxImageInfoC\n"
        "#define fb_GfxImageInfo32 fb_GfxImageInfo32C\n"
        "#define fb_GfxImageInfo64 fb_GfxImageInfo64C\n"
        f'#include "{image_info_source.as_posix()}"\n'
    )
    reference_object = work / "gfx_image_info_c_reference.o"
    run(cc + [
        "-std=c99", "-DFB_NO_GFXLIB", "-include", "sys/types.h",
        "-I", str(source_root / "rtlib"),
        "-I", str(source_root / "gfxlib2"),
        "-c", str(reference_source), "-o", str(reference_object),
    ], cwd=work)

    probe_source = work / "gfx_image_info_probe.c"
    probe_source.write_text(
        "#include <stdio.h>\n"
        "#include <string.h>\n"
        "#include <stddef.h>\n"
        "#include <sys/types.h>\n"
        '#include "fb_gfx.h"\n'
        "int fb_ErrorSetNum(int error_number) { return error_number; }\n"
        "extern int fb_GfxImageInfoC(void *, ssize_t *, ssize_t *, ssize_t *, "
        "ssize_t *, void **, ssize_t *);\n"
        "extern int fb_GfxImageInfo32C(void *, int *, int *, int *, int *, "
        "void **, int *);\n"
        "extern int fb_GfxImageInfo64C(void *, long long *, long long *, "
        "long long *, long long *, void **, long long *);\n"
        "static int check_native(void *image, int expected_result, "
        "ssize_t expected_width, ssize_t expected_height, ssize_t expected_bpp, "
        "ssize_t expected_pitch, ssize_t expected_size, ptrdiff_t expected_data) {\n"
        "    ssize_t c_width = -91, c_height = -92, c_bpp = -93;\n"
        "    ssize_t c_pitch = -94, c_size = -95;\n"
        "    ssize_t fb_width = -91, fb_height = -92, fb_bpp = -93;\n"
        "    ssize_t fb_pitch = -94, fb_size = -95;\n"
        "    void *c_data = (void *)1, *fb_data = (void *)1;\n"
        "    int c_result = fb_GfxImageInfoC(image, &c_width, &c_height, "
        "&c_bpp, &c_pitch, &c_data, &c_size);\n"
        "    int fb_result = fb_GfxImageInfo(image, &fb_width, &fb_height, "
        "&fb_bpp, &fb_pitch, &fb_data, &fb_size);\n"
        "    if (c_result != fb_result || c_width != fb_width || "
        "c_height != fb_height || c_bpp != fb_bpp || c_pitch != fb_pitch || "
        "c_size != fb_size || c_data != fb_data) return 1;\n"
        "    if (fb_result != expected_result || fb_width != expected_width || "
        "fb_height != expected_height || fb_bpp != expected_bpp || "
        "fb_pitch != expected_pitch || fb_size != expected_size) return 2;\n"
        "    if (expected_data < 0) return fb_data == NULL ? 0 : 3;\n"
        "    return (unsigned char *)fb_data == "
        "(unsigned char *)image + expected_data ? 0 : 4;\n"
        "}\n"
        "static int check_32(void *image) {\n"
        "    int c_width = -91, c_height = -92, c_bpp = -93;\n"
        "    int c_pitch = -94, c_size = -95;\n"
        "    int fb_width = -91, fb_height = -92, fb_bpp = -93;\n"
        "    int fb_pitch = -94, fb_size = -95;\n"
        "    void *c_data = (void *)1, *fb_data = (void *)1;\n"
        "    int c_result = fb_GfxImageInfo32C(image, &c_width, &c_height, "
        "&c_bpp, &c_pitch, &c_data, &c_size);\n"
        "    int fb_result = fb_GfxImageInfo32(image, &fb_width, &fb_height, "
        "&fb_bpp, &fb_pitch, &fb_data, &fb_size);\n"
        "    return c_result == fb_result && c_width == fb_width && "
        "c_height == fb_height && c_bpp == fb_bpp && c_pitch == fb_pitch && "
        "c_size == fb_size && c_data == fb_data ? 0 : 5;\n"
        "}\n"
        "static int check_64(void *image) {\n"
        "    long long c_width = -91, c_height = -92, c_bpp = -93;\n"
        "    long long c_pitch = -94, c_size = -95;\n"
        "    long long fb_width = -91, fb_height = -92, fb_bpp = -93;\n"
        "    long long fb_pitch = -94, fb_size = -95;\n"
        "    void *c_data = (void *)1, *fb_data = (void *)1;\n"
        "    int c_result = fb_GfxImageInfo64C(image, &c_width, &c_height, "
        "&c_bpp, &c_pitch, &c_data, &c_size);\n"
        "    int fb_result = fb_GfxImageInfo64(image, &fb_width, &fb_height, "
        "&fb_bpp, &fb_pitch, &fb_data, &fb_size);\n"
        "    return c_result == fb_result && c_width == fb_width && "
        "c_height == fb_height && c_bpp == fb_bpp && c_pitch == fb_pitch && "
        "c_size == fb_size && c_data == fb_data ? 0 : 6;\n"
        "}\n"
        "int main(void) {\n"
        "    union { void *alignment; unsigned char bytes[256]; } storage;\n"
        "    PUT_HEADER *header = (PUT_HEADER *)storage.bytes;\n"
        "    int result;\n"
        "    memset(&storage, 0, sizeof(storage));\n"
        "    header->type = PUT_HEADER_NEW;\n"
        "    header->bpp = 4; header->width = 5; header->height = 3;\n"
        "    header->pitch = 24;\n"
        "    result = check_native(header, 0, 5, 3, 4, 24, "
        "(ssize_t)sizeof(PUT_HEADER) + 72, sizeof(PUT_HEADER));\n"
        "    if (result) return 10 + result;\n"
        "    if ((result = check_32(header)) != 0) return 20 + result;\n"
        "    if ((result = check_64(header)) != 0) return 30 + result;\n"
        "    memset(&storage, 0, sizeof(storage));\n"
        "    header->old.bpp = 2; header->old.width = 5; header->old.height = 3;\n"
        "    result = check_native(header, 0, 5, 3, 2, 10, 34, 4);\n"
        "    if (result) return 40 + result;\n"
        "    if ((result = check_32(header)) != 0) return 50 + result;\n"
        "    if ((result = check_64(header)) != 0) return 60 + result;\n"
        "    memset(&storage, 0, sizeof(storage));\n"
        "    result = check_native(header, 1, -1, -1, -1, -1, -1, -1);\n"
        "    if (result) return 70 + result;\n"
        "    if ((result = check_32(header)) != 0) return 80 + result;\n"
        "    if ((result = check_64(header)) != 0) return 90 + result;\n"
        "    result = check_native(NULL, 1, -1, -1, -1, -1, -1, -1);\n"
        "    if (result) return 100 + result;\n"
        "    if ((result = check_32(NULL)) != 0) return 110 + result;\n"
        "    if ((result = check_64(NULL)) != 0) return 120 + result;\n"
        "    return 0;\n"
        "}\n"
    )
    support_object = work / "gfx_image_info_probe.o"
    run(cc + [
        "-std=c99", "-DFB_NO_GFXLIB", "-include", "sys/types.h",
        "-I", str(source_root / "rtlib"),
        "-I", str(source_root / "gfxlib2"),
        "-c", str(probe_source), "-o", str(support_object),
    ], cwd=work)

    integrated_source = source_root / "gfxlib2/arch/linux/x86_64/gfx_image_info.bas"
    integrated_object = work / "gfx_image_info_integrated_basic.o"
    run(fbc + [
        "-mt", "-w", "all", "-d", "FB_NO_GFXLIB",
        "-i", str(source_root.parent / "inc"),
        "-i", str(integrated_source.parent),
        "-c", str(integrated_source), "-o", str(integrated_object),
    ], cwd=work)

    for implementation, module_object in (
        ("candidate", candidate_object),
        ("integrated_basic", integrated_object),
    ):
        executable = work / ("gfx_image_info_" + implementation)
        run(cc + [
            "-std=c99", "-DFB_NO_GFXLIB", "-include", "sys/types.h",
            "-I", str(source_root / "rtlib"),
            "-I", str(source_root / "gfxlib2"),
            str(probe_source),
            str(reference_object), str(module_object),
            "-o", str(executable),
        ], cwd=work)
        run([str(executable)], cwd=work)


def main():
    parser = argparse.ArgumentParser(
        description="Compare GFXLIB2 C2FB candidates with their C routines."
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
    if not (source_root / "gfxlib2/presentation/gfx_vsync.c").is_file():
        parser.error("GFXLIB2 source directory does not contain gfx_vsync.c")
    profile_directory = Path(args.profile_directory).resolve()
    helpers = load_c2fb_tests()
    check_gfx_source_graph(source_root)

    with tempfile.TemporaryDirectory(prefix="c2fb-freebasic-gfx-") as temp:
        work = Path(temp)
        context, header_profile = build_gfx_binding(
            args.converter, cc, source_root, profile_directory, work,
        )
        check_gfx_vsync_prefix_layout(fbc, cc, source_root, work)
        body_profile = (
            profile_directory / "freebasic-linux-glibc-x86_64-body.rsp"
        )
        candidate = work / "gfx_vsync_candidates.bas"
        summary = helpers.run_freebasic_gfx_source_unit(
            args.converter, fbc, cc, source_root,
            "presentation/gfx_vsync.c", candidate,
            context, header_profile, body_profile,
        )
        if "translated 1 simple functions; skipped 0" not in summary:
            raise AssertionError(summary)
        check_vsync_behavior(
            fbc, cc, source_root, candidate.with_suffix(".o"), work,
        )

        image_candidate = work / "gfx_image_info_candidates.bas"
        image_summary = helpers.run_freebasic_gfx_source_unit(
            args.converter, fbc, cc, source_root,
            "image/gfx_image_info.c", image_candidate,
            context, header_profile, body_profile,
            extra_body_options=("--rename-proc-prefix=c2fbGfx_",),
        )
        if "translated 3 simple functions; skipped 0" not in image_summary:
            raise AssertionError(image_summary)
        check_gfx_image_info_behavior(
            fbc, cc, source_root, image_candidate.with_suffix(".o"), work,
        )
        print(
            "GFXLIB2 VSync and image-info: C2FB candidates and Basic ports "
            "match C behavior"
        )


if __name__ == "__main__":
    main()

# end of test_freebasic_gfx.py
