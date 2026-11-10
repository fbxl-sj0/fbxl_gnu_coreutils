/'
    Project: GNU Coreutils FreeBASIC port
    --------------------------------------

    File: coreutils_oputs_support.bi

    Purpose:

        Supply small C-library ABI helpers used by translated Coreutils
        output routines.

    Responsibilities:

        - Declare isspace, strchr, and fwrite_unlocked with C ABI signatures.
        - Preserve access to stdout through its C library data symbol.
        - Read one byte for the translated isspace expression.

    This file intentionally does NOT contain:

        - Option formatting, dired position tracking, or ANSI markup policy.
        - C2FB translation rules.
        - General Coreutils compatibility declarations.
'/

' Coreutils' reference build targets Linux x86-64, where size_t is unsigned long.
Extern stdout Alias "stdout" As Any Ptr

Declare Function CoreutilsIsSpace CDecl Alias "isspace" _
    (ByVal value As Long) As Long
Declare Function strchr CDecl Alias "strchr" _
    (ByVal text As Const ZString Ptr, ByVal value As Long) As ZString Ptr
Declare Function CoreutilsFwriteUnlocked CDecl Alias "fwrite_unlocked" _
    (ByVal buffer As Const Any Ptr, ByVal size As CULong, _
     ByVal count As CULong, ByVal stream As Any Ptr) As CULong

' The replacement retains the original post-increment as a separate statement.
Private Function CoreutilsIsSpaceAtPointer(ByVal pointerAddress As Any Ptr) As Integer
    Dim cursorPointer As Const Byte Ptr Ptr = CPtr(Const Byte Ptr Ptr, pointerAddress)
    Dim byteValue As UByte = CUByte(**cursorPointer)
    Return IIf(CoreutilsIsSpace(CLng(byteValue)) <> 0, 1, 0)
End Function

Private Function CoreutilsStdout() As Any Ptr
    Return stdout
End Function

/' end of coreutils_oputs_support.bi '/
