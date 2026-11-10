/'
    Project: C2FB generic header converter

    File: c2fb_generic_macro_lowering.bi

    Purpose:

        Translate supported generic-header macro expressions into FreeBASIC.

    Responsibilities:

        - Lower integer and conditional macro expressions.
        - Lower supported scalar cast chains in integer macro expressions.
        - Route untyped integer-cast arguments through typed helper requests.
        - Route call-site-dependent division and remainder through typed helpers.
        - Lower mapped C pointer casts with FreeBASIC CPtr expressions.
        - Lower C string-literal pointer casts using static storage.
        - Resolve record-member and indexed arguments in function-call macros.
        - Lower a single conditional call statement to a FreeBASIC macro block.
        - Lower simple assignment and comma statement sequences in macro blocks.
        - Remove leading void casts from supported statement macro bodies.
        - Apply explicit integer-operand assumptions to selected macros.
        - Normalize do/while-zero wrappers around one supported call statement.
        - Translate supported function-like, stringizing, and token-paste forms.
        - Convert selected replacement lists by translating tokens without parsing.
        - Resolve macro aliases and type-valued macros through shared models.
        - Report unsupported expression shapes to the generic header emitter.

    This file intentionally does NOT contain:

        - Macro source collection or generated-file output.
        - SQLite numeric define policy or general C preprocessing.
'/

Private Const MAX_GENERIC_MACRO_EXPRESSION_DEPTH As Long = 64

Declare Function TranslateGenericHeaderCondition( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef freeBasicCondition As String, _
    ByVal depth As Long, ByVal integerDivisionAssumed As Long = 0, _
    ByVal dynamicIntegerDivision As Long = 0 _
) As Long
Declare Function TranslateGenericHeaderMacroExpressionWithParameters( _
    ByRef translation As C2fbTranslationContext, _
    ByVal rawValue As String, ByRef freeBasicExpression As String, _
    parameterNames() As String, freeParameterNames() As String, _
    ByVal parameterCount As Long, _
    ByVal integerDivisionAssumed As Long = 0, _
    ByVal depth As Long = 0, _
    ByVal dynamicIntegerDivision As Long = 0 _
) As Long
Declare Function GenericHeaderMacroCastType( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceType As String, ByRef freeBasicType As String, _
    ByRef isPointerCast As Long _
) As Long
Declare Function TranslateGenericFunctionCallMacroArgument( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceArgument As String, parameterNames() As String, _
    freeParameterNames() As String, ByVal parameterCount As Long, _
    ByVal isVariadic As Long, ByRef freeBasicArgument As String _
) As Long
Declare Function TranslateGenericDirectCallMacroTokens( _
    ByRef translation As C2fbTranslationContext, ByVal sourceBody As String, _
    parameterNames() As String, freeParameterNames() As String, _
    ByVal parameterCount As Long, ByVal isVariadic As Long, _
    ByRef freeBasicExpression As String _
) As Long
Declare Function TranslateGenericMacroTokenSequence( _
    ByRef translation As C2fbTranslationContext, ByVal sourceText As String, _
    parameterNames() As String, freeParameterNames() As String, _
    ByVal parameterCount As Long, ByVal isVariadic As Long, _
    ByRef freeBasicExpression As String _
) As Long
Declare Function TranslateSimpleDeclarationStatement( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal statementText As String, ByRef outputText As String, _
    ByRef context As SimpleBodyContext, locals() As SimpleLocalVariable, _
    ByRef localCount As Long, callableNames() As String, _
    ByVal callableCount As Long, parameterNames() As String, _
    parameterAliases() As String, parameterTypes() As String, _
    ByRef symbolCount As Long _
) As Long
Declare Sub BuildC2fbRecordFieldSources( _
    ByRef declaration As C2fbDeclarationModel _
)
Declare Function ParseGenericRecordFields( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef declaration As C2fbDeclarationModel, _
    ByRef recordPlan As C2fbGenericRecordPlanModel, _
    outputNames() As String, ByRef outputNameCount As Long, _
    fields() As GenericRecordField, ByRef fieldCount As Long, _
    ByVal ownerTag As String = "", ByVal ownerAlias As String = "" _
) As Long
Declare Function GenericIntegerMacroCastFloatLiteralCandidate( _
    ByVal sourceExpression As String _
) As Long
Declare Function GenericHeaderOperatorHelperNameInContext( _
    ByRef translation As C2fbTranslationContext, ByVal operatorText As String _
) As String
Declare Function GenericMacroExpressionContainsDivision( _
    ByVal sourceExpression As String _
) As Long
Declare Function TranslateGenericHeaderDynamicDivisionExpression( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef freeBasicExpression As String, _
    ByVal integerDivisionAssumed As Long, ByVal depth As Long, _
    ByVal dynamicIntegerDivision As Long _
) As Long

Private Function GenericIntegerMacroCandidate(ByVal rawValue As String) As Long
    Dim normalizedValue As String
    If RewriteGenericMacroCharacterConstants(rawValue, normalizedValue) = 0 Then Return 0
    rawValue = Trim(normalizedValue)
    If rawValue = "" Then Return 0
    If GenericIntegerMacroCastFloatLiteralCandidate(rawValue) <> 0 Then Return -1
    Dim numericTokens() As String
    Dim numericTokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        rawValue, numericTokens(), numericTokenCount) = 0 Then Return 0
    For tokenIndex As Long = 0 To numericTokenCount - 1
        Dim tokenText As String = numericTokens(tokenIndex)
        Dim firstByte As Long = Asc(tokenText, 1)
        If (firstByte >= Asc("0") AndAlso firstByte <= Asc("9")) OrElse _
           (firstByte = Asc(".") AndAlso Len(tokenText) > 1 AndAlso _
            Asc(tokenText, 2) >= Asc("0") AndAlso _
            Asc(tokenText, 2) <= Asc("9")) Then
            Dim lowerToken As String = LCase(tokenText)
            Dim lastByte As Long = Asc(tokenText, Len(tokenText))
            If InStr(tokenText, ".") <> 0 OrElse _
               (Left(lowerToken, 2) = "0x" AndAlso _
                InStr(lowerToken, "p") <> 0) OrElse _
               (Left(lowerToken, 2) <> "0x" AndAlso _
                (InStr(lowerToken, "e") <> 0 OrElse _
                 InStr(lowerToken, "p") <> 0 OrElse _
                 lastByte = Asc("f") OrElse lastByte = Asc("F") OrElse _
                 lastByte = Asc("d") OrElse lastByte = Asc("D"))) Then _
                Return 0
        End If
    Next
    For position As Long = 1 To Len(rawValue)
        Dim currentByte As Long = Asc(rawValue, position)
        If IsSpaceByte(currentByte) <> 0 OrElse IsIdentifierPart(currentByte) <> 0 Then Continue For
        Select Case currentByte
        Case Asc("("), Asc(")"), Asc("+"), Asc("-"), Asc("*"), Asc("/"), _
             Asc("%"), Asc("|"), Asc("&"), Asc("^"), Asc("~"), Asc("<"), Asc(">"), _
             Asc("!"), Asc("="), Asc("?"), Asc(":"), Asc(",")
        Case Else
            Return 0
        End Select
    Next
    Return -1
End Function

Private Function GenericMacroExpressionContainsIdentifier( _
    ByVal sourceExpression As String _
) As Long
    For position As Long = 1 To Len(sourceExpression)
        If IsIdentifierStart(Asc(sourceExpression, position)) <> 0 Then _
            Return -1
    Next
    Return 0
End Function

Private Function RewriteGenericMacroCharacterConstants( _
    ByVal sourceExpression As String, ByRef normalizedExpression As String _
) As Long
    normalizedExpression = ""
    Dim position As Long = 1
    While position <= Len(sourceExpression)
        Dim currentByte As Long = Asc(sourceExpression, position)
        ' The accepted ASCII subset has the same value in a C wide character
        ' constant, so remove its L prefix before decoding the character.
        If currentByte = Asc("L") AndAlso _
           position < Len(sourceExpression) AndAlso _
           Asc(sourceExpression, position + 1) = Asc("'") Then
            position += 1
            currentByte = Asc("'")
        End If
        If currentByte = Asc("'") Then
            Dim characterValue As Long
            If DecodeCCharacterConstant( _
                sourceExpression, position, characterValue) = 0 Then Return 0
            normalizedExpression &= Trim(Str(characterValue))
        ElseIf currentByte = Asc(Chr(34)) Then
            Return 0
        Else
            normalizedExpression &= Chr(currentByte)
            position += 1
        End If
    Wend
    Return -1
End Function

Private Function GenericMacroStripOuterParentheses( _
    ByVal sourceExpression As String _
) As String
    sourceExpression = Trim(sourceExpression)
    While Left(sourceExpression, 1) = "("
        Dim closePosition As Long = 1
        If ScanSimpleExpressionGroup( _
            sourceExpression, closePosition, Asc("("), Asc(")")) = 0 OrElse _
           closePosition <= Len(sourceExpression) Then Exit While
        sourceExpression = Trim(Mid( _
            sourceExpression, 2, Len(sourceExpression) - 2))
    Wend
    Return sourceExpression
End Function

Private Function GenericMacroNumericTokenIsFloating( _
    ByVal tokenText As String _
) As Long
    Dim lowerToken As String = LCase(tokenText)
    If InStr(lowerToken, ".") <> 0 Then Return -1
    If Left(lowerToken, 2) = "0x" Then _
        Return CInt(InStr(lowerToken, "p") <> 0) * -1
    Return CInt(InStr(lowerToken, "e") <> 0 OrElse _
                InStr(lowerToken, "p") <> 0) * -1
End Function

Private Function TranslateGenericHexFloatingToken( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceToken As String, ByRef freeBasicToken As String _
) As Long
    Dim position As Long = 3
    If LCase(Left(sourceToken, 2)) <> "0x" Then Return 0

    Dim digitCount As Long = 0
    While position <= Len(sourceToken) AndAlso _
          IsHexDigit(Asc(sourceToken, position)) <> 0
        position += 1
        digitCount += 1
    Wend
    If Mid(sourceToken, position, 1) = "." Then
        position += 1
        While position <= Len(sourceToken) AndAlso _
              IsHexDigit(Asc(sourceToken, position)) <> 0
            position += 1
            digitCount += 1
        Wend
    End If
    If digitCount = 0 OrElse LCase(Mid(sourceToken, position, 1)) <> "p" Then _
        Return 0
    position += 1
    If Mid(sourceToken, position, 1) = "+" OrElse _
       Mid(sourceToken, position, 1) = "-" Then position += 1
    Dim exponentStart As Long = position
    While position <= Len(sourceToken) AndAlso _
          Asc(sourceToken, position) >= Asc("0") AndAlso _
          Asc(sourceToken, position) <= Asc("9")
        position += 1
    Wend
    If position = exponentStart Then Return 0

    Dim literalEnd As Long = position - 1
    Dim suffix As String = LCase(Mid(sourceToken, position, 1))
    Dim freeBasicType As String = "Double"
    If suffix = "f" Then
        freeBasicType = "Single"
        position += 1
    ElseIf suffix = "l" Then
        freeBasicType = "CLongDouble"
        position += 1
    End If
    If position <= Len(sourceToken) AndAlso _
       IsIdentifierPart(Asc(sourceToken, position)) <> 0 Then Return 0

    Dim literal As String = Left(sourceToken, literalEnd)
    Dim longDoubleValue As String = _
        "CLongDoubleFromStringValue(StrPtr(!""" & literal & """))"
    Select Case freeBasicType
    Case "Single"
        freeBasicToken = "CSng(" & longDoubleValue & ")"
    Case "CLongDouble"
        freeBasicToken = longDoubleValue
    Case Else
        freeBasicToken = "CDbl(" & longDoubleValue & ")"
    End Select
    translation.genericC.header.usesCLongDouble = -1
    Return -1
End Function

Private Function GenericIntegerMacroCastFloatLiteralCandidate( _
    ByVal sourceExpression As String _
) As Long
    sourceExpression = GenericMacroStripOuterParentheses(Trim(sourceExpression))
    If Left(sourceExpression, 1) <> "(" Then Return 0
    Dim typeEnd As Long = 1
    If ScanSimpleExpressionGroup( _
        sourceExpression, typeEnd, Asc("("), Asc(")")) = 0 Then Return 0
    Dim sourceType As String = Trim(Mid(sourceExpression, 2, typeEnd - 3))
    Dim sourceOperand As String = GenericMacroStripOuterParentheses( _
        Trim(Mid(sourceExpression, typeEnd)))
    If sourceType = "" OrElse InStr(sourceType, "*") <> 0 OrElse _
       LCase(sourceType) = "void" OrElse sourceOperand = "" Then Return 0
    If Left(sourceOperand, 1) = "+" OrElse Left(sourceOperand, 1) = "-" Then _
        sourceOperand = Trim(Mid(sourceOperand, 2))
    sourceOperand = GenericMacroStripOuterParentheses(sourceOperand)

    Dim tokens() As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        sourceOperand, tokens(), tokenCount) = 0 OrElse tokenCount <> 1 Then Return 0
    Dim firstByte As Long = Asc(tokens(0), 1)
    If ((firstByte >= Asc("0") AndAlso firstByte <= Asc("9")) OrElse _
        (firstByte = Asc(".") AndAlso Len(tokens(0)) > 1 AndAlso _
         Asc(tokens(0), 2) >= Asc("0") AndAlso _
         Asc(tokens(0), 2) <= Asc("9"))) = 0 Then Return 0
    Return GenericMacroNumericTokenIsFloating(tokens(0))
End Function

Private Function FindGenericMacroTopLevelOperator( _
    ByVal sourceExpression As String, ByVal operatorText As String _
) As Long
    Dim nesting As Long = 0
    Dim position As Long = 1
    While position <= Len(sourceExpression)
        Dim currentByte As Long = Asc(sourceExpression, position)
        If currentByte = Asc("(") Then
            nesting += 1
            position += 1
            Continue While
        ElseIf currentByte = Asc(")") Then
            nesting -= 1
            If nesting < 0 Then Return 0
            position += 1
            Continue While
        End If
        If nesting = 0 AndAlso Mid( _
            sourceExpression, position, Len(operatorText)) = operatorText Then Return position
        position += 1
    Wend
    Return 0
End Function

Private Function FindGenericMacroTopLevelOperatorLast( _
    ByVal sourceExpression As String, ByVal operatorText As String _
) As Long
    Dim nesting As Long = 0
    Dim lastPosition As Long = 0
    Dim position As Long = 1
    While position <= Len(sourceExpression)
        Select Case Mid(sourceExpression, position, 1)
        Case "(": nesting += 1
        Case ")"
            nesting -= 1
            If nesting < 0 Then Return 0
        End Select
        If nesting = 0 AndAlso Mid( _
            sourceExpression, position, Len(operatorText)) = operatorText Then
            lastPosition = position
            position += Len(operatorText)
        Else
            position += 1
        End If
    Wend
    Return lastPosition
End Function

Private Function SplitGenericMacroConditional( _
    ByVal sourceExpression As String, _
    ByRef conditionText As String, ByRef trueText As String, _
    ByRef falseText As String _
) As Long
    conditionText = ""
    trueText = ""
    falseText = ""
    Dim nesting As Long = 0
    Dim questionPosition As Long = 0
    Dim questionDepth As Long = 0
    Dim colonPosition As Long = 0
    For position As Long = 1 To Len(sourceExpression)
        Select Case Mid(sourceExpression, position, 1)
        Case "(": nesting += 1
        Case ")"
            nesting -= 1
            If nesting < 0 Then Return -1
        Case "?"
            If nesting = 0 Then
                If questionPosition = 0 Then questionPosition = position
                questionDepth += 1
            End If
        Case ":"
            If nesting = 0 AndAlso questionPosition > 0 Then
                questionDepth -= 1
                If questionDepth = 0 Then
                    colonPosition = position
                    Exit For
                End If
            End If
        End Select
    Next
    If nesting <> 0 Then Return -1
    If questionPosition = 0 Then Return 0
    If colonPosition = 0 Then Return -1
    conditionText = Trim(Left(sourceExpression, questionPosition - 1))
    trueText = Trim(Mid( _
        sourceExpression, questionPosition + 1, colonPosition - questionPosition - 1))
    falseText = Trim(Mid(sourceExpression, colonPosition + 1))
    If conditionText = "" OrElse trueText = "" OrElse falseText = "" Then Return -1
    Return 1
End Function

Private Function FindGenericMacroComparison( _
    ByVal sourceExpression As String, ByRef operatorText As String, _
    ByRef operatorPosition As Long _
) As Long
    Dim nesting As Long = 0
    Dim comparisonCount As Long = 0
    operatorText = ""
    operatorPosition = 0
    Dim position As Long = 1
    While position <= Len(sourceExpression)
        Dim currentByte As Long = Asc(sourceExpression, position)
        If currentByte = Asc("(") Then
            nesting += 1
            position += 1
            Continue While
        ElseIf currentByte = Asc(")") Then
            nesting -= 1
            If nesting < 0 Then Return -1
            position += 1
            Continue While
        End If
        If nesting <> 0 Then
            position += 1
            Continue While
        End If

        Dim candidateOperator As String = ""
        If position < Len(sourceExpression) Then
            Dim nextPair As String = Mid(sourceExpression, position, 2)
            Select Case nextPair
            Case "==", "!=", "<=", ">=": candidateOperator = nextPair
            End Select
        End If
        If candidateOperator <> "" Then
            comparisonCount += 1
            If comparisonCount > 1 Then Return -1
            operatorText = candidateOperator
            operatorPosition = position
            position += 2
            Continue While
        End If

        Select Case currentByte
        Case Asc("=")
            Return -1
        Case Asc("!")
            position += 1
            Continue While
        Case Asc("<")
            If position < Len(sourceExpression) AndAlso _
               Asc(sourceExpression, position + 1) = Asc("<") Then
                position += 2
                Continue While
            End If
            candidateOperator = "<"
        Case Asc(">")
            If position < Len(sourceExpression) AndAlso _
               Asc(sourceExpression, position + 1) = Asc(">") Then
                position += 2
                Continue While
            End If
            candidateOperator = ">"
        End Select
        If candidateOperator <> "" Then
            comparisonCount += 1
            If comparisonCount > 1 Then Return -1
            operatorText = candidateOperator
            operatorPosition = position
        End If
        position += 1
    Wend
    If nesting <> 0 Then Return -1
    If comparisonCount > 0 Then Return 1
    Return 0
End Function

Private Function GenericMacroHasTopLevelBitwiseOperator( _
    ByVal sourceExpression As String _
) As Long
    Dim nesting As Long = 0
    Dim position As Long = 1
    While position <= Len(sourceExpression)
        Dim currentByte As Long = Asc(sourceExpression, position)
        If currentByte = Asc("(") Then
            nesting += 1
        ElseIf currentByte = Asc(")") Then
            nesting -= 1
            If nesting < 0 Then Return -1
        ElseIf nesting = 0 Then
            Select Case currentByte
            Case Asc("^")
                Return -1
            Case Asc("&"), Asc("|")
                If position < Len(sourceExpression) AndAlso _
                   Asc(sourceExpression, position + 1) = currentByte Then
                    position += 1
                Else
                    Return -1
                End If
            End Select
        End If
        position += 1
    Wend
    Return 0
End Function

Private Function GenericMacroHasUnsupportedUnaryPointerOperator( _
    ByVal sourceExpression As String _
) As Long
    Dim previousByte As Long = 0
    Dim position As Long = 1
    While position <= Len(sourceExpression)
        Dim currentByte As Long = Asc(sourceExpression, position)
        If currentByte = Asc("&") AndAlso position < Len(sourceExpression) AndAlso _
           Asc(sourceExpression, position + 1) = Asc("&") Then
            previousByte = Asc("&")
            position += 2
            Continue While
        End If
        If currentByte = Asc("&") OrElse currentByte = Asc("*") Then
            If previousByte = 0 OrElse previousByte = Asc("(") OrElse _
               previousByte = Asc("+") OrElse previousByte = Asc("-") OrElse _
               previousByte = Asc("*") OrElse previousByte = Asc("/") OrElse _
               previousByte = Asc("%") OrElse previousByte = Asc("|") OrElse _
               previousByte = Asc("&") OrElse previousByte = Asc("^") OrElse _
               previousByte = Asc("~") OrElse previousByte = Asc("<") OrElse _
               previousByte = Asc(">") OrElse previousByte = Asc("!") OrElse _
               previousByte = Asc("=") OrElse previousByte = Asc("?") OrElse _
               previousByte = Asc(":") Then Return -1
        End If
        If IsSpaceByte(currentByte) = 0 Then previousByte = currentByte
        If position < Len(sourceExpression) AndAlso _
           ((currentByte = Asc("+") AndAlso Asc(sourceExpression, position + 1) = Asc("+")) OrElse _
            (currentByte = Asc("-") AndAlso Asc(sourceExpression, position + 1) = Asc("-"))) Then Return -1
        position += 1
    Wend
    Return 0
End Function

Private Function TranslateGenericMacroIntegerPart( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef freeBasicExpression As String, _
    ByVal depth As Long, ByVal integerDivisionAssumed As Long = 0, _
    ByVal dynamicIntegerDivision As Long = 0 _
) As Long
    If depth >= MAX_GENERIC_MACRO_EXPRESSION_DEPTH Then Return 0
    Dim normalizedExpression As String
    If RewriteGenericMacroCharacterConstants( _
        sourceExpression, normalizedExpression) = 0 Then Return 0
    sourceExpression = Trim(normalizedExpression)
    If sourceExpression = "" Then Return 0
    If (integerDivisionAssumed = 0 AndAlso dynamicIntegerDivision = 0 AndAlso _
        (InStr(sourceExpression, "/") <> 0 OrElse _
         InStr(sourceExpression, "%") <> 0)) OrElse _
       GenericMacroHasUnsupportedUnaryPointerOperator(sourceExpression) <> 0 Then Return 0
    Dim unwrappedExpression As String = _
        GenericMacroStripOuterParentheses(sourceExpression)
    If unwrappedExpression <> sourceExpression Then _
        Return TranslateGenericMacroIntegerPart( _
            translation, unwrappedExpression, freeBasicExpression, depth + 1, _
            integerDivisionAssumed, dynamicIntegerDivision)

    Dim conditionText As String
    Dim trueText As String
    Dim falseText As String
    Dim conditionalStatus As Long = SplitGenericMacroConditional( _
        sourceExpression, conditionText, trueText, falseText)
    If conditionalStatus < 0 Then Return 0
    If conditionalStatus > 0 Then
        Dim freeBasicCondition As String
        Dim freeBasicTrue As String
        Dim freeBasicFalse As String
        If TranslateGenericHeaderCondition( _
            translation, conditionText, freeBasicCondition, depth + 1, _
            integerDivisionAssumed, dynamicIntegerDivision) = 0 OrElse _
           TranslateGenericMacroIntegerPart( _
               translation, trueText, freeBasicTrue, depth + 1, _
               integerDivisionAssumed, dynamicIntegerDivision) = 0 OrElse _
           TranslateGenericMacroIntegerPart( _
               translation, falseText, freeBasicFalse, depth + 1, _
               integerDivisionAssumed, dynamicIntegerDivision) = 0 Then Return 0
        ' FreeBASIC's IIf lowers to conditional branches, so only the selected
        ' C conditional-expression operand executes.
        freeBasicExpression = "IIf(" & freeBasicCondition & ", " & _
            freeBasicTrue & ", " & freeBasicFalse & ")"
        Return -1
    End If

    ' Translate shifts around nested conditional operands explicitly. The
    ' general integer tokenizer cannot keep a C conditional nested inside a
    ' shift right operand while applying C operator precedence.
    Dim shiftLeftPosition As Long = _
        FindGenericMacroTopLevelOperatorLast(sourceExpression, "<<")
    Dim shiftRightPosition As Long = _
        FindGenericMacroTopLevelOperatorLast(sourceExpression, ">>")
    Dim shiftPosition As Long = shiftLeftPosition
    Dim shiftOperator As String = "<<"
    If shiftRightPosition > shiftPosition Then
        shiftPosition = shiftRightPosition
        shiftOperator = ">>"
    End If
    If shiftPosition > 0 Then
        Dim leftSource As String = Trim(Left(sourceExpression, shiftPosition - 1))
        Dim rightSource As String = Trim(Mid( _
            sourceExpression, shiftPosition + Len(shiftOperator)))
        Dim leftExpression As String
        Dim rightExpression As String
        If leftSource = "" OrElse rightSource = "" OrElse _
           TranslateGenericMacroIntegerPart( _
               translation, leftSource, leftExpression, depth + 1, _
               integerDivisionAssumed, dynamicIntegerDivision) = 0 OrElse _
           TranslateGenericMacroIntegerPart( _
               translation, rightSource, rightExpression, depth + 1, _
               integerDivisionAssumed, dynamicIntegerDivision) = 0 Then Return 0
        Dim freeBasicOperator As String = IIf(shiftOperator = "<<", "Shl", "Shr")
        freeBasicExpression = "(" & leftExpression & " " & freeBasicOperator & _
            " " & rightExpression & ")"
        Return -1
    End If

    Dim comparisonText As String
    Dim comparisonPosition As Long
    Dim comparisonStatus As Long = FindGenericMacroComparison( _
        sourceExpression, comparisonText, comparisonPosition)
    Dim hasLogicalOr As Long = CInt( _
        FindGenericMacroTopLevelOperator(sourceExpression, "||") > 0)
    Dim hasLogicalAnd As Long = CInt( _
        FindGenericMacroTopLevelOperator(sourceExpression, "&&") > 0)
    Dim hasNotOperator As Long = CInt( _
        Left(sourceExpression, 1) = "!" AndAlso Left(sourceExpression, 2) <> "!=")
    If comparisonStatus < 0 Then Return 0
    If comparisonStatus > 0 OrElse hasLogicalOr <> 0 OrElse _
       hasLogicalAnd <> 0 OrElse hasNotOperator <> 0 Then
        Dim freeBasicCondition As String
        If TranslateGenericHeaderCondition( _
            translation, sourceExpression, freeBasicCondition, depth + 1, _
            integerDivisionAssumed, dynamicIntegerDivision) = 0 Then Return 0
        ' C Boolean values are 1 or 0; FreeBASIC Boolean values are -1 or 0.
        freeBasicExpression = "IIf(" & freeBasicCondition & ", 1, 0)"
        Return -1
    End If

    If dynamicIntegerDivision <> 0 AndAlso _
       GenericMacroExpressionContainsDivision(sourceExpression) <> 0 Then
        If TranslateGenericHeaderDynamicDivisionExpression( _
            translation, sourceExpression, freeBasicExpression, _
            integerDivisionAssumed, depth + 1, dynamicIntegerDivision) = 0 Then _
            Return 0
        Return -1
    End If

    Return ConvertIntegerExpression( _
        sourceExpression, freeBasicExpression, C2FB_INTEGER_IDENTIFIERS_ANY, _
        integerDivisionAssumed, -1)
End Function

Private Function TranslateGenericHeaderCondition( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef freeBasicCondition As String, _
    ByVal depth As Long, ByVal integerDivisionAssumed As Long = 0, _
    ByVal dynamicIntegerDivision As Long = 0 _
) As Long
    If depth >= MAX_GENERIC_MACRO_EXPRESSION_DEPTH Then Return 0
    sourceExpression = Trim(sourceExpression)
    If sourceExpression = "" Then Return 0
    sourceExpression = GenericMacroStripOuterParentheses(sourceExpression)

    Dim conditionText As String
    Dim trueText As String
    Dim falseText As String
    Dim conditionalStatus As Long = SplitGenericMacroConditional( _
        sourceExpression, conditionText, trueText, falseText)
    If conditionalStatus < 0 Then Return 0
    If conditionalStatus > 0 Then
        Dim freeBasicInteger As String
        If TranslateGenericMacroIntegerPart( _
            translation, sourceExpression, freeBasicInteger, depth + 1, _
            integerDivisionAssumed, dynamicIntegerDivision) = 0 Then Return 0
        freeBasicCondition = "(" & freeBasicInteger & ") <> 0"
        Return -1
    End If

    Dim operatorPosition As Long = FindGenericMacroTopLevelOperator( _
        sourceExpression, "||")
    If operatorPosition > 0 Then
        Dim leftCondition As String
        Dim rightCondition As String
        If TranslateGenericHeaderCondition( _
            translation, Left(sourceExpression, operatorPosition - 1), leftCondition, _
            depth + 1, integerDivisionAssumed, dynamicIntegerDivision) = 0 OrElse _
           TranslateGenericHeaderCondition( _
            translation, Mid(sourceExpression, operatorPosition + 2), rightCondition, _
            depth + 1, integerDivisionAssumed, dynamicIntegerDivision) = 0 Then Return 0
        freeBasicCondition = "(" & leftCondition & ") OrElse (" & rightCondition & ")"
        Return -1
    End If

    operatorPosition = FindGenericMacroTopLevelOperator(sourceExpression, "&&")
    If operatorPosition > 0 Then
        Dim leftCondition As String
        Dim rightCondition As String
        If TranslateGenericHeaderCondition( _
            translation, Left(sourceExpression, operatorPosition - 1), leftCondition, _
            depth + 1, integerDivisionAssumed, dynamicIntegerDivision) = 0 OrElse _
           TranslateGenericHeaderCondition( _
            translation, Mid(sourceExpression, operatorPosition + 2), rightCondition, _
            depth + 1, integerDivisionAssumed, dynamicIntegerDivision) = 0 Then Return 0
        freeBasicCondition = "(" & leftCondition & ") AndAlso (" & rightCondition & ")"
        Return -1
    End If

    Dim comparisonText As String
    Dim comparisonPosition As Long
    Dim comparisonStatus As Long = FindGenericMacroComparison( _
        sourceExpression, comparisonText, comparisonPosition)
    If comparisonStatus < 0 Then Return 0
    If comparisonStatus > 0 Then
        Dim leftText As String = Trim(Left(sourceExpression, comparisonPosition - 1))
        Dim rightText As String = Trim(Mid( _
            sourceExpression, comparisonPosition + Len(comparisonText)))
        If leftText = "" OrElse rightText = "" OrElse _
           GenericMacroHasTopLevelBitwiseOperator(leftText) <> 0 OrElse _
           GenericMacroHasTopLevelBitwiseOperator(rightText) <> 0 Then Return 0
        Dim freeBasicLeft As String
        Dim freeBasicRight As String
        If TranslateGenericMacroIntegerPart( _
            translation, leftText, freeBasicLeft, depth + 1, _
            integerDivisionAssumed, dynamicIntegerDivision) = 0 OrElse _
           TranslateGenericMacroIntegerPart( _
            translation, rightText, freeBasicRight, depth + 1, _
            integerDivisionAssumed, dynamicIntegerDivision) = 0 Then Return 0
        Dim freeBasicOperator As String = comparisonText
        Select Case comparisonText
        Case "==": freeBasicOperator = "="
        Case "!=": freeBasicOperator = "<>"
        End Select
        freeBasicCondition = "(" & freeBasicLeft & " " & _
            freeBasicOperator & " " & freeBasicRight & ")"
        Return -1
    End If

    If Left(sourceExpression, 1) = "!" AndAlso Left(sourceExpression, 2) <> "!=" Then
        Dim operandCondition As String
        If TranslateGenericHeaderCondition( _
            translation, Mid(sourceExpression, 2), operandCondition, _
            depth + 1, integerDivisionAssumed, dynamicIntegerDivision) = 0 Then Return 0
        freeBasicCondition = "Not (" & operandCondition & ")"
        Return -1
    End If

    Dim freeBasicInteger As String
    If TranslateGenericMacroIntegerPart( _
        translation, sourceExpression, freeBasicInteger, depth + 1, _
        integerDivisionAssumed, dynamicIntegerDivision) = 0 Then Return 0
    freeBasicCondition = "(" & freeBasicInteger & ") <> 0"
    Return -1
End Function

Private Function TranslateGenericHeaderIntegerExpression( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef freeBasicExpression As String, _
    ByVal depth As Long, ByVal integerDivisionAssumed As Long = 0, _
    ByVal dynamicIntegerDivision As Long = 0 _
) As Long
    Return TranslateGenericMacroIntegerPart( _
        translation, sourceExpression, freeBasicExpression, depth, _
        integerDivisionAssumed, dynamicIntegerDivision)
End Function

Private Function GenericMacroTokenNeedsSpace( _
    ByVal previousToken As String, ByVal currentToken As String _
) As Long
    If previousToken = "" Then Return 0
    If previousToken = "," Then Return -1
    If currentToken = "," OrElse currentToken = ")" OrElse _
       currentToken = "]" OrElse currentToken = "->" Then Return 0
    If previousToken = "->" OrElse previousToken = "@" Then Return 0
    If currentToken = "[" AndAlso _
       (previousToken = ")" OrElse IsIdentifierToken(previousToken) <> 0) Then Return 0
    If previousToken = "(" OrElse previousToken = "[" OrElse _
       previousToken = "#" OrElse previousToken = "##" OrElse _
       currentToken = "##" Then Return 0
    If currentToken = "(" AndAlso _
       (previousToken = ")" OrElse IsIdentifierToken(previousToken) <> 0) Then Return 0
    Return -1
End Function

Private Function GenericMacroAddressOfOperator( _
    tokens() As String, ByVal tokenIndex As Long _
) As Long
    If tokenIndex = 0 Then Return -1
    Select Case tokens(tokenIndex - 1)
    Case "(", "[", ",", "=", "+=", "-=", "*=", "/=", "%=", _
         "&=", "|=", "^=", "<<=", ">>=", "?", ":", "+", "-", _
         "*", "/", "%", "&", "|", "^", "~", "!", "&&", "||", _
         "==", "!=", "<", ">", "<=", ">=", "<<", ">>"
        Return -1
    End Select
    Return 0
End Function

Private Function GenericMacroCastOperandIsComplete( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String _
) As Long
    sourceExpression = Trim(sourceExpression)
    If sourceExpression = "" Then Return 0

    If Left(sourceExpression, 1) = "(" Then
        Dim groupEnd As Long = 1
        ' Keep a grouped operand only when its parentheses enclose all of it.
        If ScanSimpleExpressionGroup( _
            sourceExpression, groupEnd, Asc("("), Asc(")")) <> 0 AndAlso _
           groupEnd > Len(sourceExpression) Then Return -1
        If groupEnd <= 1 OrElse groupEnd >= Len(sourceExpression) Then Return 0
        Dim castType As String
        Dim isPointerCast As Long
        If GenericHeaderMacroCastType( _
            translation, Mid(sourceExpression, 2, groupEnd - 3), _
            castType, isPointerCast) = 0 Then Return 0
        Dim castOperand As String = Trim(Mid(sourceExpression, groupEnd))
        If castOperand = "" Then Return 0
        Return GenericMacroCastOperandIsComplete(translation, castOperand)
    End If

    Dim position As Long = 1
    While position <= Len(sourceExpression) AndAlso _
          (Asc(sourceExpression, position) = Asc("+") OrElse _
           Asc(sourceExpression, position) = Asc("-"))
        position += 1
        If position > 2 Then Return 0
    Wend
    If position > 1 Then
        While position <= Len(sourceExpression) AndAlso _
              IsSpaceByte(Asc(sourceExpression, position)) <> 0
            position += 1
        Wend
    End If
    If position > Len(sourceExpression) Then Return 0

    Dim numericOperand As String = Trim(Mid(sourceExpression, position))
    Dim numericTokens() As String
    Dim numericTokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        numericOperand, numericTokens(), numericTokenCount) <> 0 AndAlso _
       numericTokenCount = 1 Then
        Dim numericFirstByte As Long = Asc(numericTokens(0), 1)
        If (numericFirstByte >= Asc("0") AndAlso _
            numericFirstByte <= Asc("9")) OrElse _
           (numericFirstByte = Asc(".") AndAlso _
            Len(numericTokens(0)) > 1 AndAlso _
            Asc(numericTokens(0), 2) >= Asc("0") AndAlso _
            Asc(numericTokens(0), 2) <= Asc("9")) Then Return -1
    End If

    Dim firstByte As Long = Asc(sourceExpression, position)
    If IsIdentifierStart(firstByte) <> 0 OrElse _
       (firstByte >= Asc("0") AndAlso firstByte <= Asc("9")) Then
        position += 1
        While position <= Len(sourceExpression) AndAlso _
              IsIdentifierPart(Asc(sourceExpression, position)) <> 0
            position += 1
        Wend
        If position > Len(sourceExpression) Then Return -1
        While position <= Len(sourceExpression) AndAlso _
              IsSpaceByte(Asc(sourceExpression, position)) <> 0
            position += 1
        Wend
        If position <= Len(sourceExpression) AndAlso _
           Asc(sourceExpression, position) = Asc("(") Then
            Dim callEnd As Long = position
            If ScanSimpleExpressionGroup( _
                sourceExpression, callEnd, Asc("("), Asc(")")) = 0 Then Return 0
            Return CInt(Trim(Mid(sourceExpression, callEnd)) = "")
        End If
    End If
    Return 0
End Function

Private Function GenericMacroExpressionContainsTypeCast( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, parameterNames() As String, _
    ByVal parameterCount As Long _
) As Long
    Dim foundScalarCast As Long = 0
    For position As Long = 1 To Len(sourceExpression)
        If Mid(sourceExpression, position, 1) <> "(" Then Continue For
        Dim groupEnd As Long = position
        If ScanSimpleExpressionGroup( _
            sourceExpression, groupEnd, Asc("("), Asc(")")) = 0 Then Continue For
        Dim sourceType As String = Mid( _
            sourceExpression, position + 1, groupEnd - position - 2)
        Dim namesParameter As Long = 0
        For parameterIndex As Long = 0 To parameterCount - 1
            If sourceType = parameterNames(parameterIndex) Then
                namesParameter = -1
                Exit For
            End If
        Next
        If namesParameter <> 0 Then Continue For
        Dim freeBasicType As String
        Dim isPointerCast As Long
        If GenericHeaderMacroCastType( _
            translation, sourceType, freeBasicType, isPointerCast) <> 0 Then
            ' C pointer addition scales by the pointee size, while FreeBASIC
            ' pointer addition uses byte offsets. Leave that shape to a later
            ' dedicated lowering instead of treating it as integer arithmetic.
            If isPointerCast <> 0 Then Return 0
            foundScalarCast = -1
        End If
    Next
    Return foundScalarCast
End Function

Private Function FindGenericMacroRightmostBinaryOperator( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByVal operatorGroup As Long, _
    ByRef operatorText As String, ByRef operatorPosition As Long, _
    parameterNames() As String, ByVal parameterCount As Long _
) As Long
    ' Groups follow C precedence from bitwise OR through multiplication.
    ' The rightmost operator at one precedence preserves left associativity.
    operatorText = ""
    operatorPosition = 0
    Dim nesting As Long = 0
    For position As Long = 1 To Len(sourceExpression)
        Dim currentText As String = Mid(sourceExpression, position, 1)
        If currentText = "(" Then
            nesting += 1
            Continue For
        ElseIf currentText = ")" Then
            nesting -= 1
            If nesting < 0 Then Return 0
            Continue For
        End If
        If nesting <> 0 Then Continue For

        Dim candidate As String
        Select Case operatorGroup
        Case 0 ' Bitwise OR
            If currentText = "|" AndAlso _
               Mid(sourceExpression, position + 1, 1) <> "|" AndAlso _
               (position = 1 OrElse Mid(sourceExpression, position - 1, 1) <> "|") AndAlso _
               Mid(sourceExpression, position + 1, 1) <> "=" Then candidate = "|"
        Case 1 ' Bitwise XOR
            If currentText = "^" Then candidate = "^"
        Case 2 ' Bitwise AND
            If currentText = "&" AndAlso _
               Mid(sourceExpression, position + 1, 1) <> "&" AndAlso _
               (position = 1 OrElse Mid(sourceExpression, position - 1, 1) <> "&") AndAlso _
               Mid(sourceExpression, position + 1, 1) <> "=" Then candidate = "&"
        Case 3 ' Shifts
            If position < Len(sourceExpression) AndAlso _
               (Mid(sourceExpression, position, 2) = "<<" OrElse _
                Mid(sourceExpression, position, 2) = ">>") AndAlso _
               Mid(sourceExpression, position + 2, 1) <> "=" Then _
                candidate = Mid(sourceExpression, position, 2)
        Case 4 ' Addition and subtraction
            If (currentText = "+" OrElse currentText = "-") AndAlso _
               Mid(sourceExpression, position + 1, 1) <> currentText AndAlso _
               (position = 1 OrElse Mid(sourceExpression, position - 1, 1) <> currentText) AndAlso _
               Not (currentText = "-" AndAlso _
                    Mid(sourceExpression, position + 1, 1) = ">") Then
                Dim previousPosition As Long = position - 1
                While previousPosition > 0 AndAlso _
                      IsSpaceByte(Asc(sourceExpression, previousPosition)) <> 0
                    previousPosition -= 1
                Wend
                Dim followsCastType As Long = 0
                If previousPosition > 0 AndAlso _
                   Mid(sourceExpression, previousPosition, 1) = ")" Then
                    Dim groupDepth As Long = 0
                    Dim castOpenPosition As Long = 0
                    For scanPosition As Long = previousPosition To 1 Step -1
                        Dim groupByte As String = Mid( _
                            sourceExpression, scanPosition, 1)
                        If groupByte = ")" Then
                            groupDepth += 1
                        ElseIf groupByte = "(" Then
                            groupDepth -= 1
                            If groupDepth = 0 Then
                                castOpenPosition = scanPosition
                                Exit For
                            End If
                        End If
                    Next
                    If castOpenPosition > 0 Then
                        Dim castType As String = Trim(Mid( _
                            sourceExpression, castOpenPosition + 1, _
                            previousPosition - castOpenPosition - 1))
                        Dim namesParameter As Long = 0
                        For parameterIndex As Long = 0 To parameterCount - 1
                            If castType = parameterNames(parameterIndex) Then
                                namesParameter = -1
                                Exit For
                            End If
                        Next
                        If namesParameter = 0 Then
                            Dim freeBasicCastType As String
                            Dim isPointerCast As Long
                            followsCastType = GenericHeaderMacroCastType( _
                                translation, castType, freeBasicCastType, _
                                isPointerCast)
                        End If
                    End If
                End If
                If previousPosition > 0 AndAlso _
                   InStr("(+-*/&|^~!<>=?:,", _
                         Mid(sourceExpression, previousPosition, 1)) = 0 AndAlso _
                   followsCastType = 0 Then
                    candidate = currentText
                End If
            End If
        Case 5 ' Multiplication, division, and remainder
            If (currentText = "*" OrElse currentText = "/" OrElse _
                currentText = "%") AndAlso _
               Mid(sourceExpression, position + 1, 1) <> "=" Then
                Dim previousPosition As Long = position - 1
                While previousPosition > 0 AndAlso _
                      IsSpaceByte(Asc(sourceExpression, previousPosition)) <> 0
                    previousPosition -= 1
                Wend
                If previousPosition > 0 AndAlso _
                   InStr("(+-*/%&|^~!<>=?:,", _
                         Mid(sourceExpression, previousPosition, 1)) = 0 Then
                    candidate = currentText
                End If
            End If
        End Select
        If candidate <> "" Then
            operatorText = candidate
            operatorPosition = position
        End If
    Next
    Return CInt(operatorPosition > 0) * -1
End Function

Private Function TranslateGenericHeaderDynamicDivisionExpression( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef freeBasicExpression As String, _
    ByVal integerDivisionAssumed As Long, ByVal depth As Long, _
    ByVal dynamicIntegerDivision As Long _
) As Long
    If depth >= MAX_GENERIC_MACRO_EXPRESSION_DEPTH OrElse _
       dynamicIntegerDivision = 0 Then Return 0
    sourceExpression = GenericMacroStripOuterParentheses(Trim(sourceExpression))
    If sourceExpression = "" Then Return 0

    If GenericMacroExpressionContainsDivision(sourceExpression) = 0 Then
        Return ConvertIntegerExpression( _
            sourceExpression, freeBasicExpression, _
            C2FB_INTEGER_IDENTIFIERS_ANY, integerDivisionAssumed, -1)
    End If

    Dim noParameterNames(0 To 0) As String
    For operatorGroup As Long = 0 To 5
        Dim operatorText As String
        Dim operatorPosition As Long
        If FindGenericMacroRightmostBinaryOperator( _
            translation, sourceExpression, operatorGroup, operatorText, _
            operatorPosition, noParameterNames(), 0) = 0 Then _
            Continue For
        Dim leftSource As String = Trim(Left(sourceExpression, operatorPosition - 1))
        Dim rightSource As String = Trim(Mid( _
            sourceExpression, operatorPosition + Len(operatorText)))
        If leftSource = "" OrElse rightSource = "" Then Return 0

        Dim leftExpression As String
        Dim rightExpression As String
        If TranslateGenericHeaderDynamicDivisionExpression( _
            translation, leftSource, leftExpression, integerDivisionAssumed, _
            depth + 1, dynamicIntegerDivision) = 0 OrElse _
           TranslateGenericHeaderDynamicDivisionExpression( _
            translation, rightSource, rightExpression, integerDivisionAssumed, _
            depth + 1, dynamicIntegerDivision) = 0 Then Return 0

        If operatorText = "/" OrElse operatorText = "%" Then
            Dim helperName As String = GenericHeaderOperatorHelperNameInContext( _
                translation, operatorText)
            freeBasicExpression = helperName & "(" & leftExpression & ", " & _
                rightExpression & ")"
            Return -1
        End If

        Dim freeBasicOperator As String = operatorText
        Select Case operatorText
        Case "|": freeBasicOperator = "Or"
        Case "^": freeBasicOperator = "Xor"
        Case "&": freeBasicOperator = "And"
        Case "<<": freeBasicOperator = "Shl"
        Case ">>": freeBasicOperator = "Shr"
        End Select
        freeBasicExpression = "(" & leftExpression & " " & _
            freeBasicOperator & " " & rightExpression & ")"
        Return -1
    Next

    Return 0
End Function

Private Function TranslateGenericHeaderMacroCastBinaryExpression( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef freeBasicExpression As String, _
    parameterNames() As String, freeParameterNames() As String, _
    ByVal parameterCount As Long, _
    ByVal integerDivisionAssumed As Long, ByVal depth As Long, _
    ByVal dynamicIntegerDivision As Long _
) As Long
    If GenericMacroExpressionContainsTypeCast( _
        translation, sourceExpression, parameterNames(), parameterCount) = 0 Then _
        Return 0

    For operatorGroup As Long = 0 To 5
        Dim operatorText As String
        Dim operatorPosition As Long
        If FindGenericMacroRightmostBinaryOperator( _
            translation, sourceExpression, operatorGroup, operatorText, _
            operatorPosition, parameterNames(), parameterCount) = 0 Then _
            Continue For
        Dim leftSource As String = Trim(Left(sourceExpression, operatorPosition - 1))
        Dim rightSource As String = Trim(Mid( _
            sourceExpression, operatorPosition + Len(operatorText)))
        If leftSource = "" OrElse rightSource = "" Then Return 1

        Dim leftFreeBasic As String
        Dim rightFreeBasic As String
        If TranslateGenericHeaderMacroExpressionWithParameters( _
            translation, leftSource, leftFreeBasic, parameterNames(), _
            freeParameterNames(), parameterCount, integerDivisionAssumed, _
            depth + 1, dynamicIntegerDivision) = 0 OrElse _
           TranslateGenericHeaderMacroExpressionWithParameters( _
            translation, rightSource, rightFreeBasic, parameterNames(), _
            freeParameterNames(), parameterCount, integerDivisionAssumed, _
            depth + 1, dynamicIntegerDivision) = 0 Then Return 1

        If operatorText = "/" OrElse operatorText = "%" Then
            If dynamicIntegerDivision <> 0 Then
                Dim helperName As String = GenericHeaderOperatorHelperNameInContext( _
                    translation, operatorText)
                freeBasicExpression = helperName & "(" & leftFreeBasic & ", " & _
                    rightFreeBasic & ")"
                Return -1
            End If
            If integerDivisionAssumed = 0 Then Return 1
        End If

        Dim freeBasicOperator As String = operatorText
        Select Case operatorText
        Case "/": If integerDivisionAssumed <> 0 Then freeBasicOperator = Chr(92)
        Case "%": freeBasicOperator = "Mod"
        Case "|": freeBasicOperator = "Or"
        Case "^": freeBasicOperator = "Xor"
        Case "&": freeBasicOperator = "And"
        Case "<<": freeBasicOperator = "Shl"
        Case ">>": freeBasicOperator = "Shr"
        End Select
        freeBasicExpression = "(" & leftFreeBasic & " " & _
            freeBasicOperator & " " & rightFreeBasic & ")"
        Return -1
    Next
    Return 0
End Function

Private Function GenericHeaderScalarAliasCastTargetInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal freeBasicType As String _
) As Long
    Dim currentType As String = freeBasicType
    For aliasDepth As Long = 0 To 31
        Select Case currentType
        Case "Byte", "UByte", "Short", "UShort", "Long", "ULong", _
             "CLong", "CULong", "LongInt", "ULongInt", "Integer", _
             "UInteger", "Single", "Double", "CLongDouble", "wchar_t"
            Return -1
        End Select
        Dim aliasIndex As Long = -1
        For candidateIndex As Long = 0 To _
            translation.genericC.header.headerTypeAliasCount - 1
            If translation.genericC.header.headerTypeAliases( _
                candidateIndex).freeBasicName = currentType Then
                aliasIndex = candidateIndex
                Exit For
            End If
        Next
        If aliasIndex < 0 Then Return 0
        With translation.genericC.header.headerTypeAliases(aliasIndex)
            If .isArray <> 0 OrElse .isForward <> 0 OrElse _
               .baseType = "Record" OrElse InStr(.baseType, " Ptr") <> 0 OrElse _
               Left(.baseType, 9) = "Function " OrElse Left(.baseType, 4) = "Sub " Then Return 0
            currentType = .baseType
        End With
    Next
    Return 0
End Function

Private Function GenericHeaderInlineCallbackCastType( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceType As String, ByRef freeBasicType As String _
) As Long
    sourceType = StripCFunctionAttributes(sourceType)
    If sourceType = "" Then Return 0
    Dim typeTokens() As String
    Dim typeTokenCount As Long
    TokenizeCDeclaration(sourceType, typeTokens(), typeTokenCount)
    If typeTokenCount < 4 OrElse typeTokenCount >= MAX_TYPE_WORDS Then Return 0

    Dim emptyCatalog As C2fbProjectCatalog
    Dim callbackResult As C2fbCallbackTypeResultModel
    ResolveCBodyCallbackTypeInContext( _
        translation, emptyCatalog, typeTokens(), 0, typeTokenCount - 1, _
        callbackResult, 0, C2FB_TYPE_MAPPING_GENERIC_HEADER)
    If callbackResult.status <> C2FB_CALLBACK_TYPE_CONVERTED Then Return 0
    freeBasicType = CBodyCallbackDeclarationInContext( _
        translation, callbackResult.freeBasicType)
    Return CInt(freeBasicType <> "") * -1
End Function

Private Function GenericHeaderMacroCastType( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceType As String, ByRef freeBasicType As String, _
    ByRef isPointerCast As Long _
) As Long
    isPointerCast = 0
    Dim typeTokens() As String
    Dim typeTokenCount As Long
    TokenizeCDeclaration(sourceType, typeTokens(), typeTokenCount)
    If typeTokenCount = 0 OrElse typeTokenCount >= MAX_TYPE_WORDS Then Return 0
    If GenericHeaderInlineCallbackCastType( _
        translation, sourceType, freeBasicType) <> 0 Then
        isPointerCast = -1
        Return -1
    End If

    Dim parsedType As C2fbCTypeModel
    If ParseCTypeModel( _
        typeTokens(), 0, typeTokenCount - 1, parsedType) = 0 OrElse _
       parsedType.hasUnsupportedSyntax <> 0 Then Return 0
    If parsedType.pointerDepth = 0 AndAlso _
       (parsedType.isStruct <> 0 OrElse parsedType.isUnion <> 0) Then
        ' A macro cast is expanded at its call site. Preserve an incomplete
        ' record name there even though no by-value layout can be emitted here.
        freeBasicType = GenericHeaderTagAliasNameInHeader( _
            translation.genericC.header, parsedType.baseName)
        If freeBasicType = "" Then
            freeBasicType = GenericTypeOverrideInPolicy( _
                translation.genericC.policy, parsedType.baseName)
        End If
        If freeBasicType = "" Then
            freeBasicType = translation.genericC.policy.generatedNamePrefix & _
                parsedType.baseName
        End If
        Return -1
    End If

    Dim pointerCount As Long
    Dim isConst As Long
    freeBasicType = MapGenericHeaderCType( _
        translation, parsedType, pointerCount, isConst, _
        C2FB_POINTER_MAPPING_PRESERVE)
    If freeBasicType = "" Then Return 0
    Dim mappedBaseType As String = freeBasicType
    If Left(mappedBaseType, 6) = "Const " Then _
        mappedBaseType = Trim(Mid(mappedBaseType, 7))
    While Right(mappedBaseType, 4) = " Ptr"
        mappedBaseType = Trim(Left(mappedBaseType, Len(mappedBaseType) - 4))
    Wend
    Dim pointerAliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
        translation.genericC.header, parsedType.baseName, 0)
    If pointerAliasIndex < 0 Then _
        pointerAliasIndex = GenericHeaderTypeAliasIndexInHeader( _
            translation.genericC.header, parsedType.baseName, -1)
    If pointerAliasIndex >= 0 AndAlso _
       (translation.genericC.header.headerTypeAliases(pointerAliasIndex).isFunction <> 0 OrElse _
        Left(translation.genericC.header.headerTypeAliases(pointerAliasIndex).baseType, 9) = "Function " OrElse _
        Left(translation.genericC.header.headerTypeAliases(pointerAliasIndex).baseType, 4) = "Sub ") Then
        isPointerCast = -1
        Return -1
    End If
    If pointerCount > 0 AndAlso pointerAliasIndex < 0 AndAlso _
       (parsedType.isStruct <> 0 OrElse parsedType.isUnion <> 0) AndAlso _
       GenericHeaderTagAliasNameInHeader( _
        translation.genericC.header, parsedType.baseName) = "" AndAlso _
       GenericTypeOverrideInPolicy( _
        translation.genericC.policy, parsedType.baseName) = "" Then
        ' An incomplete record tag has no member layout to preserve. Its
        ' pointer representation is still valid as an opaque ABI pointer.
        freeBasicType = "Any"
        For pointerIndex As Long = 0 To pointerCount - 1
            freeBasicType &= " Ptr"
        Next
        isPointerCast = -1
        Return -1
    End If
    If pointerCount > 0 OrElse (pointerAliasIndex >= 0 AndAlso _
       InStr(translation.genericC.header.headerTypeAliases(pointerAliasIndex).baseType, " Ptr") <> 0) Then
        Select Case mappedBaseType
        Case "Any", "ZString", "WString", "Byte", "UByte", "Short", _
             "UShort", "Long", "ULong", "CLong", "CULong", "LongInt", _
             "ULongInt", "Integer", "UInteger", "Single", "Double", _
             "CLongDouble", "wchar_t", "Cva_List"
        Case Else
            If pointerAliasIndex < 0 AndAlso _
               GenericTypeOverrideInPolicy( _
                translation.genericC.policy, parsedType.baseName) = "" AndAlso _
               GenericHeaderTagAliasNameInHeader( _
                translation.genericC.header, parsedType.baseName) = "" Then Return 0
        End Select
        isPointerCast = -1
        Return -1
    End If
    If GenericHeaderScalarAliasCastTargetInContext( _
        translation, freeBasicType) <> 0 Then Return -1
    If GenericTypeOverrideInPolicy( _
        translation.genericC.policy, parsedType.baseName) <> "" AndAlso _
       InStr(freeBasicType, " Ptr") = 0 AndAlso _
       freeBasicType <> "Any" AndAlso freeBasicType <> "void" AndAlso _
       Left(freeBasicType, 9) <> "Function " AndAlso _
       Left(freeBasicType, 4) <> "Sub " Then Return -1
    freeBasicType = ""
    Return 0
End Function

Declare Function GenericNullPointerConstantText( _
    ByVal sourceText As String _
) As Long

Private Function GenericHeaderMacroPointerCastCandidate( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String _
) As Long
    If GenericNullPointerConstantText(sourceExpression) <> 0 Then Return 0
    sourceExpression = GenericMacroStripOuterParentheses(Trim(sourceExpression))
    If Left(sourceExpression, 1) <> "(" Then Return 0
    Dim typeEnd As Long = 1
    If ScanSimpleExpressionGroup( _
        sourceExpression, typeEnd, Asc("("), Asc(")")) = 0 Then Return 0
    Dim typeTokens() As String
    Dim typeTokenCount As Long
    TokenizeCDeclaration( _
        Mid(sourceExpression, 2, typeEnd - 3), typeTokens(), typeTokenCount)
    If typeTokenCount = 0 OrElse typeTokenCount >= MAX_TYPE_WORDS Then Return 0
    Dim inlineCallbackType As String
    If GenericHeaderInlineCallbackCastType( _
        translation, Mid(sourceExpression, 2, typeEnd - 3), _
        inlineCallbackType) <> 0 Then Return -1
    Dim parsedType As C2fbCTypeModel
    If ParseCTypeModel( _
        typeTokens(), 0, typeTokenCount - 1, parsedType) = 0 OrElse _
       parsedType.hasUnsupportedSyntax <> 0 Then Return 0
    If parsedType.pointerDepth > 0 Then Return -1

    Dim aliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
        translation.genericC.header, parsedType.baseName, 0)
    If aliasIndex < 0 Then _
        aliasIndex = GenericHeaderTypeAliasIndexInHeader( _
            translation.genericC.header, parsedType.baseName, -1)
    If aliasIndex >= 0 Then
        With translation.genericC.header.headerTypeAliases(aliasIndex)
            If .isFunction <> 0 OrElse Left(.baseType, 9) = "Function " OrElse _
               Left(.baseType, 4) = "Sub " OrElse _
               InStr(.baseType, " Ptr") <> 0 Then Return -1
        End With
    End If
    Return CInt(InStr( _
        GenericTypeOverrideInPolicy( _
            translation.genericC.policy, parsedType.baseName), " Ptr") <> 0)
End Function

Private Function StripGenericVoidCastExpression( _
    ByVal sourceExpression As String, ByRef operandExpression As String _
) As Long
    sourceExpression = Trim(sourceExpression)
    operandExpression = ""
    If Left(sourceExpression, 1) <> "(" Then Return 0

    Dim typeEnd As Long = 1
    If ScanSimpleExpressionGroup( _
        sourceExpression, typeEnd, Asc("("), Asc(")")) = 0 Then Return 0
    Dim typeTokens() As String
    Dim typeTokenCount As Long
    TokenizeCDeclaration( _
        Mid(sourceExpression, 2, typeEnd - 3), typeTokens(), typeTokenCount)
    If typeTokenCount <> 1 OrElse typeTokens(0) <> "void" Then Return 0

    operandExpression = Trim(Mid(sourceExpression, typeEnd))
    If operandExpression = "" Then Return 0
    Return -1
End Function

Private Function TryTranslateGenericHeaderStringPointerCast( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef freeBasicExpression As String _
) As Long
    sourceExpression = GenericMacroStripOuterParentheses(Trim(sourceExpression))
    If Left(sourceExpression, 1) <> "(" Then Return 0
    Dim typeEnd As Long = 1
    If ScanSimpleExpressionGroup( _
        sourceExpression, typeEnd, Asc("("), Asc(")")) = 0 Then Return 0

    Dim typeTokens() As String
    Dim typeTokenCount As Long
    TokenizeCDeclaration( _
        Mid(sourceExpression, 2, typeEnd - 3), typeTokens(), typeTokenCount)
    If typeTokenCount = 0 OrElse typeTokenCount >= MAX_TYPE_WORDS Then Return 0
    Dim parsedType As C2fbCTypeModel
    If ParseCTypeModel( _
        typeTokens(), 0, typeTokenCount - 1, parsedType) = 0 OrElse _
       parsedType.hasUnsupportedSyntax <> 0 Then Return 0
    Dim freeBasicType As String
    If parsedType.pointerDepth = 0 Then
        Dim aliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
            translation.genericC.header, parsedType.baseName, 0)
        If aliasIndex < 0 OrElse _
           translation.genericC.header.headerTypeAliases(aliasIndex).isArray <> 0 OrElse _
           translation.genericC.header.headerTypeAliases(aliasIndex).isFunction <> 0 OrElse _
           GenericFreeBasicTypePointerDepthInHeader( _
               translation.genericC.header, _
               translation.genericC.header.headerTypeAliases(aliasIndex).freeBasicName, 0) <> 1 Then _
            Return 0
        freeBasicType = _
            translation.genericC.header.headerTypeAliases(aliasIndex).freeBasicName
    ElseIf parsedType.pointerDepth = 1 Then
        Dim pointerCount As Long
        Dim isConst As Long
        freeBasicType = MapGenericHeaderCType( _
            translation, parsedType, pointerCount, isConst, _
            C2FB_POINTER_MAPPING_PRESERVE)
        If pointerCount <> 1 OrElse Right(Trim(freeBasicType), 4) <> " Ptr" Then _
            Return 0
    Else
        Return 0
    End If

    Dim operand As String = Trim(Mid(sourceExpression, typeEnd))
    Dim freeBasicStringPointer As String
    If Left(operand, 1) = "&" Then operand = Trim(Mid(operand, 2))
    If TranslateGenericHeaderStringMacro(operand, freeBasicStringPointer) = 0 Then Return 0
    freeBasicExpression = "CPtr(" & freeBasicType & ", " & _
        freeBasicStringPointer & ")"
    Return -1
End Function

Private Function GenericNullPointerConstantText( _
    ByVal sourceText As String _
) As Long
    Dim compactValue As String
    For position As Long = 1 To Len(sourceText)
        If IsSpaceByte(Asc(sourceText, position)) = 0 Then _
            compactValue &= LCase(Mid(sourceText, position, 1))
    Next
    Select Case compactValue
    Case "0", "0u", "0l", "0ul", "0lu", "0ll", "0ull", "0llu", "null", _
         "__null", "(void*)0", "((void*)0)"
        Return -1
    End Select
    Return 0
End Function

Private Function GenericNullPointerConstantInContext( _
    ByRef translation As C2fbTranslationContext, ByVal macroName As String _
) As Long
    If GenericNullPointerConstantText(macroName) <> 0 Then Return -1
    Dim macroIndex As Long = GenericHeaderMacroIndexInContext( _
        translation, macroName)
    If macroIndex < 0 Then Return 0
    With translation.genericC.header.headerMacros(macroIndex)
        If .active = 0 OrElse .definition.functionLike <> 0 Then Return 0
        Return GenericNullPointerConstantText(.definition.rawValue)
    End With
    Return 0
End Function

Private Function TryTranslateGenericNullPointerComparison( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef freeBasicExpression As String _
) As Long
    sourceExpression = GenericMacroStripOuterParentheses(sourceExpression)
    Dim operatorText As String
    Dim operatorPosition As Long
    If FindGenericMacroComparison( _
        sourceExpression, operatorText, operatorPosition) <> 1 OrElse _
       (operatorText <> "==" AndAlso operatorText <> "!=") Then Return 0

    Dim leftText As String = GenericMacroStripOuterParentheses(Trim( _
        Left(sourceExpression, operatorPosition - 1)))
    Dim rightText As String = GenericMacroStripOuterParentheses(Trim(Mid( _
        sourceExpression, operatorPosition + Len(operatorText))))
    Dim pointerName As String
    If GenericNullPointerConstantInContext(translation, leftText) <> 0 Then
        pointerName = rightText
    ElseIf GenericNullPointerConstantInContext(translation, rightText) <> 0 Then
        pointerName = leftText
    Else
        Return 0
    End If
    If IsIdentifierToken(pointerName) = 0 Then Return 0

    Dim symbolIndex As Long = _
        GenericHeaderSymbolIndexInContext(translation, pointerName)
    If symbolIndex < 0 Then Return 0
    With translation.symbolTable.symbols(symbolIndex)
        If .kind <> GENERIC_SYMBOL_OBJECT OrElse _
           .genericHeader.arrayCount <> 0 OrElse _
           .genericHeader.unsizedArray <> 0 OrElse _
           Right(.genericHeader.freeBasicType, 4) <> " Ptr" OrElse _
           InStr(Left(.genericHeader.freeBasicType, _
               Len(.genericHeader.freeBasicType) - 4), " Ptr") <> 0 Then Return 0
        Dim freeBasicOperator As String = "="
        If operatorText = "!=" Then freeBasicOperator = "<>"
        freeBasicExpression = "IIf((" & .freeBasicName & " " & _
            freeBasicOperator & " 0), 1, 0)"
    End With
    Return -1
End Function

Private Function GenericMacroCastTypeFromParameter( _
    ByVal sourceType As String, parameterNames() As String, _
    freeParameterNames() As String, ByVal parameterCount As Long, _
    ByRef freeBasicType As String, ByRef isPointerCast As Long _
) As Long
    Dim tokens() As String
    Dim tokenCount As Long = 0
    TokenizeCDeclaration(sourceType, tokens(), tokenCount)
    If tokenCount = 0 Then Return 0
    Dim typeIndex As Long = 0
    Dim isConst As Long = 0
    If tokens(typeIndex) = "const" Then
        isConst = -1
        typeIndex += 1
        If typeIndex >= tokenCount Then Return 0
    End If
    Dim parameterIndex As Long = -1
    For candidateIndex As Long = 0 To parameterCount - 1
        If tokens(typeIndex) = parameterNames(candidateIndex) AndAlso _
           parameterNames(candidateIndex) = UCase(parameterNames(candidateIndex)) Then
            parameterIndex = candidateIndex
            Exit For
        End If
    Next
    If parameterIndex < 0 Then Return 0
    Dim pointerDepth As Long = 0
    For tokenIndex As Long = typeIndex + 1 To tokenCount - 1
        Select Case tokens(tokenIndex)
        Case "*"
            pointerDepth += 1
        Case "const", "volatile", "restrict", "__restrict", "__restrict__"
            Continue For
        Case Else
            Return 0
        End Select
    Next
    freeBasicType = freeParameterNames(parameterIndex)
    If isConst <> 0 Then freeBasicType = "Const " & freeBasicType
    For pointerIndex As Long = 0 To pointerDepth - 1
        freeBasicType &= " Ptr"
    Next
    isPointerCast = CInt(pointerDepth > 0) * -1
    Return -1
End Function

Private Function GenericMacroCastTargetIsInteger( _
    ByRef translation As C2fbTranslationContext, _
    ByVal freeBasicType As String _
) As Long
    freeBasicType = Trim(freeBasicType)
    If Left(freeBasicType, 6) = "Const " Then _
        freeBasicType = Trim(Mid(freeBasicType, 7))
    If InStr(freeBasicType, " Ptr") <> 0 Then Return 0
    Dim storageType As String = GenericHeaderTypeAliasStorageTypeInHeader( _
        translation.genericC.header, freeBasicType, 0)
    If storageType <> "" Then freeBasicType = Trim(storageType)
    Select Case LCase(freeBasicType)
    Case "byte", "ubyte", "short", "ushort", "long", "ulong", _
         "clong", "culong", "longint", "ulongint", "integer", "uinteger", _
         "c2fb_c_int", "c2fb_c_uint", "c2fb_c_long", "c2fb_c_ulong", _
         "c2fb_int64", "c2fb_uint64", "c2fb_size_t"
        Return -1
    End Select
    Return 0
End Function

Private Function GenericHeaderIntegerCastHelperHash( _
    ByVal sourceText As String _
) As String
    Dim firstHash As LongInt = 5381
    Dim secondHash As LongInt = 104729
    For position As Long = 1 To Len(sourceText)
        Dim value As LongInt = Asc(sourceText, position)
        firstHash = (firstHash * 33 + value) Mod 2147483647
        secondHash = (secondHash * 65599 + value) Mod 2147483647
    Next
    Return Right("00000000" & Hex(CULngInt(firstHash)), 8) & _
           Right("00000000" & Hex(CULngInt(secondHash)), 8)
End Function

Private Function GenericHeaderIntegerCastHelperNameInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal targetType As String _
) As String
    For helperIndex As Long = 0 To _
        translation.genericC.header.integerCastHelperCount - 1
        With translation.genericC.header.integerCastHelpers(helperIndex)
            If LCase(.targetType) = LCase(targetType) Then Return .functionName
        End With
    Next

    Dim identity As String = GenericHeaderIntegerCastHelperHash( _
        LCase(translation.genericC.header.rootSourcePath) & Chr(0) & _
        LCase(targetType))
    Dim functionName As String = "c2fbInternalCCast_" & identity
    Dim guardName As String = "C2FB_INTERNAL_CCAST_HELPER_" & identity
    Dim noOutputNames(0 To 0) As String
    Dim nameConflict As Long
    Do
        nameConflict = 0
        For symbolIndex As Long = 0 To translation.symbolTable.symbolCount - 1
            If LCase(translation.symbolTable.symbols(symbolIndex).freeBasicName) = _
               LCase(functionName) Then
                nameConflict = -1
                Exit For
            End If
        Next
        If nameConflict = 0 Then
            For macroIndex As Long = 0 To _
                translation.genericC.header.headerMacroCount - 1
                Dim macroName As String = _
                    translation.genericC.header.headerMacros(macroIndex).freeBasicName
                If macroName = "" Then
                    macroName = GenericFreeBasicFunctionNameInContext( _
                        translation, _
                        translation.genericC.header.headerMacros( _
                            macroIndex).definition.sourceName, _
                        noOutputNames(), 0, C2FB_SYMBOL_RENAME_DEFINE)
                End If
                If LCase(macroName) = LCase(functionName) Then
                    nameConflict = -1
                    Exit For
                End If
            Next
        End If
        If nameConflict <> 0 Then
            functionName &= "_"
            guardName &= "_"
        End If
    Loop While nameConflict <> 0

    If translation.genericC.header.integerCastHelperCount > UBound( _
        translation.genericC.header.integerCastHelpers) Then _
        ReDim Preserve translation.genericC.header.integerCastHelpers( _
            0 To UBound(translation.genericC.header.integerCastHelpers) * 2 + 1)
    With translation.genericC.header.integerCastHelpers( _
        translation.genericC.header.integerCastHelperCount)
        .targetType = targetType
        .functionName = functionName
        .guardName = guardName
    End With
    translation.genericC.header.integerCastHelperCount += 1
    Return functionName
End Function

Private Function GenericHeaderOperatorHelperNameInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal operatorText As String _
) As String
    For helperIndex As Long = 0 To _
        translation.genericC.header.operatorHelperCount - 1
        With translation.genericC.header.operatorHelpers(helperIndex)
            If .operatorText = operatorText Then Return .functionName
        End With
    Next

    Dim identity As String = GenericHeaderIntegerCastHelperHash( _
        LCase(translation.genericC.header.rootSourcePath) & Chr(0) & _
        "operator" & Chr(0) & operatorText)
    Dim functionName As String = "c2fbInternalCOperator_" & identity
    Dim guardName As String = "C2FB_INTERNAL_COPERATOR_HELPER_" & identity
    Dim noOutputNames(0 To 0) As String
    Dim nameConflict As Long
    Do
        nameConflict = 0
        For symbolIndex As Long = 0 To translation.symbolTable.symbolCount - 1
            If LCase(translation.symbolTable.symbols(symbolIndex).freeBasicName) = _
               LCase(functionName) Then
                nameConflict = -1
                Exit For
            End If
        Next
        If nameConflict = 0 Then
            For macroIndex As Long = 0 To _
                translation.genericC.header.headerMacroCount - 1
                Dim macroName As String = _
                    translation.genericC.header.headerMacros(macroIndex).freeBasicName
                If macroName = "" Then
                    macroName = GenericFreeBasicFunctionNameInContext( _
                        translation, _
                        translation.genericC.header.headerMacros( _
                            macroIndex).definition.sourceName, _
                        noOutputNames(), 0, C2FB_SYMBOL_RENAME_DEFINE)
                End If
                If LCase(macroName) = LCase(functionName) Then
                    nameConflict = -1
                    Exit For
                End If
            Next
        End If
        If nameConflict <> 0 Then
            functionName &= "_"
            guardName &= "_"
        End If
    Loop While nameConflict <> 0

    If translation.genericC.header.operatorHelperCount > UBound( _
        translation.genericC.header.operatorHelpers) Then _
        ReDim Preserve translation.genericC.header.operatorHelpers( _
            0 To UBound(translation.genericC.header.operatorHelpers) * 2 + 1)
    With translation.genericC.header.operatorHelpers( _
        translation.genericC.header.operatorHelperCount)
        .operatorText = operatorText
        .functionName = functionName
        .guardName = guardName
    End With
    translation.genericC.header.operatorHelperCount += 1
    Return functionName
End Function

Private Function GenericMacroExpressionContainsDivision( _
    ByVal sourceExpression As String _
) As Long
    Dim tokens(Any) As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        sourceExpression, tokens(), tokenCount) = 0 Then Return 0
    For tokenIndex As Long = 0 To tokenCount - 1
        If (tokens(tokenIndex) = "/" OrElse tokens(tokenIndex) = "%") AndAlso _
           (tokenIndex >= tokenCount - 1 OrElse tokens(tokenIndex + 1) <> "=") Then _
            Return -1
    Next
    Return 0
End Function

Private Function GenericMacroOperandReferencesParameter( _
    ByVal sourceOperand As String, parameterNames() As String, _
    ByVal parameterCount As Long _
) As Long
    If parameterCount = 0 Then Return 0
    Dim tokens(Any) As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        sourceOperand, tokens(), tokenCount) = 0 Then Return 0
    For tokenIndex As Long = 0 To tokenCount - 1
        For parameterIndex As Long = 0 To parameterCount - 1
            If tokens(tokenIndex) = parameterNames(parameterIndex) Then Return -1
        Next
    Next
    Return 0
End Function

Private Function TryTranslateGenericHeaderMacroCast( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef freeBasicExpression As String, _
    parameterNames() As String, freeParameterNames() As String, _
    ByVal parameterCount As Long, ByVal integerDivisionAssumed As Long, _
    ByVal depth As Long, ByVal dynamicIntegerDivision As Long _
) As Long
    sourceExpression = Trim(sourceExpression)
    If Left(sourceExpression, 1) <> "(" Then Return 0

    Dim typeEnd As Long = 1
    If ScanSimpleExpressionGroup( _
        sourceExpression, typeEnd, Asc("("), Asc(")")) = 0 Then Return 0
    Dim sourceType As String = Trim(Mid(sourceExpression, 2, typeEnd - 3))
    Dim sourceOperand As String = Trim(Mid(sourceExpression, typeEnd))
    If sourceType = "void" AndAlso _
       GenericNullPointerConstantText(sourceOperand) <> 0 Then
        ' A C void cast discards its zero operand. A BASIC zero is a valid
        ' no-op replacement in both statement and constant contexts.
        freeBasicExpression = "0"
        Return 2
    End If
    Dim freeBasicType As String
    Dim isPointerCast As Long
    If GenericHeaderMacroCastType( _
        translation, sourceType, _
        freeBasicType, isPointerCast) = 0 AndAlso _
       GenericMacroCastTypeFromParameter( _
        Mid(sourceExpression, 2, typeEnd - 3), parameterNames(), _
        freeParameterNames(), parameterCount, freeBasicType, isPointerCast) = 0 Then _
        Return 0

    Dim operand As String = sourceOperand
    ' Parentheses make the extent of a compound C cast operand unambiguous.
    If GenericMacroCastOperandIsComplete(translation, operand) = 0 Then Return 1
    Dim freeBasicOperand As String
    Dim operandWasResolved As Long = 0
    If isPointerCast <> 0 Then
        Dim pointerOperand As String = GenericMacroStripOuterParentheses(operand)
        For parameterIndex As Long = 0 To parameterCount - 1
            If pointerOperand = parameterNames(parameterIndex) Then
                freeBasicOperand = freeParameterNames(parameterIndex)
                operandWasResolved = -1
                Exit For
            End If
        Next
        If operandWasResolved = 0 AndAlso IsIdentifierToken(pointerOperand) <> 0 Then
            Dim symbolIndex As Long = _
                GenericHeaderSymbolIndexInContext(translation, pointerOperand)
            If symbolIndex >= 0 Then
                With translation.symbolTable.symbols(symbolIndex)
                    If .kind = GENERIC_SYMBOL_FUNCTION OrElse _
                       .kind = GENERIC_SYMBOL_SUB Then
                        freeBasicOperand = "ProcPtr(" & .freeBasicName & ")"
                        operandWasResolved = -1
                    ElseIf .kind = GENERIC_SYMBOL_OBJECT AndAlso _
                       .genericHeader.arrayCount = 0 AndAlso _
                       .genericHeader.unsizedArray = 0 Then
                        freeBasicOperand = .freeBasicName
                        operandWasResolved = -1
                    End If
                End With
            End If
        End If
    End If
    If operandWasResolved = 0 AndAlso _
       GenericIntegerMacroCandidate(operand) <> 0 AndAlso _
       GenericMacroExpressionContainsIdentifier(operand) = 0 AndAlso _
       GenericMacroExpressionContainsTypeCast( _
        translation, operand, parameterNames(), parameterCount) = 0 AndAlso _
       GenericMacroOperandReferencesParameter( _
        operand, parameterNames(), parameterCount) = 0 AndAlso _
       TranslateGenericHeaderIntegerExpression( _
        translation, operand, freeBasicOperand, depth + 1, _
        integerDivisionAssumed, dynamicIntegerDivision) <> 0 Then
        ' The generic macro token walker does not accept every unary integer
        ' form, including a negative literal. Static C casts still need the
        ' operand's C integer-constant-expression semantics.
        operandWasResolved = -1
    End If
    If operandWasResolved = 0 AndAlso _
       depth + 1 < MAX_GENERIC_MACRO_EXPRESSION_DEPTH Then
        ' C headers commonly stack casts, such as (unsigned)(unsigned char)x.
        ' Lower the inner cast before the outer cast so no C type token escapes
        ' into the generated FreeBASIC expression.
        Dim nestedCastExpression As String
        If TryTranslateGenericHeaderMacroCast( _
            translation, operand, nestedCastExpression, parameterNames(), _
            freeParameterNames(), parameterCount, integerDivisionAssumed, _
            depth + 1, dynamicIntegerDivision) = 2 Then
            freeBasicOperand = nestedCastExpression
            operandWasResolved = -1
        End If
    End If
    If operandWasResolved = 0 AndAlso _
       TranslateGenericHeaderMacroExpressionWithParameters( _
        translation, operand, freeBasicOperand, parameterNames(), _
        freeParameterNames(), parameterCount, integerDivisionAssumed, _
        depth + 1, dynamicIntegerDivision) = 0 Then
        If TranslateGenericDirectCallMacroTokens( _
            translation, operand, parameterNames(), freeParameterNames(), _
            parameterCount, 0, freeBasicOperand) = 0 AndAlso _
           TranslateGenericMacroTokenSequence( _
            translation, operand, parameterNames(), freeParameterNames(), _
            parameterCount, 0, freeBasicOperand) = 0 Then Return 1
    End If
    If isPointerCast <> 0 Then
        freeBasicExpression = "CPtr(" & freeBasicType & ", " & _
            freeBasicOperand & ")"
    ElseIf GenericMacroCastTargetIsInteger( _
        translation, freeBasicType) <> 0 AndAlso _
       GenericIntegerMacroCastFloatLiteralCandidate(sourceExpression) <> 0 Then
        freeBasicExpression = "Cast(" & freeBasicType & ", Fix(" & _
            freeBasicOperand & "))"
    ElseIf GenericMacroCastTargetIsInteger( _
        translation, freeBasicType) <> 0 AndAlso _
       GenericMacroOperandReferencesParameter( _
        operand, parameterNames(), parameterCount) <> 0 Then
        Dim helperName As String = GenericHeaderIntegerCastHelperNameInContext( _
            translation, freeBasicType)
        freeBasicExpression = helperName & "(" & freeBasicOperand & ")"
    Else
        freeBasicExpression = "Cast(" & freeBasicType & ", " & _
            freeBasicOperand & ")"
    End If
    Return 2
End Function

Private Function GenericMacroTokenStringLiteral( _
    ByVal sourceToken As String, ByRef freeBasicToken As String _
) As Long
    Dim quotePosition As Long = 1
    Dim isWide As Long = 0
    If Left(sourceToken, 2) = "u8" AndAlso _
       (Mid(sourceToken, 3, 1) = Chr(34) OrElse Mid(sourceToken, 3, 1) = "'") Then
        quotePosition = 3
    ElseIf (Left(sourceToken, 1) = "L" OrElse Left(sourceToken, 1) = "u" OrElse _
            Left(sourceToken, 1) = "U") AndAlso _
           (Mid(sourceToken, 2, 1) = Chr(34) OrElse Mid(sourceToken, 2, 1) = "'") Then
        quotePosition = 2
        isWide = -1
    End If
    If quotePosition > Len(sourceToken) Then Return 0
    Dim quoteByte As Long = Asc(sourceToken, quotePosition)

    If quoteByte = Asc("'") Then
        Dim characterPosition As Long = quotePosition
        Dim characterValue As Long
        If DecodeCCharacterConstant( _
            sourceToken, characterPosition, characterValue) = 0 OrElse _
           characterPosition <= Len(sourceToken) Then Return 0
        Dim stringToken As String = Chr(34) & _
            Mid(sourceToken, quotePosition + 1, _
                Len(sourceToken) - quotePosition - 1) & Chr(34)
        Dim stringExpression As String
        If TranslateGenericHeaderStringMacro( _
            stringToken, stringExpression) = 0 Then Return 0
        Dim stringLiteral As String
        If Left(stringExpression, 7) <> "StrPtr(" OrElse _
           Right(stringExpression, 1) <> ")" Then Return 0
        stringLiteral = Mid(stringExpression, 8, Len(stringExpression) - 8)
        If isWide <> 0 Then
            freeBasicToken = "Asc(WStr(" & stringLiteral & "))"
        Else
            freeBasicToken = "Asc(" & stringLiteral & ")"
        End If
        Return -1
    End If

    If quoteByte <> Asc(Chr(34)) Then Return 0
    Dim literalText As String = Mid(sourceToken, quotePosition)
    Dim stringExpression As String
    If TranslateGenericHeaderStringMacro( _
        literalText, stringExpression) = 0 Then Return 0
    If Left(stringExpression, 7) <> "StrPtr(" OrElse _
       Right(stringExpression, 1) <> ")" Then Return 0
    Dim stringLiteral As String = Mid( _
        stringExpression, 8, Len(stringExpression) - 8)
    If isWide <> 0 Then
        freeBasicToken = "WStr(" & stringLiteral & ")"
    Else
        freeBasicToken = stringLiteral
    End If
    Return -1
End Function

Private Function GenericMacroTokenNumber( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceToken As String, ByRef freeBasicToken As String _
) As Long
    If sourceToken = "" Then Return 0
    Dim firstByte As Long = Asc(sourceToken, 1)
    If (firstByte < Asc("0") OrElse firstByte > Asc("9")) AndAlso _
       (firstByte <> Asc(".") OrElse Len(sourceToken) < 2 OrElse _
        Asc(sourceToken, 2) < Asc("0") OrElse Asc(sourceToken, 2) > Asc("9")) Then _
        Return 0

    Dim lowerSourceToken As String = LCase(sourceToken)
    Dim isHexadecimal As Long = CInt(Left(lowerSourceToken, 2) = "0x")
    If lowerSourceToken = "0x" Then
        ' Preserve the compiler's accepted empty hexadecimal-prefix spelling.
        freeBasicToken = "&h"
        Return -1
    End If
    If lowerSourceToken = "0b" Then
        ' Fbfrog preserves the equivalent binary-prefix spelling as &b.
        freeBasicToken = "&b"
        Return -1
    End If
    Dim isFloatingPoint As Long = CInt(InStr(sourceToken, ".") <> 0)
    If isHexadecimal <> 0 Then
        If InStr(lowerSourceToken, "p") <> 0 Then isFloatingPoint = -1
    ElseIf InStr(lowerSourceToken, "e") <> 0 Then
        isFloatingPoint = -1
    End If
    If isHexadecimal = 0 Then
        Dim numericSuffixByte As Long = Asc(sourceToken, Len(sourceToken))
        If numericSuffixByte = Asc("f") OrElse numericSuffixByte = Asc("F") OrElse _
           numericSuffixByte = Asc("d") OrElse numericSuffixByte = Asc("D") Then _
            isFloatingPoint = -1
    End If

    If isFloatingPoint <> 0 Then
        If isHexadecimal <> 0 Then _
            Return TranslateGenericHexFloatingToken( _
                translation, sourceToken, freeBasicToken)
        Dim floatingText As String = sourceToken
        Dim lastByte As Long = Asc(floatingText, Len(floatingText))
        If lastByte = Asc("f") OrElse lastByte = Asc("F") Then
            floatingText = Left(floatingText, Len(floatingText) - 1) & "!"
        ElseIf lastByte = Asc("d") OrElse lastByte = Asc("D") Then
            floatingText = Left(floatingText, Len(floatingText) - 1) & "#"
        ElseIf lastByte = Asc("l") OrElse lastByte = Asc("L") Then
            Return 0
        End If
        freeBasicToken = floatingText
        Return -1
    End If

    Dim lowerIntegerToken As String = LCase(sourceToken)
    Dim extensionSuffix As String
    If Len(lowerIntegerToken) > 4 AndAlso Right(lowerIntegerToken, 4) = "ui64" Then
        extensionSuffix = "ui64"
    ElseIf Len(lowerIntegerToken) > 4 AndAlso Right(lowerIntegerToken, 4) = "ui32" Then
        extensionSuffix = "ui32"
    ElseIf Len(lowerIntegerToken) > 4 AndAlso Right(lowerIntegerToken, 4) = "ui16" Then
        extensionSuffix = "ui16"
    ElseIf Len(lowerIntegerToken) > 3 AndAlso Right(lowerIntegerToken, 3) = "ui8" Then
        extensionSuffix = "ui8"
    ElseIf Len(lowerIntegerToken) > 3 AndAlso Right(lowerIntegerToken, 3) = "i64" Then
        extensionSuffix = "i64"
    ElseIf Len(lowerIntegerToken) > 3 AndAlso Right(lowerIntegerToken, 3) = "i32" Then
        extensionSuffix = "i32"
    ElseIf Len(lowerIntegerToken) > 3 AndAlso Right(lowerIntegerToken, 3) = "i16" Then
        extensionSuffix = "i16"
    ElseIf Len(lowerIntegerToken) > 2 AndAlso Right(lowerIntegerToken, 2) = "i8" Then
        extensionSuffix = "i8"
    End If
    If extensionSuffix <> "" Then
        Dim sourceDigits As String = Left( _
            sourceToken, Len(sourceToken) - Len(extensionSuffix))
        Dim freeBasicDigits As String
        If GenericMacroTokenNumber( _
            translation, sourceDigits, freeBasicDigits) = 0 Then Return 0
        Select Case extensionSuffix
        Case "i64": freeBasicToken = freeBasicDigits & "ll"
        Case "ui8", "ui16", "ui32": freeBasicToken = freeBasicDigits & "u"
        Case "ui64": freeBasicToken = freeBasicDigits & "ull"
        Case Else: freeBasicToken = freeBasicDigits
        End Select
        Return -1
    End If

    Dim suffixStart As Long = Len(sourceToken) + 1
    While suffixStart > 1
        Dim suffixByte As Long = Asc(sourceToken, suffixStart - 1)
        If suffixByte = Asc("u") OrElse suffixByte = Asc("U") OrElse _
           suffixByte = Asc("l") OrElse suffixByte = Asc("L") Then
            suffixStart -= 1
        Else
            Exit While
        End If
    Wend
    Dim integerSuffix As String = LCase(Mid(sourceToken, suffixStart))
    If integerSuffix = "ul" OrElse integerSuffix = "lu" Then
        Dim literalRadix As Long = 10
        If LCase(Left(sourceToken, 2)) = "0x" Then
            literalRadix = 16
        ElseIf Left(sourceToken, 1) = "0" AndAlso suffixStart > 2 Then
            literalRadix = 8
        End If
        Dim maximumUnsignedLong As ULongInt = _
            Cast(ULongInt, CULng(-1))
        If IntegerLiteralFitsMagnitudeLimit( _
            sourceToken, 1, suffixStart, literalRadix, _
            maximumUnsignedLong) = 0 Then Return 0
        Dim sourceDigits As String = Left(sourceToken, suffixStart - 1)
        Dim freeBasicDigits As String
        If TranslateGenericHeaderIntegerExpression( _
            translation, sourceDigits, freeBasicDigits, 0) = 0 Then Return 0
        freeBasicToken = "Cast(CULong, " & freeBasicDigits & ")"
        Return -1
    End If

    Return TranslateGenericHeaderIntegerExpression( _
        translation, sourceToken, freeBasicToken, 0)
End Function

Private Function GenericMacroTokenIdentifier( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceToken As String, parameterNames() As String, _
    freeParameterNames() As String, ByVal parameterCount As Long, _
    ByVal isVariadic As Long, ByRef freeBasicToken As String _
) As Long
    For parameterIndex As Long = 0 To parameterCount - 1
        If sourceToken = parameterNames(parameterIndex) Then
            freeBasicToken = freeParameterNames(parameterIndex)
            Return -1
        End If
    Next
    If sourceToken = "__VA_ARGS__" AndAlso isVariadic <> 0 AndAlso _
       parameterCount > 0 Then
        freeBasicToken = freeParameterNames(parameterCount - 1)
        Return -1
    End If

    Dim macroIndex As Long = GenericHeaderMacroIndexInContext( _
        translation, sourceToken)
    If macroIndex >= 0 Then
        With translation.genericC.header.headerMacros(macroIndex)
            If .active = 0 OrElse GenericDefineExcludedInPolicy( _
                translation.genericC.policy, sourceToken) <> 0 Then Return 0
            If .tokenConversionFailed <> 0 Then Return 0
            If .privateName <> 0 Then
                If .resolvedValue = "" Then Return 0
                freeBasicToken = "(" & .resolvedValue & ")"
                Return -1
            End If
            If .freeBasicName = "" Then Return 0
            freeBasicToken = .freeBasicName
            Return -1
        End With
    End If

    Dim symbolIndex As Long = _
        GenericHeaderSymbolIndexInContext(translation, sourceToken)
    If symbolIndex >= 0 Then
        freeBasicToken = translation.symbolTable.symbols(symbolIndex).freeBasicName
        Return CInt(freeBasicToken <> "")
    End If
    Dim enumIndex As Long = GenericEnumMemberIndexInContext( _
        translation, sourceToken)
    If enumIndex >= 0 Then
        Return GenericEnumMemberFreeBasicReference( _
            translation, enumIndex, freeBasicToken)
    End If

    Dim typeAliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
        translation.genericC.header, sourceToken, 0)
    If typeAliasIndex < 0 Then _
        typeAliasIndex = GenericHeaderTypeAliasIndexInHeader( _
            translation.genericC.header, sourceToken, -1)
    If typeAliasIndex >= 0 Then
        freeBasicToken = _
            translation.genericC.header.headerTypeAliases(typeAliasIndex).freeBasicName
        If freeBasicToken <> "" Then Return -1
    End If

    freeBasicToken = sourceToken
    Return -1
End Function

Private Function TranslateGenericMacroTokenSequence( _
    ByRef translation As C2fbTranslationContext, ByVal sourceText As String, _
    parameterNames() As String, freeParameterNames() As String, _
    ByVal parameterCount As Long, ByVal isVariadic As Long, _
    ByRef freeBasicExpression As String _
) As Long
    freeBasicExpression = ""
    If Trim(sourceText) = "" Then Return -1
    Dim tokens() As String
    Dim tokenCount As Long = 0
    If TokenizeCPreprocessorReplacement( _
        sourceText, tokens(), tokenCount) = 0 Then Return 0
    Dim previousToken As String
    For tokenIndex As Long = 0 To tokenCount - 1
        Dim sourceToken As String = tokens(tokenIndex)
        Dim freeBasicToken As String
        Dim translated As Long = 0
        If ((Asc(sourceToken, 1) >= Asc("0") AndAlso _
             Asc(sourceToken, 1) <= Asc("9")) OrElse _
            (Left(sourceToken, 1) = "." AndAlso Len(sourceToken) > 1 AndAlso _
             Asc(sourceToken, 2) >= Asc("0") AndAlso _
             Asc(sourceToken, 2) <= Asc("9"))) AndAlso _
           tokenIndex < tokenCount - 1 AndAlso _
           IsIdentifierStart(Asc(tokens(tokenIndex + 1), 1)) <> 0 Then
            Dim combinedNumber As String = sourceToken & tokens(tokenIndex + 1)
            Dim combinedValue As String
            If GenericMacroTokenNumber( _
                translation, combinedNumber, combinedValue) <> 0 Then
                sourceToken = combinedNumber
                freeBasicToken = combinedValue
                translated = -1
                tokenIndex += 1
            End If
        End If
        If translated = 0 Then
        If Left(sourceToken, 1) = Chr(34) OrElse _
           Left(sourceToken, 1) = "'" OrElse _
           (Len(sourceToken) > 1 AndAlso _
            (Left(sourceToken, 1) = "L" OrElse Left(sourceToken, 1) = "u" OrElse _
             Left(sourceToken, 1) = "U") AndAlso _
            (Mid(sourceToken, 2, 1) = Chr(34) OrElse Mid(sourceToken, 2, 1) = "'")) OrElse _
           (Left(sourceToken, 2) = "u8" AndAlso _
            (Mid(sourceToken, 3, 1) = Chr(34) OrElse Mid(sourceToken, 3, 1) = "'")) Then
            translated = GenericMacroTokenStringLiteral(sourceToken, freeBasicToken)
        ElseIf (Asc(sourceToken, 1) >= Asc("0") AndAlso _
                Asc(sourceToken, 1) <= Asc("9")) OrElse _
               (Left(sourceToken, 1) = "." AndAlso Len(sourceToken) > 1 AndAlso _
                Asc(sourceToken, 2) >= Asc("0") AndAlso _
                Asc(sourceToken, 2) <= Asc("9")) Then
            translated = GenericMacroTokenNumber( _
                translation, sourceToken, freeBasicToken)
        ElseIf IsIdentifierStart(Asc(sourceToken, 1)) <> 0 Then
            translated = GenericMacroTokenIdentifier( _
                translation, sourceToken, parameterNames(), freeParameterNames(), _
                parameterCount, isVariadic, freeBasicToken)
        Else
            Select Case sourceToken
            Case "==": freeBasicToken = "=": translated = -1
            Case "!=": freeBasicToken = "<>": translated = -1
            Case "%": freeBasicToken = "Mod": translated = -1
            Case "%=": freeBasicToken = "Mod=": translated = -1
            Case "&"
                If GenericMacroAddressOfOperator(tokens(), tokenIndex) <> 0 Then
                    freeBasicToken = "@"
                Else
                    freeBasicToken = "And"
                End If
                translated = -1
            Case "&=": freeBasicToken = "And=": translated = -1
            Case "&&": freeBasicToken = "AndAlso": translated = -1
            Case "||": freeBasicToken = "OrElse": translated = -1
            Case "|": freeBasicToken = "Or": translated = -1
            Case "|=": freeBasicToken = "Or=": translated = -1
            Case "^": freeBasicToken = "Xor": translated = -1
            Case "^=": freeBasicToken = "Xor=": translated = -1
            Case "<<": freeBasicToken = "Shl": translated = -1
            Case "<<=": freeBasicToken = "Shl=": translated = -1
            Case ">>": freeBasicToken = "Shr": translated = -1
            Case ">>=": freeBasicToken = "Shr=": translated = -1
            Case "[": freeBasicToken = "(": translated = -1
            Case "]": freeBasicToken = ")": translated = -1
            Case "~", "!": freeBasicToken = "Not": translated = -1
            Case Else: freeBasicToken = sourceToken: translated = -1
            End Select
        End If
        End If
        If translated = 0 Then Return 0
        If GenericMacroTokenNeedsSpace(previousToken, freeBasicToken) <> 0 Then _
            freeBasicExpression &= " "
        freeBasicExpression &= freeBasicToken
        previousToken = freeBasicToken
    Next
    Return CInt(freeBasicExpression <> "")
End Function

Private Function NormalizeGenericMacroDirectCall( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceBody As String, ByRef normalizedBody As String, _
    ByRef calleeName As String, ByRef argumentText As String _
) As Long
    normalizedBody = ""
    calleeName = ""
    argumentText = ""
    sourceBody = GenericMacroStripOuterParentheses(Trim(sourceBody))
    If sourceBody = "" Then Return 0

    Dim position As Long = 1
    While position <= Len(sourceBody) AndAlso _
          IsSpaceByte(Asc(sourceBody, position)) <> 0
        position += 1
    Wend
    If position > Len(sourceBody) Then Return 0

    If Asc(sourceBody, position) = Asc("(") Then
        Dim calleeGroupEnd As Long = position
        If ScanSimpleExpressionGroup( _
            sourceBody, calleeGroupEnd, Asc("("), Asc(")")) = 0 Then Return 0
        calleeName = GenericMacroStripOuterParentheses(Trim(Mid( _
            sourceBody, position + 1, calleeGroupEnd - position - 2)))
        If IsIdentifierToken(calleeName) = 0 Then Return 0
        If GenericHeaderTypeAliasIndexInHeader( _
            translation.genericC.header, calleeName, 0) >= 0 OrElse _
           GenericHeaderTypeAliasIndexInHeader( _
            translation.genericC.header, calleeName, -1) >= 0 Then Return 0
        Select Case LCase(calleeName)
        Case "void", "char", "signed", "unsigned", "short", "int", "long", _
             "float", "double", "_bool", "bool", "typeof", "__typeof__", _
             "wchar_t", "size_t", "ssize_t", "ptrdiff_t", "intptr_t", "uintptr_t", _
             "int8_t", "uint8_t", "int16_t", "uint16_t", "int32_t", "uint32_t", _
             "int64_t", "uint64_t", "__int8", "__int16", "__int32", "__int64"
            Return 0
        End Select
        position = calleeGroupEnd
    Else
        If IsIdentifierStart(Asc(sourceBody, position)) = 0 Then Return 0
        Dim nameStart As Long = position
        position += 1
        While position <= Len(sourceBody) AndAlso _
              IsIdentifierPart(Asc(sourceBody, position)) <> 0
            position += 1
        Wend
        calleeName = Mid(sourceBody, nameStart, position - nameStart)
    End If

    While position <= Len(sourceBody) AndAlso _
          IsSpaceByte(Asc(sourceBody, position)) <> 0
        position += 1
    Wend
    If position > Len(sourceBody) OrElse _
       Asc(sourceBody, position) <> Asc("(") Then Return 0

    Dim argumentGroupEnd As Long = position
    If ScanSimpleExpressionGroup( _
        sourceBody, argumentGroupEnd, Asc("("), Asc(")")) = 0 OrElse _
       Trim(Mid(sourceBody, argumentGroupEnd)) <> "" Then Return 0
    argumentText = Mid(sourceBody, position + 1, _
        argumentGroupEnd - position - 2)
    normalizedBody = calleeName & Mid(sourceBody, position)
    Return -1
End Function

Private Function TranslateGenericDirectCallMacroTokens( _
    ByRef translation As C2fbTranslationContext, ByVal sourceBody As String, _
    parameterNames() As String, freeParameterNames() As String, _
    ByVal parameterCount As Long, ByVal isVariadic As Long, _
    ByRef freeBasicExpression As String _
) As Long
    Dim normalizedBody As String
    Dim calleeName As String
    Dim argumentText As String
    If NormalizeGenericMacroDirectCall( _
        translation, sourceBody, normalizedBody, calleeName, argumentText) = 0 Then Return 0

    If LCase(calleeName) = "defined" AndAlso parameterCount = 0 AndAlso _
       IsIdentifierToken(argumentText) <> 0 Then
        Dim macroName As String = argumentText
        Dim macroIndex As Long = GenericHeaderMacroIndexInContext( _
            translation, argumentText)
        If macroIndex >= 0 Then
            With translation.genericC.header.headerMacros(macroIndex)
                If .active <> 0 AndAlso .freeBasicName <> "" AndAlso _
                   .privateName = 0 Then macroName = .freeBasicName
            End With
        End If
        freeBasicExpression = "defined(" & macroName & ")"
        Return -1
    End If

    Dim freeBasicCallee As String
    If GenericMacroTokenIdentifier( _
        translation, calleeName, parameterNames(), freeParameterNames(), _
        parameterCount, isVariadic, freeBasicCallee) = 0 Then Return 0
    Dim arguments() As String
    Dim argumentCount As Long = 0
    If argumentText <> "" AndAlso _
       SplitSimpleCList(argumentText, arguments(), argumentCount) = 0 Then Return 0
    Dim translatedArguments As String
    For argumentIndex As Long = 0 To argumentCount - 1
        Dim freeBasicArgument As String
        If TranslateGenericFunctionCallMacroArgument( _
            translation, arguments(argumentIndex), parameterNames(), _
            freeParameterNames(), parameterCount, isVariadic, _
            freeBasicArgument) = 0 Then Return 0
        If argumentIndex > 0 Then translatedArguments &= ", "
        translatedArguments &= freeBasicArgument
    Next
    freeBasicExpression = freeBasicCallee & "(" & translatedArguments & ")"
    Return -1
End Function

Private Function TranslateGenericBraceInitializerMacro( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceBody As String, parameterNames() As String, _
    freeParameterNames() As String, ByVal parameterCount As Long, _
    ByVal isVariadic As Long, ByRef freeBasicExpression As String _
) As Long
    sourceBody = Trim(sourceBody)
    If Left(sourceBody, 1) <> "{" Then Return 0
    Dim blockEnd As Long = 1
    If ScanSimpleExpressionGroup( _
        sourceBody, blockEnd, Asc("{"), Asc("}")) = 0 Then Return -1
    If Trim(Mid(sourceBody, blockEnd)) <> "" Then Return 0

    Dim initializerText As String = Trim(Mid( _
        sourceBody, 2, blockEnd - 3))
    If initializerText = "" Then
        freeBasicExpression = "()"
        Return 1
    End If
    Dim firstWordEnd As Long = 1
    While firstWordEnd <= Len(initializerText) AndAlso _
          IsIdentifierPart(Asc(initializerText, firstWordEnd)) <> 0
        firstWordEnd += 1
    Wend
    Dim firstWord As String = LCase(Left(initializerText, firstWordEnd - 1))
    Select Case firstWord
    Case "if", "do", "while", "for", "switch", "return", "break", "continue"
        Return 0
    End Select
    If InStr(initializerText, ";") <> 0 Then Return 0
    If Right(initializerText, 1) = "," Then _
        initializerText = Trim(Left(initializerText, Len(initializerText) - 1))
    If initializerText = "" Then Return -1

    Dim elements() As String
    Dim elementCount As Long = 0
    If SplitSimpleCList( _
        initializerText, elements(), elementCount) = 0 OrElse elementCount = 0 Then _
        Return -1
    Dim translatedElements As String
    For elementIndex As Long = 0 To elementCount - 1
        Dim translatedElement As String
        If TranslateGenericFunctionCallMacroArgument( _
            translation, elements(elementIndex), parameterNames(), _
            freeParameterNames(), parameterCount, isVariadic, _
            translatedElement) = 0 Then Return -1
        If elementIndex > 0 Then translatedElements &= ", "
        translatedElements &= translatedElement
    Next
    freeBasicExpression = "(" & translatedElements & ")"
    Return 1
End Function

Declare Sub GenericMacroOuterTokenRange( _
    tokens() As String, ByVal tokenCount As Long, _
    ByRef firstToken As Long, ByRef lastToken As Long _
)

Private Function GenericHeaderAliasMacroName( _
    ByRef macro As C2fbMacroDefinitionModel _
) As String
    If macro.tokenCount = 0 Then Return ""
    Dim firstToken As Long
    Dim lastToken As Long
    GenericMacroOuterTokenRange( _
        macro.tokens(), macro.tokenCount, firstToken, lastToken)
    If firstToken = lastToken AndAlso _
       IsIdentifierToken(macro.tokens(firstToken)) <> 0 Then _
        Return macro.tokens(firstToken)
    Return ""
End Function

Private Function TranslateGenericHeaderSizeofMacroExpression( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, parameterNames() As String, _
    freeParameterNames() As String, ByVal parameterCount As Long, _
    ByVal isVariadic As Long, ByVal integerDivisionAssumed As Long, _
    ByVal depth As Long, ByRef freeBasicExpression As String _
) As Long
    sourceExpression = GenericMacroStripOuterParentheses(Trim(sourceExpression))
    If Len(sourceExpression) < 7 OrElse LCase(Left(sourceExpression, 6)) <> "sizeof" OrElse _
       IsIdentifierPart(Asc(sourceExpression, 7)) <> 0 Then Return 0

    Dim groupOpen As Long = 7
    While groupOpen <= Len(sourceExpression) AndAlso _
          IsSpaceByte(Asc(sourceExpression, groupOpen)) <> 0
        groupOpen += 1
    Wend
    If groupOpen > Len(sourceExpression) OrElse _
       Asc(sourceExpression, groupOpen) <> Asc("(") Then Return 0
    Dim groupClose As Long = groupOpen
    If ScanSimpleExpressionGroup( _
        sourceExpression, groupClose, Asc("("), Asc(")")) = 0 OrElse _
       Trim(Mid(sourceExpression, groupClose)) <> "" Then Return 0

    Dim operand As String = Trim(Mid( _
        sourceExpression, groupOpen + 1, groupClose - groupOpen - 2))
    If operand = "" Then Return 0

    ' Module-static aggregate fields commonly use sizeof on a typedef, such
    ' as the record aliases declared by the same source header. Resolve that
    ' name directly before the expression parser treats it as a variable.
    Dim operandTokens() As String
    Dim operandTokenCount As Long
    TokenizeCDeclaration(operand, operandTokens(), operandTokenCount)
    If operandTokenCount = 1 AndAlso _
       IsIdentifierToken(operandTokens(0)) <> 0 Then
        Dim aliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
            translation.genericC.header, operandTokens(0), 0)
        If aliasIndex >= 0 Then
            Dim aliasType As String = _
                translation.genericC.header.headerTypeAliases(aliasIndex).freeBasicName
            If aliasType <> "" Then
                freeBasicExpression = "SizeOf(" & aliasType & ")"
                Return -1
            End If
        End If
    End If

    Dim freeBasicType As String
    Dim isPointerCast As Long
    If GenericHeaderMacroCastType( _
        translation, operand, freeBasicType, isPointerCast) <> 0 Then
        freeBasicExpression = "SizeOf(" & freeBasicType & ")"
        Return -1
    End If

    Dim sizeTypeTokens() As String
    Dim sizeTypeTokenCount As Long
    TokenizeCDeclaration(operand, sizeTypeTokens(), sizeTypeTokenCount)
    Dim sizeType As C2fbCTypeModel
    If sizeTypeTokenCount > 0 AndAlso _
       ParseCTypeModel(sizeTypeTokens(), 0, sizeTypeTokenCount - 1, sizeType) <> 0 AndAlso _
       sizeType.hasUnsupportedSyntax = 0 AndAlso sizeType.pointerDepth = 0 AndAlso _
       (sizeType.isStruct <> 0 OrElse sizeType.isUnion <> 0) Then
        Dim tagIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
            translation.genericC.header, sizeType.baseName, -1)
        Dim recordTypeName As String = GenericHeaderTagAliasNameInHeader( _
            translation.genericC.header, sizeType.baseName)
        If tagIndex >= 0 AndAlso recordTypeName <> "" AndAlso _
           translation.genericC.header.headerTypeAliases(tagIndex).isForward = 0 Then
            freeBasicExpression = "SizeOf(" & recordTypeName & ")"
            Return -1
        End If
        recordTypeName = GenericTypeOverrideInPolicy( _
            translation.genericC.policy, sizeType.baseName)
        If recordTypeName <> "" Then
            freeBasicExpression = "SizeOf(" & recordTypeName & ")"
            Return -1
        End If
    End If

    Dim freeBasicOperand As String
    If TranslateGenericHeaderMacroExpressionWithParameters( _
        translation, operand, freeBasicOperand, parameterNames(), _
        freeParameterNames(), parameterCount, integerDivisionAssumed, _
        depth + 1) = 0 Then Return 0
    freeBasicExpression = "SizeOf(" & freeBasicOperand & ")"
    Return -1
End Function

Private Function NormalizeGenericHeaderMacroSizeofExpressions( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, parameterNames() As String, _
    freeParameterNames() As String, ByVal parameterCount As Long, _
    ByVal integerDivisionAssumed As Long, ByVal depth As Long, _
    ByRef normalizedExpression As String _
) As Long
    normalizedExpression = ""
    Dim topLevelExpression As String = _
        GenericMacroStripOuterParentheses(Trim(sourceExpression))
    If Len(topLevelExpression) >= 7 AndAlso _
       LCase(Left(topLevelExpression, 6)) = "sizeof" AndAlso _
       IsIdentifierPart(Asc(topLevelExpression, 7)) = 0 Then
        Dim groupOpen As Long = 7
        While groupOpen <= Len(topLevelExpression) AndAlso _
              IsSpaceByte(Asc(topLevelExpression, groupOpen)) <> 0
            groupOpen += 1
        Wend
        If groupOpen <= Len(topLevelExpression) AndAlso _
           Asc(topLevelExpression, groupOpen) = Asc("(") Then
            Dim groupClose As Long = groupOpen
            If ScanSimpleExpressionGroup( _
                topLevelExpression, groupClose, Asc("("), Asc(")")) <> 0 AndAlso _
               Trim(Mid(topLevelExpression, groupClose)) = "" Then
                ' The caller translates a top-level sizeof with its existing
                ' type-context path, including function-pointer typedefs.
                normalizedExpression = sourceExpression
                Return -1
            End If
        End If
    End If

    Dim position As Long = 1
    While position <= Len(sourceExpression)
        Dim currentByte As Long = Asc(sourceExpression, position)
        If currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
            Dim quoteByte As Long = currentByte
            Dim literalStart As Long = position
            position += 1
            While position <= Len(sourceExpression)
                currentByte = Asc(sourceExpression, position)
                If currentByte = Asc("\") Then
                    position += 2
                    Continue While
                End If
                position += 1
                If currentByte = quoteByte Then Exit While
            Wend
            normalizedExpression &= Mid( _
                sourceExpression, literalStart, position - literalStart)
            Continue While
        End If

        If IsIdentifierStart(currentByte) <> 0 Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(sourceExpression) AndAlso _
                  IsIdentifierPart(Asc(sourceExpression, position)) <> 0
                position += 1
            Wend
            Dim tokenText As String = Mid( _
                sourceExpression, tokenStart, position - tokenStart)
            If LCase(tokenText) = "sizeof" Then
                Dim groupOpen As Long = position
                While groupOpen <= Len(sourceExpression) AndAlso _
                      IsSpaceByte(Asc(sourceExpression, groupOpen)) <> 0
                    groupOpen += 1
                Wend
                If groupOpen <= Len(sourceExpression) AndAlso _
                   Asc(sourceExpression, groupOpen) = Asc("(") Then
                    Dim groupClose As Long = groupOpen
                    If ScanSimpleExpressionGroup( _
                        sourceExpression, groupClose, Asc("("), Asc(")")) = 0 Then _
                        Return 0
                    Dim sizeofExpression As String = Mid( _
                        sourceExpression, tokenStart, groupClose - tokenStart)
                    Dim freeBasicSizeof As String
                    If TranslateGenericHeaderSizeofMacroExpression( _
                        translation, sizeofExpression, parameterNames(), _
                        freeParameterNames(), parameterCount, 0, _
                        integerDivisionAssumed, depth, freeBasicSizeof) = 0 Then _
                        Return 0
                    normalizedExpression &= freeBasicSizeof
                    position = groupClose
                    Continue While
                End If
            End If
            normalizedExpression &= tokenText
            Continue While
        End If

        normalizedExpression &= Chr(currentByte)
        position += 1
    Wend
    Return -1
End Function

Private Function TranslateGenericHeaderMacroExpressionWithParameters( _
    ByRef translation As C2fbTranslationContext, _
    ByVal rawValue As String, ByRef freeBasicExpression As String, _
    parameterNames() As String, freeParameterNames() As String, _
    ByVal parameterCount As Long, _
    ByVal integerDivisionAssumed As Long = 0, _
    ByVal depth As Long = 0, _
    ByVal dynamicIntegerDivision As Long = 0 _
) As Long
    If depth >= MAX_GENERIC_MACRO_EXPRESSION_DEPTH Then Return 0
    Dim stringCastExpression As String = GenericMacroStripOuterParentheses(rawValue)
    If TryTranslateGenericHeaderStringPointerCast( _
        translation, stringCastExpression, freeBasicExpression) <> 0 Then Return -1
    Dim normalizedValue As String
    If RewriteGenericMacroCharacterConstants(rawValue, normalizedValue) = 0 Then Return 0
    Dim normalizedSizeofValue As String
    If NormalizeGenericHeaderMacroSizeofExpressions( _
        translation, normalizedValue, parameterNames(), freeParameterNames(), _
        parameterCount, integerDivisionAssumed, depth, _
        normalizedSizeofValue) = 0 Then Return 0
    normalizedValue = normalizedSizeofValue
    Dim castExpression As String = GenericMacroStripOuterParentheses(normalizedValue)
    If TranslateGenericHeaderSizeofMacroExpression( _
        translation, castExpression, parameterNames(), freeParameterNames(), _
        parameterCount, 0, integerDivisionAssumed, depth, _
        freeBasicExpression) <> 0 Then Return -1
    Dim singleToken() As String
    Dim singleTokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        castExpression, singleToken(), singleTokenCount) <> 0 AndAlso _
       singleTokenCount = 1 Then
        Dim firstByte As Long = Asc(singleToken(0), 1)
        If (firstByte >= Asc("0") AndAlso firstByte <= Asc("9")) OrElse _
           (firstByte = Asc(".") AndAlso Len(singleToken(0)) > 1 AndAlso _
            Asc(singleToken(0), 2) >= Asc("0") AndAlso _
            Asc(singleToken(0), 2) <= Asc("9")) Then
            If GenericMacroTokenNumber( _
                translation, singleToken(0), freeBasicExpression) <> 0 Then _
                Return -1
        End If
    End If
    If TryTranslateGenericHeaderStringPointerCast( _
        translation, castExpression, freeBasicExpression) <> 0 Then Return -1
    Dim castStatus As Long = TryTranslateGenericHeaderMacroCast( _
        translation, castExpression, freeBasicExpression, parameterNames(), _
        freeParameterNames(), parameterCount, integerDivisionAssumed, depth, _
        dynamicIntegerDivision)
    If castStatus = 2 Then Return -1
    If TryTranslateGenericNullPointerComparison( _
        translation, castExpression, freeBasicExpression) <> 0 Then Return -1
    Dim castBinaryStatus As Long = _
        TranslateGenericHeaderMacroCastBinaryExpression( _
            translation, castExpression, freeBasicExpression, _
            parameterNames(), freeParameterNames(), parameterCount, _
            integerDivisionAssumed, depth, dynamicIntegerDivision)
    If castBinaryStatus < 0 Then Return -1
    If castBinaryStatus <> 0 OrElse castStatus <> 0 Then Return 0
    Dim unsignedExpressionStatus As Long = _
        GenericUnsignedIntMacroExpressionStatus(castExpression)
    If unsignedExpressionStatus < 0 Then Return 0
    rawValue = normalizedValue
    Dim rewritten As String
    Dim position As Long = 1
    While position <= Len(rawValue)
        Dim currentByte As Long = Asc(rawValue, position)
        If IsIdentifierStart(currentByte) <> 0 Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(rawValue) AndAlso _
                  IsIdentifierPart(Asc(rawValue, position)) <> 0
                position += 1
            Wend
            Dim sourceName As String = Mid(rawValue, tokenStart, position - tokenStart)
            Dim parameterIndex As Long = -1
            For candidateIndex As Long = 0 To parameterCount - 1
                If parameterNames(candidateIndex) = sourceName Then
                    parameterIndex = candidateIndex
                    Exit For
                End If
            Next
            If parameterIndex >= 0 Then
                rewritten &= freeParameterNames(parameterIndex)
            Else
                Dim macroIndex As Long = _
                    GenericHeaderMacroIndexInContext(translation, sourceName)
                If macroIndex >= 0 Then
                    If GenericDefineExcludedInPolicy(translation.genericC.policy, sourceName) <> 0 OrElse _
                       translation.genericC.header.headerMacros(macroIndex).active = 0 OrElse _
                       translation.genericC.header.headerMacros(macroIndex).definition.functionLike <> 0 OrElse _
                       translation.genericC.header.headerMacros(macroIndex).emitted = 0 Then Return 0
                    If translation.genericC.header.headerMacros(macroIndex).privateName <> 0 Then
                        If translation.genericC.header.headerMacros(macroIndex).resolvedValue = "" Then Return 0
                        rewritten &= "(" & translation.genericC.header.headerMacros(macroIndex).resolvedValue & ")"
                    Else
                        rewritten &= translation.genericC.header.headerMacros(macroIndex).freeBasicName
                    End If
                Else
                    Dim enumIndex As Long = _
                        GenericEnumMemberIndexInContext(translation, sourceName)
                    If enumIndex < 0 Then Return 0
                    Dim enumReference As String
                    If GenericEnumMemberFreeBasicReference( _
                        translation, enumIndex, enumReference) = 0 Then Return 0
                    rewritten &= enumReference
                End If
            End If
        ElseIf currentByte >= Asc("0") AndAlso currentByte <= Asc("9") Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(rawValue) AndAlso _
                  IsIdentifierPart(Asc(rawValue, position)) <> 0
                position += 1
            Wend
            rewritten &= Mid(rawValue, tokenStart, position - tokenStart)
        Else
            rewritten &= Chr(currentByte)
            position += 1
        End If
    Wend
    If TranslateGenericHeaderIntegerExpression( _
        translation, rewritten, freeBasicExpression, 0, _
        integerDivisionAssumed, dynamicIntegerDivision) = 0 Then Return 0
    If unsignedExpressionStatus > 0 Then _
        freeBasicExpression = "CULng(" & freeBasicExpression & ")"
    Return -1
End Function

Private Function TranslateGenericHeaderMacroExpression( _
    ByRef translation As C2fbTranslationContext, _
    ByVal rawValue As String, ByRef freeBasicExpression As String, _
    ByVal integerDivisionAssumed As Long = 0 _
) As Long
    Dim parameterNames(0 To 0) As String
    Dim freeParameterNames(0 To 0) As String
    Return TranslateGenericHeaderMacroExpressionWithParameters( _
        translation, rawValue, freeBasicExpression, _
        parameterNames(), freeParameterNames(), 0, integerDivisionAssumed)
End Function

Private Function ParseGenericFunctionMacro( _
    ByRef macro As C2fbMacroDefinitionModel, parameterNames() As String, _
    freeParameterNames() As String, ByRef parameterCount As Long, _
    ByRef isVariadic As Long, ByRef body As String _
) As Long
    ReDim parameterNames(0 To MAX_TYPE_WORDS - 1)
    ReDim freeParameterNames(0 To MAX_TYPE_WORDS - 1)
    parameterCount = 0
    isVariadic = 0
    body = ""
    Dim rawDefinition As String = Trim(macro.rawValue)

    Dim groupPosition As Long = 1
    If ScanSimpleExpressionGroup( _
        rawDefinition, groupPosition, Asc("("), Asc(")")) = 0 Then Return 0
    body = Trim(Mid(rawDefinition, groupPosition))
    If macro.tokenCount < 2 OrElse macro.tokens(0) <> "(" Then Return 0

    Dim tokenDepth As Long = 0
    Dim closeToken As Long = -1
    For tokenIndex As Long = 0 To macro.tokenCount - 1
        If macro.tokens(tokenIndex) = "(" Then
            tokenDepth += 1
        ElseIf macro.tokens(tokenIndex) = ")" Then
            tokenDepth -= 1
            If tokenDepth < 0 Then Return 0
            If tokenDepth = 0 Then
                closeToken = tokenIndex
                Exit For
            End If
        End If
    Next
    If closeToken < 0 Then Return 0
    If closeToken = 1 Then Return -1

    Dim parameterRanges() As C2fbTokenRangeModel
    Dim parameterRangeCount As Long
    If SplitC2fbTokenList( _
        macro.tokens(), 1, closeToken - 1, parameterRanges(), _
        parameterRangeCount) = 0 Then Return 0
    For rangeIndex As Long = 0 To parameterRangeCount - 1
        Dim firstToken As Long = parameterRanges(rangeIndex).firstToken
        Dim lastToken As Long = parameterRanges(rangeIndex).lastToken
        If firstToken > lastToken Then Return 0
        If lastToken = firstToken + 1 AndAlso _
           macro.tokens(lastToken) = "..." Then
            If rangeIndex <> parameterRangeCount - 1 OrElse _
               IsIdentifierToken(macro.tokens(firstToken)) = 0 OrElse _
               parameterCount >= MAX_TYPE_WORDS Then Return 0
            For priorIndex As Long = 0 To parameterCount - 1
                If parameterNames(priorIndex) = macro.tokens(firstToken) Then _
                    Return 0
            Next
            parameterNames(parameterCount) = macro.tokens(firstToken)
            freeParameterNames(parameterCount) = _
                "c2fb_macro_arg_" & Trim(Str(parameterCount))
            parameterCount += 1
            isVariadic = -1
            Continue For
        End If
        If firstToken = lastToken AndAlso macro.tokens(firstToken) = "..." Then
            If rangeIndex <> parameterRangeCount - 1 Then Return 0
            For priorIndex As Long = 0 To parameterCount - 1
                If parameterNames(priorIndex) = "__VA_ARGS__" Then Return 0
            Next
            If parameterCount >= MAX_TYPE_WORDS Then Return 0
            parameterNames(parameterCount) = "__VA_ARGS__"
            freeParameterNames(parameterCount) = "c2fb_macro_args"
            parameterCount += 1
            isVariadic = -1
            Continue For
        End If
        If firstToken <> lastToken OrElse _
           IsIdentifierToken(macro.tokens(firstToken)) = 0 Then Return 0
        For priorIndex As Long = 0 To parameterCount - 1
            If parameterNames(priorIndex) = macro.tokens(firstToken) Then Return 0
        Next
        If parameterCount >= MAX_TYPE_WORDS Then Return 0
        parameterNames(parameterCount) = macro.tokens(firstToken)
        freeParameterNames(parameterCount) = _
            "c2fb_macro_arg_" & Trim(Str(parameterCount))
        parameterCount += 1
    Next
    Return -1
End Function

Private Function GenericHeaderRecordTypeFromMemberBase( _
    ByVal freeBasicType As String, ByVal usesPointer As Long _
) As String
    freeBasicType = Trim(freeBasicType)
    If Left(freeBasicType, 6) = "Const " Then _
        freeBasicType = Trim(Mid(freeBasicType, 7))
    If usesPointer <> 0 Then
        If Right(freeBasicType, 4) <> " Ptr" Then Return ""
        freeBasicType = Trim(Left(freeBasicType, Len(freeBasicType) - 4))
    ElseIf Right(freeBasicType, 4) = " Ptr" Then
        Return ""
    End If
    If freeBasicType = "" OrElse InStr(freeBasicType, " Ptr") <> 0 Then Return ""
    Return freeBasicType
End Function

Private Function GenericHeaderRecordFieldNameInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal freeBasicRecordType As String, ByVal sourceFieldName As String, _
    ByRef freeBasicFieldName As String _
) As Long
    freeBasicFieldName = ""
    Dim foundField As Long = 0
    For declarationIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
        If translation.sourceUnit.declarations(declarationIndex).entryKind <> _
           C2FB_DECLARATION_RECORD Then Continue For
        If declarationIndex > UBound(translation.genericC.header.recordPlans) Then Return 0
        With translation.genericC.header.recordPlans(declarationIndex)
            If .isSupported = 0 OrElse .bindingReady = 0 OrElse _
               (.freeBasicName <> freeBasicRecordType AndAlso _
                .aliasFreeBasicName <> freeBasicRecordType AndAlso _
                .implementationName <> freeBasicRecordType AndAlso _
                .binding.freeBasicName <> freeBasicRecordType) Then Continue For
            For itemIndex As Long = 0 To .binding.itemCount - 1
                With .binding.items(itemIndex)
                    Dim boundSourceName As String = .sourceName
                    If boundSourceName = "" Then boundSourceName = .name
                    If .kind <> C2FB_RECORD_BINDING_ITEM_FIELD OrElse _
                       boundSourceName <> sourceFieldName Then Continue For
                    If .arrayCount <> 0 OrElse .zeroArrayAccessorName <> "" Then Return 0
                    If foundField <> 0 Then Return 0
                    freeBasicFieldName = .name
                    foundField = -1
                End With
            Next
        End With
    Next
    Return foundField
End Function

Private Function TranslateGenericMemberAccessMacroArgument( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceArgument As String, ByRef freeBasicArgument As String _
) As Long
    Dim tokens() As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        sourceArgument, tokens(), tokenCount) = 0 OrElse tokenCount <> 3 Then Return 0
    If IsIdentifierToken(tokens(0)) = 0 OrElse _
       IsIdentifierToken(tokens(2)) = 0 OrElse _
       (tokens(1) <> "->" AndAlso tokens(1) <> ".") Then Return 0

    Dim symbolIndex As Long = _
        GenericHeaderSymbolIndexInContext(translation, tokens(0))
    If symbolIndex < 0 Then Return 0
    With translation.symbolTable.symbols(symbolIndex)
        If .kind <> GENERIC_SYMBOL_OBJECT OrElse _
           .genericHeader.arrayCount <> 0 OrElse _
           .genericHeader.unsizedArray <> 0 Then Return 0
        Dim usesPointer As Long = CInt(tokens(1) = "->")
        Dim freeBasicRecordType As String = GenericHeaderRecordTypeFromMemberBase( _
            .genericHeader.freeBasicType, usesPointer)
        If freeBasicRecordType = "" Then Return 0
        Dim freeBasicFieldName As String
        If GenericHeaderRecordFieldNameInContext( _
            translation, freeBasicRecordType, tokens(2), _
            freeBasicFieldName) = 0 Then Return 0
        freeBasicArgument = .freeBasicName & tokens(1) & freeBasicFieldName
    End With
    Return -1
End Function

Private Function GenericMacroExpressionTokenSequenceSupported( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, parameterNames() As String, _
    freeParameterNames() As String, ByVal parameterCount As Long, _
    ByVal isVariadic As Long, ByVal isCondition As Long = 0 _
) As Long
    Dim tokens() As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        sourceExpression, tokens(), tokenCount) = 0 Then Return 0
    Dim parenthesisDepth As Long = 0
    Dim bracketDepth As Long = 0

    For tokenIndex As Long = 0 To tokenCount - 1
        Dim sourceToken As String = tokens(tokenIndex)
        If IsIdentifierStart(Asc(sourceToken, 1)) <> 0 Then
            Dim isParameter As Long = 0
            For parameterIndex As Long = 0 To parameterCount - 1
                If sourceToken = parameterNames(parameterIndex) Then
                    isParameter = -1
                    Exit For
                End If
            Next
            If sourceToken = "__VA_ARGS__" AndAlso isVariadic <> 0 Then _
                isParameter = -1
            If isParameter = 0 AndAlso tokenIndex > 0 AndAlso _
               (tokens(tokenIndex - 1) = "->" OrElse tokens(tokenIndex - 1) = ".") Then
                ' A macro parameter's record type is supplied by its invocation.
                If tokenIndex >= 2 AndAlso _
                   IsIdentifierToken(tokens(tokenIndex - 2)) <> 0 Then
                    Dim baseIsParameter As Long = 0
                    For parameterIndex As Long = 0 To parameterCount - 1
                        If tokens(tokenIndex - 2) = parameterNames(parameterIndex) Then
                            baseIsParameter = -1
                            Exit For
                        End If
                    Next
                    If baseIsParameter = 0 Then
                        Dim baseSymbolIndex As Long = GenericHeaderSymbolIndexInContext( _
                            translation, tokens(tokenIndex - 2))
                        If baseSymbolIndex >= 0 Then
                            With translation.symbolTable.symbols(baseSymbolIndex)
                                If .kind <> GENERIC_SYMBOL_OBJECT Then Return 0
                                Dim freeBasicRecordType As String = _
                                    GenericHeaderRecordTypeFromMemberBase( _
                                        .genericHeader.freeBasicType, _
                                        CInt(tokens(tokenIndex - 1) = "->"))
                                If freeBasicRecordType = "" Then Return 0
                                Dim freeBasicFieldName As String
                                If GenericHeaderRecordFieldNameInContext( _
                                    translation, freeBasicRecordType, sourceToken, _
                                    freeBasicFieldName) = 0 Then Return 0
                            End With
                        End If
                    End If
                End If
            ElseIf isParameter = 0 Then
                Dim macroIndex As Long = GenericHeaderMacroIndexInContext( _
                    translation, sourceToken)
                If macroIndex >= 0 Then
                    With translation.genericC.header.headerMacros(macroIndex)
                        If .active = 0 OrElse .definition.functionLike <> 0 OrElse _
                           GenericDefineExcludedInPolicy( _
                            translation.genericC.policy, sourceToken) <> 0 Then Return 0
                        If .privateName <> 0 Then
                            If .resolvedValue = "" Then Return 0
                        ElseIf .freeBasicName = "" OrElse .emitted = 0 Then
                            Return 0
                        End If
                    End With
                ElseIf GenericHeaderSymbolIndexInContext( _
                    translation, sourceToken) < 0 AndAlso _
                   GenericEnumMemberIndexInContext(translation, sourceToken) < 0 Then
                    Return 0
                End If
            End If
        ElseIf (Asc(sourceToken, 1) >= Asc("0") AndAlso _
                Asc(sourceToken, 1) <= Asc("9")) OrElse _
               (Left(sourceToken, 1) = "." AndAlso Len(sourceToken) > 1 AndAlso _
                Asc(sourceToken, 2) >= Asc("0") AndAlso _
                Asc(sourceToken, 2) <= Asc("9")) Then
            Dim freeBasicToken As String
            If GenericMacroTokenNumber( _
                translation, sourceToken, freeBasicToken) = 0 Then Return 0
        ElseIf Left(sourceToken, 1) = Chr(34) OrElse _
               Left(sourceToken, 1) = "'" OrElse _
               (Len(sourceToken) > 1 AndAlso _
                (Left(sourceToken, 1) = "L" OrElse Left(sourceToken, 1) = "u" OrElse _
                 Left(sourceToken, 1) = "U") AndAlso _
                (Mid(sourceToken, 2, 1) = Chr(34) OrElse Mid(sourceToken, 2, 1) = "'")) OrElse _
               (Left(sourceToken, 2) = "u8" AndAlso _
                (Mid(sourceToken, 3, 1) = Chr(34) OrElse Mid(sourceToken, 3, 1) = "'")) Then
            Dim freeBasicToken As String
            If GenericMacroTokenStringLiteral( _
                sourceToken, freeBasicToken) = 0 Then Return 0
        Else
            Select Case sourceToken
            Case "(": parenthesisDepth += 1
            Case ")"
                parenthesisDepth -= 1
                If parenthesisDepth < 0 Then Return 0
            Case "[": bracketDepth += 1
            Case "]"
                bracketDepth -= 1
                If bracketDepth < 0 Then Return 0
            Case "->", ".", "+", "-", "*", "&"
            Case "==", "!=", "<", ">", "<=", ">=", "&&", "||"
                If isCondition = 0 Then Return 0
            Case Else
                Return 0
            End Select
        End If
    Next

    If parenthesisDepth <> 0 OrElse bracketDepth <> 0 Then Return 0
    Return -1
End Function

Private Function GenericIntegerMacroExpressionRequiresMacro( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String _
) As Long
    Dim tokens() As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        sourceExpression, tokens(), tokenCount) = 0 Then Return 0
    For tokenIndex As Long = 0 To tokenCount - 1
        If GenericTypeOverrideIsTypedefHintInPolicy( _
            translation.genericC.policy, tokens(tokenIndex)) <> 0 AndAlso _
           GenericHeaderTypeAliasIndexInHeader( _
            translation.genericC.header, tokens(tokenIndex), 0) < 0 Then _
            Return -1
        If IsIdentifierStart(Asc(tokens(tokenIndex), 1)) <> 0 AndAlso _
           IsTypeOrQualifierTokenInContext( _
            translation, tokens(tokenIndex)) = 0 AndAlso _
           GenericEnumMemberIndexInContext( _
            translation, tokens(tokenIndex)) < 0 Then Return -1
    Next
    Return 0
End Function

Private Function GenericIntegerMacroTokenSequenceSupported( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String _
) As Long
    Dim tokens() As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        sourceExpression, tokens(), tokenCount) = 0 OrElse tokenCount = 0 Then _
        Return 0

    Dim expectOperand As Long = -1
    Dim groupDepth As Long = 0
    Dim hasIdentifier As Long = 0
    For tokenIndex As Long = 0 To tokenCount - 1
        Dim sourceToken As String = tokens(tokenIndex)
        Dim firstByte As Long = Asc(sourceToken, 1)
        If IsIdentifierStart(firstByte) <> 0 Then
            If expectOperand = 0 Then Return 0
            hasIdentifier = -1
            expectOperand = 0
        ElseIf (firstByte >= Asc("0") AndAlso firstByte <= Asc("9")) OrElse _
               (firstByte = Asc(".") AndAlso Len(sourceToken) > 1 AndAlso _
                Asc(sourceToken, 2) >= Asc("0") AndAlso _
                Asc(sourceToken, 2) <= Asc("9")) Then
            If expectOperand = 0 Then Return 0
            Dim freeBasicNumber As String
            If GenericMacroTokenNumber( _
                translation, sourceToken, freeBasicNumber) = 0 Then Return 0
            expectOperand = 0
        Else
            Select Case sourceToken
            Case "("
                If expectOperand = 0 Then Return 0
                groupDepth += 1
            Case ")"
                If expectOperand <> 0 OrElse groupDepth = 0 Then Return 0
                groupDepth -= 1
                expectOperand = 0
            Case "+", "-"
                If expectOperand = 0 Then expectOperand = -1
            Case "*", "&", "|", "^", "<<", ">>"
                If expectOperand <> 0 Then Return 0
                expectOperand = -1
            Case Else
                Return 0
            End Select
        End If
    Next

    If expectOperand <> 0 OrElse groupDepth <> 0 OrElse hasIdentifier = 0 Then _
        Return 0
    Return -1
End Function

Private Function TranslateGenericFunctionCallMacroArgument( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceArgument As String, parameterNames() As String, _
    freeParameterNames() As String, ByVal parameterCount As Long, _
    ByVal isVariadic As Long, ByRef freeBasicArgument As String _
) As Long
    sourceArgument = Trim(sourceArgument)
    If sourceArgument = "" Then Return 0
    If isVariadic <> 0 AndAlso sourceArgument = "__VA_ARGS__" Then
        freeBasicArgument = freeParameterNames(parameterCount - 1)
        Return -1
    End If
    If Left(sourceArgument, 1) = "#" Then
        Dim stringizedParameter As String = Trim(Mid(sourceArgument, 2))
        If IsIdentifierToken(stringizedParameter) = 0 Then Return 0
        For parameterIndex As Long = 0 To parameterCount - 1
            If parameterNames(parameterIndex) = stringizedParameter Then
                If stringizedParameter = "__VA_ARGS__" AndAlso isVariadic = 0 Then Return 0
                freeBasicArgument = "#" & freeParameterNames(parameterIndex)
                Return -1
            End If
        Next
        Return 0
    End If
    If InStr(sourceArgument, "__VA_ARGS__") <> 0 Then Return 0

    For parameterIndex As Long = 0 To parameterCount - 1
        If isVariadic <> 0 AndAlso parameterIndex = parameterCount - 1 Then Exit For
        If sourceArgument = parameterNames(parameterIndex) Then
            freeBasicArgument = freeParameterNames(parameterIndex)
            Return -1
        End If
    Next

    If Left(sourceArgument, 1) = "!" Then
        Dim logicalOperand As String = GenericMacroStripOuterParentheses( _
            Trim(Mid(sourceArgument, 2)))
        If IsIdentifierToken(logicalOperand) <> 0 Then
            Dim freeBasicOperand As String
            If GenericMacroTokenIdentifier( _
                translation, logicalOperand, parameterNames(), freeParameterNames(), _
                parameterCount, isVariadic, freeBasicOperand) <> 0 Then
                ' FreeBASIC Boolean true is -1; negation normalizes C ! to 0 or 1.
                freeBasicArgument = "-Cast(c2fb_c_int, ((" & _
                    freeBasicOperand & ") = 0))"
                Return -1
            End If
        End If
    End If

    If TranslateGenericHeaderStringMacro( _
        sourceArgument, freeBasicArgument) <> 0 Then Return -1
    If GenericHeaderMacroIndexInContext(translation, sourceArgument) < 0 Then
        Dim symbolIndex As Long = _
            GenericHeaderSymbolIndexInContext(translation, sourceArgument)
        If symbolIndex >= 0 AndAlso _
           translation.symbolTable.symbols(symbolIndex).kind = GENERIC_SYMBOL_OBJECT AndAlso _
           translation.symbolTable.symbols(symbolIndex).genericHeader.arrayCount = 0 AndAlso _
           translation.symbolTable.symbols(symbolIndex).genericHeader.unsizedArray = 0 Then
            freeBasicArgument = translation.symbolTable.symbols(symbolIndex).freeBasicName
            Return -1
        End If
    End If
    If TranslateGenericMemberAccessMacroArgument( _
        translation, sourceArgument, freeBasicArgument) <> 0 Then Return -1
    If TranslateGenericHeaderMacroExpressionWithParameters( _
        translation, sourceArgument, freeBasicArgument, parameterNames(), _
        freeParameterNames(), parameterCount) <> 0 Then Return -1
    If GenericMacroExpressionTokenSequenceSupported( _
        translation, sourceArgument, parameterNames(), freeParameterNames(), _
        parameterCount, isVariadic) = 0 Then Return 0
    Return TranslateGenericMacroTokenSequence( _
        translation, sourceArgument, parameterNames(), freeParameterNames(), _
        parameterCount, isVariadic, freeBasicArgument)
End Function

/'
    Braces and C's do { call(); } while (0) wrapper protect statement-style
    macro use. Removing either wrapper is equivalent only for one supported call.
'/
Private Function StripGenericSingleCallMacroWrapper( _
    ByVal sourceBody As String, ByRef callBody As String _
) As Long
    sourceBody = Trim(sourceBody)
    If Left(sourceBody, 1) = "{" Then
        Dim blockClose As Long = 1
        If ScanSimpleExpressionGroup( _
            sourceBody, blockClose, Asc("{"), Asc("}")) = 0 Then Return 0
        Dim blockStatement As String = Trim(Mid( _
            sourceBody, 2, blockClose - 3))
        If blockStatement = "" OrElse Right(blockStatement, 1) <> ";" Then Return 0
        blockStatement = Trim(Left(blockStatement, Len(blockStatement) - 1))
        If blockStatement = "" Then Return 0
        Dim blockTail As String = Trim(Mid(sourceBody, blockClose))
        If blockTail <> "" AndAlso blockTail <> ";" Then Return 0
        callBody = blockStatement
        Return -1
    End If
    If Len(sourceBody) < 2 OrElse LCase(Left(sourceBody, 2)) <> "do" Then Return 0
    If Len(sourceBody) > 2 AndAlso _
       IsIdentifierPart(Asc(sourceBody, 3)) <> 0 Then Return 0

    Dim openingBrace As Long = 3
    While openingBrace <= Len(sourceBody) AndAlso _
          IsSpaceByte(Asc(sourceBody, openingBrace)) <> 0
        openingBrace += 1
    Wend
    If openingBrace > Len(sourceBody) OrElse _
       Asc(sourceBody, openingBrace) <> Asc("{") Then Return 0

    Dim closingBrace As Long = openingBrace
    If ScanSimpleExpressionGroup( _
        sourceBody, closingBrace, Asc("{"), Asc("}")) = 0 Then Return 0
    Dim statementText As String = Trim(Mid( _
        sourceBody, openingBrace + 1, closingBrace - openingBrace - 2))
    If statementText = "" OrElse Right(statementText, 1) <> ";" Then Return 0
    statementText = Trim(Left(statementText, Len(statementText) - 1))
    If statementText = "" Then Return 0

    Dim trailingText As String = Trim(Mid(sourceBody, closingBrace))
    If Len(trailingText) <= 5 OrElse LCase(Left(trailingText, 5)) <> "while" Then Return 0
    If IsIdentifierPart(Asc(trailingText, 6)) <> 0 Then Return 0
    Dim conditionOpen As Long = 6
    While conditionOpen <= Len(trailingText) AndAlso _
          IsSpaceByte(Asc(trailingText, conditionOpen)) <> 0
        conditionOpen += 1
    Wend
    If conditionOpen > Len(trailingText) OrElse _
       Asc(trailingText, conditionOpen) <> Asc("(") Then Return 0
    Dim conditionClose As Long = conditionOpen
    If ScanSimpleExpressionGroup( _
        trailingText, conditionClose, Asc("("), Asc(")")) = 0 Then Return 0
    Dim conditionText As String = Trim(Mid( _
        trailingText, conditionOpen + 1, conditionClose - conditionOpen - 2))
    If GenericMacroStripOuterParentheses(conditionText) <> "0" Then Return 0
    Dim remainingText As String = Trim(Mid(trailingText, conditionClose))
    If remainingText <> "" AndAlso remainingText <> ";" Then Return 0

    callBody = statementText
    Return -1
End Function

Declare Function TranslateGenericFunctionCallMacro( _
    ByRef translation As C2fbTranslationContext, _
    ByVal body As String, parameterNames() As String, _
    freeParameterNames() As String, ByVal parameterCount As Long, _
    ByVal isVariadic As Long, ByRef freeBasicExpression As String _
) As Long

Private Function TranslateGenericConditionalCallMacro( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceBody As String, parameterNames() As String, _
    freeParameterNames() As String, ByVal parameterCount As Long, _
    ByVal isVariadic As Long, ByRef freeBasicBlockBody As String _
) As Long
    sourceBody = Trim(sourceBody)
    If Left(sourceBody, 1) = "{" Then
        Dim blockEnd As Long = 1
        If ScanSimpleExpressionGroup( _
            sourceBody, blockEnd, Asc("{"), Asc("}")) = 0 Then Return 0
        Dim blockTail As String = Trim(Mid(sourceBody, blockEnd))
        If blockTail <> "" AndAlso blockTail <> ";" Then Return 0
        sourceBody = Trim(Mid(sourceBody, 2, blockEnd - 3))
    ElseIf Len(sourceBody) >= 2 AndAlso LCase(Left(sourceBody, 2)) = "do" Then
        Dim unwrappedBody As String
        If StripGenericSingleCallMacroWrapper( _
            sourceBody, unwrappedBody) = 0 Then Return 0
        sourceBody = Trim(unwrappedBody)
    End If

    If Len(sourceBody) < 2 OrElse LCase(Left(sourceBody, 2)) <> "if" OrElse _
       (Len(sourceBody) > 2 AndAlso IsIdentifierPart(Asc(sourceBody, 3)) <> 0) Then _
        Return 0

    Dim conditionOpen As Long = 3
    While conditionOpen <= Len(sourceBody) AndAlso _
          IsSpaceByte(Asc(sourceBody, conditionOpen)) <> 0
        conditionOpen += 1
    Wend
    If conditionOpen > Len(sourceBody) OrElse _
       Asc(sourceBody, conditionOpen) <> Asc("(") Then Return -1
    Dim conditionClose As Long = conditionOpen
    If ScanSimpleExpressionGroup( _
        sourceBody, conditionClose, Asc("("), Asc(")")) = 0 Then Return -1
    Dim conditionText As String = Trim(Mid( _
        sourceBody, conditionOpen + 1, conditionClose - conditionOpen - 2))
    If conditionText = "" Then Return -1

    Dim callBody As String = Trim(Mid(sourceBody, conditionClose))
    If Left(callBody, 1) = "{" Then
        Dim unwrappedCall As String
        If StripGenericSingleCallMacroWrapper( _
            callBody, unwrappedCall) = 0 Then Return -1
        callBody = Trim(unwrappedCall)
    Else
        If Right(callBody, 1) = ";" Then _
            callBody = Trim(Left(callBody, Len(callBody) - 1))
        If callBody = "" OrElse InStr(callBody, ";") <> 0 Then Return -1
    End If

    If GenericMacroExpressionTokenSequenceSupported( _
        translation, conditionText, parameterNames(), freeParameterNames(), _
        parameterCount, isVariadic, -1) = 0 Then Return -1
    Dim freeBasicCondition As String
    If TranslateGenericMacroTokenSequence( _
        translation, conditionText, parameterNames(), freeParameterNames(), _
        parameterCount, isVariadic, freeBasicCondition) = 0 Then Return -1
    Dim freeBasicCall As String
    If TranslateGenericFunctionCallMacro( _
        translation, callBody, parameterNames(), freeParameterNames(), _
        parameterCount, isVariadic, freeBasicCall) = 0 Then Return -1

    freeBasicBlockBody = "If (" & freeBasicCondition & ") Then" & Chr(10) & _
        "    " & freeBasicCall & Chr(10) & "End If"
    Return 1
End Function

Private Function GenericHeaderSymbolIsCallableInContext( _
    ByRef translation As C2fbTranslationContext, ByVal symbolIndex As Long _
) As Long
    If symbolIndex < 0 OrElse symbolIndex >= translation.symbolTable.symbolCount Then Return 0
    With translation.symbolTable.symbols(symbolIndex)
        If .kind = GENERIC_SYMBOL_FUNCTION OrElse .kind = GENERIC_SYMBOL_SUB Then _
            Return -1
        If .kind <> GENERIC_SYMBOL_OBJECT Then Return 0
        Dim freeBasicType As String = Trim(.genericHeader.freeBasicType)
        If Left(freeBasicType, 6) = "Const " Then _
            freeBasicType = Trim(Mid(freeBasicType, 7))
        If Left(freeBasicType, 9) = "Function " OrElse _
           Left(freeBasicType, 4) = "Sub " Then Return -1
        For aliasIndex As Long = 0 To _
            translation.genericC.header.headerTypeAliasCount - 1
            With translation.genericC.header.headerTypeAliases(aliasIndex)
                If .freeBasicName = freeBasicType AndAlso _
                   (.isFunction <> 0 OrElse Left(.baseType, 9) = "Function " OrElse _
                    Left(.baseType, 4) = "Sub ") Then Return -1
            End With
        Next
    End With
    Return 0
End Function

Private Function TranslateGenericFunctionCallMacro( _
    ByRef translation As C2fbTranslationContext, _
    ByVal body As String, parameterNames() As String, _
    freeParameterNames() As String, ByVal parameterCount As Long, _
    ByVal isVariadic As Long, ByRef freeBasicExpression As String _
) As Long
    ' Limit this path to a single call to a declaration already emitted by C2FB.
    ' The catalog supplies the FreeBASIC identifier while Alias retains the C symbol.
    body = GenericMacroStripOuterParentheses(body)
    If body = "" OrElse IsIdentifierStart(Asc(body, 1)) = 0 Then Return 0

    Dim nameEnd As Long = 1
    While nameEnd <= Len(body) AndAlso _
          IsIdentifierPart(Asc(body, nameEnd)) <> 0
        nameEnd += 1
    Wend
    Dim sourceFunctionName As String = Left(body, nameEnd - 1)
    Dim symbolIndex As Long = _
        GenericHeaderSymbolIndexInContext(translation, sourceFunctionName)
    If GenericHeaderSymbolIsCallableInContext(translation, symbolIndex) = 0 Then Return 0

    Dim openingPosition As Long = nameEnd
    While openingPosition <= Len(body) AndAlso _
          IsSpaceByte(Asc(body, openingPosition)) <> 0
        openingPosition += 1
    Wend
    If openingPosition > Len(body) OrElse _
       Asc(body, openingPosition) <> Asc("(") Then Return 0
    Dim closingPosition As Long = openingPosition
    If ScanSimpleExpressionGroup( _
        body, closingPosition, Asc("("), Asc(")")) = 0 OrElse _
       closingPosition <= Len(body) Then Return 0

    Dim argumentText As String = Trim(Mid( _
        body, openingPosition + 1, closingPosition - openingPosition - 2))
    Dim arguments() As String
    Dim argumentCount As Long = 0
    If argumentText <> "" AndAlso _
       SplitSimpleCList(argumentText, arguments(), argumentCount) = 0 Then Return 0
    Dim translatedArguments As String
    For argumentIndex As Long = 0 To argumentCount - 1
        Dim freeBasicArgument As String
        If TranslateGenericFunctionCallMacroArgument( _
            translation, arguments(argumentIndex), parameterNames(), freeParameterNames(), _
            parameterCount, isVariadic, freeBasicArgument) = 0 Then Return 0
        If argumentIndex > 0 Then translatedArguments &= ", "
        translatedArguments &= freeBasicArgument
    Next
    freeBasicExpression = translation.symbolTable.symbols(symbolIndex).freeBasicName & _
        "(" & translatedArguments & ")"
    Return -1
End Function

Private Function FindGenericMacroAssignmentOperator( _
    ByVal sourceExpression As String, ByRef operatorText As String, _
    ByRef operatorPosition As Long _
) As Long
    operatorText = ""
    operatorPosition = 0
    Dim parenDepth As Long = 0
    Dim bracketDepth As Long = 0
    Dim braceDepth As Long = 0
    Dim quoteByte As Long = 0
    Dim matchCount As Long = 0
    Dim position As Long = 1
    While position <= Len(sourceExpression)
        Dim currentByte As Long = Asc(sourceExpression, position)
        If quoteByte <> 0 Then
            If currentByte = Asc(Chr(92)) AndAlso position < Len(sourceExpression) Then
                position += 2
                Continue While
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
            position += 1
            Continue While
        ElseIf currentByte = Asc("'") OrElse currentByte = Asc(Chr(34)) Then
            quoteByte = currentByte
            position += 1
            Continue While
        End If

        Select Case currentByte
        Case Asc("("): parenDepth += 1
        Case Asc(")")
            parenDepth -= 1
            If parenDepth < 0 Then Return -1
        Case Asc("["): bracketDepth += 1
        Case Asc("]")
            bracketDepth -= 1
            If bracketDepth < 0 Then Return -1
        Case Asc("{"): braceDepth += 1
        Case Asc("}")
            braceDepth -= 1
            If braceDepth < 0 Then Return -1
        End Select
        If parenDepth = 0 AndAlso bracketDepth = 0 AndAlso braceDepth = 0 Then
            Dim candidate As String
            If position + 2 <= Len(sourceExpression) Then
                candidate = Mid(sourceExpression, position, 3)
                If candidate = "<<=" OrElse candidate = ">>=" Then
                    position += 3
                Else
                    candidate = ""
                End If
            End If
            If candidate = "" AndAlso position < Len(sourceExpression) Then
                Dim pair As String = Mid(sourceExpression, position, 2)
                Select Case pair
                Case "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^="
                    candidate = pair
                    position += 2
                End Select
            End If
            If candidate = "" AndAlso currentByte = Asc("=") Then
                Dim previousByte As Long = 0
                Dim nextByte As Long = 0
                If position > 1 Then previousByte = Asc(sourceExpression, position - 1)
                If position < Len(sourceExpression) Then _
                    nextByte = Asc(sourceExpression, position + 1)
                If previousByte <> Asc("=") AndAlso previousByte <> Asc("!") AndAlso _
                   previousByte <> Asc("<") AndAlso previousByte <> Asc(">") AndAlso _
                   nextByte <> Asc("=") Then
                    candidate = "="
                    position += 1
                End If
            End If
            If candidate <> "" Then
                matchCount += 1
                If matchCount > 1 Then Return -1
                operatorText = candidate
                operatorPosition = position - Len(candidate)
                Continue While
            End If
        End If
        position += 1
    Wend
    If parenDepth <> 0 OrElse bracketDepth <> 0 OrElse braceDepth <> 0 OrElse _
       quoteByte <> 0 Then Return -1
    If matchCount = 1 Then Return 1
    Return 0
End Function

Private Function TranslateGenericMacroAssignmentTarget( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceTarget As String, parameterNames() As String, _
    freeParameterNames() As String, ByVal parameterCount As Long, _
    ByRef freeBasicTarget As String _
) As Long
    sourceTarget = GenericMacroStripOuterParentheses(Trim(sourceTarget))
    For parameterIndex As Long = 0 To parameterCount - 1
        If sourceTarget = parameterNames(parameterIndex) Then
            freeBasicTarget = freeParameterNames(parameterIndex)
            Return -1
        End If
    Next
    If TranslateGenericMemberAccessMacroArgument( _
        translation, sourceTarget, freeBasicTarget) <> 0 Then Return -1
    If IsIdentifierToken(sourceTarget) = 0 Then Return 0
    Dim symbolIndex As Long = _
        GenericHeaderSymbolIndexInContext(translation, sourceTarget)
    If symbolIndex < 0 Then
        ' The caller may supply an external FreeBASIC lvalue that is absent
        ' from the C header being converted.
        freeBasicTarget = sourceTarget
        Return -1
    End If
    With translation.symbolTable.symbols(symbolIndex)
        If .kind <> GENERIC_SYMBOL_OBJECT OrElse _
           .genericHeader.arrayCount <> 0 OrElse _
           .genericHeader.unsizedArray <> 0 Then Return 0
        freeBasicTarget = .freeBasicName
    End With
    Return -1
End Function

Private Function TranslateGenericMacroStatementExpression( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, parameterNames() As String, _
    freeParameterNames() As String, ByVal parameterCount As Long, _
    ByVal isVariadic As Long, ByRef freeBasicStatement As String, _
    ByVal integerDivisionAssumed As Long = 0 _
) As Long
    sourceExpression = Trim(sourceExpression)
    If sourceExpression = "" Then Return 0

    Dim assignmentOperator As String
    Dim assignmentPosition As Long
    Dim assignmentStatus As Long = FindGenericMacroAssignmentOperator( _
        sourceExpression, assignmentOperator, assignmentPosition)
    If assignmentStatus < 0 Then Return 0
    If assignmentStatus > 0 Then
        Dim sourceTarget As String = Trim(Left(sourceExpression, assignmentPosition - 1))
        Dim sourceValue As String = Trim(Mid( _
            sourceExpression, assignmentPosition + Len(assignmentOperator)))
        If sourceTarget = "" OrElse sourceValue = "" Then Return 0
        Dim freeBasicTarget As String
        If TranslateGenericMacroAssignmentTarget( _
            translation, sourceTarget, parameterNames(), freeParameterNames(), _
            parameterCount, freeBasicTarget) = 0 Then Return 0

        Dim freeBasicValue As String
        If TranslateGenericHeaderMacroExpressionWithParameters( _
            translation, sourceValue, freeBasicValue, parameterNames(), _
            freeParameterNames(), parameterCount) = 0 Then
            If TranslateGenericFunctionCallMacro( _
                translation, sourceValue, parameterNames(), freeParameterNames(), _
                parameterCount, isVariadic, freeBasicValue) = 0 Then
                If GenericIntegerMacroTokenSequenceSupported( _
                    translation, sourceValue) <> 0 Then
                    If TranslateGenericMacroTokenSequence( _
                        translation, sourceValue, parameterNames(), _
                        freeParameterNames(), parameterCount, isVariadic, _
                        freeBasicValue) = 0 Then Return 0
                ElseIf GenericUnsignedIntMacroExpressionStatus(sourceValue) < 0 OrElse _
                       GenericMacroExpressionTokenSequenceSupported( _
                        translation, sourceValue, parameterNames(), _
                        freeParameterNames(), parameterCount, isVariadic) = 0 OrElse _
                       TranslateGenericMacroTokenSequence( _
                        translation, sourceValue, parameterNames(), _
                        freeParameterNames(), parameterCount, isVariadic, _
                        freeBasicValue) = 0 Then
                    Return 0
                End If
            End If
        End If

        Dim freeBasicOperator As String = assignmentOperator
        Select Case assignmentOperator
        Case "/=": If integerDivisionAssumed <> 0 Then freeBasicOperator = "\="
        Case "%=": freeBasicOperator = "Mod="
        Case "&=": freeBasicOperator = "And="
        Case "|=": freeBasicOperator = "Or="
        Case "^=": freeBasicOperator = "Xor="
        Case "<<=": freeBasicOperator = "Shl="
        Case ">>=": freeBasicOperator = "Shr="
        End Select
        freeBasicStatement = freeBasicTarget & " " & freeBasicOperator & _
            " " & freeBasicValue
        Return -1
    End If

    If TranslateGenericFunctionCallMacro( _
        translation, sourceExpression, parameterNames(), freeParameterNames(), _
        parameterCount, isVariadic, freeBasicStatement) <> 0 Then Return -1
    If TranslateGenericDirectCallMacroTokens( _
        translation, sourceExpression, parameterNames(), freeParameterNames(), _
        parameterCount, isVariadic, freeBasicStatement) <> 0 Then Return -1

    ' A literal-only operand of a statement-context comma expression has no
    ' observable effect. FreeBASIC does not accept a numeric literal as a
    ' standalone statement, so omit just this restricted case.
    Dim expressionTokens() As String
    Dim expressionTokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        sourceExpression, expressionTokens(), expressionTokenCount) <> 0 AndAlso _
       expressionTokenCount = 1 Then
        Dim ignoredNumber As String
        If GenericMacroTokenNumber( _
            translation, expressionTokens(0), ignoredNumber) <> 0 Then
            freeBasicStatement = ""
            Return -1
        End If
    End If
    Return 0
End Function

Private Function StripGenericZeroLoopMacroBody( _
    ByVal sourceBody As String, ByRef innerBody As String _
) As Long
    sourceBody = Trim(sourceBody)
    If Len(sourceBody) < 2 OrElse LCase(Left(sourceBody, 2)) <> "do" Then Return 0
    If Len(sourceBody) > 2 AndAlso _
       IsIdentifierPart(Asc(sourceBody, 3)) <> 0 Then Return 0

    Dim openingBrace As Long = 3
    While openingBrace <= Len(sourceBody) AndAlso _
          IsSpaceByte(Asc(sourceBody, openingBrace)) <> 0
        openingBrace += 1
    Wend
    If openingBrace > Len(sourceBody) OrElse _
       Asc(sourceBody, openingBrace) <> Asc("{") Then Return 0
    Dim closingBrace As Long = openingBrace
    If ScanSimpleExpressionGroup( _
        sourceBody, closingBrace, Asc("{"), Asc("}")) = 0 Then Return 0

    Dim trailingText As String = Trim(Mid(sourceBody, closingBrace))
    If Len(trailingText) <= 5 OrElse LCase(Left(trailingText, 5)) <> "while" Then Return 0
    If IsIdentifierPart(Asc(trailingText, 6)) <> 0 Then Return 0
    Dim conditionOpen As Long = 6
    While conditionOpen <= Len(trailingText) AndAlso _
          IsSpaceByte(Asc(trailingText, conditionOpen)) <> 0
        conditionOpen += 1
    Wend
    If conditionOpen > Len(trailingText) OrElse _
       Asc(trailingText, conditionOpen) <> Asc("(") Then Return 0
    Dim conditionClose As Long = conditionOpen
    If ScanSimpleExpressionGroup( _
        trailingText, conditionClose, Asc("("), Asc(")")) = 0 Then Return 0
    Dim conditionText As String = Trim(Mid( _
        trailingText, conditionOpen + 1, conditionClose - conditionOpen - 2))
    If GenericNullPointerConstantText(conditionText) = 0 Then Return 0
    Dim remainingText As String = Trim(Mid(trailingText, conditionClose))
    If remainingText <> "" AndAlso remainingText <> ";" Then Return 0

    innerBody = Trim(Mid(sourceBody, openingBrace + 1, _
        closingBrace - openingBrace - 2))
    Return -1
End Function

Private Function SplitGenericMacroStatementSequence( _
    ByVal sourceText As String, parts() As String, _
    ByRef partCount As Long, ByRef hasSemicolon As Long _
) As Long
    ReDim parts(0 To 7)
    partCount = 0
    hasSemicolon = 0
    Dim start As Long = 1
    Dim parenDepth As Long = 0
    Dim bracketDepth As Long = 0
    Dim braceDepth As Long = 0
    Dim quoteByte As Long = 0
    For position As Long = 1 To Len(sourceText) + 1
        Dim currentByte As Long = Asc(";")
        If position <= Len(sourceText) Then currentByte = Asc(sourceText, position)
        If quoteByte <> 0 Then
            If currentByte = Asc(Chr(92)) AndAlso position < Len(sourceText) Then
                position += 1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
            Continue For
        ElseIf position <= Len(sourceText) AndAlso _
               (currentByte = Asc("'") OrElse currentByte = Asc(Chr(34))) Then
            quoteByte = currentByte
        ElseIf currentByte = Asc("(") Then
            parenDepth += 1
        ElseIf currentByte = Asc(")") Then
            parenDepth -= 1
        ElseIf currentByte = Asc("[") Then
            bracketDepth += 1
        ElseIf currentByte = Asc("]") Then
            bracketDepth -= 1
        ElseIf currentByte = Asc("{") Then
            braceDepth += 1
        ElseIf currentByte = Asc("}") Then
            braceDepth -= 1
        ElseIf currentByte = Asc(";") AndAlso parenDepth = 0 AndAlso _
               bracketDepth = 0 AndAlso braceDepth = 0 Then
            If position <= Len(sourceText) Then hasSemicolon = -1
            Dim statementText As String = Trim(Mid(sourceText, start, position - start))
            If statementText <> "" Then
                If partCount >= MAX_SIMPLE_VARIABLES Then Return 0
                If partCount > UBound(parts) Then _
                    ReDim Preserve parts(0 To UBound(parts) * 2 + 1)
                parts(partCount) = statementText
                partCount += 1
            End If
            start = position + 1
        End If
        If parenDepth < 0 OrElse bracketDepth < 0 OrElse braceDepth < 0 Then Return 0
    Next
    If parenDepth <> 0 OrElse bracketDepth <> 0 OrElse braceDepth <> 0 OrElse _
       quoteByte <> 0 Then Return 0
    Return -1
End Function

Private Function GenericMacroLocalDeclarationCandidate( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceStatement As String _
) As Long
    sourceStatement = Trim(sourceStatement)
    If Right(sourceStatement, 1) = ";" Then _
        sourceStatement = RTrim(Left(sourceStatement, Len(sourceStatement) - 1))
    If sourceStatement = "" Then Return 0

    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(sourceStatement, tokens(), tokenCount)
    If tokenCount = 0 Then Return 0

    Dim firstTypeToken As Long = 0
    While firstTypeToken < tokenCount AndAlso _
          (tokens(firstTypeToken) = "static" OrElse _
           tokens(firstTypeToken) = "auto" OrElse _
           tokens(firstTypeToken) = "register" OrElse _
           tokens(firstTypeToken) = "extern")
        firstTypeToken += 1
    Wend
    If firstTypeToken >= tokenCount Then Return 0

    If IsTypeOrQualifierTokenInContext( _
        translation, tokens(firstTypeToken)) <> 0 Then Return -1
    If IsIdentifierToken(tokens(firstTypeToken)) = 0 Then Return 0
    Dim pointerCount As Long = 0
    Dim isConst As Long = 0
    If GenericTypeOverrideInPolicy( _
        translation.genericC.policy, tokens(firstTypeToken)) <> "" OrElse _
       LookupCBodyTypeAliasInContext( _
        translation, tokens(firstTypeToken), pointerCount, isConst) <> "" Then _
        Return -1
    If C2fbIsWindowsEngineSource(translation) <> 0 Then
        Dim mappedType As String
        If ResolveC2fbWindowsAbiType( _
            tokens(firstTypeToken), pointerCount, isConst, mappedType) <> 0 Then _
            Return -1
    End If
    Return 0
End Function

Private Function ReadGenericMacroConditionalBranch( _
    ByVal sourceText As String, ByRef branchText As String, _
    ByRef remainingText As String _
) As Long
    sourceText = Trim(sourceText)
    branchText = ""
    remainingText = ""
    If sourceText = "" Then Return 0

    If Left(sourceText, 1) = "{" Then
        Dim blockEnd As Long = 1
        If ScanSimpleExpressionGroup( _
            sourceText, blockEnd, Asc("{"), Asc("}")) = 0 Then Return 0
        branchText = Left(sourceText, blockEnd - 1)
        remainingText = Trim(Mid(sourceText, blockEnd))
        Return -1
    End If
    If Left(sourceText, 1) = ";" Then
        branchText = ";"
        remainingText = Trim(Mid(sourceText, 2))
        Return -1
    End If

    Dim parenthesisDepth As Long = 0
    Dim bracketDepth As Long = 0
    Dim braceDepth As Long = 0
    Dim quoteByte As Long = 0
    For position As Long = 1 To Len(sourceText)
        Dim currentByte As Long = Asc(sourceText, position)
        If quoteByte <> 0 Then
            If currentByte = Asc(Chr(92)) AndAlso position < Len(sourceText) Then
                position += 1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
            Continue For
        ElseIf currentByte = Asc("'") OrElse currentByte = Asc(Chr(34)) Then
            quoteByte = currentByte
            Continue For
        End If

        Select Case currentByte
        Case Asc("("): parenthesisDepth += 1
        Case Asc(")")
            parenthesisDepth -= 1
            If parenthesisDepth < 0 Then Return 0
        Case Asc("["): bracketDepth += 1
        Case Asc("]")
            bracketDepth -= 1
            If bracketDepth < 0 Then Return 0
        Case Asc("{"): braceDepth += 1
        Case Asc("}")
            braceDepth -= 1
            If braceDepth < 0 Then Return 0
        Case Asc(";")
            If parenthesisDepth = 0 AndAlso bracketDepth = 0 AndAlso _
               braceDepth = 0 Then
                branchText = Trim(Left(sourceText, position))
                remainingText = Trim(Mid(sourceText, position + 1))
                Return -1
            End If
        End Select
    Next
    Return 0
End Function

Private Function IndentGenericMacroBlockText( _
    ByVal sourceText As String, ByVal indentation As String _
) As String
    If sourceText = "" Then Return ""
    Dim result As String
    Dim lineStart As Long = 1
    While lineStart <= Len(sourceText)
        Dim lineEnd As Long = InStr(lineStart, sourceText, Chr(10))
        If lineEnd = 0 Then lineEnd = Len(sourceText) + 1
        If result <> "" Then result &= Chr(10)
        result &= indentation & Mid(sourceText, lineStart, lineEnd - lineStart)
        lineStart = lineEnd + 1
    Wend
    Return result
End Function

Private Function GenericMacroRecordBindingText( _
    ByRef recordBinding As C2fbRecordBindingModel, _
    ByRef outputText As String _
) As Long
    outputText = ""
    Dim compoundName As String = "Type"
    If recordBinding.isUnion <> 0 Then compoundName = "Union"
    outputText = compoundName & " " & recordBinding.freeBasicName
    If recordBinding.isPacked <> 0 Then
        outputText &= " Field = 1"
    Else
        Select Case recordBinding.packValue
        Case 1, 2, 4, 8
            outputText &= " Field = " & Trim(Str(recordBinding.packValue))
        End Select
    End If
    Dim indentLevel As Long = 1
    Dim aggregateLevel As Long = 0
    Dim aggregateIsUnionStack(0 To recordBinding.itemCount) As Long
    aggregateIsUnionStack(0) = recordBinding.isUnion
    If recordBinding.itemCount > 0 Then
        For itemIndex As Long = 0 To recordBinding.itemCount - 1
            With recordBinding.items(itemIndex)
                Select Case .kind
                Case C2FB_RECORD_BINDING_ITEM_ANONYMOUS_BEGIN
                    Dim nestedName As String = "Type"
                    If .isUnion <> 0 Then nestedName = "Union"
                    outputText &= Chr(10) & Space(indentLevel * 4) & nestedName
                    indentLevel += 1
                    aggregateLevel += 1
                    aggregateIsUnionStack(aggregateLevel) = .isUnion
                Case C2FB_RECORD_BINDING_ITEM_ANONYMOUS_END
                    If indentLevel <= 1 Then Return 0
                    indentLevel -= 1
                    Dim nestedName As String = "Type"
                    If .isUnion <> 0 Then nestedName = "Union"
                    outputText &= Chr(10) & Space(indentLevel * 4) & _
                        "End " & nestedName
                    If aggregateLevel > 0 Then aggregateLevel -= 1
                Case C2FB_RECORD_BINDING_ITEM_FIELD
                    outputText &= Chr(10) & _
                        C2fbRecordBindingFieldDeclarationText( _
                            recordBinding, itemIndex, .name, .fieldType, _
                            .arrayCount, .arrayBounds, .alignmentStorageType, _
                            .packValue, .isBitField, .bitWidth, _
                            aggregateIsUnionStack(aggregateLevel), indentLevel)
                Case Else
                    ' Flexible arrays need an accessor outside the local Type scope.
                    Return 0
                End Select
            End With
        Next
    Else
        For fieldIndex As Long = 0 To recordBinding.fieldCount - 1
            With recordBinding.fields(fieldIndex)
                outputText &= Chr(10) & _
                    C2fbRecordBindingFieldDeclarationText( _
                        recordBinding, fieldIndex, .name, .fieldType, _
                        .arrayCount, .arrayBounds, .alignmentStorageType, _
                        0, 0, 0, recordBinding.isUnion, 1)
            End With
        Next
    End If
    If indentLevel <> 1 Then Return 0
    outputText &= Chr(10) & "End " & compoundName
    Return -1
End Function

Private Function TranslateGenericMacroRecordDefinition( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceStatement As String, ByVal sourceMacroName As String, _
    ByRef outputText As String _
) As Long
    outputText = ""
    sourceStatement = Trim(sourceStatement)
    If Right(sourceStatement, 1) = ";" Then _
        sourceStatement = RTrim(Left(sourceStatement, Len(sourceStatement) - 1))
    Dim isTypedef As Long = 0
    If LCase(Left(sourceStatement, 7)) = "typedef" AndAlso _
       (Len(sourceStatement) = 7 OrElse _
        IsSpaceByte(Asc(sourceStatement, 8)) <> 0) Then
        sourceStatement = LTrim(Mid(sourceStatement, 8))
        isTypedef = -1
    End If
    Dim recordKind As C2fbRecordKind
    Dim keywordLength As Long
    Dim loweredStatement As String = LCase(sourceStatement)
    If Left(loweredStatement, 6) = "struct" AndAlso _
       (Len(sourceStatement) = 6 OrElse _
        IsSpaceByte(Asc(sourceStatement, 7)) <> 0) Then
        recordKind = C2FB_RECORD_STRUCT
        keywordLength = 6
    ElseIf Left(loweredStatement, 5) = "union" AndAlso _
           (Len(sourceStatement) = 5 OrElse _
            IsSpaceByte(Asc(sourceStatement, 6)) <> 0) Then
        recordKind = C2FB_RECORD_UNION
        keywordLength = 5
    Else
        Return 0
    End If

    Dim position As Long = keywordLength + 1
    While position <= Len(sourceStatement) AndAlso _
          IsSpaceByte(Asc(sourceStatement, position)) <> 0
        position += 1
    Wend
    Dim recordTag As String
    If position <= Len(sourceStatement) AndAlso _
       IsIdentifierStart(Asc(sourceStatement, position)) <> 0 Then
        Dim tagStart As Long = position
        position += 1
        While position <= Len(sourceStatement) AndAlso _
              IsIdentifierPart(Asc(sourceStatement, position)) <> 0
            position += 1
        Wend
        recordTag = Mid(sourceStatement, tagStart, position - tagStart)
    End If
    While position <= Len(sourceStatement) AndAlso _
          IsSpaceByte(Asc(sourceStatement, position)) <> 0
        position += 1
    Wend
    If position > Len(sourceStatement) OrElse _
       Asc(sourceStatement, position) <> Asc("{") Then Return 0
    Dim recordEnd As Long = position
    If ScanSimpleExpressionGroup( _
        sourceStatement, recordEnd, Asc("{"), Asc("}")) = 0 Then Return 0
    Dim recordAlias As String = Trim(Mid(sourceStatement, recordEnd))
    If recordAlias <> "" AndAlso IsIdentifierToken(recordAlias) = 0 Then Return 0
    If recordTag = "" Then recordTag = recordAlias
    If recordTag = "" Then Return 0

    Dim declaration As C2fbDeclarationModel
    declaration.entryKind = C2FB_DECLARATION_RECORD
    declaration.recordKind = recordKind
    declaration.recordTag = recordTag
    declaration.recordAlias = recordAlias
    declaration.isTypedef = isTypedef
    declaration.recordPrefix = Left(sourceStatement, position - 1)
    declaration.recordBody = Mid( _
        sourceStatement, position + 1, recordEnd - position - 2)
    declaration.sourceSpan.startLocation = _
        translation.sourceUnit.diagnosticState.currentSourceLocation
    declaration.sourceSpan.endLocation = _
        translation.sourceUnit.diagnosticState.currentSourceLocation
    BuildC2fbRecordFieldSources(declaration)
    If declaration.recordFieldsComplete = 0 OrElse _
       declaration.recordFieldCount = 0 Then Return 0

    Dim recordPlan As C2fbGenericRecordPlanModel
    Dim macroIndex As Long = _
        GenericHeaderMacroIndexInContext(translation, sourceMacroName)
    If macroIndex < 0 Then macroIndex = translation.genericC.header.headerMacroCount
    recordPlan.sourceDeclarationIndex = _
        translation.sourceUnit.declarationCount + macroIndex
    recordPlan.isPrepared = -1
    recordPlan.isSupported = -1
    ReDim recordPlan.nestedBindings(0 To 7)

    Dim typeNames(0 To 7) As String
    Dim typeNameCount As Long = 0
    Dim outputNames(0 To 15) As String
    Dim outputNameCount As Long = 0
    Dim typeSourceName As String = sourceMacroName & "_" & recordTag
    recordPlan.freeBasicName = GenericFreeBasicTypeNameInPolicy( _
        translation, typeSourceName, typeNames(), _
        typeNameCount, outputNames(), outputNameCount)
    outputNames(outputNameCount) = recordPlan.freeBasicName
    outputNameCount += 1

    Dim fields() As GenericRecordField
    Dim fieldCount As Long
    If ParseGenericRecordFields( _
        translation, catalog, declaration, recordPlan, outputNames(), _
        outputNameCount, fields(), fieldCount, recordTag, recordAlias) = 0 OrElse _
       fieldCount = 0 Then Return 0

    For nestedIndex As Long = 0 To recordPlan.nestedBindingCount - 1
        Dim nestedText As String
        If GenericMacroRecordBindingText( _
            recordPlan.nestedBindings(nestedIndex), nestedText) = 0 Then Return 0
        If outputText <> "" Then outputText &= Chr(10)
        outputText &= nestedText
    Next

    Dim outerBinding As C2fbRecordBindingModel
    outerBinding.freeBasicName = recordPlan.freeBasicName
    outerBinding.isUnion = CInt(recordKind = C2FB_RECORD_UNION) * -1
    outerBinding.itemCount = fieldCount
    ReDim outerBinding.items(0 To fieldCount - 1)
    For fieldIndex As Long = 0 To fieldCount - 1
        With outerBinding.items(fieldIndex)
            .kind = fields(fieldIndex).itemKind
            .isUnion = fields(fieldIndex).isUnion
            .isBitField = fields(fieldIndex).isBitField
            .bitWidth = fields(fieldIndex).bitWidth
            .name = fields(fieldIndex).name
            .sourceName = fields(fieldIndex).sourceName
            .fieldType = fields(fieldIndex).fieldType
            .arrayCount = fields(fieldIndex).arrayCount
            .arrayBounds = fields(fieldIndex).arrayBounds
            .zeroArrayAccessorName = fields(fieldIndex).zeroArrayAccessorName
            .zeroArrayPreviousFieldName = _
                fields(fieldIndex).zeroArrayPreviousFieldName
            .zeroArrayPreviousArrayCount = _
                fields(fieldIndex).zeroArrayPreviousArrayCount
        End With
    Next
    Dim outerText As String
    If GenericMacroRecordBindingText(outerBinding, outerText) = 0 Then Return 0
    If outputText <> "" Then outputText &= Chr(10)
    outputText &= outerText
    If recordTag <> "" Then
        outputText &= Chr(10) & "Type " & recordTag & " As " & _
            recordPlan.freeBasicName
    End If
    If recordAlias <> "" AndAlso recordAlias <> recordTag Then _
        outputText &= Chr(10) & "Type " & recordAlias & " As " & _
            recordPlan.freeBasicName
    Return -1
End Function

Private Function GenericMacroBodyIsEmptyBlock(ByVal sourceBody As String) As Long
    sourceBody = Trim(sourceBody)
    If sourceBody = ";" Then Return -1
    If Left(sourceBody, 1) <> "{" Then Return 0
    Dim blockEnd As Long = 1
    If ScanSimpleExpressionGroup( _
        sourceBody, blockEnd, Asc("{"), Asc("}")) = 0 OrElse _
       Trim(Mid(sourceBody, blockEnd)) <> "" Then Return 0
    Dim contents As String = Trim(Mid(sourceBody, 2, blockEnd - 3))
    Return CInt(contents = "" OrElse contents = ";") * -1
End Function

Private Function TranslateGenericMacroCondition( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceCondition As String, parameterNames() As String, _
    freeParameterNames() As String, ByVal parameterCount As Long, _
    ByVal isVariadic As Long, ByRef freeBasicCondition As String _
) As Long
    If TranslateGenericHeaderMacroExpressionWithParameters( _
        translation, sourceCondition, freeBasicCondition, parameterNames(), _
        freeParameterNames(), parameterCount) <> 0 Then Return -1
    If TranslateGenericHeaderCondition( _
        translation, sourceCondition, freeBasicCondition, 0) <> 0 Then Return -1
    If GenericMacroExpressionTokenSequenceSupported( _
        translation, sourceCondition, parameterNames(), freeParameterNames(), _
        parameterCount, isVariadic, -1) = 0 Then Return 0
    Return TranslateGenericMacroTokenSequence( _
        translation, sourceCondition, parameterNames(), freeParameterNames(), _
        parameterCount, isVariadic, freeBasicCondition)
End Function

Private Function TranslateGenericStatementMacroBlock( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceBody As String, parameterNames() As String, _
    freeParameterNames() As String, ByVal parameterCount As Long, _
    ByVal isVariadic As Long, ByRef freeBasicBlockBody As String, _
    ByVal dropSingleStatementScope As Long = 0, _
    ByVal integerDivisionAssumed As Long = 0, _
    ByVal sourceMacroName As String = "", _
    ByVal allowUnparenthesizedCommaSequence As Long = 0 _
) As Long
    sourceBody = Trim(sourceBody)
    Dim hasOuterParenthesizedExpression As Long = 0
    If Left(sourceBody, 1) = "(" Then
        Dim outerExpressionEnd As Long = 1
        If ScanSimpleExpressionGroup( _
            sourceBody, outerExpressionEnd, Asc("("), Asc(")")) <> 0 AndAlso _
           Trim(Mid(sourceBody, outerExpressionEnd)) = "" Then _
            hasOuterParenthesizedExpression = -1
    End If
    Dim hasBlockWrapper As Long = 0
    If Left(sourceBody, 1) = "{" Then
        Dim blockEnd As Long = 1
        If ScanSimpleExpressionGroup( _
            sourceBody, blockEnd, Asc("{"), Asc("}")) = 0 Then Return -1
        Dim blockTail As String = Trim(Mid(sourceBody, blockEnd))
        If blockTail <> "" AndAlso blockTail <> ";" Then Return -1
        sourceBody = Trim(Mid(sourceBody, 2, blockEnd - 3))
        hasBlockWrapper = -1
    ElseIf Len(sourceBody) >= 2 AndAlso LCase(Left(sourceBody, 2)) = "do" Then
        Dim innerBody As String
        If StripGenericZeroLoopMacroBody(sourceBody, innerBody) <> 0 Then
            sourceBody = innerBody
            hasBlockWrapper = -1
        End If
    End If
    sourceBody = GenericMacroStripOuterParentheses(sourceBody)
    For castDepth As Long = 0 To MAX_GENERIC_MACRO_EXPRESSION_DEPTH - 1
        Dim voidOperand As String
        If StripGenericVoidCastExpression(sourceBody, voidOperand) = 0 Then Exit For
        sourceBody = GenericMacroStripOuterParentheses(voidOperand)
        hasBlockWrapper = -1
    Next

    If Len(sourceBody) >= 2 AndAlso LCase(Left(sourceBody, 2)) = "if" AndAlso _
       (Len(sourceBody) = 2 OrElse _
        IsIdentifierPart(Asc(sourceBody, 3)) = 0) Then
        Dim conditionOpen As Long = 3
        While conditionOpen <= Len(sourceBody) AndAlso _
              IsSpaceByte(Asc(sourceBody, conditionOpen)) <> 0
            conditionOpen += 1
        Wend
        If conditionOpen > Len(sourceBody) OrElse _
           Asc(sourceBody, conditionOpen) <> Asc("(") Then Return -1
        Dim conditionClose As Long = conditionOpen
        If ScanSimpleExpressionGroup( _
            sourceBody, conditionClose, Asc("("), Asc(")")) = 0 Then Return -1
        Dim conditionText As String = Trim(Mid( _
            sourceBody, conditionOpen + 1, _
            conditionClose - conditionOpen - 2))
        If conditionText = "" Then Return -1

        Dim thenSource As String
        Dim remainingSource As String
        If ReadGenericMacroConditionalBranch( _
            Mid(sourceBody, conditionClose), thenSource, remainingSource) = 0 Then _
            Return -1
        Dim elseSource As String
        Dim hasElse As Long = 0
        If Len(remainingSource) >= 4 AndAlso _
           LCase(Left(remainingSource, 4)) = "else" AndAlso _
           (Len(remainingSource) = 4 OrElse _
            IsIdentifierPart(Asc(remainingSource, 5)) = 0) Then
            If ReadGenericMacroConditionalBranch( _
                Trim(Mid(remainingSource, 5)), elseSource, remainingSource) = 0 Then _
                Return -1
            hasElse = -1
        End If
        If remainingSource <> "" AndAlso remainingSource <> ";" Then Return -1

        Dim freeBasicCondition As String
        If TranslateGenericMacroCondition( _
            translation, conditionText, parameterNames(), freeParameterNames(), _
            parameterCount, isVariadic, freeBasicCondition) = 0 Then Return -1

        Dim freeBasicThen As String
        Dim thenStatus As Long = 1
        If GenericMacroBodyIsEmptyBlock(thenSource) = 0 Then
            thenStatus = TranslateGenericStatementMacroBlock( _
                translation, catalog, thenSource, parameterNames(), _
                freeParameterNames(), parameterCount, isVariadic, _
                freeBasicThen, -1, integerDivisionAssumed, sourceMacroName, _
                allowUnparenthesizedCommaSequence)
        End If
        If thenStatus <= 0 Then Return -1

        Dim freeBasicElse As String
        If hasElse <> 0 AndAlso _
           GenericMacroBodyIsEmptyBlock(elseSource) = 0 Then
            If TranslateGenericStatementMacroBlock( _
                translation, catalog, elseSource, parameterNames(), _
                freeParameterNames(), parameterCount, isVariadic, _
                freeBasicElse, -1, integerDivisionAssumed, sourceMacroName, _
                allowUnparenthesizedCommaSequence) <= 0 Then Return -1
        End If

        Dim freeBasicIf As String = "If " & freeBasicCondition & " Then"
        If freeBasicThen <> "" Then _
            freeBasicIf &= Chr(10) & IndentGenericMacroBlockText( _
                freeBasicThen, "    ")
        If hasElse <> 0 Then
            freeBasicIf &= Chr(10) & "Else"
            If freeBasicElse <> "" Then _
                freeBasicIf &= Chr(10) & IndentGenericMacroBlockText( _
                    freeBasicElse, "    ")
        End If
        freeBasicIf &= Chr(10) & "End If"
        If dropSingleStatementScope = 0 Then
            freeBasicBlockBody = "Scope" & Chr(10) & _
                IndentGenericMacroBlockText(freeBasicIf, "    ") & _
                Chr(10) & "End Scope"
        Else
            freeBasicBlockBody = freeBasicIf
        End If
        Return 1
    End If

    Dim loopKind As Long = 0
    Dim loopConditionText As String
    Dim loopBodySource As String
    Dim loopTail As String
    If Len(sourceBody) >= 5 AndAlso LCase(Left(sourceBody, 5)) = "while" AndAlso _
       (Len(sourceBody) = 5 OrElse IsIdentifierPart(Asc(sourceBody, 6)) = 0) Then
        loopKind = 1
        Dim loopConditionOpen As Long = 6
        While loopConditionOpen <= Len(sourceBody) AndAlso _
              IsSpaceByte(Asc(sourceBody, loopConditionOpen)) <> 0
            loopConditionOpen += 1
        Wend
        If loopConditionOpen > Len(sourceBody) OrElse _
           Asc(sourceBody, loopConditionOpen) <> Asc("(") Then Return -1
        Dim loopConditionClose As Long = loopConditionOpen
        If ScanSimpleExpressionGroup( _
            sourceBody, loopConditionClose, Asc("("), Asc(")")) = 0 Then Return -1
        loopConditionText = Trim(Mid( _
            sourceBody, loopConditionOpen + 1, _
            loopConditionClose - loopConditionOpen - 2))
        If loopConditionText = "" OrElse ReadGenericMacroConditionalBranch( _
            Mid(sourceBody, loopConditionClose), loopBodySource, loopTail) = 0 Then _
            Return -1
        If loopTail <> "" AndAlso loopTail <> ";" Then Return -1
    ElseIf Len(sourceBody) >= 2 AndAlso LCase(Left(sourceBody, 2)) = "do" AndAlso _
           (Len(sourceBody) = 2 OrElse IsIdentifierPart(Asc(sourceBody, 3)) = 0) Then
        loopKind = 2
        Dim loopBodyStart As Long = 3
        While loopBodyStart <= Len(sourceBody) AndAlso _
              IsSpaceByte(Asc(sourceBody, loopBodyStart)) <> 0
            loopBodyStart += 1
        Wend
        If ReadGenericMacroConditionalBranch( _
            Mid(sourceBody, loopBodyStart), loopBodySource, loopTail) = 0 Then _
            Return -1
        loopTail = Trim(loopTail)
        If Len(loopTail) < 5 OrElse LCase(Left(loopTail, 5)) <> "while" OrElse _
           (Len(loopTail) > 5 AndAlso IsIdentifierPart(Asc(loopTail, 6)) <> 0) Then _
            Return -1
        Dim loopConditionOpen As Long = 6
        While loopConditionOpen <= Len(loopTail) AndAlso _
              IsSpaceByte(Asc(loopTail, loopConditionOpen)) <> 0
            loopConditionOpen += 1
        Wend
        If loopConditionOpen > Len(loopTail) OrElse _
           Asc(loopTail, loopConditionOpen) <> Asc("(") Then Return -1
        Dim loopConditionClose As Long = loopConditionOpen
        If ScanSimpleExpressionGroup( _
            loopTail, loopConditionClose, Asc("("), Asc(")")) = 0 Then Return -1
        loopConditionText = Trim(Mid( _
            loopTail, loopConditionOpen + 1, _
            loopConditionClose - loopConditionOpen - 2))
        Dim remainingLoopTail As String = Trim(Mid(loopTail, loopConditionClose))
        If loopConditionText = "" OrElse _
           (remainingLoopTail <> "" AndAlso remainingLoopTail <> ";") Then _
            Return -1
    End If

    If loopKind <> 0 Then
        Dim freeBasicLoopCondition As String
        If TranslateGenericMacroCondition( _
            translation, loopConditionText, parameterNames(), _
            freeParameterNames(), parameterCount, isVariadic, _
            freeBasicLoopCondition) = 0 Then Return -1
        Dim freeBasicLoopBody As String
        If GenericMacroBodyIsEmptyBlock(loopBodySource) = 0 Then
            If TranslateGenericStatementMacroBlock( _
                translation, catalog, loopBodySource, parameterNames(), _
                freeParameterNames(), parameterCount, isVariadic, _
                freeBasicLoopBody, -1, integerDivisionAssumed, sourceMacroName, _
                allowUnparenthesizedCommaSequence) <= 0 Then Return -1
        End If

        Dim freeBasicLoop As String
        If loopKind = 1 Then
            freeBasicLoop = "While " & freeBasicLoopCondition
            If freeBasicLoopBody <> "" Then _
                freeBasicLoop &= Chr(10) & IndentGenericMacroBlockText( _
                    freeBasicLoopBody, "    ")
            freeBasicLoop &= Chr(10) & "Wend"
        Else
            freeBasicLoop = "Do"
            If freeBasicLoopBody <> "" Then _
                freeBasicLoop &= Chr(10) & IndentGenericMacroBlockText( _
                    freeBasicLoopBody, "    ")
            freeBasicLoop &= Chr(10) & "Loop While " & freeBasicLoopCondition
        End If
        If dropSingleStatementScope = 0 Then
            freeBasicBlockBody = "Scope" & Chr(10) & _
                IndentGenericMacroBlockText(freeBasicLoop, "    ") & _
                Chr(10) & "End Scope"
        Else
            freeBasicBlockBody = freeBasicLoop
        End If
        Return 1
    End If

    Dim statementParts() As String
    Dim statementCount As Long
    Dim hasSemicolon As Long
    If SplitGenericMacroStatementSequence( _
        sourceBody, statementParts(), statementCount, hasSemicolon) = 0 Then Return -1
    If statementCount = 0 Then Return CInt(hasBlockWrapper <> 0) * -1

    If parameterCount < 0 OrElse parameterCount >= MAX_SIMPLE_VARIABLES Then _
        Return -1
    Dim macroSymbolNames(0 To MAX_SIMPLE_VARIABLES - 1) As String
    Dim macroSymbolAliases(0 To MAX_SIMPLE_VARIABLES - 1) As String
    Dim macroSymbolTypes(0 To MAX_SIMPLE_VARIABLES - 1) As String
    For parameterIndex As Long = 0 To parameterCount - 1
        macroSymbolNames(parameterIndex) = parameterNames(parameterIndex)
        macroSymbolAliases(parameterIndex) = freeParameterNames(parameterIndex)
    Next
    Dim macroSymbolCount As Long = parameterCount
    Dim macroBodyContext As SimpleBodyContext
    macroBodyContext.scopeDepth = 1
    macroBodyContext.scopeSymbols(0) = 0
    Dim macroLocals(0 To MAX_SIMPLE_VARIABLES - 1) As SimpleLocalVariable
    Dim macroLocalCount As Long = 0
    Dim noCallableNames(0 To 0) As String
    Dim declarationStatements(0 To MAX_SIMPLE_VARIABLES - 1) As Long
    Dim hasLocalDeclarations As Long = 0
    Dim hasCommaOperator As Long = 0
    Dim hasAssignmentOperator As Long = 0
    Dim commaParts() As String
    Dim commaPartCount As Long
    For statementIndex As Long = 0 To statementCount - 1
        If GenericMacroLocalDeclarationCandidate( _
            translation, catalog, statementParts(statementIndex)) <> 0 Then
            declarationStatements(statementIndex) = -1
            hasLocalDeclarations = -1
            Continue For
        End If
        If SplitSimpleCList( _
            statementParts(statementIndex), commaParts(), commaPartCount) = 0 Then Return -1
        If commaPartCount > 1 Then hasCommaOperator = -1
        For commaIndex As Long = 0 To commaPartCount - 1
            Dim assignmentOperator As String
            Dim assignmentPosition As Long
            Dim assignmentStatus As Long = FindGenericMacroAssignmentOperator( _
                commaParts(commaIndex), assignmentOperator, assignmentPosition)
            If assignmentStatus < 0 Then Return -1
            If assignmentStatus > 0 Then hasAssignmentOperator = -1
        Next
    Next
    If hasCommaOperator <> 0 AndAlso hasSemicolon = 0 AndAlso _
       hasBlockWrapper = 0 AndAlso hasOuterParenthesizedExpression = 0 AndAlso _
       dropSingleStatementScope = 0 AndAlso _
       allowUnparenthesizedCommaSequence = 0 Then Return 0
    If hasBlockWrapper = 0 AndAlso hasSemicolon = 0 AndAlso _
       statementCount <= 1 AndAlso hasCommaOperator = 0 AndAlso _
       hasAssignmentOperator = 0 Then Return 0

    Dim translatedStatements As String
    For statementIndex As Long = 0 To statementCount - 1
        If declarationStatements(statementIndex) <> 0 Then
            Dim declarationOutput As String
            If statementCount = 1 AndAlso TranslateGenericMacroRecordDefinition( _
                translation, catalog, statementParts(statementIndex), _
                sourceMacroName, declarationOutput) <> 0 Then
                hasLocalDeclarations = -1
            Else
                If TranslateSimpleDeclarationStatement( _
                    translation, catalog, statementParts(statementIndex), _
                    declarationOutput, macroBodyContext, macroLocals(), _
                    macroLocalCount, noCallableNames(), 0, macroSymbolNames(), _
                    macroSymbolAliases(), macroSymbolTypes(), macroSymbolCount) = 0 Then _
                    Return -1
            End If
            If declarationOutput <> "" Then
                If translatedStatements <> "" Then translatedStatements &= Chr(10)
                Dim outputLineStart As Long = 1
                While outputLineStart <= Len(declarationOutput)
                    Dim outputLineEnd As Long = InStr( _
                        outputLineStart, declarationOutput, Chr(10))
                    If outputLineEnd = 0 Then _
                        outputLineEnd = Len(declarationOutput) + 1
                    translatedStatements &= "    " & Mid( _
                        declarationOutput, outputLineStart, _
                        outputLineEnd - outputLineStart)
                    If outputLineEnd <= Len(declarationOutput) Then _
                        translatedStatements &= Chr(10)
                    outputLineStart = outputLineEnd + 1
                Wend
            End If
            Continue For
        End If
        If SplitSimpleCList( _
            statementParts(statementIndex), commaParts(), commaPartCount) = 0 Then Return -1
        For commaIndex As Long = 0 To commaPartCount - 1
            Dim freeBasicStatement As String
            Dim statementStatus As Long = TranslateGenericMacroStatementExpression( _
                translation, commaParts(commaIndex), macroSymbolNames(), _
                macroSymbolAliases(), macroSymbolCount, isVariadic, _
                freeBasicStatement, integerDivisionAssumed)
            If statementStatus = 0 Then Return -1
            If freeBasicStatement = "" Then Continue For
            If translatedStatements <> "" Then translatedStatements &= Chr(10)
            translatedStatements &= "    " & freeBasicStatement
        Next
    Next
    If translatedStatements = "" Then
        If hasCommaOperator = 0 OrElse hasLocalDeclarations <> 0 Then Return -1
        freeBasicBlockBody = ""
        Return 1
    End If
    translatedStatements = macroBodyContext.declarations & translatedStatements
    If dropSingleStatementScope <> 0 AndAlso hasLocalDeclarations = 0 AndAlso _
       statementCount = 1 AndAlso _
       hasCommaOperator = 0 Then
        freeBasicBlockBody = Trim(Mid(translatedStatements, 5))
        Return 1
    End If
    freeBasicBlockBody = "Scope" & Chr(10) & translatedStatements & _
        Chr(10) & "End Scope"
    Return 1
End Function

Private Function TranslateGenericStringizingMacro( _
    ByVal body As String, parameterNames() As String, _
    freeParameterNames() As String, ByVal parameterCount As Long, _
    ByVal isVariadic As Long, ByRef freeBasicExpression As String _
) As Long
    ' Keep stringizing as a macro operation so FBC sees the original invocation tokens.
    body = GenericMacroStripOuterParentheses(body)
    If Left(body, 1) <> "#" Then Return 0
    Dim sourceParameter As String = Trim(Mid(body, 2))
    If IsIdentifierToken(sourceParameter) = 0 Then Return 0

    For parameterIndex As Long = 0 To parameterCount - 1
        If parameterNames(parameterIndex) = sourceParameter Then
            If sourceParameter = "__VA_ARGS__" AndAlso isVariadic = 0 Then Return 0
            freeBasicExpression = "#" & freeParameterNames(parameterIndex)
            Return -1
        End If
    Next
    Return 0
End Function

Private Function TranslateGenericTokenPasteMacro( _
    ByRef translation As C2fbTranslationContext, ByVal body As String, _
    parameterNames() As String, freeParameterNames() As String, _
    ByVal parameterCount As Long, _
    ByRef freeBasicExpression As String _
) As Long
    body = GenericMacroStripOuterParentheses(body)
    If body = "" Then Return 0

    Dim translated As String
    Dim pastedTokens(0 To MAX_TYPE_WORDS - 1) As String
    Dim pastedTokenCount As Long = 0
    Dim position As Long = 1
    Dim expectsIdentifier As Long = -1
    Dim pasteCount As Long = 0
    While position <= Len(body)
        While position <= Len(body) AndAlso _
              IsSpaceByte(Asc(body, position)) <> 0
            position += 1
        Wend
        If position > Len(body) Then Exit While

        If expectsIdentifier <> 0 Then
            If IsIdentifierStart(Asc(body, position)) = 0 Then Return 0
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(body) AndAlso _
                  IsIdentifierPart(Asc(body, position)) <> 0
                position += 1
            Wend
            Dim sourceParameter As String = Mid( _
                body, tokenStart, position - tokenStart)
            Dim parameterIndex As Long = -1
            For candidateIndex As Long = 0 To parameterCount - 1
                If parameterNames(candidateIndex) = sourceParameter Then
                    parameterIndex = candidateIndex
                    Exit For
                End If
            Next
            If pastedTokenCount >= MAX_TYPE_WORDS Then Return 0
            If parameterIndex < 0 Then
                pastedTokens(pastedTokenCount) = sourceParameter
            Else
                pastedTokens(pastedTokenCount) = freeParameterNames(parameterIndex)
            End If
            pastedTokenCount += 1
            expectsIdentifier = 0
        Else
            If Mid(body, position, 2) <> "##" Then Return 0
            position += 2
            expectsIdentifier = -1
            pasteCount += 1
        End If
    Wend
    If expectsIdentifier <> 0 OrElse pasteCount = 0 OrElse _
       pastedTokenCount < 2 Then Return 0

    ' Token pastes form a C identifier that must use C2FB's generated symbol
    ' prefix before FreeBASIC resolves its corresponding binding.
    translated = translation.genericC.policy.generatedNamePrefix & "##"
    For tokenIndex As Long = 0 To pastedTokenCount - 1
        If tokenIndex > 0 Then translated &= "##"
        translated &= pastedTokens(tokenIndex)
    Next
    freeBasicExpression = translated
    Return -1
End Function

Private Function GenericFunctionMacroBodySupported( _
    ByVal body As String, ByVal isVariadic As Long, _
    ByVal integerDivisionAssumed As Long = 0 _
) As Long
    Dim normalizedBody As String
    If RewriteGenericMacroCharacterConstants(body, normalizedBody) = 0 Then Return 0
    If isVariadic <> 0 AndAlso InStr(normalizedBody, "__VA_ARGS__") <> 0 Then
        If GenericMacroStripOuterParentheses(normalizedBody) = "__VA_ARGS__" Then Return -1
        Return 0
    End If
    If GenericIntegerMacroCandidate(normalizedBody) = 0 OrElse _
       InStr(normalizedBody, ",") <> 0 OrElse _
       GenericMacroHasUnsupportedUnaryPointerOperator(normalizedBody) <> 0 Then Return 0
    If integerDivisionAssumed = 0 AndAlso _
       (InStr(normalizedBody, "/") <> 0 OrElse _
        InStr(normalizedBody, "%") <> 0) Then Return 0
    Return -1
End Function

Private Sub GenericMacroOuterTokenRange( _
    tokens() As String, ByVal tokenCount As Long, _
    ByRef firstToken As Long, ByRef lastToken As Long _
)
    firstToken = 0
    lastToken = tokenCount - 1
    While firstToken <= lastToken AndAlso tokens(firstToken) = "("
        Dim depth As Long = 0
        Dim quote As String
        Dim escaped As Long = 0
        Dim closesAtEnd As Long = 0
        For tokenIndex As Long = firstToken To lastToken
            If quote <> "" Then
                If escaped <> 0 Then
                    escaped = 0
                ElseIf tokens(tokenIndex) = Chr(92) Then
                    escaped = -1
                ElseIf tokens(tokenIndex) = quote Then
                    quote = ""
                End If
                Continue For
            End If
            If tokens(tokenIndex) = "'" OrElse tokens(tokenIndex) = Chr(34) Then
                quote = tokens(tokenIndex)
            ElseIf tokens(tokenIndex) = "(" Then
                depth += 1
            ElseIf tokens(tokenIndex) = ")" Then
                depth -= 1
                If depth < 0 Then Exit For
                If depth = 0 Then
                    closesAtEnd = CInt(tokenIndex = lastToken)
                    Exit For
                End If
            End If
        Next
        If closesAtEnd = 0 Then Exit While
        firstToken += 1
        lastToken -= 1
    Wend
End Sub

Private Function GenericFunctionPointerTypeMacroValue( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long, _
    ByRef freeBasicType As String _
) As Long
    freeBasicType = ""
    For pointerOpen As Long = firstToken To lastToken - 3
        If tokens(pointerOpen) <> "(" OrElse _
           tokens(pointerOpen + 1) <> "*" OrElse _
           tokens(pointerOpen + 2) <> ")" OrElse _
           tokens(pointerOpen + 3) <> "(" Then Continue For

        Dim callbackTokens() As String
        ReDim callbackTokens(0 To lastToken - firstToken + 4)
        Dim callbackTokenCount As Long = 0
        For tokenIndex As Long = firstToken To pointerOpen
            callbackTokens(callbackTokenCount) = tokens(tokenIndex)
            callbackTokenCount += 1
        Next
        callbackTokens(callbackTokenCount) = "*"
        callbackTokenCount += 1
        callbackTokens(callbackTokenCount) = "c2fb_macro_callback"
        callbackTokenCount += 1
        callbackTokens(callbackTokenCount) = ")"
        callbackTokenCount += 1
        For tokenIndex As Long = pointerOpen + 3 To lastToken
            callbackTokens(callbackTokenCount) = tokens(tokenIndex)
            callbackTokenCount += 1
        Next

        Dim callbackResult As C2fbCallbackTypeResultModel
        ResolveCBodyCallbackTypeInContext( _
            translation, catalog, callbackTokens(), 0, _
            callbackTokenCount - 1, callbackResult, 0, _
            C2FB_TYPE_MAPPING_GENERIC_HEADER)
        If callbackResult.status <> C2FB_CALLBACK_TYPE_CONVERTED Then Return 0
        freeBasicType = CBodyCallbackDeclarationInContext( _
            translation, callbackResult.freeBasicType)
        Return CInt(freeBasicType <> "") * -1
    Next
    Return 0
End Function

Private Function GenericTypeMacroValue( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef macro As C2fbMacroDefinitionModel, ByRef freeBasicType As String _
) As Long
    If macro.tokenCount = 0 OrElse macro.tokenCount >= MAX_TYPE_WORDS Then Return 0
    Dim firstToken As Long
    Dim lastToken As Long
    GenericMacroOuterTokenRange( _
        macro.tokens(), macro.tokenCount, firstToken, lastToken)
    If firstToken > lastToken OrElse lastToken - firstToken + 1 >= MAX_TYPE_WORDS Then Return 0
    If GenericFunctionPointerTypeMacroValue( _
        translation, catalog, macro.tokens(), firstToken, lastToken, _
        freeBasicType) <> 0 Then Return -1
    Dim hasTypeSpecifier As Long = 0
    Dim expectsTagName As Long = 0
    For tokenIndex As Long = firstToken To lastToken
        If expectsTagName <> 0 Then
            If IsIdentifierToken(macro.tokens(tokenIndex)) = 0 Then Return 0
            expectsTagName = 0
            Continue For
        End If
        Select Case macro.tokens(tokenIndex)
        Case "*", "const", "volatile", "restrict", "__restrict", "__restrict__"
            Continue For
        Case "struct", "union", "enum"
            hasTypeSpecifier = -1
            expectsTagName = -1
        Case "void", "char", "signed", "unsigned", "short", "int", "long", _
             "float", "double", "_Bool", "bool", "size_t", "uintptr_t", _
             "ptrdiff_t", "int8_t", "uint8_t", "int16_t", "uint16_t", _
             "int32_t", "uint32_t", "int64_t", "uint64_t", "va_list", _
             "__gnuc_va_list", "__builtin_va_list", "wchar_t", _
             "_Atomic"
            hasTypeSpecifier = -1
        Case Else
            If IsIdentifierToken(macro.tokens(tokenIndex)) = 0 Then Return 0
            Dim aliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
                translation.genericC.header, macro.tokens(tokenIndex), 0)
            If aliasIndex >= 0 AndAlso translation.genericC.header.headerTypeAliases(aliasIndex).isArray = 0 Then
                hasTypeSpecifier = -1
            ElseIf GenericTypeOverrideInPolicy( _
                translation.genericC.policy, macro.tokens(tokenIndex)) <> "" Then
                hasTypeSpecifier = -1
            Else
                Return 0
            End If
        End Select
    Next
    If expectsTagName <> 0 OrElse hasTypeSpecifier = 0 Then Return 0

    Dim resolvedMacroType As C2fbResolvedTypeModel
    ResolveC2fbTypeModel(translation, catalog, _
        macro.tokens(), firstToken, lastToken, resolvedMacroType, _
        C2FB_POINTER_MAPPING_OPAQUE, C2FB_TYPE_MAPPING_GENERIC_HEADER)
    If resolvedMacroType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Return 0
    freeBasicType = resolvedMacroType.freeBasicType
    If freeBasicType = "" OrElse freeBasicType = "void" Then Return 0
    Return -1
End Function

/' end of c2fb_generic_macro_lowering.bi '/
