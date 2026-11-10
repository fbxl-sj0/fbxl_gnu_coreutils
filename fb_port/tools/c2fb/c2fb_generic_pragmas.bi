/'
    Project: C2FB generic C input

    File: c2fb_generic_pragmas.bi

    Purpose:

        Recognize the supported compiler library-link pragma in C input.

    Responsibilities:

        - Parse `#pragma comment(lib, "...")` with quoted-byte validation.
        - Decode the C escape sequences accepted in a library name.
        - Return only complete, non-empty library names to the scanner.

    This file intentionally does NOT contain:

        - General preprocessor evaluation or pragma execution.
        - C declaration lowering or FreeBASIC output formatting.
'/

Private Function ReadGenericPragmaIdentifier( _
    ByVal lineText As String, ByRef position As Long, _
    ByRef identifier As String _
) As Long
    While position <= Len(lineText) AndAlso IsSpaceByte(Asc(lineText, position)) <> 0
        position += 1
    Wend
    If position > Len(lineText) OrElse _
       IsIdentifierStart(Asc(lineText, position)) = 0 Then Return 0
    Dim tokenStart As Long = position
    position += 1
    While position <= Len(lineText) AndAlso _
          IsIdentifierPart(Asc(lineText, position)) <> 0
        position += 1
    Wend
    identifier = Mid(lineText, tokenStart, position - tokenStart)
    Return -1
End Function

Private Function GenericPragmaDigitValue(ByVal currentByte As Long) As Long
    If currentByte >= Asc("0") AndAlso currentByte <= Asc("9") Then _
        Return currentByte - Asc("0")
    If currentByte >= Asc("a") AndAlso currentByte <= Asc("f") Then _
        Return currentByte - Asc("a") + 10
    If currentByte >= Asc("A") AndAlso currentByte <= Asc("F") Then _
        Return currentByte - Asc("A") + 10
    Return -1
End Function

Private Function ReadGenericPragmaEscape( _
    ByVal lineText As String, ByRef position As Long, _
    ByRef byteValue As Long _
) As Long
    position += 1
    If position > Len(lineText) Then Return 0
    Dim escapeByte As Long = Asc(lineText, position)
    position += 1
    Select Case escapeByte
    Case Asc("a"): byteValue = 7
    Case Asc("b"): byteValue = 8
    Case Asc("t"): byteValue = 9
    Case Asc("n"): byteValue = 10
    Case Asc("v"): byteValue = 11
    Case Asc("f"): byteValue = 12
    Case Asc("r"): byteValue = 13
    Case Asc("\\"), Asc("'"), Asc(Chr(34)), Asc("?")
        byteValue = escapeByte
    Case Else
        Dim radix As Long = 8
        Dim maximumDigits As Long = 3
        If escapeByte = Asc("x") Then
            radix = 16
            maximumDigits = Len(lineText)
        ElseIf escapeByte >= Asc("0") AndAlso escapeByte <= Asc("7") Then
            position -= 1
        Else
            Return 0
        End If
        byteValue = 0
        Dim digitCount As Long = 0
        While position <= Len(lineText) AndAlso digitCount < maximumDigits
            Dim digit As Long = GenericPragmaDigitValue(Asc(lineText, position))
            If digit < 0 OrElse digit >= radix Then Exit While
            If byteValue > (255 - digit) \ radix Then Return 0
            byteValue = byteValue * radix + digit
            position += 1
            digitCount += 1
        Wend
        If digitCount = 0 Then Return 0
    End Select
    Return -1
End Function

Private Function ParseGenericLibraryPragma( _
    ByVal lineText As String, ByRef libraryName As String _
) As Long
    libraryName = ""
    Dim position As Long = 1
    While position <= Len(lineText) AndAlso IsSpaceByte(Asc(lineText, position)) <> 0
        position += 1
    Wend
    If position > Len(lineText) OrElse Asc(lineText, position) <> Asc("#") Then Return 0
    position += 1

    Dim directive As String
    If ReadGenericPragmaIdentifier(lineText, position, directive) = 0 OrElse _
       LCase(directive) <> "pragma" Then Return 0
    Dim pragmaName As String
    If ReadGenericPragmaIdentifier(lineText, position, pragmaName) = 0 OrElse _
       LCase(pragmaName) <> "comment" Then Return 0
    While position <= Len(lineText) AndAlso IsSpaceByte(Asc(lineText, position)) <> 0
        position += 1
    Wend
    If position > Len(lineText) OrElse Asc(lineText, position) <> Asc("(") Then Return 0
    position += 1

    Dim commentKind As String
    If ReadGenericPragmaIdentifier(lineText, position, commentKind) = 0 OrElse _
       LCase(commentKind) <> "lib" Then Return 0
    While position <= Len(lineText) AndAlso IsSpaceByte(Asc(lineText, position)) <> 0
        position += 1
    Wend
    If position > Len(lineText) OrElse Asc(lineText, position) <> Asc(",") Then Return 0
    position += 1
    While position <= Len(lineText) AndAlso IsSpaceByte(Asc(lineText, position)) <> 0
        position += 1
    Wend
    If position > Len(lineText) OrElse Asc(lineText, position) <> Asc(Chr(34)) Then Return 0

    position += 1
    Dim closedQuote As Long = 0
    While position <= Len(lineText)
        Dim currentByte As Long = Asc(lineText, position)
        If currentByte = Asc(Chr(34)) Then
            position += 1
            closedQuote = -1
            Exit While
        ElseIf currentByte = Asc(Chr(92)) Then
            If ReadGenericPragmaEscape(lineText, position, currentByte) = 0 Then Return 0
        Else
            position += 1
        End If
        If currentByte < 32 OrElse _
           currentByte = Asc(Chr(34)) Then Return 0
        libraryName &= Chr(currentByte)
    Wend
    If closedQuote = 0 Then Return 0
    While position <= Len(lineText) AndAlso IsSpaceByte(Asc(lineText, position)) <> 0
        position += 1
    Wend
    If position > Len(lineText) OrElse Asc(lineText, position) <> Asc(")") Then Return 0
    position += 1
    While position <= Len(lineText) AndAlso IsSpaceByte(Asc(lineText, position)) <> 0
        position += 1
    Wend
    If position <= Len(lineText) OrElse libraryName = "" Then Return 0
    Return -1
End Function

/' end of c2fb_generic_pragmas.bi '/
