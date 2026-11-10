/'
    Project: GNU Coreutils FreeBASIC port
    -------------------------------------

    File: coreutils_x87_support.bi

    Purpose:

        Preserve the x87 precision-control behavior required by GNU long-double
        helpers when their C inline assembly is not available to C2FB.

    Responsibilities:

        - Save the caller's x87 control word.
        - Select extended significand precision for a scoped calculation.
        - Restore the caller's complete control word afterward.

    This file intentionally does NOT contain:

        - Floating-point calculations or a general floating-point environment API.
        - Control-word changes on targets without x87 registers.
'/

Private Function C2FBCoreutilsBeginLongDoubleRounding() As UShort
#ifdef __FB_X86__
    Dim savedControlWord As UShort
    Dim extendedControlWord As UShort

    ' x87 PC bits 8-9 select precision; 0x0300 requests a 64-bit significand.
    Asm
        fnstcw [savedControlWord]
        mov ax, [savedControlWord]
        and ax, 0xfcff
        or ax, 0x0300
        mov [extendedControlWord], ax
        fldcw [extendedControlWord]
    End Asm

    Return savedControlWord
#else
    Return 0
#endif
End Function

Private Sub C2FBCoreutilsEndLongDoubleRounding( _
    ByVal savedControlWord As UShort)
#ifdef __FB_X86__
    Asm
        fldcw [savedControlWord]
    End Asm
#endif
End Sub

/' end of coreutils_x87_support.bi '/
