/'
    Project: GNU Coreutils FreeBASIC port
    --------------------------------------

    File: coreutils_dtimespec_support.bi

    Purpose:

        Preserve the sign of zero and provide a valid bound for the
        underflow case in dtimespec_bound.

    Responsibilities:

        - Call glibc's double signbit entrypoint through its C ABI.
        - Return a positive value permitted by the upstream underflow contract.

    This file intentionally does NOT contain:

        - Duration parsing or sleep scheduling.
        - General C long-double literal conversion.
'/
#include once "crt/errno.bi"

Declare Function CoreutilsGlibcSignBitDouble CDecl Alias "__signbit" _
    (ByVal value As Double) As Long

Private Function CoreutilsDtimespecSignBit(ByVal value As Double) As Long
    Return CoreutilsGlibcSignBitDouble(value)
End Function

Private Function CoreutilsDtimespecUnderflowBound() As Double
    ' dtimespec-bound.h permits any positive value below 1e-9 here.
    Return 1.0e-300
End Function

/' end of coreutils_dtimespec_support.bi '/
