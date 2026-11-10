/*
    Project: GNU Coreutils FreeBASIC port
    -------------------------------------

    File: coreutils_cp_preinclude.h

    Purpose:

        Select the portable ASSIGN_STRDUPA implementation while C2FB scans
        cp.c, avoiding glibc's GNU statement-expression form of strdupa.

    Responsibilities:

        • Load the configured Coreutils feature macros
        • Undefine strdupa before system.h selects its portable fallback

    This file intentionally does NOT contain:

        • Coreutils command implementation
        • FreeBASIC declarations or generated translation output
*/

#ifndef COREUTILS_CP_PREINCLUDE_H
#define COREUTILS_CP_PREINCLUDE_H

#include <config.h>
#include <string.h>

#undef strdupa

#endif

/* end of coreutils_cp_preinclude.h */
