/'
    Project: C2FB

    File: c2fb_integer_expr.bi

    Purpose:

        Normalize the supported C integer-expression subset for FreeBASIC.

    Responsibilities:

        - Validate integer literals and preserve C hexadecimal and octal values.
        - Preserve checked long-long widths in generic macro expressions.
        - Wrap a conservative unsigned-int constant-expression subset to 32 bits.
        - Translate C bitwise and shift operators to FreeBASIC spelling.
        - Apply the identifier policy selected by the owning conversion pass.
        - Lower division and modulus only under an explicit integer assumption.
        - Share expression normalization between SQLite defines and C macros.

    This file intentionally does NOT contain:

        - Expression evaluation, type promotion, or macro dependency resolution.
        - Complete C preprocessor or runtime expression semantics.
'/

Enum C2fbIntegerIdentifierPolicy
    C2FB_INTEGER_IDENTIFIERS_INVALID = 0
    C2FB_INTEGER_IDENTIFIERS_SQLITE = 1
    C2FB_INTEGER_IDENTIFIERS_ANY = 2
End Enum

Private Function IntegerLiteralFitsMagnitudeLimit( _
    ByVal inputExpression As String, ByVal firstDigit As Long, _
    ByVal digitEnd As Long, ByVal radix As Long, _
    ByVal maximumMagnitude As ULongInt _
) As Long
    Dim position As Long = firstDigit
    If radix = 16 Then
        position += 2
    ElseIf radix = 2 Then
        position += 2
    ElseIf radix = 8 Then
        position += 1
    End If
    If position >= digitEnd Then Return 0

    Dim radixValue As ULongInt = radix
    Dim magnitude As ULongInt = 0
    While position < digitEnd
        Dim currentByte As Long = Asc(inputExpression, position)
        Dim digitValue As Long
        If currentByte >= Asc("0") AndAlso currentByte <= Asc("9") Then
            digitValue = currentByte - Asc("0")
        ElseIf currentByte >= Asc("a") AndAlso currentByte <= Asc("f") Then
            digitValue = currentByte - Asc("a") + 10
        ElseIf currentByte >= Asc("A") AndAlso currentByte <= Asc("F") Then
            digitValue = currentByte - Asc("A") + 10
        Else
            Return 0
        End If
        If digitValue >= radix Then Return 0
        Dim digitAsUnsigned As ULongInt = digitValue
        ' Use integer division so FreeBASIC cannot round a floating quotient.
        If magnitude > (maximumMagnitude - digitAsUnsigned) \ radixValue Then Return 0
        magnitude = magnitude * radixValue + digitAsUnsigned
        position += 1
    Wend
    Return -1
End Function

Private Function GenericUnsignedIntMacroExpressionStatus( _
    ByVal sourceExpression As String _
) As Long
    Dim tokens() As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        sourceExpression, tokens(), tokenCount) = 0 Then Return 0

    Dim hasUnsignedIntSuffix As Long = 0
    Dim hasLongSuffix As Long = 0
    Dim hasUnsignedLongLongSuffix As Long = 0
    Dim safeExpression As Long = -1
    Dim expectOperand As Long = -1
    Dim groupDepth As Long = 0
    Dim unsignedIntMaximum As ULongInt = Cast(ULongInt, Cast(ULong, -1))
    Dim signedIntMaximum As ULongInt = 2147483647

    For tokenIndex As Long = 0 To tokenCount - 1
        Dim tokenText As String = tokens(tokenIndex)
        Dim firstByte As Long = Asc(tokenText, 1)
        If firstByte >= Asc("0") AndAlso firstByte <= Asc("9") Then
            If expectOperand = 0 Then safeExpression = 0
            Dim suffixStart As Long = Len(tokenText) + 1
            While suffixStart > 1
                Dim suffixByte As Long = Asc(tokenText, suffixStart - 1)
                If suffixByte = Asc("u") OrElse suffixByte = Asc("U") OrElse _
                   suffixByte = Asc("l") OrElse suffixByte = Asc("L") Then
                    suffixStart -= 1
                Else
                    Exit While
                End If
            Wend
            Dim suffix As String = LCase(Mid(tokenText, suffixStart))
            Dim digitEnd As Long = suffixStart
            Dim literalRadix As Long = 10
            If digitEnd <= 1 Then
                safeExpression = 0
                Continue For
            End If
            If LCase(Left(tokenText, 2)) = "0x" Then
                literalRadix = 16
                If digitEnd <= 3 Then safeExpression = 0
                For digitPosition As Long = 3 To digitEnd - 1
                    If IsHexDigit(Asc(tokenText, digitPosition)) = 0 Then _
                        safeExpression = 0
                Next
            ElseIf Left(tokenText, 1) = "0" AndAlso digitEnd > 2 Then
                literalRadix = 8
                For digitPosition As Long = 2 To digitEnd - 1
                    If Asc(tokenText, digitPosition) < Asc("0") OrElse _
                       Asc(tokenText, digitPosition) > Asc("7") Then _
                        safeExpression = 0
                Next
            Else
                For digitPosition As Long = 1 To digitEnd - 1
                    If Asc(tokenText, digitPosition) < Asc("0") OrElse _
                       Asc(tokenText, digitPosition) > Asc("9") Then _
                        safeExpression = 0
                Next
            End If

            If suffix = "u" Then
                hasUnsignedIntSuffix = -1
            ElseIf suffix = "ul" OrElse suffix = "lu" Then
                hasUnsignedIntSuffix = -1
                hasLongSuffix = -1
            ElseIf suffix = "ull" OrElse suffix = "llu" Then
                hasUnsignedLongLongSuffix = -1
            ElseIf suffix = "l" OrElse suffix = "ll" Then
                hasLongSuffix = -1
            ElseIf suffix <> "" Then
                If InStr(suffix, "u") <> 0 Then hasUnsignedIntSuffix = -1
                safeExpression = 0
            End If

            If literalRadix = 10 AndAlso suffix <> "u" AndAlso _
               IntegerLiteralFitsMagnitudeLimit( _
                tokenText, 1, digitEnd, literalRadix, signedIntMaximum) = 0 Then
                safeExpression = 0
            ElseIf IntegerLiteralFitsMagnitudeLimit( _
                tokenText, 1, digitEnd, literalRadix, unsignedIntMaximum) = 0 Then
                safeExpression = 0
            End If
            expectOperand = 0
        Else
            If expectOperand <> 0 Then
                Select Case tokenText
                Case "(": groupDepth += 1
                Case "+", "-", "~"
                Case Else: safeExpression = 0
                End Select
            Else
                Select Case tokenText
                Case ")"
                    If groupDepth = 0 Then
                        safeExpression = 0
                    Else
                        groupDepth -= 1
                    End If
                Case "+", "-", "*", "&", "|", "^"
                    expectOperand = -1
                Case Else: safeExpression = 0
                End Select
            End If
        End If
    Next

    If expectOperand <> 0 OrElse groupDepth <> 0 Then safeExpression = 0
    If hasUnsignedIntSuffix = 0 Then Return 0
    If hasLongSuffix <> 0 OrElse hasUnsignedLongLongSuffix <> 0 Then _
        safeExpression = 0
    If safeExpression = 0 Then Return -1
    Return 1
End Function

Private Function ConvertIntegerExpression( _
    ByVal inputExpression As String, _
    ByRef outputExpression As String, _
    ByVal identifierPolicy As C2fbIntegerIdentifierPolicy, _
    ByVal integerDivisionAssumed As Long = 0, _
    ByVal preserveLongLongSuffix As Long = 0 _
) As Long
    If identifierPolicy <> C2FB_INTEGER_IDENTIFIERS_SQLITE AndAlso _
       identifierPolicy <> C2FB_INTEGER_IDENTIFIERS_ANY Then Return 0

    Dim i As Long = 1
    outputExpression = ""
    Dim needSpace As Long = 0

    While i <= Len(inputExpression)
        Dim c As Long = Asc(inputExpression, i)
        If IsSpaceByte(c) Then
            needSpace = -1
            i += 1
        ElseIf IsIdentifierStart(c) Then
            Dim start As Long = i
            i += 1
            While i <= Len(inputExpression) AndAlso IsIdentifierPart(Asc(inputExpression, i))
                i += 1
            Wend
            Dim identifier As String = Mid(inputExpression, start, i - start)
            If identifierPolicy = C2FB_INTEGER_IDENTIFIERS_SQLITE Then
                If Left(identifier, Len("SQLITE_")) <> "SQLITE_" Then Return 0
            ElseIf IsIdentifierToken(identifier) = 0 Then
                Return 0
            End If
            If needSpace <> 0 AndAlso Len(outputExpression) > 0 Then outputExpression &= " "
            outputExpression &= identifier
            needSpace = 1
        ElseIf c >= Asc("0") AndAlso c <= Asc("9") Then
            Dim start As Long = i
            Dim isHex As Long = 0
            Dim isBinary As Long = 0
            Dim isOctal As Long = 0
            Dim binaryDigitStart As Long = 0
            If c = Asc("0") AndAlso i < Len(inputExpression) AndAlso _
               (Asc(inputExpression, i + 1) = Asc("x") OrElse Asc(inputExpression, i + 1) = Asc("X")) Then
                isHex = -1
                i += 2
                Dim digitStart As Long = i
                While i <= Len(inputExpression) AndAlso IsHexDigit(Asc(inputExpression, i))
                    i += 1
                Wend
                If i = digitStart Then Return 0
            ElseIf c = Asc("0") AndAlso i < Len(inputExpression) AndAlso _
                   (Asc(inputExpression, i + 1) = Asc("b") OrElse _
                    Asc(inputExpression, i + 1) = Asc("B")) Then
                isBinary = -1
                i += 2
                binaryDigitStart = i
                While i <= Len(inputExpression) AndAlso _
                      (Asc(inputExpression, i) = Asc("0") OrElse _
                       Asc(inputExpression, i) = Asc("1"))
                    i += 1
                Wend
                If i = binaryDigitStart AndAlso i <= Len(inputExpression) AndAlso _
                   IsSpaceByte(Asc(inputExpression, i)) = 0 Then _
                    Return 0
            ElseIf c = Asc("0") AndAlso i < Len(inputExpression) AndAlso _
                   Asc(inputExpression, i + 1) >= Asc("0") AndAlso _
                   Asc(inputExpression, i + 1) <= Asc("9") Then
                isOctal = -1
                i += 1
                Dim digitStart As Long = i
                While i <= Len(inputExpression) AndAlso _
                      Asc(inputExpression, i) >= Asc("0") AndAlso Asc(inputExpression, i) <= Asc("7")
                    i += 1
                Wend
                If i = digitStart Then Return 0
                If i <= Len(inputExpression) AndAlso _
                   Asc(inputExpression, i) >= Asc("8") AndAlso Asc(inputExpression, i) <= Asc("9") Then Return 0
            Else
                While i <= Len(inputExpression) AndAlso _
                      Asc(inputExpression, i) >= Asc("0") AndAlso Asc(inputExpression, i) <= Asc("9")
                    i += 1
                Wend
            End If
            If i = start Then Return 0
            Dim literal As String
            If isHex <> 0 Then
                literal = "&H" & Mid(inputExpression, start + 2, i - start - 2)
            ElseIf isBinary <> 0 Then
                literal = "&b" & Mid(inputExpression, binaryDigitStart, i - binaryDigitStart)
            ElseIf isOctal <> 0 Then
                literal = "&O" & Mid(inputExpression, start + 1, i - start - 1)
            Else
                literal = Mid(inputExpression, start, i - start)
            End If
            Dim digitsEnd As Long = i
            Dim suffixStart As Long = i
            While i <= Len(inputExpression) AndAlso _
                  (Asc(inputExpression, i) = Asc("u") OrElse Asc(inputExpression, i) = Asc("U") OrElse _
                   Asc(inputExpression, i) = Asc("l") OrElse Asc(inputExpression, i) = Asc("L"))
                i += 1
            Wend
            Dim integerSuffix As String = LCase(Mid( _
                inputExpression, suffixStart, i - suffixStart))
            If preserveLongLongSuffix <> 0 Then
                ' A C long-long literal must keep its width before a shift.
                If integerSuffix = "ll" Then
                    Dim literalRadix As Long = 10
                    If isHex <> 0 Then
                        literalRadix = 16
                    ElseIf isBinary <> 0 Then
                        literalRadix = 2
                    ElseIf isOctal <> 0 Then
                        literalRadix = 8
                    End If
                    If IntegerLiteralFitsMagnitudeLimit( _
                        inputExpression, start, digitsEnd, literalRadix, _
                        Cast(ULongInt, &H7FFFFFFFFFFFFFFF)) = 0 Then Return 0
                    literal = "Cast(LongInt, " & literal & ")"
                ElseIf integerSuffix = "ull" OrElse integerSuffix = "llu" Then
                    Dim literalRadix As Long = 10
                    If isHex <> 0 Then
                        literalRadix = 16
                    ElseIf isBinary <> 0 Then
                        literalRadix = 2
                    ElseIf isOctal <> 0 Then
                        literalRadix = 8
                    End If
                    If IntegerLiteralFitsMagnitudeLimit( _
                        inputExpression, start, digitsEnd, literalRadix, _
                        Cast(ULongInt, -1)) = 0 Then Return 0
                    literal = "Cast(ULongInt, " & literal & ")"
                End If
            End If
            If needSpace <> 0 AndAlso Len(outputExpression) > 0 Then outputExpression &= " "
            outputExpression &= literal
            needSpace = 1
        ElseIf c = Asc("<") AndAlso i < Len(inputExpression) AndAlso Asc(inputExpression, i + 1) = Asc("<") Then
            outputExpression &= " Shl "
            i += 2
            needSpace = 0
        ElseIf c = Asc(">") AndAlso i < Len(inputExpression) AndAlso Asc(inputExpression, i + 1) = Asc(">") Then
            outputExpression &= " Shr "
            i += 2
            needSpace = 0
        Else
            Select Case c
            Case Asc("|")
                outputExpression &= " Or "
            Case Asc("&")
                outputExpression &= " And "
            Case Asc("^")
                outputExpression &= " Xor "
            Case Asc("~")
                outputExpression &= " Not "
            Case Asc("/")
                If integerDivisionAssumed <> 0 Then
                    outputExpression &= " " & Chr(92) & " "
                Else
                    outputExpression &= "/"
                End If
            Case Asc("%")
                If integerDivisionAssumed <> 0 Then
                    outputExpression &= " Mod "
                Else
                    outputExpression &= "%"
                End If
            Case Asc("("), Asc(")"), Asc("+"), Asc("-"), Asc("*")
                outputExpression &= Chr(c)
            Case Else
                Return 0
            End Select
            i += 1
            needSpace = 0
        End If
    Wend

    outputExpression = Trim(outputExpression)
    If Len(outputExpression) = 0 Then Return 0
    Return -1
End Function

/' end of c2fb_integer_expr.bi '/
