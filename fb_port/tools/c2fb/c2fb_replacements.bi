/'
    Project: C2FB shared replacement rules

    File: c2fb_replacements.bi

    Purpose:

        Load and apply explicit C-to-C or C-to-FreeBASIC replacement rules.

    Responsibilities:

        - Normalize C token sequences for exact replacement matching.
        - Read bounded, indented replacement blocks from rule files.
        - Store rules in the shared generic-C translation context.
        - Apply rules to generic-header macros, body expressions, statements,
          and complete generic function definitions.
        - Validate FreeBASIC replacements and rewrite body-local names.

    This file intentionally does NOT contain:

        - C expression parsing or target type resolution.
        - Generic header or body command-line option policy.
        - Output formatting for replacement results.
'/

Private Sub ResetC2fbReplacementRules( _
    ByRef policy As C2fbGenericCPolicyModel _
)
    ReDim policy.replacementRules(0 To 15)
    policy.replacementRuleCount = 0
End Sub

Private Function C2fbReplacementTokenKey(ByVal sourceText As String) As String
    Dim insideBlockComment As Long = 0
    sourceText = StripComments(sourceText, insideBlockComment)
    Dim result As String
    Dim tokenCount As Long = 0
    Dim position As Long = 1
    While position <= Len(sourceText)
        Dim currentByte As Long = Asc(sourceText, position)
        If IsSpaceByte(currentByte) <> 0 Then
            position += 1
            Continue While
        End If

        Dim tokenStart As Long = position
        If currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
            Dim quoteByte As Long = currentByte
            Dim escaped As Long = 0
            Dim foundClosingQuote As Long = 0
            position += 1
            While position <= Len(sourceText)
                Dim quoteChar As Long = Asc(sourceText, position)
                If escaped <> 0 Then
                    escaped = 0
                ElseIf quoteChar = Asc("\") Then
                    escaped = -1
                ElseIf quoteChar = quoteByte Then
                    position += 1
                    foundClosingQuote = -1
                    Exit While
                End If
                position += 1
            Wend
            If foundClosingQuote = 0 Then Return ""
        ElseIf IsIdentifierStart(currentByte) <> 0 Then
            position += 1
            While position <= Len(sourceText)
                Dim nextByte As Long = Asc(sourceText, position)
                If IsIdentifierPart(nextByte) = 0 Then Exit While
                position += 1
            Wend
        ElseIf (currentByte >= Asc("0") AndAlso currentByte <= Asc("9")) OrElse _
               (currentByte = Asc(".") AndAlso position < Len(sourceText) AndAlso _
                Asc(sourceText, position + 1) >= Asc("0") AndAlso _
                Asc(sourceText, position + 1) <= Asc("9")) Then
            position += 1
            While position <= Len(sourceText)
                Dim nextByte As Long = Asc(sourceText, position)
                If IsIdentifierPart(nextByte) <> 0 OrElse nextByte = Asc(".") Then
                    position += 1
                ElseIf (nextByte = Asc("+") OrElse nextByte = Asc("-")) AndAlso _
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
                Case "->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=", _
                     "&&", "||", "+=", "-=", "*=", "/=", "%=", "&=", _
                     "|=", "^=", "##"
                    position += 2
                Case Else
                    position += 1
                End Select
            End Select
        End If

        If tokenCount >= MAX_TYPE_WORDS Then Return ""
        Dim token As String = Mid(sourceText, tokenStart, position - tokenStart)
        result &= Trim(Str(Len(token))) & ":" & token & Chr(1)
        tokenCount += 1
    Wend
    If tokenCount = 0 Then Return ""
    Return result
End Function

Private Function ReadC2fbReplacementLine( _
    ByRef lineReader As C2fbTextFileLineReaderModel, _
    ByRef lineText As String, _
    ByRef lineNumber As Long, ByRef hasPendingLine As Long _
) As Long
    If hasPendingLine <> 0 Then
        hasPendingLine = 0
    Else
        If ReadC2fbTextFileLine(lineReader, lineText) = 0 Then Return 0
        lineNumber = lineReader.physicalLineNumber
    End If
    While Trim(lineText) = "" OrElse Left(LTrim(lineText), 1) = "#"
        If ReadC2fbTextFileLine(lineReader, lineText) = 0 Then Return 0
        lineNumber = lineReader.physicalLineNumber
    Wend
    Return -1
End Function

Private Function ReadC2fbReplacementCode( _
    ByRef lineReader As C2fbTextFileLineReaderModel, _
    ByVal filePath As String, _
    ByRef lineText As String, ByRef lineNumber As Long, _
    ByRef hasPendingLine As Long, ByVal keyword As String _
) As String
    If Left(lineText, Len(keyword)) <> keyword Then _
        ReportError(filePath & "(" & Trim(Str(lineNumber)) & _
                    "): expected " & keyword)
    Dim code As String = Trim(Mid(lineText, Len(keyword) + 1))
    hasPendingLine = 0
    If code <> "" Then Return code

    If ReadC2fbReplacementLine( _
        lineReader, lineText, lineNumber, hasPendingLine) = 0 Then _
        ReportError(filePath & "(" & Trim(Str(lineNumber)) & _
                    "): replacement code block is empty")
    Dim indentationLength As Long = 0
    While indentationLength < Len(lineText)
        Dim currentByte As Long = Asc(lineText, indentationLength + 1)
        If currentByte <> Asc(" ") AndAlso currentByte <> Asc(Chr(9)) Then Exit While
        indentationLength += 1
    Wend
    If indentationLength = 0 Then _
        ReportError(filePath & "(" & Trim(Str(lineNumber)) & _
                    "): replacement code block must be indented")
    Dim indentation As String = Left(lineText, indentationLength)
    code = Mid(lineText, indentationLength + 1)

    While ReadC2fbTextFileLine(lineReader, lineText) <> 0
        lineNumber = lineReader.physicalLineNumber
        If lineText = "" Then
            hasPendingLine = -1
            Exit While
        End If
        Dim leadingByte As Long = Asc(lineText, 1)
        If leadingByte <> Asc(" ") AndAlso leadingByte <> Asc(Chr(9)) Then
            hasPendingLine = -1
            Exit While
        End If
        If Left(lineText, indentationLength) <> indentation Then
            ReportError(filePath & "(" & Trim(Str(lineNumber)) & _
                        "): inconsistent replacement block indentation")
        End If
        code &= Chr(10) & Mid(lineText, indentationLength + 1)
    Wend
    Return code
End Function

Private Sub AppendC2fbReplacementRule( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal sourceText As String, ByVal replacementText As String, _
    ByVal toFreeBasic As Long, ByVal filePath As String, _
    ByVal lineNumber As Long _
)
    Dim sourceKey As String = C2fbReplacementTokenKey(sourceText)
    If sourceKey = "" OrElse Trim(replacementText) = "" Then _
        ReportError(filePath & "(" & Trim(Str(lineNumber)) & "): empty or oversized replacement")
    For replacementIndex As Long = 0 To policy.replacementRuleCount - 1
        If policy.replacementRules(replacementIndex).sourceKey = sourceKey Then _
            ReportError(filePath & "(" & Trim(Str(lineNumber)) & _
                        "): duplicate C replacement pattern")
    Next
    If policy.replacementRuleCount >= MAX_FUNCTIONS Then _
        ReportError("replacement file exceeds the configured rule limit")
    If policy.replacementRuleCount > UBound(policy.replacementRules) Then _
        ReDim Preserve policy.replacementRules( _
            0 To UBound(policy.replacementRules) * 2 + 1)
    With policy.replacementRules(policy.replacementRuleCount)
        .sourceKey = sourceKey
        .sourceText = sourceText
        .replacementText = Trim(replacementText)
        .toFreeBasic = toFreeBasic
    End With
    policy.replacementRuleCount += 1
End Sub

Private Sub LoadC2fbReplacementRuleFile( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal inputPath As String _
)
    Dim lineReader As C2fbTextFileLineReaderModel
    If OpenC2fbTextFileLineReader(lineReader, inputPath) = 0 Then _
        ReportError("cannot read replacement file: " & inputPath)
    Dim lineText As String
    Dim lineNumber As Long = 0
    Dim hasPendingLine As Long = 0
    While ReadC2fbReplacementLine( _
        lineReader, lineText, lineNumber, hasPendingLine) <> 0
        If Left(lineText, Len("convert c:")) <> "convert c:" Then _
            ReportError(inputPath & "(" & Trim(Str(lineNumber)) & _
                        "): expected 'convert c:'")
        Dim sourceText As String = ReadC2fbReplacementCode( _
            lineReader, inputPath, lineText, lineNumber, hasPendingLine, "convert c:")
        If ReadC2fbReplacementLine( _
            lineReader, lineText, lineNumber, hasPendingLine) = 0 Then _
            ReportError(inputPath & "(" & Trim(Str(lineNumber)) & _
                        "): missing 'to c:' or 'to fb:' replacement")
        Dim toFreeBasic As Long
        Dim targetKeyword As String
        If Left(lineText, 5) = "to c:" Then
            targetKeyword = "to c:"
        ElseIf Left(lineText, 6) = "to fb:" Then
            targetKeyword = "to fb:"
            toFreeBasic = -1
        Else
            ReportError(inputPath & "(" & Trim(Str(lineNumber)) & _
                        "): expected 'to c:' or 'to fb:'")
        End If
        Dim replacementText As String = ReadC2fbReplacementCode( _
            lineReader, inputPath, lineText, lineNumber, hasPendingLine, targetKeyword)
        AppendC2fbReplacementRule( _
            policy, sourceText, replacementText, toFreeBasic, _
            inputPath, lineNumber)
    Wend
    CloseC2fbTextFileLineReader(lineReader)
End Sub

Private Function C2fbReplacementRuleMatch( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal expression As String, ByRef replacementText As String, _
    ByRef toFreeBasic As Long _
) As Long
    replacementText = ""
    toFreeBasic = 0
    Dim sourceKey As String = C2fbReplacementTokenKey(expression)
    If sourceKey = "" Then Return 0
    For replacementIndex As Long = 0 To policy.replacementRuleCount - 1
        If policy.replacementRules(replacementIndex).sourceKey = sourceKey Then
            replacementText = policy.replacementRules(replacementIndex).replacementText
            toFreeBasic = policy.replacementRules(replacementIndex).toFreeBasic
            Return -1
        End If
    Next
    Return 0
End Function

Private Function C2fbReplacementRuleHasMultipleLines( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal sourceText As String _
) As Long
    Dim sourceKey As String = C2fbReplacementTokenKey(sourceText)
    If sourceKey = "" Then Return 0
    For replacementIndex As Long = 0 To policy.replacementRuleCount - 1
        If policy.replacementRules(replacementIndex).sourceKey = sourceKey Then
            Return CInt(InStr( _
                policy.replacementRules(replacementIndex).replacementText, Chr(10)) <> 0)
        End If
    Next
    Return 0
End Function

Private Function IndentC2fbReplacement( _
    ByVal replacementText As String, ByVal indentText As String _
) As String
    Dim result As String
    Dim lineStart As Long = 1
    While lineStart <= Len(replacementText)
        Dim lineEnd As Long = InStr(lineStart, replacementText, Chr(10))
        If lineEnd = 0 Then
            result &= indentText & Mid(replacementText, lineStart)
            Exit While
        End If
        result &= indentText & Mid(replacementText, lineStart, lineEnd - lineStart) & Chr(10)
        lineStart = lineEnd + 1
    Wend
    Return result
End Function
' Safe FreeBASIC replacement validation and local-name rewriting.
Private Function ReadGenericFreeBasicBlockReturn( _
    ByVal replacementText As String, ByRef returnExpression As String _
) As Long
    returnExpression = ""
    Dim lastStatement As String
    Dim lineStart As Long = 1
    While lineStart <= Len(replacementText)
        Dim lineEnd As Long = InStr(lineStart, replacementText, Chr(10))
        Dim lineText As String
        If lineEnd = 0 Then
            lineText = Mid(replacementText, lineStart)
        Else
            lineText = Mid(replacementText, lineStart, lineEnd - lineStart)
        End If
        Dim trimmedLine As String = Trim(lineText)
        Dim loweredLine As String = LCase(trimmedLine)
        If trimmedLine <> "" AndAlso Left(trimmedLine, 1) <> "'" AndAlso _
           Left(loweredLine, 4) <> "rem " AndAlso _
           Left(loweredLine, 4) <> "rem" & Chr(9) Then
            lastStatement = trimmedLine
        End If
        If lineEnd = 0 Then Exit While
        lineStart = lineEnd + 1
    Wend

    If LCase(Left(lastStatement, 6)) <> "return" Then Return 0
    If Len(lastStatement) > 6 AndAlso _
       IsIdentifierPart(Asc(lastStatement, 7)) <> 0 Then Return 0
    returnExpression = Trim(Mid(lastStatement, 7))
    If LCase(Left(returnExpression, 4)) = "rem " OrElse _
       Left(returnExpression, 1) = "'" Then returnExpression = ""
    Return -1
End Function

Private Function IsSimpleFreeBasicBodyReplacement( _
    ByVal replacementText As String, ByVal sourceIsReturn As Long _
) As Long
    replacementText = Trim(replacementText)
    If replacementText = "" OrElse InStr(replacementText, Chr(10)) <> 0 OrElse _
       InStr(replacementText, Chr(13)) <> 0 Then Return 0

    Dim firstWords(0 To 1) As String
    Dim wordCount As Long = 0
    Dim position As Long = 1
    Dim insideString As Long = 0
    While position <= Len(replacementText)
        Dim currentByte As Long = Asc(replacementText, position)
        If insideString <> 0 Then
            If currentByte = Asc(Chr(34)) Then
                If position < Len(replacementText) AndAlso _
                   Asc(replacementText, position + 1) = Asc(Chr(34)) Then
                    position += 1
                Else
                    insideString = 0
                End If
            End If
            position += 1
        ElseIf currentByte = Asc(Chr(34)) Then
            insideString = -1
            position += 1
        ElseIf currentByte = Asc(";") OrElse currentByte = Asc(":") Then
            Return 0
        ElseIf IsIdentifierStart(currentByte) <> 0 Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(replacementText) AndAlso _
                  IsIdentifierPart(Asc(replacementText, position)) <> 0
                position += 1
            Wend
            Dim token As String = LCase(Mid( _
                replacementText, tokenStart, position - tokenStart))
            If wordCount < 2 Then firstWords(wordCount) = token
            wordCount += 1
            Select Case token
            Case "goto", "if", "then", "else", "for", "next", "while", _
                 "do", "loop", "select", "case", "break", "continue", _
                 "end", "dim", "static", "redim", "erase", _
                 "union", "enum", "declare", "property", "constructor", _
                 "destructor", "class", "namespace", "exit", "function", "sub"
                Return 0
            Case "type"
                ' Type<T>(...) is a FreeBASIC value constructor, not a block.
                Dim constructorPosition As Long = position
                While constructorPosition <= Len(replacementText) AndAlso _
                      IsSpaceByte(Asc(replacementText, constructorPosition)) <> 0
                    constructorPosition += 1
                Wend
                If constructorPosition > Len(replacementText) OrElse _
                   Asc(replacementText, constructorPosition) <> Asc("<") Then _
                    Return 0
            Case "return"
                If sourceIsReturn = 0 OrElse wordCount <> 1 Then Return 0
            End Select
        Else
            position += 1
        End If
    Wend

    If sourceIsReturn = 0 Then Return -1
    Return CInt(firstWords(0) = "return")
End Function

Private Function RewriteGenericBodyLocalNames( _
    ByVal sourceText As String, parameterNames() As String, _
    parameterAliases() As String, ByVal parameterCount As Long _
) As String
    Dim result As String
    Dim position As Long = 1
    Dim insideString As Long = 0
    While position <= Len(sourceText)
        Dim currentByte As Long = Asc(sourceText, position)
        If insideString <> 0 Then
            result &= Chr(currentByte)
            If currentByte = Asc(Chr(34)) Then
                If position < Len(sourceText) AndAlso _
                   Asc(sourceText, position + 1) = Asc(Chr(34)) Then
                    position += 1
                    result &= Chr(Asc(sourceText, position))
                Else
                    insideString = 0
                End If
            End If
            position += 1
        ElseIf currentByte = Asc(Chr(34)) Then
            insideString = -1
            result &= Chr(currentByte)
            position += 1
        ElseIf IsIdentifierStart(currentByte) <> 0 Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(sourceText) AndAlso _
                  IsIdentifierPart(Asc(sourceText, position)) <> 0
                position += 1
            Wend
            Dim token As String = Mid(sourceText, tokenStart, position - tokenStart)
            Dim previousPosition As Long = Len(result)
            While previousPosition > 0 AndAlso _
                  IsSpaceByte(Asc(result, previousPosition)) <> 0
                previousPosition -= 1
            Wend
            Dim isMemberName As Long = CInt( _
                previousPosition > 0 AndAlso Asc(result, previousPosition) = Asc("."))
            If isMemberName = 0 Then
                For symbolIndex As Long = 0 To parameterCount - 1
                    If token = parameterNames(symbolIndex) Then
                        token = parameterAliases(symbolIndex)
                        Exit For
                    End If
                Next
            End If
            result &= token
        Else
            result &= Chr(currentByte)
            position += 1
        End If
    Wend
    Return result
End Function

/' end of c2fb_replacements.bi '/
