/'
    Project: C2FB

    File: c2fb_lexer.bi

    Purpose:

        Provide bounded tokenization for C declarations and preprocessor bodies.

    Responsibilities:

        - Grow token arrays for declaration and expression helpers.
        - Preserve the token boundaries used by shared declarator parsing.
        - Tokenize replacement-list literals, identifiers, numbers, and operators.
        - Find identifiers in C source while ignoring comments and literals.
        - Keep the common C tokenization implementation outside the CLI driver.

    This file intentionally does NOT contain:

        - Declaration, expression, or preprocessor parsing policy.
        - Type mapping or FreeBASIC output formatting.
'/

' Most declarations stay small; grow the token array when a longer signature
' or nested declarator requires more room.
Private Const C2FB_INITIAL_TOKEN_CAPACITY As Long = 32

Private Function C2fbCTextContainsIdentifier( _
    ByVal sourceText As String, ByVal identifier As String _
) As Long
    If identifier = "" Then Return 0
    Dim position As Long = 1
    Dim wantedName As String = LCase(identifier)
    While position <= Len(sourceText)
        Dim currentByte As Long = Asc(sourceText, position)
        If position < Len(sourceText) AndAlso _
           Mid(sourceText, position, 2) = "//" Then
            position += 2
            While position <= Len(sourceText) AndAlso _
                  Asc(sourceText, position) <> 10
                position += 1
            Wend
        ElseIf position < Len(sourceText) AndAlso _
               Mid(sourceText, position, 2) = "/*" Then
            position += 2
            While position < Len(sourceText) AndAlso _
                  Mid(sourceText, position, 2) <> "*/"
                position += 1
            Wend
            If position < Len(sourceText) Then position += 2
        ElseIf currentByte = Asc(Chr(34)) OrElse _
               currentByte = Asc("'") Then
            Dim quoteByte As Long = currentByte
            position += 1
            While position <= Len(sourceText)
                currentByte = Asc(sourceText, position)
                If currentByte = Asc(Chr(92)) AndAlso _
                   position < Len(sourceText) Then
                    position += 2
                ElseIf currentByte = quoteByte Then
                    position += 1
                    Exit While
                Else
                    position += 1
                End If
            Wend
        ElseIf IsIdentifierStart(currentByte) <> 0 Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(sourceText) AndAlso _
                  IsIdentifierPart(Asc(sourceText, position)) <> 0
                position += 1
            Wend
            If LCase(Mid(sourceText, tokenStart, position - tokenStart)) = _
               wantedName Then Return -1
        Else
            position += 1
        End If
    Wend
    Return 0
End Function

Private Sub AddToken( _
    tokens() As String, _
    ByRef tokenCount As Long, _
    ByVal tokenText As String _
)
    If tokenCount >= UBound(tokens) Then _
        ReDim Preserve tokens(0 To UBound(tokens) * 2 + 1)
    tokens(tokenCount) = tokenText
    tokenCount += 1
End Sub

Private Function ReadCDeclarationLiteralToken( _
    ByVal declaration As String, ByRef position As Long, _
    ByRef literalToken As String _
) As Long
    literalToken = ""
    If position < 1 OrElse position > Len(declaration) Then Return 0
    Dim literalStart As Long = position
    Dim quotePosition As Long = 0
    If position + 2 <= Len(declaration) AndAlso _
       Mid(declaration, position, 2) = "u8" AndAlso _
       (Mid(declaration, position + 2, 1) = Chr(34) OrElse _
        Mid(declaration, position + 2, 1) = "'") Then
        quotePosition = position + 2
    ElseIf (Asc(declaration, position) = Asc("L") OrElse _
            Asc(declaration, position) = Asc("u") OrElse _
            Asc(declaration, position) = Asc("U")) AndAlso _
           position < Len(declaration) AndAlso _
           (Mid(declaration, position + 1, 1) = Chr(34) OrElse _
            Mid(declaration, position + 1, 1) = "'") Then
        quotePosition = position + 1
    ElseIf Asc(declaration, position) = Asc(Chr(34)) OrElse _
           Asc(declaration, position) = Asc("'") Then
        quotePosition = position
    Else
        Return 0
    End If

    Dim quoteByte As Long = Asc(declaration, quotePosition)
    position = quotePosition + 1
    Dim closedLiteral As Long = 0
    While position <= Len(declaration)
        Dim currentByte As Long = Asc(declaration, position)
        If position - literalStart > MAX_C_STRING_LITERAL_BYTES + 8 Then
            position = literalStart
            Return 1
        End If
        If currentByte = Asc(Chr(92)) Then
            If position >= Len(declaration) Then
                position = literalStart
                Return 1
            End If
            position += 2
        ElseIf currentByte = quoteByte Then
            position += 1
            closedLiteral = -1
            Exit While
        ElseIf currentByte = 10 OrElse currentByte = 13 Then
            position = literalStart
            Return 1
        Else
            position += 1
        End If
    Wend
    If closedLiteral = 0 Then
        position = literalStart
        Return 1
    End If
    literalToken = Mid(declaration, literalStart, position - literalStart)
    Return -1
End Function

Private Sub TokenizeCDeclaration( _
    ByVal declaration As String, _
    tokens() As String, _
    ByRef tokenCount As Long _
)
    ReDim tokens(0 To C2FB_INITIAL_TOKEN_CAPACITY - 1)
    tokenCount = 0
    Dim i As Long = 1

    While i <= Len(declaration)
        If tokenCount >= MAX_C_DECLARATION_TOKENS Then
            While i <= Len(declaration) AndAlso _
                  IsSpaceByte(Asc(declaration, i)) <> 0
                i += 1
            Wend
            If i <= Len(declaration) Then _
                ReportError("C declaration exceeds the configured token limit")
            Exit While
        End If
        Dim c As Long = Asc(declaration, i)
        If IsSpaceByte(c) Then
            i += 1
        Else
            Dim literalToken As String
            Dim literalStatus As Long = ReadCDeclarationLiteralToken( _
                declaration, i, literalToken)
            If literalStatus > 0 Then
                ReportError("C declaration contains an invalid or oversized literal")
                Exit Sub
            ElseIf literalStatus < 0 Then
                AddToken(tokens(), tokenCount, literalToken)
            ElseIf IsIdentifierStart(c) Then
                Dim start As Long = i
                i += 1
                While i <= Len(declaration) AndAlso IsIdentifierPart(Asc(declaration, i))
                    i += 1
                Wend
                AddToken(tokens(), tokenCount, Mid(declaration, start, i - start))
            ElseIf c = Asc(".") AndAlso i + 2 <= Len(declaration) AndAlso _
                   Mid(declaration, i, 3) = "..." Then
                AddToken(tokens(), tokenCount, "...")
                i += 3
            Else
                AddToken(tokens(), tokenCount, Chr(c))
                i += 1
            End If
        End If
    Wend
End Sub

Private Function TokenizeCPreprocessorReplacement( _
    ByVal sourceText As String, tokens() As String, _
    ByRef tokenCount As Long _
) As Long
    ReDim tokens(0 To 31)
    tokenCount = 0
    Dim position As Long = 1
    While position <= Len(sourceText)
        Dim currentByte As Long = Asc(sourceText, position)
        If IsSpaceByte(currentByte) <> 0 Then
            position += 1
            Continue While
        End If

        Dim tokenStart As Long = position
        Dim quotePosition As Long = 0
        If position + 2 <= Len(sourceText) AndAlso _
           Mid(sourceText, position, 2) = "u8" AndAlso _
           (Mid(sourceText, position + 2, 1) = Chr(34) OrElse _
            Mid(sourceText, position + 2, 1) = "'") Then
            quotePosition = position + 2
        ElseIf (currentByte = Asc("L") OrElse currentByte = Asc("u") OrElse _
                currentByte = Asc("U")) AndAlso position < Len(sourceText) AndAlso _
               (Mid(sourceText, position + 1, 1) = Chr(34) OrElse _
                Mid(sourceText, position + 1, 1) = "'") Then
            quotePosition = position + 1
        ElseIf currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
            quotePosition = position
        End If

        If quotePosition > 0 Then
            Dim quoteByte As Long = Asc(sourceText, quotePosition)
            position = quotePosition + 1
            Dim hasClosingQuote As Long = 0
            While position <= Len(sourceText)
                Dim literalByte As Long = Asc(sourceText, position)
                If literalByte = Asc(Chr(92)) AndAlso position < Len(sourceText) Then
                    position += 2
                ElseIf literalByte = quoteByte Then
                    position += 1
                    hasClosingQuote = -1
                    Exit While
                ElseIf literalByte = 10 OrElse literalByte = 13 Then
                    Return 0
                Else
                    position += 1
                End If
            Wend
            If hasClosingQuote = 0 Then Return 0
            AddToken(tokens(), tokenCount, Mid(sourceText, tokenStart, position - tokenStart))
        ElseIf IsIdentifierStart(currentByte) <> 0 Then
            position += 1
            While position <= Len(sourceText) AndAlso _
                  IsIdentifierPart(Asc(sourceText, position)) <> 0
                position += 1
            Wend
            AddToken(tokens(), tokenCount, Mid(sourceText, tokenStart, position - tokenStart))
        ElseIf (currentByte >= Asc("0") AndAlso currentByte <= Asc("9")) OrElse _
               (currentByte = Asc(".") AndAlso position < Len(sourceText) AndAlso _
                Asc(sourceText, position + 1) >= Asc("0") AndAlso _
                Asc(sourceText, position + 1) <= Asc("9")) Then
            position += 1
            While position <= Len(sourceText)
                Dim numberByte As Long = Asc(sourceText, position)
                If IsIdentifierPart(numberByte) <> 0 OrElse numberByte = Asc(".") Then
                    position += 1
                ElseIf (numberByte = Asc("+") OrElse numberByte = Asc("-")) AndAlso _
                       position > tokenStart AndAlso _
                       (Asc(sourceText, position - 1) = Asc("e") OrElse _
                        Asc(sourceText, position - 1) = Asc("E") OrElse _
                        Asc(sourceText, position - 1) = Asc("p") OrElse _
                        Asc(sourceText, position - 1) = Asc("P")) Then
                    position += 1
                Else
                    Exit While
                End If
            Wend
            AddToken(tokens(), tokenCount, Mid(sourceText, tokenStart, position - tokenStart))
        Else
            Dim threeCharacterOperator As String = ""
            If position + 2 <= Len(sourceText) Then _
                threeCharacterOperator = Mid(sourceText, position, 3)
            Select Case threeCharacterOperator
            Case "...", "<<=", ">>="
                position += 3
            Case Else
                Dim twoCharacterOperator As String = ""
                If position + 1 <= Len(sourceText) Then _
                    twoCharacterOperator = Mid(sourceText, position, 2)
                Select Case twoCharacterOperator
                Case "##", "->", "++", "--", "<<", ">>", "<=", ">=", _
                     "==", "!=", "&&", "||", "+=", "-=", "*=", "/=", _
                     "%=", "&=", "|=", "^="
                    position += 2
                Case Else
                    position += 1
                End Select
            End Select
            AddToken(tokens(), tokenCount, Mid(sourceText, tokenStart, position - tokenStart))
        End If
        If tokenCount >= MAX_FUNCTIONS Then Return 0
    Wend
    Return CInt(tokenCount > 0)
End Function

/' end of c2fb_lexer.bi '/
