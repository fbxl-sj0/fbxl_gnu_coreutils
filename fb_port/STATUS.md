# Port status

Last recorded full refresh: 2026-11-03.

- The production set covers 498 compiler contexts from 485 Coreutils source
  files. Its 498 FreeBASIC bodies and 498 type includes match the recorded
  current C2FB refresh.
- The audit recorded 3,884 translated functions, 181 generated helpers, and
  61 intentional repeated-header-helper exclusions. It reported no missing
  production candidates or missing reference symbols.
- A 104-command hybrid build passed the recorded upstream suite with 606
  passes, 114 skips, and no failures. These results are historical and depend
  on the Linux x86-64 toolchain and the external C support libraries.

This does not establish a complete native FreeBASIC port. Several generated
bodies remain partial candidates, and Windows and AArch64 runtime coverage is
incomplete. The upstream C source checkout is required to reproduce the
reference build, audit, and full test run.
