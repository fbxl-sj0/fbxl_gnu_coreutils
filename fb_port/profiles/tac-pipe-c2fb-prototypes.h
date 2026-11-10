/*
    Project: GNU Coreutils FreeBASIC port

    File: tac-pipe-c2fb-prototypes.h

    Purpose:

        Provide the external declarations needed to translate the optional
        tac pipe helper with the configured Gnulib obstack ABI.

    Responsibilities:

        - Make the obstack initializer and GNU reverse-search signatures
          visible to C2FB's source-unit body pass.

    This file intentionally does NOT contain:

        - Implementations for obstack or memrchr.
        - FreeBASIC procedure declarations.
*/

#include <obstack.h>
#include <stddef.h>
#include <string.h>

extern int rpl_obstack_begin (struct obstack *h,
                              size_t size,
                              size_t alignment,
                              void *(*chunkfun) (size_t),
                              void (*freefun) (void *));

extern void *memrchr (void const *memory, int byte_value, size_t byte_count);

/* end of tac-pipe-c2fb-prototypes.h */
