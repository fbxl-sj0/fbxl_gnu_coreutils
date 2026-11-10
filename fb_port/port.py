#!/usr/bin/env python3
"""
Project: GNU Coreutils FreeBASIC port
File: port.py
Purpose: Reproduce the reference build and conversion inventory.
Responsibilities: Capture real production compiler flags, invoke the original
C2FB tools, and report candidate compilation, untranslated functions, and
missing global symbols relative to the C reference objects. Re-index saved
compiler captures without rebuilding the C reference tree.
This file intentionally does NOT contain: C parsing, translation rules, or a
replacement for the upstream Coreutils test suite.
"""

import argparse
from collections import Counter
import csv
import fnmatch
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


PORT = Path(__file__).resolve().parent
SOURCE = Path(os.environ.get("COREUTILS_SOURCE", str(PORT.parent))).resolve()
REFERENCE = PORT / "build/reference"
DEFAULT_C2FB_TOOLS = PORT / "tools/c2fb"
TOOLS = Path(os.environ.get("COREUTILS_C2FB_TOOLS", str(DEFAULT_C2FB_TOOLS))).resolve()
DEFAULT_C2FB_CONVERTER = TOOLS / "build/c2fb"
C2FB_CONVERTER_OVERRIDE = os.environ.get("COREUTILS_C2FB_CONVERTER")
C2FB_CONVERTER = Path(
    C2FB_CONVERTER_OVERRIDE or DEFAULT_C2FB_CONVERTER
).resolve()
FBC_SOURCE_VALUE = os.environ.get("COREUTILS_FBC_SOURCE")
FBC_SOURCE = Path(FBC_SOURCE_VALUE).resolve() if FBC_SOURCE_VALUE else None
TOOLCHAIN_DIRECTORY = PORT / "build/toolchain/freebasic"
TOOLCHAIN_FBC = TOOLCHAIN_DIRECTORY / "bin/fbc"
# Use the installed compiler's include/library paths. A checkout-local binary
# needs a matching installation layout; the port build keeps its own FBC copy.
FBC_VALUE = os.environ.get("COREUTILS_FBC")
FBC = Path(FBC_VALUE).resolve() if FBC_VALUE else Path(
    str(TOOLCHAIN_FBC if TOOLCHAIN_FBC.is_file()
        else (shutil.which("fbc") or "/usr/bin/fbc"))
)
if FBC_SOURCE:
    DEFAULT_FBC_INCLUDE_DIR = FBC_SOURCE / "inc"
    DEFAULT_FBC_RUNTIME_LIBDIR = FBC_SOURCE / "lib/freebasic/linux-x86_64"
else:
    FBC_PREFIX = FBC.resolve().parent.parent
    DEFAULT_FBC_INCLUDE_DIR = FBC_PREFIX / "include/freebasic"
    DEFAULT_FBC_RUNTIME_LIBDIR = FBC_PREFIX / "lib/freebasic/linux-x86_64"
FBC_INCLUDE_DIR = Path(os.environ.get(
    "COREUTILS_FBC_INCLUDE", str(DEFAULT_FBC_INCLUDE_DIR)
)).resolve()
FBC_RUNTIME_LIBDIR_VALUE = os.environ.get("COREUTILS_FBC_RUNTIME_LIBDIR")
FBC_RUNTIME_LIBDIR = (
    Path(FBC_RUNTIME_LIBDIR_VALUE).resolve()
    if FBC_RUNTIME_LIBDIR_VALUE
    else DEFAULT_FBC_RUNTIME_LIBDIR
)
HEADER_OPTIONS = [
    "--emit-source=*",
    # Declare the FreeBASIC va_list type before emitting its C aliases.
    "--fb-include=crt/stdarg.bi",
    # Use FreeBASIC's C ABI definition for setjmp buffers.
    "--fb-include=crt/setjmp.bi",
    "--fb-include=fb_port/coreutils_glibc_abi.bi",
    "--fb-include=fb_port/coreutils_oputs_support.bi",
    "--fb-include=fb_port/coreutils_mcel_support.bi",
    "--fb-include=fb_port/coreutils_dtimespec_support.bi",
    # Keep C half-float storage at two bytes; C2FB supplies bit conversions
    # when these values cross into the C float formatting APIs.
    "--type-map=_Float16=UShort",
    "--type-map=__bf16=UShort",
    # Match glibc's x86-64 variadic ABI to the FreeBASIC CRT representation.
    "--type-map=__gnuc_va_list=Cva_List",
    "--type-map=__builtin_va_list=Cva_List",
    # The captured Linux x86-64 compiler defines size_t as unsigned long.
    "--type-map=size_t=CULong",
    # Preserve the 32-byte, 16-aligned glibc max_align_t carrier.
    "--type-map=max_align_t=CoreutilsGlibcMaxAlign",
    # The carrier is declared in FreeBASIC, outside the C header pass.
    "--type-alignment=max_align_t=16",
    # glibc defines jmp_buf as an array of __jmp_buf_tag; FBC represents the
    # same ABI storage as one jmp_buf record.
    "--type-map=jmp_buf=jmp_buf",
    "--type-map=__jmp_buf_tag=jmp_buf",
    # The reference x86-64 compiler evaluates BIN_TREE_STORAGE_SIZE to 15;
    # its sizeof(bin_tree_t) bound contains bitfields outside C2FB's evaluator.
    "--array-size=bin_tree_storage_t.data=15",
    "--rename-proc=settime=c2fb_settime",
]
BODY_OPTIONS = [
    "--include-global-definitions",
    "--include-included-c-source-bodies",
    "--include-header-inline-body=oputs_",
    # Digest and transfer statistics share this bounded plural-selection helper.
    "--include-header-inline-body=select_plural",
    # Select the complete extern-inline dependency chain from lib/mcel.h.
    "--include-header-inline-body=mcel_scanz",
    "--include-header-inline-body=mcel_scant",
    "--include-header-inline-body=mcel_scan",
    "--include-header-inline-body=mcel_ch",
    "--include-header-inline-body=mcel_err",
    "--include-header-inline-body=mcel_isbasic",
    # sleep, tail, and timeout share this gnulib floating-point bound helper.
    "--include-header-inline-body=dtimespec_bound",
    # Gnulib quoting initializes the C multibyte conversion state with this helper.
    "--include-header-inline-body=mbszero",
    # The regex engine's bitset lookups use this static inline header helper.
    "--include-header-inline-body=bitset_contain",
    "--replacement-file=" + str(PORT / "replacements/coreutils-oputs.rpl"),
    "--replacement-file=" + str(PORT / "replacements/coreutils-mcel.rpl"),
    "--replacement-file=" + str(PORT / "replacements/coreutils-dtimespec.rpl"),
    "--type-map=__gnuc_va_list=Cva_List",
    "--type-map=__builtin_va_list=Cva_List",
    # Keep size_t's LP64 type exact for C varargs such as printf("%zu").
    "--type-map=size_t=CULong",
    # Preserve the 32-byte, 16-aligned glibc max_align_t carrier.
    "--type-map=max_align_t=CoreutilsGlibcMaxAlign",
    "--type-map=jmp_buf=jmp_buf",
    "--type-map=__jmp_buf_tag=jmp_buf",
    # sort shares md5_ctx storage between header APIs and its local arrays.
    "--type-map=md5_ctx=c2fb_md5_ctx_",
    "--rename-proc=settime=c2fb_settime",
]
# C2FB translates source APIs rather than compiler-generated inline bodies.
# glibc's optimized fwrite wrapper expands into GCC statement expressions, so
# disable extern-inline bodies while preserving __OPTIMIZE__ source branches.
# Gnulib's error wrapper also adds compiler-only control-flow annotations.
BODY_COMPILER_OPTIONS = [
    "-D__NO_CTYPE",
    "-D_GL_NO_INLINE_ERROR",
    "-D__NO_INLINE__",
]
# factor.c already supplies portable C implementations for its longlong macros.
# Select those bodies during C2FB conversion so the output does not depend on
# x86 GNU inline assembly emitted by the reference compiler headers.
SOURCE_BODY_COMPILER_OPTIONS = (
    ("src/factor.c", "-DUSE_LONGLONG_H=0"),
    # C2FB translates the numeric body; the FreeBASIC profile restores its
    # scoped x87 precision control with coreutils_x87_support.bi.
    ("lib/printf-frexpl.c", "-D__FILC__"),
    ("lib/frexpl.c", "-D__FILC__"),
    # Use memchr2's bytewise fallback. The aligned longword path relies on
    # aliasing and reads past a short object's boundary, which is unsuitable
    # for this FreeBASIC translation target.
    ("lib/memchr2.c", "-D__SANITIZE_ADDRESS__"),
    # Use system.h's portable alloca+memcpy block instead of glibc strdupa's
    # GNU statement expression when translating cp.c.
    ("src/cp.c", "-include"),
    ("src/cp.c", str(PORT / "coreutils_cp_preinclude.h")),
    # The source-level AVX2 projection replaces x86intrin.h only for C2FB.
    ("src/cksum_avx2.c", "-I" + str(PORT / "cksum_avx2_intrinsics")),
    # The same byte-addressable vector type is used by the AVX2 wc loop.
    ("src/wc_avx2.c", "-I" + str(PORT / "cksum_avx2_intrinsics")),
    # The source-level PCLMUL projection replaces x86intrin.h only for C2FB.
    ("src/cksum_pclmul.c", "-I" + str(PORT / "cksum_pclmul_intrinsics")),
    # The source-level AVX-512 projection replaces x86intrin.h only for C2FB.
    ("src/cksum_avx512.c", "-I" + str(PORT / "cksum_avx512_intrinsics")),
    # The wc AVX-512 loop uses the same 64-byte record projection.
    ("src/wc_avx512.c", "-I" + str(PORT / "cksum_avx512_intrinsics")),
    # Use the same 128-bit projection for the library CRC folding routine.
    ("lib/crc-x86_64-pclmul.c", "-I" + str(PORT / "cksum_pclmul_intrinsics")),
)
SOURCE_HEADER_OPTIONS = (
    # localeinfo.h's casted -1 bounds need explicit sizes for record fields.
    ("lib/localeinfo.c", "--array-size=localeinfo.sbclen=256"),
    ("lib/localeinfo.c", "--array-size=localeinfo.sbctowc=256"),
    ("lib/printf-frexpl.c", "--fb-include=fb_port/coreutils_x87_support.bi"),
    ("lib/frexpl.c", "--fb-include=fb_port/coreutils_x87_support.bi"),
    # Give C2FB's header pass the same 32-byte carrier and type map as the body.
    ("src/cksum_avx2.c", "--type-map=__m256i=c2fb_avx2_vector256"),
    ("src/cksum_avx2.c", "--type-map=__m256i_u=c2fb_avx2_vector256"),
    ("src/wc_avx2.c", "--type-map=__m256i=c2fb_avx2_vector256"),
    ("src/wc_avx2.c", "--type-map=__m256i_u=c2fb_avx2_vector256"),
    # Give C2FB's header pass the same 16-byte carrier and type map as the body.
    ("src/cksum_pclmul.c", "--type-map=__m128i=c2fb_pclmul_vector128"),
    ("src/cksum_pclmul.c", "--type-map=__m128i_u=c2fb_pclmul_vector128"),
    ("lib/crc-x86_64-pclmul.c", "--type-map=__m128i=c2fb_pclmul_vector128"),
    ("lib/crc-x86_64-pclmul.c", "--type-map=__m128i_u=c2fb_pclmul_vector128"),
    ("src/cksum_avx512.c", "--type-map=__m512i=c2fb_avx512_vector512"),
    ("src/cksum_avx512.c", "--type-map=__m512i_u=c2fb_avx512_vector512"),
    ("src/wc_avx512.c", "--type-map=__m512i=c2fb_avx512_vector512"),
    ("src/wc_avx512.c", "--type-map=__m512i_u=c2fb_avx512_vector512"),
)
SOURCE_HEADER_COMPILER_OPTIONS = (
    ("src/cksum_avx2.c", "-I" + str(PORT / "cksum_avx2_intrinsics")),
    ("src/wc_avx2.c", "-I" + str(PORT / "cksum_avx2_intrinsics")),
    ("src/cksum_pclmul.c", "-I" + str(PORT / "cksum_pclmul_intrinsics")),
    ("lib/crc-x86_64-pclmul.c", "-I" + str(PORT / "cksum_pclmul_intrinsics")),
    ("src/cksum_avx512.c", "-I" + str(PORT / "cksum_avx512_intrinsics")),
    ("src/wc_avx512.c", "-I" + str(PORT / "cksum_avx512_intrinsics")),
)
SOURCE_FB_POST_TYPE_INCLUDES = (
    ("lib/mbbuf.c", "fb_port/coreutils_mcel_prototypes.bi"),
    ("lib/mbsstr.c", "fb_port/coreutils_mcel_prototypes.bi"),
    ("lib/exclude.c", "fb_port/coreutils_mcel_prototypes.bi"),
)
SOURCE_FB_POST_DECLARATION_INCLUDES = (
    ("src/cksum_vmull.c", "fb_port/coreutils_cksum_vmull_scalar.bi"),
    ("src/wc_neon.c", "fb_port/coreutils_wc_neon_scalar.bi"),
)
# The chown source units are linked together. Use the shared mbszero
# implementation instead of emitting its external-inline header body twice.
SOURCE_C2FB_OPTIONS = (
    # mcel.c owns shared multibyte helpers used by mbsstr.c. Keep the KMP
    # callers as external references when their inline header copies are
    # excluded; mbszero.c is the owner of the shared state-reset helper.
    ("lib/mbsstr.c", "--keep-unresolved=1"),
    ("lib/mbsstr.c", "--exclude-proc=mbszero"),
    ("lib/mbsstr.c", "--exclude-proc=mcel_ch"),
    ("lib/mbsstr.c", "--exclude-proc=mcel_err"),
    ("lib/mbsstr.c", "--exclude-proc=mcel_isbasic"),
    ("lib/mbsstr.c", "--exclude-proc=mcel_scan"),
    ("lib/mbsstr.c", "--exclude-proc=mcel_scant"),
    ("lib/mbsstr.c", "--exclude-proc=mcel_scanz"),
    # The narrow and wide included fnmatch loops use block-local flexible
    # pattern tails; one element preserves the active target's C layout.
    ("lib/fnmatch.c", "--array-size=patternlist.str=1"),
    # Keep the SHA stream callbacks on the same context-record type as the
    # external init/finalize functions.
    ("lib/sha256-stream.c", "--type-map=sha256_ctx=c2fb_sha256_ctx_"),
    ("lib/sha512-stream.c", "--type-map=sha512_ctx=c2fb_sha512_ctx_"),
    # cat.c reaches this inline sizing helper from main's input setup; include
    # its C2FB body so the translated entrypoint has no unresolved C body.
    ("src/cat.c", "--include-header-inline-body=io_blksize"),
    ("src/cat.c", "--include-header-inline-body=stdc_leading_zeros_ull"),
    ("src/cat.c", "--include-header-inline-body=__clz64_inline"),
    # split.c uses the same GNU buffer-sizing helper before reading input.
    ("src/split.c", "--include-header-inline-body=io_blksize"),
    ("src/split.c", "--include-header-inline-body=stdc_leading_zeros_ull"),
    ("src/split.c", "--include-header-inline-body=__clz64_inline"),
    # Translate the AVX2 newline counter through the byte-record helpers.
    ("src/wc_avx2.c", "--type-map=__m256i=c2fb_avx2_vector256"),
    ("src/wc_avx2.c", "--type-map=__m256i_u=c2fb_avx2_vector256"),
    ("src/wc_avx2.c", "--include-header-inline-body=_mm256_set1_epi8"),
    ("src/wc_avx2.c", "--include-header-inline-body=_mm256_load_si256"),
    ("src/wc_avx2.c", "--include-header-inline-body=_mm256_cmpeq_epi8"),
    ("src/wc_avx2.c", "--include-header-inline-body=_mm256_movemask_epi8"),
    ("src/wc_avx2.c", "--exclude-proc=mbszero"),
    # Translate the AVX-512 newline counter through the 64-byte record helpers.
    ("src/wc_avx512.c", "--type-map=__m512i=c2fb_avx512_vector512"),
    ("src/wc_avx512.c", "--type-map=__m512i_u=c2fb_avx512_vector512"),
    ("src/wc_avx512.c", "--include-header-inline-body=_mm512_set1_epi8"),
    ("src/wc_avx512.c", "--include-header-inline-body=_mm512_load_si512"),
    ("src/wc_avx512.c", "--include-header-inline-body=_mm512_cmpeq_epi8_mask"),
    ("src/wc_avx512.c", "--exclude-proc=mbszero"),
    # The AVX2 body uses a 32-byte record projection with translated intrinsic
    # helpers, so keep the original checksum function in the FreeBASIC output.
    ("src/cksum_avx2.c", "--type-map=__m256i=c2fb_avx2_vector256"),
    ("src/cksum_avx2.c", "--type-map=__m256i_u=c2fb_avx2_vector256"),
    ("src/cksum_avx2.c", "--include-header-inline-body=_mm256_set_epi64x"),
    ("src/cksum_avx2.c", "--include-header-inline-body=_mm256_set_epi8"),
    ("src/cksum_avx2.c", "--include-header-inline-body=_mm256_set_epi32"),
    ("src/cksum_avx2.c", "--include-header-inline-body=_mm256_loadu_si256"),
    ("src/cksum_avx2.c", "--include-header-inline-body=_mm256_storeu_si256"),
    ("src/cksum_avx2.c", "--include-header-inline-body=_mm256_xor_si256"),
    ("src/cksum_avx2.c", "--include-header-inline-body=_mm256_shuffle_epi8"),
    ("src/cksum_avx2.c", "--include-header-inline-body=_mm256_clmulepi64_epi128"),
    ("src/cksum_avx2.c", "--exclude-proc=mbszero"),
    # The PCLMUL body uses a 16-byte record projection with translated helpers.
    ("src/cksum_pclmul.c", "--type-map=__m128i=c2fb_pclmul_vector128"),
    ("src/cksum_pclmul.c", "--type-map=__m128i_u=c2fb_pclmul_vector128"),
    ("src/cksum_pclmul.c", "--include-header-inline-body=_mm_set_epi64x"),
    ("src/cksum_pclmul.c", "--include-header-inline-body=_mm_set_epi8"),
    ("src/cksum_pclmul.c", "--include-header-inline-body=_mm_set_epi32"),
    ("src/cksum_pclmul.c", "--include-header-inline-body=_mm_loadu_si128"),
    ("src/cksum_pclmul.c", "--include-header-inline-body=_mm_storeu_si128"),
    ("src/cksum_pclmul.c", "--include-header-inline-body=_mm_xor_si128"),
    ("src/cksum_pclmul.c", "--include-header-inline-body=_mm_shuffle_epi8"),
    ("src/cksum_pclmul.c", "--include-header-inline-body=_mm_clmulepi64_si128"),
    ("src/cksum_pclmul.c", "--exclude-proc=mbszero"),
    # Translate the library CRC fold body through the same 16-byte record API.
    ("lib/crc-x86_64-pclmul.c", "--type-map=__m128i=c2fb_pclmul_vector128"),
    ("lib/crc-x86_64-pclmul.c", "--type-map=__m128i_u=c2fb_pclmul_vector128"),
    ("lib/crc-x86_64-pclmul.c", "--include-header-inline-body=_mm_set_epi64x"),
    ("lib/crc-x86_64-pclmul.c", "--include-header-inline-body=_mm_set_epi32"),
    ("lib/crc-x86_64-pclmul.c", "--include-header-inline-body=_mm_loadu_si128"),
    ("lib/crc-x86_64-pclmul.c", "--include-header-inline-body=_mm_storeu_si128"),
    ("lib/crc-x86_64-pclmul.c", "--include-header-inline-body=_mm_xor_si128"),
    ("lib/crc-x86_64-pclmul.c", "--include-header-inline-body=_mm_clmulepi64_si128"),
    ("lib/crc-x86_64-pclmul.c", "--include-header-inline-body=_mm_and_si128"),
    ("lib/crc-x86_64-pclmul.c", "--include-header-inline-body=_mm_srli_si128"),
    ("lib/crc-x86_64-pclmul.c", "--include-header-inline-body=_mm_cvtsi128_si32"),
    # The AVX-512 body uses a 64-byte record projection with translated helpers.
    ("src/cksum_avx512.c", "--type-map=__m512i=c2fb_avx512_vector512"),
    ("src/cksum_avx512.c", "--type-map=__m512i_u=c2fb_avx512_vector512"),
    ("src/cksum_avx512.c", "--include-header-inline-body=_mm512_set_epi64"),
    ("src/cksum_avx512.c", "--include-header-inline-body=_mm512_set_epi8"),
    ("src/cksum_avx512.c", "--include-header-inline-body=_mm512_set_epi32"),
    ("src/cksum_avx512.c", "--include-header-inline-body=_mm512_loadu_si512"),
    ("src/cksum_avx512.c", "--include-header-inline-body=_mm512_storeu_si512"),
    ("src/cksum_avx512.c", "--include-header-inline-body=_mm512_xor_si512"),
    ("src/cksum_avx512.c", "--include-header-inline-body=_mm512_shuffle_epi8"),
    ("src/cksum_avx512.c", "--include-header-inline-body=_mm512_clmulepi64_epi128"),
    ("src/cksum_avx512.c", "--exclude-proc=mbszero"),
    ("src/cksum_vmull.c", "--exclude-proc=bswap_neon"),
    ("src/cksum_vmull.c", "--exclude-proc=cksum_vmull"),
    ("src/cksum_vmull.c", "--exclude-proc=mbszero"),
    ("src/wc_neon.c", "--exclude-proc=wc_lines_neon"),
    ("src/wc_neon.c", "--exclude-proc=mbszero"),
    # The noinst limits probe uses the shared inline mbszero provider.
    ("src/getlimits.c", "--exclude-proc=mbszero"),
    # The shared file-copy helper uses the same buffer-size inline chain.
    ("src/copy-file-data.c", "--include-header-inline-body=io_blksize"),
    ("src/copy-file-data.c", "--include-header-inline-body=stdc_leading_zeros_ull"),
    ("src/copy-file-data.c", "--include-header-inline-body=__clz64_inline"),
    # This file does not call mbszero; avoid exporting the selected header body.
    ("src/copy-file-data.c", "--exclude-proc=mbszero"),
    # copy.c does not call mbszero either; its C library object already provides it.
    ("src/copy.c", "--exclude-proc=mbszero"),
    # cp.c also relies on the separately built shared implementation.
    ("src/cp.c", "--exclude-proc=mbszero"),
    # The cp auxiliary objects use the same provider from libcoreutils.a.
    ("src/cp-hash.c", "--exclude-proc=mbszero"),
    ("src/force-link.c", "--exclude-proc=mbszero"),
    ("src/selinux.c", "--exclude-proc=mbszero"),
    # rm.c and the shared remove.c object both use libcoreutils' provider.
    ("src/rm.c", "--exclude-proc=mbszero"),
    ("src/remove.c", "--exclude-proc=mbszero"),
    # find-mount-point.c's duplicate header body is supplied by df.c here.
    ("src/find-mount-point.c", "--exclude-proc=mbszero"),
    # These mv.c helpers are provided out of line by libcoreutils.a.
    ("src/mv.c", "--exclude-proc=mbszero"),
    ("src/mv.c", "--exclude-proc=streq"),
    ("src/mv.c", "--exclude-proc=priv_set_remove_linkdir"),
    ("src/mv.c", "--exclude-proc=target_dirfd_valid"),
    # mkdir.c does not use the shared multibyte-zeroing helper.
    ("src/mkdir.c", "--exclude-proc=mbszero"),
    # chmod.c's C library object gets mbszero from libcoreutils.a.
    ("src/chmod.c", "--exclude-proc=mbszero"),
    # ln.c also uses the shared multibyte-zeroing implementation.
    ("src/ln.c", "--exclude-proc=mbszero"),
    # join.c includes the two comparison helpers that otherwise pull
    # libcoreutils.a's mcel object, which also defines the scan helpers.
    ("src/join.c", "--exclude-proc=mbszero"),
    ("src/join.c", "--include-header-inline-body=mcel_cmp"),
    ("src/join.c", "--include-header-inline-body=mcel_eq"),
    # date.c and the generated show-date.c link together, so share mbszero
    # from the translated lib/mbszero.c archive member.
    ("src/date.c", "--exclude-proc=mbszero"),
    ("src/show-date.c", "--exclude-proc=mbszero"),
    # expr.c's multibyte scan chain also pulls libcoreutils.a's mcel object.
    ("src/expr.c", "--include-header-inline-body=mcel_cmp"),
    ("src/expr.c", "--include-header-inline-body=mcel_eq"),
    ("src/chown.c", "--exclude-proc=mbszero"),
    ("src/chown-core.c", "--exclude-proc=mbszero"),
    # On Linux, binary-io.h's O_BINARY=0 header bodies provide both wrappers.
    ("lib/binary-io.c", "--include-header-inline-body=_gl_set_fd_mode"),
    ("lib/binary-io.c", "--include-header-inline-body=set_binary_mode"),
    # strftime.c stores these included calendar functions in static records.
    ("lib/nstrftime.c", "--include-header-body=gregorian_to_thai"),
    ("lib/nstrftime.c", "--include-header-body=gregorian_to_persian"),
    ("lib/nstrftime.c", "--include-header-body=gregorian_to_ethiopian"),
    ("lib/fprintftime.c", "--include-header-body=gregorian_to_thai"),
    ("lib/fprintftime.c", "--include-header-body=gregorian_to_persian"),
    ("lib/fprintftime.c", "--include-header-body=gregorian_to_ethiopian"),
    # The chmodat.c and chownat.c translation units export openat.h inline
    # wrappers; select their exact C bodies in the owning source contexts.
    ("lib/chmodat.c", "--include-header-inline-body=chmodat"),
    ("lib/chmodat.c", "--include-header-inline-body=lchmodat"),
    ("lib/chownat.c", "--include-header-inline-body=chownat"),
    ("lib/chownat.c", "--include-header-inline-body=lchownat"),
    # sort's command-line path uses this system.h exit-status helper.
    ("src/sort.c", "--include-header-inline-body=initialize_exit_failure"),
    # cut's C set-fields.o needs mcel_eq; its inline body also uses mcel_cmp.
    ("src/cut.c", "--include-header-inline-body=mcel_cmp"),
    ("src/cut.c", "--include-header-inline-body=mcel_eq"),
    # cut.c's selected multibyte chain uses this body; suppress its duplicate
    # in the sibling set-fields.c object.
    ("src/set-fields.c", "--exclude-proc=mbszero"),
    # c32isalpha.c instantiates its exported body from c32is-impl.h.
    ("lib/c32isalpha.c", "--include-header-inline-body=c32isalpha"),
    ("lib/c32isalpha.c", "--exclude-proc=mbszero"),
    # The remaining c32is units instantiate the same header implementation.
    ("lib/c32isalnum.c", "--include-header-inline-body=c32isalnum"),
    ("lib/c32isalnum.c", "--exclude-proc=mbszero"),
    ("lib/c32isblank.c", "--include-header-inline-body=c32isblank"),
    ("lib/c32isblank.c", "--exclude-proc=mbszero"),
    ("lib/c32iscntrl.c", "--include-header-inline-body=c32iscntrl"),
    ("lib/c32iscntrl.c", "--exclude-proc=mbszero"),
    ("lib/c32isdigit.c", "--include-header-inline-body=c32isdigit"),
    ("lib/c32isdigit.c", "--exclude-proc=mbszero"),
    ("lib/c32isgraph.c", "--include-header-inline-body=c32isgraph"),
    ("lib/c32isgraph.c", "--exclude-proc=mbszero"),
    ("lib/c32islower.c", "--include-header-inline-body=c32islower"),
    ("lib/c32islower.c", "--exclude-proc=mbszero"),
    ("lib/c32isprint.c", "--include-header-inline-body=c32isprint"),
    ("lib/c32isprint.c", "--exclude-proc=mbszero"),
    ("lib/c32ispunct.c", "--include-header-inline-body=c32ispunct"),
    ("lib/c32ispunct.c", "--exclude-proc=mbszero"),
    ("lib/c32isspace.c", "--include-header-inline-body=c32isspace"),
    ("lib/c32isspace.c", "--exclude-proc=mbszero"),
    ("lib/c32isupper.c", "--include-header-inline-body=c32isupper"),
    ("lib/c32isupper.c", "--exclude-proc=mbszero"),
    ("lib/c32isxdigit.c", "--include-header-inline-body=c32isxdigit"),
    ("lib/c32isxdigit.c", "--exclude-proc=mbszero"),
    ("lib/c32tolower.c", "--include-header-inline-body=c32tolower"),
    ("lib/c32tolower.c", "--exclude-proc=mbszero"),
    ("lib/c32toupper.c", "--include-header-inline-body=c32toupper"),
    ("lib/c32toupper.c", "--exclude-proc=mbszero"),
    # The nested gnulib Unicode units instantiate these bodies from headers.
    ("lib/unictype/ctype_alnum.c", "--include-header-inline-body=bitmap_lookup"),
    ("lib/unictype/ctype_alpha.c", "--include-header-inline-body=bitmap_lookup"),
    ("lib/unictype/ctype_blank.c", "--include-header-inline-body=bitmap_lookup"),
    ("lib/unictype/ctype_cntrl.c", "--include-header-inline-body=bitmap_lookup"),
    ("lib/unictype/ctype_digit.c", "--include-header-inline-body=bitmap_lookup"),
    ("lib/unictype/ctype_graph.c", "--include-header-inline-body=bitmap_lookup"),
    ("lib/unictype/ctype_lower.c", "--include-header-inline-body=bitmap_lookup"),
    ("lib/unictype/ctype_print.c", "--include-header-inline-body=bitmap_lookup"),
    ("lib/unictype/ctype_punct.c", "--include-header-inline-body=bitmap_lookup"),
    ("lib/unictype/ctype_space.c", "--include-header-inline-body=bitmap_lookup"),
    ("lib/unictype/ctype_upper.c", "--include-header-inline-body=bitmap_lookup"),
    ("lib/unictype/ctype_xdigit.c", "--include-header-inline-body=bitmap_lookup"),
    ("lib/uniwidth/width.c", "--include-header-inline-body=bitmap_lookup"),
    ("lib/unicase/tolower.c", "--include-header-body=uc_tolower"),
    ("lib/unicase/toupper.c", "--include-header-body=uc_toupper"),
    ("lib/unistr/u32-cpy.c", "--include-header-body=u32_cpy"),
    ("lib/unistr/u32-pcpy.c", "--include-header-body=u32_pcpy"),
    ("lib/unistr/u32-strcat.c", "--include-header-body=u32_strcat"),
    ("lib/unistr/u32-strlen.c", "--include-header-body=u32_strlen"),
    # These external-inline definitions are part of the reference base32.o.
    ("lib/base32.c", "--include-header-inline-body=isubase32"),
    ("lib/base32.c", "--include-header-inline-body=isbase32"),
    ("lib/base32.c", "--include-header-inline-body=base32_decode_ctx_init"),
    # base64.c's C object owns these inline lookup and decode-context helpers.
    ("lib/base64.c", "--include-header-inline-body=isubase64"),
    ("lib/base64.c", "--include-header-inline-body=isbase64"),
    ("lib/base64.c", "--include-header-inline-body=base64_decode_ctx_init"),
    # c-ctype.c exports its locale-independent routines from c-ctype.h.
    ("lib/c-ctype.c", "--include-header-inline-body=c_isalnum"),
    ("lib/c-ctype.c", "--include-header-inline-body=c_isalpha"),
    ("lib/c-ctype.c", "--include-header-inline-body=c_isascii"),
    ("lib/c-ctype.c", "--include-header-inline-body=c_isblank"),
    ("lib/c-ctype.c", "--include-header-inline-body=c_iscntrl"),
    ("lib/c-ctype.c", "--include-header-inline-body=c_isdigit"),
    ("lib/c-ctype.c", "--include-header-inline-body=c_isgraph"),
    ("lib/c-ctype.c", "--include-header-inline-body=c_islower"),
    ("lib/c-ctype.c", "--include-header-inline-body=c_isprint"),
    ("lib/c-ctype.c", "--include-header-inline-body=c_ispunct"),
    ("lib/c-ctype.c", "--include-header-inline-body=c_isspace"),
    ("lib/c-ctype.c", "--include-header-inline-body=c_isupper"),
    ("lib/c-ctype.c", "--include-header-inline-body=c_isxdigit"),
    ("lib/c-ctype.c", "--include-header-inline-body=c_tolower"),
    ("lib/c-ctype.c", "--include-header-inline-body=c_toupper"),
    # The rotate wrapper objects export these stdbit.h inline implementations.
    ("lib/stdc_rotate_left.c", "--include-header-inline-body=stdc_rotate_left_uc"),
    ("lib/stdc_rotate_left.c", "--include-header-inline-body=stdc_rotate_left_us"),
    ("lib/stdc_rotate_left.c", "--include-header-inline-body=stdc_rotate_left_ui"),
    ("lib/stdc_rotate_left.c", "--include-header-inline-body=stdc_rotate_left_ul"),
    ("lib/stdc_rotate_left.c", "--include-header-inline-body=stdc_rotate_left_ull"),
    ("lib/stdc_rotate_right.c", "--include-header-inline-body=stdc_rotate_right_uc"),
    ("lib/stdc_rotate_right.c", "--include-header-inline-body=stdc_rotate_right_us"),
    ("lib/stdc_rotate_right.c", "--include-header-inline-body=stdc_rotate_right_ui"),
    ("lib/stdc_rotate_right.c", "--include-header-inline-body=stdc_rotate_right_ul"),
    ("lib/stdc_rotate_right.c", "--include-header-inline-body=stdc_rotate_right_ull"),
    # OpenSSL-configured SHA objects export these gl_openssl.h inline wrappers.
    ("lib/sha256.c", "--include-header-inline-body=sha224_init_ctx"),
    ("lib/sha256.c", "--include-header-inline-body=sha224_finish_ctx"),
    ("lib/sha256.c", "--include-header-inline-body=sha224_buffer"),
    ("lib/sha256.c", "--include-header-inline-body=sha224_read_ctx"),
    ("lib/sha256.c", "--include-header-inline-body=sha256_init_ctx"),
    ("lib/sha256.c", "--include-header-inline-body=sha256_process_bytes"),
    ("lib/sha256.c", "--include-header-inline-body=sha256_process_block"),
    ("lib/sha256.c", "--include-header-inline-body=sha256_finish_ctx"),
    ("lib/sha256.c", "--include-header-inline-body=sha256_buffer"),
    ("lib/sha256.c", "--include-header-inline-body=sha256_read_ctx"),
    ("lib/sha512.c", "--include-header-inline-body=sha384_init_ctx"),
    ("lib/sha512.c", "--include-header-inline-body=sha384_finish_ctx"),
    ("lib/sha512.c", "--include-header-inline-body=sha384_buffer"),
    ("lib/sha512.c", "--include-header-inline-body=sha384_read_ctx"),
    ("lib/sha512.c", "--include-header-inline-body=sha512_init_ctx"),
    ("lib/sha512.c", "--include-header-inline-body=sha512_process_bytes"),
    ("lib/sha512.c", "--include-header-inline-body=sha512_process_block"),
    ("lib/sha512.c", "--include-header-inline-body=sha512_finish_ctx"),
    ("lib/sha512.c", "--include-header-inline-body=sha512_buffer"),
    ("lib/sha512.c", "--include-header-inline-body=sha512_read_ctx"),
    # These two objects export the OpenSSL-backed MD5 and SHA-1 bodies from
    # gl_openssl.h in the C reference build.
    ("lib/md5.c", "--include-header-inline-body=md5_init_ctx"),
    ("lib/md5.c", "--include-header-inline-body=md5_process_bytes"),
    ("lib/md5.c", "--include-header-inline-body=md5_process_block"),
    ("lib/md5.c", "--include-header-inline-body=md5_finish_ctx"),
    ("lib/md5.c", "--include-header-inline-body=md5_buffer"),
    ("lib/md5.c", "--include-header-inline-body=md5_read_ctx"),
    ("lib/sha1.c", "--include-header-inline-body=sha1_init_ctx"),
    ("lib/sha1.c", "--include-header-inline-body=sha1_process_bytes"),
    ("lib/sha1.c", "--include-header-inline-body=sha1_process_block"),
    ("lib/sha1.c", "--include-header-inline-body=sha1_finish_ctx"),
    ("lib/sha1.c", "--include-header-inline-body=sha1_buffer"),
    ("lib/sha1.c", "--include-header-inline-body=sha1_read_ctx"),
    # These objects export their public helper APIs as external inline bodies.
    ("lib/xtime.c", "--include-header-inline-body=xtime_make"),
    ("lib/xtime.c", "--include-header-inline-body=xtime_nonnegative_sec"),
    ("lib/xtime.c", "--include-header-inline-body=xtime_sec"),
    ("lib/xtime.c", "--include-header-inline-body=xtime_nonnegative_nsec"),
    ("lib/xtime.c", "--include-header-inline-body=xtime_nsec"),
    ("lib/timespec.c", "--include-header-inline-body=make_timespec"),
    ("lib/timespec.c", "--include-header-inline-body=timespec_cmp"),
    ("lib/timespec.c", "--include-header-inline-body=timespec_sign"),
    ("lib/timespec.c", "--include-header-inline-body=timespectod"),
    ("lib/xsize.c", "--include-header-inline-body=xsum"),
    ("lib/xsize.c", "--include-header-inline-body=xsum3"),
    ("lib/xsize.c", "--include-header-inline-body=xsum4"),
    ("lib/xsize.c", "--include-header-inline-body=xmax"),
    ("lib/ialloc.c", "--include-header-inline-body=_gl_alloc_nomem"),
    ("lib/ialloc.c", "--include-header-inline-body=imalloc"),
    ("lib/ialloc.c", "--include-header-inline-body=irealloc"),
    ("lib/ialloc.c", "--include-header-inline-body=icalloc"),
    ("lib/ialloc.c", "--include-header-inline-body=ireallocarray"),
    ("lib/stdc_memreverse8u.c", "--include-header-inline-body=stdc_memreverse8u8"),
    ("lib/stdc_memreverse8u.c", "--include-header-inline-body=stdc_memreverse8u16"),
    ("lib/stdc_memreverse8u.c", "--include-header-inline-body=stdc_memreverse8u32"),
    ("lib/stdc_memreverse8u.c", "--include-header-inline-body=stdc_memreverse8u64"),
    # stat-time.c provides external-inline bodies from stat-time.h in the C
    # reference object; select the same API bodies for the FreeBASIC object.
    ("lib/stat-time.c", "--include-header-inline-body=get_stat_atime_ns"),
    ("lib/stat-time.c", "--include-header-inline-body=get_stat_ctime_ns"),
    ("lib/stat-time.c", "--include-header-inline-body=get_stat_mtime_ns"),
    ("lib/stat-time.c", "--include-header-inline-body=get_stat_birthtime_ns"),
    ("lib/stat-time.c", "--include-header-inline-body=get_stat_atime"),
    ("lib/stat-time.c", "--include-header-inline-body=get_stat_ctime"),
    ("lib/stat-time.c", "--include-header-inline-body=get_stat_mtime"),
    ("lib/stat-time.c", "--include-header-inline-body=get_stat_birthtime"),
    ("lib/stat-time.c", "--include-header-inline-body=stat_time_normalize"),
    # targetdir.c exports this external-inline predicate from targetdir.h.
    ("lib/targetdir.c", "--include-header-inline-body=target_dirfd_valid"),
    # savewd.c exports the initialization and error accessors from savewd.h.
    ("lib/savewd.c", "--include-header-inline-body=savewd_init"),
    ("lib/savewd.c", "--include-header-inline-body=savewd_errno"),
    # skipchars.c exports both external-inline scanning helpers from its header.
    ("lib/skipchars.c", "--include-header-inline-body=skip_str_matching"),
    ("lib/skipchars.c", "--include-header-inline-body=skip_buf_matching"),
    # These string objects export public external-inline bodies from string.h.
    ("lib/memeq.c", "--include-header-inline-body=memeq"),
    ("lib/streq.c", "--include-header-inline-body=streq"),
    ("lib/strnul.c", "--include-header-inline-body=_gl_strnul"),
    # xmalloc.c exports this checked array reallocator from xalloc.h.
    ("lib/xmalloc.c", "--include-header-inline-body=xnrealloc"),
    # These C objects export external-inline file and 64-bit helpers.
    ("lib/same-inode.c", "--include-header-inline-body=psame_inode"),
    ("lib/u64.c", "--include-header-inline-body=u64rol"),
    # realloc.c exports its glibc-compatible zero-size policy from stdlib.h.
    ("lib/realloc.c", "--include-header-inline-body=rpl_realloc"),
    # These objects export the symlink probes from their public headers.
    ("lib/issymlink.c", "--include-header-inline-body=issymlink"),
    ("lib/issymlinkat.c", "--include-header-inline-body=issymlinkat"),
    # utimens.c exports the no-follow convenience wrapper from utimens.h.
    ("lib/utimens.c", "--include-header-inline-body=lutimensat"),
    # sig-handler.c exports its function-pointer accessor from sig-handler.h.
    ("lib/sig-handler.c", "--include-header-inline-body=get_handler"),
    # priv-set.c exports both link-directory convenience bodies from priv-set.h.
    ("lib/priv-set.c", "--include-header-inline-body=priv_set_remove_linkdir"),
    ("lib/priv-set.c", "--include-header-inline-body=priv_set_restore_linkdir"),
    # xbinary-io.c exports both checked mode helpers from xbinary-io.h.
    ("lib/xbinary-io.c", "--include-header-inline-body=xset_binary_mode"),
    ("lib/xbinary-io.c", "--include-header-inline-body=xset_binary_mode_error"),
    # xgethostname.c instantiates its implementation from xgetaname-impl.h.
    ("lib/xgethostname.c", "--include-header-body=xgethostname"),
    # mbsrtowcs.c instantiates its replacement from mbsrtowcs-impl.h.
    ("lib/mbsrtowcs.c", "--include-header-body=rpl_mbsrtowcs"),
    ("lib/mbsrtowcs.c", "--exclude-proc=mbszero"),
    # alignalloc.c exports its allocator pair from alignalloc.h.
    ("lib/alignalloc.c", "--include-header-inline-body=alignalloc"),
    ("lib/alignalloc.c", "--include-header-inline-body=alignfree"),
    # mbbuf.c provides the external-inline buffering API from mbbuf.h.
    # Keep shared multibyte helpers in libcoreutils.a instead of duplicating
    # them in the translated buffer object.
    ("lib/mbbuf.c", "--exclude-proc=mbszero"),
    ("lib/mbbuf.c", "--exclude-proc=mcel_ch"),
    ("lib/mbbuf.c", "--exclude-proc=mcel_err"),
    ("lib/mbbuf.c", "--exclude-proc=mcel_isbasic"),
    ("lib/mbbuf.c", "--exclude-proc=mcel_scan"),
    ("lib/mbbuf.c", "--exclude-proc=mcel_scant"),
    ("lib/mbbuf.c", "--exclude-proc=mcel_scanz"),
    # These functions are public C APIs supplied by libcoreutils.a; keep the
    # buffer callers while the inline helper bodies remain excluded.
    ("lib/mbbuf.c", "--keep-unresolved"),
    ("lib/mbbuf.c", "--include-header-inline-body=mbbuf_avail"),
    ("lib/mbbuf.c", "--include-header-inline-body=mbbuf_init"),
    ("lib/mbbuf.c", "--include-header-inline-body=mbbuf_topup"),
    ("lib/mbbuf.c", "--include-header-inline-body=mbbuf_fill"),
    ("lib/mbbuf.c", "--include-header-inline-body=mbbuf_advance"),
    ("lib/mbbuf.c", "--include-header-inline-body=mbbuf_get_char"),
    ("lib/mbbuf.c", "--include-header-inline-body=mbbuf_char_offset"),
    # mcel.c owns the shared multibyte comparison API and leaves mbszero to
    # its dedicated source unit.
    ("lib/mcel.c", "--exclude-proc=mbszero"),
    ("lib/mcel.c", "--include-header-inline-body=mcel_cmp"),
    ("lib/mcel.c", "--include-header-inline-body=mcel_eq"),
    ("lib/mcel.c", "--include-header-inline-body=mcel_tocmp"),
    # This public convenience predicate is an external inline in exclude.h.
    ("lib/exclude.c", "--include-header-inline-body=excluded_file_name"),
    # Translate glibc FILE field access against the checked ABI profile.
    ("lib/freadahead.c", "--fb-source-directory=" + str(PORT / "profiles")),
    ("lib/freadahead.c", "--fb-source-pattern=coreutils_glibc_file.bi"),
    ("lib/freadahead.c", "--type-map=FILE=CoreutilsGlibcFile"),
    ("lib/freadahead.c", "--type-map=_IO_FILE=CoreutilsGlibcFile"),
    ("lib/fseterr.c", "--fb-source-directory=" + str(PORT / "profiles")),
    ("lib/fseterr.c", "--fb-source-pattern=coreutils_glibc_file.bi"),
    ("lib/fseterr.c", "--type-map=FILE=CoreutilsGlibcFile"),
    ("lib/fseterr.c", "--type-map=_IO_FILE=CoreutilsGlibcFile"),
    # Keep exclude.c in the same object boundary as the shared mcel.c and
    # mbszero.c providers; translated callers retain those public C references.
    ("lib/exclude.c", "--exclude-proc=mbszero"),
    ("lib/exclude.c", "--exclude-proc=mcel_ch"),
    ("lib/exclude.c", "--exclude-proc=mcel_err"),
    ("lib/exclude.c", "--exclude-proc=mcel_isbasic"),
    ("lib/exclude.c", "--exclude-proc=mcel_scan"),
    ("lib/exclude.c", "--exclude-proc=mcel_scant"),
    ("lib/exclude.c", "--exclude-proc=mcel_scanz"),
    ("lib/exclude.c", "--keep-unresolved"),
    # mbtowc.c's implementation body lives in its included helper header.
    ("lib/mbtowc.c", "--include-header-inline-body=rpl_mbtowc"),
)
# The C encoder uses 30 KiB blocks. The 20,160-byte FreeBASIC port block stays
# divisible by the 12- and 40-byte encoder groups while reducing the peak
# allocation enough for basenc's unchanged bounded-memory test with FBC startup.
SOURCE_FB_PROFILE_OVERRIDES = (
    {
        "source": "src/basenc.c",
        "compiler_define": "-DBASE_TYPE=42",
        "macro": "ENC_BLOCKSIZE",
        "value": 20160,
        "expected_expression_occurrences": 6,
    },
    {
        "source": "lib/printf-frexpl.c",
        "compiler_define": "-D__FILC__",
        "profile": "x87_long_double_rounding",
    },
    {
        "source": "lib/frexpl.c",
        "compiler_define": "-D__FILC__",
        "profile": "frexpl_x87_long_double_rounding",
    },
)
ENC_BLOCKSIZE_C2FB_EXPRESSION = re.compile(
    r"Cast\(c2fb_c_int, \(Cast\(c2fb_c_int, \(Cast\(c2fb_c_int, 1024ULL\) "
    r"\* Cast\(c2fb_c_int, 3ULL\)\)\) \* Cast\(c2fb_c_int, 10ULL\)\)\)"
)
ENC_BLOCKSIZE_PROFILE_MARKER = (
    "' Coreutils port profile: 20,160-byte encode blocks preserve the C encoder "
    "groups and fit the FBC bounded-memory limit."
)
PRINTF_FREXPL_PROFILE_MARKER = (
    "' Coreutils port profile: preserve the x87 extended-precision scope."
)
FREXPL_PROFILE_MARKER = (
    "' Coreutils port profile: restore x87 extended precision inside frexpl."
)
PORT_SUPPORT_FILES = (
    PORT / "coreutils_glibc_abi.bi",
    PORT / "coreutils_mcel_support.bi",
    PORT / "coreutils_dtimespec_support.bi",
    PORT / "coreutils_oputs_support.bi",
    PORT / "coreutils_x87_support.bi",
    PORT / "profiles/coreutils_glibc_file.bi",
    PORT / "coreutils_mcel_prototypes.bi",
    PORT / "coreutils_cksum_stream_support.bi",
    PORT / "coreutils_cksum_avx2_scalar.bi",
    PORT / "coreutils_cksum_avx512_scalar.bi",
    PORT / "coreutils_cksum_pclmul_scalar.bi",
    PORT / "coreutils_cksum_vmull_scalar.bi",
    PORT / "coreutils_crc_pclmul_scalar.bi",
    PORT / "coreutils_wc_neon_scalar.bi",
    PORT / "arm_stubs/arm_neon.h",
    PORT / "replacements/coreutils-dtimespec.rpl",
    PORT / "replacements/coreutils-mcel.rpl",
    PORT / "replacements/coreutils-oputs.rpl",
    PORT / "replacements/coreutils-wc-avx-fallback.rpl",
)


def run_logged(command, name, *, cwd=REFERENCE, environment=None):
    log = PORT / "logs" / name
    log.parent.mkdir(parents=True, exist_ok=True)
    print(f"Running {command[0]}; log: {log}", flush=True)
    with log.open("w", encoding="utf-8") as output:
        result = subprocess.run(command, cwd=cwd, env=environment,
                                stdout=output, stderr=subprocess.STDOUT,
                                check=False)
    if result.returncode:
        print("\n".join(log.read_text(errors="replace").splitlines()[-30:]))
        raise RuntimeError(f"command failed with status {result.returncode}: {log}")


def require_coreutils_source():
    version_file = SOURCE / ".tarball-version"
    if (not (SOURCE / "configure").is_file()
            or not (SOURCE / "src").is_dir()
            or not (SOURCE / "lib").is_dir()
            or not version_file.is_file()):
        raise RuntimeError(
            "Coreutils source tree is unavailable; set COREUTILS_SOURCE to a "
            "GNU Coreutils 9.12 checkout"
        )
    version = version_file.read_text(encoding="utf-8").strip()
    if version != "9.12":
        raise RuntimeError(
            f"expected GNU Coreutils 9.12 at {SOURCE}, found {version}"
        )


def source_relative_path(path):
    resolved = Path(path).resolve()
    for root in (REFERENCE, SOURCE):
        try:
            return resolved.relative_to(root).as_posix()
        except ValueError:
            continue
    raise RuntimeError(
        f"source file is outside COREUTILS_SOURCE and the reference build: {resolved}"
    )


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def prepare_toolchain_paths():
    targets = (
        (TOOLCHAIN_DIRECTORY / "include/freebasic", FBC_SOURCE / "inc"),
        (TOOLCHAIN_DIRECTORY / "lib/freebasic", FBC_SOURCE / "lib/freebasic"),
    )
    for link_path, target_path in targets:
        target_path = target_path.resolve()
        link_path.parent.mkdir(parents=True, exist_ok=True)
        if link_path.exists() or link_path.is_symlink():
            if link_path.resolve() != target_path:
                raise RuntimeError(f"compiler support path has a different target: {link_path}")
        else:
            link_path.symlink_to(target_path, target_is_directory=True)


def build_compiler(jobs):
    if not FBC_SOURCE or not (FBC_SOURCE / "GNUmakefile").is_file():
        raise RuntimeError(f"FreeBASIC source tree is unavailable: {FBC_SOURCE}")
    prepare_toolchain_paths()
    run_logged(["make", "-s", f"-j{jobs}", "compiler",
                f"FBC_EXE={TOOLCHAIN_FBC}"],
               "freebasic-build.log", cwd=FBC_SOURCE)


def captured_production_database(captures):
    entries = {}
    for path in sorted(captures.glob("compile-*.json")):
        entry = json.loads(path.read_text(encoding="utf-8"))
        source = (Path(entry["directory"]) / entry["file"]).resolve()
        # Test helpers remain C. Only production sources enter the converter.
        production_roots = (SOURCE / "src", SOURCE / "lib",
                            REFERENCE / "src", REFERENCE / "lib")
        if not any(root in source.parents for root in production_roots):
            continue
        if source.name in {"getlimits.c", "make-prime-list.c"}:
            continue
        key = (str(source), tuple(entry["arguments"]))
        entries[key] = entry
    database = sorted(entries.values(), key=lambda item: (item["file"],
                                                          item.get("output", "")))
    if not database:
        raise RuntimeError(f"no production compiler invocations found in {captures}")
    return database


def index_captured_commands():
    require_coreutils_source()
    captures = PORT / "build/compiler-invocations"
    database = captured_production_database(captures)
    write_json(PORT / "build/compile_commands.json", database)
    print(f"Indexed {len(database)} production translation units from {captures}.")


def reference_build(jobs):
    require_coreutils_source()
    REFERENCE.mkdir(parents=True, exist_ok=True)
    if not (REFERENCE / "Makefile").is_file():
        run_logged([str(SOURCE / "configure"), "--disable-gcc-warnings",
                    "--enable-install-program=arch,coreutils,hostname,kill,uptime"],
                   "configure.log")
    environment = os.environ.copy()
    captures = PORT / "build/compiler-invocations"
    environment["COREUTILS_CAPTURE_DIRECTORY"] = str(captures)
    environment["COREUTILS_REAL_CC"] = "/usr/bin/gcc"
    run_logged(["make", f"-j{jobs}", "V=1", "all",
                "src/arch", "src/coreutils", "src/hostname", "src/kill", "src/uptime",
                f"CC={sys.executable} {PORT / 'capture_cc.py'}"],
               "reference-build.log", environment=environment)
    index_captured_commands()


def selected_database(patterns):
    database = json.loads((PORT / "build/compile_commands.json").read_text())
    selected = []
    for entry in database:
        source = (Path(entry["directory"]) / entry["file"]).resolve()
        relative = source_relative_path(source)
        if not patterns or any(fnmatch.fnmatchcase(relative, pattern)
                               for pattern in patterns):
            selected.append(entry)
    if not selected:
        raise ValueError("source patterns selected no production translation units")
    path = PORT / "build/selected_compile_commands.json"
    write_json(path, selected)
    return path


def normalize_generated_output(generated, patterns):
    source_prefixes = (
        (str(SOURCE) + os.sep, "$(COREUTILS_SOURCE)/"),
        (str(REFERENCE) + os.sep, "$(COREUTILS_REFERENCE_BUILD)/"),
    )
    for candidate in generated.glob("*_candidates.bas"):
        text = candidate.read_text(encoding="utf-8")
        for prefix, replacement in source_prefixes:
            text = text.replace(prefix, replacement)
        candidate.write_text(text, encoding="utf-8")
    for type_context in generated.glob("*_candidates_types.bi"):
        text = type_context.read_text(encoding="utf-8")
        for prefix, replacement in source_prefixes:
            text = text.replace(prefix, replacement)
        type_context.write_text(text, encoding="utf-8")

    source_map = generated / "compile-command-map.csv"
    if not source_map.is_file():
        return
    with source_map.open(newline="", encoding="utf-8") as input_file:
        rows = list(csv.DictReader(input_file))
    new_rows = []
    for row in rows:
        source_path = Path(row["SourceFile"]).resolve()
        relative_source = source_relative_path(source_path)
        new_rows.append({
            "CandidateFile": row["CandidateFile"],
            "SourceFile": relative_source,
            "TypeContextFile": row["TypeContextFile"],
            "SourceUnitContext": row["SourceUnitContext"],
        })

    existing_rows = []
    portable_map = generated / "candidate-map.csv"
    if patterns and portable_map.is_file():
        with portable_map.open(newline="", encoding="utf-8") as input_file:
            existing_rows = list(csv.DictReader(input_file))
        existing_rows = [
            row for row in existing_rows
            if not any(fnmatch.fnmatchcase(row["SourceFile"], pattern)
                       for pattern in patterns)
        ]
    all_rows = existing_rows + new_rows
    all_rows.sort(key=lambda row: row["CandidateFile"])

    with portable_map.open("w", newline="", encoding="utf-8") as output_file:
        writer = csv.writer(output_file)
        writer.writerow(("CandidateFile", "SourceFile", "TypeContextFile",
                         "SourceUnitContext"))
        for row in all_rows:
            writer.writerow((row["CandidateFile"], row["SourceFile"],
                             row["TypeContextFile"], row["SourceUnitContext"]))
    source_map.unlink()
    expected_files = {
        name for row in all_rows
        for name in (row["CandidateFile"], row["TypeContextFile"])
        if name
    }
    for candidate in generated.glob("*_candidates.bas"):
        if candidate.name not in expected_files:
            candidate.unlink()
    for type_context in generated.glob("*_candidates_types.bi"):
        if type_context.name not in expected_files:
            type_context.unlink()


def save_toolchain_snapshot(patterns, contexts):
    converter = C2FB_CONVERTER
    source_files = sorted((TOOLS / "c2fb.bas").parent.glob("c2fb_*.bi"))
    source_files.append(TOOLS / "c2fb.bas")
    source_files.extend((TOOLS / "c2fb_compile_commands.py",
                         TOOLS / "c2fb_source_unit.py"))
    snapshot = {
        "coreutils_version": (SOURCE / ".tarball-version").read_text().strip(),
        "converter": str(converter.resolve()),
        "converter_sha256": hashlib.sha256(converter.read_bytes()).hexdigest(),
        "converter_sources": {
            str(path.relative_to(TOOLS)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(set(source_files))
        },
        "port_support_files": {
            str(path.relative_to(PORT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in PORT_SUPPORT_FILES
        },
        "port_driver_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "freebasic_compiler": str(FBC.resolve()),
        "freebasic_compiler_sha256": hashlib.sha256(FBC.read_bytes()).hexdigest(),
        "freebasic_version": subprocess.run(
            [str(FBC), "-version"], capture_output=True, text=True,
            check=True,
        ).stdout.strip(),
        "compile_commands_sha256": hashlib.sha256(
            (PORT / "build/selected_compile_commands.json").read_bytes()
        ).hexdigest(),
        "source_patterns": list(patterns),
        "source_unit_context": contexts,
        "body_options": BODY_OPTIONS,
        "body_compiler_options": BODY_COMPILER_OPTIONS,
        "source_body_compiler_options": SOURCE_BODY_COMPILER_OPTIONS,
        "source_header_compiler_options": SOURCE_HEADER_COMPILER_OPTIONS,
        "source_header_options": SOURCE_HEADER_OPTIONS,
        "source_c2fb_options": SOURCE_C2FB_OPTIONS,
        "source_fb_profile_overrides": SOURCE_FB_PROFILE_OVERRIDES,
        "source_fb_post_type_includes": SOURCE_FB_POST_TYPE_INCLUDES,
        "source_fb_post_declaration_includes": SOURCE_FB_POST_DECLARATION_INCLUDES,
        "header_options": HEADER_OPTIONS if contexts else [],
    }
    write_json(PORT / "build/toolchain-snapshot.json", snapshot)


def apply_source_fb_profile_overrides(database, generated, contexts):
    """Apply validated FreeBASIC-only adaptations to selected candidates."""
    if not SOURCE_FB_PROFILE_OVERRIDES:
        return

    driver_name = "coreutils_c2fb_compile_commands_profiles"
    spec = importlib.util.spec_from_file_location(
        driver_name, TOOLS / "c2fb_compile_commands.py")
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load the C2FB compile-command driver")
    driver = importlib.util.module_from_spec(spec)
    sys.modules[driver_name] = driver
    spec.loader.exec_module(driver)

    entries = json.loads(database.read_text(encoding="utf-8"))
    source_seen = set()
    applied = set()
    for index, entry in enumerate(entries):
        model = driver.parse_command_entry(entry, index, database.parent)
        if model is None:
            continue
        source = source_relative_path(model.source_path)
        for override in SOURCE_FB_PROFILE_OVERRIDES:
            if source != override["source"]:
                continue
            source_seen.add(source)
            source_body_options = driver.source_body_compiler_options_for(
                model.source_path, SOURCE_BODY_COMPILER_OPTIONS)
            compiler_options = (*model.compiler_arguments, *source_body_options)
            if override["compiler_define"] not in compiler_options:
                continue

            source_c2fb_options = driver.source_options_for(
                model.source_path, SOURCE_C2FB_OPTIONS)
            source_header_options = driver.source_options_for(
                model.source_path, SOURCE_HEADER_OPTIONS)
            source_header_compiler_options = (
                driver.source_header_compiler_options_for(
                    model.source_path, SOURCE_HEADER_COMPILER_OPTIONS)
                if contexts else ()
            )
            signature_options = list(BODY_OPTIONS) + list(source_c2fb_options)
            if contexts:
                signature_options.extend((
                    "--source-unit-context",
                    *HEADER_OPTIONS,
                    *source_header_options,
                ))
            signature = driver.command_signature(
                model, signature_options,
                (*BODY_COMPILER_OPTIONS, *source_body_options),
                source_header_compiler_options)
            candidate = generated / driver.output_filename(model, signature)
            if not candidate.is_file():
                raise FileNotFoundError(
                    f"expected generated FreeBASIC candidate: {candidate}")

            text = candidate.read_text(encoding="utf-8")
            profile_key = (source, override["compiler_define"])
            if override.get("profile") == "x87_long_double_rounding":
                text = apply_printf_frexpl_x87_profile(candidate, text)
            elif override.get("profile") == "frexpl_x87_long_double_rounding":
                text = apply_frexpl_x87_profile(candidate, text)
            else:
                replacement = f"Cast(c2fb_c_int, {override['value']}ULL)"
                if ENC_BLOCKSIZE_PROFILE_MARKER in text:
                    if text.count(replacement) != override["expected_expression_occurrences"]:
                        raise RuntimeError(
                            f"{candidate}: unexpected already-profiled "
                            f"{override['macro']} values")
                    applied.add(profile_key)
                    continue

                text, count = ENC_BLOCKSIZE_C2FB_EXPRESSION.subn(replacement, text)
                if count != override["expected_expression_occurrences"]:
                    raise RuntimeError(
                        f"{candidate}: expected "
                        f"{override['expected_expression_occurrences']} "
                        f"{override['macro']} expansions, found {count}")
                include_position = text.find("\n#include once")
                if include_position < 0:
                    raise RuntimeError(f"{candidate}: generated include section not found")
                text = (text[:include_position] + "\n" +
                        ENC_BLOCKSIZE_PROFILE_MARKER + text[include_position:])
            candidate.write_text(text, encoding="utf-8")
            applied.add(profile_key)

    for override in SOURCE_FB_PROFILE_OVERRIDES:
        key = (override["source"], override["compiler_define"])
        if override["source"] in source_seen and key not in applied:
            raise RuntimeError(
                f"no compile context matched {override['compiler_define']} "
                f"for {override['source']}")


def apply_source_fb_post_type_includes(database, generated, contexts):
    """Add shared ABI declarations after a candidate's generated type include."""
    if not SOURCE_FB_POST_TYPE_INCLUDES:
        return

    driver_name = "coreutils_c2fb_post_type_includes"
    spec = importlib.util.spec_from_file_location(
        driver_name, TOOLS / "c2fb_compile_commands.py")
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load the C2FB compile-command driver")
    driver = importlib.util.module_from_spec(spec)
    sys.modules[driver_name] = driver
    spec.loader.exec_module(driver)

    includes_by_source = dict(SOURCE_FB_POST_TYPE_INCLUDES)
    source_seen = set()
    selected_sources = set()
    entries = json.loads(database.read_text(encoding="utf-8"))
    for index, entry in enumerate(entries):
        model = driver.parse_command_entry(entry, index, database.parent)
        if model is None:
            continue
        source = source_relative_path(model.source_path)
        selected_sources.add(source)
        include_path = includes_by_source.get(source)
        if include_path is None:
            continue
        source_seen.add(source)
        source_body_options = driver.source_body_compiler_options_for(
            model.source_path, SOURCE_BODY_COMPILER_OPTIONS)
        source_c2fb_options = driver.source_options_for(
            model.source_path, SOURCE_C2FB_OPTIONS)
        source_header_options = driver.source_options_for(
            model.source_path, SOURCE_HEADER_OPTIONS)
        source_header_compiler_options = (
            driver.source_header_compiler_options_for(
                model.source_path, SOURCE_HEADER_COMPILER_OPTIONS)
            if contexts else ()
        )
        signature_options = list(BODY_OPTIONS) + list(source_c2fb_options)
        if contexts:
            signature_options.extend((
                "--source-unit-context",
                *HEADER_OPTIONS,
                *source_header_options,
            ))
        signature = driver.command_signature(
            model, signature_options,
            (*BODY_COMPILER_OPTIONS, *source_body_options),
            source_header_compiler_options)
        candidate = generated / driver.output_filename(model, signature)
        if not candidate.is_file():
            raise FileNotFoundError(
                f"expected generated FreeBASIC candidate: {candidate}")

        text = candidate.read_text(encoding="utf-8")
        include_line = f'#include once "{include_path}"'
        if text.count(include_line) > 1:
            raise RuntimeError(
                f"{candidate}: duplicated source-profile include {include_path}")
        if include_line not in text:
            abi_start = text.find("#ifndef __C2FB_BODY_C_ABI_TYPES__")
            first_declaration = text.find("\nDeclare ", abi_start)
            if abi_start < 0 or first_declaration < 0:
                raise RuntimeError(
                    f"{candidate}: C ABI type declarations are missing")
            abi_end = text.rfind("#endif", abi_start, first_declaration)
            line_end = text.find("\n", abi_end)
            if abi_end < 0 or line_end < 0:
                raise RuntimeError(
                    f"{candidate}: C ABI type guard is malformed")
            text = (text[:line_end + 1] + include_line + "\n" +
                    text[line_end + 1:])
            candidate.write_text(text, encoding="utf-8")

    missing_sources = (set(includes_by_source) & selected_sources) - source_seen
    if missing_sources:
        raise RuntimeError(
            "no compile contexts matched source-profile includes for "
            + ", ".join(sorted(missing_sources)))


def apply_source_fb_post_declaration_includes(database, generated, contexts):
    """Add FreeBASIC implementations after generated ABI declarations."""
    if not SOURCE_FB_POST_DECLARATION_INCLUDES:
        return

    driver_name = "coreutils_c2fb_post_declaration_includes"
    spec = importlib.util.spec_from_file_location(
        driver_name, TOOLS / "c2fb_compile_commands.py")
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load the C2FB compile-command driver")
    driver = importlib.util.module_from_spec(spec)
    sys.modules[driver_name] = driver
    spec.loader.exec_module(driver)

    includes_by_source = dict(SOURCE_FB_POST_DECLARATION_INCLUDES)
    source_seen = set()
    selected_sources = set()
    entries = json.loads(database.read_text(encoding="utf-8"))
    for index, entry in enumerate(entries):
        model = driver.parse_command_entry(entry, index, database.parent)
        if model is None:
            continue
        source = source_relative_path(model.source_path)
        selected_sources.add(source)
        include_path = includes_by_source.get(source)
        if include_path is None:
            continue
        source_seen.add(source)
        source_body_options = driver.source_body_compiler_options_for(
            model.source_path, SOURCE_BODY_COMPILER_OPTIONS)
        source_c2fb_options = driver.source_options_for(
            model.source_path, SOURCE_C2FB_OPTIONS)
        source_header_options = driver.source_options_for(
            model.source_path, SOURCE_HEADER_OPTIONS)
        source_header_compiler_options = (
            driver.source_header_compiler_options_for(
                model.source_path, SOURCE_HEADER_COMPILER_OPTIONS)
            if contexts else ()
        )
        signature_options = list(BODY_OPTIONS) + list(source_c2fb_options)
        if contexts:
            signature_options.extend((
                "--source-unit-context",
                *HEADER_OPTIONS,
                *source_header_options,
            ))
        signature = driver.command_signature(
            model, signature_options,
            (*BODY_COMPILER_OPTIONS, *source_body_options),
            source_header_compiler_options)
        candidate = generated / driver.output_filename(model, signature)
        if not candidate.is_file():
            raise FileNotFoundError(
                f"expected generated FreeBASIC candidate: {candidate}")

        text = candidate.read_text(encoding="utf-8")
        include_line = f'#include once "{include_path}"'
        if text.count(include_line) > 1:
            raise RuntimeError(
                f"{candidate}: duplicated source-profile include {include_path}")
        if include_line not in text:
            first_body = re.search(
                r"(?m)^(?:Private\s+)?(?:Function|Sub)\s+", text)
            if first_body is not None:
                insertion_point = first_body.start()
            else:
                footer = re.search(r"(?m)^/\' end of .+ \'/\s*$", text)
                if footer is None:
                    raise RuntimeError(
                        f"{candidate}: no implementation or footer follows its declarations")
                insertion_point = footer.start()
            text = (text[:insertion_point] + include_line + "\n" +
                    text[insertion_point:])
            candidate.write_text(text, encoding="utf-8")

    missing_sources = (set(includes_by_source) & selected_sources) - source_seen
    if missing_sources:
        raise RuntimeError(
            "no compile contexts matched source-profile implementations for "
            + ", ".join(sorted(missing_sources)))


def apply_printf_frexpl_x87_profile(candidate, text):
    """Restore the x87 precision scope removed by the portable C profile."""
    begin_call = (
        "c2fb_saved_control_word = C2FBCoreutilsBeginLongDoubleRounding()"
    )
    end_call = "C2FBCoreutilsEndLongDoubleRounding(c2fb_saved_control_word)"
    saved_declaration = "    Dim c2fb_saved_control_word As UShort"
    support_include = '#include once "fb_port/coreutils_x87_support.bi"'
    if PRINTF_FREXPL_PROFILE_MARKER in text:
        if (text.count(PRINTF_FREXPL_PROFILE_MARKER) != 1 or
                text.count(begin_call) != 1 or text.count(end_call) != 1 or
                text.count(saved_declaration) != 1 or
                text.count("' empty C statement") != 0):
            raise RuntimeError(f"{candidate}: malformed existing x87 profile")
        types_path = candidate.with_name(candidate.stem + "_types.bi")
        if support_include not in types_path.read_text(encoding="utf-8"):
            raise RuntimeError(f"{candidate}: x87 support include is missing")
        return text

    types_path = candidate.with_name(candidate.stem + "_types.bi")
    if support_include not in types_path.read_text(encoding="utf-8"):
        raise RuntimeError(f"{candidate}: x87 support include is missing")

    function_marker = "\nFunction printf_frexpl CDecl Alias"
    if text.count(function_marker) != 1:
        raise RuntimeError(f"{candidate}: translated printf_frexpl definition is missing")
    local_declaration = "    Dim local0 As c2fb_c_int"
    if text.count(local_declaration) != 1:
        raise RuntimeError(f"{candidate}: unexpected printf_frexpl local declarations")
    empty_statement = "    ' empty C statement"
    if text.count(empty_statement) != 2:
        raise RuntimeError(f"{candidate}: expected two stripped rounding statements")
    declaration_marker = "\nDeclare Function printf_frexpl CDecl Alias"
    if text.count(declaration_marker) != 1:
        raise RuntimeError(f"{candidate}: translated printf_frexpl declaration is missing")

    text = text.replace(
        local_declaration,
        saved_declaration + "\n" + local_declaration,
        1,
    )
    text = text.replace(empty_statement, "    " + begin_call, 1)
    text = text.replace(empty_statement, "    " + end_call, 1)
    text = text.replace(
        declaration_marker,
        "\n" + PRINTF_FREXPL_PROFILE_MARKER + declaration_marker,
        1,
    )
    return text


def apply_frexpl_x87_profile(candidate, text):
    """Restore frexpl's extended-precision scope after C2FB removes C asm."""
    begin_call = (
        "c2fb_saved_control_word = C2FBCoreutilsBeginLongDoubleRounding()"
    )
    end_call = "C2FBCoreutilsEndLongDoubleRounding(c2fb_saved_control_word)"
    saved_declaration = "    Dim c2fb_saved_control_word As UShort"
    support_include = '#include once "fb_port/coreutils_x87_support.bi"'
    types_path = candidate.with_name(candidate.stem + "_types.bi")
    if support_include not in types_path.read_text(encoding="utf-8"):
        raise RuntimeError(f"{candidate}: x87 support include is missing")

    if FREXPL_PROFILE_MARKER in text:
        if (text.count(FREXPL_PROFILE_MARKER) != 1 or
                text.count(begin_call) != 1 or text.count(end_call) != 1 or
                text.count(saved_declaration) != 1 or
                text.count("' empty C statement") != 0):
            raise RuntimeError(f"{candidate}: malformed existing frexpl x87 profile")
        return text

    function_marker = "\nFunction frexpl CDecl Alias"
    declaration_marker = "\nDeclare Function frexpl CDecl Alias"
    if text.count(function_marker) != 1 or text.count(declaration_marker) != 1:
        raise RuntimeError(f"{candidate}: translated frexpl definition is missing")

    empty_statement = "    ' empty C statement"
    if text.count(empty_statement) != 2:
        raise RuntimeError(f"{candidate}: expected two stripped rounding statements")

    function_start = text.index(function_marker) + 1
    function_end = text.index("\nEnd Function", function_start)
    function_lines = text[function_start:function_end].splitlines()
    declaration_positions = [
        index for index, line in enumerate(function_lines)
        if line.startswith("    Dim ")
    ]
    if not declaration_positions:
        raise RuntimeError(f"{candidate}: frexpl local declarations are missing")
    last_declaration = declaration_positions[-1]
    function_lines.insert(last_declaration + 1, saved_declaration)
    function_text = "\n".join(function_lines)
    function_text = function_text.replace(empty_statement, begin_call, 1)
    function_text = function_text.replace(empty_statement, end_call, 1)
    text = (text[:function_start] + function_text +
            text[function_end:])
    text = text.replace(
        declaration_marker,
        "\n" + FREXPL_PROFILE_MARKER + declaration_marker,
        1,
    )
    return text


def translate(patterns, jobs, contexts):
    require_coreutils_source()
    if C2FB_CONVERTER_OVERRIDE is None:
        run_logged(["make", "converter", f"FBC={FBC}"], "converter-build.log", cwd=TOOLS)
    elif not C2FB_CONVERTER.is_file():
        raise FileNotFoundError(
            f"COREUTILS_C2FB_CONVERTER does not exist: {C2FB_CONVERTER}"
        )
    database = selected_database(patterns)
    generated = PORT / ("generated-context" if contexts else "generated")
    command = [sys.executable, str(TOOLS / "c2fb_compile_commands.py"),
               str(database), str(generated),
               f"--converter={C2FB_CONVERTER}", f"--jobs={jobs}",
               *("--c2fb-option=" + option for option in BODY_OPTIONS)]
    command.extend("--body-compiler-option=" + option
                   for option in BODY_COMPILER_OPTIONS)
    command.extend(
        "--source-body-compiler-option=" + pattern + "=" + option
        for pattern, option in SOURCE_BODY_COMPILER_OPTIONS
    )
    command.extend(
        "--source-c2fb-option=" + pattern + "=" + option
        for pattern, option in SOURCE_C2FB_OPTIONS
    )
    if contexts:
        command.extend(
            "--source-header-compiler-option=" + pattern + "=" + option
            for pattern, option in SOURCE_HEADER_COMPILER_OPTIONS
        )
        command.extend(
            "--source-header-option=" + pattern + "=" + option
            for pattern, option in SOURCE_HEADER_OPTIONS
        )
        command.extend(["--source-unit-context",
                        *("--header-option=" + option for option in HEADER_OPTIONS)])
    run_logged(command, "translate.log")
    apply_source_fb_profile_overrides(database, generated, contexts)
    apply_source_fb_post_type_includes(database, generated, contexts)
    apply_source_fb_post_declaration_includes(database, generated, contexts)
    normalize_generated_output(generated, patterns)
    save_toolchain_snapshot(patterns, contexts)


def conversion_units(contexts):
    # Reuse the authoritative driver's argument normalization and filenames.
    # The full reference database remains the scope even after a focused run.
    name = "coreutils_c2fb_compile_commands"
    spec = importlib.util.spec_from_file_location(name, TOOLS / "c2fb_compile_commands.py")
    driver = importlib.util.module_from_spec(spec)
    sys.modules[name] = driver
    spec.loader.exec_module(driver)
    path = PORT / "build/compile_commands.json"
    entries = json.loads(path.read_text(encoding="utf-8"))
    options = list(BODY_OPTIONS)
    units = {}
    for index, entry in enumerate(entries):
        model = driver.parse_command_entry(entry, index, path.parent)
        if model is None:
            raise ValueError("production database contains a non-C translation unit")
        source_body_options = driver.source_body_compiler_options_for(
            model.source_path, SOURCE_BODY_COMPILER_OPTIONS)
        source_c2fb_options = driver.source_options_for(
            model.source_path, SOURCE_C2FB_OPTIONS)
        source_header_options = driver.source_options_for(
            model.source_path, SOURCE_HEADER_OPTIONS)
        source_header_compiler_options = (
            driver.source_header_compiler_options_for(
                model.source_path, SOURCE_HEADER_COMPILER_OPTIONS)
            if contexts else ()
        )
        signature_options = options + list(source_c2fb_options)
        if contexts:
            signature_options.extend((
                "--source-unit-context",
                *HEADER_OPTIONS,
                *source_header_options,
            ))
        signature = driver.command_signature(
            model, signature_options,
            (*BODY_COMPILER_OPTIONS, *source_body_options),
            source_header_compiler_options)
        filename = driver.output_filename(model, signature)
        unit = units.setdefault(filename, {"source": str(model.source_path),
                                           "reference_objects": []})
        unit["reference_objects"].append(Path(entry["directory"]) / entry["output"])
    return units


def defined_symbols(path):
    result = subprocess.run(["nm", "-g", "--defined-only", "--format=posix", str(path)],
                            capture_output=True, text=True, check=True)
    return {line.split()[0] for line in result.stdout.splitlines() if line.split()}


def generated_body_helper_names(candidate_text):
    """Return private FreeBASIC procedures generated to lower C constructs."""
    functions = re.findall(r"^(?:Private )?(?:Function|Sub) (\w+)\b",
                           candidate_text, re.MULTILINE)
    helper_prefixes = (
        # These adapters preserve C volatile-access and CPU feature behavior;
        # they are emitted by C2FB and have no corresponding C definitions.
        "c2fb_volatile_",
        "c2fb_cpu_features_",
        "c2fb_float16_to_single",
        "c2fb_bfloat16_to_single",
        "__c2fb_builtin_",
        "__c2fb_double_value",
        "__c2fb_single_value",
        "c2fb_record_initializer_",
        "c2fb_union_initializer_",
        "c2fb_obstack_blank_",
        "c2fb_obstack_finish_",
        "c2fb_obstack_grow_",
        "c2fb_obstack_free_",
        "c2fb_obstack_ptr_grow_",
        "c2fb_obstack_1grow_",
        "c2fb_builtin_stdc_",
    )
    return [name for name in functions if name.startswith(helper_prefixes)]


def emitted_c_function_names(candidate_text):
    """Return translated C procedures without generated FreeBASIC helpers."""
    functions = re.findall(r"^(?:Private )?(?:Function|Sub) (\w+)\b",
                           candidate_text, re.MULTILINE)
    helper_names = set(generated_body_helper_names(candidate_text))
    return [name for name in functions if name not in helper_names]


def audit(contexts, patterns=()):
    require_coreutils_source()
    units = conversion_units(contexts)
    selected_units = {}
    for filename, unit in units.items():
        relative_source = source_relative_path(unit["source"])
        if not patterns or any(fnmatch.fnmatchcase(relative_source, pattern)
                               for pattern in patterns):
            selected_units[filename] = unit
    if not selected_units:
        raise ValueError("source patterns selected no conversion candidates")

    audited_records = []
    generated = PORT / ("generated-context" if contexts else "generated")
    output = PORT / "build" / ("objects-context" if contexts else "objects")
    output.mkdir(parents=True, exist_ok=True)
    for filename, unit in sorted(selected_units.items()):
        candidate = generated / filename
        reference_symbols = set()
        for reference_object in unit["reference_objects"]:
            reference_symbols.update(defined_symbols(reference_object))
        if not candidate.is_file():
            audited_records.append({"candidate": str(candidate.relative_to(PORT)),
                                    "source": unit["source"], "missing_candidate": True,
                                    "functions": [], "generated_helpers": [], "skipped": [],
                                    "compile_status": None,
                                    "missing_link_symbols": sorted(reference_symbols)})
            continue
        text = candidate.read_text(encoding="utf-8")
        skipped = re.findall(r"^' c2fb skipped (\w+): (.*)$", text, re.MULTILINE)
        functions = emitted_c_function_names(text)
        generated_helpers = generated_body_helper_names(text)
        object_path = output / (candidate.stem + ".o")
        result = subprocess.run(
            [str(FBC), "-c", "-w", "all", "-maxerr", "10",
             "-i", str(PORT.parent), "-i", str(SOURCE),
             "-i", str(PORT / "profiles"),
             str(candidate),
             "-o", str(object_path)],
            cwd=PORT.parent, capture_output=True, text=True, check=False)
        log = PORT / "logs/compile" / (candidate.stem + ".log")
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(result.stdout + result.stderr, encoding="utf-8")
        fb_symbols = defined_symbols(object_path) if result.returncode == 0 else set()
        audited_records.append({"candidate": str(candidate.relative_to(PORT)),
                               "source": unit["source"], "missing_candidate": False,
                               "functions": functions,
                               "generated_helpers": generated_helpers,
                               "skipped": [{"function": name, "reason": reason}
                                           for name, reason in skipped],
                               "compile_status": result.returncode,
                               "missing_link_symbols": sorted(reference_symbols - fb_symbols),
                               "compile_log": str(log.relative_to(PORT))})
    if not audited_records:
        raise RuntimeError("no generated candidates exist to audit")

    report_name = "conversion-audit-context.json" if contexts else "conversion-audit.json"
    report_path = PORT / "build" / report_name
    if patterns:
        if not report_path.is_file():
            raise RuntimeError(
                "a source-scoped audit needs an existing full audit to update")
        previous = json.loads(report_path.read_text(encoding="utf-8"))
        audited_sources = {unit["source"] for unit in selected_units.values()}
        records = [record for record in previous["candidates"]
                   if record["source"] not in audited_sources]
        records.extend(audited_records)
    else:
        records = audited_records
    records.sort(key=lambda record: record["candidate"])
    reasons = Counter(item["reason"] for record in records
                      for item in record["skipped"])
    report = {"units": len(records),
              "missing_candidates": sum(item["missing_candidate"] for item in records),
              "compiled_units": sum(item["compile_status"] == 0 for item in records),
              "emitted_functions": sum(len(item["functions"]) for item in records),
              "generated_helper_functions": sum(
                  len(item["generated_helpers"]) for item in records),
              "skipped_functions": sum(len(item["skipped"]) for item in records),
              "missing_link_symbols": sum(len(item["missing_link_symbols"])
                                           for item in records),
              "skip_reasons": dict(reasons.most_common()), "candidates": records}
    write_json(report_path, report)
    print(json.dumps({key: value for key, value in report.items()
                      if key != "candidates"}, indent=2))
    # A successful report write does not mean the port is complete.
    return int(any(record["missing_candidate"]
                   or record["compile_status"] != 0
                   or record["skipped"]
                   or record["missing_link_symbols"]
                   for record in audited_records))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("compiler", "reference", "index-captures",
                                           "translate", "audit", "reference-tests"))
    parser.add_argument("--source", action="append", default=[])
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--contexts", action="store_true")
    arguments = parser.parse_args()
    if not 1 <= arguments.jobs <= 32:
        parser.error("--jobs must be between 1 and 32")
    if arguments.action == "compiler":
        build_compiler(arguments.jobs)
    elif arguments.action == "reference":
        reference_build(arguments.jobs)
    elif arguments.action == "index-captures":
        index_captured_commands()
    elif arguments.action == "translate":
        translate(arguments.source, arguments.jobs, arguments.contexts)
    elif arguments.action == "audit":
        return audit(arguments.contexts, arguments.source)
    else:
        require_coreutils_source()
        run_logged(["make", f"-j{arguments.jobs}", "check"], "reference-tests.log")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(f"coreutils FreeBASIC port: {error}", file=sys.stderr)
        raise SystemExit(1)

# end of port.py
