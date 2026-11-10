# Port status

## Build recorded 2026-11-10

- The fresh Coreutils 9.12 reference build captured 498 production compile
  contexts covering 485 source files.
- C2FB generated 498 FreeBASIC bodies and 498 type includes. The audit compiled
  all 498 modules, emitted 3,884 functions and 181 generated helpers, and found
  no missing candidates or reference symbols. Its 61 skipped functions are
  intentional repeated-header-helper exclusions.
- The FreeBASIC replacement archive contains 352 members and 721 global
  symbols. The linker localized 62 duplicate symbols to match C object
  visibility, then linked all 109 configured commands.
- The build used FreeBASIC 1.20.5-2 on Linux x86-64. It did not run the
  upstream test suite or verify runtime behavior for these newly linked
  binaries. Local outputs are under `fb_port/build/hybrid-built-now/` and are
  ignored by Git.

## Earlier test results

An earlier 104-command hybrid build passed 606 upstream tests, skipped 114,
and had no failures. Those results are historical and do not verify the
2026-11-10 build.

Windows and AArch64 runtime coverage remains incomplete. Keep a separate GNU
Coreutils 9.12 source checkout to reproduce the reference build, translation,
audit, and command links; its implementation sources are not included here.
