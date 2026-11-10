/'
    Project: GNU Coreutils FreeBASIC ABI support
    --------------------------------------------

    File: coreutils_glibc_abi.bi

    Purpose:

        Define FreeBASIC storage used to represent glibc x86-64 ABI types
        that the FreeBASIC CRT does not declare directly.

    Responsibilities:

        - Preserve the size and alignment of glibc's max_align_t carrier.

    This file intentionally does NOT contain:

        - C library declarations or runtime implementations.
'/

#include once "crt/longdouble.bi"

' Integer<128> supplies glibc's 16-byte alignment; CLongDouble fills the
' remaining bytes. This carrier is used only for max_align_t's storage layout.
Type CoreutilsGlibcMaxAlign
    maxAlignInteger As Integer<128>
    maxAlignLongDouble As CLongDouble
End Type

/' end of coreutils_glibc_abi.bi '/
