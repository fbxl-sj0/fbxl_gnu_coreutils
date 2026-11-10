/'
    Project: SQLite FreeBASIC port tools

    File: c2fb_literals.bi

    Purpose:

        Read C literal values without changing their types or stored bytes.

    Responsibilities:

        - Validate bounded integer and floating constants, including exact
          decimal and hexadecimal C floating constants.
        - Decode C character and string escapes.
        - Emit string storage with static lifetime and a trailing NUL byte.

    This file intentionally does NOT contain:

        - Operator parsing, C preprocessor evaluation, or runtime allocations.
'/

Private Function ReadSimpleHexFloatingValue( _
    ByRef parser As SimpleExpressionParser, ByRef value As SimpleExpressionValue _
) As Long
    Dim position As Long = parser.position
    Dim start As Long = position
    If LCase(Mid(parser.sourceText, position, 2)) <> "0x" Then Return 0
    position += 2

    Dim digitCount As Long = 0
    While position <= Len(parser.sourceText) AndAlso _
          IsHexDigit(Asc(parser.sourceText, position)) <> 0
        position += 1
        digitCount += 1
    Wend
    If Mid(parser.sourceText, position, 1) = "." Then
        position += 1
        While position <= Len(parser.sourceText) AndAlso _
              IsHexDigit(Asc(parser.sourceText, position)) <> 0
            position += 1
            digitCount += 1
        Wend
    End If
    If digitCount = 0 OrElse LCase(Mid(parser.sourceText, position, 1)) <> "p" Then _
        Return 0
    position += 1
    If Mid(parser.sourceText, position, 1) = "+" OrElse _
       Mid(parser.sourceText, position, 1) = "-" Then position += 1
    Dim exponentStart As Long = position
    While position <= Len(parser.sourceText) AndAlso _
          Asc(parser.sourceText, position) >= Asc("0") AndAlso _
          Asc(parser.sourceText, position) <= Asc("9")
        position += 1
    Wend
    If position = exponentStart Then Return 0

    Dim literal As String = Mid(parser.sourceText, start, position - start)
    value.typeName = "Double"
    Dim suffix As String = LCase(Mid(parser.sourceText, position, 1))
    If suffix = "l" Then
        value.typeName = "CLongDouble"
        position += 1
    ElseIf suffix = "f" Then
        value.typeName = "Single"
        position += 1
    End If
    If position <= Len(parser.sourceText) AndAlso _
       IsIdentifierPart(Asc(parser.sourceText, position)) <> 0 Then Return 0

    Dim longDoubleValue As String = _
        "CLongDoubleFromStringValue(StrPtr(!""" & literal & """))"
    Select Case value.typeName
    Case "CLongDouble"
        value.text = longDoubleValue
    Case "Single"
        value.text = "CSng(" & longDoubleValue & ")"
    Case Else
        value.text = "CDbl(" & longDoubleValue & ")"
    End Select
    value.isLValue = 0
    parser.position = position
    Return -1
End Function

Private Function ReadSimpleFloatingValue( _
    ByRef parser As SimpleExpressionParser, ByRef value As SimpleExpressionValue _
) As Long
    Dim position As Long = parser.position
    Dim start As Long = position
    If LCase(Mid(parser.sourceText, position, 2)) = "0x" Then _
        Return ReadSimpleHexFloatingValue(parser, value)
    Dim digitCount As Long = 0
    While position <= Len(parser.sourceText) AndAlso _
          Asc(parser.sourceText, position) >= Asc("0") AndAlso Asc(parser.sourceText, position) <= Asc("9")
        position += 1
        digitCount += 1
    Wend
    Dim isFloating As Long = 0
    If Mid(parser.sourceText, position, 1) = "." Then
        isFloating = -1
        position += 1
        While position <= Len(parser.sourceText) AndAlso _
              Asc(parser.sourceText, position) >= Asc("0") AndAlso Asc(parser.sourceText, position) <= Asc("9")
            position += 1
            digitCount += 1
        Wend
    End If
    If digitCount = 0 Then Return 0
    If LCase(Mid(parser.sourceText, position, 1)) = "e" Then
        isFloating = -1
        position += 1
        If Mid(parser.sourceText, position, 1) = "+" OrElse Mid(parser.sourceText, position, 1) = "-" Then position += 1
        Dim exponentStart As Long = position
        While position <= Len(parser.sourceText) AndAlso _
              Asc(parser.sourceText, position) >= Asc("0") AndAlso Asc(parser.sourceText, position) <= Asc("9")
            position += 1
        Wend
        If position = exponentStart Then Return 0
    End If
    If isFloating = 0 Then Return 0
    Dim literal As String = Mid(parser.sourceText, start, position - start)
    value.typeName = "Double"
    ' lex.bas accepts # after a floating token; D is an exponent marker there.
    Dim suffix As String = "#"
    If LCase(Mid(parser.sourceText, position, 1)) = "l" Then
        value.typeName = "CLongDouble"
        suffix = ""
        position += 1
    ElseIf LCase(Mid(parser.sourceText, position, 1)) = "f" Then
        value.typeName = "Single"
        suffix = "f"
        position += 1
    End If
    If position <= Len(parser.sourceText) AndAlso IsIdentifierPart(Asc(parser.sourceText, position)) <> 0 Then Return 0
    If Left(literal, 1) = "." Then literal = "0" & literal
    If Right(literal, 1) = "." Then literal &= "0"
    If value.typeName = "CLongDouble" Then
        ' Keep the source decimal spelling until the CRT parses it as native
        ' long double; routing through Double would discard C's extra precision.
        value.text = "CLongDoubleFromStringValue(StrPtr(!""" & literal & """))"
    Else
        Dim magnitude As Double = Val(literal)
        If magnitude > 1.7976931348623157e308 Then Return 0
        If value.typeName = "Single" AndAlso magnitude > 3.4028234663852886e38 Then Return 0
        value.text = literal & suffix
        If value.typeName = "Single" Then value.text = "__c2fb_single_value(" & value.text & ")"
    End If
    value.isLValue = 0
    parser.position = position
    Return -1
End Function

Private Function ReadSimpleStringEscape( _
    ByRef parser As SimpleExpressionParser, ByRef byteValue As Long _
) As Long
    parser.position += 1
    If parser.position > Len(parser.sourceText) Then Return 0
    Dim c As Long = Asc(parser.sourceText, parser.position)
    parser.position += 1
    Select Case c
    ' GCC and Clang accept \e as the ASCII escape character.
    Case Asc("e"): byteValue = 27
    Case Asc("a"): byteValue = 7
    Case Asc("b"): byteValue = 8
    Case Asc("t"): byteValue = 9
    Case Asc("n"): byteValue = 10
    Case Asc("v"): byteValue = 11
    Case Asc("f"): byteValue = 12
    Case Asc("r"): byteValue = 13
    Case Asc("\"), Asc("'"), Asc(""""), Asc("?"): byteValue = c
    Case Else
        Dim radix As Long = 8
        Dim maximumDigits As Long = 3
        If c = Asc("x") Then
            radix = 16
            maximumDigits = Len(parser.sourceText)
        ElseIf c >= Asc("0") AndAlso c <= Asc("7") Then
            parser.position -= 1
        Else
            Return 0
        End If
        byteValue = 0
        Dim digitCount As Long = 0
        While parser.position <= Len(parser.sourceText) AndAlso digitCount < maximumDigits
            Dim digit As Long = SimpleDigitValue(Asc(parser.sourceText, parser.position))
            If digit < 0 OrElse digit >= radix Then Exit While
            If byteValue > (255 - digit) \ radix Then Return 0
            byteValue = byteValue * radix + digit
            parser.position += 1
            digitCount += 1
        Wend
        If digitCount = 0 Then Return 0
    End Select
    Return -1
End Function

Private Function ReadSimpleStringValue( _
    ByRef parser As SimpleExpressionParser, ByRef value As SimpleExpressionValue _
) As Long
    Dim literal As String
    Dim byteCount As Long = 0
    ' Bound generated literal storage independently of expression recursion.
    Do
        If Mid(parser.sourceText, parser.position, 1) <> Chr(34) Then Return 0
        parser.position += 1
        Dim hasClosingQuote As Long = 0
        While parser.position <= Len(parser.sourceText)
            Dim c As Long = Asc(parser.sourceText, parser.position)
            If c = Asc("""") Then
                parser.position += 1
                hasClosingQuote = -1
                Exit While
            ElseIf c = Asc("\") Then
                If ReadSimpleStringEscape(parser, c) = 0 Then Return 0
            Else
                If c = 10 OrElse c = 13 OrElse c = 0 Then Return 0
                parser.position += 1
            End If
            If byteCount >= MAX_C_STRING_LITERAL_BYTES Then Return 0
            If c >= 32 AndAlso c <= 126 AndAlso c <> Asc("\") AndAlso c <> Asc("""") Then
                literal &= Chr(c)
            Else
                ' FreeBASIC numeric string escapes are decimal and consume at
                ' most three digits. C octal and hex escapes were decoded above.
                literal &= "\" & Right("00" & Trim(Str(c)), 3)
            End If
            byteCount += 1
        Wend
        If hasClosingQuote = 0 Then Return 0
        SkipCSpaces(parser.sourceText, parser.position)
        If Mid(parser.sourceText, parser.position, 1) <> Chr(34) Then Exit Do
    Loop
    ' STRPTR on a literal uses static compiler storage, not a temporary STRING
    ' descriptor. Embedded NULs remain present and the compiler appends a NUL.
    value.text = "StrPtr(!""" & literal & """)"
    value.typeName = "Const ZString Ptr"
    value.isLValue = 0
    value.arrayCount = byteCount + 1
    Return -1
End Function

Private Function ReadSimpleWideStringValue( _
    ByRef parser As SimpleExpressionParser, ByRef value As SimpleExpressionValue _
) As Long
    Dim startPosition As Long = parser.position
    Dim endPosition As Long = startPosition
    Do
        If Mid(parser.sourceText, endPosition, 1) <> "L" OrElse _
           Mid(parser.sourceText, endPosition + 1, 1) <> Chr(34) Then Return 0
        endPosition += 2
        Dim hasClosingQuote As Long = 0
        While endPosition <= Len(parser.sourceText)
            Dim currentByte As Long = Asc(parser.sourceText, endPosition)
            If currentByte = Asc(Chr(34)) Then
                endPosition += 1
                hasClosingQuote = -1
                Exit While
            ElseIf currentByte = Asc(Chr(92)) Then
                endPosition += 2
            Else
                endPosition += 1
            End If
        Wend
        If hasClosingQuote = 0 Then Return 0
        SkipCSpaces(parser.sourceText, endPosition)
        If Mid(parser.sourceText, endPosition, 1) <> "L" OrElse _
           Mid(parser.sourceText, endPosition + 1, 1) <> Chr(34) Then Exit Do
    Loop

    Dim targetType As String = parser.targetType
    If targetType = "" Then
        Dim typeTokens(0 To 0) As String
        typeTokens(0) = "wchar_t"
        Dim resolvedType As C2fbResolvedTypeModel
        ResolveC2fbTypeModel( _
            parser.translation[0], parser.catalog[0], typeTokens(), _
            0, 0, resolvedType)
        If resolvedType.status <> C2FB_TYPE_RESOLUTION_RESOLVED OrElse _
           resolvedType.freeBasicType = "" Then Return 0
        targetType = resolvedType.freeBasicType & " Ptr"
    End If

    Dim pointerValue As String
    If TranslateGenericWideStringLiteralPointer( _
        parser.translation[0], _
        Mid(parser.sourceText, startPosition, endPosition - startPosition), _
        targetType, pointerValue) = 0 Then Return 0
    parser.position = endPosition
    value.text = pointerValue
    value.typeName = targetType
    value.layoutType = targetType
    value.storageType = targetType
    value.pointerCount = SimpleTypePointerDepth(targetType)
    value.isLValue = 0
    value.isAddressAccessor = 0
    value.isWholeCall = 0
    value.isFunctionDesignator = 0
    value.lValueText = ""
    Return -1
End Function

Private Function TranslateGenericHeaderStringMacro( _
    ByVal sourceText As String, ByRef outputValue As String _
) As Long
    sourceText = Trim(sourceText)
    While Left(sourceText, 1) = "("
        Dim closePosition As Long = 1
        If ScanSimpleExpressionGroup( _
            sourceText, closePosition, Asc("("), Asc(")")) = 0 OrElse _
           closePosition <= Len(sourceText) Then Exit While
        sourceText = Trim(Mid(sourceText, 2, Len(sourceText) - 2))
    Wend

    Dim isWideString As Long = 0
    If Left(sourceText, 1) = "L" AndAlso _
       Mid(sourceText, 2, 1) = Chr(34) Then
        sourceText = Mid(sourceText, 2)
        isWideString = -1
    End If

    Dim parser As SimpleExpressionParser
    parser.sourceText = sourceText
    parser.position = 1
    Dim value As SimpleExpressionValue
    If ReadSimpleStringValue(parser, value) = 0 Then Return 0
    If parser.position <= Len(parser.sourceText) Then Return 0
    If isWideString <> 0 Then
        If Left(value.text, 7) <> "StrPtr(" OrElse _
           Right(value.text, 1) <> ")" Then Return 0
        Dim literalText As String = _
            Mid(value.text, 8, Len(value.text) - 8)
        outputValue = "WStr(" & literalText & ")"
    Else
        outputValue = value.text
    End If
    Return -1
End Function

Private Function ReadSimpleIntegerValue( _
    ByRef parser As SimpleExpressionParser, ByRef value As SimpleExpressionValue _
) As Long
    Dim start As Long = parser.position
    Dim radix As ULongInt = 10
    If Mid(LCase(parser.sourceText), start, 2) = "0x" Then
        radix = 16
        parser.position += 2
    ElseIf Mid(parser.sourceText, start, 1) = "0" Then
        radix = 8
    End If
    Dim digitStart As Long = parser.position
    Dim magnitude As ULongInt = 0
    Const MAX_LITERAL As ULongInt = &HFFFFFFFFFFFFFFFFULL
    While parser.position <= Len(parser.sourceText)
        Dim digit As Long = SimpleDigitValue(Asc(parser.sourceText, parser.position))
        If digit < 0 OrElse CULngInt(digit) >= radix Then Exit While
        If magnitude > (MAX_LITERAL - CULngInt(digit)) \ radix Then Return 0
        magnitude = magnitude * radix + CULngInt(digit)
        parser.position += 1
    Wend
    If parser.position = digitStart Then Return 0
    Dim digits As String = Mid(parser.sourceText, digitStart, parser.position - digitStart)
    Dim suffixStart As Long = parser.position
    While parser.position <= Len(parser.sourceText) AndAlso _
          IsIdentifierPart(Asc(parser.sourceText, parser.position)) <> 0
        parser.position += 1
    Wend
    Dim suffix As String = LCase(Mid(parser.sourceText, suffixStart, parser.position - suffixStart))
    Dim isUnsigned As Long = 0
    Dim longCount As Long = 0
    Select Case suffix
    Case "":
    Case "u": isUnsigned = -1
    Case "l": longCount = 1
    Case "ul", "lu": isUnsigned = -1: longCount = 1
    Case "ll": longCount = 2
    Case "ull", "llu": isUnsigned = -1: longCount = 2
    Case Else: Return 0
    End Select

    Const MAX_INT As ULongInt = &H7FFFFFFF
    Const MAX_UINT As ULongInt = &HFFFFFFFFULL
    Const MAX_INT64 As ULongInt = &H7FFFFFFFFFFFFFFFULL
    Dim longIs64 As Long = 0
#if defined(__FB_64BIT__) AndAlso Not defined(__FB_WIN32__)
    longIs64 = -1
#endif
    If longCount = 2 Then
        value.typeName = IIf(isUnsigned <> 0, "c2fb_uint64", "c2fb_int64")
        If isUnsigned = 0 AndAlso magnitude > MAX_INT64 Then
            If radix = 10 Then Return 0
            value.typeName = "c2fb_uint64"
        End If
    ElseIf isUnsigned <> 0 Then
        If longCount = 0 AndAlso magnitude <= MAX_UINT Then
            value.typeName = "c2fb_c_uint"
        ElseIf longIs64 <> 0 OrElse magnitude <= MAX_UINT Then
            value.typeName = "c2fb_c_ulong"
        Else
            value.typeName = "c2fb_uint64"
        End If
    ElseIf longCount = 0 AndAlso magnitude <= MAX_INT Then
        value.typeName = "c2fb_c_int"
    ElseIf longCount = 0 AndAlso radix <> 10 AndAlso magnitude <= MAX_UINT Then
        value.typeName = "c2fb_c_uint"
    ElseIf longIs64 <> 0 AndAlso magnitude <= MAX_INT64 Then
        value.typeName = "c2fb_c_long"
    ElseIf longCount = 1 AndAlso longIs64 = 0 AndAlso magnitude <= MAX_INT Then
        value.typeName = "c2fb_c_long"
    ElseIf longCount = 1 AndAlso radix <> 10 AndAlso longIs64 = 0 AndAlso magnitude <= MAX_UINT Then
        value.typeName = "c2fb_c_ulong"
    ElseIf magnitude <= MAX_INT64 Then
        value.typeName = "c2fb_int64"
    ElseIf radix <> 10 Then
        value.typeName = "c2fb_uint64"
    Else
        Return 0
    End If

    Dim literal As String = digits
    If radix = 16 Then literal = "&H" & digits
    If radix = 8 Then literal = "&O" & digits
    ' An unsigned 64-bit source literal keeps the magnitude intact before the
    ' explicit C type conversion, even when FreeBASIC would infer a signed type.
    value.text = "Cast(" & value.typeName & ", " & literal & "ULL)"
    value.isLValue = 0
    Return -1
End Function

Private Function DecodeCCharacterConstant( _
    ByVal sourceText As String, ByRef position As Long, _
    ByRef characterValue As Long _
) As Long
    characterValue = 0
    If position > Len(sourceText) OrElse _
       Asc(sourceText, position) <> Asc("'") Then Return 0
    position += 1
    If position > Len(sourceText) Then Return 0
    Dim currentByte As Long = Asc(sourceText, position)
    position += 1
    If currentByte = Asc("\") Then
        If position > Len(sourceText) Then Return 0
        currentByte = Asc(sourceText, position)
        position += 1
        Select Case currentByte
        ' GCC and Clang use \e for the ESC control character.
        Case Asc("e"): currentByte = 27
        Case Asc("a"): currentByte = 7
        Case Asc("b"): currentByte = 8
        Case Asc("t"): currentByte = 9
        Case Asc("n"): currentByte = 10
        Case Asc("v"): currentByte = 11
        Case Asc("f"): currentByte = 12
        Case Asc("r"): currentByte = 13
        Case Asc("\"), Asc("'"), Asc(""""), Asc("?")
        Case Else
            Dim radix As Long = 8
            Dim maximumDigits As Long = 3
            If currentByte = Asc("x") Then
                radix = 16
                maximumDigits = Len(sourceText)
            ElseIf currentByte >= Asc("0") AndAlso currentByte <= Asc("7") Then
                position -= 1
            Else
                Return 0
            End If
            currentByte = 0
            Dim digitCount As Long = 0
            While position <= Len(sourceText) AndAlso digitCount < maximumDigits
                Dim digit As Long = SimpleDigitValue(Asc(sourceText, position))
                If digit < 0 OrElse digit >= radix Then Exit While
                ' Only single-byte ASCII values have a target-independent C int here.
                If currentByte > (127 - digit) \ radix Then Return 0
                currentByte = currentByte * radix + digit
                position += 1
                digitCount += 1
            Wend
            If digitCount = 0 Then Return 0
        End Select
    ElseIf currentByte = Asc("'") OrElse currentByte < 32 OrElse _
           currentByte > 126 Then
        Return 0
    End If
    If position > Len(sourceText) OrElse _
       Asc(sourceText, position) <> Asc("'") Then Return 0
    position += 1
    characterValue = currentByte
    Return -1
End Function

Private Function ReadSimpleCharacterValue( _
    ByRef parser As SimpleExpressionParser, ByRef value As SimpleExpressionValue _
) As Long
    Dim literalStart As Long = parser.position
    Dim isWideCharacter As Long = 0
    If Mid(parser.sourceText, parser.position, 2) = "L'" Then
        parser.position += 1
        isWideCharacter = -1
    End If
    Dim characterValue As Long
    If DecodeCCharacterConstant( _
        parser.sourceText, parser.position, characterValue) = 0 Then
        parser.position = literalStart
        Return 0
    End If
    If isWideCharacter <> 0 Then
        ' Use the matching generated or explicitly mapped C wchar_t type.
        Dim wideType As String = GenericTypeOverrideInPolicy( _
            parser.translation[0].genericC.policy, "wchar_t")
        If wideType = "" Then _
            wideType = MappedFbBodyTypeAlias( _
                parser.translation[0], parser.catalog[0], "wchar_t")
        If wideType = "" Then wideType = "wchar_t"
        value.text = "Cast(" & wideType & ", " & _
            Trim(Str(characterValue)) & ")"
        value.typeName = wideType
    Else
        value.text = "Cast(c2fb_c_int, " & Trim(Str(characterValue)) & ")"
        value.typeName = "c2fb_c_int"
    End If
    value.isLValue = 0
    Return -1
End Function

/' end of c2fb_literals.bi '/
