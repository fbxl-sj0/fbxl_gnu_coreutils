/'
    Project: C2FB generic header converter

    File: c2fb_generic_declarations.bi

    Purpose:

        Lower plain generic C declarations into external FreeBASIC bindings.

    Responsibilities:

        - Consume shared declaration tokens and split multi-object declarations
          by token range.
        - Emit function-type aliases, external objects, and callbacks.
        - Apply generic type, array-size, and string override policy.
        - Report declarations that do not map safely to supported bindings.

    This file intentionally does NOT contain:

        - C record layout preparation or enum constant output.
        - Generic macro collection, lowering, or formatting.
'/

Private Function GenericDeclaratorWithoutInitializer(ByVal declaration As String) As String
    Dim parenDepth As Long = 0
    Dim bracketDepth As Long = 0
    Dim braceDepth As Long = 0
    Dim quoteByte As Long = 0
    For position As Long = 1 To Len(declaration)
        Dim currentByte As Long = Asc(declaration, position)
        If quoteByte <> 0 Then
            If currentByte = Asc("\\") Then
                position += 1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
        ElseIf currentByte = Asc("'") OrElse currentByte = Asc(Chr(34)) Then
            quoteByte = currentByte
        Else
            Select Case currentByte
            Case Asc("("): parenDepth += 1
            Case Asc(")"): parenDepth -= 1
            Case Asc("["): bracketDepth += 1
            Case Asc("]"): bracketDepth -= 1
            Case Asc("{"): braceDepth += 1
            Case Asc("}"): braceDepth -= 1
            Case Asc("=")
                If parenDepth = 0 AndAlso bracketDepth = 0 AndAlso braceDepth = 0 Then _
                    Return Trim(Left(declaration, position - 1))
            End Select
        End If
    Next
    Return Trim(declaration)
End Function

Declare Function GenericHeaderPlainDeclaratorRemoved( _
    ByRef sourceDeclaration As C2fbDeclarationModel, ByVal sourceName As String _
) As Long

Declare Function ParseGenericHeaderDeclaratorTokens( _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long, _
    ByRef commonType As String, ByRef sourceName As String, _
    ByRef bindingOrder As String, ByRef commonTypeTokenCount As Long _
) As Long

Private Function ParseGenericHeaderDeclarator( _
    ByVal declaration As String, ByRef commonType As String, _
    ByRef sourceName As String, ByRef bindingOrder As String _
) As Long
    commonType = ""
    sourceName = ""
    bindingOrder = ""
    declaration = GenericDeclaratorWithoutInitializer( _
        StripCFunctionAttributes(declaration))
    If declaration = "" Then Return 0

    Dim tokens() As String
    Dim tokenCount As Long
    Dim commonTypeTokenCount As Long
    TokenizeCDeclaration(declaration, tokens(), tokenCount)
    Return ParseGenericHeaderDeclaratorTokens( _
        tokens(), 0, tokenCount - 1, commonType, sourceName, bindingOrder, _
        commonTypeTokenCount)
End Function

Private Function ParseGenericHeaderDeclaratorTokens( _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long, _
    ByRef commonType As String, ByRef sourceName As String, _
    ByRef bindingOrder As String, ByRef commonTypeTokenCount As Long _
) As Long
    commonType = ""
    sourceName = ""
    bindingOrder = ""
    commonTypeTokenCount = 0
    If firstToken < 0 OrElse lastToken < firstToken OrElse _
       lastToken > UBound(tokens) Then Return 0
    If tokens(lastToken) = ";" Then lastToken -= 1
    If lastToken < firstToken + 1 Then Return 0

    ' C object initializers do not contribute to the FreeBASIC binding.
    ' Ignore only a top-level assignment so nested expressions remain intact.
    Dim assignmentToken As Long
    If FindC2fbTopLevelAssignmentToken( _
        tokens(), firstToken, lastToken, assignmentToken) = 0 Then Return 0
    If assignmentToken >= firstToken Then lastToken = assignmentToken - 1
    If lastToken < firstToken + 1 OrElse _
       lastToken - firstToken + 1 >= MAX_TYPE_WORDS Then Return 0

    For declaratorStart As Long = firstToken + 1 To lastToken
        Dim declaratorInsideAtomicType As Long = 0
        Dim atomicSpecifier As Long = firstToken
        While atomicSpecifier <= declaratorStart
            If tokens(atomicSpecifier) = "_Atomic" AndAlso _
               atomicSpecifier < lastToken AndAlso _
               tokens(atomicSpecifier + 1) = "(" Then
                Dim nestingDepth As Long = 1
                Dim closingToken As Long = atomicSpecifier + 2
                While closingToken <= lastToken AndAlso nestingDepth > 0
                    If tokens(closingToken) = "(" Then
                        nestingDepth += 1
                    ElseIf tokens(closingToken) = ")" Then
                        nestingDepth -= 1
                    End If
                    If nestingDepth > 0 Then closingToken += 1
                Wend
                If nestingDepth <> 0 Then Return 0
                If declaratorStart >= atomicSpecifier AndAlso _
                   declaratorStart <= closingToken Then
                    declaratorInsideAtomicType = -1
                    Exit While
                End If
                atomicSpecifier = closingToken + 1
            Else
                atomicSpecifier += 1
            End If
        Wend
        If declaratorInsideAtomicType <> 0 Then Continue For
        If IsCFunctionReturnTypePrefix( _
            tokens(), firstToken, declaratorStart - 1) = 0 Then Continue For
        Dim position As Long = declaratorStart
        Dim candidate As C2fbDeclaratorModel
        If ParseCDeclaratorModel( _
            tokens(), position, lastToken, candidate) = 0 Then Continue For
        If position <> lastToken + 1 OrElse _
           IsIdentifierToken(candidate.name) = 0 OrElse _
           IsCDeclarationSpecifierKeyword(candidate.name) <> 0 Then Continue For
        Dim commonTypeTokens() As String
        ReDim commonTypeTokens(0 To MAX_TYPE_WORDS - 1)
        Dim filteredCommonTypeTokenCount As Long = 0
        For typeToken As Long = firstToken To declaratorStart - 1
            Select Case tokens(typeToken)
            Case "_Thread_local", "__thread", "thread_local"
                Continue For
            End Select
            AddToken(commonTypeTokens(), filteredCommonTypeTokenCount, _
                     tokens(typeToken))
        Next
        commonType = GenericTokensToText( _
            commonTypeTokens(), 0, filteredCommonTypeTokenCount - 1)
        commonTypeTokenCount = declaratorStart - firstToken
        sourceName = candidate.name
        bindingOrder = candidate.bindingOrder
        Return CInt(commonType <> "") * -1
    Next
    Return 0
End Function

Private Function GenericLastIdentifierPosition( _
    ByVal sourceText As String, ByVal identifier As String _
) As Long
    If identifier = "" Then Return 0
    Dim matchPosition As Long = 1
    Dim lastPosition As Long = 0
    While matchPosition <= Len(sourceText)
        matchPosition = InStr(matchPosition, sourceText, identifier)
        If matchPosition = 0 Then Exit While
        Dim beforeIsIdentifier As Long = 0
        Dim afterIsIdentifier As Long = 0
        If matchPosition > 1 Then _
            beforeIsIdentifier = IsIdentifierPart(Asc(sourceText, matchPosition - 1))
        If matchPosition + Len(identifier) <= Len(sourceText) Then _
            afterIsIdentifier = IsIdentifierPart(Asc(sourceText, matchPosition + Len(identifier)))
        If beforeIsIdentifier = 0 AndAlso afterIsIdentifier = 0 Then _
            lastPosition = matchPosition
        matchPosition += Len(identifier)
    Wend
    Return lastPosition
End Function

Private Function ParseGenericArrayBoundsInDeclaration( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceText As String, ByVal identifierEndPosition As Long, _
    ByVal expectedDimensionCount As Long, ByRef arrayBounds As String, _
    ByRef firstDimensionCount As Long, ByRef totalElementCount As Long, _
    ByRef isUnsized As Long, ByVal allowUnsized As Long, _
    ByVal allowZeroLength As Long, _
    ByVal unsizedBoundHint As Long = 0 _
) As Long
    arrayBounds = ""
    firstDimensionCount = 0
    totalElementCount = 1
    isUnsized = 0
    If identifierEndPosition < 1 OrElse _
       identifierEndPosition > Len(sourceText) + 1 OrElse _
       expectedDimensionCount <= 0 OrElse _
       expectedDimensionCount > MAX_GENERIC_ARRAY_RANK Then Return 0

    Dim searchPosition As Long = identifierEndPosition
    For dimensionIndex As Long = 0 To expectedDimensionCount - 1
        Dim openingBracket As Long = InStr(searchPosition, sourceText, "[")
        If openingBracket = 0 Then Return 0
        Dim bracketDepth As Long = 1
        Dim closingBracket As Long = openingBracket + 1
        While closingBracket <= Len(sourceText) AndAlso bracketDepth > 0
            Select Case Mid(sourceText, closingBracket, 1)
            Case "[": bracketDepth += 1
            Case "]": bracketDepth -= 1
            End Select
            closingBracket += 1
        Wend
        If bracketDepth <> 0 Then Return 0
        closingBracket -= 1

        Dim boundExpression As String = Trim(Mid( _
            sourceText, openingBracket + 1, closingBracket - openingBracket - 1))
        Dim dimensionCount As Long = 0
        If boundExpression = "" Then
            If allowUnsized = 0 OrElse dimensionIndex <> 0 Then Return 0
            If unsizedBoundHint > 0 Then
                dimensionCount = unsizedBoundHint
            Else
                If expectedDimensionCount <> 1 Then Return 0
                isUnsized = -1
                totalElementCount = 0
            End If
        ElseIf EvaluateSimpleArrayBound( _
            boundExpression, dimensionCount, MAX_GENERIC_ARRAY_COUNT, _
            allowZeroLength) = 0 AndAlso _
           EvaluateGenericHeaderArrayBound( _
            translation, boundExpression, dimensionCount, _
            MAX_GENERIC_ARRAY_COUNT, allowZeroLength) = 0 Then
            Return 0
        End If
        If isUnsized = 0 Then
            If dimensionIndex = 0 Then firstDimensionCount = dimensionCount
            If dimensionCount = 0 Then
                totalElementCount = 0
            ElseIf totalElementCount > 0 Then
                If totalElementCount > MAX_GENERIC_ARRAY_COUNT \ dimensionCount Then _
                    Return 0
                totalElementCount *= dimensionCount
            End If
            If arrayBounds <> "" Then arrayBounds &= ", "
            arrayBounds &= "0 To " & Trim(Str(dimensionCount - 1))
        End If
        searchPosition = closingBracket + 1
    Next
    If isUnsized <> 0 Then arrayBounds = ""
    Return -1
End Function

Private Function CombineGenericArrayBounds( _
    ByVal firstBounds As String, ByVal secondBounds As String _
) As String
    If firstBounds = "" Then Return secondBounds
    If secondBounds = "" Then Return firstBounds
    Return firstBounds & ", " & secondBounds
End Function

Private Function TranslateGenericModuleStaticArrayDecayInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceName As String, ByVal offsetExpression As String, _
    ByVal targetPointerType As String, ByRef initialValue As String _
) As Long
    initialValue = ""
    If sourceName = "" OrElse targetPointerType = "" Then Return 0
    Dim symbolIndex As Long = _
        GenericHeaderSymbolIndexInContext(translation, sourceName)
    If symbolIndex < 0 Then Return 0
    With translation.symbolTable.symbols(symbolIndex)
        If .kind <> GENERIC_SYMBOL_OBJECT OrElse _
           .genericHeader.arrayCount <= 0 OrElse _
           .genericHeader.unsizedArray <> 0 OrElse _
           .freeBasicName = "" OrElse .genericHeader.freeBasicType = "" Then _
            Return 0
        Dim arrayPointerType As String = .genericHeader.freeBasicType
        If Right(arrayPointerType, 4) <> " Ptr" Then _
            arrayPointerType &= " Ptr"
        Dim arrayAddress As String = _
            "CPtr(" & arrayPointerType & ", @" & .freeBasicName & "(0))"
        If offsetExpression <> "" Then
            Dim offsetOperator As String = Left(LTrim(offsetExpression), 1)
            If offsetOperator <> "+" AndAlso offsetOperator <> "-" Then _
                offsetExpression = "+ " & offsetExpression
            arrayAddress &= " " & offsetExpression
        End If
        initialValue = "CPtr(" & targetPointerType & ", " & _
            arrayAddress & ")"
    End With
    Return -1
End Function

Private Function TranslateGenericModuleStaticAddressInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceText As String, ByVal isCallbackObject As Long, _
    ByVal targetPointerType As String, _
    ByRef initialValue As String, ByVal selfSourceName As String _
) As Long
    initialValue = ""
    sourceText = GenericMacroStripOuterParentheses(Trim(sourceText))
    Dim tokens() As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        sourceText, tokens(), tokenCount) = 0 Then Return 0

    Dim sourceName As String
    Dim isAddressOfObject As Long = 0
    If tokenCount = 2 AndAlso tokens(0) = "&" AndAlso _
       IsIdentifierToken(tokens(1)) <> 0 Then
        sourceName = tokens(1)
        isAddressOfObject = -1
        If selfSourceName <> "" AndAlso sourceName = selfSourceName Then
            initialValue = "CPtr(" & targetPointerType & ", @" & _
                "__C2FB_STATIC_SELF_ADDRESS__" & ")"
            Return -1
        End If
    ElseIf tokenCount >= 5 AndAlso tokens(0) = "&" AndAlso _
           IsIdentifierToken(tokens(1)) <> 0 AndAlso tokens(2) = "[" Then
        sourceName = tokens(1)
        Dim externalObjectIndex As Long = -1
        For objectIndex As Long = 0 To _
            translation.body.externalObjectCount - 1
            With translation.body.externalObjects(objectIndex)
                If .sourceName = sourceName AndAlso .isAmbiguous = 0 Then
                    externalObjectIndex = objectIndex
                    Exit For
                End If
            End With
        Next
        If externalObjectIndex < 0 Then Return 0

        With translation.body.externalObjects(externalObjectIndex)
            If .isArray = 0 OrElse .isUnsizedArray <> 0 OrElse _
               .arrayRank <= 0 OrElse .arrayRank > MAX_GENERIC_ARRAY_RANK Then _
                Return 0

            Dim dimensionExpressions() As String
            Dim dimensionExpressionCount As Long
            If SplitSimpleCList( _
                .arrayDimensions, dimensionExpressions(), _
                dimensionExpressionCount) = 0 OrElse _
               dimensionExpressionCount <> .arrayRank Then Return 0

            Dim subscripts As String
            Dim tokenPosition As Long = 2
            For dimensionIndex As Long = 0 To .arrayRank - 1
                If tokenPosition >= tokenCount OrElse _
                   tokens(tokenPosition) <> "[" Then Return 0
                Dim bracketDepth As Long = 1
                Dim closingBracket As Long = tokenPosition + 1
                While closingBracket < tokenCount AndAlso bracketDepth > 0
                    If tokens(closingBracket) = "[" Then
                        bracketDepth += 1
                    ElseIf tokens(closingBracket) = "]" Then
                        bracketDepth -= 1
                    End If
                    closingBracket += 1
                Wend
                If bracketDepth <> 0 Then Return 0
                closingBracket -= 1
                If closingBracket <= tokenPosition + 1 Then Return 0

                Dim dimensionSize As Long
                If EvaluateGenericHeaderArrayBound( _
                    translation, dimensionExpressions(dimensionIndex), _
                    dimensionSize, MAX_GENERIC_ARRAY_COUNT) = 0 OrElse _
                   dimensionSize <= 0 Then Return 0
                Dim subscriptValue As Long
                Dim subscriptExpression As String = GenericTokensToText( _
                    tokens(), tokenPosition + 1, closingBracket - 1)
                If EvaluateGenericHeaderArrayBound( _
                    translation, subscriptExpression, subscriptValue, _
                    MAX_GENERIC_ARRAY_COUNT, -1) = 0 OrElse _
                   subscriptValue < 0 OrElse subscriptValue >= dimensionSize Then _
                    Return 0

                If dimensionIndex > 0 Then subscripts &= ", "
                subscripts &= Trim(Str(subscriptValue))
                tokenPosition = closingBracket + 1
            Next
            If tokenPosition <> tokenCount Then Return 0

            ' Addressing an element keeps the C pointer tied to the same
            ' storage used by exported records initialized from that array.
            initialValue = "@" & .freeBasicName & "(" & subscripts & ")"
            Return -1
        End With
    ElseIf tokenCount >= 3 AndAlso _
           IsIdentifierToken(tokens(0)) <> 0 AndAlso _
           (tokens(1) = "+" OrElse tokens(1) = "-") Then
        Dim offsetExpression As String = GenericTokensToText( _
            tokens(), 1, tokenCount - 1)
        If offsetExpression = "" Then Return 0
        Return TranslateGenericModuleStaticArrayDecayInitializer( _
            translation, tokens(0), offsetExpression, targetPointerType, initialValue)
    ElseIf tokenCount >= 3 AndAlso _
           IsIdentifierToken(tokens(tokenCount - 1)) <> 0 AndAlso _
           tokens(tokenCount - 2) = "+" Then
        Dim offsetExpression As String = GenericTokensToText( _
            tokens(), 0, tokenCount - 3)
        If offsetExpression = "" Then Return 0
        Return TranslateGenericModuleStaticArrayDecayInitializer( _
            translation, tokens(tokenCount - 1), offsetExpression, _
            targetPointerType, initialValue)
    ElseIf tokenCount = 1 AndAlso isCallbackObject = 0 AndAlso _
           IsIdentifierToken(tokens(0)) <> 0 Then
        Return TranslateGenericModuleStaticArrayDecayInitializer( _
            translation, tokens(0), "", targetPointerType, initialValue)
    ElseIf tokenCount = 1 AndAlso isCallbackObject <> 0 AndAlso _
           IsIdentifierToken(tokens(0)) <> 0 Then
        sourceName = tokens(0)
    Else
        Return 0
    End If

    Dim symbolIndex As Long = _
        GenericHeaderSymbolIndexInContext(translation, sourceName)
    If symbolIndex < 0 AndAlso isAddressOfObject <> 0 Then
        ' Body source units keep external objects in their own translation
        ' context, separate from generic-header declarations. A global
        ' pointer initializer can still take the address of that C object.
        For objectIndex As Long = 0 To _
            translation.body.externalObjectCount - 1
            With translation.body.externalObjects(objectIndex)
                If .sourceName = sourceName AndAlso .isAmbiguous = 0 AndAlso _
                   .freeBasicName <> "" AndAlso .isArray = 0 Then
                    initialValue = "CPtr(" & targetPointerType & ", @" & _
                        .freeBasicName & ")"
                    Return -1
                End If
            End With
        Next
    End If
    If symbolIndex < 0 Then Return 0
    With translation.symbolTable.symbols(symbolIndex)
        Select Case .kind
        Case GENERIC_SYMBOL_FUNCTION, GENERIC_SYMBOL_SUB
            If isCallbackObject = 0 Then Return 0
            initialValue = "ProcPtr(" & .freeBasicName & ")"
        Case GENERIC_SYMBOL_OBJECT
            If isAddressOfObject = 0 Then Return 0
            initialValue = "@" & .freeBasicName
        Case Else
            Return 0
        End Select
    End With
    Return -1
End Function

Private Function ResolveGenericStaticSelfAddressPlaceholder( _
    ByVal sourceText As String, ByVal freeBasicName As String _
) As String
    Const placeholder As String = "__C2FB_STATIC_SELF_ADDRESS__"
    Dim remainingText As String = sourceText
    Dim resolvedText As String
    Dim placeholderPosition As Long = InStr(remainingText, placeholder)
    While placeholderPosition > 0
        resolvedText &= Left(remainingText, placeholderPosition - 1) & _
            freeBasicName
        remainingText = Mid(remainingText, _
            placeholderPosition + Len(placeholder))
        placeholderPosition = InStr(remainingText, placeholder)
    Wend
    Return resolvedText & remainingText
End Function

Private Function ReadGenericStaticStringEscape( _
    ByVal sourceText As String, ByRef position As Long, _
    ByRef byteValue As Long _
) As Long
    position += 1
    If position > Len(sourceText) Then Return 0
    Dim escapedByte As Long = Asc(sourceText, position)
    position += 1
    Select Case escapedByte
    ' Match the GCC extension used by terminal-control strings in RTLIB.
    Case Asc("e"): byteValue = 27
    Case Asc("a"): byteValue = 7
    Case Asc("b"): byteValue = 8
    Case Asc("t"): byteValue = 9
    Case Asc("n"): byteValue = 10
    Case Asc("v"): byteValue = 11
    Case Asc("f"): byteValue = 12
    Case Asc("r"): byteValue = 13
    Case Asc(Chr(92)), Asc("'"), Asc(Chr(34)), Asc("?")
        byteValue = escapedByte
    Case Else
        Dim radix As Long = 8
        Dim maximumDigits As Long = 3
        If escapedByte = Asc("x") Then
            radix = 16
            maximumDigits = Len(sourceText)
        ElseIf escapedByte >= Asc("0") AndAlso escapedByte <= Asc("7") Then
            position -= 1
        Else
            Return 0
        End If
        byteValue = 0
        Dim digitCount As Long = 0
        While position <= Len(sourceText) AndAlso digitCount < maximumDigits
            Dim digit As Long = SimpleDigitValue(Asc(sourceText, position))
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

Private Function ReadGenericStaticStringBytes( _
    ByVal sourceText As String, values() As Long, _
    ByRef byteCount As Long _
) As Long
    byteCount = 0
    sourceText = Trim(sourceText)
    If sourceText = "" Then Return 0

    Dim capacity As Long = 16
    ReDim values(0 To capacity - 1)
    Dim position As Long = 1
    SkipCSpaces(sourceText, position)
    Do
        If position > Len(sourceText) OrElse _
           Asc(sourceText, position) <> Asc(Chr(34)) Then Return 0
        position += 1
        Dim hasClosingQuote As Long = 0
        While position <= Len(sourceText)
            Dim byteValue As Long = Asc(sourceText, position)
            If byteValue = Asc(Chr(34)) Then
                position += 1
                hasClosingQuote = -1
                Exit While
            ElseIf byteValue = Asc(Chr(92)) Then
                If ReadGenericStaticStringEscape( _
                    sourceText, position, byteValue) = 0 Then Return 0
            Else
                If byteValue = 0 OrElse byteValue = 10 OrElse byteValue = 13 Then _
                    Return 0
                position += 1
            End If

            If byteCount >= MAX_C_STRING_LITERAL_BYTES Then Return 0
            If byteCount >= capacity Then
                If capacity > MAX_C_STRING_LITERAL_BYTES \ 2 Then
                    capacity = MAX_C_STRING_LITERAL_BYTES
                Else
                    capacity *= 2
                End If
                ReDim Preserve values(0 To capacity - 1)
            End If
            values(byteCount) = byteValue
            byteCount += 1
        Wend
        If hasClosingQuote = 0 Then Return 0
        SkipCSpaces(sourceText, position)
        If position > Len(sourceText) OrElse _
           Asc(sourceText, position) <> Asc(Chr(34)) Then Exit Do
    Loop
    SkipCSpaces(sourceText, position)
    Return CInt(position > Len(sourceText)) * -1
End Function

Private Function AppendGenericWideCodeUnit( _
    ByVal codeUnit As Long, values() As Long, _
    ByRef codeUnitCount As Long, ByRef capacity As Long _
) As Long
    If codeUnitCount >= MAX_GENERIC_STATIC_INITIALIZER_VALUES Then Return 0
    If codeUnitCount >= capacity Then
        If capacity > MAX_GENERIC_STATIC_INITIALIZER_VALUES \ 2 Then
            capacity = MAX_GENERIC_STATIC_INITIALIZER_VALUES
        Else
            capacity *= 2
        End If
        ReDim Preserve values(0 To capacity - 1)
    End If
    values(codeUnitCount) = codeUnit
    codeUnitCount += 1
    Return -1
End Function

Private Function AppendGenericWideCodePoint( _
    ByVal codePoint As Long, ByVal wcharSize As Long, values() As Long, _
    ByRef codeUnitCount As Long, ByRef capacity As Long _
) As Long
    If codePoint < 0 OrElse codePoint > &H10FFFF OrElse _
       (codePoint >= &HD800 AndAlso codePoint <= &HDFFF) Then Return 0
    If wcharSize = 4 Then
        Return AppendGenericWideCodeUnit( _
            codePoint, values(), codeUnitCount, capacity)
    End If
    If wcharSize <> 2 Then Return 0

    If codePoint <= &HFFFF Then
        Return AppendGenericWideCodeUnit( _
            codePoint, values(), codeUnitCount, capacity)
    End If
    codePoint -= &H10000
    If AppendGenericWideCodeUnit( _
        &HD800 + (codePoint \ 1024), values(), _
        codeUnitCount, capacity) = 0 Then Return 0
    Return AppendGenericWideCodeUnit( _
        &HDC00 + (codePoint And 1023), values(), _
        codeUnitCount, capacity)
End Function

Private Function ReadGenericWideStringEscape( _
    ByVal sourceText As String, ByRef position As Long, _
    ByRef codePoint As Long _
) As Long
    position += 1
    If position > Len(sourceText) Then Return 0
    Dim escapedByte As Long = Asc(sourceText, position)
    position += 1
    Select Case escapedByte
    Case Asc("e"): codePoint = 27
    Case Asc("a"): codePoint = 7
    Case Asc("b"): codePoint = 8
    Case Asc("t"): codePoint = 9
    Case Asc("n"): codePoint = 10
    Case Asc("v"): codePoint = 11
    Case Asc("f"): codePoint = 12
    Case Asc("r"): codePoint = 13
    Case Asc(Chr(92)), Asc("'"), Asc(Chr(34)), Asc("?")
        codePoint = escapedByte
    Case Asc("u"), Asc("U")
        Dim digitCount As Long = IIf(escapedByte = Asc("u"), 4, 8)
        codePoint = 0
        For digitIndex As Long = 1 To digitCount
            If position > Len(sourceText) Then Return 0
            Dim digit As Long = SimpleDigitValue(Asc(sourceText, position))
            If digit < 0 OrElse digit >= 16 OrElse _
               codePoint > (&H10FFFF - digit) \ 16 Then Return 0
            codePoint = codePoint * 16 + digit
            position += 1
        Next
        If codePoint >= &HD800 AndAlso codePoint <= &HDFFF Then Return 0
    Case Asc("x")
        codePoint = 0
        Dim digitCount As Long = 0
        While position <= Len(sourceText)
            Dim digit As Long = SimpleDigitValue(Asc(sourceText, position))
            If digit < 0 OrElse digit >= 16 Then Exit While
            If codePoint > (&H10FFFF - digit) \ 16 Then Return 0
            codePoint = codePoint * 16 + digit
            position += 1
            digitCount += 1
        Wend
        If digitCount = 0 Then Return 0
    Case Asc("0") To Asc("7")
        position -= 1
        codePoint = 0
        Dim digitCount As Long = 0
        While position <= Len(sourceText) AndAlso digitCount < 3
            Dim digit As Long = Asc(sourceText, position) - Asc("0")
            If digit < 0 OrElse digit > 7 Then Exit While
            codePoint = codePoint * 8 + digit
            position += 1
            digitCount += 1
        Wend
    Case Else
        Return 0
    End Select
    Return -1
End Function

Private Function ReadGenericUtf8Scalar( _
    ByVal sourceText As String, ByRef position As Long, _
    ByRef codePoint As Long _
) As Long
    If position > Len(sourceText) Then Return 0
    Dim firstByte As Long = Asc(sourceText, position)
    If firstByte <= &H7F Then
        If firstByte = 0 OrElse firstByte = 10 OrElse firstByte = 13 Then _
            Return 0
        codePoint = firstByte
        position += 1
        Return -1
    End If

    Dim continuationCount As Long
    Dim minimumCodePoint As Long
    Select Case firstByte
    Case &HC2 To &HDF
        continuationCount = 1
        minimumCodePoint = &H80
        codePoint = firstByte And &H1F
    Case &HE0 To &HEF
        continuationCount = 2
        minimumCodePoint = &H800
        codePoint = firstByte And &HF
    Case &HF0 To &HF4
        continuationCount = 3
        minimumCodePoint = &H10000
        codePoint = firstByte And &H7
    Case Else
        Return 0
    End Select

    For byteIndex As Long = 1 To continuationCount
        If position + byteIndex > Len(sourceText) Then Return 0
        Dim continuation As Long = Asc(sourceText, position + byteIndex)
        If continuation < &H80 OrElse continuation > &HBF Then Return 0
        If byteIndex = 1 Then
            If (firstByte = &HE0 AndAlso continuation < &HA0) OrElse _
               (firstByte = &HED AndAlso continuation > &H9F) OrElse _
               (firstByte = &HF0 AndAlso continuation < &H90) OrElse _
               (firstByte = &HF4 AndAlso continuation > &H8F) Then Return 0
        End If
        codePoint = codePoint * 64 + (continuation - &H80)
    Next
    If codePoint < minimumCodePoint OrElse codePoint > &H10FFFF OrElse _
       (codePoint >= &HD800 AndAlso codePoint <= &HDFFF) Then Return 0
    position += continuationCount + 1
    Return -1
End Function

Private Function ReadGenericStaticWideStringCodeUnits( _
    ByVal sourceText As String, ByVal wcharSize As Long, _
    values() As Long, ByRef codeUnitCount As Long _
) As Long
    codeUnitCount = 0
    sourceText = Trim(sourceText)
    If sourceText = "" OrElse (wcharSize <> 2 AndAlso wcharSize <> 4) Then _
        Return 0

    Dim capacity As Long = 16
    ReDim values(0 To capacity - 1)
    Dim position As Long = 1
    Do
        SkipCSpaces(sourceText, position)
        If Mid(sourceText, position, 1) <> "L" Then Return 0
        position += 1
        If Mid(sourceText, position, 1) <> Chr(34) Then Return 0
        position += 1
        Dim hasClosingQuote As Long = 0
        While position <= Len(sourceText)
            If Asc(sourceText, position) = Asc(Chr(34)) Then
                position += 1
                hasClosingQuote = -1
                Exit While
            End If

            Dim codePoint As Long
            If Asc(sourceText, position) = Asc(Chr(92)) Then
                If ReadGenericWideStringEscape( _
                    sourceText, position, codePoint) = 0 Then Return 0
            Else
                If ReadGenericUtf8Scalar( _
                    sourceText, position, codePoint) = 0 Then Return 0
            End If
            If AppendGenericWideCodePoint( _
                codePoint, wcharSize, values(), codeUnitCount, capacity) = 0 Then _
                Return 0
        Wend
        If hasClosingQuote = 0 Then Return 0
        SkipCSpaces(sourceText, position)
        If position > Len(sourceText) Then Exit Do
    Loop

    If AppendGenericWideCodeUnit( _
        0, values(), codeUnitCount, capacity) = 0 Then Return 0
    Return -1
End Function

Private Function TranslateGenericWideCharacterArrayInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceText As String, ByVal freeBasicType As String, _
    ByVal isUnsizedArray As Long, ByRef arrayCount As Long, _
    ByRef initialValue As String _
) As Long
    Dim cWideCharacterSize As Long = GenericHeaderPreprocessorSizeValue( _
        translation, "__SIZEOF_WCHAR_T__")
    Dim freeBasicCharacterSize As Long = GenericHeaderFreeBasicScalarSize( _
        translation, freeBasicType)
    If (cWideCharacterSize <> 2 AndAlso cWideCharacterSize <> 4) OrElse _
       freeBasicCharacterSize <> cWideCharacterSize Then Return 0

    Dim codeUnits() As Long
    Dim codeUnitCount As Long
    If ReadGenericStaticWideStringCodeUnits( _
        sourceText, cWideCharacterSize, codeUnits(), codeUnitCount) = 0 Then _
        Return 0
    If isUnsizedArray <> 0 Then
        arrayCount = codeUnitCount
    ElseIf arrayCount <= 0 Then
        Return 0
    ElseIf codeUnitCount > arrayCount Then
        ' C permits a fixed wide-character array to omit the literal's final
        ' NUL when its bound exactly matches the preceding code units.
        If codeUnitCount - 1 <> arrayCount Then Return 0
        codeUnitCount -= 1
    End If
    If codeUnitCount > arrayCount Then Return 0

    initialValue = "{"
    For valueIndex As Long = 0 To codeUnitCount - 1
        If valueIndex > 0 Then initialValue &= ", "
        initialValue &= Trim(Str(codeUnits(valueIndex)))
    Next
    initialValue &= "}"
    Return -1
End Function

Private Declare Function GenericBodyGeneratedNameExists( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceName As String _
) As Long

Private Function TranslateGenericWideStringLiteralPointer( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceText As String, ByVal freeBasicPointerType As String, _
    ByRef initialValue As String _
) As Long
    initialValue = ""
    freeBasicPointerType = Trim(freeBasicPointerType)
    If Right(freeBasicPointerType, 4) <> " Ptr" Then Return 0

    Dim elementType As String = Trim(Left( _
        freeBasicPointerType, Len(freeBasicPointerType) - 4))
    If Left(elementType, 6) = "Const " Then _
        elementType = Trim(Mid(elementType, 7))
    Dim aliasStorageType As String = GenericHeaderTypeAliasStorageTypeInHeader( _
        translation.genericC.header, elementType, 0)
    If aliasStorageType <> "" Then elementType = aliasStorageType
    If Left(elementType, 6) = "Const " Then _
        elementType = Trim(Mid(elementType, 7))

    Dim cWideCharacterSize As Long = GenericHeaderPreprocessorSizeValue( _
        translation, "__SIZEOF_WCHAR_T__")
    Dim freeBasicCharacterSize As Long = GenericHeaderFreeBasicScalarSize( _
        translation, elementType)
    If cWideCharacterSize <= 0 Then
        ' Body source units retain the caller's wchar_t type map, while the
        ' generic-header size table may not contain the C compiler builtin.
        ' Use that explicit FreeBASIC scalar mapping as the target width.
        cWideCharacterSize = freeBasicCharacterSize
    End If
    If (cWideCharacterSize <> 2 AndAlso cWideCharacterSize <> 4) OrElse _
       freeBasicCharacterSize <> cWideCharacterSize Then Return 0

    Dim codeUnits() As Long
    Dim codeUnitCount As Long
    If ReadGenericStaticWideStringCodeUnits( _
        sourceText, cWideCharacterSize, codeUnits(), codeUnitCount) = 0 Then _
        Return 0

    Dim initializer As String
    For valueIndex As Long = 0 To codeUnitCount - 1
        If valueIndex > 0 Then initializer &= ", "
        initializer &= Trim(Str(codeUnits(valueIndex)))
    Next
    Dim storageName As String
    Do
        storageName = "c2fb_internal_static_wchar_array_" & _
            Trim(Str(translation.body.generatedStaticStorageSerial))
        translation.body.generatedStaticStorageSerial += 1
    Loop While GenericBodyGeneratedNameExists(translation, storageName) <> 0

    translation.body.generatedStaticDeclarations &= _
        "Private Dim Shared " & storageName & "(0 To " & _
        Trim(Str(codeUnitCount - 1)) & ") As " & elementType & _
        " = {" & initializer & "}" & Chr(10)
    initialValue = "CPtr(" & freeBasicPointerType & ", @" & _
        storageName & "(0))"
    Return -1
End Function

Private Function ReadGenericStaticCharacterArrayBytes( _
    ByVal sourceText As String, values() As Long, _
    ByRef byteCount As Long _
) As Long
    byteCount = 0
    Dim parts() As String
    Dim partCount As Long
    If SplitSimpleCList( _
        sourceText, parts(), partCount, 0, _
        MAX_GENERIC_STATIC_INITIALIZER_VALUES) = 0 OrElse _
       partCount <= 0 Then Return 0

    ReDim values(0 To partCount - 1)
    For partIndex As Long = 0 To partCount - 1
        Dim literal As String = Trim(parts(partIndex))
        Dim position As Long = 1
        If position > Len(literal) OrElse _
           Asc(literal, position) <> Asc("'") Then Return 0
        position += 1
        If position > Len(literal) Then Return 0

        Dim byteValue As Long
        If Asc(literal, position) = Asc(Chr(92)) Then
            If ReadGenericStaticStringEscape( _
                literal, position, byteValue) = 0 Then Return 0
        Else
            byteValue = Asc(literal, position)
            If byteValue < 32 OrElse byteValue > 126 Then Return 0
            position += 1
        End If
        If position > Len(literal) OrElse _
           Asc(literal, position) <> Asc("'") Then Return 0
        position += 1
        SkipCSpaces(literal, position)
        If position <= Len(literal) Then Return 0
        values(partIndex) = byteValue
    Next
    byteCount = partCount
    Return -1
End Function

Private Function TranslateGenericCharacterArrayInitializer( _
    ByVal sourceText As String, ByVal isUnsizedArray As Long, _
    ByVal useStringStorage As Long, ByRef arrayCount As Long, _
    ByRef initialValue As String _
) As Long
    Dim byteValues() As Long
    Dim byteCount As Long
    If ReadGenericStaticStringBytes( _
        sourceText, byteValues(), byteCount) = 0 Then Return 0

    Dim includeTerminator As Long = -1
    If isUnsizedArray <> 0 Then
        arrayCount = byteCount + 1
    ElseIf arrayCount <= 0 Then
        Return 0
    ElseIf byteCount >= arrayCount Then
        ' C permits an exact character-count bound without storing the final NUL.
        If byteCount <> arrayCount Then Return 0
        includeTerminator = 0
    End If

    If useStringStorage <> 0 Then
        initialValue = "!" & Chr(34)
        For byteIndex As Long = 0 To byteCount - 1
            Dim byteValue As Long = byteValues(byteIndex)
            If byteValue >= 32 AndAlso byteValue <= 126 AndAlso _
               byteValue <> Asc(Chr(92)) AndAlso byteValue <> Asc(Chr(34)) Then
                initialValue &= Chr(byteValue)
            Else
                initialValue &= Chr(92) & Right( _
                    "00" & Trim(Str(byteValue)), 3)
            End If
        Next
        initialValue &= Chr(34)
        Return -1
    End If

    initialValue = "{"
    For byteIndex As Long = 0 To byteCount - 1
        If byteIndex > 0 Then initialValue &= ", "
        initialValue &= Trim(Str(byteValues(byteIndex)))
    Next
    If includeTerminator <> 0 Then
        If byteCount > 0 Then initialValue &= ", "
        initialValue &= "0"
    End If
    ' FreeBASIC zero-fills the remaining elements of a static array initializer.
    initialValue &= "}"
    Return -1
End Function

Private Function TranslateGenericCharacterArrayBytesInitializer( _
    byteValues() As Long, ByVal byteCount As Long, _
    ByVal isUnsizedArray As Long, ByVal useStringStorage As Long, _
    ByRef arrayCount As Long, ByRef initialValue As String _
) As Long
    If byteCount <= 0 Then Return 0
    If isUnsizedArray <> 0 Then arrayCount = byteCount
    If arrayCount < byteCount OrElse arrayCount <= 0 Then Return 0

    If useStringStorage <> 0 Then
        initialValue = "!" & Chr(34)
        For byteIndex As Long = 0 To arrayCount - 1
            Dim byteValue As Long = 0
            If byteIndex < byteCount Then byteValue = byteValues(byteIndex)
            If byteValue >= 32 AndAlso byteValue <= 126 AndAlso _
               byteValue <> Asc(Chr(92)) AndAlso byteValue <> Asc(Chr(34)) Then
                initialValue &= Chr(byteValue)
            Else
                initialValue &= Chr(92) & Right( _
                    "00" & Trim(Str(byteValue)), 3)
            End If
        Next
        initialValue &= Chr(34)
        Return -1
    End If

    initialValue = "{"
    For byteIndex As Long = 0 To byteCount - 1
        If byteIndex > 0 Then initialValue &= ", "
        initialValue &= Trim(Str(byteValues(byteIndex)))
    Next
    initialValue &= "}"
    Return -1
End Function

Private Function GenericBodyGeneratedNameExists( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceName As String _
) As Long
    Dim targetName As String = LCase(sourceName)
    For declarationIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If LCase(.sourceName) = targetName OrElse _
               LCase(.recordTag) = targetName OrElse _
               LCase(.recordAlias) = targetName Then Return -1
        End With
    Next
    For objectIndex As Long = 0 To translation.body.externalObjectCount - 1
        With translation.body.externalObjects(objectIndex)
            If LCase(.sourceName) = targetName OrElse _
               LCase(.freeBasicName) = targetName Then Return -1
        End With
    Next
    For symbolIndex As Long = 0 To translation.symbolTable.symbolCount - 1
        With translation.symbolTable.symbols(symbolIndex)
            If LCase(.sourceName) = targetName OrElse _
               LCase(.freeBasicName) = targetName OrElse _
               LCase(.cName) = targetName Then Return -1
        End With
    Next
    For aliasIndex As Long = 0 To translation.body.aliasCount - 1
        If LCase(translation.body.aliases(aliasIndex).name) = targetName Then _
            Return -1
    Next
    For enumIndex As Long = 0 To _
        translation.genericC.header.enumMemberCount - 1
        With translation.genericC.header.enumMembers(enumIndex)
            If LCase(.sourceName) = targetName OrElse _
               LCase(.freeBasicName) = targetName Then Return -1
        End With
    Next
    Return 0
End Function

Private Function TranslateGenericStaticCharacterCompoundLiteralPointer( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceText As String, ByVal freeBasicType As String, _
    ByRef initialValue As String _
) As Long
    initialValue = ""
    If translation.target.profile <> C2FB_TARGET_GENERIC OrElse _
       InStr(freeBasicType, " Ptr") = 0 Then Return 0

    sourceText = GenericMacroStripOuterParentheses(Trim(sourceText))
    If Left(sourceText, 1) <> "(" Then Return 0
    Dim typeEnd As Long = 1
    If ScanSimpleExpressionGroup( _
        sourceText, typeEnd, Asc("("), Asc(")")) = 0 Then Return 0
    Dim sourceType As String = Trim(Mid(sourceText, 2, typeEnd - 3))
    Dim arrayOpen As Long = InStr(sourceType, "[")
    If arrayOpen <= 0 Then Return 0
    Dim arrayClose As Long = InStr(arrayOpen + 1, sourceType, "]")
    If arrayClose <= arrayOpen OrElse _
       Trim(Mid(sourceType, arrayClose + 1)) <> "" Then Return 0

    Dim elementTokens() As String
    Dim elementTokenCount As Long
    TokenizeCDeclaration(Trim(Left(sourceType, arrayOpen - 1)), _
                         elementTokens(), elementTokenCount)
    If elementTokenCount <= 0 Then Return 0
    Dim elementType As C2fbCTypeModel
    If ParseCTypeModel(elementTokens(), 0, elementTokenCount - 1, elementType) = 0 OrElse _
       elementType.pointerDepth <> 0 OrElse _
       (elementType.baseName <> "char" AndAlso _
        elementType.baseName <> "signed char" AndAlso _
        elementType.baseName <> "unsigned char") Then Return 0

    Dim initializerPosition As Long = typeEnd
    SkipCSpaces(sourceText, initializerPosition)
    If initializerPosition > Len(sourceText) OrElse _
       Asc(sourceText, initializerPosition) <> Asc("{") Then Return 0
    Dim initializerEnd As Long = initializerPosition
    If ScanSimpleExpressionGroup( _
        sourceText, initializerEnd, Asc("{"), Asc("}")) = 0 OrElse _
       Trim(Mid(sourceText, initializerEnd)) <> "" Then Return 0
    Dim initializerBody As String = Trim(Mid( _
        sourceText, initializerPosition + 1, _
        initializerEnd - initializerPosition - 2))
    If Right(initializerBody, 1) = "," Then _
        initializerBody = RTrim(Left( _
            initializerBody, Len(initializerBody) - 1))
    Dim initializerValues() As String
    Dim initializerValueCount As Long
    If SplitSimpleCList( _
        initializerBody, initializerValues(), initializerValueCount, 0, _
        MAX_GENERIC_STATIC_INITIALIZER_VALUES) = 0 OrElse _
       initializerValueCount <= 0 Then Return 0

    Dim arrayCount As Long = initializerValueCount
    Dim boundText As String = Trim(Mid( _
        sourceType, arrayOpen + 1, arrayClose - arrayOpen - 1))
    If boundText <> "" AndAlso EvaluateGenericBodyArrayBound( _
        translation, boundText, arrayCount, MAX_GENERIC_ARRAY_COUNT) = 0 Then _
        Return 0
    If arrayCount < initializerValueCount OrElse _
       arrayCount > MAX_GENERIC_ARRAY_COUNT Then Return 0

    Dim byteValues As String
    For valueIndex As Long = 0 To arrayCount - 1
        Dim byteValue As Long = 0
        If valueIndex < initializerValueCount Then
            Dim sourceValue As String = Trim(initializerValues(valueIndex))
            If Left(sourceValue, 1) = "'" Then
                Dim characterPosition As Long = 1
                If DecodeCCharacterConstant( _
                    sourceValue, characterPosition, byteValue) = 0 Then Return 0
                SkipCSpaces(sourceValue, characterPosition)
                If characterPosition <= Len(sourceValue) Then Return 0
            ElseIf EvaluateGenericEnumIntegerValue( _
                translation, sourceValue, byteValue) = 0 Then
                Return 0
            End If
        End If
        If byteValue < 0 OrElse byteValue > 255 Then Return 0
        If valueIndex > 0 Then byteValues &= ", "
        byteValues &= Trim(Str(byteValue))
    Next

    Dim storageName As String
    Do
        storageName = "c2fb_internal_static_char_array_" & _
            Trim(Str(translation.body.generatedStaticStorageSerial))
        translation.body.generatedStaticStorageSerial += 1
    Loop While GenericBodyGeneratedNameExists(translation, storageName) <> 0

    ' FreeBASIC constant arrays cannot be addressed through an element.
    ' The backing storage is private; C constness stays on the pointer field.
    Dim storageDeclaration As String = "Private Dim Shared " & storageName & "(0 To " & _
        Trim(Str(arrayCount - 1)) & ") As UByte = {" & byteValues & "}"
    translation.body.generatedStaticDeclarations &= _
        storageDeclaration & Chr(10)
    initialValue = "CPtr(" & freeBasicType & ", @" & _
        storageName & "(0))"
    Return -1
End Function


Private Function IsGenericCharacterArrayType( _
    ByRef translation As C2fbTranslationContext, _
    ByVal commonType As String, ByVal freeBasicType As String, _
    ByVal stringOverrideMode As Long _
) As Long
    If Left(freeBasicType, 6) = "Const " Then _
        freeBasicType = Mid(freeBasicType, 7)
    If freeBasicType <> "Byte" AndAlso freeBasicType <> "UByte" Then Return 0

    Dim typeTokens() As String
    Dim typeTokenCount As Long
    TokenizeCDeclaration(commonType, typeTokens(), typeTokenCount)
    If typeTokenCount <= 0 Then Return 0
    Dim parsedType As C2fbCTypeModel
    If ParseCTypeModel(typeTokens(), 0, typeTokenCount - 1, parsedType) = 0 OrElse _
       parsedType.pointerDepth <> 0 Then Return 0
    Select Case parsedType.baseName
    Case "char", "signed char", "unsigned char"
        Return -1
    End Select
    If stringOverrideMode > 0 Then
        Dim aliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
            translation.genericC.header, parsedType.baseName, 0)
        If aliasIndex >= 0 Then
            Dim characterKind As Long = _
                translation.genericC.header.headerTypeAliases(aliasIndex).characterKind
            If characterKind = C2FB_C_CHARACTER_CHAR OrElse _
               characterKind = C2FB_C_CHARACTER_WIDE Then Return -1
        End If
    End If
    Return 0
End Function

Declare Function TranslateGenericRecordModuleStaticInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceText As String, ByVal freeBasicType As String, _
    ByRef initialValue As String, ByVal selfSourceName As String _
) As Long

Declare Function GenericRecordBindingForStaticInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByVal freeBasicType As String, _
    ByRef recordBinding As C2fbRecordBindingModel _
) As Long

Private Function EvaluateGenericArrayInitializerIndex( _
    ByRef translation As C2fbTranslationContext, _
    ByVal expression As String, ByRef index As Long _
) As Long
    If EvaluateSimpleArrayBound( _
        expression, index, MAX_GENERIC_ARRAY_COUNT - 1, -1) <> 0 Then _
        Return -1
    Dim evaluatedIndex As Long
    If EvaluateGenericEnumIntegerValue( _
        translation, expression, evaluatedIndex) = 0 OrElse _
       evaluatedIndex < 0 OrElse evaluatedIndex >= MAX_GENERIC_ARRAY_COUNT Then _
        Return 0
    index = evaluatedIndex
    Return -1
End Function

Private Function ParseGenericArrayInitializerDesignator( _
    ByRef translation As C2fbTranslationContext, _
    ByVal initializerItem As String, _
    ByRef firstIndex As Long, ByRef lastIndex As Long, _
    ByRef elementText As String _
) As Long
    initializerItem = Trim(initializerItem)
    firstIndex = 0
    lastIndex = 0
    elementText = ""
    If Left(initializerItem, 1) <> "[" Then Return 0

    Dim bracketEnd As Long = 1
    If ScanSimpleExpressionGroup( _
        initializerItem, bracketEnd, Asc("["), Asc("]")) = 0 Then _
        Return -1
    Dim indexText As String = Trim(Mid( _
        initializerItem, 2, bracketEnd - 3))
    Dim assignmentPosition As Long = bracketEnd
    SkipCSpaces(initializerItem, assignmentPosition)
    If Mid(initializerItem, assignmentPosition, 1) <> "=" Then Return -1
    assignmentPosition += 1
    elementText = Trim(Mid(initializerItem, assignmentPosition))
    If indexText = "" OrElse elementText = "" Then Return -1

    Dim rangePosition As Long = InStr(indexText, "...")
    If rangePosition = 0 Then
        If EvaluateGenericArrayInitializerIndex( _
            translation, indexText, firstIndex) = 0 Then _
            Return -1
        lastIndex = firstIndex
        Return 1
    End If
    If InStr(rangePosition + 3, indexText, "...") <> 0 Then Return -1
    Dim firstExpression As String = Trim(Left(indexText, rangePosition - 1))
    Dim lastExpression As String = Trim(Mid(indexText, rangePosition + 3))
    If firstExpression = "" OrElse lastExpression = "" Then Return -1
    If EvaluateGenericArrayInitializerIndex( _
        translation, firstExpression, firstIndex) = 0 OrElse _
       EvaluateGenericArrayInitializerIndex( _
        translation, lastExpression, lastIndex) = 0 OrElse _
       lastIndex < firstIndex Then Return -1
    Return 1
End Function

Private Function TranslateGenericCharacterMatrixInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceText As String, _
    ByVal rowCount As Long, ByVal rowWidth As Long, _
    ByRef initialValue As String _
) As Long
    initialValue = ""
    If rowCount < 1 OrElse rowWidth < 1 OrElse _
       rowCount > MAX_GENERIC_STATIC_INITIALIZER_VALUES \ rowWidth Then Return 0

    sourceText = Trim(sourceText)
    If Left(sourceText, 1) <> "{" Then Return 0
    Dim closingBrace As Long = 1
    If ScanSimpleExpressionGroup( _
        sourceText, closingBrace, Asc("{"), Asc("}")) = 0 OrElse _
       Trim(Mid(sourceText, closingBrace)) <> "" Then Return 0
    Dim initializerBody As String = Trim(Mid( _
        sourceText, 2, closingBrace - 3))
    If Right(initializerBody, 1) = "," Then _
        initializerBody = RTrim(Left( _
            initializerBody, Len(initializerBody) - 1))

    Dim values() As String
    Dim valueCount As Long
    If SplitSimpleCList( _
        initializerBody, values(), valueCount, 0, _
        MAX_GENERIC_STATIC_INITIALIZER_VALUES) = 0 OrElse _
       valueCount > rowCount Then Return 0

    Dim rowInitializers() As String
    ReDim rowInitializers(0 To rowCount - 1)
    For rowIndex As Long = 0 To rowCount - 1
        rowInitializers(rowIndex) = "{"
        For byteIndex As Long = 0 To rowWidth - 1
            If byteIndex > 0 Then rowInitializers(rowIndex) &= ", "
            rowInitializers(rowIndex) &= "0"
        Next
        rowInitializers(rowIndex) &= "}"
    Next

    Dim nextRow As Long = 0
    For valueIndex As Long = 0 To valueCount - 1
        Dim firstRow As Long
        Dim lastRow As Long
        Dim stringText As String
        Dim designatorStatus As Long = ParseGenericArrayInitializerDesignator( _
            translation, values(valueIndex), firstRow, lastRow, stringText)
        If designatorStatus < 0 Then Return 0
        If designatorStatus = 0 Then
            firstRow = nextRow
            lastRow = firstRow
            stringText = Trim(values(valueIndex))
        End If
        If firstRow < 0 OrElse lastRow < firstRow OrElse _
           lastRow >= rowCount Then Return 0

        Dim stringBytes() As Long
        Dim stringByteCount As Long
        If ReadGenericStaticStringBytes( _
            stringText, stringBytes(), stringByteCount) = 0 OrElse _
           stringByteCount > rowWidth Then Return 0

        Dim rowInitializer As String = "{"
        For byteIndex As Long = 0 To rowWidth - 1
            If byteIndex > 0 Then rowInitializer &= ", "
            If byteIndex < stringByteCount Then
                rowInitializer &= Trim(Str(stringBytes(byteIndex)))
            ElseIf byteIndex = stringByteCount AndAlso _
                   stringByteCount < rowWidth Then
                rowInitializer &= "0"
            Else
                rowInitializer &= "0"
            End If
        Next
        rowInitializer &= "}"
        For rowIndex As Long = firstRow To lastRow
            rowInitializers(rowIndex) = rowInitializer
        Next
        nextRow = lastRow + 1
    Next

    initialValue = "{"
    For rowIndex As Long = 0 To rowCount - 1
        If rowIndex > 0 Then initialValue &= ", "
        initialValue &= rowInitializers(rowIndex)
    Next
    initialValue &= "}"
    Return -1
End Function

Private Function GenericModuleStaticTypeSizeInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceType As String, ByRef byteSize As Long, _
    ByVal depth As Long = 0 _
) As Long
    If depth >= 32 OrElse sourceType = "" Then Return 0
    sourceType = Trim(sourceType)
    ' This helper resolves type spellings in static initializers. A leading
    ' dereference belongs to an unevaluated C expression such as sizeof(*p);
    ' let the body parser resolve p's pointee layout instead of sizing p.
    If Left(sourceType, 1) = "*" Then Return 0
    If LCase(Trim(sourceType)) = "long double" Then
        If GenericArrayBoundTypeSizeInContext( _
            translation, sourceType, byteSize) <> 0 Then Return -1
        Return CInt(byteSize > 0) * -1
    End If
    If GenericArrayBoundTypeSizeInContext( _
        translation, sourceType, byteSize) <> 0 Then Return -1

    Dim typeTokens() As String
    Dim typeTokenCount As Long
    TokenizeCDeclaration(sourceType, typeTokens(), typeTokenCount)
    If typeTokenCount <= 0 Then Return 0
    Dim parsedSourceType As C2fbCTypeModel
    If ParseCTypeModel(typeTokens(), 0, typeTokenCount - 1, _
        parsedSourceType) <> 0 AndAlso _
       (parsedSourceType.isStruct <> 0 OrElse _
        parsedSourceType.isUnion <> 0) Then
        ' File-scope sizeof in a C initializer can name an aggregate tag
        ' directly; resolve it through the prepared generic-header layout.
        byteSize = GenericHeaderSizeofTypeInBytes( _
            translation, sourceType)
        Return CInt(byteSize > 0) * -1
    End If
    Dim aliasName As String
    For tokenIndex As Long = 0 To typeTokenCount - 1
        If IsQualifierToken(typeTokens(tokenIndex)) <> 0 Then Continue For
        If IsIdentifierToken(typeTokens(tokenIndex)) = 0 OrElse _
           aliasName <> "" Then Return 0
        aliasName = typeTokens(tokenIndex)
    Next
    If aliasName = "" Then Return 0

    Dim aliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
        translation.genericC.header, aliasName, 0)
    If aliasIndex < 0 Then Return 0
    With translation.genericC.header.headerTypeAliases(aliasIndex)
        If .isFunction <> 0 OrElse .isTag <> 0 Then Return 0
        If .isArray <> 0 Then
            If .arrayCount <= 0 Then Return 0
            Dim elementSize As Long
            If GenericModuleStaticTypeSizeInContext( _
                translation, .arrayElementType, elementSize, depth + 1) = 0 OrElse _
               elementSize <= 0 OrElse _
               .arrayCount > MAX_GENERIC_ARRAY_BOUND_VALUE \ elementSize Then _
                Return 0
            byteSize = elementSize * .arrayCount
            Return -1
        End If
        Return GenericModuleStaticTypeSizeInContext( _
            translation, .baseType, byteSize, depth + 1)
    End With
    Return 0
End Function

Private Function GenericModuleStaticObjectSizeInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceName As String, ByRef byteSize As Long _
) As Long
    byteSize = 0
    Dim symbolIndex As Long = _
        GenericHeaderSymbolIndexInContext(translation, sourceName)
    If symbolIndex < 0 Then Return 0
    With translation.symbolTable.symbols(symbolIndex)
        If .kind <> GENERIC_SYMBOL_OBJECT OrElse _
           .genericHeader.unsizedArray <> 0 OrElse _
           .genericHeader.freeBasicType = "" Then Return 0

        Dim elementSize As Long
        If InStr(.genericHeader.freeBasicType, " Ptr") <> 0 Then
            elementSize = GenericHeaderPreprocessorSizeValue( _
                translation, "__SIZEOF_POINTER__")
        Else
            elementSize = GenericHeaderFreeBasicScalarSize( _
                translation, .genericHeader.freeBasicType)
            If elementSize <= 0 Then
                elementSize = GenericHeaderSimpleRecordSizeInBytes( _
                    translation, .genericHeader.freeBasicType)
            End If
        End If
        If elementSize <= 0 Then Return 0

        Dim elementCount As Long = .genericHeader.arrayCount
        If elementCount <= 0 Then elementCount = 1
        If elementCount > MAX_GENERIC_ARRAY_BOUND_VALUE \ elementSize Then _
            Return 0
        byteSize = elementCount * elementSize
        Return -1
    End With
    Return 0
End Function

Private Function GenericModuleStaticArrayElementSizeInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceName As String, ByRef byteSize As Long _
) As Long
    byteSize = 0
    Dim symbolIndex As Long = _
        GenericHeaderSymbolIndexInContext(translation, sourceName)
    If symbolIndex < 0 Then Return 0
    With translation.symbolTable.symbols(symbolIndex)
        If .kind <> GENERIC_SYMBOL_OBJECT OrElse _
           .genericHeader.unsizedArray <> 0 OrElse _
           .genericHeader.arrayCount <= 0 OrElse _
           .genericHeader.freeBasicType = "" Then Return 0

        If InStr(.genericHeader.freeBasicType, " Ptr") <> 0 Then
            byteSize = GenericHeaderPreprocessorSizeValue( _
                translation, "__SIZEOF_POINTER__")
        Else
            byteSize = GenericHeaderFreeBasicScalarSize( _
                translation, .genericHeader.freeBasicType)
            If byteSize <= 0 Then
                byteSize = GenericHeaderSimpleRecordSizeInBytes( _
                    translation, .genericHeader.freeBasicType)
            End If
        End If
        Return CInt(byteSize > 0) * -1
    End With
    Return 0
End Function

Private Function GenericModuleStaticSizeofOperandInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceOperand As String, ByRef byteSize As Long _
) As Long
    sourceOperand = Trim(sourceOperand)
    If IsIdentifierToken(sourceOperand) <> 0 Then _
        Return GenericModuleStaticObjectSizeInContext( _
            translation, sourceOperand, byteSize)

    Dim openingBracket As Long = InStr(sourceOperand, "[")
    If openingBracket <= 1 Then Return 0
    Dim sourceName As String = Trim(Left(sourceOperand, openingBracket - 1))
    If IsIdentifierToken(sourceName) = 0 Then Return 0
    Dim bracketEnd As Long = openingBracket
    If ScanSimpleExpressionGroup( _
        sourceOperand, bracketEnd, Asc("["), Asc("]")) = 0 OrElse _
       Trim(Mid(sourceOperand, bracketEnd)) <> "" Then Return 0
    Return GenericModuleStaticArrayElementSizeInContext( _
        translation, sourceName, byteSize)
End Function

Private Function NormalizeGenericModuleStaticInitializerSizeof( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceExpression As String, ByRef normalizedExpression As String _
) As Long
    normalizedExpression = ""
    Dim position As Long = 1
    While position <= Len(sourceExpression)
        If Mid(sourceExpression, position, Len("sizeof")) = "sizeof" AndAlso _
           (position = 1 OrElse _
            IsIdentifierPart(Asc(sourceExpression, position - 1)) = 0) Then
            Dim operandPosition As Long = position + Len("sizeof")
            SkipCSpaces(sourceExpression, operandPosition)
            Dim byteSize As Long
            If operandPosition <= Len(sourceExpression) AndAlso _
               Asc(sourceExpression, operandPosition) = Asc(Chr(34)) Then
                If GenericArrayBoundStringSize( _
                    sourceExpression, operandPosition, byteSize) = 0 Then Return 0
            ElseIf operandPosition <= Len(sourceExpression) AndAlso _
                   Asc(sourceExpression, operandPosition) = Asc("(") Then
                Dim groupEnd As Long = operandPosition
                If ScanSimpleExpressionGroup( _
                    sourceExpression, groupEnd, Asc("("), Asc(")")) = 0 Then _
                    Return 0
                Dim sourceType As String = Trim(Mid( _
                    sourceExpression, operandPosition + 1, _
                    groupEnd - operandPosition - 2))
                If GenericModuleStaticTypeSizeInContext( _
                    translation, sourceType, byteSize) = 0 Then Return 0
                operandPosition = groupEnd
            ElseIf operandPosition <= Len(sourceExpression) AndAlso _
                   IsIdentifierStart(Asc(sourceExpression, operandPosition)) <> 0 Then
                Dim identifierStart As Long = operandPosition
                operandPosition += 1
                While operandPosition <= Len(sourceExpression) AndAlso _
                      IsIdentifierPart(Asc(sourceExpression, operandPosition)) <> 0
                    operandPosition += 1
                Wend
                Dim sourceName As String = Mid( _
                    sourceExpression, identifierStart, _
                    operandPosition - identifierStart)
                If GenericModuleStaticObjectSizeInContext( _
                    translation, sourceName, byteSize) = 0 Then Return 0
            Else
                Return 0
            End If
            normalizedExpression &= Trim(Str(byteSize))
            position = operandPosition
        Else
            normalizedExpression &= Mid(sourceExpression, position, 1)
            position += 1
        End If
    Wend
    Return -1
End Function

Private Function NormalizeGenericStaticFloatingValueHelperCalls( _
    ByVal sourceExpression As String, ByRef normalizedExpression As String, _
    ByVal helperName As String, ByVal targetType As String, _
    ByVal depth As Long = 0 _
) As Long
    normalizedExpression = ""
    If depth >= MAX_GENERIC_MACRO_EXPRESSION_DEPTH Then Return 0
    Dim position As Long = 1
    Dim foundHelper As Long = 0
    While position <= Len(sourceExpression)
        Dim currentByte As Long = Asc(sourceExpression, position)
        If currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
            ' Literal contents are data, even when they resemble helper calls.
            Dim literalStart As Long = position
            Dim quoteByte As Long = currentByte
            position += 1
            While position <= Len(sourceExpression)
                currentByte = Asc(sourceExpression, position)
                If currentByte = Asc(Chr(92)) Then
                    position += 2
                ElseIf currentByte = quoteByte Then
                    If position < Len(sourceExpression) AndAlso _
                       Asc(sourceExpression, position + 1) = quoteByte Then
                        position += 2
                    Else
                        position += 1
                        Exit While
                    End If
                Else
                    position += 1
                End If
            Wend
            normalizedExpression &= Mid( _
                sourceExpression, literalStart, position - literalStart)
            Continue While
        End If
        If Mid(sourceExpression, position, Len(helperName)) = helperName AndAlso _
           (position = 1 OrElse _
            IsIdentifierPart(Asc(sourceExpression, position - 1)) = 0) Then
            Dim operandPosition As Long = position + Len(helperName)
            SkipCSpaces(sourceExpression, operandPosition)
            If operandPosition <= Len(sourceExpression) AndAlso _
               Asc(sourceExpression, operandPosition) = Asc("(") Then
                Dim groupEnd As Long = operandPosition
                If ScanSimpleExpressionGroup( _
                    sourceExpression, groupEnd, Asc("("), Asc(")")) = 0 Then _
                    Return 0
                Dim operand As String = Trim(Mid( _
                    sourceExpression, operandPosition + 1, _
                    groupEnd - operandPosition - 2))
                If operand = "" Then Return 0
                Dim normalizedOperand As String
                If NormalizeGenericStaticFloatingValueHelperCalls( _
                    operand, normalizedOperand, helperName, targetType, _
                    depth + 1) = 0 Then _
                    normalizedOperand = operand
                normalizedExpression &= "Cast(" & targetType & ", " & _
                    normalizedOperand & ")"
                position = groupEnd
                foundHelper = -1
                Continue While
            End If
        End If
        normalizedExpression &= Mid(sourceExpression, position, 1)
        position += 1
    Wend
    Return foundHelper
End Function

Private Sub NormalizeGenericStaticInitializerValue( _
    ByRef initialValue As String _
)
    Dim normalizedValue As String
    If NormalizeGenericStaticFloatingValueHelperCalls( _
        initialValue, normalizedValue, "__c2fb_single_value", "Single") <> 0 Then _
        initialValue = normalizedValue
    If NormalizeGenericStaticFloatingValueHelperCalls( _
        initialValue, normalizedValue, "__c2fb_double_value", "Double") <> 0 Then _
        initialValue = normalizedValue
End Sub

Private Function GenericModuleStaticBooleanKeywordValue( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceText As String, ByRef initialValue As String _
) As Long
    If translation.target.profile <> C2FB_TARGET_GENERIC Then Return 0
    Select Case sourceText
    Case "true"
        initialValue = "1"
    Case "false"
        initialValue = "0"
    Case Else
        Return 0
    End Select

    ' Before C23, true and false are macros or ordinary identifiers. Do not
    ' replace a project declaration or a retained macro with the keywords.
    For symbolIndex As Long = 0 To translation.symbolTable.symbolCount - 1
        If translation.symbolTable.symbols(symbolIndex).sourceName = _
           sourceText Then Return 0
    Next
    If GenericEnumMemberIndexInContext(translation, sourceText) >= 0 Then _
        Return 0
    For macroIndex As Long = 0 To _
        translation.genericC.header.headerMacroCount - 1
        If translation.genericC.header.headerMacros( _
            macroIndex).definition.sourceName = sourceText Then Return 0
    Next
    Return -1
End Function

Private Function GenericModuleStaticInitializerHasCTypeCast( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceText As String _
) As Long
    Dim tokens() As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        sourceText, tokens(), tokenCount) = 0 Then Return 0

    For openIndex As Long = 0 To tokenCount - 1
        If tokens(openIndex) <> "(" Then Continue For
        Dim groupDepth As Long = 1
        Dim closeIndex As Long = openIndex + 1
        While closeIndex < tokenCount AndAlso groupDepth > 0
            If tokens(closeIndex) = "(" Then
                groupDepth += 1
            ElseIf tokens(closeIndex) = ")" Then
                groupDepth -= 1
            End If
            closeIndex += 1
        Wend
        If groupDepth <> 0 OrElse closeIndex <= openIndex + 2 Then Continue For

        Dim sourceType As String
        For typeIndex As Long = openIndex + 1 To closeIndex - 2
            If sourceType <> "" Then sourceType &= " "
            sourceType &= tokens(typeIndex)
        Next
        Dim freeBasicType As String
        Dim isPointerCast As Long
        If GenericHeaderMacroCastType( _
            translation, sourceType, freeBasicType, isPointerCast) <> 0 Then _
            Return -1
    Next
    Return 0
End Function

Private Function TranslateGenericModuleStaticInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceText As String, ByVal freeBasicType As String, _
    ByVal isArray As Long, ByVal isPointerLike As Long, _
    ByVal isCallbackObject As Long, ByVal isCharacterArray As Long, _
    ByVal isUnsizedArray As Long, ByVal useStringStorage As Long, _
    ByRef arrayCount As Long, ByRef initialValue As String, _
    ByVal selfSourceName As String _
) As Long
    sourceText = Trim(sourceText)
    initialValue = ""
    If sourceText = "" Then Return -1
    If isArray = 0 AndAlso isPointerLike = 0 AndAlso _
       isCallbackObject = 0 AndAlso _
       (InStr(sourceText, "?") <> 0 OrElse _
        InStr(sourceText, "'") <> 0) Then
        Dim scalarSize As Long = GenericHeaderFreeBasicScalarSize( _
            translation, freeBasicType)
        Dim integerValue As Long
        If scalarSize > 0 AndAlso EvaluateGenericEnumIntegerValue( _
            translation, sourceText, integerValue) <> 0 Then
            Dim integerType As String = freeBasicType
            If Left(integerType, 6) = "Const " Then _
                integerType = Mid(integerType, 7)
            ' Fold deeply nested integer conditionals before ordinary lowering
            ' can emit an empty initializer for a source-level macro expression.
            initialValue = "Cast(" & integerType & ", " & _
                Trim(Str(integerValue)) & ")"
            Return -1
        End If
    End If
    If GenericModuleStaticBooleanKeywordValue( _
        translation, sourceText, initialValue) <> 0 Then Return -1

    If isArray <> 0 AndAlso Left(sourceText, 2) = "L" & Chr(34) Then
        Return TranslateGenericWideCharacterArrayInitializer( _
            translation, sourceText, freeBasicType, isUnsizedArray, _
            arrayCount, initialValue)
    End If

    If sourceText = "{0}" Then
        ' Module-level FreeBASIC storage starts zeroed, matching C's aggregate
        ' zero initializer without relying on C brace syntax.
        Return -1
    End If

    If isArray = 0 AndAlso isPointerLike = 0 AndAlso _
       Left(sourceText, 1) = "{" Then
        Dim recordBinding As C2fbRecordBindingModel
        If GenericRecordBindingForStaticInitializer( _
            translation, freeBasicType, recordBinding) <> 0 Then
            ' Once this is known to be a record initializer, do not let the
            ' scalar brace fallback turn a rejected field into a partial tuple.
            Return TranslateGenericRecordModuleStaticInitializer( _
                translation, sourceText, freeBasicType, initialValue, _
                selfSourceName)
        End If
    End If

    If Left(sourceText, 1) = "{" Then
        Dim closingBrace As Long = 1
        If ScanSimpleExpressionGroup( _
            sourceText, closingBrace, Asc("{"), Asc("}")) = 0 OrElse _
           Trim(Mid(sourceText, closingBrace)) <> "" Then Return 0
        Dim initializerBody As String = Trim(Mid( _
            sourceText, 2, closingBrace - 3))
        If initializerBody = "" Then Return -1
        If Right(initializerBody, 1) = "," Then _
            initializerBody = RTrim(Left( _
                initializerBody, Len(initializerBody) - 1))
        If isArray <> 0 AndAlso isCharacterArray <> 0 Then
            ' A brace-wrapped adjacent string sequence is one C string
            ' initializer, including its explicit embedded NUL bytes.
            Dim stringBytes() As Long
            Dim stringByteCount As Long
            If ReadGenericStaticStringBytes( _
                initializerBody, stringBytes(), stringByteCount) <> 0 Then
                Return TranslateGenericCharacterArrayInitializer( _
                    initializerBody, isUnsizedArray, useStringStorage, _
                    arrayCount, initialValue)
            End If
            Dim characterBytes() As Long
            Dim characterByteCount As Long
            If ReadGenericStaticCharacterArrayBytes( _
                initializerBody, characterBytes(), characterByteCount) <> 0 Then
                Return TranslateGenericCharacterArrayBytesInitializer( _
                    characterBytes(), characterByteCount, isUnsizedArray, _
                    useStringStorage, arrayCount, initialValue)
            End If
        End If
        Dim values() As String
        Dim valueCount As Long
        If SplitSimpleCList( _
            initializerBody, values(), valueCount, 0, _
            MAX_GENERIC_STATIC_INITIALIZER_VALUES) = 0 OrElse _
           valueCount <= 0 Then Return 0
        If isArray = 0 AndAlso valueCount <> 1 Then Return 0
        Dim hasArrayDesignator As Long = 0
        If isArray <> 0 Then
            For valueIndex As Long = 0 To valueCount - 1
                If Left(Trim(values(valueIndex)), 1) = "[" Then
                    hasArrayDesignator = -1
                    Exit For
                End If
            Next
        End If
        If arrayCount > 0 AndAlso valueCount > arrayCount AndAlso _
           hasArrayDesignator = 0 Then Return 0
        If arrayCount = 0 AndAlso isArray <> 0 AndAlso _
           hasArrayDesignator = 0 Then arrayCount = valueCount

        If hasArrayDesignator <> 0 Then
            If arrayCount = 0 Then
                Dim nextInferredIndex As Long = 0
                Dim maximumInitializedIndex As Long = -1
                For valueIndex As Long = 0 To valueCount - 1
                    Dim firstIndex As Long
                    Dim lastIndex As Long
                    Dim elementText As String
                    Dim designatorStatus As Long = _
                        ParseGenericArrayInitializerDesignator( _
                            translation, values(valueIndex), firstIndex, _
                            lastIndex, elementText)
                    If designatorStatus < 0 Then Return 0
                    If designatorStatus = 0 Then
                        firstIndex = nextInferredIndex
                        lastIndex = firstIndex
                    End If
                    If firstIndex < 0 OrElse _
                       lastIndex >= MAX_GENERIC_ARRAY_COUNT Then Return 0
                    If lastIndex > maximumInitializedIndex Then _
                        maximumInitializedIndex = lastIndex
                    nextInferredIndex = lastIndex + 1
                Next
                If maximumInitializedIndex < 0 Then Return 0
                arrayCount = maximumInitializedIndex + 1
            End If
            If arrayCount < 1 OrElse _
               arrayCount > MAX_GENERIC_STATIC_INITIALIZER_VALUES Then Return 0

            Dim translatedArrayValues() As String
            ReDim translatedArrayValues(0 To arrayCount - 1)
            For valueIndex As Long = 0 To arrayCount - 1
                translatedArrayValues(valueIndex) = "0"
            Next

            Dim nextArrayIndex As Long = 0
            For valueIndex As Long = 0 To valueCount - 1
                Dim firstIndex As Long
                Dim lastIndex As Long
                Dim elementText As String
                Dim designatorStatus As Long = _
                    ParseGenericArrayInitializerDesignator( _
                        translation, values(valueIndex), firstIndex, _
                        lastIndex, elementText)
                If designatorStatus < 0 Then Return 0
                If designatorStatus = 0 Then
                    firstIndex = nextArrayIndex
                    lastIndex = firstIndex
                    elementText = Trim(values(valueIndex))
                End If
                If firstIndex < 0 OrElse lastIndex < firstIndex OrElse _
                   lastIndex >= arrayCount Then Return 0

                Dim translatedElement As String
                If TranslateGenericModuleStaticInitializer( _
                    translation, elementText, freeBasicType, 0, _
                    isPointerLike, isCallbackObject, 0, 0, 0, arrayCount, _
                    translatedElement, selfSourceName) = 0 Then Return 0
                For elementIndex As Long = firstIndex To lastIndex
                    translatedArrayValues(elementIndex) = translatedElement
                Next
                nextArrayIndex = lastIndex + 1
            Next

            Dim translatedArrayInitializer As String
            For valueIndex As Long = 0 To arrayCount - 1
                If valueIndex > 0 Then translatedArrayInitializer &= ", "
                translatedArrayInitializer &= translatedArrayValues(valueIndex)
            Next
            initialValue = "{" & translatedArrayInitializer & "}"
            Return -1
        End If

        Dim translatedValues As String
        For valueIndex As Long = 0 To valueCount - 1
            Dim translatedValue As String
            If TranslateGenericModuleStaticInitializer( _
                translation, values(valueIndex), freeBasicType, 0, _
                isPointerLike, isCallbackObject, 0, 0, 0, arrayCount, _
                translatedValue, selfSourceName) = 0 Then Return 0
            If valueIndex > 0 Then translatedValues &= ", "
            translatedValues &= translatedValue
        Next
        initialValue = "{" & translatedValues & "}"
        Return -1
    End If

    If isArray <> 0 Then
        If isCharacterArray <> 0 AndAlso Left(sourceText, 1) = Chr(34) Then _
            Return TranslateGenericCharacterArrayInitializer( _
                sourceText, isUnsizedArray, useStringStorage, _
                arrayCount, initialValue)
        Return 0
    End If
    If isPointerLike <> 0 AndAlso isCallbackObject = 0 Then
        If TranslateGenericStaticCharacterCompoundLiteralPointer( _
            translation, sourceText, freeBasicType, initialValue) <> 0 Then _
            Return -1
        Dim pointerStorageType As String = _
            GenericHeaderTypeAliasStorageTypeInHeader( _
                translation.genericC.header, freeBasicType, 0)
        If pointerStorageType = "" Then pointerStorageType = freeBasicType
        If Left(pointerStorageType, 6) = "Const " Then _
            pointerStorageType = Trim(Mid(pointerStorageType, 7))
        If pointerStorageType = "ZString Ptr" Then
            Dim stringPointerValue As String
            If TranslateGenericHeaderStringMacro( _
                sourceText, stringPointerValue) <> 0 Then
                ' C string literals have static storage duration. STRPTR on a
                ' FreeBASIC literal likewise points at compiler-owned storage.
                initialValue = "CPtr(" & freeBasicType & ", " & _
                    stringPointerValue & ")"
                Return -1
            End If
        End If
    End If
    If isPointerLike <> 0 AndAlso _
       GenericNullPointerConstantText(sourceText) <> 0 Then
        ' Retain callback attributes and the destination pointer type. The C
        ' backend emits a pointer initializer's zero as C's null constant.
        initialValue = "CPtr(" & freeBasicType & ", 0)"
        Return -1
    End If
    If TranslateGenericModuleStaticAddressInitializer( _
        translation, sourceText, isCallbackObject, freeBasicType, initialValue, _
        selfSourceName) <> 0 Then Return -1

    If translation.target.profile = C2FB_TARGET_GENERIC AndAlso _
       InStr(sourceText, "sizeof") <> 0 Then
        Dim normalizedSizeof As String
        ' C static initializers need target-ABI constant sizes before their
        ' types are mapped to FreeBASIC aliases, some of which are opaque.
        If (NormalizeGenericModuleStaticInitializerSizeof( _
                translation, sourceText, normalizedSizeof) <> 0 OrElse _
            NormalizeGenericArrayBoundSizeof( _
                translation, sourceText, normalizedSizeof) <> 0) AndAlso _
           TranslateGenericHeaderIntegerExpression( _
               translation, normalizedSizeof, initialValue, 0, -1) <> 0 Then _
            Return -1
    End If

    Dim sizeofParameterNames(0 To 0) As String
    Dim sizeofFreeParameterNames(0 To 0) As String
    If TranslateGenericHeaderSizeofMacroExpression( _
        translation, sourceText, sizeofParameterNames(), _
        sizeofFreeParameterNames(), 0, 0, 0, 0, initialValue) <> 0 Then _
        Return -1

    If translation.target.profile = C2FB_TARGET_GENERIC Then
        Dim enumExpression As String
        If TranslateGenericEnumExpression( _
            translation, sourceText, enumExpression) <> 0 Then
            initialValue = enumExpression
            Return -1
        End If
    End If

    Dim scalarCastExpression As String = _
        GenericMacroStripOuterParentheses(sourceText)
    If isArray = 0 AndAlso isPointerLike = 0 AndAlso _
       Left(scalarCastExpression, 1) = "(" Then
        Dim castTypeEnd As Long = 1
        If ScanSimpleExpressionGroup( _
            scalarCastExpression, castTypeEnd, Asc("("), Asc(")")) <> 0 AndAlso _
           castTypeEnd < Len(scalarCastExpression) Then
            Dim castType As String = Trim(Mid( _
                scalarCastExpression, 2, castTypeEnd - 3))
            Dim freeBasicCastType As String
            Dim isPointerCast As Long
            If GenericHeaderMacroCastType( _
                translation, castType, freeBasicCastType, _
                isPointerCast) <> 0 AndAlso _
               isPointerCast = 0 AndAlso _
               TranslateGenericHeaderMacroExpression( _
                translation, scalarCastExpression, initialValue, -1) <> 0 Then _
                ' Resolve C scalar casts before the integer-only path, which
                ' can otherwise preserve the original cast syntax verbatim.
                NormalizeGenericStaticInitializerValue(initialValue)
                Return -1
            End If
        End If
    End If

    If GenericIntegerMacroCandidate(sourceText) <> 0 Then
        ' Static C initializers are integer constant expressions here, so
        ' division and remainder use C integer semantics even when the
        ' expression contains a conditional operator.
        If translation.target.profile = C2FB_TARGET_GENERIC AndAlso _
           GenericModuleStaticInitializerHasCTypeCast( _
               translation, sourceText) <> 0 AndAlso _
           TranslateGenericHeaderMacroExpression( _
               translation, sourceText, initialValue, -1) <> 0 Then
            NormalizeGenericStaticInitializerValue(initialValue)
            Return -1
        End If
        If TranslateGenericHeaderIntegerExpression( _
            translation, sourceText, initialValue, 0, -1) <> 0 Then
            NormalizeGenericStaticInitializerValue(initialValue)
            Return -1
        End If
        If InStr(sourceText, "'") <> 0 Then
            Dim evaluatedCharacterExpression As Long
            If EvaluateGenericEnumIntegerValue( _
                translation, sourceText, evaluatedCharacterExpression) <> 0 Then
                ' Character lookup tables are constant C expressions. When
                ' the expression renderer cannot lower the full ternary chain,
                ' evaluate its bounded integer result without retaining C syntax.
                initialValue = Trim(Str(evaluatedCharacterExpression))
                Return -1
            End If
        End If
    End If
    If TranslateGenericHeaderMacroExpression( _
        translation, sourceText, initialValue) <> 0 Then
        NormalizeGenericStaticInitializerValue(initialValue)
        Return -1
    End If
    Return 0
End Function

' C record initializers follow member order. Explicit braces around fixed
' array fields are kept so FreeBASIC receives the same aggregate shape.
Private Function SplitGenericStaticInitializerList( _
    ByVal sourceText As String, values() As String, _
    ByRef valueCount As Long _
) As Long
    sourceText = Trim(sourceText)
    valueCount = 0
    If Left(sourceText, 1) <> "{" Then Return 0

    Dim closingBrace As Long = 1
    If ScanSimpleExpressionGroup( _
        sourceText, closingBrace, Asc("{"), Asc("}")) = 0 OrElse _
       Trim(Mid(sourceText, closingBrace)) <> "" Then Return 0
    Dim bodyText As String = Trim(Mid( _
        sourceText, 2, closingBrace - 3))
    If bodyText = "" Then Return -1
    If Right(bodyText, 1) = "," Then _
        bodyText = RTrim(Left(bodyText, Len(bodyText) - 1))
    If bodyText = "" Then Return -1
    Return SplitSimpleCList(bodyText, values(), valueCount)
End Function

Private Function GenericHeaderStaticByteArrayElementType( _
    ByRef translation As C2fbTranslationContext, _
    ByVal freeBasicType As String _
) As Long
    Dim storageType As String = GenericHeaderTypeAliasStorageTypeInHeader( _
        translation.genericC.header, freeBasicType, 0)
    If storageType <> "" Then freeBasicType = storageType
    If Left(freeBasicType, 6) = "Const " Then _
        freeBasicType = Mid(freeBasicType, 7)
    Select Case LCase(freeBasicType)
    Case "byte", "ubyte", "c2fb_c_char", "c2fb_c_uchar"
        Return -1
    End Select
    Return 0
End Function

Private Function UnwrapGenericStaticScalarInitializer( _
    ByVal sourceText As String, ByRef scalarText As String, _
    ByVal nestingDepth As Long _
) As Long
    If nestingDepth > MAX_GENERIC_ARRAY_RANK Then Return 0
    sourceText = Trim(sourceText)
    If Left(sourceText, 1) <> "{" Then
        scalarText = sourceText
        Return IIf(sourceText <> "", -1, 0)
    End If

    Dim values() As String
    Dim valueCount As Long
    If SplitGenericStaticInitializerList( _
        sourceText, values(), valueCount) = 0 OrElse valueCount <> 1 Then Return 0
    Return UnwrapGenericStaticScalarInitializer( _
        values(0), scalarText, nestingDepth + 1)
End Function

Private Function GenericRecordBindingForStaticInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByVal freeBasicType As String, _
    ByRef recordBinding As C2fbRecordBindingModel _
) As Long
    If Left(freeBasicType, 6) = "Const " Then freeBasicType = Mid(freeBasicType, 7)
    Dim storageType As String = GenericHeaderTypeAliasStorageTypeInHeader( _
        translation.genericC.header, freeBasicType, 0)
    If storageType <> "" AndAlso storageType <> "Any" Then
        For declarationIndex As Long = 0 To translation.sourceUnit.declarationCount - 1
            If declarationIndex > UBound(translation.genericC.header.recordPlans) Then Exit For
            Dim plan As C2fbGenericRecordPlanModel = _
                translation.genericC.header.recordPlans(declarationIndex)
            ' A forward typedef may resolve through its backing UDT name rather
            ' than the generic "Record" storage marker.
            If plan.isSupported <> 0 AndAlso plan.bindingReady <> 0 AndAlso _
               (plan.freeBasicName = freeBasicType OrElse _
                plan.aliasFreeBasicName = freeBasicType OrElse _
                plan.implementationName = storageType) Then
                recordBinding = plan.binding
                Return -1
            End If
            For nestedIndex As Long = 0 To plan.nestedBindingCount - 1
                If plan.nestedBindings(nestedIndex).freeBasicName = freeBasicType OrElse _
                   plan.nestedBindings(nestedIndex).freeBasicName = storageType Then
                    recordBinding = plan.nestedBindings(nestedIndex)
                    Return -1
                End If
            Next
        Next
    End If
    For bodyRecordIndex As Long = 0 To _
        translation.body.recordBindingCount - 1
        With translation.body.recordBindings(bodyRecordIndex)
            If (.fbName <> freeBasicType AndAlso _
                .sourceName <> freeBasicType) OrElse _
               .staticInitializerBinding.itemCount <= 0 Then Continue For
            recordBinding = .staticInitializerBinding
            Return -1
        End With
    Next
    Return 0
End Function

Private Function TranslateGenericRecordModuleStaticInitializer( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceText As String, ByVal freeBasicType As String, _
    ByRef initialValue As String, ByVal selfSourceName As String _
) As Long
    initialValue = ""
    Dim recordBinding As C2fbRecordBindingModel
    Dim bindingResult As Long = GenericRecordBindingForStaticInitializer( _
        translation, freeBasicType, recordBinding)
    If InStr(LCase(freeBasicType), "numname") <> 0 Then _
        Print "sig2str initializer binding: "; freeBasicType; _
            " plans "; translation.genericC.header.recordPlanCount; _
            " items "; recordBinding.itemCount
    If bindingResult = 0 OrElse recordBinding.itemCount <= 0 Then Return 0

    Dim items() As String
    Dim itemCount As Long
    If SplitGenericStaticInitializerList( _
        sourceText, items(), itemCount) = 0 Then Return 0

    Dim initializerIndex As Long = 0
    Dim translatedFields As String
    For fieldIndex As Long = 0 To recordBinding.itemCount - 1
        With recordBinding.items(fieldIndex)
            If .kind <> C2FB_RECORD_BINDING_ITEM_FIELD OrElse _
               .isBitField <> 0 OrElse _
               .fieldType = "" OrElse _
               GenericHeaderTypeAliasStorageTypeInHeader( _
                   translation.genericC.header, .fieldType, 0) = "Record" Then Return 0
            Dim isCallbackField As Long = CInt( _
                Left(.fieldType, 9) = "Function " OrElse _
                Left(.fieldType, 4) = "Sub ") * -1
            Dim isPointerField As Long = _
                CInt(InStr(.fieldType, " Ptr") <> 0 OrElse _
                     isCallbackField <> 0) * -1
            Dim fieldValueCount As Long = .arrayCount
            If InStr(LCase(freeBasicType), "numname") <> 0 Then _
                Print "sig2str field "; fieldIndex; " type "; .fieldType; _
                    " count "; .arrayCount; " bounds "; .arrayBounds; _
                    " item "; initializerIndex; " text "; _
                    IIf(initializerIndex < itemCount, items(initializerIndex), "")
            If fieldValueCount = 0 Then
                If .arrayBounds <> "" Then Return 0
                fieldValueCount = 1
            ElseIf InStr(.arrayBounds, ",") <> 0 Then
                ' FreeBASIC nested-array initializers need a shape-preserving
                ' translation. Keep this first subset to one-dimensional fields.
                Return 0
            End If
            If fieldValueCount > MAX_FUNCTIONS Then Return 0

            Dim fieldInitialValue As String
            Dim initializedCharacterArray As Long = 0
            If .arrayCount > 0 AndAlso _
               GenericHeaderStaticByteArrayElementType( _
                   translation, .fieldType) <> 0 AndAlso _
               initializerIndex < itemCount Then
                Dim characterInitializer As String = _
                    Trim(items(initializerIndex))
                If Left(characterInitializer, 1) = "{" Then
                    Dim characterValues() As String
                    Dim characterValueCount As Long
                    If SplitGenericStaticInitializerList( _
                        characterInitializer, characterValues(), _
                        characterValueCount) <> 0 AndAlso _
                       characterValueCount = 1 Then
                        characterInitializer = Trim(characterValues(0))
                    End If
                End If
                If Left(characterInitializer, 1) = Chr(34) Then
                    Dim characterArrayCount As Long = fieldValueCount
                    If TranslateGenericModuleStaticInitializer( _
                        translation, characterInitializer, .fieldType, -1, _
                        0, 0, -1, 0, 0, characterArrayCount, _
                        fieldInitialValue, selfSourceName) = 0 OrElse _
                       characterArrayCount <> fieldValueCount Then Return 0
                    initializerIndex += 1
                    initializedCharacterArray = -1
                End If
            End If
            If initializedCharacterArray = 0 AndAlso .arrayCount > 0 Then
                Dim arrayValues() As String
                Dim arrayValueCount As Long = 0
                Dim explicitArrayList As Long = 0
                If initializerIndex < itemCount AndAlso _
                   Left(Trim(items(initializerIndex)), 1) = "{" Then
                    If SplitGenericStaticInitializerList( _
                        items(initializerIndex), arrayValues(), arrayValueCount) = 0 OrElse _
                       arrayValueCount > fieldValueCount Then Return 0
                    initializerIndex += 1
                    explicitArrayList = -1
                End If

                Dim translatedArrayValues As String
                For elementIndex As Long = 0 To fieldValueCount - 1
                    Dim sourceValue As String = "0"
                    If explicitArrayList <> 0 Then
                        If elementIndex < arrayValueCount Then _
                            sourceValue = arrayValues(elementIndex)
                    ElseIf initializerIndex < itemCount Then
                        sourceValue = items(initializerIndex)
                        initializerIndex += 1
                    End If
                    Dim scalarValue As String
                    If UnwrapGenericStaticScalarInitializer( _
                        sourceValue, scalarValue, 0) = 0 Then Return 0
                    Dim translatedValue As String
                    If isCallbackField <> 0 Then
                        If GenericNullPointerConstantText(scalarValue) = 0 Then _
                            Return 0
                        translatedValue = "0"
                    Else
                    Dim scalarArrayCount As Long = 0
                    If TranslateGenericModuleStaticInitializer( _
                            translation, scalarValue, .fieldType, 0, _
                            isPointerField, 0, 0, 0, 0, _
                            scalarArrayCount, translatedValue, _
                            selfSourceName) = 0 OrElse _
                       translatedValue = "" Then Return 0
                    End If
                    If translatedArrayValues <> "" Then _
                        translatedArrayValues &= ", "
                    translatedArrayValues &= translatedValue
                Next
                fieldInitialValue = "{" & translatedArrayValues & "}"
            ElseIf initializedCharacterArray = 0 Then
                Dim sourceValue As String = "0"
                If initializerIndex < itemCount Then
                    sourceValue = items(initializerIndex)
                    initializerIndex += 1
                End If
                Dim scalarSourceValue As String
                If UnwrapGenericStaticScalarInitializer( _
                    sourceValue, scalarSourceValue, 0) = 0 Then Return 0
                Dim translatedValue As String
                If isCallbackField <> 0 Then
                    If GenericNullPointerConstantText(scalarSourceValue) <> 0 Then
                        translatedValue = "0"
                    ElseIf TranslateGenericModuleStaticAddressInitializer( _
                        translation, scalarSourceValue, -1, .fieldType, _
                        translatedValue, selfSourceName) = 0 Then
                        Return 0
                    End If
                Else
                    Dim scalarArrayCount As Long = 0
                    Dim fieldResult As Long = _
                        TranslateGenericModuleStaticInitializer( _
                            translation, scalarSourceValue, .fieldType, 0, _
                            isPointerField, 0, 0, 0, 0, _
                            scalarArrayCount, translatedValue, _
                            selfSourceName)
                    If fieldResult = 0 OrElse translatedValue = "" Then Return 0
                End If
                fieldInitialValue = translatedValue
            End If

            If translatedFields <> "" Then translatedFields &= ", "
            translatedFields &= fieldInitialValue
            If recordBinding.isUnion <> 0 Then Exit For
        End With
    Next
    If initializerIndex < itemCount Then Return 0
    initialValue = "(" & translatedFields & ")"
    Return -1
End Function

Private Function ResolveGenericCallbackArrayObjectTypeInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, tokens() As String, _
    ByVal tokenCount As Long, ByVal sourceName As String, _
    ByRef callbackResult As C2fbCallbackTypeResultModel _
) As Long
    For nameToken As Long = 0 To tokenCount - 2
        If tokens(nameToken) <> sourceName OrElse _
           tokens(nameToken + 1) <> "[" Then Continue For
        Dim arrayClose As Long = nameToken + 1
        Dim arrayDepth As Long = 0
        For tokenIndex As Long = nameToken + 1 To tokenCount - 1
            If tokens(tokenIndex) = "[" Then
                arrayDepth += 1
            ElseIf tokens(tokenIndex) = "]" Then
                arrayDepth -= 1
                If arrayDepth = 0 Then
                    arrayClose = tokenIndex
                    Exit For
                End If
            End If
        Next
        If arrayDepth <> 0 Then Return 0

        Dim callbackTokens() As String
        ReDim callbackTokens(0 To tokenCount - 1)
        Dim callbackTokenCount As Long = 0
        For tokenIndex As Long = 0 To tokenCount - 1
            If tokenIndex = nameToken + 1 Then
                tokenIndex = arrayClose
                Continue For
            End If
            If tokenIndex = nameToken Then
                callbackTokens(callbackTokenCount) = "c2fb_callback_array_element"
            Else
                callbackTokens(callbackTokenCount) = tokens(tokenIndex)
            End If
            callbackTokenCount += 1
        Next
        ResolveCBodyCallbackTypeInContext( _
            translation, catalog, callbackTokens(), 0, _
            callbackTokenCount - 1, callbackResult, 0, _
            C2FB_TYPE_MAPPING_GENERIC_HEADER)
        Return CInt(callbackResult.status = _
                    C2FB_CALLBACK_TYPE_CONVERTED) * -1
    Next
    Return 0
End Function

Private Function EmitGenericFunctionAliasUsage( _
    ByRef translation As C2fbTranslationContext, _
    ByVal functionType As String, ByVal sourceName As String, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, names() As String, ByRef nameCount As Long, _
    outputNames() As String, ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
) As Long
    Dim isSub As Long = CInt(Left(functionType, 4) = "Sub ")
    If isSub = 0 AndAlso Left(functionType, 9) <> "Function " Then Return 0
    Dim callingConventionPosition As Long = 0
    Dim callingConvention As String
    Dim cdeclPosition As Long = InStr(functionType, "CDecl(")
    Dim stdcallPosition As Long = InStr(functionType, "StdCall(")
    Dim pascalPosition As Long = InStr(functionType, "Pascal(")
    If cdeclPosition > 0 Then
        callingConventionPosition = cdeclPosition
        callingConvention = "CDecl"
    End If
    If stdcallPosition > 0 AndAlso _
       (callingConventionPosition = 0 OrElse _
        stdcallPosition < callingConventionPosition) Then
        callingConventionPosition = stdcallPosition
        callingConvention = "StdCall"
    End If
    If pascalPosition > 0 AndAlso _
       (callingConventionPosition = 0 OrElse _
        pascalPosition < callingConventionPosition) Then
        callingConventionPosition = pascalPosition
        callingConvention = "Pascal"
    End If
    If callingConventionPosition = 0 Then Return 0
    Dim openParen As Long = callingConventionPosition + Len(callingConvention)
    Dim closePosition As Long = openParen
    If ScanSimpleExpressionGroup( _
        functionType, closePosition, Asc("("), Asc(")")) = 0 Then Return 0
    Dim parameters As String = Trim(Mid( _
        functionType, openParen + 1, closePosition - openParen - 2))
    Dim trailingType As String = Trim(Mid(functionType, closePosition))
    If isSub = 0 Then
        If Left(trailingType, 3) <> "As " OrElse Len(trailingType) <= 3 Then Return 0
        trailingType = Trim(Mid(trailingType, 4))
    ElseIf trailingType <> "" Then
        Return 0
    End If
    parameters = ApplyGenericStringOverrideInGenericC( _
        translation.genericC, sourceName, parameters)
    trailingType = ApplyGenericStringOverrideInGenericC( _
        translation.genericC, sourceName, trailingType)
    If GenericHeaderSourceNameWasEmitted( _
        translation, names(), nameCount, sourceName) <> 0 Then Return -1

    Dim emittedName As String = _
        GenericFreeBasicFunctionNameInContext( _
            translation, sourceName, outputNames(), outputNameCount, _
            C2FB_SYMBOL_RENAME_PROCEDURE)
    If nameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES OrElse _
       outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
        ReportError("generic header exceeds the configured function limit")
    Dim procedureBinding As C2fbProcedureBindingModel
    procedureBinding.freeBasicName = emittedName
    procedureBinding.cName = sourceName
    procedureBinding.returnType = trailingType
    procedureBinding.parameterList = parameters
    procedureBinding.callingConvention = callingConvention
    procedureBinding.isSub = isSub
    WriteGenericProcedureBindingWithGuardsInPolicy( _
        translation.genericC.policy, outputFile, sourceName, procedureBinding)
    RecordGenericHeaderProcedureInContext(translation, sourceName, procedureBinding)
    If nameCount > UBound(names) Then _
        ReDim Preserve names(0 To UBound(names) * 2 + 1)
    names(nameCount) = sourceName
    nameCount += 1
    If outputNameCount > UBound(outputNames) Then _
        ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
    outputNames(outputNameCount) = emittedName
    outputNameCount += 1
    conversionSummary.convertedCount += 1
    Return -1
End Function

Declare Sub EmitGenericExternalObjectTokensCore( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal declaration As String, ByRef outputFile As C2fbGeneratedFileOutputModel, _
    tokens() As String, ByVal tokenCount As Long, _
    names() As String, ByRef nameCount As Long, _
    outputNames() As String, ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel, _
    ByVal linkName As String, ByVal isReferenceObject As Long = 0 _
)

Private Sub EmitGenericExternalObjectTokens( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal declaration As String, ByRef outputFile As C2fbGeneratedFileOutputModel, _
    tokens() As String, ByVal tokenCount As Long, _
    names() As String, ByRef nameCount As Long, _
    outputNames() As String, ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel, _
    ByVal isReferenceObject As Long = 0 _
)
    Dim loweredDeclaration As String
    Dim linkName As String
    Dim assemblyNameStatus As Long = ParseCAssemblyNameLabel( _
        declaration, loweredDeclaration, linkName)
    If assemblyNameStatus > 0 Then
        EmitC2fbSkipped(translation, outputFile, conversionSummary, _
            "unsupported assembler symbol name", declaration)
        Exit Sub
    ElseIf assemblyNameStatus < 0 Then
        Dim loweredTokens() As String
        Dim loweredTokenCount As Long
        TokenizeCDeclaration( _
            StripCFunctionAttributes(loweredDeclaration), _
            loweredTokens(), loweredTokenCount)
        EmitGenericExternalObjectTokensCore( _
            translation, catalog, loweredDeclaration, outputFile, _
            loweredTokens(), loweredTokenCount, names(), nameCount, _
            outputNames(), outputNameCount, conversionSummary, linkName, _
            isReferenceObject)
    Else
        EmitGenericExternalObjectTokensCore( _
            translation, catalog, declaration, outputFile, tokens(), tokenCount, _
            names(), nameCount, outputNames(), outputNameCount, _
            conversionSummary, "", isReferenceObject)
    End If
End Sub

Private Sub EmitGenericExternalObjectTokensCore( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal declaration As String, ByRef outputFile As C2fbGeneratedFileOutputModel, _
    tokens() As String, ByVal tokenCount As Long, _
    names() As String, ByRef nameCount As Long, _
    outputNames() As String, ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel, _
    ByVal linkName As String, ByVal isReferenceObject As Long = 0 _
)
    If isReferenceObject = 0 Then
        Dim referenceIndex As Long = -1
        Dim parenDepth As Long = 0
        Dim bracketDepth As Long = 0
        Dim braceDepth As Long = 0
        For tokenIndex As Long = 0 To tokenCount - 1
            Select Case tokens(tokenIndex)
            Case "(": parenDepth += 1
            Case ")": If parenDepth > 0 Then parenDepth -= 1
            Case "[": bracketDepth += 1
            Case "]": If bracketDepth > 0 Then bracketDepth -= 1
            Case "{": braceDepth += 1
            Case "}": If braceDepth > 0 Then braceDepth -= 1
            Case "=":
                If parenDepth = 0 AndAlso bracketDepth = 0 AndAlso _
                   braceDepth = 0 Then Exit For
            Case "&":
                If parenDepth = 0 AndAlso bracketDepth = 0 AndAlso _
                   braceDepth = 0 Then
                    If referenceIndex >= 0 Then
                        EmitC2fbSkipped(translation, outputFile, _
                            conversionSummary, "unsupported C++ reference object", declaration)
                        Exit Sub
                    End If
                    referenceIndex = tokenIndex
                End If
            End Select
        Next
        If referenceIndex >= 0 Then
            If translation.genericC.header.cppMode = 0 Then
                EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                    "C++ reference object requires C++ preprocessing mode", declaration)
                Exit Sub
            End If
            Dim referenceTokens() As String
            ReDim referenceTokens(0 To tokenCount - 2)
            Dim referenceTokenCount As Long = 0
            For tokenIndex As Long = 0 To tokenCount - 1
                If tokenIndex = referenceIndex Then Continue For
                AddToken(referenceTokens(), referenceTokenCount, tokens(tokenIndex))
            Next
            EmitGenericExternalObjectTokensCore( _
                translation, catalog, declaration, outputFile, _
                referenceTokens(), referenceTokenCount, names(), nameCount, _
                outputNames(), outputNameCount, conversionSummary, linkName, -1)
            Exit Sub
        End If
    End If

    Dim commonType As String
    Dim sourceName As String
    Dim bindingOrder As String
    Dim baseTokenCount As Long
    If ParseGenericHeaderDeclaratorTokens( _
        tokens(), 0, tokenCount - 1, commonType, sourceName, bindingOrder, _
        baseTokenCount) = 0 Then Exit Sub
    Dim isThreadLocal As Long = 0
    For tokenIndex As Long = 0 To tokenCount - 1
        Select Case tokens(tokenIndex)
        Case "_Thread_local", "__thread": isThreadLocal = -1
        Case "thread_local"
            If tokens(tokenIndex) <> sourceName Then isThreadLocal = -1
        End Select
    Next
    Dim hasStaticStorage As Long = 0
    Dim hasExternStorage As Long = 0
    For tokenIndex As Long = 0 To tokenCount - 1
        If tokens(tokenIndex) = "typedef" Then Exit Sub
        If tokens(tokenIndex) = "static" Then hasStaticStorage = -1
        If tokens(tokenIndex) = "extern" Then hasExternStorage = -1
    Next
    If isThreadLocal <> 0 AndAlso _
       translation.genericC.header.cppMode <> 0 AndAlso _
       hasStaticStorage = 0 Then
        EmitC2fbSkipped(translation, outputFile, conversionSummary, _
            "external C++ thread-local object needs a C++ linker name", _
            sourceName & ": " & declaration)
        Exit Sub
    End If
    If GenericVariableExcludedInPolicy(translation.genericC.policy, sourceName) <> 0 AndAlso _
       (hasStaticStorage = 0 OrElse _
        translation.genericC.policy.includeStaticObjects = 0) Then Exit Sub
    Dim initializerToken As Long
    If FindC2fbTopLevelAssignmentToken( _
        tokens(), 0, tokenCount - 1, initializerToken) = 0 Then Exit Sub
    Dim sourceInitializerText As String
    If initializerToken >= 0 Then
        Dim initializerOperator As String
        Dim initializerPosition As Long
        If FindGenericMacroAssignmentOperator( _
            declaration, initializerOperator, initializerPosition) <= 0 OrElse _
           initializerOperator <> "=" Then
            EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                "unsupported object initializer", declaration)
            Exit Sub
        End If
        sourceInitializerText = Trim(Mid(declaration, initializerPosition + 1))
        If Right(sourceInitializerText, 1) = ";" Then _
            sourceInitializerText = RTrim(Left( _
                sourceInitializerText, Len(sourceInitializerText) - 1))
        If sourceInitializerText = "" Then
            EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                "empty object initializer", declaration)
            Exit Sub
        End If
    End If

    Dim hasFunctionOperator As Long = 0
    Dim pointerDepth As Long = 0
    Dim arrayDimensions As Long = 0
    For bindingIndex As Long = 1 To Len(bindingOrder)
        Select Case Mid(bindingOrder, bindingIndex, 1)
        Case "F": hasFunctionOperator = -1
        Case "P": pointerDepth += 1
        Case "A": arrayDimensions += 1
        End Select
    Next
    If Len(bindingOrder) > 0 AndAlso Left(bindingOrder, 1) = "F" Then Exit Sub
    Dim callbackObject As Long = 0
    Dim isCallbackArray As Long = 0
    Dim callbackResult As C2fbCallbackTypeResultModel
    Dim freeBasicType As String
    If hasFunctionOperator <> 0 Then
        Dim callbackLastToken As Long = tokenCount - 1
        If initializerToken >= 0 Then callbackLastToken = initializerToken - 1
        If callbackLastToken >= 0 AndAlso _
           tokens(callbackLastToken) = ";" Then callbackLastToken -= 1
        ResolveCBodyCallbackTypeInContext( _
            translation, catalog, tokens(), 0, callbackLastToken, _
            callbackResult, 0, C2FB_TYPE_MAPPING_GENERIC_HEADER, -1)
        isCallbackArray = CInt( _
            arrayDimensions = 1 AndAlso Left(bindingOrder, 1) = "A" AndAlso _
            Mid(bindingOrder, 2) = "PF") * -1
        If isCallbackArray <> 0 AndAlso _
           (callbackResult.status <> C2FB_CALLBACK_TYPE_CONVERTED OrElse _
            callbackResult.callbackName <> sourceName) Then _
            ResolveGenericCallbackArrayObjectTypeInContext( _
                translation, catalog, tokens(), callbackLastToken + 1, _
                sourceName, callbackResult)
        If callbackResult.status = C2FB_CALLBACK_TYPE_UNSUPPORTED Then
            EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                "unsupported callback object", declaration)
            Exit Sub
        End If
        If callbackResult.status = C2FB_CALLBACK_TYPE_CONVERTED AndAlso _
           (callbackResult.callbackName = sourceName OrElse isCallbackArray <> 0) Then
            freeBasicType = CBodyCallbackDeclarationInContext( _
                translation, callbackResult.freeBasicType)
            If freeBasicType <> "" Then callbackObject = -1
        End If
    End If
    If hasFunctionOperator <> 0 AndAlso callbackObject = 0 Then
        EmitC2fbSkipped(translation, outputFile, conversionSummary, "function-pointer object", declaration)
        Exit Sub
    End If
    If GenericHeaderSourceNameWasEmitted( _
        translation, names(), nameCount, sourceName) <> 0 Then Exit Sub

    If callbackObject <> 0 AndAlso callbackResult.pointerDepth > 1 Then
        If callbackResult.pointerDepth > MAX_FREEBASIC_POINTER_LEVELS Then
            EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                "pointer depth exceeds FreeBASIC's configured limit", declaration)
            Exit Sub
        End If
        Dim generatedPrefix As String = translation.genericC.policy.generatedNamePrefix
        If generatedPrefix = "" Then generatedPrefix = "c2fb_"
        Dim callbackAliasName As String = _
            "_" & generatedPrefix & "callback_" & sourceName
        While C2fbNameListContains( _
            outputNames(), outputNameCount, callbackAliasName) <> 0
            callbackAliasName &= "_"
        Wend
        If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
            ReportError("generic header exceeds the configured output-name limit")
        Dim callbackTypeAlias As C2fbTypeAliasBindingModel
        callbackTypeAlias.freeBasicName = callbackAliasName
        callbackTypeAlias.targetType = freeBasicType
        WriteC2fbTypeAlias(outputFile, callbackTypeAlias)
        If outputNameCount > UBound(outputNames) Then _
            ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
        outputNames(outputNameCount) = callbackAliasName
        outputNameCount += 1
        freeBasicType = callbackAliasName
        For pointerIndex As Long = 2 To callbackResult.pointerDepth
            freeBasicType &= " Ptr"
        Next
    End If

    If baseTokenCount <= 0 Then Exit Sub
    Dim baseTokens() As String
    ReDim baseTokens(0 To baseTokenCount - 1)
    Dim sourceTypeTokenCount As Long = baseTokenCount
    baseTokenCount = 0
    For tokenIndex As Long = 0 To sourceTypeTokenCount - 1
        Select Case tokens(tokenIndex)
        Case "_Thread_local", "__thread", "thread_local"
            Continue For
        End Select
        AddToken(baseTokens(), baseTokenCount, tokens(tokenIndex))
    Next
    If baseTokenCount = 0 Then Exit Sub
    commonType = GenericTokensToText(baseTokens(), 0, baseTokenCount - 1)

    Dim hasAtomicTypeWrapper As Long = 0
    For tokenIndex As Long = 0 To baseTokenCount - 2
        If baseTokens(tokenIndex) = "_Atomic" AndAlso _
           baseTokens(tokenIndex + 1) = "(" Then
            hasAtomicTypeWrapper = -1
            Exit For
        End If
    Next

    If callbackObject = 0 AndAlso _
       (bindingOrder = "" OrElse arrayDimensions > 0) Then
        Dim functionTypeAliasIndex As Long = -1
        For tokenIndex As Long = 0 To baseTokenCount - 1
            Dim candidateAlias As Long = _
                GenericHeaderTypeAliasIndexInHeader( _
                    translation.genericC.header, baseTokens(tokenIndex), 0)
            If candidateAlias >= 0 AndAlso _
               translation.genericC.header.headerTypeAliases(candidateAlias).isFunction <> 0 Then
                functionTypeAliasIndex = candidateAlias
                Exit For
            End If
        Next
        If functionTypeAliasIndex >= 0 Then
            If arrayDimensions > 0 OrElse hasAtomicTypeWrapper <> 0 Then
                ' A callback typedef hides the function pointer operator from
                ' an array object declarator or _Atomic(type-name), but its
                ' storage remains a procedure pointer rather than a procedure.
                freeBasicType = translation.genericC.header.headerTypeAliases( _
                    functionTypeAliasIndex).freeBasicName
                If freeBasicType = "" Then
                    EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                        "unresolved callback array typedef", declaration)
                    Exit Sub
                End If
                callbackObject = -1
            Else
                If CDeclarationHasStdCall(declaration) <> 0 Then
                    EmitC2fbSkipped(translation,  _
                        outputFile, conversionSummary, _
                        "non-CDecl function type alias use", declaration)
                    Exit Sub
                End If
                Dim functionType As String = _
                    GenericHeaderFunctionAliasTypeInHeader( _
                        translation.genericC.header, functionTypeAliasIndex)
                If functionType = "" OrElse EmitGenericFunctionAliasUsage( _
                    translation, _
                    functionType, sourceName, outputFile, names(), nameCount, _
                    outputNames(), outputNameCount, conversionSummary) = 0 Then
                    EmitC2fbSkipped(translation,  _
                        outputFile, conversionSummary, _
                        "unsupported function type alias use", declaration)
                End If
                Exit Sub
            End If
        End If
    End If

    Dim arrayCount As Long = 0
    Dim arrayBounds As String
    Dim firstArrayDimensionCount As Long = 0
    Dim unsizedArray As Long = 0
    Dim arraySizeHint As Long = 0
    Dim unsizedStringType As String
    Dim arrayTypeAliasIndex As Long = -1
    For tokenIndex As Long = 0 To baseTokenCount - 1
        Dim candidateAlias As Long = GenericHeaderTypeAliasIndexInHeader( _
            translation.genericC.header, baseTokens(tokenIndex), 0)
        If candidateAlias >= 0 AndAlso _
           translation.genericC.header.headerTypeAliases(candidateAlias).isArray <> 0 Then
            arrayTypeAliasIndex = candidateAlias
            Exit For
        End If
    Next
    If isCallbackArray <> 0 Then
        Dim namePosition As Long = InStr(declaration, sourceName)
        Dim openBracket As Long = 0
        If namePosition > 0 Then _
            openBracket = InStr(namePosition + Len(sourceName), declaration, "[")
        Dim closeBracket As Long = 0
        If openBracket > 0 Then _
            closeBracket = InStr(openBracket + 1, declaration, "]")
        If openBracket = 0 OrElse closeBracket = 0 Then
            EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                "unsupported callback array bound", declaration)
            Exit Sub
        End If
        Dim boundExpression As String = Trim(Mid( _
            declaration, openBracket + 1, closeBracket - openBracket - 1))
        If boundExpression = "" Then
            unsizedArray = -1
        ElseIf EvaluateSimpleArrayBound( _
            boundExpression, arrayCount, MAX_GENERIC_ARRAY_COUNT) = 0 AndAlso _
            EvaluateGenericHeaderArrayBound( _
                translation, boundExpression, arrayCount, _
                MAX_GENERIC_ARRAY_COUNT) = 0 Then
            EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                "unsupported callback array bound", declaration)
            Exit Sub
        End If
    End If
    If callbackObject = 0 Then
    If arrayTypeAliasIndex >= 0 Then
        If bindingOrder = "" Then
            freeBasicType = translation.genericC.header.headerTypeAliases(arrayTypeAliasIndex).arrayElementType
            arrayCount = translation.genericC.header.headerTypeAliases(arrayTypeAliasIndex).arrayCount
            arrayBounds = translation.genericC.header.headerTypeAliases(arrayTypeAliasIndex).arrayBounds
            If arrayCount = 0 Then unsizedArray = -1
        ElseIf Left(bindingOrder, 1) = "P" AndAlso pointerDepth > 0 Then
            ' A pointer to an array typedef is kept opaque because its stride
            ' includes the typedef's hidden array dimension.
            freeBasicType = "Any Ptr"
            For pointerIndex As Long = 2 To pointerDepth
                freeBasicType &= " Ptr"
            Next
        ElseIf Left(bindingOrder, 1) = "A" AndAlso _
               arrayDimensions > 0 AndAlso pointerDepth = 0 Then
            Dim identifierPosition As Long = _
                GenericLastIdentifierPosition(declaration, sourceName)
            Dim objectBounds As String
            Dim objectFirstCount As Long
            Dim objectElementCount As Long
            Dim objectUnsized As Long
            If identifierPosition = 0 OrElse _
               ParseGenericArrayBoundsInDeclaration( _
                translation, declaration, identifierPosition + Len(sourceName), _
                arrayDimensions, objectBounds, objectFirstCount, _
                objectElementCount, objectUnsized) = 0 OrElse objectUnsized <> 0 Then
                EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                    "unsupported nested array typedef object", declaration)
                Exit Sub
            End If
            Dim typedefElementCount As Long = _
                translation.genericC.header.headerTypeAliases(arrayTypeAliasIndex).arrayCount
            If typedefElementCount <= 0 OrElse _
               objectElementCount > MAX_GENERIC_ARRAY_COUNT \ typedefElementCount Then
                EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                    "oversized nested array typedef object", declaration)
                Exit Sub
            End If
            arrayCount = objectElementCount * typedefElementCount
            arrayBounds = CombineGenericArrayBounds( _
                objectBounds, _
                translation.genericC.header.headerTypeAliases(arrayTypeAliasIndex).arrayBounds)
            freeBasicType = _
                translation.genericC.header.headerTypeAliases(arrayTypeAliasIndex).arrayElementType
        ElseIf Left(bindingOrder, 1) = "A" AndAlso _
               arrayDimensions = 1 AndAlso pointerDepth > 0 Then
            Dim openingBracket As Long = InStr(declaration, "[")
            Dim closingBracket As Long = InStr(openingBracket + 1, declaration, "]")
            If openingBracket = 0 OrElse closingBracket = 0 OrElse _
               (EvaluateSimpleArrayBound(Trim(Mid( _
                   declaration, openingBracket + 1, _
                   closingBracket - openingBracket - 1)), arrayCount, _
                   MAX_GENERIC_ARRAY_COUNT) = 0 AndAlso _
                EvaluateGenericHeaderArrayBound(translation, Trim(Mid( _
                    declaration, openingBracket + 1, _
                    closingBracket - openingBracket - 1)), arrayCount, _
                    MAX_GENERIC_ARRAY_COUNT) = 0) Then
                EmitC2fbSkipped(translation,  _
                    outputFile, conversionSummary, "unsupported array typedef object", declaration)
                Exit Sub
            End If
            freeBasicType = "Any Ptr"
            For pointerIndex As Long = 2 To pointerDepth
                freeBasicType &= " Ptr"
            Next
        Else
            EmitC2fbSkipped(translation, outputFile, conversionSummary, "nested array typedef object", declaration)
            Exit Sub
        End If
    ElseIf arrayDimensions > 0 AndAlso Left(bindingOrder, 1) = "A" Then
        Dim identifierPosition As Long = _
            GenericLastIdentifierPosition(declaration, sourceName)
        Dim unsizedArrayBoundHint As Long = 0
        If arrayDimensions > 1 AndAlso hasStaticStorage = 0 AndAlso _
           initializerToken < 0 Then
            unsizedArrayBoundHint = UseGenericArraySizeOverrideInPolicy( _
                translation.genericC.policy, sourceName)
            If unsizedArrayBoundHint > 0 Then _
                arraySizeHint = unsizedArrayBoundHint
        End If
        If identifierPosition = 0 OrElse _
           ParseGenericArrayBoundsInDeclaration( _
            translation, declaration, identifierPosition + Len(sourceName), _
            arrayDimensions, arrayBounds, firstArrayDimensionCount, arrayCount, _
            unsizedArray, -1, 0, unsizedArrayBoundHint) = 0 Then
            EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                "unsupported external array bounds", declaration)
            Exit Sub
        End If
        If unsizedArray <> 0 AndAlso arrayDimensions <> 1 Then
            EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                "unsupported multidimensional unsized array", declaration)
            Exit Sub
        End If
        If pointerDepth > 0 Then
            If baseTokenCount + pointerDepth >= MAX_TYPE_WORDS Then
                EmitC2fbSkipped(translation,  _
                    outputFile, conversionSummary, "oversized external array type", declaration)
                Exit Sub
            End If
            Dim elementTokens() As String
            ReDim elementTokens(0 To MAX_TYPE_WORDS - 1)
            Dim elementTokenCount As Long = 0
            For tokenIndex As Long = 0 To baseTokenCount - 1
                AddToken(elementTokens(), elementTokenCount, baseTokens(tokenIndex))
            Next
            For pointerIndex As Long = 1 To pointerDepth
                AddToken(elementTokens(), elementTokenCount, "*")
            Next
            Dim resolvedArrayElementPointerType As C2fbResolvedTypeModel
            ResolveC2fbTypeModel(translation, catalog, _
                elementTokens(), 0, elementTokenCount - 1, resolvedArrayElementPointerType, _
                C2FB_POINTER_MAPPING_OPAQUE, C2FB_TYPE_MAPPING_GENERIC_HEADER)
            If resolvedArrayElementPointerType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then
                EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                    "unsupported external array type", _
                    C2fbTypeResolutionFailureDescription( _
                        resolvedArrayElementPointerType.status) & ": " & declaration)
                Exit Sub
            End If
            freeBasicType = resolvedArrayElementPointerType.freeBasicType
            If resolvedArrayElementPointerType.isConst <> 0 AndAlso _
               resolvedArrayElementPointerType.pointerCount = 0 Then _
                freeBasicType = "Const " & freeBasicType
        Else
            Dim resolvedArrayElementValueType As C2fbResolvedTypeModel
            ResolveC2fbTypeModel(translation, catalog, _
                baseTokens(), 0, baseTokenCount - 1, resolvedArrayElementValueType, _
                C2FB_POINTER_MAPPING_OPAQUE, C2FB_TYPE_MAPPING_GENERIC_HEADER)
            If resolvedArrayElementValueType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then
                EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                    "unsupported external array type", _
                    C2fbTypeResolutionFailureDescription( _
                        resolvedArrayElementValueType.status) & ": " & declaration)
                Exit Sub
            End If
            freeBasicType = resolvedArrayElementValueType.freeBasicType
            If resolvedArrayElementValueType.isConst <> 0 AndAlso _
               resolvedArrayElementValueType.pointerCount = 0 Then _
                freeBasicType = "Const " & freeBasicType
        End If
    ElseIf pointerDepth > 0 Then
        If arrayDimensions > 0 Then
            ' A pointer to an array is represented opaquely so BASIC indexing
            ' cannot apply the wrong element stride.
            freeBasicType = "Any Ptr"
            For pointerIndex As Long = 2 To pointerDepth
                freeBasicType &= " Ptr"
            Next
        Else
            If pointerDepth + baseTokenCount >= MAX_TYPE_WORDS Then
                EmitC2fbSkipped(translation,  _
                    outputFile, conversionSummary, "oversized external pointer type", declaration)
                Exit Sub
            End If
            Dim pointerTokens() As String
            ReDim pointerTokens(0 To MAX_TYPE_WORDS - 1)
            Dim pointerTokenCount As Long = 0
            For tokenIndex As Long = 0 To baseTokenCount - 1
                AddToken(pointerTokens(), pointerTokenCount, baseTokens(tokenIndex))
            Next
            For pointerIndex As Long = 1 To pointerDepth
                AddToken(pointerTokens(), pointerTokenCount, "*")
            Next
            Dim resolvedPointerType As C2fbResolvedTypeModel
            ResolveC2fbTypeModel(translation, catalog, _
                pointerTokens(), 0, pointerTokenCount - 1, resolvedPointerType, _
                C2FB_POINTER_MAPPING_OPAQUE, C2FB_TYPE_MAPPING_GENERIC_HEADER)
            If resolvedPointerType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then
                EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                    "unsupported external pointer type", _
                    C2fbTypeResolutionFailureDescription( _
                        resolvedPointerType.status) & ": " & declaration)
                Exit Sub
            End If
            freeBasicType = resolvedPointerType.freeBasicType
        End If
    ElseIf arrayDimensions > 0 Then
        EmitC2fbSkipped(translation, outputFile, conversionSummary, "unsupported external array", declaration)
        Exit Sub
    ElseIf bindingOrder = "" Then
        Dim resolvedValueType As C2fbResolvedTypeModel
        ' C permits an extern object declaration with an incomplete record
        ' type. The FreeBASIC declaration is useful for address-taking and
        ' ByRef calls; operations that need its layout remain compiler errors.
        Dim allowIncompleteExternValue As Long = CInt( _
            hasExternStorage <> 0 AndAlso hasStaticStorage = 0 AndAlso _
            initializerToken < 0 AndAlso isReferenceObject = 0) * -1
        ResolveC2fbTypeModel(translation, catalog, _
            baseTokens(), 0, baseTokenCount - 1, resolvedValueType, _
            C2FB_POINTER_MAPPING_OPAQUE, C2FB_TYPE_MAPPING_GENERIC_HEADER, _
            C2FB_TYPE_RECOGNITION_ALLOW_FALLBACK, allowIncompleteExternValue)
        If resolvedValueType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then
            EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                "unsupported external value type", _
                C2fbTypeResolutionFailureDescription( _
                    resolvedValueType.status) & ": " & declaration)
            Exit Sub
        End If
        freeBasicType = resolvedValueType.freeBasicType
        If resolvedValueType.isConst <> 0 AndAlso resolvedValueType.pointerCount = 0 Then _
            freeBasicType = "Const " & freeBasicType
    Else
        EmitC2fbSkipped(translation,  _
            outputFile, conversionSummary, "unsupported external declarator", declaration)
        Exit Sub
    End If
    End If

    If pointerDepth = 0 AndAlso arrayDimensions = 0 AndAlso callbackObject = 0 AndAlso _
       GenericHeaderTypeIsOpaqueEmptyRecordInHeader( _
        translation.genericC.header, freeBasicType) <> 0 Then
        EmitC2fbSkipped(translation, outputFile, conversionSummary, _
            "zero-size record object has no FreeBASIC by-value storage", declaration)
        Exit Sub
    End If

    Dim stringOverrideName As String = sourceName
    If GenericStringOverrideModeInPolicy( _
        translation.genericC.policy, stringOverrideName) = 0 AndAlso _
       arrayTypeAliasIndex >= 0 Then _
        stringOverrideName = _
            translation.genericC.header.headerTypeAliases(arrayTypeAliasIndex).sourceName
    Dim stringOverrideMode As Long = _
        GenericStringOverrideModeInPolicy( _
            translation.genericC.policy, stringOverrideName)
    If stringOverrideMode = 0 Then _
        stringOverrideMode = GenericHeaderFbfrogStringDefaultMode( _
            translation, commonType, freeBasicType)
    If stringOverrideMode > 0 AndAlso pointerDepth = 0 AndAlso _
       arrayDimensions = 0 AndAlso callbackObject = 0 Then
        Dim characterScalarType As String = _
            GenericHeaderFbfrogCharacterScalarType( _
                translation, commonType, freeBasicType)
        If characterScalarType <> "" Then freeBasicType = characterScalarType
    End If
    Dim isCharacterArray As Long = CInt( _
        arrayDimensions = 1 AndAlso pointerDepth = 0 AndAlso _
        IsGenericCharacterArrayType( _
            translation, commonType, freeBasicType, stringOverrideMode) <> 0) * -1
    Dim isCharacterMatrix As Long = CInt( _
        arrayDimensions = 2 AndAlso pointerDepth = 0 AndAlso _
        IsGenericCharacterArrayType( _
            translation, commonType, freeBasicType, stringOverrideMode) <> 0) * -1

    Dim constAggregateStorageType As String
    Dim isConstAggregateAccessor As Long = 0
    If Left(freeBasicType, 6) = "Const " AndAlso _
       pointerDepth = 0 AndAlso arrayDimensions = 0 AndAlso _
       arrayCount = 0 AndAlso unsizedArray = 0 AndAlso callbackObject = 0 AndAlso _
       isReferenceObject = 0 Then
        constAggregateStorageType = Trim(Mid(freeBasicType, 7))
        If constAggregateStorageType = "jmp_buf" OrElse _
           GenericHeaderTypeAliasStorageTypeInHeader( _
               translation.genericC.header, constAggregateStorageType, 0) = "Record" Then
            isConstAggregateAccessor = -1
        Else
            constAggregateStorageType = ""
        End If
    End If

    Dim initialValue As String
    If hasStaticStorage <> 0 AndAlso initializerToken >= 0 Then
        Dim isArrayObject As Long = CInt( _
            arrayBounds <> "" OrElse arrayCount > 0 OrElse _
            (arrayDimensions > 0 AndAlso pointerDepth = 0) OrElse _
            unsizedArray <> 0) * -1
        Dim isPointerObject As Long = CInt( _
            pointerDepth > 0 OrElse callbackObject <> 0) * -1
        Dim initializerType As String = freeBasicType
        If isConstAggregateAccessor <> 0 Then _
            initializerType = constAggregateStorageType
        Dim initializerTranslated As Long = 0
        If isCharacterMatrix <> 0 AndAlso _
           InStr(sourceInitializerText, Chr(34)) <> 0 AndAlso _
           firstArrayDimensionCount > 0 AndAlso _
           arrayCount > 0 AndAlso _
           arrayCount Mod firstArrayDimensionCount = 0 Then
            Dim characterRowWidth As Long = _
                arrayCount \ firstArrayDimensionCount
            initializerTranslated = TranslateGenericCharacterMatrixInitializer( _
                translation, sourceInitializerText, firstArrayDimensionCount, _
                characterRowWidth, initialValue)
        Else
            initializerTranslated = TranslateGenericModuleStaticInitializer( _
                translation, sourceInitializerText, initializerType, _
                isArrayObject, isPointerObject, callbackObject, _
                isCharacterArray, unsizedArray, _
                CInt(stringOverrideMode > 0) * -1, arrayCount, initialValue, _
                sourceName)
        End If
        If initializerTranslated = 0 Then
            EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                "unsupported module-static initializer", declaration)
            Exit Sub
        End If
        If initialValue = "" AndAlso _
           Trim(sourceInitializerText) <> "{0}" Then
            ' An empty FreeBASIC initializer means zeroed storage. Only C's
            ' canonical {0} initializer may use that without an ABI opt-in.
            ' Never silently discard a nonzero aggregate field here.
            EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                "unsupported module-static initializer", declaration)
            Exit Sub
        End If
        If translation.body.generatedStaticDeclarations <> "" Then
            ' Compound literals use file-scope byte storage. Emit that storage
            ' before this object's initializer refers to it.
            WriteC2fbOutputText( _
                outputFile, translation.body.generatedStaticDeclarations)
            translation.body.generatedStaticDeclarations = ""
        End If
        If unsizedArray <> 0 AndAlso arrayCount > 0 Then
            unsizedArray = 0
        End If
    End If

    If unsizedArray <> 0 Then
        arraySizeHint = UseGenericArraySizeOverrideInPolicy(translation.genericC.policy, sourceName)
        If arraySizeHint > 0 Then
            arrayCount = arraySizeHint
            unsizedArray = 0
        End If
    End If

    If arrayCount > 0 AndAlso stringOverrideMode > 0 AndAlso _
       (arrayDimensions = 1 OrElse initializerToken < 0) Then
        Dim fixedStringType As String
        Dim outerBounds As String
        Dim outerElementCount As Long
        If GenericHeaderFbfrogStringArrayShape( _
            translation.genericC.header, freeBasicType, arrayBounds, _
            arrayCount, fixedStringType, outerBounds, outerElementCount) <> 0 Then
            freeBasicType = fixedStringType
            arrayBounds = outerBounds
            arrayCount = outerElementCount
            If arrayBounds = "" Then arrayCount = 0
        End If
    End If
    freeBasicType = ApplyGenericStringOverrideModeInHeader( _
        translation.genericC.header, stringOverrideMode, freeBasicType)
    If unsizedArray <> 0 AndAlso _
       (stringOverrideMode > 0 OrElse _
        (translation.genericC.policy.fixUnsizedArrays <> 0 AndAlso _
         stringOverrideMode = 0)) Then _
        unsizedStringType = GenericStringPointerTypeInHeader(translation.genericC.header, freeBasicType)
    If freeBasicType = "" OrElse freeBasicType = "void" Then
        EmitC2fbSkipped(translation, outputFile, conversionSummary, "unknown external object type", declaration)
        Exit Sub
    End If
    If isReferenceObject <> 0 AndAlso _
       (arrayCount > 0 OrElse unsizedArray <> 0 OrElse callbackObject <> 0 OrElse _
        arrayDimensions > 0) Then
        EmitC2fbSkipped(translation, outputFile, conversionSummary, _
            "unsupported C++ reference object shape", declaration)
        Exit Sub
    End If

    Dim emittedName As String = _
        GenericFreeBasicFunctionNameInContext(translation, sourceName, outputNames(), outputNameCount)
    Dim storedName As String
    If unsizedArray <> 0 Then
        storedName = GenericFreeBasicFunctionNameInContext(translation,  _
            sourceName & "_storage", outputNames(), outputNameCount)
    ElseIf isConstAggregateAccessor <> 0 Then
        storedName = GenericFreeBasicFunctionNameInContext( _
            translation, sourceName & "_storage", outputNames(), outputNameCount)
        While LCase(storedName) = LCase(emittedName)
            storedName &= "_"
        Wend
    End If
    Dim selfAddressName As String = emittedName
    If unsizedArray <> 0 OrElse isConstAggregateAccessor <> 0 Then _
        selfAddressName = storedName
    initialValue = ResolveGenericStaticSelfAddressPlaceholder( _
        initialValue, selfAddressName)
    If nameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
        ReportError("generic header exceeds the configured symbol limit")
    Dim addedOutputNames As Long = 1
    If unsizedArray <> 0 OrElse isConstAggregateAccessor <> 0 Then _
        addedOutputNames = 2
    If outputNameCount + addedOutputNames > MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
        ReportError("generic header exceeds the configured output-name limit")

    If arraySizeHint > 0 AndAlso unsizedArray = 0 Then _
        WriteC2fbOutputLine( _
            outputFile, "' c2fb applies --array-size hint: " & sourceName & "=" & _
            Trim(Str(arraySizeHint)))
    Dim objectBinding As C2fbObjectBindingModel
    objectBinding.freeBasicName = emittedName
    objectBinding.cName = sourceName
    objectBinding.linkName = linkName
    objectBinding.freeBasicType = freeBasicType
    objectBinding.arrayCount = arrayCount
    objectBinding.arrayBounds = arrayBounds
    objectBinding.isUnsizedArray = unsizedArray
    objectBinding.isByRef = isReferenceObject
    objectBinding.isModuleStatic = hasStaticStorage
    objectBinding.isThreadLocal = isThreadLocal
    objectBinding.isPrivate = CInt( _
        hasStaticStorage <> 0 AndAlso _
        translation.genericC.policy.privateStaticObjects <> 0) * -1
    objectBinding.isConstAggregateAccessor = isConstAggregateAccessor
    objectBinding.initialValue = initialValue
    If unsizedArray <> 0 Then
        objectBinding.storageName = storedName
        objectBinding.stringAccessorType = unsizedStringType
    ElseIf isConstAggregateAccessor <> 0 Then
        objectBinding.storageName = storedName
    End If
    WriteGenericObjectBindingWithGuardsInPolicy( _
        translation.genericC.policy, outputFile, sourceName, objectBinding)
    RecordGenericHeaderObjectInContext(translation, sourceName, objectBinding)

    If nameCount > UBound(names) Then ReDim Preserve names(0 To UBound(names) * 2 + 1)
    names(nameCount) = sourceName
    nameCount += 1
    If outputNameCount > UBound(outputNames) Then _
        ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
    outputNames(outputNameCount) = emittedName
    outputNameCount += 1
    If unsizedArray <> 0 OrElse isConstAggregateAccessor <> 0 Then
        If outputNameCount > UBound(outputNames) Then _
            ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
        outputNames(outputNameCount) = storedName
        outputNameCount += 1
    End If
    If hasStaticStorage <> 0 Then
        conversionSummary.genericHeader.moduleStaticObjectCount += 1
    Else
        conversionSummary.genericHeader.externalObjectCount += 1
    End If
End Sub

Private Sub EmitGenericExternalObject( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal declaration As String, ByRef outputFile As C2fbGeneratedFileOutputModel, _
    names() As String, ByRef nameCount As Long, _
    outputNames() As String, ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    Dim normalized As String = StripCFunctionAttributes(declaration)
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(normalized, tokens(), tokenCount)
    EmitGenericExternalObjectTokens( _
        translation, catalog, declaration, outputFile, tokens(), tokenCount, _
        names(), nameCount, outputNames(), outputNameCount, conversionSummary)
End Sub

Private Sub EmitGenericHeaderDeclaration( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef sourceDeclaration As C2fbDeclarationModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    names() As String, ByRef nameCount As Long, _
    outputNames() As String, ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    Dim declaration As String = sourceDeclaration.text
    If sourceDeclaration.removeFromGenericHeader <> 0 Then Exit Sub
    Dim parts() As String
    Dim partCount As Long
    Dim textPartsReady As Long = _
        SplitSimpleCList(declaration, parts(), partCount)
    Dim sourceRanges() As C2fbTokenRangeModel
    Dim sourceRangeCount As Long = 0
    Dim sourceRangesReady As Long = 0
    If sourceDeclaration.tokenCount > 0 AndAlso _
       SplitC2fbTokenList( _
           sourceDeclaration.tokens(), 0, sourceDeclaration.tokenCount - 1, _
           sourceRanges(), sourceRangeCount) <> 0 Then
        sourceRangesReady = -1
    End If

    If textPartsReady <> 0 AndAlso sourceRangesReady <> 0 AndAlso _
        partCount = sourceRangeCount Then
        If sourceRangeCount = 1 Then
            Dim singleCommonType As String
            Dim singleSourceName As String
            Dim singleBindingOrder As String
            If ParseGenericHeaderDeclarator( _
                declaration, singleCommonType, singleSourceName, _
                singleBindingOrder) <> 0 AndAlso _
               GenericHeaderPlainDeclaratorRemoved( _
                   sourceDeclaration, singleSourceName) <> 0 Then Exit Sub
            EmitPrototypeWithTokens(translation, catalog, declaration, _
                sourceDeclaration.tokens(), sourceDeclaration.tokenCount, outputFile, names(), nameCount, _
                outputNames(), outputNameCount, conversionSummary, _
                C2FB_TYPE_MAPPING_GENERIC_HEADER)
            EmitGenericExternalObjectTokens( _
                translation, catalog, declaration, outputFile, _
                sourceDeclaration.tokens(), sourceDeclaration.tokenCount, _
                names(), nameCount, outputNames(), outputNameCount, conversionSummary)
            Exit Sub
        End If

        Dim tokenCommonType As String
        Dim tokenFirstName As String
        Dim tokenFirstBinding As String
        Dim tokenCommonTypeCount As Long
        If ParseGenericHeaderDeclaratorTokens( _
            sourceDeclaration.tokens(), sourceRanges(0).firstToken, _
            sourceRanges(0).lastToken, tokenCommonType, tokenFirstName, _
            tokenFirstBinding, tokenCommonTypeCount) <> 0 Then
            Dim canBuildAllParts As Long = -1
            For validatePartIndex As Long = 0 To partCount - 1
                Dim validationTokens() As String
                Dim validationTokenCount As Long
                If BuildC2fbDeclaratorPartTokens( _
                    sourceDeclaration.tokens(), sourceRanges(), sourceRangeCount, _
                    validatePartIndex, tokenCommonTypeCount, validationTokens(), _
                    validationTokenCount) = 0 Then
                    canBuildAllParts = 0
                    Exit For
                End If
            Next

            If canBuildAllParts <> 0 Then
                Dim tokenPartOrder() As Long
                ApplyGenericMoveAboveToDeclarationParts( _
                    translation, parts(), partCount, tokenCommonType, _
                    tokenPartOrder())
                For tokenPartPosition As Long = 0 To partCount - 1
                    Dim tokenPartIndex As Long = tokenPartOrder(tokenPartPosition)
                    Dim tokenItemDeclaration As String = Trim(parts(tokenPartIndex))
                    If tokenPartIndex > 0 Then _
                        tokenItemDeclaration = _
                            tokenCommonType & " " & tokenItemDeclaration
                    Dim itemTokens() As String
                    Dim itemTokenCount As Long
                    If BuildC2fbDeclaratorPartTokens( _
                        sourceDeclaration.tokens(), sourceRanges(), sourceRangeCount, _
                        tokenPartIndex, tokenCommonTypeCount, itemTokens(), _
                        itemTokenCount) = 0 Then _
                        ReportError("generic declaration token split changed during lowering")
                    Dim itemCommonType As String
                    Dim itemSourceName As String
                    Dim itemBindingOrder As String
                    If ParseGenericHeaderDeclarator( _
                        tokenItemDeclaration, itemCommonType, itemSourceName, _
                        itemBindingOrder) <> 0 AndAlso _
                       GenericHeaderPlainDeclaratorRemoved( _
                           sourceDeclaration, itemSourceName) <> 0 Then Continue For
                    EmitPrototypeWithTokens(translation, catalog, tokenItemDeclaration, _
                        itemTokens(), itemTokenCount, _
                        outputFile, names(), nameCount, outputNames(), _
                        outputNameCount, conversionSummary, _
                        C2FB_TYPE_MAPPING_GENERIC_HEADER)
                    EmitGenericExternalObjectTokens( _
                        translation, catalog, tokenItemDeclaration, outputFile, _
                        itemTokens(), itemTokenCount, names(), nameCount, _
                        outputNames(), outputNameCount, conversionSummary)
                Next
                Exit Sub
            End If
        End If
    End If

    If textPartsReady = 0 OrElse partCount <= 1 Then
        Dim singleCommonType As String
        Dim singleSourceName As String
        Dim singleBindingOrder As String
        If ParseGenericHeaderDeclarator( _
            declaration, singleCommonType, singleSourceName, _
            singleBindingOrder) <> 0 AndAlso _
           GenericHeaderPlainDeclaratorRemoved( _
               sourceDeclaration, singleSourceName) <> 0 Then Exit Sub
        EmitPrototype(translation, catalog, declaration, outputFile, names(), nameCount, _
            outputNames(), outputNameCount, conversionSummary, _
            C2FB_TYPE_MAPPING_GENERIC_HEADER)
        EmitGenericExternalObject(translation, catalog, declaration, outputFile, _
            names(), nameCount, outputNames(), outputNameCount, conversionSummary)
        Exit Sub
    End If

    Dim commonType As String
    Dim firstName As String
    Dim firstBinding As String
    If ParseGenericHeaderDeclarator( _
        parts(0), commonType, firstName, firstBinding) = 0 Then
        EmitPrototype(translation, catalog, declaration, outputFile, names(), nameCount, _
            outputNames(), outputNameCount, conversionSummary, _
            C2FB_TYPE_MAPPING_GENERIC_HEADER)
        Exit Sub
    End If

    Dim partOrder() As Long
    ApplyGenericMoveAboveToDeclarationParts( _
        translation, parts(), partCount, commonType, partOrder())
    For partPosition As Long = 0 To partCount - 1
        Dim partIndex As Long = partOrder(partPosition)
        Dim itemDeclaration As String = Trim(parts(partIndex))
        If partIndex > 0 Then itemDeclaration = commonType & " " & itemDeclaration
        Dim itemCommonType As String
        Dim itemSourceName As String
        Dim itemBindingOrder As String
        If ParseGenericHeaderDeclarator( _
            itemDeclaration, itemCommonType, itemSourceName, _
            itemBindingOrder) <> 0 AndAlso _
           GenericHeaderPlainDeclaratorRemoved( _
               sourceDeclaration, itemSourceName) <> 0 Then Continue For
        EmitPrototype(translation, catalog, itemDeclaration, outputFile, names(), nameCount, _
            outputNames(), outputNameCount, conversionSummary, _
            C2FB_TYPE_MAPPING_GENERIC_HEADER)
        EmitGenericExternalObject(translation, catalog, itemDeclaration, outputFile, names(), nameCount, _
            outputNames(), outputNameCount, conversionSummary)
    Next
End Sub

/' ------------------------------------------------------------------------- '/
/' Generic header output passes                                             '/
/' ------------------------------------------------------------------------- '/

/' end of c2fb_generic_declarations.bi '/
