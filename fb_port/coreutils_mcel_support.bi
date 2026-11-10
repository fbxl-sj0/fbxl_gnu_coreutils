/'
    Project: GNU Coreutils FreeBASIC compatibility support
    ------------------------------------------------------

    File: coreutils_mcel_support.bi

    Purpose:

        Provide the fail-fast operation used when translating the preconditions
        in the GNU multibyte character helpers.

    Responsibilities:

        - Declare the C abort function with its Linux ABI signature.
        - Preserve GNU assume preconditions as fail-fast runtime checks.

    This file intentionally does NOT contain:

        - Multibyte decoding or character conversion logic.
        - C2FB parsing or translation rules.
'/

Declare Sub CoreutilsMcelAbort CDecl Alias "abort" ()

Private Sub CoreutilsMcelAssume(ByVal condition As Long)
    If condition = 0 Then CoreutilsMcelAbort()
End Sub

/' end of coreutils_mcel_support.bi '/
