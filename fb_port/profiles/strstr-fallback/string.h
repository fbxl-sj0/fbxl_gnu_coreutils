/*
    Project: GNU Coreutils FreeBASIC port

    File: fb_port/profiles/strstr-fallback/string.h

    Purpose:

        Expose ordinary string declarations while preprocessing the Gnulib
        strstr fallback on a glibc host.

    Responsibilities:

        - Include the configured project and system string declarations.
        - Remove libc's type-generic wrappers for strstr, strchr, and memchr.
        - Rename the fallback definition to rpl_strstr for comparison.

    This file intentionally does NOT contain:

        - String function implementations.
        - Changes to the upstream Coreutils source.
*/

#include_next <string.h>

#undef strstr
#undef strchr
#undef memchr

#define strstr rpl_strstr

/* end of string.h */
