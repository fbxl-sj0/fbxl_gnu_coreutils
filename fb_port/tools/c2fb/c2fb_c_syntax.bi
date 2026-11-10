/'
    Project: C2FB C syntax helpers
    ------------------------------

    File: c2fb_c_syntax.bi

    Purpose:

        Provide bounded C text scanners shared by declaration, record,
        expression, and body conversion passes.

    Responsibilities:

        - Strip C comments without changing quoted string or character contents.
        - Recognize C and SQLite attribute tokens used by declaration lowering.
        - Define shared whitespace, identifier, qualifier, and digit predicates.
        - Distinguish declaration specifiers from identifier-shaped declarator names.
        - Scan balanced C source groups and skip C whitespace.
        - Decode ASCII digits shared by literal and array-bound parsing.
        - Parse bounded integer constant array bounds.
        - Split comma-delimited C lists while respecting nested groups and quotes.
        - Flatten bounded nested array initializers into row-major C values.

    This file intentionally does NOT contain:

        - C declaration or function-body translation policy.
        - FreeBASIC type mapping or generated output formatting.
'/

Private Function IsSpaceByte(ByVal c As Long) As Long
    Select Case c
    Case 9, 10, 13, 32
        Return -1
    End Select
    Return 0
End Function

Private Function IsIdentifierStart(ByVal c As Long) As Long
    Return CInt((c >= Asc("A") AndAlso c <= Asc("Z")) OrElse _
                (c >= Asc("a") AndAlso c <= Asc("z")) OrElse c = Asc("_"))
End Function

Private Function IsIdentifierPart(ByVal c As Long) As Long
    Return CInt(IsIdentifierStart(c) OrElse (c >= Asc("0") AndAlso c <= Asc("9")))
End Function

Private Function IsIdentifierToken(ByVal text As String) As Long
    If Len(text) = 0 OrElse IsIdentifierStart(Asc(text, 1)) = 0 Then Return 0
    For i As Long = 2 To Len(text)
        If IsIdentifierPart(Asc(text, i)) = 0 Then Return 0
    Next
    Return -1
End Function

Private Function IsCDeclarationSpecifierKeyword(ByVal token As String) As Long
    ' Type and storage specifiers are identifier-shaped, but cannot name a
    ' declarator. Without this check, the `int` in
    ' `unsigned int (*callback)(int)` can look like a function name and hide
    ' the file-scope callback object from later passes. Keep this list limited
    ' to declaration specifiers so ordinary C identifiers remain available.
    Select Case LCase(token)
    Case "auto", "char", "const", "double", "enum", "extern", "float", _
         "inline", "int", "long", "register", "restrict", "short", _
         "signed", "__signed", "__signed__", "static", "struct", "typedef", "union", "unsigned", _
         "void", "volatile", "_atomic", "_bool", "_complex", _
         "_imaginary", "_noreturn", "_thread_local"
        Return -1
    End Select
    Return 0
End Function

Private Function IsQualifierToken(ByVal text As String) As Long
    Select Case text
    Case "const", "volatile", "restrict", "__restrict", "__restrict__", "register"
        Return -1
    End Select
    Return 0
End Function

Private Function IsHexDigit(ByVal c As Long) As Long
    Return CInt((c >= Asc("0") AndAlso c <= Asc("9")) OrElse _
                (c >= Asc("A") AndAlso c <= Asc("F")) OrElse _
                (c >= Asc("a") AndAlso c <= Asc("f")))
End Function

Private Type SimpleArrayBoundParser
    sourceText As String
    position As Long
End Type

' Base64 lookup macros expand into 64 nested ternaries. Each branch passes
' through the expression-precedence readers before reaching the next one.
Private Const MAX_SIMPLE_ARRAY_BOUND_DEPTH As Long = 1024

Private Function SimpleDigitValue(ByVal c As Long) As Long
    If c >= Asc("0") AndAlso c <= Asc("9") Then Return c - Asc("0")
    If c >= Asc("a") AndAlso c <= Asc("f") Then Return c - Asc("a") + 10
    If c >= Asc("A") AndAlso c <= Asc("F") Then Return c - Asc("A") + 10
    Return -1
End Function

Private Function StripComments(ByVal inputLine As String, ByRef insideBlock As Long) As String
    Dim outputLine As String = ""
    Dim quote As Long = 0
    Dim i As Long = 1

    While i <= Len(inputLine)
        Dim c As Long = Asc(inputLine, i)

        If insideBlock <> 0 Then
            If c = Asc("*") AndAlso i < Len(inputLine) AndAlso Asc(inputLine, i + 1) = Asc("/") Then
                insideBlock = 0
                i += 2
            Else
                i += 1
            End If
        ElseIf quote <> 0 Then
            outputLine &= Chr(c)
            If c = Asc("\") AndAlso i < Len(inputLine) Then
                i += 1
                outputLine &= Mid(inputLine, i, 1)
            ElseIf c = quote Then
                quote = 0
            End If
            i += 1
        ElseIf c = Asc("'") OrElse c = Asc("""") Then
            quote = c
            outputLine &= Chr(c)
            i += 1
        ElseIf c = Asc("/") AndAlso i < Len(inputLine) AndAlso Asc(inputLine, i + 1) = Asc("*") Then
            insideBlock = -1
            outputLine &= " "
            i += 2
        ElseIf c = Asc("/") AndAlso i < Len(inputLine) AndAlso Asc(inputLine, i + 1) = Asc("/") Then
            Exit While
        Else
            outputLine &= Chr(c)
            i += 1
        End If
    Wend

    Return outputLine
End Function

Private Function IsAttributeToken(ByVal value As String) As Long
    Select Case LCase(value)
    Case "sqlite_api", "sqlite_extern", "sqlite_private", "sqlite_deprecated", _
         "sqlite_experimental", "sqlite_noinline", "sqlite_opt_inline", "sqlite_cdecl", _
         "extern", "inline", "__attribute__", "__declspec", _
         "cdecl", "__cdecl", "__cdecl__", "stdcall", "__stdcall", _
         "__stdcall__", "winapi", "apientry", "ntapi"
        Return -1
    End Select
    Return 0
End Function

Declare Function ReadSimpleArrayBoundExpression( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
Declare Function ReadSimpleArrayBoundTerm( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
Declare Function ReadSimpleArrayBoundShift( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
Declare Function ReadSimpleArrayBoundRelational( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
Declare Function ReadSimpleArrayBoundEquality( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
Declare Function ReadSimpleArrayBoundBitwiseAnd( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
Declare Function ReadSimpleArrayBoundBitwiseXor( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
Declare Function ReadSimpleArrayBoundBitwiseOr( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
Declare Function ReadSimpleArrayBoundLogicalAnd( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
Declare Function ReadSimpleArrayBoundLogicalOr( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
Declare Function ReadSimpleArrayBoundConditional( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
Declare Function ReadSimpleArrayBoundPrimary( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
Declare Function EvaluateSimpleArrayBound( _
    ByVal expression As String, _
    ByRef arrayCount As Long, _
    ByVal maximumCount As Long = MAX_SIMPLE_ARRAY_COUNT, _
    ByVal allowZero As Long = 0 _
) As Long

Private Function ScanSimpleExpressionGroup( _
    ByVal inputExpression As String, _
    ByRef position As Long, _
    ByVal openingByte As Long, _
    ByVal closingByte As Long _
) As Long
    If position > Len(inputExpression) OrElse _
       Asc(inputExpression, position) <> openingByte Then Return 0

    Dim depth As Long = 0
    Dim quoteByte As Long = 0
    While position <= Len(inputExpression)
        Dim currentByte As Long = Asc(inputExpression, position)
        If quoteByte <> 0 Then
            If currentByte = Asc("\\") Then
                position += 2
                Continue While
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
        ElseIf currentByte = Asc("'") OrElse currentByte = Asc("""") Then
            quoteByte = currentByte
        ElseIf currentByte = openingByte Then
            depth += 1
        ElseIf currentByte = closingByte Then
            depth -= 1
            If depth = 0 Then
                position += 1
                Return -1
            End If
        End If
        position += 1
    Wend
    Return 0
End Function

Private Sub SkipCSpaces(ByRef sourceText As String, ByRef position As Long)
    While position <= Len(sourceText) AndAlso IsSpaceByte(Asc(sourceText, position)) <> 0
        position += 1
    Wend
End Sub

Private Function DecodeCAssemblyNameLiteral( _
    ByVal literalText As String, ByRef linkName As String _
) As Long
    linkName = ""
    Dim position As Long = 1
    Const MAX_ASSEMBLY_NAME_LENGTH As Long = 4096
    While position <= Len(literalText)
        SkipCSpaces(literalText, position)
        If position > Len(literalText) Then Exit While
        If Asc(literalText, position) <> Asc(Chr(34)) Then Return 0
        position += 1

        Dim closedLiteral As Long = 0
        While position <= Len(literalText)
            Dim currentByte As Long = Asc(literalText, position)
            position += 1
            If currentByte = Asc(Chr(34)) Then
                closedLiteral = -1
                Exit While
            ElseIf currentByte = Asc("\\") Then
                If position > Len(literalText) Then Return 0
                currentByte = Asc(literalText, position)
                position += 1
                Select Case currentByte
                Case Asc("a"): currentByte = 7
                Case Asc("b"): currentByte = 8
                Case Asc("t"): currentByte = 9
                Case Asc("n"): currentByte = 10
                Case Asc("v"): currentByte = 11
                Case Asc("f"): currentByte = 12
                Case Asc("r"): currentByte = 13
                Case Asc("\\"), Asc("'"), Asc(Chr(34)), Asc("?")
                Case Asc("x")
                    Dim digitCount As Long = 0
                    currentByte = 0
                    While position <= Len(literalText)
                        Dim digit As Long = SimpleDigitValue( _
                            Asc(literalText, position))
                        If digit < 0 OrElse digit >= 16 Then Exit While
                        If currentByte > (126 - digit) \ 16 Then Return 0
                        currentByte = currentByte * 16 + digit
                        position += 1
                        digitCount += 1
                    Wend
                    If digitCount = 0 Then Return 0
                Case Asc("0") To Asc("7")
                    Dim digitCount As Long = 1
                    currentByte -= Asc("0")
                    While position <= Len(literalText) AndAlso digitCount < 3
                        Dim digit As Long = Asc(literalText, position) - Asc("0")
                        If digit < 0 OrElse digit > 7 Then Exit While
                        If currentByte > (126 - digit) \ 8 Then Return 0
                        currentByte = currentByte * 8 + digit
                        position += 1
                        digitCount += 1
                    Wend
                Case Else
                    Return 0
                End Select
            End If

            ' FreeBASIC Alias strings cannot safely carry NUL or control bytes.
            If currentByte < 32 OrElse currentByte > 126 Then Return 0
            If Len(linkName) >= MAX_ASSEMBLY_NAME_LENGTH Then Return 0
            linkName &= Chr(currentByte)
        Wend
        If closedLiteral = 0 Then Return 0
    Wend
    Return CInt(linkName <> "") * -1
End Function

Private Function CAssemblyNameHasSupportedSuffix( _
    ByVal declaration As String, ByVal position As Long _
) As Long
    While position <= Len(declaration)
        SkipCSpaces(declaration, position)
        If position > Len(declaration) Then Return -1

        Dim suffixByte As Long = Asc(declaration, position)
        If suffixByte = Asc(";") OrElse suffixByte = Asc(",") OrElse _
           suffixByte = Asc("=") Then Return -1
        If IsIdentifierStart(suffixByte) = 0 Then Return 0

        Dim tokenStart As Long = position
        position += 1
        While position <= Len(declaration) AndAlso _
              IsIdentifierPart(Asc(declaration, position)) <> 0
            position += 1
        Wend
        Dim attributeName As String = Mid( _
            declaration, tokenStart, position - tokenStart)
        If attributeName <> "__attribute__" AndAlso _
           attributeName <> "__declspec" Then Return 0

        SkipCSpaces(declaration, position)
        If position > Len(declaration) OrElse _
           Asc(declaration, position) <> Asc("(") Then Return 0
        If ScanSimpleExpressionGroup( _
            declaration, position, Asc("("), Asc(")")) = 0 Then Return 0
    Wend
    Return -1
End Function

Private Function ParseCAssemblyNameLabel( _
    ByVal declaration As String, ByRef loweredDeclaration As String, _
    ByRef linkName As String _
) As Long
    loweredDeclaration = declaration
    linkName = ""
    Dim parenthesisDepth As Long = 0
    Dim bracketDepth As Long = 0
    Dim braceDepth As Long = 0
    Dim quoteByte As Long = 0
    Dim position As Long = 1

    While position <= Len(declaration)
        Dim currentByte As Long = Asc(declaration, position)
        If quoteByte <> 0 Then
            If currentByte = Asc("\\") Then
                position += 2
                Continue While
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
            position += 1
            Continue While
        End If

        If currentByte = Asc("'") OrElse currentByte = Asc(Chr(34)) Then
            quoteByte = currentByte
            position += 1
            Continue While
        End If

        If IsIdentifierStart(currentByte) <> 0 Then
            Dim identifierStart As Long = position
            position += 1
            While position <= Len(declaration) AndAlso _
                  IsIdentifierPart(Asc(declaration, position)) <> 0
                position += 1
            Wend

            Dim identifierText As String = Mid( _
                declaration, identifierStart, position - identifierStart)
            If parenthesisDepth = 0 AndAlso bracketDepth = 0 AndAlso _
               braceDepth = 0 AndAlso _
               (identifierText = "asm" OrElse identifierText = "__asm" OrElse _
                identifierText = "__asm__") Then
                Dim openingPosition As Long = position
                SkipCSpaces(declaration, openingPosition)
                If openingPosition <= Len(declaration) AndAlso _
                   Asc(declaration, openingPosition) = Asc("(") Then
                    Dim closingPosition As Long = openingPosition
                    If ScanSimpleExpressionGroup( _
                        declaration, closingPosition, Asc("("), Asc(")")) <> 0 Then
                        Dim literalText As String = Mid( _
                            declaration, openingPosition + 1, _
                            closingPosition - openingPosition - 2)
                        Dim candidateLinkName As String
                        Dim afterGroup As Long = closingPosition
                        If CAssemblyNameHasSupportedSuffix( _
                            declaration, afterGroup) <> 0 Then
                            loweredDeclaration = _
                                Left(declaration, identifierStart - 1) & _
                                Mid(declaration, closingPosition)
                            If DecodeCAssemblyNameLiteral( _
                                literalText, candidateLinkName) <> 0 Then
                                linkName = candidateLinkName
                                Return -1
                            End If
                            Return 1
                        End If
                    End If
                End If
            End If
            Continue While
        End If

        Select Case currentByte
        Case Asc("("): parenthesisDepth += 1
        Case Asc(")"): If parenthesisDepth > 0 Then parenthesisDepth -= 1
        Case Asc("["): bracketDepth += 1
        Case Asc("]"): If bracketDepth > 0 Then bracketDepth -= 1
        Case Asc("{"): braceDepth += 1
        Case Asc("}"): If braceDepth > 0 Then braceDepth -= 1
        End Select
        position += 1
    Wend
    Return 0
End Function

/' ------------------------------------------------------------------------- '/
/' Fixed integer array bounds                                                '/
/' ------------------------------------------------------------------------- '/

Private Function ReadSimpleArrayBoundLiteral( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt _
) As Long
    SkipCSpaces(parser.sourceText, parser.position)
    If parser.position > Len(parser.sourceText) Then Return 0

    If Asc(parser.sourceText, parser.position) = Asc("'") Then
        Dim characterPosition As Long = parser.position
        Dim characterValue As Long
        If DecodeCCharacterConstant( _
            parser.sourceText, characterPosition, characterValue) = 0 Then _
            Return 0
        parser.position = characterPosition
        value = characterValue
        Return -1
    End If

    Dim radix As ULongInt = 10
    If LCase(Mid(parser.sourceText, parser.position, 2)) = "0x" Then
        radix = 16
        parser.position += 2
    ElseIf Mid(parser.sourceText, parser.position, 1) = "0" Then
        radix = 8
    End If

    Dim digitStart As Long = parser.position
    Dim magnitude As ULongInt = 0
    While parser.position <= Len(parser.sourceText)
        Dim digit As Long = SimpleDigitValue(Asc(parser.sourceText, parser.position))
        If digit < 0 OrElse CULngInt(digit) >= radix Then Exit While
        If magnitude > (MAX_GENERIC_ARRAY_BOUND_MAGNITUDE - CULngInt(digit)) \ radix Then Return 0
        magnitude = magnitude * radix + CULngInt(digit)
        parser.position += 1
    Wend
    If parser.position = digitStart Then Return 0

    Dim suffixStart As Long = parser.position
    While parser.position <= Len(parser.sourceText) AndAlso _
          (Asc(parser.sourceText, parser.position) = Asc("u") OrElse _
           Asc(parser.sourceText, parser.position) = Asc("U") OrElse _
           Asc(parser.sourceText, parser.position) = Asc("l") OrElse _
           Asc(parser.sourceText, parser.position) = Asc("L"))
        parser.position += 1
    Wend
    Dim suffix As String = LCase(Mid(parser.sourceText, suffixStart, parser.position - suffixStart))
    Select Case suffix
    Case "", "u", "l", "ul", "lu", "ll", "ull", "llu"
    Case Else
        Return 0
    End Select

    value = CLngInt(magnitude)
    Return -1
End Function

Private Function ReadSimpleArrayBoundPrimary( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
    If depth > MAX_SIMPLE_ARRAY_BOUND_DEPTH Then Return 0
    SkipCSpaces(parser.sourceText, parser.position)
    If parser.position > Len(parser.sourceText) Then Return 0

    Dim nextByte As Long = Asc(parser.sourceText, parser.position)
    If nextByte = Asc("+") OrElse nextByte = Asc("-") Then
        parser.position += 1
        If ReadSimpleArrayBoundPrimary(parser, value, depth + 1) = 0 Then Return 0
        If nextByte = Asc("-") Then value = -value
        Return -1
    End If

    If nextByte = Asc("(") Then
        parser.position += 1
        If ReadSimpleArrayBoundConditional(parser, value, depth + 1) = 0 Then Return 0
        SkipCSpaces(parser.sourceText, parser.position)
        If parser.position > Len(parser.sourceText) OrElse _
           Asc(parser.sourceText, parser.position) <> Asc(")") Then Return 0
        parser.position += 1
        Return -1
    End If

    Return ReadSimpleArrayBoundLiteral(parser, value)
End Function

Private Function ReadSimpleArrayBoundTerm( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
    If ReadSimpleArrayBoundPrimary(parser, value, depth + 1) = 0 Then Return 0
    While 1
        SkipCSpaces(parser.sourceText, parser.position)
        If parser.position > Len(parser.sourceText) Then Exit While
        Dim operation As Long = Asc(parser.sourceText, parser.position)
        If operation <> Asc("*") AndAlso operation <> Asc("/") AndAlso _
           operation <> Asc("%") Then Exit While
        parser.position += 1

        Dim rightValue As LongInt
        If ReadSimpleArrayBoundPrimary(parser, rightValue, depth + 1) = 0 Then Return 0
        Select Case operation
        Case Asc("*")
            If value <> 0 AndAlso rightValue <> 0 AndAlso _
               Abs(value) > MAX_GENERIC_ARRAY_BOUND_VALUE \ Abs(rightValue) Then Return 0
            value *= rightValue
        Case Asc("/")
            If rightValue = 0 Then Return 0
            value \= rightValue
        Case Asc("%")
            If rightValue = 0 Then Return 0
            value Mod= rightValue
        End Select
        If value < -MAX_GENERIC_ARRAY_BOUND_VALUE OrElse _
           value > MAX_GENERIC_ARRAY_BOUND_VALUE Then Return 0
    Wend
    Return -1
End Function

Private Function ReadSimpleArrayBoundShift( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
    If ReadSimpleArrayBoundExpression(parser, value, depth + 1) = 0 Then Return 0
    Dim maximumShift As Long = 0
    Dim maximumFactor As LongInt = 1
    While maximumFactor <= MAX_GENERIC_ARRAY_BOUND_VALUE \ 2
        maximumFactor *= 2
        maximumShift += 1
    Wend

    While 1
        SkipCSpaces(parser.sourceText, parser.position)
        If parser.position > Len(parser.sourceText) Then Exit While
        Dim operation As String = Mid(parser.sourceText, parser.position, 2)
        If operation <> "<<" AndAlso operation <> ">>" Then Exit While
        parser.position += 2

        Dim shiftCount As LongInt
        If ReadSimpleArrayBoundExpression(parser, shiftCount, depth + 1) = 0 OrElse _
           value < 0 OrElse shiftCount < 0 OrElse shiftCount > maximumShift Then _
            Return 0
        Dim factor As LongInt = 1
        For i As LongInt = 1 To shiftCount
            factor *= 2
        Next
        If operation = "<<" Then
            If value <> 0 AndAlso _
               value > MAX_GENERIC_ARRAY_BOUND_VALUE \ factor Then Return 0
            value *= factor
        Else
            value \= factor
        End If
        If value > MAX_GENERIC_ARRAY_BOUND_VALUE Then Return 0
    Wend
    Return -1
End Function

Private Function ReadSimpleArrayBoundRelational( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
    If depth > MAX_SIMPLE_ARRAY_BOUND_DEPTH OrElse _
       ReadSimpleArrayBoundShift(parser, value, depth + 1) = 0 Then Return 0
    While 1
        SkipCSpaces(parser.sourceText, parser.position)
        If parser.position > Len(parser.sourceText) Then Exit While
        Dim operation As String = Mid(parser.sourceText, parser.position, 2)
        Dim operatorWidth As Long = 2
        If operation <> "<=" AndAlso operation <> ">=" Then
            If Asc(parser.sourceText, parser.position) = Asc("<") AndAlso _
               Mid(parser.sourceText, parser.position, 2) <> "<<" Then
                operation = "<"
                operatorWidth = 1
            ElseIf Asc(parser.sourceText, parser.position) = Asc(">") AndAlso _
                   Mid(parser.sourceText, parser.position, 2) <> ">>" Then
                operation = ">"
                operatorWidth = 1
            Else
                Exit While
            End If
        End If
        parser.position += operatorWidth

        Dim rightValue As LongInt
        If ReadSimpleArrayBoundShift(parser, rightValue, depth + 1) = 0 Then Return 0
        Dim comparisonResult As Long = 0
        Select Case operation
        Case "<": If value < rightValue Then comparisonResult = 1
        Case "<=": If value <= rightValue Then comparisonResult = 1
        Case ">": If value > rightValue Then comparisonResult = 1
        Case ">=": If value >= rightValue Then comparisonResult = 1
        End Select
        value = comparisonResult
    Wend
    Return -1
End Function

Private Function ReadSimpleArrayBoundEquality( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
    If depth > MAX_SIMPLE_ARRAY_BOUND_DEPTH OrElse _
       ReadSimpleArrayBoundRelational(parser, value, depth + 1) = 0 Then Return 0
    While 1
        SkipCSpaces(parser.sourceText, parser.position)
        If parser.position > Len(parser.sourceText) Then Exit While
        Dim operation As String = Mid(parser.sourceText, parser.position, 2)
        If operation <> "==" AndAlso operation <> "!=" Then Exit While
        parser.position += 2

        Dim rightValue As LongInt
        If ReadSimpleArrayBoundRelational(parser, rightValue, depth + 1) = 0 Then Return 0
        If operation = "==" Then
            value = CInt(value = rightValue)
        Else
            value = CInt(value <> rightValue)
        End If
        If value <> 0 Then value = 1
    Wend
    Return -1
End Function

Private Function ReadSimpleArrayBoundBitwiseAnd( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
    If ReadSimpleArrayBoundEquality(parser, value, depth + 1) = 0 Then Return 0
    While 1
        SkipCSpaces(parser.sourceText, parser.position)
        If parser.position > Len(parser.sourceText) OrElse _
           Mid(parser.sourceText, parser.position, 2) = "&&" OrElse _
           Asc(parser.sourceText, parser.position) <> Asc("&") Then Exit While
        parser.position += 1
        Dim rightValue As LongInt
        If ReadSimpleArrayBoundEquality(parser, rightValue, depth + 1) = 0 Then Return 0
        value = value And rightValue
        If value < -MAX_GENERIC_ARRAY_BOUND_VALUE OrElse _
           value > MAX_GENERIC_ARRAY_BOUND_VALUE Then Return 0
    Wend
    Return -1
End Function

Private Function ReadSimpleArrayBoundBitwiseXor( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
    If ReadSimpleArrayBoundBitwiseAnd(parser, value, depth + 1) = 0 Then Return 0
    While 1
        SkipCSpaces(parser.sourceText, parser.position)
        If parser.position > Len(parser.sourceText) OrElse _
           Asc(parser.sourceText, parser.position) <> Asc("^") Then Exit While
        parser.position += 1
        Dim rightValue As LongInt
        If ReadSimpleArrayBoundBitwiseAnd(parser, rightValue, depth + 1) = 0 Then Return 0
        value = value Xor rightValue
        If value < -MAX_GENERIC_ARRAY_BOUND_VALUE OrElse _
           value > MAX_GENERIC_ARRAY_BOUND_VALUE Then Return 0
    Wend
    Return -1
End Function

Private Function ReadSimpleArrayBoundBitwiseOr( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
    If ReadSimpleArrayBoundBitwiseXor(parser, value, depth + 1) = 0 Then Return 0
    While 1
        SkipCSpaces(parser.sourceText, parser.position)
        If parser.position > Len(parser.sourceText) OrElse _
           Mid(parser.sourceText, parser.position, 2) = "||" OrElse _
           Asc(parser.sourceText, parser.position) <> Asc("|") Then Exit While
        parser.position += 1
        Dim rightValue As LongInt
        If ReadSimpleArrayBoundBitwiseXor(parser, rightValue, depth + 1) = 0 Then Return 0
        value = value Or rightValue
        If value < -MAX_GENERIC_ARRAY_BOUND_VALUE OrElse _
           value > MAX_GENERIC_ARRAY_BOUND_VALUE Then Return 0
    Wend
    Return -1
End Function

Private Function ReadSimpleArrayBoundLogicalAnd( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
    If depth > MAX_SIMPLE_ARRAY_BOUND_DEPTH OrElse _
       ReadSimpleArrayBoundBitwiseOr(parser, value, depth + 1) = 0 Then Return 0
    While 1
        SkipCSpaces(parser.sourceText, parser.position)
        If parser.position > Len(parser.sourceText) OrElse _
           Mid(parser.sourceText, parser.position, 2) <> "&&" Then Exit While
        parser.position += 2
        Dim rightValue As LongInt
        If ReadSimpleArrayBoundBitwiseOr(parser, rightValue, depth + 1) = 0 Then Return 0
        If value <> 0 AndAlso rightValue <> 0 Then
            value = 1
        Else
            value = 0
        End If
    Wend
    Return -1
End Function

Private Function ReadSimpleArrayBoundLogicalOr( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
    If depth > MAX_SIMPLE_ARRAY_BOUND_DEPTH OrElse _
       ReadSimpleArrayBoundLogicalAnd(parser, value, depth + 1) = 0 Then Return 0
    While 1
        SkipCSpaces(parser.sourceText, parser.position)
        If parser.position > Len(parser.sourceText) OrElse _
           Mid(parser.sourceText, parser.position, 2) <> "||" Then Exit While
        parser.position += 2
        Dim rightValue As LongInt
        If ReadSimpleArrayBoundLogicalAnd(parser, rightValue, depth + 1) = 0 Then Return 0
        If value <> 0 OrElse rightValue <> 0 Then
            value = 1
        Else
            value = 0
        End If
    Wend
    Return -1
End Function

Private Function ReadSimpleArrayBoundConditional( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
    If depth > MAX_SIMPLE_ARRAY_BOUND_DEPTH OrElse _
       ReadSimpleArrayBoundLogicalOr(parser, value, depth + 1) = 0 Then Return 0
    SkipCSpaces(parser.sourceText, parser.position)
    If parser.position > Len(parser.sourceText) OrElse _
       Asc(parser.sourceText, parser.position) <> Asc("?") Then Return -1
    parser.position += 1

    Dim trueValue As LongInt
    If ReadSimpleArrayBoundConditional(parser, trueValue, depth + 1) = 0 Then Return 0
    SkipCSpaces(parser.sourceText, parser.position)
    If parser.position > Len(parser.sourceText) OrElse _
       Asc(parser.sourceText, parser.position) <> Asc(":") Then Return 0
    parser.position += 1

    Dim falseValue As LongInt
    If ReadSimpleArrayBoundConditional(parser, falseValue, depth + 1) = 0 Then Return 0
    If value <> 0 Then
        value = trueValue
    Else
        value = falseValue
    End If
    Return -1
End Function

Private Function ReadSimpleArrayBoundExpression( _
    ByRef parser As SimpleArrayBoundParser, _
    ByRef value As LongInt, _
    ByVal depth As Long _
) As Long
    If ReadSimpleArrayBoundTerm(parser, value, depth + 1) = 0 Then Return 0
    While 1
        SkipCSpaces(parser.sourceText, parser.position)
        If parser.position > Len(parser.sourceText) Then Exit While
        Dim operation As Long = Asc(parser.sourceText, parser.position)
        If operation <> Asc("+") AndAlso operation <> Asc("-") Then Exit While
        parser.position += 1

        Dim rightValue As LongInt
        If ReadSimpleArrayBoundTerm(parser, rightValue, depth + 1) = 0 Then Return 0
        If operation = Asc("+") Then
            If rightValue > 0 AndAlso value > MAX_GENERIC_ARRAY_BOUND_VALUE - rightValue Then Return 0
            If rightValue < 0 AndAlso value < -MAX_GENERIC_ARRAY_BOUND_VALUE - rightValue Then Return 0
            value += rightValue
        Else
            If rightValue < 0 AndAlso value > MAX_GENERIC_ARRAY_BOUND_VALUE + rightValue Then Return 0
            If rightValue > 0 AndAlso value < -MAX_GENERIC_ARRAY_BOUND_VALUE + rightValue Then Return 0
            value -= rightValue
        End If
    Wend
    Return -1
End Function

Private Function EvaluateSimpleArrayBound( _
    ByVal expression As String, _
    ByRef arrayCount As Long, _
    ByVal maximumCount As Long = MAX_SIMPLE_ARRAY_COUNT, _
    ByVal allowZero As Long = 0 _
) As Long
    Dim parser As SimpleArrayBoundParser
    parser.sourceText = expression
    parser.position = 1
    Dim value As LongInt
    If ReadSimpleArrayBoundConditional(parser, value, 0) = 0 Then Return 0
    SkipCSpaces(parser.sourceText, parser.position)
    If parser.position <= Len(parser.sourceText) OrElse value < 0 OrElse _
       (value = 0 AndAlso allowZero = 0) OrElse _
       maximumCount < 1 OrElse maximumCount > MAX_GENERIC_ARRAY_COUNT OrElse _
       value > maximumCount Then Return 0
    arrayCount = CLng(value)
    Return -1
End Function

' Find the C initializer assignment without scanning large array values as declarator tokens.
Private Function FindSimpleAssignmentEquals(ByVal sourceText As String) As Long
    Dim parenDepth As Long = 0
    Dim bracketDepth As Long = 0
    Dim braceDepth As Long = 0
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    Dim position As Long = 1
    While position <= Len(sourceText)
        Dim currentByte As Long = Asc(sourceText, position)
        If quoteByte <> 0 Then
            If escaped <> 0 Then
                escaped = 0
            ElseIf currentByte = Asc(Chr(92)) Then
                escaped = -1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
        ElseIf Mid(sourceText, position, 2) = "/*" Then
            Dim commentEnd As Long = InStr(position + 2, sourceText, "*/")
            If commentEnd = 0 Then Return 0
            position = commentEnd + 2
            Continue While
        ElseIf Mid(sourceText, position, 2) = "//" Then
            Dim lineEnd As Long = InStr(position + 2, sourceText, Chr(10))
            If lineEnd = 0 Then Return 0
            position = lineEnd + 1
            Continue While
        ElseIf currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
            quoteByte = currentByte
        ElseIf currentByte = Asc("(") Then
            parenDepth += 1
        ElseIf currentByte = Asc(")") Then
            parenDepth -= 1
            If parenDepth < 0 Then Return 0
        ElseIf currentByte = Asc("[") Then
            bracketDepth += 1
        ElseIf currentByte = Asc("]") Then
            bracketDepth -= 1
            If bracketDepth < 0 Then Return 0
        ElseIf currentByte = Asc("{") Then
            braceDepth += 1
        ElseIf currentByte = Asc("}") Then
            braceDepth -= 1
            If braceDepth < 0 Then Return 0
        ElseIf currentByte = Asc("=") AndAlso parenDepth = 0 AndAlso _
               bracketDepth = 0 AndAlso braceDepth = 0 Then
            Dim previousByte As Long
            Dim nextByte As Long
            If position > 1 Then previousByte = Asc(sourceText, position - 1)
            If position < Len(sourceText) Then nextByte = Asc(sourceText, position + 1)
            If nextByte <> Asc("=") AndAlso _
               previousByte <> Asc("=") AndAlso _
               previousByte <> Asc("!") AndAlso _
               previousByte <> Asc("<") AndAlso _
               previousByte <> Asc(">") AndAlso _
               previousByte <> Asc("+") AndAlso _
               previousByte <> Asc("-") AndAlso _
               previousByte <> Asc("*") AndAlso _
               previousByte <> Asc("/") AndAlso _
               previousByte <> Asc("%") AndAlso _
               previousByte <> Asc("&") AndAlso _
               previousByte <> Asc("|") AndAlso _
               previousByte <> Asc("^") Then Return position
        End If
        position += 1
    Wend
    Return 0
End Function

Private Function SplitSimpleCList( _
    ByVal sourceText As String, parts() As String, ByRef partCount As Long, _
    ByVal allowTrailingComma As Long = 0, _
    ByVal maximumPartCount As Long = MAX_SIMPLE_VARIABLES _
) As Long
    If maximumPartCount < 1 OrElse _
       maximumPartCount > MAX_GENERIC_ARRAY_COUNT Then Return 0
    ReDim parts(0 To 7)
    partCount = 0
    Dim start As Long = 1
    Dim parenDepth As Long = 0
    Dim bracketDepth As Long = 0
    Dim braceDepth As Long = 0
    Dim quoteByte As Long = 0
    For i As Long = 1 To Len(sourceText) + 1
        Dim c As Long = IIf(i <= Len(sourceText), Asc(sourceText, i), Asc(","))
        If quoteByte <> 0 Then
            If c = Asc("\") Then
                i += 1
            ElseIf c = quoteByte Then
                quoteByte = 0
            End If
        ElseIf c = Asc("'") OrElse c = Asc("""") Then
            quoteByte = c
        ElseIf c = Asc("(") Then
            parenDepth += 1
        ElseIf c = Asc(")") Then
            parenDepth -= 1
        ElseIf c = Asc("[") Then
            bracketDepth += 1
        ElseIf c = Asc("]") Then
            bracketDepth -= 1
        ElseIf c = Asc("{") Then
            braceDepth += 1
        ElseIf c = Asc("}") Then
            braceDepth -= 1
        ElseIf c = Asc(",") AndAlso parenDepth = 0 AndAlso bracketDepth = 0 AndAlso braceDepth = 0 Then
            If partCount >= maximumPartCount Then Return 0
            If partCount > UBound(parts) Then ReDim Preserve parts(0 To UBound(parts) * 2 + 1)
            parts(partCount) = Trim(Mid(sourceText, start, i - start))
            If parts(partCount) = "" Then
                ' C permits one trailing comma in enum and initializer lists.
                If allowTrailingComma <> 0 AndAlso i > Len(sourceText) AndAlso _
                   partCount > 0 Then Exit For
                Return 0
            End If
            partCount += 1
            start = i + 1
        End If
        If parenDepth < 0 OrElse bracketDepth < 0 OrElse braceDepth < 0 Then Return 0
    Next
    Return CInt(parenDepth = 0 AndAlso bracketDepth = 0 AndAlso braceDepth = 0 AndAlso quoteByte = 0)
End Function

Private Function UnwrapSimpleCScalarArrayInitializer( _
    ByVal sourceText As String, ByRef scalarText As String _
) As Long
    sourceText = Trim(sourceText)
    scalarText = ""
    While Left(sourceText, 1) = "{" AndAlso Right(sourceText, 1) = "}"
        Dim groupEndPosition As Long = 1
        If ScanSimpleExpressionGroup( _
            sourceText, groupEndPosition, Asc("{"), Asc("}")) = 0 OrElse _
           Trim(Mid(sourceText, groupEndPosition)) <> "" Then Return 0

        Dim groupBody As String = Trim(Mid( _
            sourceText, 2, groupEndPosition - 3))
        Dim parts() As String
        Dim partCount As Long
        If SplitSimpleCList(groupBody, parts(), partCount, -1) = 0 OrElse _
           partCount <> 1 Then Return 0
        sourceText = Trim(parts(0))
    Wend

    If sourceText = "" Then Return 0
    scalarText = sourceText
    Return -1
End Function

Private Function FlattenSimpleCArrayInitializer( _
    ByVal initializerText As String, dimensions() As Long, _
    ByVal dimensionCount As Long, ByVal currentDimension As Long, _
    values() As String, ByRef valueCount As Long, _
    ByVal maximumValueCount As Long, _
    ByVal preserveLeafAggregateBraces As Long _
) As Long
    initializerText = Trim(initializerText)
    If dimensionCount < 1 OrElse currentDimension < 0 OrElse _
       currentDimension >= dimensionCount OrElse maximumValueCount < 1 OrElse _
       Left(initializerText, 1) <> "{" OrElse _
       Right(initializerText, 1) <> "}" Then Return 0

    Dim initializerBody As String = Trim(Mid( _
        initializerText, 2, Len(initializerText) - 2))
    Dim parts() As String
    Dim partCount As Long
    If SplitSimpleCList( _
        initializerBody, parts(), partCount, -1) = 0 Then Return 0

    Dim elementCapacity As LongInt = 1
    For dimensionIndex As Long = currentDimension To dimensionCount - 1
        If dimensions(dimensionIndex) < 1 OrElse _
           elementCapacity > (maximumValueCount \ dimensions(dimensionIndex)) Then _
            Return 0
        elementCapacity *= dimensions(dimensionIndex)
    Next
    If valueCount < 0 OrElse _
       valueCount > maximumValueCount - elementCapacity Then Return 0

    Dim firstValue As Long = valueCount
    For partIndex As Long = 0 To partCount - 1
        Dim partText As String = Trim(parts(partIndex))
        If partText = "" Then Return 0

        Dim isGroupedValue As Long = CInt( _
            Left(partText, 1) = "{" AndAlso Right(partText, 1) = "}")
        If isGroupedValue = 0 Then
            If valueCount - firstValue >= elementCapacity OrElse _
               valueCount >= maximumValueCount Then Return 0
            values(valueCount) = partText
            valueCount += 1
            Continue For
        End If

        Dim groupDimension As Long = dimensionCount
        Dim localOffset As LongInt = valueCount - firstValue
        For candidateDimension As Long = currentDimension To dimensionCount - 2
            Dim subaggregateCapacity As LongInt = 1
            For sizeIndex As Long = candidateDimension + 1 To dimensionCount - 1
                subaggregateCapacity *= dimensions(sizeIndex)
            Next
            If localOffset Mod subaggregateCapacity = 0 Then
                groupDimension = candidateDimension + 1
                Exit For
            End If
        Next

        If groupDimension < dimensionCount Then
            Dim groupCapacity As LongInt = 1
            For sizeIndex As Long = groupDimension To dimensionCount - 1
                groupCapacity *= dimensions(sizeIndex)
            Next
            If localOffset > elementCapacity - groupCapacity Then Return 0
            If FlattenSimpleCArrayInitializer( _
                partText, dimensions(), dimensionCount, groupDimension, _
                values(), valueCount, maximumValueCount, _
                preserveLeafAggregateBraces) = 0 Then Return 0
        ElseIf preserveLeafAggregateBraces <> 0 Then
            ' Record elements consume braces as aggregate initializers; scalar
            ' array elements instead unwrap a single scalar value.
            If localOffset >= elementCapacity OrElse _
               valueCount >= maximumValueCount Then Return 0
            values(valueCount) = partText
            valueCount += 1
        Else
            Dim scalarText As String
            If UnwrapSimpleCScalarArrayInitializer( _
                partText, scalarText) = 0 OrElse _
               localOffset >= elementCapacity OrElse _
               valueCount >= maximumValueCount Then Return 0
            values(valueCount) = scalarText
            valueCount += 1
        End If
    Next

    While valueCount < firstValue + elementCapacity
        If valueCount >= maximumValueCount Then Return 0
        values(valueCount) = ""
        valueCount += 1
    Wend
    Return -1
End Function
/' end of c2fb_c_syntax.bi '/
