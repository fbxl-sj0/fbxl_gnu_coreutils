"""
Project: SQLite FreeBASIC port tools
File: c2fb_target_matrix.py
Purpose: Generate generic C header bindings for several compiler targets or API versions.
Responsibilities: Read a profile manifest, invoke C2FB once per profile, publish
    separate bindings, and optionally create a condition-dispatch include.
This file intentionally does NOT contain: C preprocessing or declaration translation.
"""

import argparse
from contextlib import ExitStack
from functools import lru_cache
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile


PROFILE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
COMBINED_BINDING_NAME = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}\.bi$", re.IGNORECASE
)
FREEBASIC_CONDITION = re.compile(r"^[A-Za-z0-9_() \t=!<>+\-]+$")
VERSION_MACRO = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
VERSION_VALUE = re.compile(r"^-?(?:0|[1-9][0-9]*)$")
FBFROG_TARGET_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")
# Match fbfrog/src/api.bi ApiBits.MaxApis, which stores 256 API combinations.
DEFAULT_MAX_PROFILES = 256
MAX_CONFIGURED_PROFILES = 4096
# Match fbfrog's argument-file expansion limit in src/fbfrog.bas.
MAX_FBFROG_SCRIPT_FILES = 1024
# These target names and architecture capabilities mirror fbfrog/src/api.bas.
FBFROG_OS_MACROS = {
    "linux": "__FB_LINUX__",
    "freebsd": "__FB_FREEBSD__",
    "openbsd": "__FB_OPENBSD__",
    "netbsd": "__FB_NETBSD__",
    "darwin": "__FB_DARWIN__",
    "windows": "__FB_WIN32__",
    "cygwin": "__FB_CYGWIN__",
    "dos": "__FB_DOS__",
}
FBFROG_UNIX_SYSTEMS = {
    "linux", "freebsd", "openbsd", "netbsd", "darwin", "cygwin",
}
FBFROG_64BIT_ARCHITECTURES = {"x86_64", "aarch64"}
FBFROG_ARM_ARCHITECTURES = {"arm", "aarch64"}
FBFROG_ARCHITECTURES = {"x86", "x86_64", "arm", "aarch64"}
FBFROG_OS_SUPPORTS_64BIT = {
    "linux", "freebsd", "openbsd", "netbsd", "darwin", "windows", "cygwin",
}
FBFROG_OS_SUPPORTS_ARM = {"linux", "freebsd", "openbsd", "netbsd"}
FBFROG_OS_COMPILER_PREDEFINES = {
    "linux": {
        "unix": "1", "__unix": "1", "__unix__": "1", "__ELF__": "1",
        "linux": "1", "__linux": "1", "__linux__": "1", "__gnu_linux__": "1",
    },
    "freebsd": {
        "unix": "1", "__unix": "1", "__unix__": "1", "__ELF__": "1",
        "__FreeBSD__": "10", "__FreeBSD_cc_version": "1000001",
    },
    "openbsd": {
        "unix": "1", "__unix": "1", "__unix__": "1", "__ELF__": "1",
        "__OpenBSD__": "1",
    },
    "netbsd": {
        "unix": "1", "__unix": "1", "__unix__": "1", "__ELF__": "1",
        "__NetBSD__": "1",
    },
    "darwin": {
        "unix": "1", "__unix": "1", "__unix__": "1",
        "__APPLE__": "1", "__MACH__": "1",
    },
    "windows": {
        "__MINGW32__": "1", "__MSVCRT__": "1", "WIN32": "1",
        "_WIN32": "1", "__WIN32": "1", "__WIN32__": "1",
        "WINNT": "1", "__WINNT": "1", "__WINNT__": "1",
    },
    "cygwin": {
        "unix": "1", "__unix": "1", "__unix__": "1", "__CYGWIN__": "1",
    },
    "dos": {
        "DJGPP": "2", "__DJGPP": "2", "__DJGPP__": "2", "GO32": "1",
        "__GO32": "1", "__GO32__": "1", "MSDOS": "1", "__MSDOS": "1",
        "__MSDOS__": "1",
    },
}
FBFROG_ARCH_COMPILER_PREDEFINES = {
    "x86": {
        "i386": "1", "__i386": "1", "__i386__": "1", "__i486__": "1",
        "__i586": "1", "__i586__": "1", "__pentium": "1",
        "__pentium__": "1", "__i686": "1", "__i686__": "1",
        "__pentiumpro": "1", "__pentiumpro__": "1", "_M_IX86": "",
        "_X86_": "", "__X86__": "1", "__code_model_32__": "1",
    },
    "x86_64": {
        "__x86_64": "1", "__x86_64__": "1", "__amd64": "1",
        "__amd64__": "1", "__k8": "1", "__k8__": "1", "_M_X64": "",
        "_M_AMD64": "", "__code_model_small__": "1", "__MMX__": "1",
        "__SSE__": "1", "__SSE2__": "1", "__SSE2_MATH__": "1",
        "__SSE_MATH__": "1",
    },
    "arm": {
        "__APCS_32__": "1", "__arm__": "1", "__ARM_32BIT_STATE": "1",
        "__ARM_ARCH": "7", "__ARM_ARCH_7A__": "1", "__ARM_ARCH_ISA_ARM": "1",
        "__ARM_ARCH_ISA_THUMB": "2", "__ARM_ARCH_PROFILE": "65",
        "__ARM_EABI__": "1", "__ARMEL__": "1", "__ARM_FEATURE_CLZ": "1",
        "__ARM_FEATURE_DSP": "1", "__ARM_FEATURE_LDREX": "15",
        "__ARM_FEATURE_QBIT": "1", "__ARM_FEATURE_SAT": "1",
        "__ARM_FEATURE_SIMD32": "1", "__ARM_FEATURE_UNALIGNED": "1",
        "__ARM_FP": "12", "__ARM_NEON_FP": "4", "__ARM_PCS_VFP": "1",
        "__ARM_SIZEOF_MINIMAL_ENUM": "4",
    },
    "aarch64": {
        "__aarch64__": "1", "__AARCH64_CMODEL_SMALL__": "1",
        "__AARCH64EL__": "1", "__ARM_64BIT_STATE": "1", "__ARM_ARCH": "8",
        "__ARM_ARCH_8A": "1", "__ARM_ARCH_ISA_A64": "1",
        "__ARM_ARCH_PROFILE": "65",
    },
}
FBFROG_TARGET_ABI_PREDEFINE_NAMES = {
    "__ORDER_BIG_ENDIAN__", "__ORDER_LITTLE_ENDIAN__", "__ORDER_PDP_ENDIAN__",
    "__BYTE_ORDER__", "__FLOAT_WORD_ORDER__", "__LITTLE_ENDIAN__",
    "__CHAR_BIT__", "__SIZEOF_SHORT__", "__SIZEOF_INT__",
    "__SIZEOF_LONG__", "__SIZEOF_LONG_DOUBLE__", "__SIZEOF_POINTER__",
    "__SIZEOF_PTRDIFF_T__", "__SIZEOF_SIZE_T__", "__SIZEOF_LONG_LONG__",
    "__SIZEOF_INT128__", "__SIZEOF_FLOAT__", "__SIZEOF_DOUBLE__",
    "__BIGGEST_ALIGNMENT__", "__LONG_MAX__", "__SIZE_TYPE__", "__SIZE_MAX__",
    "__PTRDIFF_TYPE__", "__PTRDIFF_MAX__", "__INTPTR_TYPE__",
    "__INTPTR_MAX__", "__UINTPTR_TYPE__", "__UINTPTR_MAX__",
    "__SIZEOF_WCHAR_T__", "__WCHAR_TYPE__", "__WCHAR_MIN__",
    "__WCHAR_MAX__", "__SIZEOF_WINT_T__", "__WINT_TYPE__",
    "__WINT_MIN__", "__WINT_MAX__",
}
FBFROG_COMPILER_VERSION_PREDEFINE_NAMES = {
    "__STDC__", "__STDC_VERSION__", "__STDC_HOSTED__", "__STDC_IEC_559__",
    "__GNUC__", "__GNUC_MINOR__", "__GNUC_PATCHLEVEL__", "__GNUC_PREREQ",
    "__clang__", "__clang_major__", "__clang_minor__",
    "__clang_patchlevel__", "__clang_version__", "__llvm__",
}
FBFROG_INTEGER_TYPE_PREDEFINE_NAMES = {
    "__INT8_TYPE__", "__INT8_MAX__", "__UINT8_TYPE__", "__UINT8_MAX__",
    "__INT16_TYPE__", "__INT16_MAX__", "__UINT16_TYPE__", "__UINT16_MAX__",
    "__INT32_TYPE__", "__INT32_MAX__", "__UINT32_TYPE__", "__UINT32_MAX__",
    "__INT64_TYPE__", "__INT64_MAX__", "__UINT64_TYPE__", "__UINT64_MAX__",
    "__SCHAR_MAX__", "__SHRT_MAX__", "__INT_MAX__", "__LONG_LONG_MAX__",
    "__INTMAX_TYPE__", "__INTMAX_MAX__", "__UINTMAX_TYPE__", "__UINTMAX_MAX__",
    "__CHAR16_TYPE__", "__CHAR32_TYPE__", "__SIG_ATOMIC_TYPE__",
    "__SIG_ATOMIC_MIN__", "__SIG_ATOMIC_MAX__",
    "__INT_FAST8_TYPE__", "__INT_FAST8_MAX__",
    "__UINT_FAST8_TYPE__", "__UINT_FAST8_MAX__",
    "__INT_FAST16_TYPE__", "__INT_FAST16_MAX__",
    "__UINT_FAST16_TYPE__", "__UINT_FAST16_MAX__",
    "__INT_FAST32_TYPE__", "__INT_FAST32_MAX__",
    "__UINT_FAST32_TYPE__", "__UINT_FAST32_MAX__",
    "__INT_FAST64_TYPE__", "__INT_FAST64_MAX__",
    "__UINT_FAST64_TYPE__", "__UINT_FAST64_MAX__",
    "__INT_LEAST8_TYPE__", "__INT_LEAST8_MAX__",
    "__UINT_LEAST8_TYPE__", "__UINT_LEAST8_MAX__",
    "__INT_LEAST16_TYPE__", "__INT_LEAST16_MAX__",
    "__UINT_LEAST16_TYPE__", "__UINT_LEAST16_MAX__",
    "__INT_LEAST32_TYPE__", "__INT_LEAST32_MAX__",
    "__UINT_LEAST32_TYPE__", "__UINT_LEAST32_MAX__",
    "__INT_LEAST64_TYPE__", "__INT_LEAST64_MAX__",
    "__UINT_LEAST64_TYPE__", "__UINT_LEAST64_MAX__",
    "__INT8_C", "__INT16_C", "__INT32_C", "__INT64_C", "__INTMAX_C",
    "__UINT8_C", "__UINT16_C", "__UINT32_C", "__UINT64_C", "__UINTMAX_C",
}
FBFROG_TARGET_PREDEFINE_NAMES = set(FBFROG_OS_MACROS.values()) | {
    "__FB_64BIT__", "__FB_ARM__", "__LP64__", "_LP64",
    "__USER_LABEL_PREFIX__", "_INTEGRAL_MAX_BITS", "_REENTRANT",
    "__cdecl", "_cdecl", "__declspec", "__fastcall", "_fastcall",
    "__stdcall", "_stdcall", "__thiscall", "_thiscall",
    "__extension__", "register",
} | {
    name for values in FBFROG_OS_COMPILER_PREDEFINES.values() for name in values
} | {
    name for values in FBFROG_ARCH_COMPILER_PREDEFINES.values() for name in values
} | FBFROG_TARGET_ABI_PREDEFINE_NAMES | \
    FBFROG_COMPILER_VERSION_PREDEFINE_NAMES | \
    FBFROG_INTEGER_TYPE_PREDEFINE_NAMES | {
    "__MINGW64__", "WIN64", "_WIN64", "__WIN64", "__WIN64__",
    "__CYGWIN32__",
}
FBFROG_C2FB_SINGLE_OPTIONS = {
    "-removedefine": "--exclude-define",
    "-removeproc": "--exclude-proc",
    "-removevar": "--exclude-variable",
    "-remove": "--exclude",
    "-dropprocbody": "--drop-inline-body",
    "-typedefhint": "--typedef-hint",
    "-addforwarddecl": "--forward-decl",
    "-ifndefdecl": "--ifndef-decl",
    "-undefbeforedecl": "--undef-before-decl",
    "-convbodytokens": "--convert-macro-tokens",
    "-forcefunction2macro": "--force-inline-macro",
    "-expandindefine": "--expand-in-define",
    "-noexpand": "--no-expand-macro",
    "-expand": "--expand-type",
    "-string": "--string",
    "-nostring": "--no-string",
    "-removeinclude": "--remove-include",
    "-replacements": "--replacement-file",
    "-dontemit": "--exclude-source",
    "-inclib": "--fb-library",
    "-undef": "--undef",
    "-addinclude": "--fb-include",
}
FBFROG_C2FB_PAIR_OPTIONS = {
    "-rename": "--rename",
    "-renametag": "--rename-tag",
    "-renametypedef": "--rename-typedef",
    "-renameproc": "--rename-proc",
    "-renamedefine": "--rename-define",
    "-renamemacroparam": "--rename-macro-param",
    "-moveabove": "--move-above",
    "-setarraysize": "--array-size",
}
FBFROG_C2FB_SWITCH_OPTIONS = {
    "-removeEmptyReservedDefines": "--remove-empty-reserved-defines",
    "-windowsms": "--windows-ms",
    "-clong32": "--clong32",
    "-nofunctionbodies": "--no-inline-bodies",
    "-dropmacrobodyscopes": "--drop-macro-body-scopes",
    "-fixunsizedarrays": "--fix-unsized-arrays",
}


def require_string(value, label):
    if not isinstance(value, str) or not value.strip() or "\0" in value:
        raise ValueError(f"{label} must be a non-empty string")
    return value.strip()


def string_list(value, label):
    if not isinstance(value, list):
        raise ValueError(f"{label} must be a list of command-line arguments")
    result = []
    for index, item in enumerate(value):
        result.append(require_string(item, f"{label}[{index}]"))
    return result


def is_fbfrog_binding_destination(value):
    """Accept a .bi file name or path used by fbfrog -emit and output options."""
    if not isinstance(value, str) or not value.strip() or "\0" in value:
        return False
    destination = Path(value)
    return destination.name not in {"", ".", ".."} and \
        destination.suffix.casefold() == ".bi"


def parse_fbfrog_target(value, label):
    target = require_string(value, label).casefold()
    if target == "win32":
        operating_system, architecture = "windows", "x86"
    elif target == "win64":
        operating_system, architecture = "windows", "x86_64"
    elif target == "dos":
        operating_system, architecture = "dos", "x86"
    else:
        pieces = target.split("-")
        if len(pieces) != 2:
            raise ValueError(
                f"{label} must name one concrete OS/architecture target"
            )
        operating_system, architecture = pieces
    if operating_system not in FBFROG_OS_MACROS:
        raise ValueError(f"{label} has unknown fbfrog OS {operating_system!r}")
    if architecture not in FBFROG_ARCHITECTURES:
        raise ValueError(f"{label} has unknown fbfrog architecture {architecture!r}")
    if operating_system == "dos" and architecture != "x86":
        raise ValueError(f"{label}: fbfrog supports DOS only on x86")
    if operating_system == "windows" and architecture not in {"x86", "x86_64"}:
        raise ValueError(f"{label}: fbfrog supports Windows only on x86/x86_64")
    if architecture in FBFROG_64BIT_ARCHITECTURES and \
       operating_system not in FBFROG_OS_SUPPORTS_64BIT:
        raise ValueError(f"{label}: fbfrog does not define a 64-bit {operating_system} target")
    if architecture in FBFROG_ARM_ARCHITECTURES and \
       operating_system not in FBFROG_OS_SUPPORTS_ARM:
        raise ValueError(f"{label}: fbfrog does not define an ARM {operating_system} target")
    canonical = {
        ("windows", "x86"): "win32",
        ("windows", "x86_64"): "win64",
        ("dos", "x86"): "dos",
    }.get((operating_system, architecture), f"{operating_system}-{architecture}")
    return {
        "fbfrog_target": canonical,
        "os": operating_system,
        "arch": architecture,
        "os_macro": FBFROG_OS_MACROS[operating_system],
        "is_unix": operating_system in FBFROG_UNIX_SYSTEMS,
        "is_64bit": architecture in FBFROG_64BIT_ARCHITECTURES,
        "is_arm": architecture in FBFROG_ARM_ARCHITECTURES,
    }


def default_fbfrog_target_specs():
    """Return the same OS/architecture target set FBFrog enables by default."""
    targets = []
    for operating_system in FBFROG_OS_MACROS:
        architectures = ["x86"]
        if operating_system in FBFROG_OS_SUPPORTS_64BIT:
            architectures.append("x86_64")
        if operating_system in FBFROG_OS_SUPPORTS_ARM:
            architectures.append("arm")
            if operating_system in FBFROG_OS_SUPPORTS_64BIT:
                architectures.append("aarch64")
        for architecture in architectures:
            target_name = {
                ("windows", "x86"): "win32",
                ("windows", "x86_64"): "win64",
                ("dos", "x86"): "dos",
            }.get(
                (operating_system, architecture),
                f"{operating_system}-{architecture}",
            )
            targets.append({
                "name": target_name,
                "fbfrog_target": target_name,
            })
    return targets


@lru_cache(maxsize=32)
def compiler_has_clang_predefines(compiler):
    """Check whether the selected C preprocessor is Clang."""
    try:
        command = shlex.split(compiler)
    except ValueError:
        return False
    if not command:
        return False
    try:
        result = subprocess.run(
            [*command, "-dM", "-E", "-x", "c", "-"],
            input="", capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0 and re.search(
        r"^#define __clang__\s+", result.stdout, re.MULTILINE,
    ) is not None


def fbfrog_target_compiler_predefines(target):
    definitions = dict(FBFROG_OS_COMPILER_PREDEFINES[target["os"]])
    definitions.update(FBFROG_ARCH_COMPILER_PREDEFINES[target["arch"]])
    definitions[target["os_macro"]] = "1"
    if target["is_64bit"]:
        definitions["__FB_64BIT__"] = "1"
    if target["is_arm"]:
        definitions["__FB_ARM__"] = "1"
    if target["is_unix"] and target["is_64bit"]:
        definitions["__LP64__"] = "1"
        definitions["_LP64"] = "1"
    if target["os"] == "windows" and target["is_64bit"]:
        definitions.update({
            "__MINGW64__": "1", "WIN64": "1", "_WIN64": "1",
            "__WIN64": "1", "__WIN64__": "1",
        })
    if target["os"] == "cygwin" and not target["is_64bit"]:
        definitions["__CYGWIN32__"] = "1"
    definitions["__USER_LABEL_PREFIX__"] = (
        "_" if target["os"] in {"dos", "windows", "cygwin"} else ""
    )
    definitions["__extension__"] = ""
    definitions["register"] = ""
    if target["os"] == "windows":
        definitions["_INTEGRAL_MAX_BITS"] = "64"
        definitions["_REENTRANT"] = "1"
    if target["os"] in {"windows", "cygwin"}:
        definitions.update({
            "__cdecl": "__attribute__((__cdecl__))",
            "_cdecl": "__attribute__((__cdecl__))",
            "__declspec(x)": "__attribute__((x))",
            "__fastcall": "__attribute__((__fastcall__))",
            "_fastcall": "__attribute__((__fastcall__))",
            "__stdcall": "__attribute__((__stdcall__))",
            "_stdcall": "__attribute__((__stdcall__))",
            "__thiscall": "__attribute__((__thiscall__))",
            "_thiscall": "__attribute__((__thiscall__))",
        })

    # FBFrog exposes a stable GCC/Clang identity to each target profile.
    definitions.update({
        "__STDC__": "1",
        "__STDC_VERSION__": "199901",
        "__STDC_HOSTED__": "1",
        "__STDC_IEC_559__": "1",
        "__GNUC__": "4",
        "__GNUC_MINOR__": "1111111",
        "__GNUC_PATCHLEVEL__": "1111111",
        "__GNUC_PREREQ(maj,min)": (
            "((__GNUC__ << 16) + __GNUC_MINOR__ >= "
            "((maj) << 16) + (min))"
        ),
        "__clang__": "1",
        "__clang_major__": "3",
        "__clang_minor__": "1111111",
        "__clang_patchlevel__": "1111111",
        "__clang_version__": '"fbfrog"',
        "__llvm__": "1",
    })

    # FBFrog's default.h supplies target sizes even when the preprocessor runs
    # on a different host. Replace the host compiler's corresponding builtins.
    pointer_size = 8 if target["is_64bit"] else 4
    long_size = 8 if target["is_unix"] and target["is_64bit"] else 4
    if target["is_64bit"]:
        long_double_size = 16
    elif target["is_arm"]:
        long_double_size = 8
    else:
        long_double_size = 12
    if target["os"] in {"dos", "cygwin", "windows"}:
        wchar_size = 2
        wchar_type = "unsigned short int"
        wchar_min = "0"
        wchar_max = "65535"
        if target["os"] == "windows":
            wint_size = 2
            wint_type = "unsigned short int"
            wint_min = "0"
            wint_max = "65535"
        elif target["os"] == "dos":
            wint_size = 4
            wint_type = "int"
            wint_min = "(-2147483647 - 1)"
            wint_max = "2147483647"
        else:
            wint_size = 4
            wint_type = "unsigned int"
            wint_min = "0u"
            wint_max = "4294967295U"
    elif target["is_arm"]:
        wchar_size = 4
        wchar_type = "unsigned int"
        wchar_min = "0u"
        wchar_max = "4294967295U"
        wint_size = 4
        wint_type = "unsigned int"
        wint_min = "0u"
        wint_max = "4294967295U"
    else:
        wchar_size = 4
        wchar_type = "int"
        wchar_min = "(-2147483647 - 1)"
        wchar_max = "2147483647"
        wint_size = 4
        if target["os"] == "linux":
            wint_type = "unsigned int"
            wint_min = "0u"
            wint_max = "4294967295U"
        else:
            wint_type = "int"
            wint_min = "(-2147483647 - 1)"
            wint_max = "2147483647"

    if pointer_size == 8:
        size_type = "long long unsigned int"
        size_max = "18446744073709551615ULL"
        ptrdiff_type = "long long int"
        ptrdiff_max = "9223372036854775807LL"
        intptr_type = "long long int"
        intptr_max = "9223372036854775807LL"
        uintptr_type = "long long unsigned int"
        uintptr_max = "18446744073709551615ULL"
    else:
        size_type = "unsigned int"
        size_max = "4294967295U"
        ptrdiff_type = "int"
        ptrdiff_max = "2147483647"
        intptr_type = "int"
        intptr_max = "2147483647"
        uintptr_type = "unsigned int"
        uintptr_max = "4294967295U"

    definitions.update({
        "__ORDER_BIG_ENDIAN__": "4321",
        "__ORDER_LITTLE_ENDIAN__": "1234",
        "__ORDER_PDP_ENDIAN__": "3412",
        "__BYTE_ORDER__": "__ORDER_LITTLE_ENDIAN__",
        "__FLOAT_WORD_ORDER__": "__ORDER_LITTLE_ENDIAN__",
        "__LITTLE_ENDIAN__": "1",
        "__CHAR_BIT__": "8",
        "__SIZEOF_SHORT__": "2",
        "__SIZEOF_INT__": "4",
        "__SIZEOF_LONG__": str(long_size),
        "__SIZEOF_LONG_DOUBLE__": str(long_double_size),
        "__SIZEOF_POINTER__": str(pointer_size),
        "__SIZEOF_PTRDIFF_T__": str(pointer_size),
        "__SIZEOF_SIZE_T__": str(pointer_size),
        "__SIZEOF_LONG_LONG__": "8",
        "__SIZEOF_INT128__": "16",
        "__SIZEOF_FLOAT__": "4",
        "__SIZEOF_DOUBLE__": "8",
        "__BIGGEST_ALIGNMENT__": (
            "8" if target["is_arm"] and not target["is_64bit"] else "16"
        ),
        "__LONG_MAX__": (
            "9223372036854775807LL" if long_size == 8 else "2147483647"
        ),
        "__SIZE_TYPE__": size_type,
        "__SIZE_MAX__": size_max,
        "__PTRDIFF_TYPE__": ptrdiff_type,
        "__PTRDIFF_MAX__": ptrdiff_max,
        "__INTPTR_TYPE__": intptr_type,
        "__INTPTR_MAX__": intptr_max,
        "__UINTPTR_TYPE__": uintptr_type,
        "__UINTPTR_MAX__": uintptr_max,
        "__SIZEOF_WCHAR_T__": str(wchar_size),
        "__WCHAR_TYPE__": wchar_type,
        "__WCHAR_MIN__": wchar_min,
        "__WCHAR_MAX__": wchar_max,
        "__SIZEOF_WINT_T__": str(wint_size),
        "__WINT_TYPE__": wint_type,
        "__WINT_MIN__": wint_min,
        "__WINT_MAX__": wint_max,
        "__INT8_TYPE__": "signed char",
        "__INT8_MAX__": "127",
        "__UINT8_TYPE__": "unsigned char",
        "__UINT8_MAX__": "255",
        "__INT16_TYPE__": "short int",
        "__INT16_MAX__": "32767",
        "__UINT16_TYPE__": "short unsigned int",
        "__UINT16_MAX__": "65535",
        "__INT32_TYPE__": "int",
        "__INT32_MAX__": "2147483647",
        "__UINT32_TYPE__": "unsigned int",
        "__UINT32_MAX__": "4294967295U",
        "__INT64_TYPE__": "long long int",
        "__INT64_MAX__": "9223372036854775807LL",
        "__UINT64_TYPE__": "long long unsigned int",
        "__UINT64_MAX__": "18446744073709551615ULL",
        "__SCHAR_MAX__": "__INT8_MAX__",
        "__SHRT_MAX__": "__INT16_MAX__",
        "__INT_MAX__": "__INT32_MAX__",
        "__LONG_LONG_MAX__": "__INT64_MAX__",
        "__INTMAX_TYPE__": "__INT64_TYPE__",
        "__INTMAX_MAX__": "__INT64_MAX__",
        "__UINTMAX_TYPE__": "__UINT64_TYPE__",
        "__UINTMAX_MAX__": "__UINT64_MAX__",
        "__CHAR16_TYPE__": "__UINT16_TYPE__",
        "__CHAR32_TYPE__": "__UINT32_TYPE__",
        "__SIG_ATOMIC_TYPE__": "__INT32_TYPE__",
        "__SIG_ATOMIC_MIN__": "(-__SIG_ATOMIC_MAX__ - 1)",
        "__SIG_ATOMIC_MAX__": "__INT32_MAX__",
        "__INT8_C(c)": "c",
        "__INT16_C(c)": "c",
        "__INT32_C(c)": "c",
        "__INT64_C(c)": "c ## LL",
        "__INTMAX_C(c)": "c ## LL",
        "__UINT8_C(c)": "c",
        "__UINT16_C(c)": "c",
        "__UINT32_C(c)": "c ## U",
        "__UINT64_C(c)": "c ## ULL",
        "__UINTMAX_C(c)": "c ## ULL",
    })

    if target["os"] in {"linux", "windows", "cygwin", "dos"}:
        definitions.update({
            "__INT_FAST8_TYPE__": "__INT8_TYPE__",
            "__INT_FAST8_MAX__": "__INT8_MAX__",
            "__UINT_FAST8_TYPE__": "__UINT8_TYPE__",
            "__UINT_FAST8_MAX__": "__UINT8_MAX__",
            "__INT_FAST64_TYPE__": "__INT64_TYPE__",
            "__INT_FAST64_MAX__": "__INT64_MAX__",
            "__UINT_FAST64_TYPE__": "__UINT64_TYPE__",
            "__UINT_FAST64_MAX__": "__UINT64_MAX__",
            "__INT_LEAST8_TYPE__": "__INT8_TYPE__",
            "__INT_LEAST8_MAX__": "__INT8_MAX__",
            "__UINT_LEAST8_TYPE__": "__UINT8_TYPE__",
            "__UINT_LEAST8_MAX__": "__UINT8_MAX__",
            "__INT_LEAST16_TYPE__": "__INT16_TYPE__",
            "__INT_LEAST16_MAX__": "__INT16_MAX__",
            "__UINT_LEAST16_TYPE__": "__UINT16_TYPE__",
            "__UINT_LEAST16_MAX__": "__UINT16_MAX__",
            "__INT_LEAST32_TYPE__": "int",
            "__INT_LEAST32_MAX__": "__INT32_MAX__",
            "__UINT_LEAST32_TYPE__": "__UINT32_TYPE__",
            "__UINT_LEAST32_MAX__": "__UINT32_MAX__",
            "__INT_LEAST64_TYPE__": "__INT64_TYPE__",
            "__INT_LEAST64_MAX__": "__INT64_MAX__",
            "__UINT_LEAST64_TYPE__": "__UINT64_TYPE__",
            "__UINT_LEAST64_MAX__": "__UINT64_MAX__",
        })
        if target["is_64bit"] and target["os"] in {"linux", "cygwin"}:
            definitions.update({
                "__INT_FAST16_TYPE__": "__INT64_TYPE__",
                "__INT_FAST16_MAX__": "__INT64_MAX__",
                "__UINT_FAST16_TYPE__": "__UINT64_TYPE__",
                "__UINT_FAST16_MAX__": "__UINT64_MAX__",
                "__INT_FAST32_TYPE__": "__INT64_TYPE__",
                "__INT_FAST32_MAX__": "__INT64_MAX__",
                "__UINT_FAST32_TYPE__": "__UINT64_TYPE__",
                "__UINT_FAST32_MAX__": "__UINT64_MAX__",
            })
        else:
            fast16_type = (
                "__INT16_TYPE__"
                if target["os"] in {"windows", "dos"} else "int"
            )
            fast16_max = (
                "__INT16_MAX__"
                if target["os"] in {"windows", "dos"} else "__INT32_MAX__"
            )
            fast16_unsigned_type = (
                "__UINT16_TYPE__"
                if target["os"] in {"windows", "dos"} else "__UINT32_TYPE__"
            )
            fast16_unsigned_max = (
                "__UINT16_MAX__"
                if target["os"] in {"windows", "dos"} else "__UINT32_MAX__"
            )
            definitions.update({
                "__INT_FAST16_TYPE__": fast16_type,
                "__INT_FAST16_MAX__": fast16_max,
                "__UINT_FAST16_TYPE__": fast16_unsigned_type,
                "__UINT_FAST16_MAX__": fast16_unsigned_max,
                "__INT_FAST32_TYPE__": "int",
                "__INT_FAST32_MAX__": "__INT32_MAX__",
                "__UINT_FAST32_TYPE__": "__UINT32_TYPE__",
                "__UINT_FAST32_MAX__": "__UINT32_MAX__",
            })
    return definitions


def freebasic_target_wstring_size(target):
    """Return FBC's target WSTRING code-unit width from its target table."""
    if target["os"] in {"windows", "cygwin", "xbox"}:
        return 2
    if target["os"] == "dos":
        return 1
    return 4


def fbfrog_target_matches(pattern, target):
    pattern = pattern.casefold()
    if pattern == "64bit":
        return target["is_64bit"]
    if pattern == "32bit":
        return not target["is_64bit"]
    if pattern == "win32":
        return target["fbfrog_target"] == "win32"
    if pattern == "win64":
        return target["fbfrog_target"] == "win64"
    if pattern == "unix":
        return target["is_unix"]
    return pattern in {
        target["os"], target["arch"], target["fbfrog_target"],
    }


def filter_fbfrog_targets(targets, target_options):
    if not target_options:
        return targets

    enabled_os = set(FBFROG_OS_MACROS)
    enabled_arch = set(FBFROG_ARCHITECTURES)
    first_target_option = True
    for raw_option in target_options:
        option = raw_option.casefold()
        if first_target_option:
            enabled_os.clear()
            enabled_arch.clear()
            first_target_option = False

        if option == "nodos":
            enabled_os = set(FBFROG_OS_MACROS)
            enabled_arch = set(FBFROG_ARCHITECTURES)
            enabled_os.discard("dos")
        elif option == "noarm":
            enabled_os = set(FBFROG_OS_MACROS)
            enabled_arch = set(FBFROG_ARCHITECTURES) - FBFROG_ARM_ARCHITECTURES
        elif option == "win32":
            enabled_os.add("windows")
            enabled_arch.add("x86")
        elif option == "win64":
            enabled_os.add("windows")
            enabled_arch.add("x86_64")
        elif "-" in option:
            target = parse_fbfrog_target(option, "fbfrog -target")
            enabled_os.add(target["os"])
            enabled_arch.add(target["arch"])
        elif option in FBFROG_OS_MACROS:
            enabled_os.add(option)
            enabled_arch = set(FBFROG_ARCHITECTURES)
        elif option in FBFROG_ARCHITECTURES:
            enabled_os = set(FBFROG_OS_MACROS)
            enabled_arch.add(option)
        else:
            raise ValueError(f"unsupported fbfrog -target value {raw_option!r}")

    selected = [
        target for target in targets
        if target["os"] in enabled_os and target["arch"] in enabled_arch
    ]
    if not selected:
        raise ValueError("fbfrog -target filters select no configured targets")
    return selected


def translate_fbfrog_script_option(command, arguments):
    if command in FBFROG_C2FB_SINGLE_OPTIONS:
        option = FBFROG_C2FB_SINGLE_OPTIONS[command]
        return [f"{option}={arguments[0]}"]
    if command in FBFROG_C2FB_PAIR_OPTIONS:
        option = FBFROG_C2FB_PAIR_OPTIONS[command]
        return [f"{option}={arguments[0]}={arguments[1]}"]
    if command == "-rename_":
        return [f"--rename={arguments[0]}={arguments[0]}_"]
    if command == "-remove1st":
        return [f"--remove-first={arguments[0]}"]
    if command == "-remove2nd":
        return [f"--remove-repeated={arguments[0]}"]
    if command in FBFROG_C2FB_SWITCH_OPTIONS:
        return [FBFROG_C2FB_SWITCH_OPTIONS[command]]
    return None


def expand_version_matrix(matrix, profile_limit=DEFAULT_MAX_PROFILES):
    if not isinstance(matrix, dict):
        raise ValueError("version_matrix must be a JSON object")
    allowed_keys = {
        "macro",
        "values",
        "name_prefix",
        "compiler",
        "compiler_options",
        "compiler_option_template",
        "c2fb_options",
        "freebasic_condition_template",
        "input",
        "headers",
    }
    unknown_keys = sorted(set(matrix) - allowed_keys)
    if unknown_keys:
        raise ValueError(
            f"unknown version_matrix key(s): {', '.join(unknown_keys)}"
        )

    macro = require_string(matrix.get("macro"), "version_matrix.macro")
    if not VERSION_MACRO.fullmatch(macro):
        raise ValueError("version_matrix.macro must be a C identifier")
    values = matrix.get("values")
    if not isinstance(values, list) or not values:
        raise ValueError("version_matrix.values must be a non-empty list")
    if len(values) > profile_limit:
        raise ValueError(
            f"version_matrix.values may contain at most {profile_limit} entries"
        )

    name_prefix = require_string(
        matrix.get("name_prefix", "version"), "version_matrix.name_prefix"
    )
    compiler = require_string(matrix.get("compiler"), "version_matrix.compiler")
    compiler_options = string_list(
        matrix.get("compiler_options", []), "version_matrix.compiler_options"
    )
    c2fb_options = string_list(
        matrix.get("c2fb_options", []), "version_matrix.c2fb_options"
    )
    compiler_option_template = require_string(
        matrix.get("compiler_option_template", "-D{macro}={value}"),
        "version_matrix.compiler_option_template",
    )
    condition_template = require_string(
        matrix.get(
            "freebasic_condition_template", "{macro} = {value}"
        ),
        "version_matrix.freebasic_condition_template",
    )

    profiles = []
    seen_values = set()
    for index, raw_value in enumerate(values):
        if isinstance(raw_value, bool) or not isinstance(raw_value, (int, str)):
            raise ValueError(
                f"version_matrix.values[{index}] must be an integer or numeric string"
            )
        value = str(raw_value).strip()
        if not VERSION_VALUE.fullmatch(value):
            raise ValueError(
                f"version_matrix.values[{index}] must be a decimal integer"
            )
        if value in seen_values:
            raise ValueError(f"duplicate version_matrix value: {value}")
        seen_values.add(value)
        try:
            name = f"{name_prefix}-{value}"
            condition = condition_template.format(macro=macro, value=value)
            compiler_define = compiler_option_template.format(
                macro=macro, value=value
            )
        except (KeyError, ValueError) as error:
            raise ValueError(
                f"invalid version_matrix template: {error}"
            ) from error
        profile = {
            "name": name,
            "compiler": compiler,
            "compiler_options": [
                *compiler_options,
                require_string(
                    compiler_define,
                    f"version_matrix compiler option for {value}",
                ),
            ],
            "c2fb_options": c2fb_options,
            "freebasic_condition": condition,
        }
        if matrix.get("input") is not None:
            profile["input"] = matrix["input"]
        if matrix.get("headers") is not None:
            profile["headers"] = matrix["headers"]
        profiles.append(profile)
    return profiles


def read_fbfrog_script(script_path):
    """Parse the supported declaration, target, and binding-option subset."""
    script_path = Path(script_path)
    file_count = 0

    def location_prefix(record):
        if record is None:
            return ""
        return f"{record['source_path']}:{record['line']}: "

    def load_script_tokens(path, ancestors=(), include_site=None):
        nonlocal file_count
        path = Path(path)
        if not path.is_absolute():
            base_directory = (
                include_site["source_path"].parent
                if include_site is not None else Path.cwd()
            )
            path = base_directory / path
        try:
            path = path.resolve()
        except (OSError, RuntimeError) as error:
            raise ValueError(
                f"{location_prefix(include_site)}cannot resolve fbfrog script "
                f"{path}: {error}"
            ) from error
        if path in ancestors:
            raise ValueError(
                f"{location_prefix(include_site)}recursive fbfrog script "
                f"inclusion: {path}"
            )
        file_count += 1
        if file_count > MAX_FBFROG_SCRIPT_FILES:
            raise ValueError(
                f"{location_prefix(include_site)}fbfrog script expands to more "
                f"than {MAX_FBFROG_SCRIPT_FILES} files"
            )
        try:
            lines = path.read_text(
                encoding="utf-8", errors="replace").splitlines()
        except OSError as error:
            raise ValueError(
                f"{location_prefix(include_site)}cannot read fbfrog script "
                f"{path}: {error}"
            ) from error

        include_chain = (*ancestors, path)
        records = []
        for line_number, line in enumerate(lines, 1):
            try:
                line_tokens = shlex.split(line, comments=True)
            except ValueError as error:
                raise ValueError(
                    f"{path}:{line_number}: invalid quoting: {error}"
                ) from error
            for token in line_tokens:
                record = {
                    "token": token,
                    "line": line_number,
                    "source_path": path,
                    "include_chain": include_chain,
                }
                if token.startswith("@"):
                    if token == "@":
                        raise ValueError(
                            f"{path}:{line_number}: expected a file name after @"
                        )
                    records.extend(load_script_tokens(
                        token[1:], include_chain, record
                    ))
                else:
                    records.append(record)
        return records

    token_records = load_script_tokens(script_path)
    tokens = [record["token"] for record in token_records]
    index = 0
    version_declarations = []
    boolean_declarations = []
    target_filters = []
    emit_groups = []
    emit_rules = []
    emit_group_indexes = {}
    destination_references = []
    output_path = None
    current_output_path = None
    default_input_path = None
    verbosity = 0

    def fail(message, token_index=None):
        if token_index is None:
            raise ValueError(f"{script_path}:1: {message}")
        record = token_records[token_index]
        raise ValueError(
            f"{record['source_path']}:{record['line']}: {message}"
        )

    def token_base_directory(token_index):
        return token_records[token_index]["source_path"].parent

    def resolve_script_path_argument(value, token_index):
        path = Path(value)
        if not path.is_absolute():
            path = token_base_directory(token_index) / path
        try:
            return str(path.resolve())
        except (OSError, RuntimeError) as error:
            fail(f"cannot resolve script path {path}: {error}", token_index)

    def output_destination_key(value):
        path = Path(value)
        if not path.is_absolute() and current_output_path is not None and \
           Path(current_output_path).is_dir():
            path = Path(current_output_path) / path
        normalized_path = os.path.normpath(str(path))
        return os.path.normcase(normalized_path).casefold()

    def require_identifier(value, description, token_index):
        if not VERSION_MACRO.fullmatch(value):
            fail(f"{description} must be a C identifier", token_index)

    def parse_sequence(stops=frozenset()):
        nonlocal index, output_path, current_output_path, default_input_path
        nonlocal verbosity
        nodes = []
        while index < len(tokens):
            command_index = index
            command = tokens[index]
            if command in stops:
                break
            index += 1

            if command == "-declareversions":
                if index >= len(tokens):
                    fail("expected -declareversions <macro> <values...>", command_index)
                macro = tokens[index]
                macro_index = index
                index += 1
                require_identifier(macro, "version selector", macro_index)
                values = []
                while index < len(tokens) and (
                    not tokens[index].startswith("-") or
                    VERSION_VALUE.fullmatch(tokens[index])
                ):
                    values.append(tokens[index])
                    index += 1
                if not values or any(VERSION_VALUE.fullmatch(value) is None for value in values):
                    fail("version values must be decimal integers", command_index)
                if len(set(values)) != len(values):
                    fail("duplicate version value", command_index)
                numeric_values = [int(value, 10) for value in values]
                if any(left >= right for left, right in zip(numeric_values, numeric_values[1:])):
                    fail("version values must be in ascending order", command_index)
                declaration = {"kind": "versions", "macro": macro, "values": values}
                version_declarations.append(declaration)
                nodes.append(declaration)
            elif command == "-o":
                if index >= len(tokens):
                    fail("expected an output path after -o", command_index)
                current_output_path = resolve_script_path_argument(tokens[index], index)
                output_path = current_output_path
                index += 1
            elif command == "-declarebool":
                if index >= len(tokens):
                    fail("expected -declarebool <symbol>", command_index)
                macro_index = index
                macro = tokens[index]
                index += 1
                require_identifier(macro, "boolean selector", macro_index)
                declaration = {"kind": "boolean", "macro": macro}
                boolean_declarations.append(declaration)
                nodes.append(declaration)
            elif command in {
                "-selectversion", "-selectdefine", "-selecttarget",
            }:
                selector_kind = {
                    "-selectversion": "version",
                    "-selectdefine": "define",
                    "-selecttarget": "target",
                }[command]
                cases = []
                saw_else = False
                if index >= len(tokens) or tokens[index] != "-case":
                    fail(f"expected -case after {command}", command_index)
                while index < len(tokens) and tokens[index] != "-endselect":
                    if tokens[index] == "-case":
                        if saw_else:
                            fail("-case behind -caseelse", index)
                        case_index = index
                        index += 1
                        if index >= len(tokens) or (
                            tokens[index].startswith("-") and
                            VERSION_VALUE.fullmatch(tokens[index]) is None
                        ):
                            fail("expected a case value", case_index)
                        value_index = index
                        value = tokens[index]
                        index += 1
                        if selector_kind == "define":
                            require_identifier(value, "selectdefine case", value_index)
                        elif VERSION_VALUE.fullmatch(value) is None:
                            if selector_kind == "version":
                                fail("selectversion cases must be decimal integers", value_index)
                            if FBFROG_TARGET_PATTERN.fullmatch(value) is None:
                                fail("selecttarget case must be a target pattern", value_index)
                        if any(existing["value"] == value for existing in cases):
                            fail("duplicate select case", value_index)
                        body = parse_sequence(frozenset({"-case", "-caseelse", "-endselect"}))
                        cases.append({"value": value, "body": body})
                    elif tokens[index] == "-caseelse":
                        if saw_else:
                            fail("duplicate -caseelse", index)
                        saw_else = True
                        index += 1
                        body = parse_sequence(frozenset({"-case", "-caseelse", "-endselect"}))
                        cases.append({"value": None, "body": body})
                    else:
                        fail("expected -case, -caseelse, or -endselect", index)
                if index >= len(tokens):
                    fail(f"missing -endselect for {command}", command_index)
                index += 1
                nodes.append({"kind": "select", "selector": selector_kind, "cases": cases})
            elif command in {"-ifdef", "-iftarget"}:
                if index >= len(tokens):
                    description = "-ifdef <symbol>" if command == "-ifdef" else "-iftarget <target>"
                    fail(f"expected {description}", command_index)
                value_index = index
                value = tokens[index]
                index += 1
                if command == "-ifdef":
                    require_identifier(value, "ifdef symbol", value_index)
                elif FBFROG_TARGET_PATTERN.fullmatch(value) is None:
                    fail("iftarget argument must be a target pattern", value_index)
                true_body = parse_sequence(frozenset({"-else", "-endif"}))
                false_body = []
                if index < len(tokens) and tokens[index] == "-else":
                    index += 1
                    false_body = parse_sequence(frozenset({"-else", "-endif"}))
                    if index < len(tokens) and tokens[index] == "-else":
                        fail("-else behind -else", index)
                if index >= len(tokens) or tokens[index] != "-endif":
                    fail(f"missing -endif for {command}", command_index)
                index += 1
                if command == "-ifdef":
                    nodes.append({"kind": "ifdef", "symbol": value,
                                  "true": true_body, "false": false_body})
                else:
                    nodes.append({"kind": "iftarget", "pattern": value,
                                  "true": true_body, "false": false_body})
            elif command == "-define":
                if index >= len(tokens):
                    fail("expected -define <name> [body]", command_index)
                name_index = index
                name = tokens[index]
                index += 1
                require_identifier(name, "-define name", name_index)
                body = None
                if index < len(tokens):
                    next_token = tokens[index]
                    if not next_token.startswith("-") or VERSION_VALUE.fullmatch(next_token):
                        body = next_token
                        index += 1
                nodes.append({"kind": "define", "name": name, "body": body})
            elif command in {"-include", "-incdir"}:
                if index >= len(tokens) or tokens[index].startswith("-"):
                    fail(f"expected a path after {command}", command_index)
                path_index = index
                path = tokens[index]
                index += 1
                nodes.append({
                    "kind": "include" if command == "-include" else "incdir",
                    "path": path,
                    "base_directory": str(token_base_directory(path_index)),
                })
            elif command == "-fbfroginclude":
                if index >= len(tokens) or tokens[index].startswith("-"):
                    fail("expected a C header path after -fbfroginclude", command_index)
                path_index = index
                path = tokens[index]
                index += 1
                nodes.append({
                    "kind": "fbfroginclude",
                    "path": path,
                    "base_directory": str(token_base_directory(path_index)),
                })
            elif command == "-title":
                if index + 2 >= len(tokens):
                    fail(
                        "expected -title <text> <license file> <translators file>",
                        command_index,
                    )
                title, license_path, translators_path = tokens[index:index + 3]
                license_base_directory = str(token_base_directory(index + 1))
                translators_base_directory = str(token_base_directory(index + 2))
                if not title.strip():
                    fail("-title text must not be empty", index)
                index += 3
                destination = None
                if index < len(tokens) and tokens[index].casefold().endswith(".bi"):
                    destination_path = tokens[index]
                    if not is_fbfrog_binding_destination(destination_path):
                        fail("-title destination must be a .bi file name or path", index)
                    destination = output_destination_key(destination_path)
                    destination_references.append(destination)
                    index += 1
                nodes.append({
                    "kind": "title",
                    "title": title,
                    "license": license_path,
                    "translators": translators_path,
                    "license_base_directory": license_base_directory,
                    "translators_base_directory": translators_base_directory,
                    "destination": destination,
                })
            elif command == "-emit":
                # fbfrog records -emit while parsing, outside its conditional API
                # path evaluation, so these routes apply to every expanded profile.
                if index + 1 >= len(tokens):
                    fail("expected -emit <source pattern> <destination .bi>", command_index)
                source_pattern = tokens[index]
                destination = tokens[index + 1]
                index += 2
                if not is_fbfrog_binding_destination(destination):
                    fail(
                        "-emit destination must be a .bi file name or path",
                        command_index,
                    )
                destination_key = output_destination_key(destination)
                emit_output_directory = None
                if current_output_path is not None and \
                   Path(current_output_path).is_dir():
                    emit_output_directory = current_output_path
                group_index = emit_group_indexes.get(destination_key)
                if group_index is None:
                    group_index = len(emit_groups)
                    emit_group_indexes[destination_key] = group_index
                    emit_groups.append({
                        "destination": destination,
                        "destination_key": destination_key,
                        "patterns": [],
                        "output_directory": emit_output_directory,
                    })
                emit_groups[group_index]["patterns"].append(source_pattern)
                emit_rules.append({
                    "pattern": source_pattern,
                    "destination_key": destination_key,
                })
            elif command in FBFROG_C2FB_SINGLE_OPTIONS or command in {
                "-rename_", "-remove1st", "-remove2nd",
            }:
                if index >= len(tokens) or tokens[index].startswith("-"):
                    fail(f"expected an argument after {command}", command_index)
                argument_index = index
                option_arguments = [tokens[index]]
                if command == "-replacements":
                    option_arguments[0] = resolve_script_path_argument(
                        option_arguments[0], argument_index
                    )
                index += 1
                translated_options = translate_fbfrog_script_option(
                    command, option_arguments
                )
                destination = None
                if command in {"-addinclude", "-inclib", "-undef"} and \
                   index < len(tokens) and tokens[index].casefold().endswith(".bi"):
                    destination_path = tokens[index]
                    if not is_fbfrog_binding_destination(destination_path):
                        fail(
                            f"{command} destination must be a .bi file name or path",
                            index,
                        )
                    destination = output_destination_key(destination_path)
                    destination_references.append(destination)
                    index += 1
                if destination is None:
                    option_kind = (
                        "default-destination-c2fb-options"
                        if command in {"-addinclude", "-inclib", "-undef"}
                        else "c2fb-options"
                    )
                    nodes.append({"kind": option_kind, "arguments": translated_options})
                else:
                    nodes.append({
                        "kind": "destination-c2fb-options",
                        "destination": destination,
                        "arguments": translated_options,
                    })
            elif command in FBFROG_C2FB_PAIR_OPTIONS:
                if index + 1 >= len(tokens) or tokens[index].startswith("-") or \
                   tokens[index + 1].startswith("-"):
                    fail(f"expected two arguments after {command}", command_index)
                option_arguments = tokens[index:index + 2]
                index += 2
                nodes.append({
                    "kind": "c2fb-options",
                    "arguments": translate_fbfrog_script_option(
                        command, option_arguments
                    ),
                })
            elif command in FBFROG_C2FB_SWITCH_OPTIONS or \
                 command == "-fixunsizedarrays":
                nodes.append({
                    "kind": "c2fb-options",
                    "arguments": translate_fbfrog_script_option(command, []),
                })
            elif command == "-target":
                if index >= len(tokens) or tokens[index].startswith("-"):
                    fail("expected a target after -target", command_index)
                pattern = tokens[index]
                index += 1
                if FBFROG_TARGET_PATTERN.fullmatch(pattern) is None:
                    fail("-target argument must be a target pattern", command_index)
                target_filters.append(pattern)
            elif command == "-v":
                # FBFrog verbosity is global even when nested in a script branch.
                if verbosity < 2:
                    verbosity += 1
            elif command in {"-case", "-caseelse", "-endselect", "-else", "-endif"}:
                fail(f"unmatched {command}", command_index)
            elif command.startswith("-"):
                fail(f"unsupported fbfrog script option {command}", command_index)
            else:
                if command.casefold().endswith(".fbfrog"):
                    record = token_records[command_index]
                    nested_records = load_script_tokens(
                        command, record["include_chain"], record
                    )
                    tokens[command_index:command_index + 1] = [
                        nested_record["token"] for nested_record in nested_records
                    ]
                    token_records[command_index:command_index + 1] = nested_records
                    index = command_index
                    continue
                nodes.append({
                    "kind": "input",
                    "path": command,
                    "base_directory": str(token_base_directory(command_index)),
                })
                if default_input_path is None:
                    default_input_path = resolve_script_path_argument(
                        command, command_index
                    )
        return nodes

    nodes = parse_sequence()
    if index != len(tokens):
        fail("unexpected script token", index)
    if len(version_declarations) > 1:
        fail("only one -declareversions directive is supported")
    boolean_names = list(dict.fromkeys(
        entry["macro"] for entry in boolean_declarations
    ))

    version = version_declarations[0] if version_declarations else None
    return {
        "nodes": nodes,
        "version": version,
        "booleans": boolean_names,
        "target_filters": target_filters,
        "emit_groups": emit_groups,
        "emit_rules": emit_rules,
        "destination_references": destination_references,
        "output_path": output_path,
        "default_input_path": default_input_path,
        "verbosity": verbosity,
    }


def expand_fbfrog_version_script(
    script_config, base_directory, profile_limit=DEFAULT_MAX_PROFILES
):
    if not isinstance(script_config, dict):
        raise ValueError("fbfrog_version_script must be a JSON object")
    allowed_keys = {
        "path", "compiler", "name_prefix", "compiler_options",
        "c2fb_options", "freebasic_condition_template", "targets",
    }
    unknown_keys = sorted(set(script_config) - allowed_keys)
    if unknown_keys:
        raise ValueError(
            "unknown fbfrog_version_script key(s): " + ", ".join(unknown_keys)
        )
    script_path = resolve_manifest_path(
        base_directory, script_config.get("path"), "fbfrog_version_script.path"
    )
    parsed = read_fbfrog_script(script_path)
    compiler_value = script_config.get("compiler")
    compiler = None if compiler_value is None else require_string(
        compiler_value, "fbfrog_version_script.compiler"
    )
    if "targets" in script_config:
        raw_targets = script_config["targets"]
    else:
        # FBFrog enables its full target set unless the user filters it.
        if compiler is None:
            compiler = "cc"
        raw_targets = default_fbfrog_target_specs()
    name_prefix = require_string(
        script_config.get("name_prefix", "fbfrog-version"),
        "fbfrog_version_script.name_prefix",
    )
    common_compiler_options = string_list(
        script_config.get("compiler_options", []),
        "fbfrog_version_script.compiler_options",
    )
    common_c2fb_options = string_list(
        script_config.get("c2fb_options", []),
        "fbfrog_version_script.c2fb_options",
    )
    common_c2fb_options = [
        "--fbfrog-string-defaults",
        *(["-v"] * parsed["verbosity"]),
        *common_c2fb_options,
    ]
    condition_template = require_string(
        script_config.get(
            "freebasic_condition_template", "{macro} = {value}"
        ),
        "fbfrog_version_script.freebasic_condition_template",
    )

    if not isinstance(raw_targets, list):
        raise ValueError("fbfrog_version_script.targets must be a list")
    if len(raw_targets) > MAX_CONFIGURED_PROFILES:
        raise ValueError(
            "fbfrog_version_script.targets may contain at most "
            f"{MAX_CONFIGURED_PROFILES} entries"
        )

    targets = []
    seen_target_names = set()
    for target_index, target_value in enumerate(raw_targets):
        target_label = f"fbfrog_version_script.targets[{target_index}]"
        if not isinstance(target_value, dict):
            raise ValueError(f"{target_label} must be a JSON object")
        target_keys = {
            "name", "fbfrog_target", "compiler", "compiler_options",
            "c2fb_options", "freebasic_condition",
        }
        unknown_target_keys = sorted(set(target_value) - target_keys)
        if unknown_target_keys:
            raise ValueError(
                f"unknown key(s) in {target_label}: {', '.join(unknown_target_keys)}"
            )

        target_name = require_string(target_value.get("name"), f"{target_label}.name")
        if not PROFILE_NAME.fullmatch(target_name):
            raise ValueError(f"{target_label}.name is not a valid profile name")
        if target_name.casefold() in seen_target_names:
            raise ValueError(f"duplicate fbfrog target profile name: {target_name}")
        seen_target_names.add(target_name.casefold())

        target = parse_fbfrog_target(
            target_value.get("fbfrog_target"), f"{target_label}.fbfrog_target"
        )
        target_compiler = target_value.get("compiler", compiler)
        if target_compiler is None:
            raise ValueError(
                f"{target_label}.compiler or fbfrog_version_script.compiler is required"
            )
        target["name"] = target_name
        target["compiler"] = require_string(
            target_compiler, f"{target_label}.compiler"
        )
        target["compiler_options"] = string_list(
            target_value.get("compiler_options", []),
            f"{target_label}.compiler_options",
        )
        target["c2fb_options"] = string_list(
            target_value.get("c2fb_options", []),
            f"{target_label}.c2fb_options",
        )

        default_condition_parts = [f"defined({target['os_macro']})"]
        if target["is_64bit"]:
            default_condition_parts.append("defined(__FB_64BIT__)")
        else:
            default_condition_parts.append("not defined(__FB_64BIT__)")
        if target["is_arm"]:
            default_condition_parts.append("defined(__FB_ARM__)")
        elif target["arch"] in {"x86", "x86_64"}:
            default_condition_parts.append("not defined(__FB_ARM__)")
        target["freebasic_condition"] = require_string(
            target_value.get(
                "freebasic_condition", " and ".join(default_condition_parts)
            ),
            f"{target_label}.freebasic_condition",
        )
        targets.append(target)

    if not targets and compiler is None:
        raise ValueError(
            "fbfrog_version_script.compiler is required when targets are omitted"
        )
    if parsed["target_filters"] and not targets:
        raise ValueError("fbfrog -target requires fbfrog_version_script.targets")
    targets = filter_fbfrog_targets(targets, parsed["target_filters"])

    states = []
    for target in targets:
        states.append({
            "definitions": {}, "conditions": [], "selectors": {},
            "headers": [], "preprocessor_options": [], "c2fb_options": [],
            "default_destination_c2fb_options": [],
            "destination_c2fb_options": {}, "title_options": None,
            "destination_titles": {},
            "target": target,
        })
    if not states:
        states.append({
            "definitions": {}, "conditions": [], "selectors": {},
            "headers": [], "preprocessor_options": [], "c2fb_options": [],
            "default_destination_c2fb_options": [],
            "destination_c2fb_options": {}, "title_options": None,
            "destination_titles": {},
            "target": None,
        })

    def clone_state(state):
        return {
            "definitions": dict(state["definitions"]),
            "conditions": list(state["conditions"]),
            "selectors": dict(state["selectors"]),
            "headers": list(state["headers"]),
            "preprocessor_options": list(state["preprocessor_options"]),
            "c2fb_options": list(state["c2fb_options"]),
            "default_destination_c2fb_options": list(
                state["default_destination_c2fb_options"]
            ),
            "destination_c2fb_options": {
                key: list(value)
                for key, value in state["destination_c2fb_options"].items()
            },
            "title_options": (
                None if state["title_options"] is None
                else list(state["title_options"])
            ),
            "destination_titles": {
                key: list(value)
                for key, value in state["destination_titles"].items()
            },
            "target": state["target"],
        }

    def script_relative_path(value, base_directory=None):
        path = Path(require_string(value, "fbfrog script path"))
        if not path.is_absolute():
            base = script_path.parent if base_directory is None else Path(base_directory)
            path = base / path
        try:
            return str(path.resolve())
        except (OSError, RuntimeError) as error:
            raise ValueError(f"cannot resolve fbfrog script path {path}: {error}") from error

    def include_argument(value, base_directory=None):
        path = Path(value)
        if path.is_absolute():
            return str(path)
        base = script_path.parent if base_directory is None else Path(base_directory)
        if path.parent != Path(".") or (base / path).exists():
            return script_relative_path(value, base)
        return value

    def apply_nodes(node_list, input_states):
        current_states = input_states
        for node in node_list:
            next_states = []
            kind = node["kind"]
            for state in current_states:
                if kind == "versions":
                    if state["selectors"].get(node["macro"]) is not None:
                        raise ValueError("version declaration is reached more than once on one script path")
                    for value in node["values"]:
                        variant = clone_state(state)
                        variant["selectors"][node["macro"]] = value
                        variant["conditions"].append(f"{node['macro']} = {value}")
                        next_states.append(variant)
                elif kind == "boolean":
                    if node["macro"] in state["selectors"]:
                        raise ValueError(
                            f"boolean selector {node['macro']} is reached more than once on one script path"
                        )
                    for enabled in (True, False):
                        variant = clone_state(state)
                        variant["selectors"][node["macro"]] = enabled
                        if enabled:
                            variant["conditions"].append(f"defined({node['macro']})")
                        else:
                            variant["conditions"].append(f"not defined({node['macro']})")
                        next_states.append(variant)
                elif kind == "define":
                    variant = clone_state(state)
                    variant["definitions"][node["name"]] = node["body"]
                    next_states.append(variant)
                elif kind == "ifdef":
                    symbol = node["symbol"]
                    branch = node["true"] if state["selectors"].get(symbol) is True else node["false"]
                    next_states.extend(apply_nodes(branch, [clone_state(state)]))
                elif kind == "iftarget":
                    target = state["target"]
                    if target is None:
                        raise ValueError(
                            f"-iftarget {node['pattern']} requires fbfrog_version_script.targets"
                        )
                    branch = node["true"] if fbfrog_target_matches(
                        node["pattern"], target
                    ) else node["false"]
                    next_states.extend(apply_nodes(branch, [clone_state(state)]))
                elif kind == "select":
                    selected_body = None
                    for case in node["cases"]:
                        if case["value"] is None:
                            if selected_body is None:
                                selected_body = case["body"]
                            break
                        if node["selector"] == "version":
                            selector = parsed["version"]
                            if selector is None:
                                raise ValueError("-selectversion requires -declareversions")
                            value = state["selectors"].get(selector["macro"])
                            if case["value"] not in selector["values"]:
                                raise ValueError(
                                    f"selectversion case {case['value']} was not declared"
                                )
                            matches = value is not None and value == case["value"]
                        elif node["selector"] == "define":
                            symbol = case["value"]
                            matches = state["selectors"].get(symbol) is True
                        else:
                            target = state["target"]
                            if target is None:
                                raise ValueError(
                                    "-selecttarget requires fbfrog_version_script.targets"
                                )
                            matches = fbfrog_target_matches(case["value"], target)
                        if matches:
                            selected_body = case["body"]
                            break
                    if selected_body is not None:
                        next_states.extend(apply_nodes(selected_body, [clone_state(state)]))
                    else:
                        next_states.append(clone_state(state))
                elif kind == "input":
                    variant = clone_state(state)
                    variant["headers"].append(script_relative_path(
                        node["path"], node.get("base_directory")))
                    next_states.append(variant)
                elif kind == "include":
                    variant = clone_state(state)
                    variant["preprocessor_options"].extend([
                        "-include", include_argument(
                            node["path"], node.get("base_directory")),
                    ])
                    next_states.append(variant)
                elif kind == "fbfroginclude":
                    variant = clone_state(state)
                    included_path = script_relative_path(
                        node["path"], node.get("base_directory"))
                    variant["preprocessor_options"].extend([
                        "-include", included_path,
                    ])
                    variant["c2fb_options"].append(
                        "--exclude-source=" + included_path)
                    next_states.append(variant)
                elif kind == "incdir":
                    variant = clone_state(state)
                    variant["preprocessor_options"].append(
                        "-I" + script_relative_path(
                            node["path"], node.get("base_directory"))
                    )
                    next_states.append(variant)
                elif kind == "c2fb-options":
                    variant = clone_state(state)
                    variant["c2fb_options"].extend(node["arguments"])
                    next_states.append(variant)
                elif kind == "default-destination-c2fb-options":
                    variant = clone_state(state)
                    variant["default_destination_c2fb_options"].extend(
                        node["arguments"]
                    )
                    next_states.append(variant)
                elif kind == "destination-c2fb-options":
                    variant = clone_state(state)
                    key = node["destination"].casefold()
                    variant["destination_c2fb_options"].setdefault(key, []).extend(
                        node["arguments"]
                    )
                    next_states.append(variant)
                elif kind == "title":
                    variant = clone_state(state)
                    title_options = [
                        "--title=" + node["title"],
                        "--license-file=" + script_relative_path(
                            node["license"],
                            node.get("license_base_directory")),
                        "--translators-file=" + script_relative_path(
                            node["translators"],
                            node.get("translators_base_directory")),
                    ]
                    if node["destination"] is None:
                        if variant["title_options"] is not None:
                            raise ValueError("duplicate global -title metadata")
                        variant["title_options"] = title_options
                    else:
                        key = node["destination"].casefold()
                        if key in variant["destination_titles"]:
                            raise ValueError(
                                f"duplicate -title metadata for {node['destination']}"
                            )
                        variant["destination_titles"][key] = title_options
                    next_states.append(variant)
                else:
                    raise ValueError(f"unsupported parsed fbfrog command: {kind}")
            current_states = next_states
            if len(current_states) > profile_limit:
                raise ValueError(
                    f"fbfrog script expands to more than {profile_limit} API profiles"
                )
        return current_states

    states = apply_nodes(parsed["nodes"], states)
    if not states or len(states) > profile_limit:
        raise ValueError(
            f"fbfrog script must expand to 1..{profile_limit} API profiles"
        )

    profiles = []
    for profile_index, state in enumerate(states, 1):
        try:
            condition_terms = []
            if state["target"]:
                condition_terms.append(state["target"]["freebasic_condition"])
            if parsed["version"]:
                macro = parsed["version"]["macro"]
                version_condition = condition_template.format(
                    macro=macro,
                    value=state["selectors"][macro],
                )
                condition_terms.append(version_condition)
            elif condition_template != "{macro} = {value}":
                raise ValueError(
                    "custom freebasic_condition_template requires a version selector"
                )
            for macro in parsed["booleans"]:
                if macro not in state["selectors"]:
                    continue
                if state["selectors"][macro]:
                    condition_terms.append(f"defined({macro})")
                else:
                    condition_terms.append(f"not defined({macro})")
            condition = " and ".join(f"({term})" for term in condition_terms)
        except (KeyError, ValueError) as error:
            raise ValueError(
                f"invalid fbfrog version condition template: {error}"
            ) from error

        label_parts = []
        if state["target"]:
            label_parts.append(state["target"]["name"])
        if parsed["version"]:
            macro = parsed["version"]["macro"]
            label_parts.append(str(state["selectors"][macro]))
        for macro in parsed["booleans"]:
            if macro in state["selectors"]:
                label_parts.append(f"{macro.lower()}-{'on' if state['selectors'][macro] else 'off'}")
        label = "-".join(label_parts) or str(profile_index)
        profile_name = f"{name_prefix}-{label}"
        if not PROFILE_NAME.fullmatch(profile_name):
            profile_name = f"{name_prefix[:45]}-{profile_index:03d}"

        target = state["target"]
        compiler_options = list(common_compiler_options)
        c2fb_options = list(common_c2fb_options)
        if target:
            compiler_options.extend(target["compiler_options"])
            c2fb_options.extend(target["c2fb_options"])
            c2fb_options.append(
                "--fbfrog-wstring-size="
                + str(freebasic_target_wstring_size(target))
            )
            compiler_options.extend(
                f"-U{macro}" for macro in sorted(FBFROG_TARGET_PREDEFINE_NAMES)
            )
            for macro, value in fbfrog_target_compiler_predefines(target).items():
                compiler_options.append(f"-D{macro}={value}")
            if compiler_has_clang_predefines(target["compiler"]):
                compiler_options.extend([
                    "-Wno-builtin-macro-redefined",
                    "-U__has_feature",
                    "-D__has_feature(x)=0",
                ])
        compiler_options.extend(state["preprocessor_options"])
        c2fb_options.extend(state["c2fb_options"])
        for macro in state["selectors"]:
            value = state["selectors"][macro]
            if isinstance(value, bool):
                compiler_options.append(f"-D{macro}=1" if value else f"-U{macro}")
            else:
                compiler_options.append(f"-D{macro}={value}")
        for name, body in state["definitions"].items():
            if body is None:
                compiler_options.append(f"-D{name}=")
            else:
                compiler_options.append(f"-D{name}={body}")
        profiles.append({
            "name": profile_name,
            "headers": list(dict.fromkeys(state["headers"])),
            "compiler": target["compiler"] if target else compiler,
            "compiler_options": compiler_options,
            "c2fb_options": c2fb_options,
            "default_destination_c2fb_options": state[
                "default_destination_c2fb_options"
            ],
            "destination_c2fb_options": state["destination_c2fb_options"],
            "title_options": state["title_options"],
            "destination_titles": state["destination_titles"],
            "freebasic_condition": condition or None,
        })
    return {
        "profiles": profiles,
        "emit_groups": parsed["emit_groups"],
        "emit_rules": parsed["emit_rules"],
        "destination_references": parsed["destination_references"],
        "output_path": parsed["output_path"],
        "default_input_path": parsed["default_input_path"],
    }


def resolve_manifest_path(base_directory, value, label):
    path = Path(require_string(value, label))
    if not path.is_absolute():
        path = base_directory / path
    try:
        return path.resolve()
    except (OSError, RuntimeError) as error:
        raise ValueError(f"cannot resolve {label} path {path}: {error}") from error


def read_matrix_config(manifest_path):
    try:
        source = manifest_path.read_text(encoding="utf-8")
    except OSError as error:
        raise ValueError(f"cannot read manifest {manifest_path}: {error}") from error
    try:
        config = json.loads(source)
    except json.JSONDecodeError as error:
        raise ValueError(
            f"invalid JSON in {manifest_path} at line {error.lineno}, "
            f"column {error.colno}: {error.msg}"
        ) from error
    if not isinstance(config, dict):
        raise ValueError("manifest root must be a JSON object")

    allowed_keys = {
        "input",
        "output_directory",
        "converter",
        "combined_binding",
        "max_profiles",
        "c2fb_options",
        "compiler_options",
        "profiles",
        "version_matrix",
        "fbfrog_version_script",
    }
    unknown_keys = sorted(set(config) - allowed_keys)
    if unknown_keys:
        raise ValueError(f"unknown manifest key(s): {', '.join(unknown_keys)}")

    profile_limit = config.get("max_profiles", DEFAULT_MAX_PROFILES)
    if (
        isinstance(profile_limit, bool)
        or not isinstance(profile_limit, int)
        or profile_limit < 1
        or profile_limit > MAX_CONFIGURED_PROFILES
    ):
        raise ValueError(
            f"max_profiles must be an integer from 1 to {MAX_CONFIGURED_PROFILES}"
        )

    base_directory = manifest_path.parent
    input_path = None
    input_argument = None
    if config.get("input") is not None:
        input_argument = require_string(config.get("input"), "input")
        input_path = resolve_manifest_path(base_directory, input_argument, "input")
        if not input_path.is_file():
            raise ValueError(f"input header does not exist: {input_path}")

    output_directory = None
    if config.get("output_directory") is not None:
        output_directory = resolve_manifest_path(
            base_directory, config["output_directory"], "output_directory"
        )

    converter_text = require_string(config.get("converter"), "converter")
    converter_path = Path(converter_text)
    if converter_path.is_absolute() or len(converter_path.parts) > 1:
        converter = str(resolve_manifest_path(base_directory, converter_text, "converter"))
    else:
        converter = converter_text

    combined_binding = config.get("combined_binding")
    if combined_binding is not None:
        combined_binding = require_string(combined_binding, "combined_binding")
        if not COMBINED_BINDING_NAME.fullmatch(combined_binding):
            raise ValueError("combined_binding must be a .bi file name in output_directory")

    common_c2fb_options = string_list(
        config.get("c2fb_options", []), "c2fb_options"
    )
    common_compiler_options = string_list(
        config.get("compiler_options", []), "compiler_options"
    )

    profiles = config.get("profiles", [])
    if not isinstance(profiles, list):
        raise ValueError("profiles must be a list")
    combined_bindings = []
    profile_output_paths = {}
    if config.get("version_matrix") is not None and \
       config.get("fbfrog_version_script") is not None:
        raise ValueError(
            "version_matrix and fbfrog_version_script are mutually exclusive"
        )
    if config.get("version_matrix") is not None:
        if config.get("combined_binding") is None:
            raise ValueError("version_matrix requires combined_binding")
        profiles = profiles + expand_version_matrix(
            config["version_matrix"], profile_limit
        )
    if config.get("fbfrog_version_script") is not None:
        script_expansion = expand_fbfrog_version_script(
            config["fbfrog_version_script"], base_directory, profile_limit
        )
        script_profiles = script_expansion["profiles"]
        emit_groups = script_expansion["emit_groups"]
        emit_rules = script_expansion["emit_rules"]
        destination_references = script_expansion["destination_references"]
        script_output_path = script_expansion["output_path"]
        if emit_groups:
            for group in emit_groups:
                output_destination = Path(group["destination"])
                group_output_directory = group["output_directory"]
                if group_output_directory is not None:
                    group_output_directory = Path(group_output_directory)
                elif output_directory is not None:
                    group_output_directory = output_directory
                if output_destination.is_absolute():
                    group_output_path = output_destination.resolve()
                else:
                    if group_output_directory is None:
                        raise ValueError(
                            "relative fbfrog -emit destinations need an output_directory or an existing -o directory"
                        )
                    group_output_path = (
                        group_output_directory / output_destination
                    ).resolve()
                group["output_directory"] = group_output_directory
                group["output_path"] = group_output_path
                group["selector_name"] = group_output_path.name
                group["selector_output_directory"] = group_output_path.parent
                group["profile_output_directory"] = group_output_path.parent
                group["route_destination"] = str(group_output_path)
            if output_directory is None:
                output_directory = emit_groups[0]["output_path"].parent
        elif script_output_path is not None:
            output_path = Path(script_output_path)
            if output_path.is_dir():
                output_directory = output_path
                if combined_binding is None:
                    default_input = input_path
                    if default_input is None and script_expansion["default_input_path"]:
                        default_input = Path(script_expansion["default_input_path"])
                    combined_binding = (
                        default_input.stem + ".bi"
                        if default_input is not None else "unknown.bi"
                    )
            else:
                if output_path.suffix.casefold() != ".bi":
                    raise ValueError(
                        "fbfrog -o file output must use a .bi extension in target-matrix mode"
                    )
                output_name = output_path.name
                if not COMBINED_BINDING_NAME.fullmatch(output_name):
                    raise ValueError(
                        "fbfrog -o file output must be a .bi file name"
                    )
                if combined_binding is not None and \
                   combined_binding.casefold() != output_name.casefold():
                    raise ValueError(
                        "fbfrog -o output conflicts with combined_binding"
                    )
                combined_binding = output_name
                output_directory = output_path.parent
        for profile in script_profiles:
            script_headers = profile.pop("headers", [])
            if input_argument is not None:
                script_headers.insert(0, input_argument)
            if script_headers:
                profile["headers"] = list(dict.fromkeys(script_headers))
        available_destinations = {
            group["destination_key"] for group in emit_groups
        }
        if not emit_groups and combined_binding is not None:
            available_destinations.add(combined_binding.casefold())
        missing_destinations = sorted(
            {destination.casefold() for destination in destination_references}
            - available_destinations
        )
        if missing_destinations:
            raise ValueError(
                "fbfrog binding option references an unknown -emit destination: "
                + ", ".join(missing_destinations)
            )
        if emit_groups:
            if profiles or config.get("version_matrix") is not None:
                raise ValueError(
                    "fbfrog -emit groups cannot be combined with separate manifest profiles"
                )
            explicit_combined = config.get("combined_binding")
            if explicit_combined is not None and (
                len(emit_groups) != 1 or
                explicit_combined.casefold() != emit_groups[0]["destination"].casefold()
            ):
                raise ValueError(
                    "when using fbfrog -emit, omit combined_binding or set it to the single emit destination"
                )
            if len(emit_groups) == 1 and explicit_combined is not None:
                combined_binding = None

            direct_profile_outputs = (
                len(script_profiles) == 1 and
                script_profiles[0]["freebasic_condition"] is None
            )
            for group_index, group in enumerate(emit_groups):
                group_profile_names = []
                for profile_index, script_profile in enumerate(script_profiles):
                    profile = dict(script_profile)
                    if direct_profile_outputs:
                        profile_name = (
                            f"emit{group_index + 1}-"
                            f"{Path(group['destination']).stem}"
                        )
                    else:
                        profile_name = f"emit{group_index + 1}-{script_profile['name']}"
                        if len(profile_name) > 64:
                            profile_name = f"emit{group_index + 1}-{profile_index + 1}"
                    if not PROFILE_NAME.fullmatch(profile_name):
                        raise ValueError(
                            f"fbfrog -emit destination cannot form a C2FB profile name: "
                            f"{group['destination']}"
                        )
                    profile["name"] = profile_name
                    if direct_profile_outputs:
                        profile_output_paths[profile_name] = group["output_path"]
                    else:
                        profile_output_paths[profile_name] = (
                            group["profile_output_directory"] /
                            f"{profile_name}.bi"
                        )
                    destination_key = group["destination_key"]
                    title_options = script_profile["destination_titles"].get(
                        destination_key, script_profile["title_options"] or []
                    )
                    default_output_options = (
                        script_profile["default_destination_c2fb_options"]
                        if group_index == 0 else []
                    )
                    profile["c2fb_options"] = [
                        *script_profile["c2fb_options"],
                        *(
                            option
                            for rule in emit_rules
                            for option in (
                                "--source-route", rule["pattern"],
                                next(
                                    candidate["route_destination"]
                                    for candidate in emit_groups
                                    if candidate["destination_key"] ==
                                       rule["destination_key"]
                                ),
                            )
                        ),
                        "--source-destination", group["route_destination"],
                        *default_output_options,
                        *script_profile["destination_c2fb_options"].get(
                            destination_key, []),
                        *title_options,
                    ]
                    profile.pop("default_destination_c2fb_options", None)
                    profile.pop("destination_c2fb_options", None)
                    profile.pop("title_options", None)
                    profile.pop("destination_titles", None)
                    profiles.append(profile)
                    group_profile_names.append(profile_name)
                if not direct_profile_outputs:
                    combined_bindings.append({
                        "name": group["selector_name"],
                        "profiles": group_profile_names,
                        "output_directory": group["selector_output_directory"],
                        "path": group["output_path"],
                    })
        else:
            if combined_binding is None:
                raise ValueError(
                    "fbfrog_version_script requires combined_binding when it has no -emit groups"
                )
            combined_key = combined_binding.casefold()
            for profile in script_profiles:
                title_options = profile["destination_titles"].get(
                    combined_key, profile["title_options"] or []
                )
                profile["c2fb_options"].extend(
                    profile["default_destination_c2fb_options"]
                )
                profile["c2fb_options"].extend(
                    profile["destination_c2fb_options"].get(combined_key, [])
                )
                profile["c2fb_options"].extend(title_options)
                profile.pop("default_destination_c2fb_options", None)
                profile.pop("destination_c2fb_options", None)
                profile.pop("title_options", None)
                profile.pop("destination_titles", None)
            profiles = profiles + script_profiles
    if output_directory is None:
        raise ValueError(
            "output_directory is required unless a fbfrog -o path selects it"
        )
    if combined_binding is not None and \
       not COMBINED_BINDING_NAME.fullmatch(combined_binding):
        raise ValueError("combined_binding must be a .bi file name in output_directory")
    if not profiles:
        raise ValueError("profiles or version_matrix must define at least one profile")
    if len(profiles) > profile_limit:
        raise ValueError(f"profiles may contain at most {profile_limit} entries")

    parsed_profiles = []
    seen_names = set()
    input_paths = set()
    for index, profile in enumerate(profiles):
        label = f"profiles[{index}]"
        if not isinstance(profile, dict):
            raise ValueError(f"{label} must be a JSON object")
        profile_keys = {
            "name",
            "input",
            "headers",
            "compiler",
            "c2fb_options",
            "compiler_options",
            "freebasic_condition",
        }
        unknown_profile_keys = sorted(set(profile) - profile_keys)
        if unknown_profile_keys:
            raise ValueError(
                f"unknown key(s) in {label}: {', '.join(unknown_profile_keys)}"
            )

        name = require_string(profile.get("name"), f"{label}.name")
        if not PROFILE_NAME.fullmatch(name):
            raise ValueError(
                f"{label}.name must start with a letter or digit and contain only "
                "letters, digits, underscores, or hyphens"
            )
        folded_name = name.casefold()
        if folded_name in seen_names:
            raise ValueError(f"duplicate profile name: {name}")
        seen_names.add(folded_name)

        if profile.get("input") is not None and profile.get("headers") is not None:
            raise ValueError(f"{label} must use either input or headers, not both")
        if profile.get("headers") is not None:
            header_arguments = string_list(profile["headers"], f"{label}.headers")
            if not header_arguments:
                raise ValueError(f"{label}.headers must contain at least one C header")
        elif profile.get("input") is not None:
            header_arguments = [require_string(profile["input"], f"{label}.input")]
        elif input_path is not None:
            header_arguments = [input_argument]
        else:
            raise ValueError(
                f"{label} must specify input or headers when the manifest has no default input"
            )
        headers = []
        for header_index, header_argument in enumerate(header_arguments):
            header_path = resolve_manifest_path(
                base_directory, header_argument, f"{label}.headers[{header_index}]"
            )
            if not header_path.is_file():
                raise ValueError(f"C header does not exist: {header_path}")
            # Absolute root paths make GCC/Clang line markers stable, so
            # suffix-based --emit-source filters behave the same for relative
            # and absolute manifest paths.
            headers.append(str(header_path))
            input_paths.add(header_path)

        compiler = require_string(profile.get("compiler"), f"{label}.compiler")
        freebasic_condition = profile.get("freebasic_condition")
        if freebasic_condition is not None:
            freebasic_condition = require_string(
                freebasic_condition, f"{label}.freebasic_condition"
            )
            condition_is_single_line = "\n" not in freebasic_condition and \
                "\r" not in freebasic_condition
            if not condition_is_single_line or \
               not FREEBASIC_CONDITION.fullmatch(freebasic_condition):
                raise ValueError(
                    f"{label}.freebasic_condition must be a single-line "
                    "FreeBASIC preprocessor condition"
                )
        c2fb_options = string_list(
            profile.get("c2fb_options", []), f"{label}.c2fb_options"
        )
        compiler_options = string_list(
            profile.get("compiler_options", []), f"{label}.compiler_options"
        )
        parsed_profiles.append(
            {
                "name": name,
                "headers": headers,
                "compiler": compiler,
                "freebasic_condition": freebasic_condition,
                "c2fb_options": c2fb_options,
                "compiler_options": compiler_options,
            }
        )

    conditions = [profile["freebasic_condition"] for profile in parsed_profiles]
    if combined_bindings:
        if combined_binding is not None:
            raise ValueError("combined_binding cannot be combined with fbfrog -emit groups")
        profiles_by_name = {
            profile["name"]: profile for profile in parsed_profiles
        }
        for binding in combined_bindings:
            group_profiles = [
                profiles_by_name[name] for name in binding["profiles"]
            ]
            group_conditions = [
                profile["freebasic_condition"] for profile in group_profiles
            ]
            if any(condition is None for condition in group_conditions):
                raise ValueError(
                    f"fbfrog -emit selector {binding['name']} requires a target or version condition"
                )
            normalized_group_conditions = [
                " ".join(condition.split()).casefold()
                for condition in group_conditions
            ]
            if len(normalized_group_conditions) != len(set(normalized_group_conditions)):
                raise ValueError(
                    f"fbfrog -emit selector {binding['name']} has duplicate conditions"
                )
    else:
        if combined_binding is None and any(condition is not None for condition in conditions):
            raise ValueError("freebasic_condition requires combined_binding")
        if combined_binding is not None and any(condition is None for condition in conditions):
            raise ValueError(
                "combined_binding requires freebasic_condition on every profile"
            )
        normalized_conditions = [
            " ".join(condition.split()).casefold()
            for condition in conditions
            if condition is not None
        ]
        if len(normalized_conditions) != len(set(normalized_conditions)):
            raise ValueError("combined_binding profiles must use distinct conditions")
    profile_paths = {
        profile_output_paths.get(
            profile["name"], output_directory / f"{profile['name']}.bi"
        ).resolve()
        for profile in parsed_profiles
    }
    if combined_binding is not None and \
       (output_directory / combined_binding).resolve() in profile_paths:
        raise ValueError("combined_binding must not replace a profile binding")
    binding_paths = [
        Path(binding.get("path", output_directory / binding["name"])).resolve()
        for binding in combined_bindings
    ]
    if any(path in profile_paths for path in binding_paths):
        raise ValueError("fbfrog -emit destination conflicts with a profile output")
    if len(binding_paths) != len(set(binding_paths)):
        raise ValueError("duplicate fbfrog -emit destination")

    return {
        "base_directory": base_directory,
        "input_paths": input_paths,
        "output_directory": output_directory,
        "combined_binding": combined_binding,
        "combined_bindings": combined_bindings,
        "profile_output_paths": profile_output_paths,
        "converter": converter,
        "common_c2fb_options": common_c2fb_options,
        "common_compiler_options": common_compiler_options,
        "max_profiles": profile_limit,
        "profiles": parsed_profiles,
    }


def combined_binding_source(binding_name, profiles):
    lines = [
        "/'",
        "    Project: C2FB API variant binding",
        f"    File: {binding_name}",
        "",
        "    Purpose:",
        "",
        "        Select the generated API binding for the active FreeBASIC configuration.",
        "",
        "    Responsibilities:",
        "",
        "        - Include the first profile whose FreeBASIC condition is true.",
        "        - Fail compilation when no profile matches.",
        "",
        "    This file intentionally does NOT contain:",
        "",
        "        - C declarations or ABI layouts; each profile file owns one variant.",
        "'/",
        "",
    ]
    for index, profile in enumerate(profiles):
        directive = "#if" if index == 0 else "#elseif"
        lines.append(f"{directive} {profile['freebasic_condition']}")
        lines.append(f'#include once "{profile["name"]}.bi"')
    lines.extend(
        [
            "#else",
            "#error No C2FB profile matches this FreeBASIC configuration.",
            "#endif",
            "",
            f"' end of {binding_name}",
            "",
        ]
    )
    return "\n".join(lines)


def run_matrix(config):
    output_directory = config["output_directory"]
    final_outputs = {}
    input_resolved = {path.resolve() for path in config["input_paths"]}
    profile_output_paths = config.get("profile_output_paths", {})
    for profile in config["profiles"]:
        output_path = profile_output_paths.get(
            profile["name"], output_directory / f"{profile['name']}.bi"
        )
        output_path = output_path.absolute()
        try:
            resolved_output_path = output_path.resolve()
        except (OSError, RuntimeError) as error:
            print(
                f"c2fb target matrix: cannot resolve output {output_path}: {error}",
                file=sys.stderr,
            )
            return 2
        if resolved_output_path in input_resolved:
            print(
                f"c2fb target matrix: output would overwrite input header: {output_path}",
                file=sys.stderr,
            )
            return 2
        if output_path.exists() and output_path.is_dir():
            print(
                f"c2fb target matrix: output path is a directory: {output_path}",
                file=sys.stderr,
            )
            return 2
        final_outputs[profile["name"]] = output_path

    selector_specs = []
    if config["combined_binding"] is not None:
        selector_specs.append({
            "name": config["combined_binding"],
            "profiles": config["profiles"],
        })
    profiles_by_name = {
        profile["name"]: profile for profile in config["profiles"]
    }
    for binding in config.get("combined_bindings", []):
        selector_specs.append({
            "name": binding["name"],
            "profiles": [
                profiles_by_name[name] for name in binding["profiles"]
            ],
            "output_directory": binding.get("output_directory", output_directory),
            "path": binding.get("path"),
        })

    selector_outputs = []
    seen_selector_paths = set()
    for selector in selector_specs:
        selector_directory = selector.get("output_directory", output_directory)
        selector_path = selector.get("path")
        if selector_path is None:
            selector_path = selector_directory / selector["name"]
        selector_path = Path(selector_path).absolute()
        try:
            resolved_selector_path = selector_path.resolve()
        except (OSError, RuntimeError) as error:
            print(
                f"c2fb target matrix: cannot resolve selector "
                f"{selector_path}: {error}",
                file=sys.stderr,
            )
            return 2
        if resolved_selector_path in seen_selector_paths:
            print(
                f"c2fb target matrix: duplicate selector output: {selector_path}",
                file=sys.stderr,
            )
            return 2
        seen_selector_paths.add(resolved_selector_path)
        if resolved_selector_path in input_resolved:
            print(
                f"c2fb target matrix: selector would overwrite input header: "
                f"{selector_path}",
                file=sys.stderr,
            )
            return 2
        if any(
            resolved_selector_path == output_path.resolve()
            for output_path in final_outputs.values()
        ):
            print(
                f"c2fb target matrix: selector conflicts with a profile output: "
                f"{selector_path}",
                file=sys.stderr,
            )
            return 2
        if selector_path.exists() and selector_path.is_dir():
            print(
                f"c2fb target matrix: selector output is a directory: "
                f"{selector_path}",
                file=sys.stderr,
            )
            return 2
        selector_outputs.append((selector_path, selector["profiles"]))

    try:
        output_directories = {path.parent for path in final_outputs.values()}
        output_directories.update(path.parent for path, _ in selector_outputs)
        with ExitStack() as temporary_directories:
            staged_directories = {}
            for directory in sorted(output_directories, key=str):
                directory.mkdir(parents=True, exist_ok=True)
                temporary_path = temporary_directories.enter_context(
                    tempfile.TemporaryDirectory(
                        prefix=".c2fb-target-matrix-", dir=directory
                    )
                )
                staged_directories[directory.resolve()] = Path(temporary_path)
            staged_outputs = []
            for profile_index, profile in enumerate(config["profiles"]):
                name = profile["name"]
                final_path = final_outputs[name]
                staged_path = staged_directories[final_path.parent.resolve()] / (
                    f"profile-{profile_index}-{final_path.name}"
                )
                command = [
                    config["converter"],
                    "generic-header",
                    str(profile["headers"][0]),
                    str(staged_path),
                    *config["common_c2fb_options"],
                    *profile["c2fb_options"],
                    profile["compiler"],
                    *config["common_compiler_options"],
                    *profile["compiler_options"],
                ]
                for header_path in profile["headers"][1:]:
                    command.append(f"--c-include={header_path}")
                print(
                    f"c2fb target matrix: generating {name} -> {final_path}",
                    flush=True,
                )
                with tempfile.TemporaryFile(
                    mode="w+t", encoding="utf-8", errors="replace"
                ) as log_file:
                    try:
                        result = subprocess.run(
                            command,
                            cwd=config["base_directory"],
                            stdout=log_file,
                            stderr=log_file,
                            check=False,
                        )
                    except OSError as error:
                        print(
                            f"c2fb target matrix: could not start C2FB for {name}: {error}",
                            file=sys.stderr,
                        )
                        return 127
                    log_file.seek(0)
                    for line in log_file:
                        sys.stdout.write(line.replace(str(staged_path), str(final_path)))
                    sys.stdout.flush()
                if result.returncode != 0:
                    print(
                        f"c2fb target matrix: profile {name} failed with status "
                        f"{result.returncode}; no staged bindings were published",
                        file=sys.stderr,
                    )
                    return 1
                if not staged_path.is_file() or staged_path.stat().st_size == 0:
                    print(
                        f"c2fb target matrix: C2FB produced no binding for {name}",
                        file=sys.stderr,
                    )
                    return 1
                staged_outputs.append((staged_path, final_path))

            for selector_index, (selector_path, selector_profiles) in enumerate(
                selector_outputs
            ):
                staged_combined_path = staged_directories[
                    selector_path.parent.resolve()
                ] / f"selector-{selector_index}-{selector_path.name}"
                staged_combined_path.write_text(
                    combined_binding_source(
                        selector_path.name, selector_profiles
                    ),
                    encoding="utf-8",
                )
                staged_outputs.append((staged_combined_path, selector_path))

            for staged_path, final_path in staged_outputs:
                os.replace(staged_path, final_path)
    except OSError as error:
        print(f"c2fb target matrix: output error: {error}", file=sys.stderr)
        return 1

    if not selector_outputs:
        print(
            f"c2fb target matrix: published {len(final_outputs)} bindings in "
            f"{output_directory}"
        )
    elif len(selector_outputs) == 1:
        print(
            f"c2fb target matrix: published {len(final_outputs)} profile bindings "
            f"and selector {selector_outputs[0][0]}"
        )
    else:
        print(
            f"c2fb target matrix: published {len(final_outputs)} profile bindings "
            f"and {len(selector_outputs)} selectors"
        )
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    arguments = parser.parse_args()
    manifest_path = arguments.manifest.resolve()
    try:
        config = read_matrix_config(manifest_path)
    except ValueError as error:
        parser.error(str(error))
    return run_matrix(config)


if __name__ == "__main__":
    raise SystemExit(main())

# end of c2fb_target_matrix.py
