/*
    Project: GNU Coreutils FreeBASIC port
    -------------------------------------

    File: localeconv-fallback-source-context.h

    Purpose:

        Select the Gnulib localeconv replacement branch for an isolated
        translation and runtime check of lib/localeconv.c.

    Responsibilities:

        - expose the lconv members present in the Linux test ABI
        - map the replacement function name while the wrapper header loads

    This file intentionally does NOT contain:

        - locale data or a replacement localeconv implementation
        - settings for the configured Coreutils Linux build
*/

#ifndef C2FB_LOCALECONV_FALLBACK_SOURCE_CONTEXT_H
#define C2FB_LOCALECONV_FALLBACK_SOURCE_CONTEXT_H

#define HAVE_STRUCT_LCONV_DECIMAL_POINT 1
#define HAVE_STRUCT_LCONV_INT_P_CS_PRECEDES 1

#include <locale.h>

/* The implementation must export rpl_localeconv and call libc localeconv. */
#undef localeconv
#define localeconv rpl_localeconv

#endif

/* end of localeconv-fallback-source-context.h */
