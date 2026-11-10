"""
Project: C2FB FreeBASIC GFXLIB2 tests
File: test_freebasic_gfx_png.py
Purpose: Compare the C2FB PNG codec candidate and Basic port with C.
Responsibilities: Translate, compile, link, and exercise PNG save/load paths.
This file intentionally does NOT contain: PNG codec implementation code.
"""

import argparse
import importlib.util
import platform
from pathlib import Path
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


def load_c2fb_tests():
    sys.dont_write_bytecode = True
    test_path = TEST_DIRECTORY / "test_c2fb.py"
    spec = importlib.util.spec_from_file_location("c2fb_png_test_helpers", test_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load C2FB test helpers from {test_path}")
    helpers = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helpers)
    return helpers


def check_png_codec(fbc, cc, converter, source_root, profile_directory, work):
    helpers = load_c2fb_tests()
    context, header_profile = gfx_tests.build_gfx_binding(
        converter, cc, source_root, profile_directory, work,
    )
    body_profile = profile_directory / "freebasic-linux-glibc-x86_64-body.rsp"
    candidate = work / "gfx_png_candidates.bas"
    summary = helpers.run_freebasic_gfx_source_unit(
        converter, fbc, cc, source_root, "image/gfx_png.c", candidate,
        context, header_profile, body_profile,
        extra_body_options=("--rename-proc-prefix=c2fbGfx_",),
    )
    if "translated 61 simple functions; skipped 0" not in summary:
        raise AssertionError(summary)

    source = source_root / "gfxlib2/image/gfx_png.c"
    reference_source = work / "gfx_png_c_reference.c"
    reference_source.write_text(
        "#define fb_hGfxPngLoad fb_hGfxPngLoadC\n"
        "#define fb_hGfxPngSave fb_hGfxPngSaveC\n"
        f'#include "{source.as_posix()}"\n',
        encoding="utf-8",
    )
    compile_flags = [
        "-std=c99", "-DFB_NO_GFXLIB", "-DENABLE_MT", "-include",
        "sys/types.h", "-I", str(source_root / "rtlib"),
        "-I", str(source_root / "gfxlib2"),
    ]
    reference_object = work / "gfx_png_c_reference.o"
    run(cc + compile_flags + [
        "-c", str(reference_source), "-o", str(reference_object),
    ], cwd=work)

    support_source = work / "gfx_png_probe.c"
    support_source.write_text(
        "#include <stdio.h>\n"
        "#include <stdlib.h>\n"
        "#include <string.h>\n"
        "#include <stdint.h>\n"
        "#include <sys/types.h>\n"
        '#include "gfx_png.h"\n'
        "FBGFX *__fb_gfx;\n"
        "void *(*fb_hMemCpy)(void *, const void *, size_t) = memcpy;\n"
        "void *(*fb_hMemSet)(void *, int, size_t) = memset;\n"
        "void fb_GfxLock(void) {}\n"
        "void fb_GfxUnlock(int start_line, int end_line) {\n"
        "    (void)start_line; (void)end_line;\n"
        "}\n"
        "void fb_hRestorePalette(void) {}\n"
        "void fb_hSetPixelTransfer(FB_GFXCTX *ctx, unsigned int color) {\n"
        "    (void)ctx; (void)color;\n"
        "}\n"
        "void fb_hPrepareTarget(FB_GFXCTX *ctx, void *target) {\n"
        "    PUT_HEADER *header = (PUT_HEADER *)target;\n"
        "    size_t header_size = header->type == PUT_HEADER_NEW ?\n"
        "        sizeof(PUT_HEADER) : 4u;\n"
        "    unsigned int width = header->type == PUT_HEADER_NEW ?\n"
        "        header->width : header->old.width;\n"
        "    unsigned int height = header->type == PUT_HEADER_NEW ?\n"
        "        header->height : header->old.height;\n"
        "    unsigned int bpp = header->type == PUT_HEADER_NEW ?\n"
        "        (unsigned int)header->bpp : header->old.bpp;\n"
        "    unsigned int pitch = header->type == PUT_HEADER_NEW ?\n"
        "        header->pitch : width * bpp;\n"
        "    unsigned int row;\n"
        "    unsigned char *pixels = (unsigned char *)target + header_size;\n"
        "    for (row = 0; row < height && row < (unsigned int)ctx->max_h; row++)\n"
        "        ctx->line[row] = pixels + ((size_t)row * pitch);\n"
        "}\n"
        "int fb_hGfxPngLoadC(FB_GFXCTX *, FILE *, void *, void *, int);\n"
        "int fb_hGfxPngSaveC(FB_GFXCTX *, FILE *, void *, void *, int);\n"
        "static FBGFX gfx_state;\n"
        "static FB_GFXCTX gfx_context;\n"
        "static unsigned char *gfx_lines[16];\n"
        "static unsigned int gfx_palette[256];\n"
        "static char gfx_dirty[16];\n"
        "static void configure_graphics(unsigned int width, unsigned int height,\n"
        "    unsigned int bpp, unsigned int pitch) {\n"
        "    memset(&gfx_state, 0, sizeof(gfx_state));\n"
        "    memset(&gfx_context, 0, sizeof(gfx_context));\n"
        "    memset(gfx_dirty, 0, sizeof(gfx_dirty));\n"
        "    gfx_context.line = gfx_lines;\n"
        "    gfx_context.max_h = (int)height;\n"
        "    gfx_context.target_bpp = (int)bpp;\n"
        "    gfx_context.target_pitch = (int)pitch;\n"
        "    gfx_state.w = (int)width; gfx_state.h = (int)height;\n"
        "    gfx_state.bpp = (int)bpp; gfx_state.pitch = (int)pitch;\n"
        "    gfx_state.device_palette = gfx_palette;\n"
        "    gfx_state.framebuffer = NULL; gfx_state.dirty = gfx_dirty;\n"
        "    __fb_gfx = &gfx_state;\n"
        "}\n"
        "static size_t read_file(FILE *file, unsigned char *buffer, size_t capacity) {\n"
        "    long size;\n"
        "    if (fflush(file) != 0 || fseek(file, 0, SEEK_END) != 0) return 0;\n"
        "    size = ftell(file);\n"
        "    if (size < 0 || (size_t)size > capacity || fseek(file, 0, SEEK_SET) != 0) return 0;\n"
        "    return fread(buffer, 1, (size_t)size, file);\n"
        "}\n"
        "static void write_be32(unsigned char *p, uint32_t value) {\n"
        "    p[0] = (unsigned char)(value >> 24); p[1] = (unsigned char)(value >> 16);\n"
        "    p[2] = (unsigned char)(value >> 8); p[3] = (unsigned char)value;\n"
        "}\n"
        "static int load_pair(const unsigned char *png, size_t png_size,\n"
        "    unsigned int width, unsigned int height, unsigned int bpp,\n"
        "    int expect_success) {\n"
        "    FILE *c_file = tmpfile(), *fb_file = tmpfile();\n"
        "    union { void *align; unsigned char bytes[4096]; } c_dest, fb_dest;\n"
        "    unsigned int c_palette[256], fb_palette[256];\n"
        "    PUT_HEADER *c_header = (PUT_HEADER *)c_dest.bytes;\n"
        "    PUT_HEADER *fb_header = (PUT_HEADER *)fb_dest.bytes;\n"
        "    unsigned int pitch = (width * bpp + 15u) & ~15u;\n"
        "    void *c_pal = bpp == 1u ? c_palette : NULL;\n"
        "    void *fb_pal = bpp == 1u ? fb_palette : NULL;\n"
        "    int c_result, fb_result; unsigned int row;\n"
        "    if (!c_file || !fb_file) return 10;\n"
        "    if (fwrite(png, 1, png_size, c_file) != png_size ||\n"
        "        fwrite(png, 1, png_size, fb_file) != png_size) return 11;\n"
        "    rewind(c_file); rewind(fb_file);\n"
        "    memset(c_dest.bytes, 0xCD, sizeof(c_dest.bytes));\n"
        "    memset(fb_dest.bytes, 0xCD, sizeof(fb_dest.bytes));\n"
        "    c_header->type = PUT_HEADER_NEW; c_header->bpp = (int)bpp;\n"
        "    c_header->width = width; c_header->height = height; c_header->pitch = pitch;\n"
        "    fb_header->type = PUT_HEADER_NEW; fb_header->bpp = (int)bpp;\n"
        "    fb_header->width = width; fb_header->height = height; fb_header->pitch = pitch;\n"
        "    memset(c_palette, 0xA5, sizeof(c_palette));\n"
        "    memset(fb_palette, 0xA5, sizeof(fb_palette));\n"
        "    configure_graphics(width, height, bpp, pitch);\n"
        "    c_result = fb_hGfxPngLoadC(&gfx_context, c_file, c_dest.bytes, c_pal, 0);\n"
        "    configure_graphics(width, height, bpp, pitch);\n"
        "    fb_result = fb_hGfxPngLoad(&gfx_context, fb_file, fb_dest.bytes, fb_pal, 0);\n"
        "    fclose(c_file); fclose(fb_file);\n"
        "    if (c_result != fb_result) return 12;\n"
        "    if (!expect_success) return c_result == 0 ? 13 : 0;\n"
        "    if (c_result != 0) return 14;\n"
        "    for (row = 0; row < height; row++) {\n"
        "        size_t bytes = (size_t)width * bpp;\n"
        "        unsigned char *c_pixels = c_dest.bytes + sizeof(PUT_HEADER) + ((size_t)row * pitch);\n"
        "        unsigned char *fb_pixels = fb_dest.bytes + sizeof(PUT_HEADER) + ((size_t)row * pitch);\n"
        "        if (memcmp(c_pixels, fb_pixels, bytes) != 0) return 15;\n"
        "    }\n"
        "    if (bpp == 1u && memcmp(c_palette, fb_palette, sizeof(c_palette)) != 0) return 16;\n"
        "    return 0;\n"
        "}\n"
        "static int run_case(unsigned int bpp, int bits, unsigned int output_bpp,\n"
        "    unsigned int width, unsigned int height) {\n"
        "    union { void *align; unsigned char bytes[4096]; } source;\n"
        "    PUT_HEADER *header = (PUT_HEADER *)source.bytes;\n"
        "    unsigned char *pixels; unsigned int palette[256];\n"
        "    unsigned int x, y, i, pitch = (width * bpp + 15u) & ~15u;\n"
        "    FILE *c_file = tmpfile(), *fb_file = tmpfile();\n"
        "    unsigned char c_png[65536], fb_png[65536], corrupt[65536];\n"
        "    size_t c_size, fb_size; int c_result, fb_result;\n"
        "    if (!c_file || !fb_file || sizeof(PUT_HEADER) + pitch * height > sizeof(source.bytes)) return 20;\n"
        "    memset(&source, 0, sizeof(source));\n"
        "    header->type = PUT_HEADER_NEW; header->bpp = (int)bpp;\n"
        "    header->width = width; header->height = height; header->pitch = pitch;\n"
        "    pixels = source.bytes + sizeof(PUT_HEADER);\n"
        "    for (i = 0; i < 256u; i++) {\n"
        "        unsigned int red = (i * 5u + 3u) & 63u;\n"
        "        unsigned int green = (i * 9u + 7u) & 63u;\n"
        "        unsigned int blue = (i * 13u + 11u) & 63u;\n"
        "        palette[i] = red | (green << 8) | (blue << 16);\n"
        "    }\n"
        "    for (y = 0; y < height; y++) for (x = 0; x < width; x++) {\n"
        "        if (bpp == 1u) pixels[y*pitch+x] = (unsigned char)((x + 3u*y) & 7u);\n"
        "        else if (bpp == 2u) {\n"
        "            uint16_t value = (uint16_t)((((x*3u+y)&31u)<<11) | (((x*5u+y*7u)&63u)<<5) | ((x*11u+y*13u)&31u));\n"
        "            memcpy(pixels + y*pitch + 2u*x, &value, sizeof(value));\n"
        "        } else {\n"
        "            uint32_t value = ((x*13u+y*23u)&255u)<<24 | ((x*11u+y*3u)&255u)<<16 | ((x*5u+y*17u)&255u)<<8 | ((x*19u+y*7u)&255u);\n"
        "            memcpy(pixels + y*pitch + 4u*x, &value, sizeof(value));\n"
        "        }\n"
        "    }\n"
        "    configure_graphics(width, height, bpp, pitch);\n"
        "    c_result = fb_hGfxPngSaveC(&gfx_context, c_file, source.bytes, bpp == 1u ? palette : NULL, bits);\n"
        "    configure_graphics(width, height, bpp, pitch);\n"
        "    fb_result = fb_hGfxPngSave(&gfx_context, fb_file, source.bytes, bpp == 1u ? palette : NULL, bits);\n"
        "    if (c_result != fb_result || c_result != 0) return 21;\n"
        "    c_size = read_file(c_file, c_png, sizeof(c_png));\n"
        "    fb_size = read_file(fb_file, fb_png, sizeof(fb_png));\n"
        "    fclose(c_file); fclose(fb_file);\n"
        "    if (c_size == 0 || c_size != fb_size || memcmp(c_png, fb_png, c_size) != 0) return 22;\n"
        "    if (load_pair(c_png, c_size, width, height, output_bpp, 1) != 0) return 23;\n"
        "    memcpy(corrupt, c_png, c_size);\n"
        "    for (i = 8; i + 8u < c_size; ) {\n"
        "        uint32_t chunk_size = ((uint32_t)corrupt[i]<<24)|((uint32_t)corrupt[i+1]<<16)|((uint32_t)corrupt[i+2]<<8)|corrupt[i+3];\n"
        "        if (i + 12u + chunk_size > c_size) return 24;\n"
        "        if (memcmp(corrupt+i+4u, \"IDAT\", 4) == 0 && chunk_size > 0u) { corrupt[i+8u] ^= 1u; break; }\n"
        "        i += 12u + chunk_size;\n"
        "    }\n"
        "    if (i + 8u >= c_size) return 25;\n"
        "    return load_pair(corrupt, c_size, width, height, output_bpp, 0) == 0 ? 0 : 26;\n"
        "}\n"
        "int main(void) {\n"
        "    int result;\n"
        "    result = run_case(4u, 32, 4u, 7u, 5u); if (result) return result;\n"
        "    result = run_case(2u, 16, 2u, 5u, 4u); if (result) return result;\n"
        "    result = run_case(1u, 8, 1u, 7u, 5u); if (result) return result;\n"
        "    result = run_case(1u, 24, 4u, 7u, 5u); if (result) return result;\n"
        "    puts(\"GFXPNG_C2FB_PARITY_PASS\"); return 0;\n"
        "}\n",
        encoding="utf-8",
    )


    support_object = work / "gfx_png_probe.o"
    run(cc + compile_flags + [
        "-c", str(support_source), "-o", str(support_object),
    ], cwd=work)

    basic_source = source_root / "gfxlib2/arch/linux/x86_64/gfx_png.bas"
    basic_object = work / "gfx_png_integrated_basic.o"
    run(fbc + [
        "-mt", "-w", "all", "-d", "FB_NO_GFXLIB",
        "-i", str(source_root.parent / "inc"),
        "-i", str(basic_source.parent),
        "-c", str(basic_source), "-o", str(basic_object),
    ], cwd=work)

    for name, module_object in (
        ("candidate", candidate.with_suffix(".o")),
        ("integrated_basic", basic_object),
    ):
        executable = work / ("gfx_png_" + name)
        run(cc + [
            str(support_object), str(reference_object),
            str(module_object), "-o", str(executable),
        ], cwd=work)
        output = run([str(executable)], cwd=work)
        if "GFXPNG_C2FB_PARITY_PASS" not in output:
            raise AssertionError(output)
    print(
        "GFXLIB2 PNG: C2FB candidate and Basic port match C for RGBA, "
        "RGB565, indexed, indexed-to-RGB, and corrupt-chunk cases"
    )


def main():
    parser = argparse.ArgumentParser(
        description="Compare the C2FB GFXLIB2 PNG codec candidate with C."
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
    converter = str(Path(args.converter).resolve())
    source_root = Path(args.source_directory).resolve()
    if not (source_root / "gfxlib2/image/gfx_png.c").is_file():
        parser.error("GFXLIB2 source directory does not contain gfx_png.c")
    if not (source_root / "gfxlib2/arch/linux/x86_64/gfx_png.bas").is_file():
        parser.error("Linux x86-64 Basic PNG port is missing")
    profile_directory = Path(args.profile_directory).resolve()
    gfx_tests.check_gfx_source_graph(source_root)

    with tempfile.TemporaryDirectory(prefix="c2fb-freebasic-gfx-png-") as temp:
        check_png_codec(
            fbc, cc, converter, source_root, profile_directory, Path(temp),
        )


if __name__ == "__main__":
    main()

# end of test_freebasic_gfx_png.py
