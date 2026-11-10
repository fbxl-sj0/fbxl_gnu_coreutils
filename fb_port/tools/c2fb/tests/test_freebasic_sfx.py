#!/usr/bin/env python3
"""
Project: SQLite FreeBASIC port tools
File: test_freebasic_sfx.py
Purpose: Validate the SFX portion of the FreeBASIC source-port workflow.
Responsibilities: Compile Basic modules, run focused behavior tests, check the
runtime-prefix ABI, and translate/compile the root SFX C source candidates.
This file intentionally does NOT contain: Full RTLIB/GFXLIB or SQLite tests.
"""

import argparse
import importlib.util
import os
import platform
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT_SFX_SUMMARY = re.compile(
    r"translated (\d+) simple functions; skipped (\d+) "
    r"unsupported or duplicate candidates"
)
SFX_CONTEXT_FIELDS = (
    "current_channel",
    "channel_context_active",
    "master_volume",
    "balance",
    "octave",
    "tempo",
)


def run(command, **options):
    result = subprocess.run(
        command, capture_output=True, text=True, **options
    )
    if result.returncode:
        raise RuntimeError(
            f"Command failed: {shlex.join(map(str, command))}\n"
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


def check_context_prefix(fbc, cc, source_root, work):
    sfx_directory = source_root / "sfxlib"
    c_source = work / "sfx_context_prefix_layout.c"
    c_format = " ".join("%zu" for _ in range(len(SFX_CONTEXT_FIELDS) + 1))
    c_source.write_text(
        "#include <stddef.h>\n"
        "#include <stdio.h>\n"
        '#include "fb_sfx.h"\n'
        "int main(void) {\n"
        f'    printf("{c_format}", sizeof(FB_SFXCTX), '
        + ", ".join(
            f"offsetof(FB_SFXCTX, {field})" for field in SFX_CONTEXT_FIELDS
        )
        + ");\n"
        "    return 0;\n"
        "}\n"
    )
    c_executable = work / "sfx_context_prefix_layout_c"
    run(cc + [
        "-std=c99", f"-I{sfx_directory}", str(c_source),
        "-o", str(c_executable),
    ])

    basic_source = work / "sfx_context_prefix_layout.bas"
    basic_expressions = [
        f"CULngInt(@context.{field})-CULngInt(@context)"
        for field in SFX_CONTEXT_FIELDS
    ]
    basic_source.write_text(
        '#include once "fb_sfx_c_prefix.bi"\n'
        "Dim context As SfxRuntimeContextPrefix\n"
        + 'Print '
        + '; " "; '.join(basic_expressions)
        + "\n"
    )
    basic_executable = work / "sfx_context_prefix_layout_bas"
    run(fbc + [
        "-w", "all", "-i", str(sfx_directory),
        str(basic_source), "-x", str(basic_executable),
    ], cwd=work)

    c_values = run([str(c_executable)]).split()
    basic_values = run([str(basic_executable)]).split()
    # The first C value is sizeof(FB_SFXCTX); the remaining values are the
    # field offsets shared with SfxRuntimeContextPrefix.
    if c_values[1:] != basic_values:
        raise AssertionError(
            "SFX context prefix layout differs: "
            f"C={c_values[1:]}, FreeBASIC={basic_values}"
        )
    print(
        "SFX context field offsets match: "
        + ", ".join(
            f"{field}={offset}"
            for field, offset in zip(SFX_CONTEXT_FIELDS, basic_values)
        )
    )


def check_sfx_source_graph(source_root):
    sfx_directory = source_root / "sfxlib"
    make_output = run([
        "make", "-s", "-C", str(source_root.parent), "-pn",
    ])
    variables = {}
    for line in make_output.splitlines():
        match = re.match(r"^(SFX_SRC(?:_FB|_C)?) := (.*)$", line)
        if match is not None:
            variables[match.group(1)] = match.group(2).split()

    basic_sources = {
        str(Path(source).resolve())
        for source in variables.get("SFX_SRC_FB", ())
    }
    selected = set(variables.get("SFX_SRC", ()))
    root_basic_sources = {
        str(source.resolve()) for source in sfx_directory.glob("*.bas")
    }
    if not root_basic_sources <= basic_sources:
        raise AssertionError("SFX Make graph omitted a root Basic module")
    if not basic_sources <= selected:
        raise AssertionError("selected SFX sources omitted a Basic module")

    basic_stems = {Path(source).stem for source in basic_sources}
    selected_c_sources = {
        str(Path(source).resolve())
        for source in variables.get("SFX_SRC_C", ())
    }
    c_conflicts = {
        source for source in selected_c_sources
        if Path(source).stem in basic_stems
    }
    if c_conflicts:
        raise AssertionError("SFX Make graph retained a replaced C peer")
    c_peers = set()
    for source in map(Path, basic_sources):
        peer_stems = (source.with_suffix(".c"), source.with_suffix(".cpp"))
        root_stems = (
            sfx_directory / source.with_suffix(".c").name,
            sfx_directory / source.with_suffix(".cpp").name,
        )
        c_peers.update(path for path in (*peer_stems, *root_stems) if path.is_file())
    replaced_c_peers = {
        str(source.resolve()) for source in c_peers
    } - selected_c_sources
    c2fb_sources = {
        source for source in basic_sources
        if "C2FB translated" in Path(source).read_text(errors="replace")
        or "translated with C2FB" in Path(source).read_text(errors="replace")
    }
    debug_source = str((sfx_directory / "sfx_debug.bas").resolve())
    midi_pause_source = str((sfx_directory / "sfx_midi_pause.bas").resolve())
    music_status_source = str(
        (sfx_directory / "sfx_music_status.bas").resolve()
    )
    music_pause_source = str(
        (sfx_directory / "sfx_music_pause.bas").resolve()
    )
    music_resume_source = str(
        (sfx_directory / "sfx_music_resume.bas").resolve()
    )
    music_stop_source = str(
        (sfx_directory / "sfx_music_stop.bas").resolve()
    )
    music_play_source = str(
        (sfx_directory / "sfx_music_play.bas").resolve()
    )
    music_load_source = str(
        (sfx_directory / "sfx_music_load.bas").resolve()
    )
    sfx_load_source = str(
        (sfx_directory / "sfx_sfx_load.bas").resolve()
    )
    if any(source not in c2fb_sources for source in (
        debug_source, midi_pause_source, music_status_source,
        music_pause_source, music_resume_source, music_stop_source,
        music_play_source, music_load_source, sfx_load_source,
    )):
        raise AssertionError("SFX Make graph omitted a C2FB shared-state port")

    mixer_basic = str(
        (sfx_directory / "linux" / "x86_64" / "sfx_mixer.bas").resolve()
    )
    if mixer_basic not in basic_sources or mixer_basic not in c2fb_sources:
        raise AssertionError(
            "Linux x86-64 SFX graph omitted its C2FB mixer implementation"
        )

    arm_output = run([
        "make", "-s", "-C", str(source_root.parent), "-pn",
        "TARGET_OS=linux", "TARGET_ARCH=arm", "ARM_VER=v7",
    ])
    arm_variables = {}
    for line in arm_output.splitlines():
        match = re.match(r"^(SFX_SRC(?:_FB|_C)?) := (.*)$", line)
        if match is not None:
            arm_variables[match.group(1)] = match.group(2).split()
    arm_selected = set(arm_variables.get("SFX_SRC", ()))
    arm_basic = set(arm_variables.get("SFX_SRC_FB", ()))
    arm_c = set(arm_variables.get("SFX_SRC_C", ()))
    generic_mixer_c = str((sfx_directory / "sfx_mixer.c").resolve())
    if generic_mixer_c not in arm_selected or generic_mixer_c not in arm_c:
        raise AssertionError("ARM SFX graph did not retain the generic C mixer")
    if mixer_basic in arm_selected or mixer_basic in arm_basic:
        raise AssertionError("ARM SFX graph selected the x86-64 mixer module")

    print(
        f"SFX source graph: {len(basic_sources)} Basic modules selected; "
        f"{len(c2fb_sources)} are C2FB-translated; "
        f"{len(replaced_c_peers)} present C peers replaced; "
        "target/architecture mixer fallback checked"
    )
    return sorted((Path(source) for source in basic_sources), key=lambda p: p.as_posix())


def check_sfx_debug_behavior(fbc, cc, source_root, basic_object,
                             candidate_object, work):
    sfx_directory = source_root / "sfxlib"
    probe_source = work / "sfx_debug_probe.c"
    probe_source.write_text(
        "#include <stdio.h>\n"
        "int fb_sfxDebugEnabled(void);\n"
        "void fb_sfxDebugLog(const char *format, ...);\n"
        "int main(void) {\n"
        '    printf("%d\\n", fb_sfxDebugEnabled());\n'
        '    fb_sfxDebugLog("value=%d", 17);\n'
        "    return 0;\n"
        "}\n"
    )
    reference_executable = work / "sfx_debug_c_reference"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}",
        str(sfx_directory / "sfx_debug.c"), str(probe_source),
        "-o", str(reference_executable),
    ], cwd=work)

    probe_object = work / "sfx_debug_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        "-c", str(probe_source), "-o", str(probe_object),
    ], cwd=work)

    basic_include_directory = source_root.parent / "inc"
    executables = {"C reference": reference_executable}
    for implementation, object_path in (
        ("integrated Basic", basic_object),
        ("C2FB candidate", candidate_object),
    ):
        executable = work / (
            "sfx_debug_" + implementation.lower().replace(" ", "_")
        )
        run(fbc + [
            "-mt", "-w", "all", "-i", str(basic_include_directory),
            str(object_path), str(probe_object), "-x", str(executable),
        ], cwd=work)
        executables[implementation] = executable

    environment_cases = (
        ("unset", None),
        ("empty", ""),
        ("disabled", "0"),
        ("enabled", "1"),
        ("enabled text", "yes"),
    )
    for case_name, setting in environment_cases:
        observed = {}
        for implementation, executable in executables.items():
            environment = os.environ.copy()
            environment.pop("SFXLIB_DEBUG", None)
            if setting is not None:
                environment["SFXLIB_DEBUG"] = setting
            result = subprocess.run(
                [str(executable)], capture_output=True, text=True,
                env=environment, cwd=work,
            )
            observed[implementation] = (
                result.returncode, result.stdout, result.stderr
            )
        expected_enabled = (
            setting is not None and setting != "" and setting[0] != "0"
        )
        expected = (
            0,
            "1\n" if expected_enabled else "0\n",
            "SFX: value=17\n" if expected_enabled else "",
        )
        if any(result != expected for result in observed.values()):
            raise AssertionError(
                f"SFX debug {case_name} behavior differs: "
                f"expected={expected}, observed={observed}"
            )
    print(
        "SFX debug: C2FB candidate and integrated Basic module match C for "
        "disabled/enabled environment values and variadic formatting"
    )


def check_sfx_midi_pause_behavior(fbc, cc, source_root, basic_object,
                                  candidate_object, work):
    sfx_directory = source_root / "sfxlib"
    rtlib_directory = source_root / "rtlib"
    probe_source = work / "sfx_midi_pause_probe.c"
    probe_source.write_text(
        '#include "fb_sfx_internal.h"\n'
        "#include <stdio.h>\n"
        "#include <stdlib.h>\n"
        "int g_midi_playing;\n"
        "static int lock_depth;\n"
        "static int lock_calls;\n"
        "static int unlock_calls;\n"
        "static int output_pause_calls;\n"
        "static int last_output_pause;\n"
        "void fb_sfxRuntimeLock(void) { ++lock_depth; ++lock_calls; }\n"
        "void fb_sfxRuntimeUnlock(void) { --lock_depth; ++unlock_calls; }\n"
        "void fb_sfxMidiOutputPause(int paused) {\n"
        "    ++output_pause_calls;\n"
        "    last_output_pause = paused;\n"
        "}\n"
        "int main(int argc, char **argv) {\n"
        "    int paused_after_pause;\n"
        "    int output_calls_after_pause;\n"
        "    int last_output_after_pause;\n"
        "    if (argc != 3) return 90;\n"
        "    g_midi_playing = atoi(argv[1]);\n"
        "    g_midi_paused = atoi(argv[2]);\n"
        "    last_output_pause = -1;\n"
        "    if (fb_sfxMidiPause() != 0) return 91;\n"
        "    paused_after_pause = fb_sfxMidiPaused();\n"
        "    output_calls_after_pause = output_pause_calls;\n"
        "    last_output_after_pause = last_output_pause;\n"
        "    fb_sfxMidiPauseReset();\n"
        '    printf("%d %d %d %d %d %d %d %d\\n", '
        "           paused_after_pause, output_calls_after_pause, "
        "last_output_after_pause, g_midi_paused, output_pause_calls, "
        "last_output_pause, lock_calls, unlock_calls);\n"
        "    return lock_depth == 0 ? 0 : 92;\n"
        "}\n"
    )
    reference_executable = work / "sfx_midi_pause_c_reference"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        "-include", "sys/types.h",
        f"-I{rtlib_directory}", f"-I{sfx_directory}",
        str(sfx_directory / "sfx_midi_pause.c"), str(probe_source),
        "-o", str(reference_executable),
    ], cwd=work)

    probe_object = work / "sfx_midi_pause_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        "-include", "sys/types.h", f"-I{rtlib_directory}",
        f"-I{sfx_directory}", "-c", str(probe_source), "-o", str(probe_object),
    ], cwd=work)

    include_directory = source_root.parent / "inc"
    executables = {"C reference": reference_executable}
    for implementation, object_path in (
        ("integrated Basic", basic_object),
        ("C2FB candidate", candidate_object),
    ):
        executable = work / (
            "sfx_midi_pause_" + implementation.lower().replace(" ", "_")
        )
        run(fbc + [
            "-mt", "-w", "all", "-i", str(include_directory),
            str(object_path), str(probe_object), "-x", str(executable),
        ], cwd=work)
        executables[implementation] = executable

    scenarios = (
        ("stopped", 0, 0, "0 0 -1 0 1 0 3 3\n"),
        ("active", 1, 0, "1 1 1 0 2 0 3 3\n"),
        ("already paused", 1, 1, "1 0 -1 0 1 0 3 3\n"),
        ("stopped with pause bit", 0, 1, "1 0 -1 0 1 0 3 3\n"),
    )
    for scenario, playing, paused, expected_output in scenarios:
        for implementation, executable in executables.items():
            result = subprocess.run(
                [str(executable), str(playing), str(paused)],
                capture_output=True, text=True, cwd=work,
            )
            observed = (result.returncode, result.stdout, result.stderr)
            expected = (0, expected_output, "")
            if observed != expected:
                raise AssertionError(
                    f"SFX MIDI pause {scenario} differs for {implementation}: "
                    f"expected={expected}, observed={observed}"
                )
    print(
        "SFX MIDI pause: C2FB candidate and integrated Basic module match C "
        "for stopped, active, already-paused, and reset states"
    )


def check_sfx_music_status_prefix(fbc, cc, source_root, work):
    sfx_directory = source_root / "sfxlib"
    c_source = work / "sfx_music_status_prefix_layout.c"
    c_source.write_text(
        "#include <stddef.h>\n"
        "#include <stdio.h>\n"
        '#include "fb_sfx.h"\n'
        "int main(void) {\n"
        '    printf("%zu %zu %zu %zu %zu\\n", '
        "offsetof(FB_SFXCTX, voices), "
        "offsetof(FB_SFXVOICE, type), sizeof(FB_SFXVOICE), "
        "offsetof(FB_SFXCTX, music_playing), "
        "offsetof(FB_SFXCTX, music_pos));\n"
        "    return 0;\n"
        "}\n"
    )
    c_executable = work / "sfx_music_status_prefix_layout_c"
    run(cc + [
        "-std=c99", f"-I{sfx_directory}", str(c_source),
        "-o", str(c_executable),
    ])

    basic_source = work / "sfx_music_status_prefix_layout.bas"
    basic_source.write_text(
        '#include once "fb_sfx_c_prefix.bi"\n'
        "Dim context As SfxMusicContextPrefix\n"
        'Print CULngInt(@context.voices(0))-CULngInt(@context); " "; _\n'
        '      CULngInt(@context.voices(0).voice_type)-_\n'
        '      CULngInt(@context.voices(0)); " "; _\n'
        '      CULngInt(@context.voices(1))-CULngInt(@context.voices(0)); " "; _\n'
        '      CULngInt(@context.music_playing)-CULngInt(@context); " "; _\n'
        '      CULngInt(@context.music_pos)-CULngInt(@context)\n'
    )
    basic_executable = work / "sfx_music_status_prefix_layout_bas"
    run(fbc + [
        "-w", "all", "-i", str(sfx_directory),
        str(basic_source), "-x", str(basic_executable),
    ], cwd=work)

    c_layout = run([str(c_executable)]).split()
    basic_layout = run([str(basic_executable)]).split()
    if c_layout != basic_layout:
        raise AssertionError(
            "SFX music-status context layout differs: "
            f"C={c_layout}, FreeBASIC={basic_layout}"
        )
    print(
        "SFX music-status prefix matches C for voice offset, voice type, "
        "voice stride, music_playing, and music_pos"
    )

    cross_target_source = work / "sfx_music_status_linux_x86.c"
    run(fbc + [
        "-target", "linux-x86", "-arch", "386", "-gen", "gcc",
        "-r", "-c", str(sfx_directory / "sfx_music_status.bas"),
        "-o", str(cross_target_source),
        "-i", str(source_root.parent / "inc"),
        "-i", str(sfx_directory),
    ], cwd=work)
    generated_c = cross_target_source.read_text()
    voice_match = re.search(
        r"struct (fb_type_[A-Za-z0-9_]+)\s*\{\s*int32 ACTIVE;",
        generated_c,
    )
    context_match = re.search(
        r"struct (fb_type_[A-Za-z0-9_]+)\s*\{\s*int32 INITIALIZED;",
        generated_c,
    )
    if voice_match is None or context_match is None:
        raise AssertionError("cannot identify the i386 music-status C layouts")
    voice_type = voice_match.group(1)
    context_type = context_match.group(1)
    cross_layout_source = work / "sfx_music_status_linux_x86_layout.c"
    cross_layout_source.write_text(
        f'#define __fb_sfx c2fb_layout_sfx\n'
        f'#define fb_sfxMusicStatus c2fb_layout_status\n'
        f'#define fb_sfxMusicPosition c2fb_layout_position\n'
        f'#include "{cross_target_source}"\n'
        "#undef __fb_sfx\n"
        "#undef fb_sfxMusicStatus\n"
        "#undef fb_sfxMusicPosition\n"
        f'#include "{sfx_directory / "fb_sfx.h"}"\n'
        f'_Static_assert(sizeof(struct {voice_type}) == '
        'sizeof(FB_SFXVOICE), "i386 voice stride mismatch");\n'
        f'_Static_assert(__builtin_offsetof(struct {context_type}, VOICES) == '
        '__builtin_offsetof(FB_SFXCTX, voices), '
        '"i386 voice array offset mismatch");\n'
        f'_Static_assert(__builtin_offsetof(struct {context_type}, MUSIC_PLAYING) == '
        '__builtin_offsetof(FB_SFXCTX, music_playing), '
        '"i386 music state offset mismatch");\n'
        f'_Static_assert(__builtin_offsetof(struct {context_type}, MUSIC_POS) == '
        '__builtin_offsetof(FB_SFXCTX, music_pos), '
        '"i386 music position offset mismatch");\n'
    )
    run(cc + [
        "-m32", "-std=gnu11", "-fsyntax-only", f"-I{sfx_directory}",
        str(cross_layout_source),
    ], cwd=work)
    print("SFX music-status prefix also matches the i386 C ABI")


def check_sfx_music_status_behavior(fbc, cc, source_root, basic_object,
                                   candidate_object, work):
    sfx_directory = source_root / "sfxlib"
    probe_source = work / "sfx_music_status_probe.c"
    probe_source.write_text(
        "#include <stdio.h>\n"
        "#include <string.h>\n"
        '#include "fb_sfx_internal.h"\n'
        "#ifndef SFX_STATUS_FUNCTION\n"
        "#define SFX_STATUS_FUNCTION fb_sfxMusicStatus\n"
        "#endif\n"
        "#ifndef SFX_POSITION_FUNCTION\n"
        "#define SFX_POSITION_FUNCTION fb_sfxMusicPosition\n"
        "#endif\n"
        "extern int SFX_STATUS_FUNCTION(void);\n"
        "extern long SFX_POSITION_FUNCTION(void);\n"
        "FB_SFXCTX *__fb_sfx;\n"
        "static int lock_count;\n"
        "static int unlock_count;\n"
        "void fb_sfxRuntimeLock(void) { ++lock_count; }\n"
        "void fb_sfxRuntimeUnlock(void) { ++unlock_count; }\n"
        "static void run_case(const char *name, int has_context, int playing,\n"
        "                     int paused, int looping, int position,\n"
        "                     int other_voice, int music_voice) {\n"
        "    FB_SFXCTX context;\n"
        "    int status;\n"
        "    long music_position;\n"
        "    memset(&context, 0, sizeof(context));\n"
        "    context.music_playing = playing;\n"
        "    context.music_paused = paused;\n"
        "    context.music_loop = looping;\n"
        "    context.music_pos = position;\n"
        "    if (other_voice >= 0) {\n"
        "        context.voices[other_voice].active = 1;\n"
        "        context.voices[other_voice].type = FB_SFX_VOICE_SFX;\n"
        "    }\n"
        "    if (music_voice >= 0) {\n"
        "        context.voices[music_voice].active = 1;\n"
        "        context.voices[music_voice].type = FB_SFX_VOICE_MUSIC;\n"
        "    }\n"
        "    __fb_sfx = has_context ? &context : NULL;\n"
        "    lock_count = 0;\n"
        "    unlock_count = 0;\n"
        "    status = SFX_STATUS_FUNCTION();\n"
        "    music_position = SFX_POSITION_FUNCTION();\n"
        '    printf("%s|%d|%ld|%d|%d|%d|%d|%ld\\n", name, status, '
        "           music_position, lock_count, unlock_count, "
        "           context.music_playing, context.music_paused, "
        "           (long)context.music_pos);\n"
        "}\n"
        "int main(void) {\n"
        '    run_case("no-context", 0, 0, 1, 1, 91, -1, -1);\n'
        '    run_case("stopped", 1, -1, 1, 1, 17, -1, -1);\n'
        '    run_case("playing", 1, 0, 0, 1, 44, -1, 4);\n'
        '    run_case("paused", 1, 0, 1, 0, 88, 0, 63);\n'
        '    run_case("stale", 1, 0, 1, 1, 123, -1, -1);\n'
        '    run_case("other-voice", 1, 1, 0, 1, 77, 2, -1);\n'
        '    run_case("later-music-voice", 1, 1, 0, 1, 55, 0, 63);\n'
        "    return 0;\n"
        "}\n"
    )

    reference_object = work / "sfx_music_status_reference.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}",
        "-Dfb_sfxMusicStatus=cReferenceMusicStatus",
        "-Dfb_sfxMusicPosition=cReferenceMusicPosition",
        "-c", str(sfx_directory / "sfx_music_status.c"),
        "-o", str(reference_object),
    ], cwd=work)

    c_reference_probe = work / "sfx_music_status_reference_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}",
        "-DSFX_STATUS_FUNCTION=cReferenceMusicStatus",
        "-DSFX_POSITION_FUNCTION=cReferenceMusicPosition",
        "-c", str(probe_source), "-o", str(c_reference_probe),
    ], cwd=work)
    reference_executable = work / "sfx_music_status_reference"
    run(cc + [
        str(reference_object), str(c_reference_probe),
        "-o", str(reference_executable),
    ], cwd=work)
    expected = run([str(reference_executable)], cwd=work)

    probe_object = work / "sfx_music_status_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", "-c", str(probe_source),
        "-o", str(probe_object),
    ], cwd=work)

    for implementation, object_path in (
        ("C2FB candidate", candidate_object),
        ("integrated Basic", basic_object),
    ):
        executable = work / (
            "sfx_music_status_" + implementation.lower().replace(" ", "_")
        )
        run(fbc + [
            "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
            str(object_path), str(probe_object), "-x", str(executable),
        ], cwd=work)
        observed = run([str(executable)], cwd=work)
        if observed != expected:
            raise AssertionError(
                f"SFX music status differs for {implementation}: "
                f"C={expected!r}, observed={observed!r}"
            )
    print(
        "SFX music status: C2FB candidate and integrated Basic match C for "
        "null, stopped, playing, paused, stale, and mixed-voice states"
    )


def check_sfx_music_controls_behavior(
    fbc, cc, source_root, basic_pause, basic_resume,
    candidate_pause, candidate_resume, work,
):
    sfx_directory = source_root / "sfxlib"
    probe_source = work / "sfx_music_controls_probe.c"
    probe_source.write_text(
        "#include <stdio.h>\n"
        "#include <string.h>\n"
        '#include "fb_sfx_internal.h"\n'
        "#ifndef SFX_MUSIC_PAUSE_FUNCTION\n"
        "#define SFX_MUSIC_PAUSE_FUNCTION fb_sfxMusicPause\n"
        "#endif\n"
        "#ifndef SFX_MUSIC_RESUME_FUNCTION\n"
        "#define SFX_MUSIC_RESUME_FUNCTION fb_sfxMusicResume\n"
        "#endif\n"
        "extern void SFX_MUSIC_PAUSE_FUNCTION(void);\n"
        "extern void SFX_MUSIC_RESUME_FUNCTION(void);\n"
        "FB_SFXCTX *__fb_sfx;\n"
        "int fb_sfx_music_control_ready;\n"
        "int fb_sfx_music_control_debug_enabled;\n"
        "static int lock_count;\n"
        "static int unlock_count;\n"
        "static int debug_count;\n"
        "static char debug_message[96];\n"
        "int fb_sfxEnsureInitialized(void) {\n"
        "    return fb_sfx_music_control_ready;\n"
        "}\n"
        "int fb_sfxDebugEnabled(void) {\n"
        "    return fb_sfx_music_control_debug_enabled;\n"
        "}\n"
        "void fb_sfxDebugLog(const char *format, ...) {\n"
        "    ++debug_count;\n"
        "    strncpy(debug_message, format, sizeof(debug_message) - 1);\n"
        "    debug_message[sizeof(debug_message) - 1] = '\\0';\n"
        "}\n"
        "void fb_sfxRuntimeLock(void) { ++lock_count; }\n"
        "void fb_sfxRuntimeUnlock(void) { ++unlock_count; }\n"
        "static void run_case(const char *name, int ready, int debug_enabled,\n"
        "                     int pause_operation, int playing, int paused,\n"
        "                     int music_voices, int other_voice,\n"
        "                     int other_paused) {\n"
        "    FB_SFXCTX context;\n"
        "    memset(&context, 0, sizeof(context));\n"
        "    context.music_playing = playing;\n"
        "    context.music_paused = paused;\n"
        "    context.music_loop = 1;\n"
        "    context.music_pos = 123;\n"
        "    if (music_voices & 1) {\n"
        "        context.voices[0].active = 1;\n"
        "        context.voices[0].type = FB_SFX_VOICE_MUSIC;\n"
        "        context.voices[0].paused = paused;\n"
        "    }\n"
        "    if (other_voice) {\n"
        "        context.voices[1].active = 1;\n"
        "        context.voices[1].type = FB_SFX_VOICE_SFX;\n"
        "        context.voices[1].paused = other_paused;\n"
        "    }\n"
        "    if (music_voices & 2) {\n"
        "        context.voices[2].active = 1;\n"
        "        context.voices[2].type = FB_SFX_VOICE_MUSIC;\n"
        "        context.voices[2].paused = paused;\n"
        "    }\n"
        "    __fb_sfx = &context;\n"
        "    fb_sfx_music_control_ready = ready;\n"
        "    fb_sfx_music_control_debug_enabled = debug_enabled;\n"
        "    lock_count = 0;\n"
        "    unlock_count = 0;\n"
        "    debug_count = 0;\n"
        "    debug_message[0] = '\\0';\n"
        "    if (pause_operation)\n"
        "        SFX_MUSIC_PAUSE_FUNCTION();\n"
        "    else\n"
        "        SFX_MUSIC_RESUME_FUNCTION();\n"
        '    printf("%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%s\\n", name, '
        "           lock_count, unlock_count, debug_count, "
        "           context.music_playing, context.music_paused, "
        "           context.music_loop, context.music_pos, "
        "           context.voices[0].paused, context.voices[1].paused, "
        "           context.voices[2].paused, debug_message);\n"
        "}\n"
        "int main(void) {\n"
        '    run_case("not-ready-pause", 0, 1, 1, 0, 0, 1, 1, 0);\n'
        '    run_case("not-ready-resume", 0, 1, 0, 0, 1, 1, 1, 1);\n'
        '    run_case("stopped-pause", 1, 1, 1, -1, 0, 1, 1, 0);\n'
        '    run_case("already-paused", 1, 1, 1, 0, 1, 1, 1, 1);\n'
        '    run_case("pause-active", 1, 1, 1, 0, 0, 3, 1, 0);\n'
        '    run_case("pause-no-voice", 1, 0, 1, 0, 0, 0, 0, 0);\n'
        '    run_case("resume-not-paused", 1, 1, 0, 0, 0, 3, 1, 0);\n'
        '    run_case("resume-active", 1, 1, 0, 0, 1, 3, 1, 1);\n'
        '    run_case("resume-no-voice", 1, 0, 0, 0, 1, 0, 0, 0);\n'
        "    return 0;\n"
        "}\n"
    )

    reference_objects = []
    for source_name, object_name in (
        ("sfx_music_pause.c", "sfx_music_pause_reference.o"),
        ("sfx_music_resume.c", "sfx_music_resume_reference.o"),
    ):
        object_path = work / object_name
        run(cc + [
            "-std=c99", "-Wall", "-Wextra", "-Werror",
            f"-I{sfx_directory}",
            "-Dfb_sfxMusicPause=cReferenceMusicPause",
            "-Dfb_sfxMusicResume=cReferenceMusicResume",
            "-c", str(sfx_directory / source_name), "-o", str(object_path),
        ], cwd=work)
        reference_objects.append(object_path)

    reference_probe = work / "sfx_music_controls_reference_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}",
        "-DSFX_MUSIC_PAUSE_FUNCTION=cReferenceMusicPause",
        "-DSFX_MUSIC_RESUME_FUNCTION=cReferenceMusicResume",
        "-c", str(probe_source), "-o", str(reference_probe),
    ], cwd=work)
    reference_executable = work / "sfx_music_controls_reference"
    run(cc + [
        *(str(path) for path in reference_objects), str(reference_probe),
        "-o", str(reference_executable),
    ], cwd=work)
    expected = run([str(reference_executable)], cwd=work)

    probe_object = work / "sfx_music_controls_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", "-c", str(probe_source),
        "-o", str(probe_object),
    ], cwd=work)

    for implementation, pause_object, resume_object in (
        ("C2FB candidate", candidate_pause, candidate_resume),
        ("integrated Basic", basic_pause, basic_resume),
    ):
        executable = work / (
            "sfx_music_controls_" + implementation.lower().replace(" ", "_")
        )
        run(fbc + [
            "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
            str(pause_object), str(resume_object), str(probe_object),
            "-x", str(executable),
        ], cwd=work)
        observed = run([str(executable)], cwd=work)
        if observed != expected:
            raise AssertionError(
                f"SFX music controls differ for {implementation}: "
                f"C={expected!r}, observed={observed!r}"
            )
    print(
        "SFX music pause/resume: C2FB candidates and integrated Basic match "
        "C for initialization, stopped, paused, active, and voice-less states"
    )


def check_sfx_music_stop_behavior(fbc, cc, source_root, basic_object,
                                  candidate_object, work):
    sfx_directory = source_root / "sfxlib"
    probe_source = work / "sfx_music_stop_probe.c"
    probe_source.write_text(
        "#include <stdio.h>\n"
        "#include <string.h>\n"
        '#include "fb_sfx_internal.h"\n'
        "#ifndef SFX_MUSIC_STOP_FUNCTION\n"
        "#define SFX_MUSIC_STOP_FUNCTION fb_sfxMusicStop\n"
        "#endif\n"
        "#ifndef SFX_MUSIC_STOP_LOCKED_FUNCTION\n"
        "#define SFX_MUSIC_STOP_LOCKED_FUNCTION fb_sfxMusicStopLocked\n"
        "#endif\n"
        "extern void SFX_MUSIC_STOP_FUNCTION(void);\n"
        "extern void SFX_MUSIC_STOP_LOCKED_FUNCTION(void);\n"
        "FB_SFXCTX *__fb_sfx;\n"
        "int fb_sfx_music_stop_ready;\n"
        "int fb_sfx_music_stop_debug_enabled;\n"
        "static int lock_count;\n"
        "static int unlock_count;\n"
        "static int debug_count;\n"
        "static char debug_message[96];\n"
        "static float sample_data[3];\n"
        "int fb_sfxEnsureInitialized(void) {\n"
        "    return fb_sfx_music_stop_ready;\n"
        "}\n"
        "int fb_sfxDebugEnabled(void) {\n"
        "    return fb_sfx_music_stop_debug_enabled;\n"
        "}\n"
        "void fb_sfxDebugLog(const char *format, ...) {\n"
        "    ++debug_count;\n"
        "    strncpy(debug_message, format, sizeof(debug_message) - 1);\n"
        "    debug_message[sizeof(debug_message) - 1] = '\\0';\n"
        "}\n"
        "void fb_sfxRuntimeLock(void) { ++lock_count; }\n"
        "void fb_sfxRuntimeUnlock(void) { ++unlock_count; }\n"
        "static void run_case(const char *name, int ready, int debug_enabled,\n"
        "                     int locked_call, int has_context, int playing,\n"
        "                     int paused, int looping, int position,\n"
        "                     int music_zero_active, int sfx_active,\n"
        "                     int music_two_active) {\n"
        "    FB_SFXCTX context;\n"
        "    memset(&context, 0, sizeof(context));\n"
        "    context.music_playing = playing;\n"
        "    context.music_paused = paused;\n"
        "    context.music_loop = looping;\n"
        "    context.music_pos = position;\n"
        "    context.voices[0].type = FB_SFX_VOICE_MUSIC;\n"
        "    context.voices[0].active = music_zero_active;\n"
        "    context.voices[0].data = &sample_data[0];\n"
        "    context.voices[1].type = FB_SFX_VOICE_SFX;\n"
        "    context.voices[1].active = sfx_active;\n"
        "    context.voices[1].data = &sample_data[1];\n"
        "    context.voices[2].type = FB_SFX_VOICE_MUSIC;\n"
        "    context.voices[2].active = music_two_active;\n"
        "    context.voices[2].data = &sample_data[2];\n"
        "    __fb_sfx = has_context ? &context : NULL;\n"
        "    fb_sfx_music_stop_ready = ready;\n"
        "    fb_sfx_music_stop_debug_enabled = debug_enabled;\n"
        "    lock_count = 0;\n"
        "    unlock_count = 0;\n"
        "    debug_count = 0;\n"
        "    debug_message[0] = '\\0';\n"
        "    if (locked_call) {\n"
        "        fb_sfxRuntimeLock();\n"
        "        SFX_MUSIC_STOP_LOCKED_FUNCTION();\n"
        "        fb_sfxRuntimeUnlock();\n"
        "    } else {\n"
        "        SFX_MUSIC_STOP_FUNCTION();\n"
        "    }\n"
        '    printf("%s|%d|%d|%d|%d|%d|%d|%ld|%d|%d|%d|%d|%d|%d|%s\\n", '
        "           name, lock_count, unlock_count, debug_count, "
        "           context.music_playing, context.music_paused, "
        "           context.music_loop, (long)context.music_pos, "
        "           context.voices[0].active, context.voices[0].data == NULL, "
        "           context.voices[1].active, context.voices[1].data != NULL, "
        "           context.voices[2].active, context.voices[2].data == NULL, "
        "           debug_message);\n"
        "}\n"
        "int main(void) {\n"
        '    run_case("not-ready", 0, 1, 0, 1, 0, 1, 1, 41, 1, 1, 0);\n'
        '    run_case("public-active", 1, 1, 0, 1, 0, 1, 1, 81, 1, 1, 0);\n'
        '    run_case("public-stopped", 1, 1, 0, 1, -1, 0, 0, 9, 1, 0, 0);\n'
        '    run_case("locked-active", 1, 0, 1, 1, 1, 1, 1, 77, 1, 1, 1);\n'
        '    run_case("locked-no-context", 1, 1, 1, 0, 0, 1, 1, 13, 1, 0, 0);\n'
        '    run_case("locked-inactive-voice", 1, 0, 1, 1, -1, 1, 1, 55, 0, 1, 0);\n'
        "    return 0;\n"
        "}\n"
    )

    reference_object = work / "sfx_music_stop_reference.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}",
        "-Dfb_sfxMusicStop=cReferenceMusicStop",
        "-Dfb_sfxMusicStopLocked=cReferenceMusicStopLocked",
        "-c", str(sfx_directory / "sfx_music_stop.c"),
        "-o", str(reference_object),
    ], cwd=work)

    reference_probe = work / "sfx_music_stop_reference_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}",
        "-DSFX_MUSIC_STOP_FUNCTION=cReferenceMusicStop",
        "-DSFX_MUSIC_STOP_LOCKED_FUNCTION=cReferenceMusicStopLocked",
        "-c", str(probe_source), "-o", str(reference_probe),
    ], cwd=work)
    reference_executable = work / "sfx_music_stop_reference"
    run(cc + [
        str(reference_object), str(reference_probe),
        "-o", str(reference_executable),
    ], cwd=work)
    expected = run([str(reference_executable)], cwd=work)

    probe_object = work / "sfx_music_stop_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", "-c", str(probe_source),
        "-o", str(probe_object),
    ], cwd=work)
    executable = work / "sfx_music_stop_basic"
    run(fbc + [
        "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
        str(basic_object), str(probe_object), "-x", str(executable),
    ], cwd=work)
    observed = run([str(executable)], cwd=work)
    if observed != expected:
        raise AssertionError(
            f"SFX music stop differs for integrated Basic: "
            f"C={expected!r}, observed={observed!r}"
        )

    candidate_executable = work / "sfx_music_stop_candidate"
    run(fbc + [
        "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
        str(candidate_object), str(probe_object), "-x", str(candidate_executable),
    ], cwd=work)
    candidate_output = run([str(candidate_executable)], cwd=work)
    if candidate_output != expected:
        raise AssertionError(
            f"SFX music stop differs for C2FB candidate: "
            f"C={expected!r}, observed={candidate_output!r}"
        )
    print(
        "SFX music stop: C2FB candidate and integrated Basic match C for "
        "readiness, stop state, voice clearing, lock, and debug cases"
    )


def check_sfx_music_play_behavior(
    fbc, cc, source_root, basic_play, basic_stop,
    candidate_play, work,
):
    sfx_directory = source_root / "sfxlib"
    probe_source = work / "sfx_music_play_probe.c"
    probe_source.write_text(
        "#include <stdio.h>\n"
        "#include <string.h>\n"
        '#include "fb_sfx_internal.h"\n'
        "#ifndef SFX_MUSIC_PLAY_FUNCTION\n"
        "#define SFX_MUSIC_PLAY_FUNCTION fb_sfxMusicPlay\n"
        "#endif\n"
        "#ifndef SFX_MUSIC_LOOP_FUNCTION\n"
        "#define SFX_MUSIC_LOOP_FUNCTION fb_sfxMusicLoop\n"
        "#endif\n"
        "#ifndef SFX_MUSIC_RESTART_FUNCTION\n"
        "#define SFX_MUSIC_RESTART_FUNCTION fb_sfxMusicRestart\n"
        "#endif\n"
        "extern int SFX_MUSIC_PLAY_FUNCTION(void);\n"
        "extern int SFX_MUSIC_LOOP_FUNCTION(void);\n"
        "extern void SFX_MUSIC_RESTART_FUNCTION(void);\n"
        "FB_SFXCTX *__fb_sfx;\n"
        "static int initialized;\n"
        "static int debug_enabled;\n"
        "static int allocation_failure;\n"
        "static int allocation_count;\n"
        "static int activation_count;\n"
        "static int lock_count;\n"
        "static int unlock_count;\n"
        "static int debug_count;\n"
        "static char debug_message[96];\n"
        "static float asset_samples[16];\n"
        "static float spare_samples[16];\n"
        "int fb_sfxEnsureInitialized(void) { return initialized; }\n"
        "int fb_sfxDebugEnabled(void) { return debug_enabled; }\n"
        "void fb_sfxDebugLog(const char *format, ...) {\n"
        "    ++debug_count;\n"
        "    strncpy(debug_message, format, sizeof(debug_message) - 1);\n"
        "    debug_message[sizeof(debug_message) - 1] = '\\0';\n"
        "}\n"
        "void fb_sfxRuntimeLock(void) { ++lock_count; }\n"
        "void fb_sfxRuntimeUnlock(void) { ++unlock_count; }\n"
        "FB_SFXVOICE *fb_sfxVoiceAllocLocked(void) {\n"
        "    int index;\n"
        "    ++allocation_count;\n"
        "    if (allocation_failure || !__fb_sfx) return NULL;\n"
        "    for (index = 0; index < FB_SFX_MAX_VOICES; ++index) {\n"
        "        FB_SFXVOICE *voice = &__fb_sfx->voices[index];\n"
        "        if (!voice->active) {\n"
        "            memset(voice, 0, sizeof(*voice));\n"
        "            return voice;\n"
        "        }\n"
        "    }\n"
        "    return NULL;\n"
        "}\n"
        "void fb_sfxVoiceActivateLocked(FB_SFXVOICE *voice) {\n"
        "    ++activation_count;\n"
        "    voice->active = 1;\n"
        "}\n"
        "static void run_case(const char *name, int operation, int is_ready,\n"
        "                     int show_debug, int asset_loaded,\n"
        "                     int source_rate, int output_rate,\n"
        "                     int fail_allocation, int playing, int paused,\n"
        "                     int looping, long music_position,\n"
        "                     int music_voice_index, int has_sfx_voice) {\n"
        "    FB_SFXCTX context;\n"
        "    int result = 0;\n"
        "    int voice_index;\n"
        "    memset(&context, 0, sizeof(context));\n"
        "    context.samplerate = output_rate;\n"
        "    context.music_playing = playing;\n"
        "    context.music_paused = paused;\n"
        "    context.music_loop = looping;\n"
        "    context.music_pos = (int)music_position;\n"
        "    context.music.data = asset_loaded ? asset_samples : NULL;\n"
        "    context.music.loaded = asset_loaded;\n"
        "    context.music.size = 16;\n"
        "    context.music.frames = 4;\n"
        "    context.music.sample_rate = source_rate;\n"
        "    if (music_voice_index >= 0) {\n"
        "        FB_SFXVOICE *voice = &context.voices[music_voice_index];\n"
        "        voice->active = 1;\n"
        "        voice->type = FB_SFX_VOICE_MUSIC;\n"
        "        voice->data = spare_samples;\n"
        "        voice->position = 12;\n"
        "        voice->pos = 13;\n"
        "        voice->sample_pos = 4.5f;\n"
        "        voice->sample_step = 0.25f;\n"
        "        voice->loop = 1;\n"
        "        voice->env_state = FB_SFX_ENV_SUSTAIN;\n"
        "        voice->env_level = 0.5f;\n"
        "    }\n"
        "    if (has_sfx_voice) {\n"
        "        context.voices[1].active = 1;\n"
        "        context.voices[1].type = FB_SFX_VOICE_SFX;\n"
        "        context.voices[1].data = spare_samples;\n"
        "    }\n"
        "    __fb_sfx = &context;\n"
        "    initialized = is_ready;\n"
        "    debug_enabled = show_debug;\n"
        "    allocation_failure = fail_allocation;\n"
        "    allocation_count = activation_count = 0;\n"
        "    lock_count = unlock_count = debug_count = 0;\n"
        "    debug_message[0] = '\\0';\n"
        "    if (operation == 0) result = SFX_MUSIC_PLAY_FUNCTION();\n"
        "    else if (operation == 1) result = SFX_MUSIC_LOOP_FUNCTION();\n"
        "    else SFX_MUSIC_RESTART_FUNCTION();\n"
        '    printf("case|%s|%d|%d|%d|%d|%d|%d\\n", name, result, '
        "           lock_count, unlock_count, allocation_count, "
        "           activation_count, debug_count);\n"
        '    printf("context|%d|%d|%d|%d\\n", context.music_playing, '
        "           context.music_paused, context.music_loop, context.music_pos);\n"
        '    for (voice_index = 0; voice_index < 3; ++voice_index) {\n'
        '        FB_SFXVOICE *voice = &context.voices[voice_index];\n'
        '        printf("voice|%d|%d|%d|%d|%d|%d|%.9g|%.9g|%d|%d|%.9g|%d\\n",\n'
        '               voice_index, voice->active, voice->type, voice->length,\n'
        '               voice->position, voice->pos, voice->sample_pos,\n'
        '               voice->sample_step, voice->loop, voice->env_state,\n'
        '               voice->env_level, voice->data == context.music.data);\n'
        '    }\n'
        '    printf("debug|%s\\n", debug_message);\n'
        "}\n"
        "int main(void) {\n"
        '    run_case("not-ready-play", 0, 0, 1, 1, 22050, 44100, 0, -1, 0, 0, 9, -1, 0);\n'
        '    run_case("missing-asset", 0, 1, 1, 0, 22050, 44100, 0, -1, 0, 0, 9, -1, 0);\n'
        '    run_case("allocation-failure", 0, 1, 1, 1, 22050, 44100, 1, 0, 1, 1, 77, 0, 1);\n'
        '    run_case("play-success", 0, 1, 1, 1, 22050, 44100, 0, -1, 0, 0, 9, -1, 1);\n'
        '    run_case("loop-success", 1, 1, 1, 1, 32000, 48000, 0, 0, 1, 0, 90, 0, 1);\n'
        '    run_case("restart-stopped", 2, 1, 1, 1, 22050, 44100, 0, -1, 0, 0, 33, 0, 1);\n'
        '    run_case("restart-no-voice", 2, 1, 1, 1, 22050, 44100, 0, 0, 1, 1, 65, -1, 1);\n'
        '    run_case("restart-active", 2, 1, 1, 1, 22050, 44100, 0, 0, 1, 1, 88, 2, 1);\n'
        "    return 0;\n"
        "}\n"
    )

    reference_objects = []
    for source_name, object_name in (
        ("sfx_music_play.c", "sfx_music_play_reference.o"),
        ("sfx_music_stop.c", "sfx_music_stop_reference.o"),
    ):
        object_path = work / object_name
        command = cc + [
            "-std=c99", "-Wall", "-Wextra", "-Werror",
            f"-I{sfx_directory}",
        ]
        if source_name == "sfx_music_play.c":
            command.extend((
                "-Dfb_sfxMusicPlay=cReferenceMusicPlay",
                "-Dfb_sfxMusicLoop=cReferenceMusicLoop",
                "-Dfb_sfxMusicRestart=cReferenceMusicRestart",
            ))
        command.extend((
            "-c", str(sfx_directory / source_name), "-o", str(object_path),
        ))
        run(command, cwd=work)
        reference_objects.append(object_path)

    reference_probe = work / "sfx_music_play_reference_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}",
        "-DSFX_MUSIC_PLAY_FUNCTION=cReferenceMusicPlay",
        "-DSFX_MUSIC_LOOP_FUNCTION=cReferenceMusicLoop",
        "-DSFX_MUSIC_RESTART_FUNCTION=cReferenceMusicRestart",
        "-c", str(probe_source), "-o", str(reference_probe),
    ], cwd=work)
    reference_executable = work / "sfx_music_play_reference"
    run(cc + [
        *(str(path) for path in reference_objects), str(reference_probe),
        "-o", str(reference_executable),
    ], cwd=work)
    expected = run([str(reference_executable)], cwd=work)

    probe_object = work / "sfx_music_play_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", "-c", str(probe_source), "-o", str(probe_object),
    ], cwd=work)
    for implementation, play_object, stop_object in (
        ("C2FB candidate", candidate_play, basic_stop),
        ("integrated Basic", basic_play, basic_stop),
    ):
        executable = work / (
            "sfx_music_play_" + implementation.lower().replace(" ", "_")
        )
        run(fbc + [
            "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
            str(play_object), str(stop_object), str(probe_object),
            "-x", str(executable),
        ], cwd=work)
        observed = run([str(executable)], cwd=work)
        if observed != expected:
            raise AssertionError(
                f"SFX music play differs for {implementation}: "
                f"C={expected!r}, observed={observed!r}"
            )
    print(
        "SFX music play: C2FB candidate and integrated Basic match C for "
        "readiness, asset, allocation, loop, restart, and debug cases"
    )


def check_sfx_music_load_behavior(
    fbc, cc, source_root, basic_load, basic_stop,
    candidate_load, work,
):
    sfx_directory = source_root / "sfxlib"
    probe_source = work / "sfx_music_load_probe.c"
    probe_source.write_text(
        "#include <stdarg.h>\n"
        "#include <stdio.h>\n"
        "#include <stdlib.h>\n"
        "#include <string.h>\n"
        '#include "fb_sfx_internal.h"\n'
        "#ifndef SFX_MUSIC_LOAD_FUNCTION\n"
        "#define SFX_MUSIC_LOAD_FUNCTION fb_sfxMusicLoad\n"
        "#endif\n"
        "#ifndef SFX_MUSIC_UNLOAD_FUNCTION\n"
        "#define SFX_MUSIC_UNLOAD_FUNCTION fb_sfxMusicUnload\n"
        "#endif\n"
        "extern int SFX_MUSIC_LOAD_FUNCTION(const char *filename);\n"
        "extern void SFX_MUSIC_UNLOAD_FUNCTION(void);\n"
        "FB_SFXCTX *__fb_sfx;\n"
        "static int initialized;\n"
        "static int debug_enabled;\n"
        "static int decoder_calls;\n"
        "static int lock_count;\n"
        "static int unlock_count;\n"
        "static int debug_count;\n"
        "static char debug_message[160];\n"
        "static int track_memory;\n"
        "static int fail_allocation_at;\n"
        "static int allocation_attempts;\n"
        "static int free_calls;\n"
        "static struct { void *pointer; int live; } tracked[16];\n"
        "static int tracked_count;\n"
        "static float decoded_samples[6] = { 1.0f, 3.0f, 2.0f, 4.0f, 5.0f, 7.0f };\n"
        "void *__real_malloc(size_t size);\n"
        "void __real_free(void *pointer);\n"
        "void *__wrap_malloc(size_t size) {\n"
        "    void *pointer;\n"
        "    if (track_memory) {\n"
        "        ++allocation_attempts;\n"
        "        if (fail_allocation_at == allocation_attempts) return NULL;\n"
        "    }\n"
        "    pointer = __real_malloc(size);\n"
        "    if (track_memory && pointer && tracked_count < 16) {\n"
        "        tracked[tracked_count].pointer = pointer;\n"
        "        tracked[tracked_count].live = 1;\n"
        "        ++tracked_count;\n"
        "    }\n"
        "    return pointer;\n"
        "}\n"
        "void __wrap_free(void *pointer) {\n"
        "    int index;\n"
        "    if (!pointer) return;\n"
        "    if (track_memory) ++free_calls;\n"
        "    for (index = 0; index < tracked_count; ++index) {\n"
        "        if (tracked[index].live && tracked[index].pointer == pointer) {\n"
        "            tracked[index].live = 0;\n"
        "            break;\n"
        "        }\n"
        "    }\n"
        "    __real_free(pointer);\n"
        "}\n"
        "static int live_allocation_count(void) {\n"
        "    int index;\n"
        "    int count = 0;\n"
        "    for (index = 0; index < tracked_count; ++index)\n"
        "        if (tracked[index].live) ++count;\n"
        "    return count;\n"
        "}\n"
        "static void release_tracked_allocations(void) {\n"
        "    int index;\n"
        "    for (index = 0; index < tracked_count; ++index) {\n"
        "        if (tracked[index].live) {\n"
        "            __real_free(tracked[index].pointer);\n"
        "            tracked[index].live = 0;\n"
        "        }\n"
        "    }\n"
        "}\n"
        "int fb_sfxEnsureInitialized(void) { return initialized; }\n"
        "int fb_sfxDebugEnabled(void) { return debug_enabled; }\n"
        "void fb_sfxDebugLog(const char *format, ...) {\n"
        "    va_list arguments;\n"
        "    ++debug_count;\n"
        "    va_start(arguments, format);\n"
        "    vsnprintf(debug_message, sizeof(debug_message), format, arguments);\n"
        "    va_end(arguments);\n"
        "}\n"
        "void fb_sfxRuntimeLock(void) { ++lock_count; }\n"
        "void fb_sfxRuntimeUnlock(void) { ++unlock_count; }\n"
        "int fb_sfxDecodeFile(const char *filename, float **decoded,\n"
        "                     int *frames, int *channels, int *sample_rate) {\n"
        "    ++decoder_calls;\n"
        "    *decoded = NULL;\n"
        "    if (strcmp(filename, \"decode-error\") == 0) return -1;\n"
        "    *decoded = (float *)malloc(sizeof(decoded_samples));\n"
        "    if (!*decoded) return -1;\n"
        "    memcpy(*decoded, decoded_samples, sizeof(decoded_samples));\n"
        "    *frames = 3;\n"
        "    *channels = 2;\n"
        "    *sample_rate = 22050;\n"
        "    if (strcmp(filename, \"zero-frames\") == 0) *frames = 0;\n"
        "    if (strcmp(filename, \"zero-channels\") == 0) *channels = 0;\n"
        "    return 0;\n"
        "}\n"
        "static void run_case(const char *case_name, int operation,\n"
        "                     int is_ready, int show_debug, const char *filename,\n"
        "                     int keep_old_asset, int playing, int music_voice,\n"
        "                     int fail_at, int track) {\n"
        "    FB_SFXCTX context;\n"
        "    float *old_data = NULL;\n"
        "    int result = 0;\n"
        "    int live_count;\n"
        "    float sample0 = 0.0f, sample1 = 0.0f, sample2 = 0.0f;\n"
        "    memset(&context, 0, sizeof(context));\n"
        "    if (keep_old_asset) {\n"
        "        old_data = (float *)__real_malloc(2 * sizeof(float));\n"
        "        if (!old_data) return;\n"
        "        old_data[0] = 9.0f; old_data[1] = 11.0f;\n"
        "        context.music.data = old_data;\n"
        "        context.music.size = 8;\n"
        "        context.music.frames = 2;\n"
        "        context.music.sample_rate = 11025;\n"
        "        context.music.loaded = 1;\n"
        "        strcpy(context.music.name, \"old.ogg\");\n"
        "    }\n"
        "    context.music_playing = playing;\n"
        "    if (music_voice) {\n"
        "        context.voices[0].active = 1;\n"
        "        context.voices[0].type = FB_SFX_VOICE_MUSIC;\n"
        "        context.voices[0].data = context.music.data;\n"
        "    }\n"
        "    __fb_sfx = &context;\n"
        "    initialized = is_ready;\n"
        "    debug_enabled = show_debug;\n"
        "    decoder_calls = lock_count = unlock_count = debug_count = 0;\n"
        "    allocation_attempts = free_calls = tracked_count = 0;\n"
        "    fail_allocation_at = fail_at;\n"
        "    track_memory = track;\n"
        "    debug_message[0] = '\\0';\n"
        "    if (operation == 0)\n"
        "        result = SFX_MUSIC_LOAD_FUNCTION(filename);\n"
        "    else\n"
        "        SFX_MUSIC_UNLOAD_FUNCTION();\n"
        "    track_memory = 0;\n"
        "    live_count = live_allocation_count();\n"
        "    if (context.music.data && context.music.frames > 0) {\n"
        "        sample0 = context.music.data[0];\n"
        "        if (context.music.frames > 1) sample1 = context.music.data[1];\n"
        "        if (context.music.frames > 2) sample2 = context.music.data[2];\n"
        "    }\n"
        '    printf("run|%s|%d|%d|%d|%d|%d|%d|%d|%d\\n", case_name, '
        "           result, decoder_calls, lock_count, unlock_count, "
        "           allocation_attempts, free_calls, live_count, debug_count);\n"
        '    printf("asset|%d|%d|%d|%d|%s\\n", context.music.loaded, '
        "           context.music.size, context.music.frames, "
        "           context.music.sample_rate, context.music.name);\n"
        '    printf("samples|%.9g|%.9g|%.9g\\n", sample0, sample1, sample2);\n'
        '    printf("state|%d|%d|%d|%d|%d|%d\\n", context.music_playing, '
        "           context.music_paused, context.music_loop, context.music_pos, "
        "           context.voices[0].active, context.voices[0].data == NULL);\n"
        '    printf("debug|%s\\n", debug_message);\n'
        "    if (context.music.data) __wrap_free(context.music.data);\n"
        "    release_tracked_allocations();\n"
        "}\n"
        "int main(void) {\n"
        '    run_case("not-ready", 0, 0, 0, "song.ogg", 1, 0, 1, 0, 1);\n'
        '    run_case("null-name", 0, 1, 0, NULL, 1, 0, 1, 0, 1);\n'
        '    run_case("empty-name", 0, 1, 0, "", 1, 0, 1, 0, 1);\n'
        '    run_case("decode-error", 0, 1, 0, "decode-error", 1, 0, 1, 0, 1);\n'
        '    run_case("zero-frames", 0, 1, 0, "zero-frames", 1, 0, 1, 0, 1);\n'
        '    run_case("zero-channels", 0, 1, 0, "zero-channels", 1, 0, 1, 0, 1);\n'
        '    run_case("mono-allocation-failure", 0, 1, 0, "song.ogg", 1, 0, 1, 2, 1);\n'
        '    run_case("load-success", 0, 1, 0, "song.ogg", 0, -1, 0, 0, 1);\n'
        '    run_case("replace-current", 0, 1, 0, "song.ogg", 1, 0, 1, 0, 1);\n'
        '    run_case("debug-load", 0, 1, 1, "song.ogg", 0, -1, 0, 0, 0);\n'
        '    run_case("unload", 1, 1, 1, NULL, 1, 0, 1, 0, 1);\n'
        '    run_case("unload-not-ready", 1, 0, 0, NULL, 1, 0, 1, 0, 1);\n'
        "    return 0;\n"
        "}\n"
    )

    reference_objects = []
    for source_name, object_name in (
        ("sfx_music_load.c", "sfx_music_load_reference.o"),
        ("sfx_music_stop.c", "sfx_music_stop_reference.o"),
    ):
        object_path = work / object_name
        command = cc + ["-std=c99", "-Wall", "-Wextra", "-Werror", f"-I{sfx_directory}"]
        if source_name == "sfx_music_load.c":
            command.extend((
                "-Dfb_sfxMusicLoad=cReferenceMusicLoad",
                "-Dfb_sfxMusicUnload=cReferenceMusicUnload",
            ))
        command.extend(("-c", str(sfx_directory / source_name), "-o", str(object_path)))
        run(command, cwd=work)
        reference_objects.append(object_path)

    reference_probe = work / "sfx_music_load_reference_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror", f"-I{sfx_directory}",
        "-DSFX_MUSIC_LOAD_FUNCTION=cReferenceMusicLoad",
        "-DSFX_MUSIC_UNLOAD_FUNCTION=cReferenceMusicUnload",
        "-c", str(probe_source), "-o", str(reference_probe),
    ], cwd=work)
    wrap_flags = ["-Wl,--wrap=malloc", "-Wl,--wrap=free"]
    reference_executable = work / "sfx_music_load_reference"
    run(cc + [
        *(str(path) for path in reference_objects), str(reference_probe),
        *wrap_flags, "-o", str(reference_executable),
    ], cwd=work)
    expected = run([str(reference_executable)], cwd=work)

    probe_object = work / "sfx_music_load_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror", f"-I{sfx_directory}",
        "-c", str(probe_source), "-o", str(probe_object),
    ], cwd=work)
    for implementation, load_object, stop_object in (
        ("C2FB candidate", candidate_load, basic_stop),
        ("integrated Basic", basic_load, basic_stop),
    ):
        executable = work / (
            "sfx_music_load_" + implementation.lower().replace(" ", "_")
        )
        run(fbc + [
            "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
            "-Wl", "--wrap=malloc", "-Wl", "--wrap=free",
            str(load_object), str(stop_object), str(probe_object),
            "-x", str(executable),
        ], cwd=work)
        observed = run([str(executable)], cwd=work)
        if observed != expected:
            raise AssertionError(
                f"SFX music load differs for {implementation}: "
                f"C={expected!r}, observed={observed!r}"
            )
    print(
        "SFX music load: C2FB candidate and integrated Basic match C for "
        "decode errors, invalid dimensions, allocation failure, replacement, "
        "unload, mono conversion, and debug output"
    )


def check_sfx_sfx_load_behavior(
    fbc, cc, source_root, basic_load, basic_stop, candidate_load, work,
):
    sfx_directory = source_root / "sfxlib"
    probe_source = work / "sfx_sfx_load_probe.c"
    probe_source.write_text(
        "#include <stdarg.h>\n"
        "#include <stdio.h>\n"
        "#include <stdlib.h>\n"
        "#include <string.h>\n"
        '#include "fb_sfx_internal.h"\n'
        "#ifndef SFX_ASSET_LOAD_FUNCTION\n"
        "#define SFX_ASSET_LOAD_FUNCTION fb_sfxSfxLoad\n"
        "#endif\n"
        "#ifndef SFX_ASSET_UNLOAD_FUNCTION\n"
        "#define SFX_ASSET_UNLOAD_FUNCTION fb_sfxSfxUnload\n"
        "#endif\n"
        "extern void SFX_ASSET_LOAD_FUNCTION(int id, const char *filename);\n"
        "extern void SFX_ASSET_UNLOAD_FUNCTION(int id);\n"
        "FB_SFXCTX *__fb_sfx;\n"
        "static int initialized;\n"
        "static int debug_enabled;\n"
        "static int decoder_calls;\n"
        "static int lock_count;\n"
        "static int unlock_count;\n"
        "static int debug_count;\n"
        "static char debug_message[160];\n"
        "static int track_memory;\n"
        "static int fail_allocation_at;\n"
        "static int allocation_attempts;\n"
        "static int free_calls;\n"
        "static struct { void *pointer; int live; } tracked[16];\n"
        "static int tracked_count;\n"
        "static float decoded_samples[6] = { 1.0f, 3.0f, 2.0f, 4.0f, 5.0f, 7.0f };\n"
        "static float spare_samples[4] = { 9.0f, 11.0f, 13.0f, 15.0f };\n"
        "void *__real_malloc(size_t size);\n"
        "void __real_free(void *pointer);\n"
        "void *__wrap_malloc(size_t size) {\n"
        "    void *pointer;\n"
        "    if (track_memory) {\n"
        "        ++allocation_attempts;\n"
        "        if (fail_allocation_at == allocation_attempts) return NULL;\n"
        "    }\n"
        "    pointer = __real_malloc(size);\n"
        "    if (track_memory && pointer && tracked_count < 16) {\n"
        "        tracked[tracked_count].pointer = pointer;\n"
        "        tracked[tracked_count].live = 1;\n"
        "        ++tracked_count;\n"
        "    }\n"
        "    return pointer;\n"
        "}\n"
        "void __wrap_free(void *pointer) {\n"
        "    int index;\n"
        "    if (!pointer) return;\n"
        "    if (track_memory) ++free_calls;\n"
        "    for (index = 0; index < tracked_count; ++index) {\n"
        "        if (tracked[index].live && tracked[index].pointer == pointer) {\n"
        "            tracked[index].live = 0;\n"
        "            break;\n"
        "        }\n"
        "    }\n"
        "    __real_free(pointer);\n"
        "}\n"
        "static int live_allocation_count(void) {\n"
        "    int index;\n"
        "    int count = 0;\n"
        "    for (index = 0; index < tracked_count; ++index)\n"
        "        if (tracked[index].live) ++count;\n"
        "    return count;\n"
        "}\n"
        "static void release_tracked_allocations(void) {\n"
        "    int index;\n"
        "    for (index = 0; index < tracked_count; ++index) {\n"
        "        if (tracked[index].live) {\n"
        "            __real_free(tracked[index].pointer);\n"
        "            tracked[index].live = 0;\n"
        "        }\n"
        "    }\n"
        "}\n"
        "int fb_sfxEnsureInitialized(void) { return initialized; }\n"
        "int fb_sfxDebugEnabled(void) { return debug_enabled; }\n"
        "void fb_sfxDebugLog(const char *format, ...) {\n"
        "    va_list arguments;\n"
        "    ++debug_count;\n"
        "    va_start(arguments, format);\n"
        "    vsnprintf(debug_message, sizeof(debug_message), format, arguments);\n"
        "    va_end(arguments);\n"
        "}\n"
        "void fb_sfxRuntimeLock(void) { ++lock_count; }\n"
        "void fb_sfxRuntimeUnlock(void) { ++unlock_count; }\n"
        "int fb_sfxDecodeFile(const char *filename, float **decoded,\n"
        "                     int *frames, int *channels, int *sample_rate) {\n"
        "    ++decoder_calls;\n"
        "    *decoded = NULL;\n"
        "    if (strcmp(filename, \"decode-error\") == 0) return -1;\n"
        "    *decoded = (float *)malloc(sizeof(decoded_samples));\n"
        "    if (!*decoded) return -1;\n"
        "    memcpy(*decoded, decoded_samples, sizeof(decoded_samples));\n"
        "    *frames = 3; *channels = 2; *sample_rate = 22050;\n"
        "    if (strcmp(filename, \"zero-frames\") == 0) *frames = 0;\n"
        "    if (strcmp(filename, \"zero-channels\") == 0) *channels = 0;\n"
        "    return 0;\n"
        "}\n"
        "static void run_case(const char *case_name, int operation,\n"
        "                     int is_ready, int show_debug, int sfx_id,\n"
        "                     const char *filename, int keep_old_asset,\n"
        "                     int playing, int fail_at, int track) {\n"
        "    FB_SFXCTX context;\n"
        "    float *old_data = NULL;\n"
        "    int index = (sfx_id >= 0 && sfx_id < FB_SFX_MAX_SFX) ? sfx_id : 0;\n"
        "    int other_id = (index == 4) ? 5 : 4;\n"
        "    int live_count;\n"
        "    float sample0 = 0.0f, sample1 = 0.0f, sample2 = 0.0f;\n"
        "    memset(&context, 0, sizeof(context));\n"
        "    context.music_playing = playing;\n"
        "    context.sfx[other_id].data = spare_samples;\n"
        "    context.sfx[other_id].size = sizeof(spare_samples);\n"
        "    context.sfx[other_id].frames = 4;\n"
        "    context.sfx[other_id].sample_rate = 16000;\n"
        "    context.sfx[other_id].loaded = 1;\n"
        "    strcpy(context.sfx[other_id].name, \"other.ogg\");\n"
        "    if (keep_old_asset && sfx_id >= 0 && sfx_id < FB_SFX_MAX_SFX) {\n"
        "        old_data = (float *)__real_malloc(2 * sizeof(float));\n"
        "        if (!old_data) return;\n"
        "        old_data[0] = 9.0f; old_data[1] = 11.0f;\n"
        "        context.sfx[index].data = old_data;\n"
        "        context.sfx[index].size = 8;\n"
        "        context.sfx[index].frames = 2;\n"
        "        context.sfx[index].sample_rate = 11025;\n"
        "        context.sfx[index].loaded = 1;\n"
        "        strcpy(context.sfx[index].name, \"old.ogg\");\n"
        "    } else if (sfx_id < 0 || sfx_id >= FB_SFX_MAX_SFX) {\n"
        "        context.sfx[0].data = spare_samples;\n"
        "        context.sfx[0].loaded = 1;\n"
        "        strcpy(context.sfx[0].name, \"sentinel.ogg\");\n"
        "    }\n"
        "    context.voices[0].active = 1;\n"
        "    context.voices[0].type = FB_SFX_VOICE_SFX;\n"
        "    context.voices[0].sfx_id = sfx_id;\n"
        "    context.voices[0].data = old_data ? old_data : spare_samples;\n"
        "    context.voices[1].active = 1;\n"
        "    context.voices[1].type = FB_SFX_VOICE_SFX;\n"
        "    context.voices[1].sfx_id = other_id;\n"
        "    context.voices[1].data = spare_samples;\n"
        "    context.voices[2].active = 1;\n"
        "    context.voices[2].type = FB_SFX_VOICE_MUSIC;\n"
        "    context.voices[2].data = spare_samples;\n"
        "    __fb_sfx = &context;\n"
        "    initialized = is_ready; debug_enabled = show_debug;\n"
        "    decoder_calls = lock_count = unlock_count = debug_count = 0;\n"
        "    allocation_attempts = free_calls = tracked_count = 0;\n"
        "    fail_allocation_at = fail_at; track_memory = track;\n"
        "    debug_message[0] = '\\0';\n"
        "    if (operation == 0) SFX_ASSET_LOAD_FUNCTION(sfx_id, filename);\n"
        "    else SFX_ASSET_UNLOAD_FUNCTION(sfx_id);\n"
        "    track_memory = 0; live_count = live_allocation_count();\n"
        "    if (context.sfx[index].data && context.sfx[index].frames > 0) {\n"
        "        sample0 = context.sfx[index].data[0];\n"
        "        if (context.sfx[index].frames > 1) sample1 = context.sfx[index].data[1];\n"
        "        if (context.sfx[index].frames > 2) sample2 = context.sfx[index].data[2];\n"
        "    }\n"
        '    printf("run|%s|%d|%d|%d|%d|%d|%d|%d|%d\\n", case_name, '
        "           decoder_calls, lock_count, unlock_count, allocation_attempts, "
        "           free_calls, live_count, debug_count, context.sfx[index].loaded);\n"
        '    printf("asset|%d|%d|%d|%d|%s\\n", context.sfx[index].size, '
        "           context.sfx[index].frames, context.sfx[index].sample_rate, "
        "           context.sfx[other_id].loaded, context.sfx[index].name);\n"
        '    printf("samples|%.9g|%.9g|%.9g\\n", sample0, sample1, sample2);\n'
        '    printf("voices|%d|%d|%d|%d|%d|%d\\n", '
        "           context.voices[0].active, context.voices[0].sfx_id, "
        "           context.voices[0].data == NULL, context.voices[1].active, "
        "           context.voices[1].sfx_id, context.voices[2].active);\n"
        '    printf("debug|%s\\n", debug_message);\n'
        "    if (context.sfx[index].data && context.sfx[index].data != spare_samples)\n"
        "        __wrap_free(context.sfx[index].data);\n"
        "    release_tracked_allocations();\n"
        "}\n"
        "int main(void) {\n"
        '    run_case("not-ready", 0, 0, 0, 3, "song.ogg", 1, 7, 0, 1);\n'
        '    run_case("negative-id", 0, 1, 0, -1, "song.ogg", 0, -1, 0, 1);\n'
        '    run_case("high-id", 0, 1, 0, 64, "song.ogg", 0, -1, 0, 1);\n'
        '    run_case("empty-name", 0, 1, 0, 3, "", 1, 0, 0, 1);\n'
        '    run_case("decode-error", 0, 1, 0, 3, "decode-error", 1, 0, 0, 1);\n'
        '    run_case("zero-frames", 0, 1, 0, 3, "zero-frames", 1, 0, 0, 1);\n'
        '    run_case("zero-channels", 0, 1, 0, 3, "zero-channels", 1, 0, 0, 1);\n'
        '    run_case("allocation-failure", 0, 1, 0, 3, "song.ogg", 1, 0, 2, 1);\n'
        '    run_case("load-success", 0, 1, 0, 3, "song.ogg", 0, -1, 0, 1);\n'
        '    run_case("replace-current", 0, 1, 0, 3, "song.ogg", 1, 7, 0, 1);\n'
        '    run_case("debug-load", 0, 1, 1, 7, "song.ogg", 0, -1, 0, 0);\n'
        '    run_case("unload", 1, 1, 1, 3, NULL, 1, 0, 0, 1);\n'
        '    run_case("unload-not-ready", 1, 0, 0, 3, NULL, 1, 0, 0, 1);\n'
        "    return 0;\n"
        "}\n"
    )

    reference_objects = []
    for source_name, object_name in (
        ("sfx_sfx_load.c", "sfx_sfx_load_reference.o"),
        ("sfx_music_stop.c", "sfx_music_stop_reference.o"),
    ):
        object_path = work / object_name
        command = cc + ["-std=c99", "-Wall", "-Wextra", "-Werror", f"-I{sfx_directory}"]
        if source_name == "sfx_sfx_load.c":
            command.extend((
                "-Dfb_sfxSfxLoad=cReferenceSfxLoad",
                "-Dfb_sfxSfxUnload=cReferenceSfxUnload",
            ))
        command.extend(("-c", str(sfx_directory / source_name), "-o", str(object_path)))
        run(command, cwd=work)
        reference_objects.append(object_path)

    reference_probe = work / "sfx_sfx_load_reference_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror", f"-I{sfx_directory}",
        "-DSFX_ASSET_LOAD_FUNCTION=cReferenceSfxLoad",
        "-DSFX_ASSET_UNLOAD_FUNCTION=cReferenceSfxUnload",
        "-c", str(probe_source), "-o", str(reference_probe),
    ], cwd=work)
    wrap_flags = ["-Wl,--wrap=malloc", "-Wl,--wrap=free"]
    reference_executable = work / "sfx_sfx_load_reference"
    run(cc + [
        *(str(path) for path in reference_objects), str(reference_probe),
        *wrap_flags, "-o", str(reference_executable),
    ], cwd=work)
    expected = run([str(reference_executable)], cwd=work)

    probe_object = work / "sfx_sfx_load_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror", f"-I{sfx_directory}",
        "-c", str(probe_source), "-o", str(probe_object),
    ], cwd=work)
    executable = work / "sfx_sfx_load_basic"
    run(fbc + [
        "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
        "-Wl", "--wrap=malloc", "-Wl", "--wrap=free",
        str(basic_load), str(basic_stop), str(probe_object),
        "-x", str(executable),
    ], cwd=work)
    observed = run([str(executable)], cwd=work)
    if observed != expected:
        raise AssertionError(
            f"SFX indexed asset load differs for integrated Basic: "
            f"C={expected!r}, observed={observed!r}"
        )

    candidate_executable = work / "sfx_sfx_load_candidate"
    run(fbc + [
        "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
        "-Wl", "--wrap=malloc", "-Wl", "--wrap=free",
        str(candidate_load), str(basic_stop), str(probe_object),
        "-x", str(candidate_executable),
    ], cwd=work)
    candidate_output = run([str(candidate_executable)], cwd=work)
    if candidate_output != expected:
        raise AssertionError(
            f"SFX indexed asset load differs for C2FB candidate: "
            f"C={expected!r}, observed={candidate_output!r}"
        )
    print(
        "SFX indexed asset load: C2FB candidate and integrated Basic match C "
        "for ID bounds, decode failures, memory ownership, replacement, unload, "
        "voice selection, mono conversion, and debug cases"
    )


def check_sfx_voice_command(fbc, cc, source_root, basic_object,
                            candidate_object, work):
    sfx_directory = source_root / "sfxlib"
    rtlib_directory = source_root / "rtlib"
    support_source = work / "sfx_voice_command_support.c"
    support_source.write_text(
        '#include "fb_sfx.h"\n'
        '#include "fb_sfx_internal.h"\n'
        "#include <stdarg.h>\n"
        "#include <stdio.h>\n"
        "FB_SFXCTX *__fb_sfx;\n"
        "static int g_initialized, g_channel, g_instrument;\n"
        "static unsigned int g_defined_mask;\n"
        "static int g_debug_enabled, g_set_calls, g_get_calls;\n"
        "static int g_last_set_channel, g_last_set_instrument, g_last_get_channel;\n"
        "static int g_debug_calls;\n"
        "static char g_debug_text[128];\n"
        "void fb_sfxVoiceTestReset(int initialized, int has_context, "
        "int channel, int instrument, unsigned int defined_mask, "
        "int debug_enabled) {\n"
        "    __fb_sfx = has_context ? (FB_SFXCTX *)1 : NULL;\n"
        "    g_initialized = initialized; g_channel = channel;\n"
        "    g_instrument = instrument; g_defined_mask = defined_mask;\n"
        "    g_debug_enabled = debug_enabled; g_set_calls = g_get_calls = 0;\n"
        "    g_last_set_channel = g_last_set_instrument = g_last_get_channel = -99;\n"
        "    g_debug_calls = 0; g_debug_text[0] = 0;\n"
        "}\n"
        "int fb_sfxEnsureInitialized(void) { return g_initialized; }\n"
        "int fb_sfxChannelCmdGet(void) { return g_channel; }\n"
        "void fb_sfxChannelSetInstrument(int channel, int instrument) {\n"
        "    ++g_set_calls; g_last_set_channel = channel;\n"
        "    g_last_set_instrument = instrument; g_instrument = instrument;\n"
        "}\n"
        "int fb_sfxChannelGetInstrument(int channel) {\n"
        "    ++g_get_calls; g_last_get_channel = channel; return g_instrument;\n"
        "}\n"
        "int fb_sfxInstrumentDefined(int instrument) {\n"
        "    if (instrument < 0 || instrument >= FB_SFX_MAX_INSTRUMENTS) return 0;\n"
        "    return (g_defined_mask & (1u << instrument)) != 0;\n"
        "}\n"
        "int fb_sfxDebugEnabled(void) { return g_debug_enabled; }\n"
        "void fb_sfxDebugLog(const char *format, ...) {\n"
        "    va_list arguments; ++g_debug_calls;\n"
        "    va_start(arguments, format);\n"
        "    vsnprintf(g_debug_text, sizeof(g_debug_text), format, arguments);\n"
        "    va_end(arguments);\n"
        "}\n"
        "int fb_sfxVoiceTestSetCalls(void) { return g_set_calls; }\n"
        "int fb_sfxVoiceTestGetCalls(void) { return g_get_calls; }\n"
        "int fb_sfxVoiceTestLastSetChannel(void) { return g_last_set_channel; }\n"
        "int fb_sfxVoiceTestLastSetInstrument(void) { return g_last_set_instrument; }\n"
        "int fb_sfxVoiceTestLastGetChannel(void) { return g_last_get_channel; }\n"
        "int fb_sfxVoiceTestInstrument(void) { return g_instrument; }\n"
        "int fb_sfxVoiceTestDebugCalls(void) { return g_debug_calls; }\n"
        "const char *fb_sfxVoiceTestDebugText(void) { return g_debug_text; }\n"
    )
    support_object = work / "sfx_voice_command_support.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror", "-DFB_NO_GFXLIB",
        f"-I{sfx_directory}", f"-I{rtlib_directory}",
        "-c", str(support_source), "-o", str(support_object),
    ], cwd=work)

    reference_object = work / "sfx_voice_command_c_reference.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror", "-DFB_NO_GFXLIB",
        "-Dfb_sfxVoice=fb_sfxVoiceC",
        "-Dfb_sfxVoiceGet=fb_sfxVoiceGetC",
        f"-I{sfx_directory}", f"-I{rtlib_directory}",
        "-c", str(sfx_directory / "sfx_voice_cmd.c"),
        "-o", str(reference_object),
    ], cwd=work)

    basic_driver = (
        '#lang "fb"\n'
        'Declare Sub sfxVoice CDecl Alias "@VOICE_ALIAS@" (ByVal instrumentId As Long)\n'
        'Declare Function sfxVoiceGet CDecl Alias "@VOICE_GET_ALIAS@" () As Long\n'
        'Declare Sub sfxVoiceTestReset CDecl Alias "fb_sfxVoiceTestReset" '
        "(ByVal initialized As Long, ByVal hasContext As Long, ByVal selectedChannel As Long, "
        "ByVal instrumentState As Long, ByVal definedMask As UInteger, ByVal debugEnabled As Long)\n"
        'Declare Function sfxVoiceTestSetCalls CDecl Alias "fb_sfxVoiceTestSetCalls" () As Long\n'
        'Declare Function sfxVoiceTestGetCalls CDecl Alias "fb_sfxVoiceTestGetCalls" () As Long\n'
        'Declare Function sfxVoiceTestLastSetChannel CDecl Alias "fb_sfxVoiceTestLastSetChannel" () As Long\n'
        'Declare Function sfxVoiceTestLastSetInstrument CDecl Alias "fb_sfxVoiceTestLastSetInstrument" () As Long\n'
        'Declare Function sfxVoiceTestLastGetChannel CDecl Alias "fb_sfxVoiceTestLastGetChannel" () As Long\n'
        'Declare Function sfxVoiceTestInstrument CDecl Alias "fb_sfxVoiceTestInstrument" () As Long\n'
        'Declare Function sfxVoiceTestDebugCalls CDecl Alias "fb_sfxVoiceTestDebugCalls" () As Long\n'
        'Declare Function sfxVoiceTestDebugText CDecl Alias "fb_sfxVoiceTestDebugText" () As Const ZString Ptr\n'
        'Declare Function sfxVoiceTestStringCompare CDecl Alias "strcmp" '
        "(ByVal leftText As Const ZString Ptr, ByVal rightText As Const ZString Ptr) As Long\n"
        "Private Sub checkVoiceCase(ByVal caseName As Const ZString Ptr, "
        "ByVal initialized As Long, ByVal selectedChannel As Long, ByVal instrumentState As Long, "
        "ByVal definedMask As UInteger, ByVal debugEnabled As Long, "
        "ByVal requestedInstrument As Long, ByVal expectedSetCalls As Long, "
        "ByVal expectedInstrument As Long, ByVal expectedDebugCalls As Long, "
        "ByVal expectedDebugText As Const ZString Ptr)\n"
        "    sfxVoiceTestReset(initialized, 1, selectedChannel, instrumentState, "
        "definedMask, debugEnabled)\n"
        "    sfxVoice(requestedInstrument)\n"
        "    If sfxVoiceTestSetCalls() <> expectedSetCalls Then Print caseName; "
        "\" set calls\": End 1\n"
        "    If sfxVoiceTestInstrument() <> expectedInstrument Then Print caseName; "
        "\" instrument\": End 2\n"
        "    If expectedSetCalls > 0 Then\n"
        "        If sfxVoiceTestLastSetChannel() <> selectedChannel Then Print caseName; "
        "\" set channel\": End 3\n"
        "        If sfxVoiceTestLastSetInstrument() <> expectedInstrument Then Print caseName; "
        "\" set value\": End 4\n"
        "    End If\n"
        "    If sfxVoiceTestDebugCalls() <> expectedDebugCalls Then Print caseName; "
        "\" debug calls\": End 5\n"
        "    If sfxVoiceTestStringCompare(sfxVoiceTestDebugText(), expectedDebugText) <> 0 Then "
        "Print caseName; \" debug text\": End 6\n"
        "End Sub\n"
        "Private Sub checkVoiceGet(ByVal caseName As Const ZString Ptr, "
        "ByVal hasContext As Long, ByVal selectedChannel As Long, ByVal instrumentState As Long, "
        "ByVal expectedResult As Long, ByVal expectedGetCalls As Long)\n"
        "    sfxVoiceTestReset(0, hasContext, selectedChannel, instrumentState, 0, 0)\n"
        "    If sfxVoiceGet() <> expectedResult Then Print caseName; "
        "\" query result\": End 7\n"
        "    If sfxVoiceTestGetCalls() <> expectedGetCalls Then Print caseName; "
        "\" query calls\": End 8\n"
        "    If expectedGetCalls > 0 Then\n"
        "        If sfxVoiceTestLastGetChannel() <> selectedChannel Then Print caseName; "
        "\" query channel\": End 9\n"
        "    End If\n"
        "End Sub\n"
        "Function main() As Integer\n"
        "    checkVoiceCase(\"not initialized\", 0, 3, 4, 16, 1, 4, 0, 4, 0, StrPtr(!\"\"))\n"
        "    checkVoiceCase(\"clear\", 1, 3, 4, 0, 1, -1, 1, -1, 1, "
        "StrPtr(!\"sfx_voice_cmd: channel=3 instrument cleared\"))\n"
        "    checkVoiceCase(\"out of range\", 1, 3, 4, 16, 1, 16, 0, 4, 0, StrPtr(!\"\"))\n"
        "    checkVoiceCase(\"undefined\", 1, 3, 4, 0, 1, 4, 0, 4, 0, StrPtr(!\"\"))\n"
        "    checkVoiceCase(\"valid\", 1, 3, -1, 16, 1, 4, 1, 4, 1, "
        "StrPtr(!\"sfx_voice_cmd: channel=3 instrument=4\"))\n"
        "    checkVoiceGet(\"missing context\", 0, 3, 7, -1, 0)\n"
        "    checkVoiceGet(\"uninitialized context\", 1, 3, 7, 7, 1)\n"
        '    Print "SFX VOICE cases passed"\n'
        "    Return 0\n"
        "End Function\n"
        "End main()\n"
    )
    expected_output = "SFX VOICE cases passed\n"
    observed = {}
    implementations = (
        ("C reference", reference_object, "fb_sfxVoiceC", "fb_sfxVoiceGetC"),
        ("C2FB candidate", candidate_object, "fb_sfxVoice", "fb_sfxVoiceGet"),
        ("integrated Basic", basic_object, "fb_sfxVoice", "fb_sfxVoiceGet"),
    )
    for label, implementation_object, voice_alias, get_alias in implementations:
        driver_source = work / (
            "sfx_voice_driver_" + label.lower().replace(" ", "_") + ".bas"
        )
        driver_source.write_text(
            basic_driver.replace("@VOICE_ALIAS@", voice_alias)
            .replace("@VOICE_GET_ALIAS@", get_alias)
        )
        executable = work / (
            "sfx_voice_" + label.lower().replace(" ", "_")
        )
        run(fbc + [
            "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
            str(driver_source), str(implementation_object), str(support_object),
            "-x", str(executable),
        ], cwd=work)
        observed[label] = run([str(executable)], cwd=work)

    if any(output != expected_output for output in observed.values()):
        raise AssertionError(
            "SFX VOICE behavior differs from C: "
            f"expected={expected_output!r}, observed={observed}"
        )
    print(
        "SFX VOICE: C2FB candidate and integrated Basic module match C for "
        "initialization, bounds, instrument validation, clearing, debug, and queries"
    )


def check_sfx_wave_command(fbc, cc, source_root, basic_object,
                           candidate_object, work):
    sfx_directory = source_root / "sfxlib"
    rtlib_directory = source_root / "rtlib"
    support_source = work / "sfx_wave_command_support.c"
    support_source.write_text(
        '#include "fb_sfx.h"\n'
        '#include "fb_sfx_internal.h"\n'
        "#include <stdarg.h>\n"
        "#include <stdio.h>\n"
        "#include <string.h>\n"
        "static FB_SFXCTX g_context;\n"
        "FB_SFXCTX *__fb_sfx;\n"
        "static int g_initialized, g_debug_enabled, g_debug_calls;\n"
        "static char g_debug_text[128];\n"
        "void fb_sfxWaveTestReset(int initialized, int has_context, "
        "int seed_defined, int debug_enabled) {\n"
        "    memset(&g_context, 0, sizeof(g_context));\n"
        "    g_initialized = initialized; g_debug_enabled = debug_enabled;\n"
        "    g_debug_calls = 0; g_debug_text[0] = 0;\n"
        "    __fb_sfx = has_context ? &g_context : NULL;\n"
        "    if (seed_defined) {\n"
        "        for (int i = 0; i < FB_SFX_MAX_WAVES; ++i) {\n"
        "            g_context.waves[i].type = FB_SFX_WAVE_TRIANGLE;\n"
        "            g_context.waves[i].defined = 1;\n"
        "        }\n"
        "    }\n"
        "}\n"
        "int fb_sfxEnsureInitialized(void) { return g_initialized; }\n"
        "int fb_sfxDebugEnabled(void) { return g_debug_enabled; }\n"
        "void fb_sfxDebugLog(const char *format, ...) {\n"
        "    va_list arguments; ++g_debug_calls;\n"
        "    va_start(arguments, format);\n"
        "    vsnprintf(g_debug_text, sizeof(g_debug_text), format, arguments);\n"
        "    va_end(arguments);\n"
        "}\n"
        "int fb_sfxWaveTestType(int id) { return g_context.waves[id].type; }\n"
        "int fb_sfxWaveTestDefined(int id) { return g_context.waves[id].defined; }\n"
        "int fb_sfxWaveTestDefinedCount(void) {\n"
        "    int count = 0;\n"
        "    for (int i = 0; i < FB_SFX_MAX_WAVES; ++i)\n"
        "        count += g_context.waves[i].defined != 0;\n"
        "    return count;\n"
        "}\n"
        "int fb_sfxWaveTestDebugCalls(void) { return g_debug_calls; }\n"
        "const char *fb_sfxWaveTestDebugText(void) { return g_debug_text; }\n"
    )
    support_object = work / "sfx_wave_command_support.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror", "-DFB_NO_GFXLIB",
        f"-I{sfx_directory}", f"-I{rtlib_directory}",
        "-c", str(support_source), "-o", str(support_object),
    ], cwd=work)

    reference_object = work / "sfx_wave_command_c_reference.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror", "-DFB_NO_GFXLIB",
        "-Dfb_sfxWaveCmd=fb_sfxWaveCmdC",
        "-Dfb_sfxWaveDefined=fb_sfxWaveDefinedC",
        "-Dfb_sfxWaveCmdReset=fb_sfxWaveCmdResetC",
        f"-I{sfx_directory}", f"-I{rtlib_directory}",
        "-c", str(sfx_directory / "sfx_wave_cmd.c"),
        "-o", str(reference_object),
    ], cwd=work)

    basic_driver = (
        '#lang "fb"\n'
        'Declare Sub waveCmd CDecl Alias "@WAVE_CMD_ALIAS@" '
        "(ByVal waveId As Long, ByVal waveKind As Long)\n"
        'Declare Function waveDefined CDecl Alias "@WAVE_DEFINED_ALIAS@" '
        "(ByVal waveId As Long) As Long\n"
        'Declare Sub waveCmdReset CDecl Alias "@WAVE_RESET_ALIAS@" ()\n'
        'Declare Sub waveTestReset CDecl Alias "fb_sfxWaveTestReset" '
        "(ByVal initialized As Long, ByVal hasContext As Long, "
        "ByVal seedDefined As Long, ByVal debugEnabled As Long)\n"
        'Declare Function waveTestType CDecl Alias "fb_sfxWaveTestType" '
        "(ByVal waveId As Long) As Long\n"
        'Declare Function waveTestDefined CDecl Alias "fb_sfxWaveTestDefined" '
        "(ByVal waveId As Long) As Long\n"
        'Declare Function waveTestDefinedCount CDecl Alias "fb_sfxWaveTestDefinedCount" () As Long\n'
        'Declare Function waveTestDebugCalls CDecl Alias "fb_sfxWaveTestDebugCalls" () As Long\n'
        'Declare Function waveTestDebugText CDecl Alias "fb_sfxWaveTestDebugText" () As Const ZString Ptr\n'
        'Declare Function waveTestStringCompare CDecl Alias "strcmp" '
        "(ByVal leftText As Const ZString Ptr, ByVal rightText As Const ZString Ptr) As Long\n"
        "Private Sub checkWaveCase(ByVal caseName As Const ZString Ptr, "
        "ByVal initialized As Long, ByVal waveId As Long, ByVal waveKind As Long, "
        "ByVal expectedType As Long, ByVal expectedDefined As Long, "
        "ByVal expectedDebugCalls As Long, ByVal expectedDebugText As Const ZString Ptr)\n"
        "    waveTestReset(initialized, 1, 0, 1)\n"
        "    waveCmd(waveId, waveKind)\n"
        "    If waveTestType(3) <> expectedType Then Print caseName; "
        "\" type\": End 1\n"
        "    If waveTestDefined(3) <> expectedDefined Then Print caseName; "
        "\" defined\": End 2\n"
        "    If waveTestDebugCalls() <> expectedDebugCalls Then Print caseName; "
        "\" debug calls\": End 3\n"
        "    If waveTestStringCompare(waveTestDebugText(), expectedDebugText) <> 0 Then "
        "Print caseName; \" debug text\": End 4\n"
        "End Sub\n"
        "Private Sub checkWaveQuery(ByVal caseName As Const ZString Ptr, "
        "ByVal hasContext As Long, ByVal waveId As Long, ByVal seedDefined As Long, "
        "ByVal expectedDefined As Long)\n"
        "    waveTestReset(1, hasContext, seedDefined, 0)\n"
        "    If waveDefined(waveId) <> expectedDefined Then Print caseName; "
        "\" query\": End 5\n"
        "End Sub\n"
        "Private Sub checkWaveReset(ByVal caseName As Const ZString Ptr, "
        "ByVal initialized As Long, ByVal expectedCount As Long, "
        "ByVal expectedDebugCalls As Long, ByVal expectedDebugText As Const ZString Ptr)\n"
        "    waveTestReset(initialized, 1, 1, 1)\n"
        "    waveCmdReset()\n"
        "    If waveTestDefinedCount() <> expectedCount Then Print caseName; "
        "\" reset count\": End 6\n"
        "    If waveTestDebugCalls() <> expectedDebugCalls Then Print caseName; "
        "\" reset debug calls\": End 7\n"
        "    If waveTestStringCompare(waveTestDebugText(), expectedDebugText) <> 0 Then "
        "Print caseName; \" reset debug text\": End 8\n"
        "End Sub\n"
        "Function main() As Integer\n"
        "    checkWaveCase(\"not initialized\", 0, 3, 2, 0, 0, 0, StrPtr(!\"\"))\n"
        "    checkWaveCase(\"negative id\", 1, -1, 2, 0, 0, 0, StrPtr(!\"\"))\n"
        "    checkWaveCase(\"upper id\", 1, 16, 2, 0, 0, 0, StrPtr(!\"\"))\n"
        "    checkWaveCase(\"low clamp\", 1, 3, -2, 0, 1, 1, "
        "StrPtr(!\"sfx_wave_cmd: id=3 type=0\"))\n"
        "    checkWaveCase(\"high clamp\", 1, 3, 99, 4, 1, 1, "
        "StrPtr(!\"sfx_wave_cmd: id=3 type=4\"))\n"
        "    checkWaveCase(\"middle type\", 1, 3, 2, 2, 1, 1, "
        "StrPtr(!\"sfx_wave_cmd: id=3 type=2\"))\n"
        "    checkWaveQuery(\"missing context\", 0, 3, 1, 0)\n"
        "    checkWaveQuery(\"negative query\", 1, -1, 1, 0)\n"
        "    checkWaveQuery(\"upper query\", 1, 16, 1, 0)\n"
        "    checkWaveQuery(\"defined query\", 1, 3, 1, 1)\n"
        "    checkWaveReset(\"uninitialized reset\", 0, 16, 0, StrPtr(!\"\"))\n"
        "    checkWaveReset(\"reset\", 1, 0, 1, "
        "StrPtr(!\"sfx_wave_cmd: waveform table reset\"))\n"
        '    Print "SFX WAVE cases passed"\n'
        "    Return 0\n"
        "End Function\n"
        "End main()\n"
    )

    expected_output = "SFX WAVE cases passed\n"
    observed = {}
    implementations = (
        ("C reference", reference_object, "fb_sfxWaveCmdC", "fb_sfxWaveDefinedC", "fb_sfxWaveCmdResetC"),
        ("C2FB candidate", candidate_object, "fb_sfxWaveCmd", "fb_sfxWaveDefined", "fb_sfxWaveCmdReset"),
        ("integrated Basic", basic_object, "fb_sfxWaveCmd", "fb_sfxWaveDefined", "fb_sfxWaveCmdReset"),
    )
    for label, implementation_object, command_alias, query_alias, reset_alias in implementations:
        driver_source = work / (
            "sfx_wave_driver_" + label.lower().replace(" ", "_") + ".bas"
        )
        driver_source.write_text(
            basic_driver.replace("@WAVE_CMD_ALIAS@", command_alias)
            .replace("@WAVE_DEFINED_ALIAS@", query_alias)
            .replace("@WAVE_RESET_ALIAS@", reset_alias)
        )
        executable = work / (
            "sfx_wave_" + label.lower().replace(" ", "_")
        )
        run(fbc + [
            "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
            str(driver_source), str(implementation_object), str(support_object),
            "-x", str(executable),
        ], cwd=work)
        observed[label] = run([str(executable)], cwd=work)

    if any(output != expected_output for output in observed.values()):
        raise AssertionError(
            "SFX WAVE behavior differs from C: "
            f"expected={expected_output!r}, observed={observed}"
        )
    print(
        "SFX WAVE: C2FB candidate and integrated Basic module match C for "
        "initialization, bounds, clamping, definition queries, reset, and debug"
    )


def check_sfx_capture_stop(fbc, cc, source_root, basic_object,
                           candidate_object, work):
    sfx_directory = source_root / "sfxlib"
    rtlib_directory = source_root / "rtlib"

    c_layout_source = work / "sfx_capture_stop_layout.c"
    c_layout_source.write_text(
        "#include <stddef.h>\n"
        "#include <stdio.h>\n"
        '#include "fb_sfx.h"\n'
        "int main(void) {\n"
        '    printf("%zu %zu %zu %zu %zu", sizeof(FB_SFXCTX), '
        "sizeof(FB_SFXCAPTURE), offsetof(FB_SFXCTX, capture), "
        "offsetof(FB_SFXCTX, capture.enabled), "
        "offsetof(FB_SFXCTX, driver));\n"
        "    return 0;\n"
        "}\n"
    )
    basic_layout_source = work / "sfx_capture_stop_layout.bas"
    basic_layout_source.write_text(
        '#include once "fb_sfx_c_prefix.bi"\n'
        "Dim context As SfxDriverContextPrefix\n"
        'Print SizeOf(context); " "; SizeOf(SfxCaptureStopCapturePrefix); " "; '
        'CULngInt(@context.capture)-CULngInt(@context); " "; '
        'CULngInt(@context.capture.enabled)-CULngInt(@context); " "; '
        'CULngInt(@context.driver)-CULngInt(@context)\n'
    )
    for label, c_definition, fb_definition in (
        ("desktop", None, None),
        ("nuttx", "-D__NuttX__", "__FB_NUTTX__"),
    ):
        c_executable = work / f"sfx_capture_stop_layout_c_{label}"
        c_command = [
            *cc, "-std=c99", f"-I{sfx_directory}", f"-I{rtlib_directory}",
        ]
        if c_definition is not None:
            c_command.append(c_definition)
        run(c_command + [
            str(c_layout_source), "-o", str(c_executable),
        ], cwd=work)

        basic_executable = work / f"sfx_capture_stop_layout_basic_{label}"
        basic_command = [
            *fbc, "-w", "all", "-i", str(source_root.parent / "inc"),
            "-i", str(sfx_directory),
        ]
        if fb_definition is not None:
            basic_command.extend(("-d", fb_definition))
        run(basic_command + [
            str(basic_layout_source), "-x", str(basic_executable),
        ], cwd=work)
        c_layout = run([str(c_executable)], cwd=work).split()
        basic_layout = run([str(basic_executable)], cwd=work).split()
        if c_layout != basic_layout:
            raise AssertionError(
                f"SFX capture-stop prefix differs for {label}: "
                f"C={c_layout}, FreeBASIC={basic_layout}"
            )

    support_source = work / "sfx_capture_stop_support.c"
    support_source.write_text(
        '#include "fb_sfx.h"\n'
        '#include "fb_sfx_internal.h"\n'
        '#include "fb_sfx_driver.h"\n'
        "#include <string.h>\n"
        "static FB_SFXCTX g_context;\n"
        "static SFXDRIVER g_real_driver;\n"
        "static SFXDRIVER g_null_driver;\n"
        "FB_SFXCTX *__fb_sfx;\n"
        "static int g_lock_calls, g_unlock_calls, g_lock_depth;\n"
        "static int g_driver_checks, g_last_driver_kind, g_check_depth;\n"
        "static int g_platform_stops, g_stop_depth, g_enabled_at_unlock;\n"
        "void fb_sfxCaptureTestReset(int has_context, int enabled, int driver_kind) {\n"
        "    memset(&g_context, 0, sizeof(g_context));\n"
        "    memset(&g_real_driver, 0, sizeof(g_real_driver));\n"
        "    memset(&g_null_driver, 0, sizeof(g_null_driver));\n"
        '    g_real_driver.name = "test"; g_null_driver.name = "null";\n'
        "    g_context.capture.enabled = enabled;\n"
        "    if (driver_kind == 1) g_context.driver = &g_real_driver;\n"
        "    else if (driver_kind == 2) g_context.driver = &g_null_driver;\n"
        "    __fb_sfx = has_context ? &g_context : NULL;\n"
        "    g_lock_calls = g_unlock_calls = g_lock_depth = 0;\n"
        "    g_driver_checks = g_platform_stops = 0;\n"
        "    g_last_driver_kind = -1; g_check_depth = g_stop_depth = -1;\n"
        "    g_enabled_at_unlock = -1;\n"
        "}\n"
        "void fb_sfxRuntimeLock(void) { ++g_lock_calls; ++g_lock_depth; }\n"
        "void fb_sfxRuntimeUnlock(void) {\n"
        "    ++g_unlock_calls; --g_lock_depth;\n"
        "    g_enabled_at_unlock = g_context.capture.enabled;\n"
        "}\n"
        "int fb_sfxDriverIsNull(const SFXDRIVER *driver) {\n"
        "    ++g_driver_checks; g_check_depth = g_lock_depth;\n"
        "    if (!driver) g_last_driver_kind = 0;\n"
        "    else if (driver == &g_null_driver) g_last_driver_kind = 2;\n"
        "    else g_last_driver_kind = 1;\n"
        "    return driver == &g_null_driver;\n"
        "}\n"
        "void fb_sfxPlatformCaptureStop(void) {\n"
        "    ++g_platform_stops; g_stop_depth = g_lock_depth;\n"
        "}\n"
        "int fb_sfxCaptureTestEnabled(void) { return g_context.capture.enabled; }\n"
        "int fb_sfxCaptureTestLockCalls(void) { return g_lock_calls; }\n"
        "int fb_sfxCaptureTestUnlockCalls(void) { return g_unlock_calls; }\n"
        "int fb_sfxCaptureTestDriverChecks(void) { return g_driver_checks; }\n"
        "int fb_sfxCaptureTestLastDriverKind(void) { return g_last_driver_kind; }\n"
        "int fb_sfxCaptureTestCheckDepth(void) { return g_check_depth; }\n"
        "int fb_sfxCaptureTestPlatformStops(void) { return g_platform_stops; }\n"
        "int fb_sfxCaptureTestStopDepth(void) { return g_stop_depth; }\n"
        "int fb_sfxCaptureTestEnabledAtUnlock(void) { return g_enabled_at_unlock; }\n"
    )
    support_object = work / "sfx_capture_stop_support.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror", "-DFB_NO_GFXLIB",
        f"-I{sfx_directory}", f"-I{rtlib_directory}",
        "-c", str(support_source), "-o", str(support_object),
    ], cwd=work)

    reference_object = work / "sfx_capture_stop_c_reference.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror", "-DFB_NO_GFXLIB",
        "-Dfb_sfxCaptureStop=fb_sfxCaptureStopC",
        f"-I{sfx_directory}", f"-I{rtlib_directory}",
        "-c", str(sfx_directory / "sfx_capture_stop.c"),
        "-o", str(reference_object),
    ], cwd=work)

    basic_driver = (
        '#lang "fb"\n'
        'Declare Sub captureStop CDecl Alias "@CAPTURE_STOP_ALIAS@" ()\n'
        'Declare Sub captureTestReset CDecl Alias "fb_sfxCaptureTestReset" '
        "(ByVal hasContext As Long, ByVal enabled As Long, ByVal driverKind As Long)\n"
        'Declare Function captureTestEnabled CDecl Alias "fb_sfxCaptureTestEnabled" () As Long\n'
        'Declare Function captureTestLockCalls CDecl Alias "fb_sfxCaptureTestLockCalls" () As Long\n'
        'Declare Function captureTestUnlockCalls CDecl Alias "fb_sfxCaptureTestUnlockCalls" () As Long\n'
        'Declare Function captureTestDriverChecks CDecl Alias "fb_sfxCaptureTestDriverChecks" () As Long\n'
        'Declare Function captureTestLastDriverKind CDecl Alias "fb_sfxCaptureTestLastDriverKind" () As Long\n'
        'Declare Function captureTestCheckDepth CDecl Alias "fb_sfxCaptureTestCheckDepth" () As Long\n'
        'Declare Function captureTestPlatformStops CDecl Alias "fb_sfxCaptureTestPlatformStops" () As Long\n'
        'Declare Function captureTestStopDepth CDecl Alias "fb_sfxCaptureTestStopDepth" () As Long\n'
        'Declare Function captureTestEnabledAtUnlock CDecl Alias "fb_sfxCaptureTestEnabledAtUnlock" () As Long\n'
        "Private Sub checkCaptureCase(ByVal caseName As Const ZString Ptr, "
        "ByVal hasContext As Long, ByVal enabled As Long, ByVal driverKind As Long, "
        "ByVal expectedEnabled As Long, ByVal expectedLocks As Long, "
        "ByVal expectedChecks As Long, ByVal expectedDriverKind As Long, "
        "ByVal expectedStops As Long, ByVal expectedUnlockState As Long)\n"
        "    captureTestReset(hasContext, enabled, driverKind)\n"
        "    captureStop()\n"
        "    If captureTestEnabled() <> expectedEnabled Then Print caseName; "
        "\" enabled\": End 1\n"
        "    If captureTestLockCalls() <> expectedLocks Then Print caseName; "
        "\" locks\": End 2\n"
        "    If captureTestUnlockCalls() <> expectedLocks Then Print caseName; "
        "\" unlocks\": End 3\n"
        "    If captureTestDriverChecks() <> expectedChecks Then Print caseName; "
        "\" driver checks\": End 4\n"
        "    If captureTestLastDriverKind() <> expectedDriverKind Then Print caseName; "
        "\" driver kind\": End 5\n"
        "    If captureTestPlatformStops() <> expectedStops Then Print caseName; "
        "\" platform stop\": End 6\n"
        "    If captureTestEnabledAtUnlock() <> expectedUnlockState Then Print caseName; "
        "\" unlock state\": End 7\n"
        "    If expectedChecks > 0 AndAlso captureTestCheckDepth() <> 0 Then Print caseName; "
        "\" driver check under lock\": End 8\n"
        "    If expectedStops > 0 AndAlso captureTestStopDepth() <> 0 Then Print caseName; "
        "\" platform stop under lock\": End 9\n"
        "End Sub\n"
        "Function main() As Integer\n"
        "    checkCaptureCase(\"missing context\", 0, 1, 1, 1, 0, 0, -1, 0, -1)\n"
        "    checkCaptureCase(\"already stopped\", 1, 0, 1, 0, 1, 0, -1, 0, 0)\n"
        "    checkCaptureCase(\"active without driver\", 1, 1, 0, 0, 1, 1, 0, 1, 0)\n"
        "    checkCaptureCase(\"active real driver\", 1, 1, 1, 0, 1, 1, 1, 1, 0)\n"
        "    checkCaptureCase(\"active null driver\", 1, 1, 2, 0, 1, 1, 2, 0, 0)\n"
        '    Print "SFX CAPTURE STOP cases passed"\n'
        "    Return 0\n"
        "End Function\n"
        "End main()\n"
    )

    expected_output = "SFX CAPTURE STOP cases passed\n"
    observed = {}
    implementations = (
        ("C reference", reference_object, "fb_sfxCaptureStopC"),
        ("C2FB candidate", candidate_object, "fb_sfxCaptureStop"),
        ("integrated Basic", basic_object, "fb_sfxCaptureStop"),
    )
    for label, implementation_object, function_alias in implementations:
        driver_source = work / (
            "sfx_capture_stop_driver_" + label.lower().replace(" ", "_") + ".bas"
        )
        driver_source.write_text(
            basic_driver.replace("@CAPTURE_STOP_ALIAS@", function_alias)
        )
        executable = work / (
            "sfx_capture_stop_" + label.lower().replace(" ", "_")
        )
        run(fbc + [
            "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
            str(driver_source), str(implementation_object), str(support_object),
            "-x", str(executable),
        ], cwd=work)
        observed[label] = run([str(executable)], cwd=work)

    if any(output != expected_output for output in observed.values()):
        raise AssertionError(
            "SFX CAPTURE STOP behavior differs from C: "
            f"expected={expected_output!r}, observed={observed}"
        )
    print(
        "SFX CAPTURE STOP: C2FB candidate and integrated Basic match C for "
        "missing context, stopped state, driver selection, and lock ordering"
    )


def check_sfx_capture_start(fbc, cc, source_root, basic_object,
                            candidate_object, work):
    sfx_directory = source_root / "sfxlib"
    rtlib_directory = source_root / "rtlib"
    support_source = work / "sfx_capture_start_support.c"
    support_source.write_text(
        '#include "fb_sfx.h"\n'
        '#include "fb_sfx_internal.h"\n'
        '#include "fb_sfx_driver.h"\n'
        "#include <stdarg.h>\n"
        "#include <stdio.h>\n"
        "#include <string.h>\n"
        "static FB_SFXCTX g_context;\n"
        "static SFXDRIVER g_real_driver;\n"
        "static SFXDRIVER g_null_driver;\n"
        "FB_SFXCTX *__fb_sfx;\n"
        "static int g_initialized, g_start_result, g_clear_context;\n"
        "static int g_debug_enabled, g_debug_calls, g_lock_calls, g_unlock_calls;\n"
        "static int g_lock_depth, g_driver_checks, g_last_driver_kind;\n"
        "static int g_check_depth, g_platform_starts, g_start_depth;\n"
        "static int g_enabled_at_unlock;\n"
        "static char g_debug_text[128];\n"
        "void fb_sfxCaptureStartTestReset(int has_context, int initialized, "
        "int enabled, int driver_kind, int start_result, int clear_context, "
        "int debug_enabled) {\n"
        "    memset(&g_context, 0, sizeof(g_context));\n"
        "    memset(&g_real_driver, 0, sizeof(g_real_driver));\n"
        "    memset(&g_null_driver, 0, sizeof(g_null_driver));\n"
        '    g_real_driver.name = "test"; g_null_driver.name = "null";\n'
        "    g_context.capture.enabled = enabled;\n"
        "    if (driver_kind == 1) g_context.driver = &g_real_driver;\n"
        "    else if (driver_kind == 2) g_context.driver = &g_null_driver;\n"
        "    __fb_sfx = has_context ? &g_context : NULL;\n"
        "    g_initialized = initialized; g_start_result = start_result;\n"
        "    g_clear_context = clear_context; g_debug_enabled = debug_enabled;\n"
        "    g_debug_calls = g_lock_calls = g_unlock_calls = g_lock_depth = 0;\n"
        "    g_driver_checks = g_platform_starts = 0;\n"
        "    g_last_driver_kind = -1; g_check_depth = g_start_depth = -1;\n"
        "    g_enabled_at_unlock = -1; g_debug_text[0] = 0;\n"
        "}\n"
        "int fb_sfxEnsureInitialized(void) { return g_initialized; }\n"
        "void fb_sfxRuntimeLock(void) { ++g_lock_calls; ++g_lock_depth; }\n"
        "void fb_sfxRuntimeUnlock(void) {\n"
        "    ++g_unlock_calls; --g_lock_depth;\n"
        "    g_enabled_at_unlock = g_context.capture.enabled;\n"
        "}\n"
        "int fb_sfxDriverIsNull(const SFXDRIVER *driver) {\n"
        "    ++g_driver_checks; g_check_depth = g_lock_depth;\n"
        "    if (!driver) g_last_driver_kind = 0;\n"
        "    else if (driver == &g_null_driver) g_last_driver_kind = 2;\n"
        "    else g_last_driver_kind = 1;\n"
        "    return driver == &g_null_driver;\n"
        "}\n"
        "int fb_sfxPlatformCaptureStart(void) {\n"
        "    ++g_platform_starts; g_start_depth = g_lock_depth;\n"
        "    if (g_clear_context) __fb_sfx = NULL;\n"
        "    return g_start_result;\n"
        "}\n"
        "int fb_sfxDebugEnabled(void) { return g_debug_enabled; }\n"
        "void fb_sfxDebugLog(const char *format, ...) {\n"
        "    va_list arguments; ++g_debug_calls;\n"
        "    va_start(arguments, format);\n"
        "    vsnprintf(g_debug_text, sizeof(g_debug_text), format, arguments);\n"
        "    va_end(arguments);\n"
        "}\n"
        "int fb_sfxCaptureStartTestEnabled(void) { return g_context.capture.enabled; }\n"
        "int fb_sfxCaptureStartTestContext(void) { return __fb_sfx != NULL; }\n"
        "int fb_sfxCaptureStartTestLocks(void) { return g_lock_calls; }\n"
        "int fb_sfxCaptureStartTestUnlocks(void) { return g_unlock_calls; }\n"
        "int fb_sfxCaptureStartTestDriverChecks(void) { return g_driver_checks; }\n"
        "int fb_sfxCaptureStartTestDriverKind(void) { return g_last_driver_kind; }\n"
        "int fb_sfxCaptureStartTestCheckDepth(void) { return g_check_depth; }\n"
        "int fb_sfxCaptureStartTestPlatformStarts(void) { return g_platform_starts; }\n"
        "int fb_sfxCaptureStartTestStartDepth(void) { return g_start_depth; }\n"
        "int fb_sfxCaptureStartTestEnabledAtUnlock(void) { return g_enabled_at_unlock; }\n"
        "int fb_sfxCaptureStartTestDebugCalls(void) { return g_debug_calls; }\n"
        "const char *fb_sfxCaptureStartTestDebugText(void) { return g_debug_text; }\n"
    )
    support_object = work / "sfx_capture_start_support.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror", "-DFB_NO_GFXLIB",
        f"-I{sfx_directory}", f"-I{rtlib_directory}",
        "-c", str(support_source), "-o", str(support_object),
    ], cwd=work)

    reference_object = work / "sfx_capture_start_c_reference.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror", "-DFB_NO_GFXLIB",
        "-Dfb_sfxCaptureStart=fb_sfxCaptureStartC",
        "-Dfb_sfxCaptureRunning=fb_sfxCaptureRunningC",
        f"-I{sfx_directory}", f"-I{rtlib_directory}",
        "-c", str(sfx_directory / "sfx_capture_start.c"),
        "-o", str(reference_object),
    ], cwd=work)

    basic_driver = (
        '#lang "fb"\n'
        'Declare Function startCapture CDecl Alias "@CAPTURE_START_ALIAS@" () As Long\n'
        'Declare Function queryCaptureRunning CDecl Alias "@CAPTURE_RUNNING_ALIAS@" () As Long\n'
        'Declare Sub captureStartTestReset CDecl Alias "fb_sfxCaptureStartTestReset" '
        "(ByVal hasContext As Long, ByVal initialized As Long, ByVal enabled As Long, "
        "ByVal driverKind As Long, ByVal startResult As Long, "
        "ByVal clearContext As Long, ByVal debugEnabled As Long)\n"
        'Declare Function captureStartTestEnabled CDecl Alias "fb_sfxCaptureStartTestEnabled" () As Long\n'
        'Declare Function captureStartTestContext CDecl Alias "fb_sfxCaptureStartTestContext" () As Long\n'
        'Declare Function captureStartTestLocks CDecl Alias "fb_sfxCaptureStartTestLocks" () As Long\n'
        'Declare Function captureStartTestUnlocks CDecl Alias "fb_sfxCaptureStartTestUnlocks" () As Long\n'
        'Declare Function captureStartTestDriverChecks CDecl Alias "fb_sfxCaptureStartTestDriverChecks" () As Long\n'
        'Declare Function captureStartTestDriverKind CDecl Alias "fb_sfxCaptureStartTestDriverKind" () As Long\n'
        'Declare Function captureStartTestCheckDepth CDecl Alias "fb_sfxCaptureStartTestCheckDepth" () As Long\n'
        'Declare Function captureStartTestPlatformStarts CDecl Alias "fb_sfxCaptureStartTestPlatformStarts" () As Long\n'
        'Declare Function captureStartTestStartDepth CDecl Alias "fb_sfxCaptureStartTestStartDepth" () As Long\n'
        'Declare Function captureStartTestEnabledAtUnlock CDecl Alias "fb_sfxCaptureStartTestEnabledAtUnlock" () As Long\n'
        'Declare Function captureStartTestDebugCalls CDecl Alias "fb_sfxCaptureStartTestDebugCalls" () As Long\n'
        'Declare Function captureStartTestDebugText CDecl Alias "fb_sfxCaptureStartTestDebugText" () As Const ZString Ptr\n'
        'Declare Function captureStartTestStringCompare CDecl Alias "strcmp" '
        "(ByVal leftText As Const ZString Ptr, ByVal rightText As Const ZString Ptr) As Long\n"
        "Private Sub checkCaptureStartCase(ByVal caseName As Const ZString Ptr, "
        "ByVal hasContext As Long, ByVal initialized As Long, "
        "ByVal enabled As Long, ByVal driverKind As Long, "
        "ByVal startResult As Long, ByVal clearContext As Long, "
        "ByVal debugEnabled As Long, ByVal expectedResult As Long, "
        "ByVal expectedEnabled As Long, ByVal expectedContext As Long, "
        "ByVal expectedLocks As Long, ByVal expectedDriverChecks As Long, "
        "ByVal expectedDriverKind As Long, ByVal expectedPlatformStarts As Long, "
        "ByVal expectedDebugCalls As Long, ByVal expectedDebugText As Const ZString Ptr)\n"
        "    captureStartTestReset(hasContext, initialized, enabled, driverKind, "
        "startResult, clearContext, debugEnabled)\n"
        "    If startCapture() <> expectedResult Then Print caseName; "
        "\" result\": End 1\n"
        "    If captureStartTestEnabled() <> expectedEnabled Then Print caseName; "
        "\" enabled\": End 2\n"
        "    If captureStartTestContext() <> expectedContext Then Print caseName; "
        "\" context\": End 3\n"
        "    If captureStartTestLocks() <> expectedLocks Then Print caseName; "
        "\" locks\": End 4\n"
        "    If captureStartTestUnlocks() <> expectedLocks Then Print caseName; "
        "\" unlocks\": End 5\n"
        "    If captureStartTestDriverChecks() <> expectedDriverChecks Then Print caseName; "
        "\" driver checks\": End 6\n"
        "    If captureStartTestDriverKind() <> expectedDriverKind Then Print caseName; "
        "\" driver kind\": End 7\n"
        "    If captureStartTestPlatformStarts() <> expectedPlatformStarts Then Print caseName; "
        "\" platform starts\": End 8\n"
        "    If expectedDriverChecks > 0 AndAlso captureStartTestCheckDepth() <> 1 Then Print caseName; "
        "\" driver check outside lock\": End 9\n"
        "    If expectedPlatformStarts > 0 AndAlso captureStartTestStartDepth() <> 0 Then Print caseName; "
        "\" platform callback under lock\": End 10\n"
        "    If captureStartTestDebugCalls() <> expectedDebugCalls Then Print caseName; "
        "\" debug calls\": End 11\n"
        "    If captureStartTestStringCompare(captureStartTestDebugText(), "
        "expectedDebugText) <> 0 Then Print caseName; \" debug text\": End 12\n"
        "End Sub\n"
        "Private Sub checkCaptureRunning(ByVal caseName As Const ZString Ptr, "
        "ByVal hasContext As Long, ByVal enabled As Long, ByVal expected As Long)\n"
        "    captureStartTestReset(hasContext, 0, enabled, 0, 0, 0, 0)\n"
        "    If queryCaptureRunning() <> expected Then Print caseName; "
        "\" running\": End 13\n"
        "End Sub\n"
        "Function main() As Integer\n"
        "    checkCaptureStartCase(\"not initialized\", 1, 0, 0, 1, 0, 0, 1, "
        "-1, 0, 1, 0, 0, -1, 0, 0, StrPtr(!\"\"))\n"
        "    checkCaptureStartCase(\"already running\", 1, 1, 1, 1, 0, 0, 0, "
        "0, 1, 1, 1, 0, -1, 0, 0, StrPtr(!\"\"))\n"
        "    checkCaptureStartCase(\"null driver\", 1, 1, 0, 2, 0, 0, 0, "
        "0, 1, 1, 1, 1, 2, 0, 0, StrPtr(!\"\"))\n"
        "    checkCaptureStartCase(\"real driver success\", 1, 1, 0, 1, 0, 0, 0, "
        "0, 1, 1, 2, 1, 1, 1, 0, StrPtr(!\"\"))\n"
        "    checkCaptureStartCase(\"real driver failure\", 1, 1, 0, 1, -1, 0, 1, "
        "-1, 0, 1, 1, 1, 1, 1, 1, "
        "StrPtr(!\"sfx_capture_start: failed to initialize capture device\"))\n"
        "    checkCaptureStartCase(\"context cleared during start\", 1, 1, 0, 1, 0, 1, 0, "
        "0, 0, 0, 2, 1, 1, 1, 0, StrPtr(!\"\"))\n"
        "    checkCaptureRunning(\"missing context\", 0, 1, 0)\n"
        "    checkCaptureRunning(\"stopped\", 1, 0, 0)\n"
        "    checkCaptureRunning(\"running\", 1, 1, 1)\n"
        "    checkCaptureRunning(\"paused\", 1, 2, 0)\n"
        '    Print "SFX CAPTURE START cases passed"\n'
        "    Return 0\n"
        "End Function\n"
        "End main()\n"
    )

    expected_output = "SFX CAPTURE START cases passed\n"
    observed = {}
    implementations = (
        ("C reference", reference_object, "fb_sfxCaptureStartC", "fb_sfxCaptureRunningC"),
        ("C2FB candidate", candidate_object, "fb_sfxCaptureStart", "fb_sfxCaptureRunning"),
        ("integrated Basic", basic_object, "fb_sfxCaptureStart", "fb_sfxCaptureRunning"),
    )
    for label, implementation_object, start_alias, running_alias in implementations:
        driver_source = work / (
            "sfx_capture_start_driver_" + label.lower().replace(" ", "_") + ".bas"
        )
        driver_source.write_text(
            basic_driver.replace("@CAPTURE_START_ALIAS@", start_alias)
            .replace("@CAPTURE_RUNNING_ALIAS@", running_alias)
        )
        executable = work / (
            "sfx_capture_start_" + label.lower().replace(" ", "_")
        )
        run(fbc + [
            "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
            str(driver_source), str(implementation_object), str(support_object),
            "-x", str(executable),
        ], cwd=work)
        observed[label] = run([str(executable)], cwd=work)

    if any(output != expected_output for output in observed.values()):
        raise AssertionError(
            "SFX CAPTURE START behavior differs from C: "
            f"expected={expected_output!r}, observed={observed}"
        )
    print(
        "SFX CAPTURE START: C2FB candidate and integrated Basic match C for "
        "initialization, running state, null/real driver paths, failures, and debug"
    )


def check_sfx_access(fbc, cc, source_root, basic_object,
                     candidate_object, work):
    sfx_directory = source_root / "sfxlib"
    rtlib_directory = source_root / "rtlib"
    c_layout_source = work / "sfx_access_driver_layout.c"
    c_layout_source.write_text(
        "#include <stddef.h>\n"
        "#include <stdio.h>\n"
        '#include "fb_sfx_driver.h"\n'
        "int main(void) {\n"
        '    printf("%zu %zu", offsetof(SFXDRIVER, poll), sizeof(void *));\n'
        "    return 0;\n"
        "}\n"
    )
    c_layout_executable = work / "sfx_access_driver_layout_c"
    run(cc + [
        "-std=c99", f"-I{sfx_directory}", f"-I{rtlib_directory}",
        str(c_layout_source), "-o", str(c_layout_executable),
    ], cwd=work)

    basic_layout_source = work / "sfx_access_driver_layout.bas"
    basic_layout_source.write_text(
        '#include once "fb_sfx_c_prefix.bi"\n'
        "Dim driver As SfxDriverPollPrefix\n"
        'Print CULngInt(@driver.pollCallback)-CULngInt(@driver); " "; SizeOf(Any Ptr)\n'
    )
    basic_layout_executable = work / "sfx_access_driver_layout_basic"
    run(fbc + [
        "-w", "all", "-i", str(source_root.parent / "inc"),
        "-i", str(sfx_directory), str(basic_layout_source),
        "-x", str(basic_layout_executable),
    ], cwd=work)
    c_layout = run([str(c_layout_executable)], cwd=work).split()
    basic_layout = run([str(basic_layout_executable)], cwd=work).split()
    if c_layout != basic_layout:
        raise AssertionError(
            f"SFX driver-poll prefix differs: C={c_layout}, FreeBASIC={basic_layout}"
        )

    support_source = work / "sfx_access_support.c"
    support_source.write_text(
        '#include "fb_sfx.h"\n'
        '#include "fb_sfx_internal.h"\n'
        '#include "fb_sfx_driver.h"\n'
        "#include <stdarg.h>\n"
        "#include <stdio.h>\n"
        "#include <string.h>\n"
        "static FB_SFXCTX g_context;\n"
        "static SFXDRIVER g_driver_with_poll;\n"
        "static SFXDRIVER g_driver_without_poll;\n"
        "FB_SFXCTX *__fb_sfx;\n"
        "static int g_init_result, g_debug_enabled, g_init_calls;\n"
        "static int g_lock_calls, g_unlock_calls, g_lock_depth;\n"
        "static int g_poll_calls, g_poll_depth, g_debug_calls;\n"
        "static char g_debug_text[128];\n"
        "static void fb_sfxAccessTestPoll(void) {\n"
        "    ++g_poll_calls; g_poll_depth = g_lock_depth;\n"
        "}\n"
        "void fb_sfxAccessTestReset(int init_result, int has_context, "
        "int driver_kind, int debug_enabled) {\n"
        "    memset(&g_context, 0, sizeof(g_context));\n"
        "    memset(&g_driver_with_poll, 0, sizeof(g_driver_with_poll));\n"
        "    memset(&g_driver_without_poll, 0, sizeof(g_driver_without_poll));\n"
        '    g_driver_with_poll.name = "poll";\n'
        '    g_driver_without_poll.name = "no-poll";\n'
        "    g_driver_with_poll.poll = fb_sfxAccessTestPoll;\n"
        "    if (driver_kind == 1) g_context.driver = &g_driver_with_poll;\n"
        "    else if (driver_kind == 2) g_context.driver = &g_driver_without_poll;\n"
        "    else g_context.driver = NULL;\n"
        "    __fb_sfx = has_context ? &g_context : NULL;\n"
        "    g_init_result = init_result; g_debug_enabled = debug_enabled;\n"
        "    g_init_calls = g_lock_calls = g_unlock_calls = g_lock_depth = 0;\n"
        "    g_poll_calls = g_debug_calls = 0; g_poll_depth = -1;\n"
        "    g_debug_text[0] = 0;\n"
        "}\n"
        "int fb_sfxEnsureInit(void) { ++g_init_calls; return g_init_result; }\n"
        "int fb_sfxDebugEnabled(void) { return g_debug_enabled; }\n"
        "void fb_sfxDebugLog(const char *format, ...) {\n"
        "    va_list arguments; ++g_debug_calls;\n"
        "    va_start(arguments, format);\n"
        "    vsnprintf(g_debug_text, sizeof(g_debug_text), format, arguments);\n"
        "    va_end(arguments);\n"
        "}\n"
        "void fb_sfxRuntimeLock(void) { ++g_lock_calls; ++g_lock_depth; }\n"
        "void fb_sfxRuntimeUnlock(void) { ++g_unlock_calls; --g_lock_depth; }\n"
        "int fb_sfxAccessTestInitCalls(void) { return g_init_calls; }\n"
        "int fb_sfxAccessTestContext(void) { return __fb_sfx != NULL; }\n"
        "int fb_sfxAccessTestLockCalls(void) { return g_lock_calls; }\n"
        "int fb_sfxAccessTestUnlockCalls(void) { return g_unlock_calls; }\n"
        "int fb_sfxAccessTestPollCalls(void) { return g_poll_calls; }\n"
        "int fb_sfxAccessTestPollDepth(void) { return g_poll_depth; }\n"
        "int fb_sfxAccessTestDebugCalls(void) { return g_debug_calls; }\n"
        "const char *fb_sfxAccessTestDebugText(void) { return g_debug_text; }\n"
    )
    support_object = work / "sfx_access_support.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror", "-DFB_NO_GFXLIB",
        f"-I{sfx_directory}", f"-I{rtlib_directory}",
        "-c", str(support_source), "-o", str(support_object),
    ], cwd=work)

    reference_object = work / "sfx_access_c_reference.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror", "-DFB_NO_GFXLIB",
        "-Dfb_sfxEnsureInitialized=fb_sfxEnsureInitializedC",
        "-Dfb_sfxGetContext=fb_sfxGetContextC",
        "-Dfb_sfxPoll=fb_sfxPollC",
        f"-I{sfx_directory}", f"-I{rtlib_directory}",
        "-c", str(sfx_directory / "sfx_access.c"),
        "-o", str(reference_object),
    ], cwd=work)

    basic_driver = (
        '#lang "fb"\n'
        'Declare Function ensureInitialized CDecl Alias "@ENSURE_ALIAS@" () As Long\n'
        'Declare Function getContext CDecl Alias "@CONTEXT_ALIAS@" () As Any Ptr\n'
        'Declare Sub pollDriver CDecl Alias "@POLL_ALIAS@" ()\n'
        'Declare Sub accessTestReset CDecl Alias "fb_sfxAccessTestReset" '
        "(ByVal initResult As Long, ByVal hasContext As Long, "
        "ByVal driverKind As Long, ByVal debugEnabled As Long)\n"
        'Declare Function accessTestInitCalls CDecl Alias "fb_sfxAccessTestInitCalls" () As Long\n'
        'Declare Function accessTestContext CDecl Alias "fb_sfxAccessTestContext" () As Long\n'
        'Declare Function accessTestLockCalls CDecl Alias "fb_sfxAccessTestLockCalls" () As Long\n'
        'Declare Function accessTestUnlockCalls CDecl Alias "fb_sfxAccessTestUnlockCalls" () As Long\n'
        'Declare Function accessTestPollCalls CDecl Alias "fb_sfxAccessTestPollCalls" () As Long\n'
        'Declare Function accessTestPollDepth CDecl Alias "fb_sfxAccessTestPollDepth" () As Long\n'
        'Declare Function accessTestDebugCalls CDecl Alias "fb_sfxAccessTestDebugCalls" () As Long\n'
        'Declare Function accessTestDebugText CDecl Alias "fb_sfxAccessTestDebugText" () As Const ZString Ptr\n'
        'Declare Function accessTestStringCompare CDecl Alias "strcmp" '
        "(ByVal leftText As Const ZString Ptr, ByVal rightText As Const ZString Ptr) As Long\n"
        "Private Sub checkAccessCase(ByVal caseName As Const ZString Ptr, "
        "ByVal initResult As Long, ByVal hasContext As Long, "
        "ByVal driverKind As Long, ByVal debugEnabled As Long, "
        "ByVal expectedEnsure As Long, ByVal expectedContext As Long, "
        "ByVal expectedInitCalls As Long, ByVal expectedLocks As Long, "
        "ByVal expectedPolls As Long, ByVal expectedPollDepth As Long, "
        "ByVal expectedDebugCalls As Long, ByVal expectedDebugText As Const ZString Ptr)\n"
        "    accessTestReset(initResult, hasContext, driverKind, debugEnabled)\n"
        "    If ensureInitialized() <> expectedEnsure Then Print caseName; "
        "\" ensure\": End 1\n"
        "    If (getContext() <> 0) <> (expectedContext <> 0) Then Print caseName; "
        "\" context\": End 2\n"
        "    pollDriver()\n"
        "    If accessTestInitCalls() <> expectedInitCalls Then Print caseName; "
        "\" init calls\": End 3\n"
        "    If accessTestLockCalls() <> expectedLocks Then Print caseName; "
        "\" lock calls\": End 4\n"
        "    If accessTestUnlockCalls() <> expectedLocks Then Print caseName; "
        "\" unlock calls\": End 5\n"
        "    If accessTestPollCalls() <> expectedPolls Then Print caseName; "
        "\" poll calls\": End 6\n"
        "    If accessTestPollDepth() <> expectedPollDepth Then Print caseName; "
        "\" poll lock depth\": End 7\n"
        "    If accessTestDebugCalls() <> expectedDebugCalls Then Print caseName; "
        "\" debug calls\": End 8\n"
        "    If accessTestStringCompare(accessTestDebugText(), expectedDebugText) <> 0 Then "
        "Print caseName; \" debug text\": End 9\n"
        "End Sub\n"
        "Function main() As Integer\n"
        "    checkAccessCase(\"driver poll\", 0, 1, 1, 0, 1, 1, 3, 1, 1, 1, 0, StrPtr(!\"\"))\n"
        "    checkAccessCase(\"initialization failure\", 1, 1, 1, 1, 0, 0, 3, 0, 0, -1, 3, "
        "StrPtr(!\"sfx_access: sound subsystem initialization failed\"))\n"
        "    checkAccessCase(\"no driver\", 0, 1, 0, 0, 1, 1, 3, 1, 0, -1, 0, StrPtr(!\"\"))\n"
        "    checkAccessCase(\"driver without poll\", 0, 1, 2, 0, 1, 1, 3, 1, 0, -1, 0, StrPtr(!\"\"))\n"
        '    Print "SFX access cases passed"\n'
        "    Return 0\n"
        "End Function\n"
        "End main()\n"
    )
    expected_output = "SFX access cases passed\n"
    observed = {}
    implementations = (
        ("C reference", reference_object, "fb_sfxEnsureInitializedC", "fb_sfxGetContextC", "fb_sfxPollC"),
        ("C2FB candidate", candidate_object, "fb_sfxEnsureInitialized", "fb_sfxGetContext", "fb_sfxPoll"),
        ("integrated Basic", basic_object, "fb_sfxEnsureInitialized", "fb_sfxGetContext", "fb_sfxPoll"),
    )
    for label, implementation_object, ensure_alias, context_alias, poll_alias in implementations:
        driver_source = work / (
            "sfx_access_driver_" + label.lower().replace(" ", "_") + ".bas"
        )
        driver_source.write_text(
            basic_driver.replace("@ENSURE_ALIAS@", ensure_alias)
            .replace("@CONTEXT_ALIAS@", context_alias)
            .replace("@POLL_ALIAS@", poll_alias)
        )
        executable = work / (
            "sfx_access_" + label.lower().replace(" ", "_")
        )
        run(fbc + [
            "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
            str(driver_source), str(implementation_object), str(support_object),
            "-x", str(executable),
        ], cwd=work)
        observed[label] = run([str(executable)], cwd=work)

    if any(output != expected_output for output in observed.values()):
        raise AssertionError(
            "SFX access behavior differs from C: "
            f"expected={expected_output!r}, observed={observed}"
        )
    print(
        "SFX access: C2FB candidate and integrated Basic match C for "
        "initialization, context access, driver polling, lock depth, and debug"
    )


def check_sfx_buffer_behavior(fbc, cc, source_root, basic_object,
                              candidate_object, work):
    sfx_directory = source_root / "sfxlib"
    probe_source = work / "sfx_buffer_probe.c"
    probe_source.write_text(
        "#include <limits.h>\n"
        "#include <stdarg.h>\n"
        "#include <stdio.h>\n"
        "#include <string.h>\n"
        '#include "fb_sfx_internal.h"\n'
        "FB_SFXCTX *__fb_sfx;\n"
        "static int debug_enabled;\n"
        "static char debug_message[128];\n"
        "int fb_sfxDebugEnabled(void) { return debug_enabled; }\n"
        "void fb_sfxDebugLog(const char *format, ...) {\n"
        "    va_list args;\n"
        "    va_start(args, format);\n"
        "    vsnprintf(debug_message, sizeof(debug_message), format, args);\n"
        "    va_end(args);\n"
        "}\n"
        "static void print_samples(const char *label, const float *values,\n"
        "                          int count) {\n"
        "    int i;\n"
        "    printf(\"%s\", label);\n"
        "    for (i = 0; i < count; ++i)\n"
        "        printf(\"|%a\", (double)values[i]);\n"
        "    putchar('\\n');\n"
        "}\n"
        "int main(void) {\n"
        "    FB_SFXCTX context;\n"
        "    const float input[8] = {\n"
        "        0.125f, -0.25f, 0.5f, -0.75f,\n"
        "        1.0f, -1.0f, 0.375f, -0.5f\n"
        "    };\n"
        "    float output[8] = {0};\n"
        "    int result;\n"
        "\n"
        "    memset(&context, 0, sizeof(context));\n"
        "    __fb_sfx = NULL;\n"
        "    result = fb_sfxBufferInit(4);\n"
        "    printf(\"no-context|%d|%d|%d|%d|%a\\n\", result,\n"
        "           fb_sfxBufferFrames(), fb_sfxBufferSamples(),\n"
        "           fb_sfxBufferPtr() != NULL,\n"
        "           (double)fb_sfxBufferRead(0));\n"
        "    result = fb_sfxMixBufferRead(output, 2);\n"
        "    printf(\"no-context-read|%d\\n\", result);\n"
        "    print_samples(\"no-context-samples\", output, 4);\n"
        "    result = fb_sfxMixBufferWrite(input, 2);\n"
        "    printf(\"no-context-write|%d\\n\", result);\n"
        "\n"
        "    __fb_sfx = &context;\n"
        "    context.output_channels = 2;\n"
        "    context.buffer_size = 4;\n"
        "    debug_enabled = 1;\n"
        "    result = fb_sfxBufferInit(4);\n"
        "    printf(\"initialized|%d|%d|%d|%d|%s\\n\", result,\n"
        "           fb_sfxBufferFrames(), fb_sfxBufferSamples(),\n"
        "           fb_sfxBufferPtr() != NULL, debug_message);\n"
        "    print_samples(\"initial-samples\", context.mixbuffer, 8);\n"
        "\n"
        "    fb_sfxBufferWrite(-1, 0.25f);\n"
        "    fb_sfxBufferWrite(0, 0.25f);\n"
        "    fb_sfxBufferWrite(7, -0.75f);\n"
        "    fb_sfxBufferWrite(8, 0.5f);\n"
        "    printf(\"indexed-read|%a|%a|%a\\n\",\n"
        "           (double)fb_sfxBufferRead(-1),\n"
        "           (double)fb_sfxBufferRead(0),\n"
        "           (double)fb_sfxBufferRead(8));\n"
        "\n"
        "    result = fb_sfxMixBufferWrite(input, 4);\n"
        "    printf(\"frame-write|%d\\n\", result);\n"
        "    result = fb_sfxMixBufferRead(output, 4);\n"
        "    printf(\"frame-read|%d\\n\", result);\n"
        "    print_samples(\"frame-samples\", output, 8);\n"
        "\n"
        "    printf(\"invalid-init|%d|%d|%d\\n\",\n"
        "           fb_sfxBufferInit(0), fb_sfxBufferInit(INT_MAX),\n"
        "           fb_sfxBufferFrames());\n"
        "    fb_sfxBufferClear();\n"
        "    print_samples(\"cleared-samples\", context.mixbuffer, 8);\n"
        "\n"
        "    fb_sfxBufferShutdown();\n"
        "    printf(\"shutdown|%d|%d|%d|%s\\n\",\n"
        "           fb_sfxBufferFrames(), fb_sfxBufferSamples(),\n"
        "           fb_sfxBufferPtr() != NULL, debug_message);\n"
        "    fb_sfxMixBufferInit();\n"
        "    printf(\"mix-init|%d|%d\\n\",\n"
        "           fb_sfxBufferFrames(), fb_sfxBufferSamples());\n"
        "    fb_sfxMixBufferShutdown();\n"
        "    printf(\"mix-shutdown|%d|%d\\n\",\n"
        "           fb_sfxBufferFrames(), fb_sfxBufferPtr() != NULL);\n"
        "    return 0;\n"
        "}\n"
    )

    renamed_symbols = (
        "fb_sfxBufferInit=cReferenceSfxBufferInit",
        "fb_sfxBufferShutdown=cReferenceSfxBufferShutdown",
        "fb_sfxBufferClear=cReferenceSfxBufferClear",
        "fb_sfxBufferPtr=cReferenceSfxBufferPtr",
        "fb_sfxBufferFrames=cReferenceSfxBufferFrames",
        "fb_sfxBufferSamples=cReferenceSfxBufferSamples",
        "fb_sfxBufferWrite=cReferenceSfxBufferWrite",
        "fb_sfxBufferRead=cReferenceSfxBufferRead",
        "fb_sfxMixBufferInit=cReferenceSfxMixBufferInit",
        "fb_sfxMixBufferShutdown=cReferenceSfxMixBufferShutdown",
        "fb_sfxMixBufferWrite=cReferenceSfxMixBufferWrite",
        "fb_sfxMixBufferRead=cReferenceSfxMixBufferRead",
    )
    rename_options = ["-D" + symbol for symbol in renamed_symbols]

    reference_object = work / "sfx_buffer_reference.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", *rename_options,
        "-c", str(sfx_directory / "sfx_buffer.c"),
        "-o", str(reference_object),
    ], cwd=work)

    reference_probe = work / "sfx_buffer_reference_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", *rename_options,
        "-c", str(probe_source), "-o", str(reference_probe),
    ], cwd=work)
    reference_executable = work / "sfx_buffer_reference"
    run(cc + [
        str(reference_object), str(reference_probe),
        "-o", str(reference_executable),
    ], cwd=work)
    expected = run([str(reference_executable)], cwd=work)

    probe_object = work / "sfx_buffer_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", "-c", str(probe_source),
        "-o", str(probe_object),
    ], cwd=work)

    for implementation, object_path in (
        ("C2FB candidate", candidate_object),
        ("integrated Basic", basic_object),
    ):
        executable = work / (
            "sfx_buffer_" + implementation.lower().replace(" ", "_")
        )
        run(fbc + [
            "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
            str(object_path), str(probe_object), "-x", str(executable),
        ], cwd=work)
        observed = run([str(executable)], cwd=work)
        if observed != expected:
            raise AssertionError(
                f"SFX buffer behavior differs for {implementation}: "
                f"C={expected!r}, observed={observed!r}"
            )

    print(
        "SFX buffer: C2FB candidate and integrated Basic match C for "
        "allocation, size checks, sample bounds, frame access, clear, and "
        "shutdown"
    )


def check_sfx_envelope_behavior(fbc, cc, source_root, basic_object,
                                candidate_object, work):
    sfx_directory = source_root / "sfxlib"
    probe_source = work / "sfx_envelope_probe.c"
    probe_source.write_text(
        "#include <stdio.h>\n"
        "#include <stdarg.h>\n"
        "#include <string.h>\n"
        '#include "fb_sfx_internal.h"\n'
        "FB_SFXCTX *__fb_sfx;\n"
        "static int debug_enabled;\n"
        "static char debug_message[128];\n"
        "int fb_sfxDebugEnabled(void) { return debug_enabled; }\n"
        "void fb_sfxDebugLog(const char *format, ...) {\n"
        "    va_list args;\n"
        "    va_start(args, format);\n"
        "    vsnprintf(debug_message, sizeof(debug_message), format, args);\n"
        "    va_end(args);\n"
        "}\n"
        "static void print_voice(const char *label, FB_SFXVOICE *voice,\n"
        "                        float result) {\n"
        "    printf(\"%s|%a|%d|%a|%d|%d\\n\", label,\n"
        "           (double)result, voice->env_state,\n"
        "           (double)voice->env_level, voice->active,\n"
        "           voice->env_time);\n"
        "}\n"
        "int main(void) {\n"
        "    FB_SFXCTX context;\n"
        "    FB_SFXVOICE voice;\n"
        "    float result;\n"
        "\n"
        "    memset(&context, 0, sizeof(context));\n"
        "    memset(&voice, 0, sizeof(voice));\n"
        "    __fb_sfx = NULL;\n"
        "    voice.envelope = 1;\n"
        "    voice.env_state = 7;\n"
        "    voice.env_level = 0.4f;\n"
        "    voice.env_time = 9;\n"
        "    fb_sfxEnvelopeInit();\n"
        "    fb_sfxEnvelopeDefine(1, 0.5f, 0.25f, 0.5f, 0.75f);\n"
        "    fb_sfxVoiceSetEnvelope(&voice, 3);\n"
        "    fb_sfxEnvelopeRelease(&voice);\n"
        "    result = fb_sfxEnvelopeProcess(&voice, 0.1f);\n"
        "    print_voice(\"no-context\", &voice, result);\n"
        "\n"
        "    __fb_sfx = &context;\n"
        "    debug_enabled = 1;\n"
        "    fb_sfxEnvelopeInit();\n"
        "    printf(\"defaults|%d|%a|%a|%a|%a|%d|%a|%a|%a|%a\\n\",\n"
        "           context.envelopes[0].defined,\n"
        "           (double)context.envelopes[0].attack,\n"
        "           (double)context.envelopes[0].decay,\n"
        "           (double)context.envelopes[0].sustain,\n"
        "           (double)context.envelopes[0].release,\n"
        "           context.envelopes[15].defined,\n"
        "           (double)context.envelopes[15].attack,\n"
        "           (double)context.envelopes[15].decay,\n"
        "           (double)context.envelopes[15].sustain,\n"
        "           (double)context.envelopes[15].release);\n"
        "    printf(\"init-debug|%s\\n\", debug_message);\n"
        "\n"
        "    fb_sfxEnvelopeDefine(1, -0.5f, -0.25f, 1.5f, -0.75f);\n"
        "    printf(\"clamped|%a|%a|%a|%a|%s\\n\",\n"
        "           (double)context.envelopes[1].attack,\n"
        "           (double)context.envelopes[1].decay,\n"
        "           (double)context.envelopes[1].sustain,\n"
        "           (double)context.envelopes[1].release, debug_message);\n"
        "    fb_sfxEnvelopeDefine(1, 0.5f, 0.25f, 0.5f, 0.75f);\n"
        "\n"
        "    voice.active = 1;\n"
        "    voice.envelope = 9;\n"
        "    voice.env_state = 7;\n"
        "    voice.env_level = 0.8f;\n"
        "    voice.env_time = 55;\n"
        "    fb_sfxVoiceSetEnvelope(&voice, 1);\n"
        "    printf(\"assigned|%d|%d|%a|%d|%s\\n\",\n"
        "           voice.envelope, voice.env_state,\n"
        "           (double)voice.env_level, voice.env_time, debug_message);\n"
        "    fb_sfxVoiceSetEnvelope(&voice, FB_SFX_MAX_ENVELOPES);\n"
        "    fb_sfxVoiceSetEnvelope(NULL, 0);\n"
        "    printf(\"invalid-assign|%d|%d|%a|%d\\n\",\n"
        "           voice.envelope, voice.env_state,\n"
        "           (double)voice.env_level, voice.env_time);\n"
        "\n"
        "    voice.env_level = 0.0f;\n"
        "    voice.env_state = FB_SFX_ENV_ATTACK;\n"
        "    result = fb_sfxEnvelopeProcess(&voice, 0.125f);\n"
        "    print_voice(\"attack-step\", &voice, result);\n"
        "    result = fb_sfxEnvelopeProcess(&voice, 0.5f);\n"
        "    print_voice(\"attack-complete\", &voice, result);\n"
        "    result = fb_sfxEnvelopeProcess(&voice, 0.125f);\n"
        "    print_voice(\"decay-step\", &voice, result);\n"
        "    result = fb_sfxEnvelopeProcess(&voice, 0.125f);\n"
        "    print_voice(\"decay-complete\", &voice, result);\n"
        "    result = fb_sfxEnvelopeProcess(&voice, 0.25f);\n"
        "    print_voice(\"sustain\", &voice, result);\n"
        "    fb_sfxEnvelopeRelease(&voice);\n"
        "    result = fb_sfxEnvelopeProcess(&voice, 0.125f);\n"
        "    print_voice(\"release-step\", &voice, result);\n"
        "    result = fb_sfxEnvelopeProcess(&voice, 0.25f);\n"
        "    print_voice(\"release-complete\", &voice, result);\n"
        "\n"
        "    fb_sfxEnvelopeDefine(2, 0.0f, 0.0f, 1.0f, 0.0f);\n"
        "    voice.active = 1;\n"
        "    fb_sfxVoiceSetEnvelope(&voice, 2);\n"
        "    result = fb_sfxEnvelopeProcess(&voice, 0.0f);\n"
        "    print_voice(\"zero-attack\", &voice, result);\n"
        "    result = fb_sfxEnvelopeProcess(&voice, 0.0f);\n"
        "    print_voice(\"zero-decay\", &voice, result);\n"
        "    fb_sfxEnvelopeRelease(&voice);\n"
        "    result = fb_sfxEnvelopeProcess(&voice, 0.0f);\n"
        "    print_voice(\"zero-release\", &voice, result);\n"
        "\n"
        "    voice.envelope = -1;\n"
        "    voice.env_state = FB_SFX_ENV_ATTACK;\n"
        "    voice.env_level = 0.75f;\n"
        "    voice.active = 1;\n"
        "    result = fb_sfxEnvelopeProcess(&voice, 0.1f);\n"
        "    print_voice(\"negative-id\", &voice, result);\n"
        "    voice.envelope = FB_SFX_MAX_ENVELOPES;\n"
        "    result = fb_sfxEnvelopeProcess(&voice, 0.1f);\n"
        "    print_voice(\"large-id\", &voice, result);\n"
        "    voice.envelope = 1;\n"
        "    voice.env_state = 99;\n"
        "    voice.env_level = 0.375f;\n"
        "    result = fb_sfxEnvelopeProcess(&voice, 0.1f);\n"
        "    print_voice(\"unknown-state\", &voice, result);\n"
        "    return 0;\n"
        "}\n"
    )

    renamed_symbols = (
        "fb_sfxEnvelopeInit=cReferenceSfxEnvelopeInit",
        "fb_sfxEnvelopeDefine=cReferenceSfxEnvelopeDefine",
        "fb_sfxVoiceSetEnvelope=cReferenceSfxVoiceSetEnvelope",
        "fb_sfxEnvelopeRelease=cReferenceSfxEnvelopeRelease",
        "fb_sfxEnvelopeProcess=cReferenceSfxEnvelopeProcess",
    )
    rename_options = ["-D" + symbol for symbol in renamed_symbols]

    reference_object = work / "sfx_envelope_reference.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", *rename_options,
        "-c", str(sfx_directory / "sfx_envelope.c"),
        "-o", str(reference_object),
    ], cwd=work)

    reference_probe = work / "sfx_envelope_reference_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", *rename_options,
        "-c", str(probe_source), "-o", str(reference_probe),
    ], cwd=work)
    reference_executable = work / "sfx_envelope_reference"
    run(cc + [
        str(reference_object), str(reference_probe),
        "-o", str(reference_executable),
    ], cwd=work)
    expected = run([str(reference_executable)], cwd=work)

    probe_object = work / "sfx_envelope_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", "-c", str(probe_source),
        "-o", str(probe_object),
    ], cwd=work)

    for implementation, object_path in (
        ("C2FB candidate", candidate_object),
        ("integrated Basic", basic_object),
    ):
        executable = work / (
            "sfx_envelope_" + implementation.lower().replace(" ", "_")
        )
        run(fbc + [
            "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
            str(object_path), str(probe_object), "-x", str(executable),
        ], cwd=work)
        observed = run([str(executable)], cwd=work)
        if observed != expected:
            raise AssertionError(
                f"SFX envelope behavior differs for {implementation}: "
                f"C={expected!r}, observed={observed!r}"
            )

    print(
        "SFX envelope: C2FB candidate and integrated Basic match C for "
        "defaults, clamps, voice assignment, ADSR phases, zero times, and "
        "invalid voice envelope IDs"
    )


def check_sfx_instrument_behavior(fbc, cc, source_root, basic_object,
                                 candidate_object, work):
    sfx_directory = source_root / "sfxlib"
    probe_source = work / "sfx_instrument_probe.c"
    probe_source.write_text(
        "#include <stdio.h>\n"
        "#include <stdarg.h>\n"
        "#include <string.h>\n"
        '#include "fb_sfx_internal.h"\n'
        "FB_SFXCTX *__fb_sfx;\n"
        "static int ready;\n"
        "static int debug_enabled;\n"
        "static char debug_message[128];\n"
        "int fb_sfxEnsureInitialized(void) { return ready; }\n"
        "int fb_sfxDebugEnabled(void) { return debug_enabled; }\n"
        "void fb_sfxDebugLog(const char *format, ...) {\n"
        "    va_list args;\n"
        "    va_start(args, format);\n"
        "    vsnprintf(debug_message, sizeof(debug_message), format, args);\n"
        "    va_end(args);\n"
        "}\n"
        "void fb_sfxVoiceSetWaveform(FB_SFXVOICE *voice, int waveform) {\n"
        "    if (!voice) return;\n"
        "    voice->waveform = waveform;\n"
        "    if (fb_sfxDebugEnabled())\n"
        "        fb_sfxDebugLog(\"sfx_waveform: voice waveform set to %d\",\n"
        "                       waveform);\n"
        "}\n"
        "void fb_sfxVoiceSetEnvelope(FB_SFXVOICE *voice, int id) {\n"
        "    if (!voice || !__fb_sfx || id < 0 ||\n"
        "        id >= FB_SFX_MAX_ENVELOPES) return;\n"
        "    voice->envelope = id;\n"
        "    voice->env_state = FB_SFX_ENV_ATTACK;\n"
        "    voice->env_level = 0.0f;\n"
        "    voice->env_time = 0;\n"
        "    if (fb_sfxDebugEnabled())\n"
        "        fb_sfxDebugLog(\"sfx_envelope: voice assigned envelope %d\",\n"
        "                       id);\n"
        "}\n"
        "static void print_voice(const char *label, FB_SFXVOICE *voice) {\n"
        "    printf(\"%s|%d|%d|%d|%a|%d\\n\", label,\n"
        "           voice->waveform, voice->envelope, voice->env_state,\n"
        "           (double)voice->env_level, voice->env_time);\n"
        "}\n"
        "int main(void) {\n"
        "    FB_SFXCTX context;\n"
        "    FB_SFXVOICE voice;\n"
        "    int i;\n"
        "\n"
        "    memset(&context, 0, sizeof(context));\n"
        "    memset(&voice, 0, sizeof(voice));\n"
        "    __fb_sfx = NULL;\n"
        "    ready = 0;\n"
        "    voice.waveform = 8;\n"
        "    voice.envelope = 7;\n"
        "    voice.env_state = 9;\n"
        "    voice.env_level = 0.5f;\n"
        "    voice.env_time = 4;\n"
        "    fb_sfxInstrumentDefine(1, 2, 3);\n"
        "    fb_sfxInstrumentAssign(0, 1);\n"
        "    printf(\"no-context|%d\\n\", fb_sfxInstrumentDefined(1));\n"
        "    fb_sfxInstrumentApply(&voice, 0, 3, 2);\n"
        "    print_voice(\"apply-no-context\", &voice);\n"
        "\n"
        "    __fb_sfx = &context;\n"
        "    ready = 1;\n"
        "    debug_enabled = 1;\n"
        "    for (i = 0; i < FB_SFX_MAX_INSTRUMENTS; ++i)\n"
        "        context.instruments[i].defined = 1;\n"
        "    fb_sfxInstrumentReset();\n"
        "    printf(\"reset|%d|%d|%s\\n\",\n"
        "           fb_sfxInstrumentDefined(0),\n"
        "           fb_sfxInstrumentDefined(FB_SFX_MAX_INSTRUMENTS - 1),\n"
        "           debug_message);\n"
        "\n"
        "    fb_sfxInstrumentDefine(1, -3, FB_SFX_MAX_ENVELOPES);\n"
        "    printf(\"definition|%d|%d|%d|%s\\n\",\n"
        "           fb_sfxInstrumentDefined(1),\n"
        "           context.instruments[1].wave_id,\n"
        "           context.instruments[1].env_id, debug_message);\n"
        "    fb_sfxInstrumentDefine(-1, 5, 6);\n"
        "    fb_sfxInstrumentDefine(FB_SFX_MAX_INSTRUMENTS, 5, 6);\n"
        "    printf(\"invalid-definition|%d|%d\\n\",\n"
        "           fb_sfxInstrumentDefined(-1),\n"
        "           fb_sfxInstrumentDefined(FB_SFX_MAX_INSTRUMENTS));\n"
        "\n"
        "    fb_sfxInstrumentDefine(2, 3, 2);\n"
        "    fb_sfxInstrumentAssign(0, 1);\n"
        "    fb_sfxInstrumentAssign(1, 2);\n"
        "    fb_sfxInstrumentAssign(-1, 1);\n"
        "    fb_sfxInstrumentAssign(FB_SFX_MAX_CHANNELS, 1);\n"
        "    fb_sfxInstrumentAssign(1, FB_SFX_MAX_INSTRUMENTS);\n"
        "    fb_sfxInstrumentAssign(1, 3);\n"
        "    printf(\"assignment|%d|%d|%s\\n\",\n"
        "           context.channels[0].instrument,\n"
        "           context.channels[1].instrument, debug_message);\n"
        "\n"
        "    context.waves[0].defined = 1;\n"
        "    context.waves[0].type = 2;\n"
        "    voice.waveform = 9;\n"
        "    voice.envelope = 8;\n"
        "    voice.env_state = 7;\n"
        "    voice.env_level = 0.6f;\n"
        "    voice.env_time = 41;\n"
        "    fb_sfxInstrumentApply(&voice, 0, 3, 4);\n"
        "    print_voice(\"default-and-wave\", &voice);\n"
        "    printf(\"apply-debug|%s\\n\", debug_message);\n"
        "\n"
        "    voice.waveform = 9;\n"
        "    voice.envelope = 9;\n"
        "    voice.env_state = 7;\n"
        "    voice.env_level = 0.4f;\n"
        "    voice.env_time = 12;\n"
        "    fb_sfxInstrumentApply(&voice, 1, 6, -1);\n"
        "    print_voice(\"undefined-wave-and-envelope\", &voice);\n"
        "\n"
        "    context.waves[3].defined = 1;\n"
        "    context.waves[3].type = 4;\n"
        "    context.envelopes[2].defined = 1;\n"
        "    fb_sfxInstrumentApply(&voice, 1, 0, 0);\n"
        "    print_voice(\"instrument-wave-and-envelope\", &voice);\n"
        "\n"
        "    voice.envelope = 11;\n"
        "    voice.env_state = 13;\n"
        "    voice.env_level = 0.3f;\n"
        "    voice.env_time = 17;\n"
        "    fb_sfxInstrumentApply(&voice, -1, 5, -1);\n"
        "    print_voice(\"invalid-channel\", &voice);\n"
        "    context.channels[1].instrument = 99;\n"
        "    fb_sfxInstrumentApply(&voice, 1, 7, -1);\n"
        "    print_voice(\"invalid-instrument-slot\", &voice);\n"
        "    fb_sfxInstrumentApply(NULL, 1, 1, 1);\n"
        "\n"
        "    fb_sfxInstrumentReset();\n"
        "    printf(\"final-reset|%d|%d|%s\\n\",\n"
        "           fb_sfxInstrumentDefined(1),\n"
        "           fb_sfxInstrumentDefined(2), debug_message);\n"
        "    return 0;\n"
        "}\n"
    )

    renamed_symbols = (
        "fb_sfxInstrumentDefine=cReferenceSfxInstrumentDefine",
        "fb_sfxInstrumentAssign=cReferenceSfxInstrumentAssign",
        "fb_sfxInstrumentApply=cReferenceSfxInstrumentApply",
        "fb_sfxInstrumentDefined=cReferenceSfxInstrumentDefined",
        "fb_sfxInstrumentReset=cReferenceSfxInstrumentReset",
    )
    rename_options = ["-D" + symbol for symbol in renamed_symbols]

    reference_object = work / "sfx_instrument_reference.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", *rename_options,
        "-c", str(sfx_directory / "sfx_instrument.c"),
        "-o", str(reference_object),
    ], cwd=work)

    reference_probe = work / "sfx_instrument_reference_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", *rename_options,
        "-c", str(probe_source), "-o", str(reference_probe),
    ], cwd=work)
    reference_executable = work / "sfx_instrument_reference"
    run(cc + [
        str(reference_object), str(reference_probe),
        "-o", str(reference_executable),
    ], cwd=work)
    expected = run([str(reference_executable)], cwd=work)

    probe_object = work / "sfx_instrument_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", "-c", str(probe_source),
        "-o", str(probe_object),
    ], cwd=work)

    for implementation, object_path in (
        ("C2FB candidate", candidate_object),
        ("integrated Basic", basic_object),
    ):
        executable = work / (
            "sfx_instrument_" + implementation.lower().replace(" ", "_")
        )
        run(fbc + [
            "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
            str(object_path), str(probe_object), "-x", str(executable),
        ], cwd=work)
        observed = run([str(executable)], cwd=work)
        if observed != expected:
            raise AssertionError(
                f"SFX instrument behavior differs for {implementation}: "
                f"C={expected!r}, observed={observed!r}"
            )

    print(
        "SFX instruments: C2FB candidate and integrated Basic match C for "
        "definition, validation, assignment, fallback, application, reset, "
        "and debug behavior"
    )


def check_sfx_waveform_behavior(fbc, cc, source_root, basic_object,
                                candidate_object, work):
    sfx_directory = source_root / "sfxlib"
    probe_source = work / "sfx_waveform_probe.c"
    probe_source.write_text(
        "#include <stdio.h>\n"
        "#include <stdarg.h>\n"
        "#include <stdlib.h>\n"
        "#include <string.h>\n"
        '#include "fb_sfx_internal.h"\n'
        "FB_SFXCTX *__fb_sfx;\n"
        "static int debug_enabled;\n"
        "static char debug_message[128];\n"
        "int fb_sfxDebugEnabled(void) { return debug_enabled; }\n"
        "void fb_sfxDebugLog(const char *format, ...) {\n"
        "    va_list args;\n"
        "    va_start(args, format);\n"
        "    vsnprintf(debug_message, sizeof(debug_message), format, args);\n"
        "    va_end(args);\n"
        "}\n"
        "static void set_voice(FB_SFXVOICE *voice, int waveform,\n"
        "                     float phase, int frequency) {\n"
        "    memset(voice, 0, sizeof(*voice));\n"
        "    voice->waveform = waveform;\n"
        "    voice->phase = phase;\n"
        "    voice->frequency = frequency;\n"
        "}\n"
        "static void print_result(const char *label, FB_SFXVOICE *voice,\n"
        "                        float sample) {\n"
        "    printf(\"%s|%a|%a|%a|%d|%a|%d|%d\\n\", label,\n"
        "           (double)sample, (double)voice->phase,\n"
        "           (double)voice->phase_step, voice->phase_rate,\n"
        "           (double)voice->noise_value, voice->noise_ready,\n"
        "           voice->waveform);\n"
        "}\n"
        "int main(void) {\n"
        "    FB_SFXCTX context;\n"
        "    FB_SFXVOICE voice;\n"
        "    float sample;\n"
        "\n"
        "    memset(&context, 0, sizeof(context));\n"
        "    memset(&voice, 0, sizeof(voice));\n"
        "    srand(48271u);\n"
        "    __fb_sfx = NULL;\n"
        "    set_voice(&voice, FB_SFX_WAVE_SINE, 0.125f, 220);\n"
        "    sample = fb_sfxWaveformSample(&voice);\n"
        "    print_result(\"no-context-sine\", &voice, sample);\n"
        "\n"
        "    __fb_sfx = &context;\n"
        "    context.samplerate = 44100;\n"
        "    set_voice(&voice, FB_SFX_WAVE_SINE, 0.125f, 220);\n"
        "    sample = fb_sfxWaveformSample(&voice);\n"
        "    print_result(\"sine\", &voice, sample);\n"
        "    set_voice(&voice, FB_SFX_WAVE_SQUARE, 0.5f, 220);\n"
        "    sample = fb_sfxWaveformSample(&voice);\n"
        "    print_result(\"square-boundary\", &voice, sample);\n"
        "    set_voice(&voice, FB_SFX_WAVE_TRIANGLE, 0.25f, 220);\n"
        "    sample = fb_sfxWaveformSample(&voice);\n"
        "    print_result(\"triangle-boundary\", &voice, sample);\n"
        "    set_voice(&voice, FB_SFX_WAVE_SAW, 0.0f, 220);\n"
        "    sample = fb_sfxWaveformSample(&voice);\n"
        "    print_result(\"saw-wrap\", &voice, sample);\n"
        "\n"
        "    set_voice(&voice, FB_SFX_WAVE_SAW, 0.5f, 220);\n"
        "    voice.phase_step = 0.125f;\n"
        "    voice.phase_rate = context.samplerate;\n"
        "    sample = fb_sfxWaveformSample(&voice);\n"
        "    print_result(\"cached-step\", &voice, sample);\n"
        "    context.samplerate = 0;\n"
        "    set_voice(&voice, FB_SFX_WAVE_TRIANGLE, 0.25f, 220);\n"
        "    sample = fb_sfxWaveformSample(&voice);\n"
        "    print_result(\"invalid-samplerate\", &voice, sample);\n"
        "    set_voice(&voice, -1, 0.25f, 220);\n"
        "    sample = fb_sfxWaveformSample(&voice);\n"
        "    print_result(\"invalid-waveform\", &voice, sample);\n"
        "\n"
        "    context.samplerate = 44100;\n"
        "    set_voice(&voice, FB_SFX_WAVE_NOISE, 0.0f, 0);\n"
        "    sample = fb_sfxWaveformSample(&voice);\n"
        "    print_result(\"white-noise-first\", &voice, sample);\n"
        "    sample = fb_sfxWaveformSample(&voice);\n"
        "    print_result(\"white-noise-second\", &voice, sample);\n"
        "    set_voice(&voice, FB_SFX_WAVE_NOISE, 0.99f, 4410);\n"
        "    voice.phase_step = 0.1f;\n"
        "    voice.phase_rate = context.samplerate;\n"
        "    sample = fb_sfxWaveformSample(&voice);\n"
        "    print_result(\"pitched-noise-wrap\", &voice, sample);\n"
        "    sample = fb_sfxWaveformSample(&voice);\n"
        "    print_result(\"pitched-noise-hold\", &voice, sample);\n"
        "    __fb_sfx = NULL;\n"
        "    sample = fb_sfxWaveformSample(&voice);\n"
        "    print_result(\"pitched-noise-no-context\", &voice, sample);\n"
        "\n"
        "    debug_enabled = 1;\n"
        "    fb_sfxVoiceSetWaveform(&voice, FB_SFX_WAVE_TRIANGLE);\n"
        "    printf(\"set-waveform|%d|%s\\n\", voice.waveform, debug_message);\n"
        "    fb_sfxVoiceSetWaveform(NULL, FB_SFX_WAVE_SINE);\n"
        "    printf(\"null-set-waveform|%s\\n\", debug_message);\n"
        "    return 0;\n"
        "}\n"
    )

    renamed_symbols = (
        "fb_sfxWaveformSample=cReferenceSfxWaveformSample",
        "fb_sfxVoiceSetWaveform=cReferenceSfxVoiceSetWaveform",
    )
    rename_options = ["-D" + symbol for symbol in renamed_symbols]

    reference_object = work / "sfx_waveform_reference.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", *rename_options,
        "-c", str(sfx_directory / "sfx_waveform.c"),
        "-o", str(reference_object),
    ], cwd=work)

    oscillator_object = work / "sfx_oscillator_helper.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}",
        "-c", str(sfx_directory / "sfx_oscillator.c"),
        "-o", str(oscillator_object),
    ], cwd=work)

    reference_probe = work / "sfx_waveform_reference_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", *rename_options,
        "-c", str(probe_source), "-o", str(reference_probe),
    ], cwd=work)
    reference_executable = work / "sfx_waveform_reference"
    run(cc + [
        str(reference_object), str(oscillator_object),
        str(reference_probe), "-lm", "-o", str(reference_executable),
    ], cwd=work)
    expected = run([str(reference_executable)], cwd=work)

    probe_object = work / "sfx_waveform_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", "-c", str(probe_source),
        "-o", str(probe_object),
    ], cwd=work)

    for implementation, object_path in (
        ("C2FB candidate", candidate_object),
        ("integrated Basic", basic_object),
    ):
        executable = work / (
            "sfx_waveform_" + implementation.lower().replace(" ", "_")
        )
        run(fbc + [
            "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
            str(object_path), str(oscillator_object), str(probe_object),
            "-l", "m", "-x", str(executable),
        ], cwd=work)
        observed = run([str(executable)], cwd=work)
        if observed != expected:
            raise AssertionError(
                f"SFX waveform behavior differs for {implementation}: "
                f"C={expected!r}, observed={observed!r}"
            )

    print(
        "SFX waveform: C2FB candidate and integrated Basic match C for "
        "waveform boundaries, phase caching and wrapping, noise modes, "
        "invalid inputs, and debug output"
    )


def check_sfx_voice_behavior(fbc, cc, source_root, basic_object,
                             candidate_object, work):
    sfx_directory = source_root / "sfxlib"
    probe_source = work / "sfx_voice_probe.c"
    probe_source.write_text(
        "#include <stdio.h>\n"
        "#include <stdarg.h>\n"
        "#include <string.h>\n"
        '#include "fb_sfx_internal.h"\n'
        "FB_SFXCTX *__fb_sfx;\n"
        "void fb_sfxVoiceStartTone(FB_SFXVOICE *, int, float);\n"
        "void fb_sfxVoiceStartSample(FB_SFXVOICE *, const float *, int, float);\n"
        "void fb_sfxVoiceStop(FB_SFXVOICE *);\n"
        "void fb_sfxVoiceAdvance(FB_SFXVOICE *);\n"
        "static int initialization_ready;\n"
        "static int debug_enabled;\n"
        "static int lock_count;\n"
        "static int unlock_count;\n"
        "static int lock_depth;\n"
        "static char debug_message[128];\n"
        "int fb_sfxEnsureInitialized(void) {\n"
        "    return initialization_ready && __fb_sfx && __fb_sfx->initialized;\n"
        "}\n"
        "int fb_sfxDebugEnabled(void) { return debug_enabled; }\n"
        "void fb_sfxDebugLog(const char *format, ...) {\n"
        "    va_list args;\n"
        "    va_start(args, format);\n"
        "    vsnprintf(debug_message, sizeof(debug_message), format, args);\n"
        "    va_end(args);\n"
        "}\n"
        "void fb_sfxRuntimeLock(void) { ++lock_count; ++lock_depth; }\n"
        "void fb_sfxRuntimeUnlock(void) { ++unlock_count; --lock_depth; }\n"
        "static void print_voice(const char *label, const FB_SFXVOICE *voice) {\n"
        "    printf(\"%s|%d|%d|%a|%a|%d|%a|%a|%d|%d|%d|%d|%d|%d|%d|%d|%a|%a|%d|%d|%d|%d|%d|%a|%d|%a|%d|%d\\n\",\n"
        "           label, voice->active, voice->channel,\n"
        "           (double)voice->volume, (double)voice->pan,\n"
        "           voice->frequency, (double)voice->phase,\n"
        "           (double)voice->phase_step, voice->phase_rate,\n"
        "           voice->waveform, voice->type, voice->sfx_id,\n"
        "           voice->paused, voice->loop, voice->position, voice->pos,\n"
        "           (double)voice->sample_pos, (double)voice->sample_step,\n"
        "           voice->length, voice->start_delay, voice->hard_stop,\n"
        "           voice->envelope, voice->env_state,\n"
        "           (double)voice->env_level, voice->env_time,\n"
        "           (double)voice->noise_value, voice->noise_ready,\n"
        "           voice->data != NULL);\n"
        "}\n"
        "static void print_locks(const char *label) {\n"
        "    printf(\"%s|%d|%d|%d\\n\", label,\n"
        "           lock_count, unlock_count, lock_depth);\n"
        "}\n"
        "int main(void) {\n"
        "    FB_SFXCTX context;\n"
        "    FB_SFXVOICE voice;\n"
        "    FB_SFXVOICE *locked_voice;\n"
        "    FB_SFXVOICE *allocated_voice;\n"
        "    float samples[2] = { 0.25f, -0.5f };\n"
        "    int i;\n"
        "\n"
        "    memset(&context, 0, sizeof(context));\n"
        "    memset(&voice, 0, sizeof(voice));\n"
        "    __fb_sfx = NULL;\n"
        "    debug_enabled = 0;\n"
        "    fb_sfxVoiceInit(&voice);\n"
        "    print_voice(\"initialized\", &voice);\n"
        "    fb_sfxVoiceInit(NULL);\n"
        "    printf(\"no-context-active-count|%d\\n\",\n"
        "           fb_sfxVoiceActiveCount());\n"
        "    printf(\"no-context-locked-allocation|%d\\n\",\n"
        "           fb_sfxVoiceAllocLocked() != NULL);\n"
        "\n"
        "    __fb_sfx = &context;\n"
        "    context.initialized = 1;\n"
        "    initialization_ready = 1;\n"
        "    debug_enabled = 1;\n"
        "    locked_voice = fb_sfxVoiceAllocLocked();\n"
        "    printf(\"locked-allocation|%d|%d|%d|%s\\n\",\n"
        "           locked_voice == &context.voices[0],\n"
        "           locked_voice ? locked_voice->active : -1,\n"
        "           fb_sfxVoiceActiveCount(), debug_message);\n"
        "    fb_sfxVoiceActivateLocked(locked_voice);\n"
        "    fb_sfxVoiceActivateLocked(NULL);\n"
        "    allocated_voice = fb_sfxVoiceAlloc();\n"
        "    printf(\"public-allocation|%d|%d|%d\\n\",\n"
        "           allocated_voice == &context.voices[1],\n"
        "           allocated_voice ? allocated_voice->active : -1,\n"
        "           fb_sfxVoiceActiveCount());\n"
        "    print_locks(\"allocation-locks\");\n"
        "    fb_sfxVoiceFree(allocated_voice);\n"
        "    fb_sfxVoiceFree(NULL);\n"
        "    print_locks(\"free-locks\");\n"
        "\n"
        "    context.samplerate = 44100;\n"
        "    fb_sfxVoiceStartTone(locked_voice, 440, 0.75f);\n"
        "    print_voice(\"start-tone\", locked_voice);\n"
        "    fb_sfxVoiceStartSample(locked_voice, samples, 2, 0.5f);\n"
        "    print_voice(\"start-sample\", locked_voice);\n"
        "    fb_sfxVoiceAdvance(locked_voice);\n"
        "    print_voice(\"sample-advance-one\", locked_voice);\n"
        "    fb_sfxVoiceAdvance(locked_voice);\n"
        "    print_voice(\"sample-advance-end\", locked_voice);\n"
        "    fb_sfxVoiceStartTone(locked_voice, -1, 0.25f);\n"
        "    print_voice(\"negative-tone-frequency\", locked_voice);\n"
        "    fb_sfxVoiceStartSample(NULL, samples, 2, 0.5f);\n"
        "    fb_sfxVoiceStop(locked_voice);\n"
        "    print_voice(\"voice-stop\", locked_voice);\n"
        "    print_locks(\"control-locks\");\n"
        "    printf(\"voice-debug|%s\\n\", debug_message);\n"
        "\n"
        "    for (i = 0; i < FB_SFX_MAX_VOICES; ++i)\n"
        "        fb_sfxVoiceInit(&context.voices[i]);\n"
        "    for (i = 0; i < 5; ++i) {\n"
        "        context.voices[i].active = (i != 3);\n"
        "        context.voices[i].type = (i == 2 ? 3 : 2);\n"
        "        context.voices[i].channel = (i == 4 ? 2 : i % 2);\n"
        "        context.voices[i].paused = (i == 1);\n"
        "    }\n"
        "    printf(\"status-initial|%d|%d|%d|%d\\n\",\n"
        "           fb_sfxVoiceActiveCount(),\n"
        "           fb_sfxVoiceStatusType(2),\n"
        "           fb_sfxVoiceStatusTypeChannel(2, 1),\n"
        "           fb_sfxVoiceStatusTypeChannel(9, -1));\n"
        "    fb_sfxVoiceStopTypeChannel(2, 1);\n"
        "    fb_sfxVoicePauseTypeChannel(2, 0);\n"
        "    printf(\"status-channel-controls|%d|%d|%d|%d|%d\\n\",\n"
        "           context.voices[0].active, context.voices[1].active,\n"
        "           context.voices[0].paused, context.voices[4].paused,\n"
        "           fb_sfxVoiceStatusTypeChannel(2, 0));\n"
        "    fb_sfxVoiceResumeType(2);\n"
        "    printf(\"status-resume|%d|%d|%d\\n\",\n"
        "           context.voices[0].paused, context.voices[4].paused,\n"
        "           fb_sfxVoiceStatusType(2));\n"
        "    fb_sfxVoicePauseType(2);\n"
        "    printf(\"status-pause-type|%d|%d|%d\\n\",\n"
        "           context.voices[0].paused, context.voices[4].paused,\n"
        "           fb_sfxVoiceStatusType(2));\n"
        "    fb_sfxVoiceStopType(3);\n"
        "    printf(\"stop-type|%d|%d\\n\",\n"
        "           context.voices[2].active,\n"
        "           fb_sfxVoiceStatusType(3));\n"
        "    fb_sfxVoiceStopType(2);\n"
        "    printf(\"stop-all-type|%d|%d\\n\",\n"
        "           fb_sfxVoiceActiveCount(),\n"
        "           fb_sfxVoiceStatusType(2));\n"
        "\n"
        "    for (i = 0; i < FB_SFX_MAX_VOICES; ++i)\n"
        "        context.voices[i].active = 1;\n"
        "    allocated_voice = fb_sfxVoiceAlloc();\n"
        "    printf(\"full-pool|%d|%s\\n\",\n"
        "           allocated_voice != NULL, debug_message);\n"
        "    print_locks(\"final-locks\");\n"
        "    return 0;\n"
        "}\n"
    )

    renamed_symbols = (
        "fb_sfxVoiceInit=cReferenceSfxVoiceInit",
        "fb_sfxVoiceAllocLocked=cReferenceSfxVoiceAllocLocked",
        "fb_sfxVoiceActivateLocked=cReferenceSfxVoiceActivateLocked",
        "fb_sfxVoiceAlloc=cReferenceSfxVoiceAlloc",
        "fb_sfxVoiceFree=cReferenceSfxVoiceFree",
        "fb_sfxVoiceStartTone=cReferenceSfxVoiceStartTone",
        "fb_sfxVoiceStartSample=cReferenceSfxVoiceStartSample",
        "fb_sfxVoiceStop=cReferenceSfxVoiceStop",
        "fb_sfxVoiceAdvance=cReferenceSfxVoiceAdvance",
        "fb_sfxVoiceActiveCount=cReferenceSfxVoiceActiveCount",
        "fb_sfxVoiceStopType=cReferenceSfxVoiceStopType",
        "fb_sfxVoiceStopTypeChannel=cReferenceSfxVoiceStopTypeChannel",
        "fb_sfxVoicePauseType=cReferenceSfxVoicePauseType",
        "fb_sfxVoicePauseTypeChannel=cReferenceSfxVoicePauseTypeChannel",
        "fb_sfxVoiceResumeType=cReferenceSfxVoiceResumeType",
        "fb_sfxVoiceResumeTypeChannel=cReferenceSfxVoiceResumeTypeChannel",
        "fb_sfxVoiceStatusType=cReferenceSfxVoiceStatusType",
        "fb_sfxVoiceStatusTypeChannel=cReferenceSfxVoiceStatusTypeChannel",
    )
    rename_options = ["-D" + symbol for symbol in renamed_symbols]

    reference_object = work / "sfx_voice_reference.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", *rename_options,
        "-c", str(sfx_directory / "sfx_voice.c"),
        "-o", str(reference_object),
    ], cwd=work)

    oscillator_object = work / "sfx_voice_oscillator.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}",
        "-c", str(sfx_directory / "sfx_oscillator.c"),
        "-o", str(oscillator_object),
    ], cwd=work)

    reference_probe = work / "sfx_voice_reference_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", *rename_options,
        "-c", str(probe_source), "-o", str(reference_probe),
    ], cwd=work)
    reference_executable = work / "sfx_voice_reference"
    run(cc + [
        str(reference_object), str(oscillator_object),
        str(reference_probe), "-lm", "-o", str(reference_executable),
    ], cwd=work)
    expected = run([str(reference_executable)], cwd=work)

    probe_object = work / "sfx_voice_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", "-c", str(probe_source),
        "-o", str(probe_object),
    ], cwd=work)

    for implementation, object_path in (
        ("C2FB candidate", candidate_object),
        ("integrated Basic", basic_object),
    ):
        executable = work / (
            "sfx_voice_" + implementation.lower().replace(" ", "_")
        )
        run(fbc + [
            "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
            str(object_path), str(oscillator_object), str(probe_object),
            "-l", "m", "-x", str(executable),
        ], cwd=work)
        observed = run([str(executable)], cwd=work)
        if observed != expected:
            raise AssertionError(
                f"SFX voice behavior differs for {implementation}: "
                f"C={expected!r}, observed={observed!r}"
            )

    print(
        "SFX voice: C2FB candidate and integrated Basic match C for "
        "initialization, pool allocation, playback state, locking, type/channel "
        "controls, status precedence, and full-pool behavior"
    )


def check_sfx_oscillator_behavior(fbc, cc, source_root, basic_object,
                                 candidate_object, work):
    sfx_directory = source_root / "sfxlib"
    probe_source = work / "sfx_oscillator_probe.c"
    probe_source.write_text(
        "#include <math.h>\n"
        "#include <stdarg.h>\n"
        "#include <stdio.h>\n"
        "#include <stdlib.h>\n"
        "#include <string.h>\n"
        '#include "fb_sfx_internal.h"\n'
        "FB_SFXCTX *__fb_sfx;\n"
        "void fb_sfxOscillatorReset(FB_SFXVOICE *);\n"
        "static int debug_enabled;\n"
        "static char debug_message[128];\n"
        "int fb_sfxDebugEnabled(void) { return debug_enabled; }\n"
        "void fb_sfxDebugLog(const char *format, ...) {\n"
        "    va_list args;\n"
        "    va_start(args, format);\n"
        "    vsnprintf(debug_message, sizeof(debug_message), format, args);\n"
        "    va_end(args);\n"
        "}\n"
        "static void set_voice(FB_SFXVOICE *voice, int waveform,\n"
        "                     float phase, int frequency) {\n"
        "    memset(voice, 0, sizeof(*voice));\n"
        "    voice->waveform = waveform;\n"
        "    voice->phase = phase;\n"
        "    voice->frequency = frequency;\n"
        "}\n"
        "static void print_voice(const char *label, FB_SFXVOICE *voice,\n"
        "                        float result) {\n"
        "    printf(\"%s|%a|%d|%a|%d|%d|%a|%d|%a|%d|%d\\n\",\n"
        "           label, (double)result, voice->waveform,\n"
        "           (double)voice->phase, voice->frequency,\n"
        "           voice->phase_rate, (double)voice->phase_step,\n"
        "           voice->noise_ready, (double)voice->noise_value,\n"
        "           voice->active, voice->noise_ready);\n"
        "}\n"
        "int main(void) {\n"
        "    FB_SFXCTX context;\n"
        "    FB_SFXVOICE voice;\n"
        "    float result;\n"
        "\n"
        "    memset(&context, 0, sizeof(context));\n"
        "    memset(&voice, 0, sizeof(voice));\n"
        "    srand(48271u);\n"
        "    __fb_sfx = NULL;\n"
        "    set_voice(&voice, FB_SFX_WAVE_SINE, 0.25f, 220);\n"
        "    voice.phase_step = 0.125f;\n"
        "    voice.phase_rate = 44100;\n"
        "    result = fb_sfxOscillatorPhaseStep(&voice);\n"
        "    print_voice(\"step-no-context\", &voice, result);\n"
        "    fb_sfxVoiceSetFrequency(&voice, -10);\n"
        "    print_voice(\"frequency-no-context\", &voice, 0.0f);\n"
        "\n"
        "    __fb_sfx = &context;\n"
        "    context.samplerate = 44100;\n"
        "    set_voice(&voice, FB_SFX_WAVE_SINE, 0.25f, 220);\n"
        "    result = fb_sfxOscillatorPhaseStep(&voice);\n"
        "    print_voice(\"step-initial\", &voice, result);\n"
        "    voice.phase_step = 0.125f;\n"
        "    voice.phase_rate = context.samplerate;\n"
        "    result = fb_sfxOscillatorPhaseStep(&voice);\n"
        "    print_voice(\"step-cached\", &voice, result);\n"
        "    voice.frequency = 11025;\n"
        "    voice.phase_step = 0.0f;\n"
        "    voice.phase_rate = 0;\n"
        "    result = fb_sfxOscillatorPhaseStep(&voice);\n"
        "    print_voice(\"step-recomputed\", &voice, result);\n"
        "    context.samplerate = 48000;\n"
        "    result = fb_sfxOscillatorPhaseStep(&voice);\n"
        "    print_voice(\"step-rate-change\", &voice, result);\n"
        "    context.samplerate = 0;\n"
        "    voice.phase_step = 0.25f;\n"
        "    voice.phase_rate = 48000;\n"
        "    result = fb_sfxOscillatorPhaseStep(&voice);\n"
        "    print_voice(\"step-invalid-rate\", &voice, result);\n"
        "\n"
        "    context.samplerate = 44100;\n"
        "    set_voice(&voice, FB_SFX_WAVE_SINE, 0.25f, 11025);\n"
        "    result = fb_sfxOscillatorSample(&voice);\n"
        "    print_voice(\"sine-sample\", &voice, result);\n"
        "    set_voice(&voice, FB_SFX_WAVE_SQUARE, 0.5f, 0);\n"
        "    result = fb_sfxOscillatorSample(&voice);\n"
        "    print_voice(\"square-boundary\", &voice, result);\n"
        "    set_voice(&voice, FB_SFX_WAVE_TRIANGLE, 0.75f, 0);\n"
        "    result = fb_sfxOscillatorSample(&voice);\n"
        "    print_voice(\"triangle-boundary\", &voice, result);\n"
        "    set_voice(&voice, FB_SFX_WAVE_SAW, 0.0f, 0);\n"
        "    result = fb_sfxOscillatorSample(&voice);\n"
        "    print_voice(\"saw-boundary\", &voice, result);\n"
        "    set_voice(&voice, -1, 0.5f, 11025);\n"
        "    result = fb_sfxOscillatorSample(&voice);\n"
        "    print_voice(\"invalid-waveform\", &voice, result);\n"
        "\n"
        "    result = fb_sfxOscillatorWaveSample(FB_SFX_WAVE_SINE, 0.125f);\n"
        "    printf(\"sine-table-interpolation|%a\\n\", (double)result);\n"
        "    printf(\"wrapped-lookups|%a|%a|%a\\n\",\n"
        "           (double)fb_sfxOscillatorWaveSample(FB_SFX_WAVE_SAW, 1.25f),\n"
        "           (double)fb_sfxOscillatorWaveSample(FB_SFX_WAVE_SAW, -0.25f),\n"
        "           (double)fb_sfxOscillatorWaveSample(-1, 0.5f));\n"
        "    printf(\"nonfinite-lookups|%a|%a\\n\",\n"
        "           (double)fb_sfxOscillatorWaveSample(FB_SFX_WAVE_SINE, NAN),\n"
        "           (double)fb_sfxOscillatorWaveSample(FB_SFX_WAVE_SINE, INFINITY));\n"
        "\n"
        "    set_voice(&voice, FB_SFX_WAVE_NOISE, 0.0f, 0);\n"
        "    result = fb_sfxOscillatorSample(&voice);\n"
        "    print_voice(\"white-noise-first\", &voice, result);\n"
        "    result = fb_sfxOscillatorSample(&voice);\n"
        "    print_voice(\"white-noise-second\", &voice, result);\n"
        "    set_voice(&voice, FB_SFX_WAVE_NOISE, 0.75f, 11025);\n"
        "    result = fb_sfxOscillatorSample(&voice);\n"
        "    print_voice(\"pitched-noise-wrap\", &voice, result);\n"
        "    result = fb_sfxOscillatorSample(&voice);\n"
        "    print_voice(\"pitched-noise-next\", &voice, result);\n"
        "\n"
        "    set_voice(&voice, FB_SFX_WAVE_SQUARE, 0.8f, 440);\n"
        "    voice.noise_value = 0.6f;\n"
        "    voice.noise_ready = 1;\n"
        "    voice.phase_step = 0.1f;\n"
        "    voice.phase_rate = context.samplerate;\n"
        "    fb_sfxOscillatorReset(&voice);\n"
        "    print_voice(\"reset\", &voice, 0.0f);\n"
        "    fb_sfxOscillatorReset(NULL);\n"
        "\n"
        "    debug_enabled = 1;\n"
        "    fb_sfxVoiceSetFrequency(&voice, 440);\n"
        "    printf(\"set-frequency|%s\\n\", debug_message);\n"
        "    fb_sfxVoiceSetFrequency(&voice, -1);\n"
        "    printf(\"clamped-frequency|%d|%s\\n\",\n"
        "           voice.frequency, debug_message);\n"
        "    fb_sfxVoiceSetFrequency(NULL, 440);\n"
        "    return 0;\n"
        "}\n"
    )

    renamed_symbols = (
        "fb_sfxOscillatorReset=cReferenceSfxOscillatorReset",
        "fb_sfxOscillatorPhaseStep=cReferenceSfxOscillatorPhaseStep",
        "fb_sfxOscillatorSample=cReferenceSfxOscillatorSample",
        "fb_sfxOscillatorWaveSample=cReferenceSfxOscillatorWaveSample",
        "fb_sfxVoiceSetFrequency=cReferenceSfxVoiceSetFrequency",
    )
    rename_options = ["-D" + symbol for symbol in renamed_symbols]

    reference_object = work / "sfx_oscillator_reference.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", *rename_options,
        "-c", str(sfx_directory / "sfx_oscillator.c"),
        "-o", str(reference_object),
    ], cwd=work)

    reference_probe = work / "sfx_oscillator_reference_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", *rename_options,
        "-c", str(probe_source), "-o", str(reference_probe),
    ], cwd=work)
    reference_executable = work / "sfx_oscillator_reference"
    run(cc + [
        str(reference_object), str(reference_probe), "-lm",
        "-o", str(reference_executable),
    ], cwd=work)
    expected = run([str(reference_executable)], cwd=work)

    probe_object = work / "sfx_oscillator_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", "-c", str(probe_source),
        "-o", str(probe_object),
    ], cwd=work)

    for implementation, object_path in (
        ("C2FB candidate", candidate_object),
        ("integrated Basic", basic_object),
    ):
        executable = work / (
            "sfx_oscillator_" + implementation.lower().replace(" ", "_")
        )
        run(fbc + [
            "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
            str(object_path), str(probe_object), "-l", "m",
            "-x", str(executable),
        ], cwd=work)
        observed = run([str(executable)], cwd=work)
        if observed != expected:
            raise AssertionError(
                f"SFX oscillator behavior differs for {implementation}: "
                f"C={expected!r}, observed={observed!r}"
            )

    print(
        "SFX oscillator: C2FB candidate and integrated Basic match C for "
        "phase caching, reset, waveform dispatch, sine interpolation, "
        "nonfinite input, seeded noise, and frequency changes"
    )


def check_sfx_mixer_behavior(fbc, cc, source_root, basic_object,
                             candidate_object, work):
    sfx_directory = source_root / "sfxlib"
    probe_source = work / "sfx_mixer_probe.c"
    probe_source.write_text(
        "#include <math.h>\n"
        "#include <stdarg.h>\n"
        "#include <stdio.h>\n"
        "#include <string.h>\n"
        '#include "fb_sfx_internal.h"\n'
        '#include "fb_sfx_mixer.h"\n'
        "FB_SFXCTX *__fb_sfx;\n"
        "short fb_sfxFloatToS16(float value) {\n"
        "    return (short)(value * 32767.0f);\n"
        "}\n"
        "int fb_sfxFloatToS32(float value) {\n"
        "    return (int)((double)value * 2147483647.0);\n"
        "}\n"
        "float fb_sfxS16ToFloat(short value) {\n"
        "    return (float)value / 32768.0f;\n"
        "}\n"
        "static int debug_enabled;\n"
        "static char debug_message[128];\n"
        "int fb_sfxDebugEnabled(void) { return debug_enabled; }\n"
        "void fb_sfxDebugLog(const char *format, ...) {\n"
        "    va_list args;\n"
        "    va_start(args, format);\n"
        "    vsnprintf(debug_message, sizeof(debug_message), format, args);\n"
        "    va_end(args);\n"
        "}\n"
        "void fb_sfxEchoProcessBlock(float *buffer, int frames) {\n"
        "    (void)buffer; (void)frames;\n"
        "}\n"
        "void fb_sfxMidiSoftwareMixBlock(float *buffer, int frames) {\n"
        "    (void)buffer; (void)frames;\n"
        "}\n"
        "float fb_sfxEnvelopeProcess(FB_SFXVOICE *voice, float dt) {\n"
        "    (void)dt;\n"
        "    if (!voice) return 0.0f;\n"
        "    voice->env_level = 0.8f;\n"
        "    return voice->env_level;\n"
        "}\n"
        "void fb_sfxEnvelopeRelease(FB_SFXVOICE *voice) {\n"
        "    if (voice) voice->env_state = FB_SFX_ENV_RELEASE;\n"
        "}\n"
        "float fb_sfxOscillatorSample(FB_SFXVOICE *voice) {\n"
        "    if (!voice) return 0.0f;\n"
        "    voice->phase += 0.125f;\n"
        "    return (float)voice->position * 0.125f;\n"
        "}\n"
        "float fb_sfxOscillatorPhaseStep(FB_SFXVOICE *voice) {\n"
        "    return voice ? 0.125f : 0.0f;\n"
        "}\n"
        "float fb_sfxOscillatorWaveSample(int waveform, float phase) {\n"
        "    if (phase < 0.0f || phase >= 1.0f) {\n"
        "        phase -= floorf(phase);\n"
        "        if (phase < 0.0f) phase += 1.0f;\n"
        "    }\n"
        "    switch (waveform) {\n"
        "    case FB_SFX_WAVE_SQUARE: return phase < 0.5f ? 1.0f : -1.0f;\n"
        "    case FB_SFX_WAVE_TRIANGLE:\n"
        "        if (phase < 0.25f) return phase * 4.0f;\n"
        "        if (phase < 0.75f) return 2.0f - phase * 4.0f;\n"
        "        return phase * 4.0f - 4.0f;\n"
        "    case FB_SFX_WAVE_SAW: return phase * 2.0f - 1.0f;\n"
        "    default: return 0.0f;\n"
        "    }\n"
        "}\n"
        "static void print_buffer(const char *label, const float *buffer,\n"
        "                         int samples) {\n"
        "    int i;\n"
        "    printf(\"%s\", label);\n"
        "    for (i = 0; i < samples; ++i)\n"
        "        printf(\"|%a\", (double)buffer[i]);\n"
        "    putchar('\\n');\n"
        "}\n"
        "int main(void) {\n"
        "    FB_SFXCTX context;\n"
        "    FB_SFXVOICE *voice;\n"
        "    float buffer[8] = { 1.0f, -1.0f, 2.0f, -2.0f,\n"
        "                        3.0f, -3.0f, 4.0f, -4.0f };\n"
        "    float clamp_inputs[8] = { -2.0f, -1.0f, -0.5f, 0.0f,\n"
        "                              0.5f, 1.0f, 2.0f, NAN };\n"
        "    int i;\n"
        "\n"
        "    memset(&context, 0, sizeof(context));\n"
        "    __fb_sfx = &context;\n"
        "    context.output_channels = 2;\n"
        "    context.samplerate = 44100;\n"
        "    context.master_volume = 1.0f;\n"
        "    context.mixbuffer = buffer;\n"
        "    context.channels[0].volume = 1.0f;\n"
        "    context.channels[0].pan = 0.0f;\n"
        "    debug_enabled = 1;\n"
        "    printf(\"clamp|%a|%a|%a|%a|%a|%a|%a|%d\\n\",\n"
        "           (double)fb_sfxMixerClamp(clamp_inputs[0]),\n"
        "           (double)fb_sfxMixerClamp(clamp_inputs[1]),\n"
        "           (double)fb_sfxMixerClamp(clamp_inputs[2]),\n"
        "           (double)fb_sfxMixerClamp(clamp_inputs[3]),\n"
        "           (double)fb_sfxMixerClamp(clamp_inputs[4]),\n"
        "           (double)fb_sfxMixerClamp(clamp_inputs[5]),\n"
        "           (double)fb_sfxMixerClamp(clamp_inputs[6]),\n"
        "           isnan(fb_sfxMixerClamp(clamp_inputs[7])));\n"
        "\n"
        "    fb_sfxMixerClear(buffer, 3);\n"
        "    print_buffer(\"clear\", buffer, 6);\n"
        "    buffer[0] = 0.25f; buffer[1] = -0.25f;\n"
        "    fb_sfxMixerClear(buffer, 0);\n"
        "    print_buffer(\"clear-zero-frames\", buffer, 2);\n"
        "    fb_sfxMixerSetChannelVolume(0, 0.75f);\n"
        "    fb_sfxMixerSetChannelPan(0, -0.25f);\n"
        "    fb_sfxMixerSetChannelVolume(-1, 0.1f);\n"
        "    fb_sfxMixerSetChannelPan(FB_SFX_MAX_CHANNELS, 0.9f);\n"
        "    printf(\"channel-controls|%a|%a\\n\",\n"
        "           (double)context.channels[0].volume,\n"
        "           (double)context.channels[0].pan);\n"
        "\n"
        "    fb_sfxMixerInit();\n"
        "    context.voices[0].active = 1;\n"
        "    context.voices[0].position = 17;\n"
        "    fb_sfxMixerInit();\n"
        "    printf(\"mixer-init|%d|%d|%s\\n\",\n"
        "           context.voices[0].active, context.voices[0].position,\n"
        "           debug_message);\n"
        "\n"
        "    context.voices[0].active = 1;\n"
        "    voice = fb_sfxMixerAllocVoice();\n"
        "    printf(\"mixer-alloc|%d|%d|%a|%a|%a\\n\",\n"
        "           voice == &context.voices[1], voice ? voice->active : -1,\n"
        "           voice ? (double)voice->volume : -1.0,\n"
        "           voice ? (double)voice->pan : -1.0,\n"
        "           voice ? (double)voice->sample_step : -1.0);\n"
        "    fb_sfxMixerFreeVoice(voice);\n"
        "    fb_sfxMixerFreeVoice(NULL);\n"
        "    printf(\"mixer-free|%d\\n\", voice ? voice->active : -1);\n"
        "\n"
        "    context.master_volume = 1.0f;\n"
        "    context.balance = 0.0f;\n"
        "    context.channels[0].volume = 1.0f;\n"
        "    context.channels[0].pan = 0.0f;\n"
        "    for (i = 0; i < FB_SFX_MAX_VOICES; ++i)\n"
        "        memset(&context.voices[i], 0, sizeof(context.voices[i]));\n"
        "    voice = &context.voices[0];\n"
        "    voice->active = 1;\n"
        "    voice->channel = 0;\n"
        "    voice->volume = 1.0f;\n"
        "    voice->type = FB_SFX_VOICE_TONE;\n"
        "    voice->waveform = FB_SFX_WAVE_SINE;\n"
        "    voice->env_state = FB_SFX_ENV_ATTACK;\n"
        "    voice->sample_step = 1.0f;\n"
        "    for (i = 0; i < 8; ++i) buffer[i] = 9.0f;\n"
        "    fb_sfxMixerProcess(4);\n"
        "    print_buffer(\"mixed-block\", buffer, 8);\n"
        "    printf(\"mixed-voice|%d|%d|%a|%d\\n\",\n"
        "           voice->active, voice->position,\n"
        "           (double)voice->env_level,\n"
        "           fb_sfxMixerSimdEnabled());\n"
        "\n"
        "    memset(buffer, 0, sizeof(buffer));\n"
        "    context.envelopes[0].sustain = 0.8f;\n"
        "    voice->active = 1;\n"
        "    voice->paused = 0;\n"
        "    voice->waveform = FB_SFX_WAVE_SQUARE;\n"
        "    voice->env_state = FB_SFX_ENV_SUSTAIN;\n"
        "    voice->envelope = 0;\n"
        "    voice->phase = 0.25f;\n"
        "    voice->phase_step = 0.125f;\n"
        "    voice->phase_rate = context.samplerate;\n"
        "    voice->position = 0;\n"
        "    fb_sfxMixerProcess(4);\n"
        "    print_buffer(\"sustained-waveform\", buffer, 8);\n"
        "    printf(\"waveform-voice|%d|%d|%a|%d\\n\",\n"
        "           voice->active, voice->position,\n"
        "           (double)voice->phase, fb_sfxMixerSimdEnabled());\n"
        "    fb_sfxMixerProcess(0);\n"
        "    print_buffer(\"zero-frame-process\", buffer, 8);\n"
        "    fb_sfxMixerShutdown();\n"
        "    return 0;\n"
        "}\n"
    )

    renamed_symbols = (
        "fb_sfxMixerDiagnostics=cReferenceSfxMixerDiagnostics",
        "fb_sfxMixerInit=cReferenceSfxMixerInit",
        "fb_sfxMixerShutdown=cReferenceSfxMixerShutdown",
        "fb_sfxMixerClear=cReferenceSfxMixerClear",
        "fb_sfxMixerAllocVoice=cReferenceSfxMixerAllocVoice",
        "fb_sfxMixerFreeVoice=cReferenceSfxMixerFreeVoice",
        "fb_sfxMixerStopChannel=cReferenceSfxMixerStopChannel",
        "fb_sfxMixerStopAll=cReferenceSfxMixerStopAll",
        "fb_sfxMixerSetChannelVolume=cReferenceSfxMixerSetChannelVolume",
        "fb_sfxMixerSetChannelPan=cReferenceSfxMixerSetChannelPan",
        "fb_sfxMixerProcessEnvelope=cReferenceSfxMixerProcessEnvelope",
        "fb_sfxMixerOscillator=cReferenceSfxMixerOscillator",
        "fb_sfxMixerClamp=cReferenceSfxMixerClamp",
        "fb_sfxMixerSimdEnabled=cReferenceSfxMixerSimdEnabled",
        "fb_sfxMixerProcess=cReferenceSfxMixerProcess",
    )
    rename_options = ["-D" + symbol for symbol in renamed_symbols]

    reference_object = work / "sfx_mixer_reference.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", *rename_options,
        "-c", str(sfx_directory / "sfx_mixer.c"),
        "-o", str(reference_object),
    ], cwd=work)

    simd_object = work / "sfx_mixer_simd.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}",
        "-c", str(sfx_directory / "x86_64" / "sfx_simd.c"),
        "-o", str(simd_object),
    ], cwd=work)

    reference_probe = work / "sfx_mixer_reference_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", *rename_options,
        "-c", str(probe_source), "-o", str(reference_probe),
    ], cwd=work)
    reference_executable = work / "sfx_mixer_reference"
    run(cc + [
        str(reference_object), str(simd_object), str(reference_probe), "-lm",
        "-o", str(reference_executable),
    ], cwd=work)

    probe_object = work / "sfx_mixer_probe.o"
    run(cc + [
        "-std=c99", "-Wall", "-Wextra", "-Werror",
        f"-I{sfx_directory}", "-c", str(probe_source),
        "-o", str(probe_object),
    ], cwd=work)

    base_environment = os.environ.copy()
    base_environment["SFXLIB_MIXER_DEBUG"] = "0"
    base_environment.pop("SFXLIB_MIXER_DUMP", None)
    base_environment.pop("SFXLIB_MIXER_DUMP_FRAMES", None)

    for implementation, object_path in (
        ("C2FB candidate", candidate_object),
        ("integrated Basic", basic_object),
    ):
        executable = work / (
            "sfx_mixer_" + implementation.lower().replace(" ", "_")
        )
        run(fbc + [
            "-mt", "-w", "all", "-i", str(source_root.parent / "inc"),
            str(object_path), str(simd_object), str(probe_object), "-l", "m",
            "-x", str(executable),
        ], cwd=work)

    for simd_setting in ("0", "1"):
        runtime_environment = base_environment.copy()
        runtime_environment["SFXLIB_MIXER_SIMD"] = simd_setting
        expected = run(
            [str(reference_executable)], cwd=work, env=runtime_environment
        )
        for implementation in ("C2FB candidate", "integrated Basic"):
            executable = work / (
                "sfx_mixer_" + implementation.lower().replace(" ", "_")
            )
            observed = run(
                [str(executable)], cwd=work, env=runtime_environment
            )
            if observed != expected:
                raise AssertionError(
                    f"SFX mixer behavior differs for {implementation} "
                    f"with SIMD={simd_setting}: "
                    f"C={expected!r}, observed={observed!r}"
                )

    print(
        "SFX mixer: C2FB candidate and integrated Basic match C for clamp, "
        "clear, channel settings, voice allocation, scalar mixing, and "
        "scalar/SSE2 process paths"
    )


def check_root_sfx_candidates(converter, fbc, cc, source_root,
                              profile_directory, work):
    source_directory = source_root / "sfxlib"
    candidate_directory = work / "sfx-root-candidates"
    source_files = sorted(source_directory.glob("sfx_*.c"))
    header_profile = profile_directory / "freebasic-linux-glibc-x86_64.rsp"
    body_profile = profile_directory / "freebasic-linux-glibc-x86_64-body.rsp"
    unit_manifest = (
        profile_directory / "freebasic-sfxlib-linux-x86_64-units.json"
    )
    source_unit_tool = Path(__file__).resolve().parents[1] / "c2fb_source_unit.py"

    summary = run([
        sys.executable, str(source_unit_tool),
        str(source_directory), str(candidate_directory),
        "--tree", "--jobs=4", "--source-pattern=sfx_*.c",
        "--converter", converter, "--compiler", cc[0],
        "--unit-manifest", str(unit_manifest),
        "--header-option=--emit-source=*fb.h",
        "--header-option=--emit-source=*fb_*.h",
        "--body-option=--rename-proc-prefix=c2fbPorted_",
        "--header-compiler-option=" + f"-I{source_root / 'rtlib'}",
        "--header-compiler-option=" + f"-I{source_directory}",
        "--header-compiler-option=" + f"-I{source_directory / 'linux'}",
        "--header-compiler-option=" + f"-I{source_directory / 'unix'}",
        "--header-compiler-option=" + f"@{header_profile}",
        "--header-compiler-option=-DENABLE_MT",
        "--body-compiler-option=" + f"-I{source_root / 'rtlib'}",
        "--body-compiler-option=" + f"-I{source_directory}",
        "--body-compiler-option=" + f"-I{source_directory / 'linux'}",
        "--body-compiler-option=" + f"-I{source_directory / 'unix'}",
        "--body-compiler-option=" + f"@{body_profile}",
        "--body-compiler-option=-DENABLE_MT",
    ])
    if f"processed {len(source_files)} C files; failed 0" not in summary:
        raise AssertionError(summary)

    counts = [
        tuple(map(int, match))
        for match in ROOT_SFX_SUMMARY.findall(summary)
    ]
    if len(counts) != len(source_files):
        raise AssertionError(summary)
    skipped_count = sum(skipped for _, skipped in counts)
    if skipped_count != 0:
        raise AssertionError(summary)

    candidates = sorted(candidate_directory.rglob("*_candidates.bas"))
    if len(candidates) != len(source_files):
        raise AssertionError(summary)
    buffer_candidate = candidate_directory / "sfx_buffer_candidates.bas"
    if 'crt/longdouble.bi' in buffer_candidate.read_text():
        raise AssertionError(
            "scalar SFX buffer candidates should not import C long-double support"
        )
    for candidate in candidates:
        run(fbc + [
            "-w", "all", "-c", str(candidate),
            "-o", str(candidate.with_suffix(".o")),
            "-i", str(candidate.parent),
            "-i", str(source_root.parent / "inc"),
            "-i", str(source_root / "rtlib"),
            "-i", str(source_directory),
            "-i", str(source_directory / "linux"),
            "-i", str(source_directory / "unix"),
        ], cwd=candidate.parent)

    translated_count = sum(translated for translated, _ in counts)
    print(
        f"SFX root candidates: {len(candidates)} C files, "
        f"{translated_count} procedures, {skipped_count} skipped; "
        "all candidate objects compiled"
    )
    return candidate_directory


def main():
    parser = argparse.ArgumentParser(
        description="Run the focused FreeBASIC SFX source checks."
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
        parser.error("the current SFX C2FB profile requires Linux x86-64")

    helpers = load_c2fb_tests()
    source_root = helpers.freebasic_source_root(args.source_directory)
    sfx_directory = source_root / "sfxlib"
    if not sfx_directory.is_dir():
        parser.error(f"FreeBASIC SFX source directory is missing: {sfx_directory}")

    fbc = shlex.split(args.fbc)
    cc = shlex.split(args.cc)
    if not fbc or not cc:
        parser.error("--fbc and --cc must each contain a command")

    basic_sources = check_sfx_source_graph(source_root)
    with tempfile.TemporaryDirectory(prefix="c2fb-freebasic-sfx-") as temp:
        work = Path(temp)
        for source in basic_sources:
            relative_source = source.relative_to(sfx_directory)
            object_path = (
                work / "basic-objects" / relative_source.with_suffix(".o")
            )
            object_path.parent.mkdir(parents=True, exist_ok=True)
            run(fbc + [
                "-mt", "-w", "all", "-d", "FB_NO_GFXLIB",
                "-i", str(source_root.parent / "inc"),
                "-i", str(sfx_directory),
                "-i", str(source_root / "rtlib"),
                "-c", str(source), "-o", str(object_path),
            ], cwd=work)
        print(
            f"compiled {len(basic_sources)} FreeBASIC SFX modules "
            "selected by the active source graph"
        )

        runtime_checks = (
            helpers.check_freebasic_sfx_balance,
            helpers.check_freebasic_sfx_volume,
            helpers.check_freebasic_sfx_channel_cmd,
            helpers.check_freebasic_sfx_musical_state,
            helpers.check_freebasic_sfx_note,
            helpers.check_freebasic_sfx_command_adapters,
            helpers.check_freebasic_sfx_capture_read,
            helpers.check_freebasic_sfx_music_cmd,
            helpers.check_freebasic_sfx_midi_close,
            helpers.check_freebasic_sfx_midi_resume,
            helpers.check_freebasic_sfx_midi_stop,
        )
        for check in runtime_checks:
            check(fbc, cc, source_root, work)
        print(f"passed {len(runtime_checks)} focused SFX runtime-test groups")

        check_context_prefix(fbc, cc, source_root, work)
        check_sfx_music_status_prefix(fbc, cc, source_root, work)
        candidate_directory = check_root_sfx_candidates(
            args.converter, fbc, cc, source_root,
            Path(args.profile_directory).resolve(), work,
        )
        check_sfx_buffer_behavior(
            fbc, cc, source_root,
            work / "basic-objects" / "sfx_buffer.o",
            candidate_directory / "sfx_buffer_candidates.o",
            work,
        )
        check_sfx_envelope_behavior(
            fbc, cc, source_root,
            work / "basic-objects" / "sfx_envelope.o",
            candidate_directory / "sfx_envelope_candidates.o",
            work,
        )
        check_sfx_instrument_behavior(
            fbc, cc, source_root,
            work / "basic-objects" / "sfx_instrument.o",
            candidate_directory / "sfx_instrument_candidates.o",
            work,
        )
        check_sfx_waveform_behavior(
            fbc, cc, source_root,
            work / "basic-objects" / "sfx_waveform.o",
            candidate_directory / "sfx_waveform_candidates.o",
            work,
        )
        check_sfx_mixer_behavior(
            fbc, cc, source_root,
            work / "basic-objects" / "linux" / "x86_64" / "sfx_mixer.o",
            candidate_directory / "sfx_mixer_candidates.o",
            work,
        )
        check_sfx_voice_behavior(
            fbc, cc, source_root,
            work / "basic-objects" / "sfx_voice.o",
            candidate_directory / "sfx_voice_candidates.o",
            work,
        )
        check_sfx_oscillator_behavior(
            fbc, cc, source_root,
            work / "basic-objects" / "sfx_oscillator.o",
            candidate_directory / "sfx_oscillator_candidates.o",
            work,
        )
        check_sfx_voice_command(
            fbc, cc, source_root,
            work / "basic-objects" / "sfx_voice_cmd.o",
            candidate_directory / "sfx_voice_cmd_candidates.o",
            work,
        )
        check_sfx_wave_command(
            fbc, cc, source_root,
            work / "basic-objects" / "sfx_wave_cmd.o",
            candidate_directory / "sfx_wave_cmd_candidates.o",
            work,
        )
        check_sfx_capture_stop(
            fbc, cc, source_root,
            work / "basic-objects" / "sfx_capture_stop.o",
            candidate_directory / "sfx_capture_stop_candidates.o",
            work,
        )
        check_sfx_capture_start(
            fbc, cc, source_root,
            work / "basic-objects" / "sfx_capture_start.o",
            candidate_directory / "sfx_capture_start_candidates.o",
            work,
        )
        check_sfx_access(
            fbc, cc, source_root,
            work / "basic-objects" / "sfx_access.o",
            candidate_directory / "sfx_access_candidates.o",
            work,
        )
        check_sfx_debug_behavior(
            fbc, cc, source_root,
            work / "basic-objects" / "sfx_debug.o",
            candidate_directory / "sfx_debug_candidates.o", work,
        )
        check_sfx_midi_pause_behavior(
            fbc, cc, source_root,
            work / "basic-objects" / "sfx_midi_pause.o",
            candidate_directory / "sfx_midi_pause_candidates.o", work,
        )
        check_sfx_music_status_behavior(
            fbc, cc, source_root,
            work / "basic-objects" / "sfx_music_status.o",
            candidate_directory / "sfx_music_status_candidates.o", work,
        )
        check_sfx_music_controls_behavior(
            fbc, cc, source_root,
            work / "basic-objects" / "sfx_music_pause.o",
            work / "basic-objects" / "sfx_music_resume.o",
            candidate_directory / "sfx_music_pause_candidates.o",
            candidate_directory / "sfx_music_resume_candidates.o",
            work,
        )
        check_sfx_music_stop_behavior(
            fbc, cc, source_root,
            work / "basic-objects" / "sfx_music_stop.o",
            candidate_directory / "sfx_music_stop_candidates.o", work,
        )
        check_sfx_music_play_behavior(
            fbc, cc, source_root,
            work / "basic-objects" / "sfx_music_play.o",
            work / "basic-objects" / "sfx_music_stop.o",
            candidate_directory / "sfx_music_play_candidates.o", work,
        )
        check_sfx_music_load_behavior(
            fbc, cc, source_root,
            work / "basic-objects" / "sfx_music_load.o",
            work / "basic-objects" / "sfx_music_stop.o",
            candidate_directory / "sfx_music_load_candidates.o", work,
        )
        check_sfx_sfx_load_behavior(
            fbc, cc, source_root,
            work / "basic-objects" / "sfx_sfx_load.o",
            work / "basic-objects" / "sfx_music_stop.o",
            candidate_directory / "sfx_sfx_load_candidates.o", work,
        )


if __name__ == "__main__":
    main()

# end of test_freebasic_sfx.py
