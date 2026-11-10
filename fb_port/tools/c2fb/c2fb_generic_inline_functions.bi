/'
    Project: C2FB generic header converter

    File: c2fb_generic_inline_functions.bi

    Purpose:

        Convert simple C header function definitions into FreeBASIC macros.

    Responsibilities:

        - Scan active function definitions from the preprocessed header tree.
        - Keep supported scalar, pointer, and callback return expressions with
          safe parameter evaluation.
        - Avoid replacing non-static definitions that have a separate prototype.
        - Reuse generic macro expression lowering and symbol naming.
        - Report function bodies outside the conservative macro subset.

    This file intentionally does NOT contain:

        - General C statement-body translation or full C inline-linkage semantics.
        - General function-pointer macro calls or automatic side-effect analysis.
        - C preprocessing or ordinary header declaration emission.
'/

Private Function IsGenericInlineIntegerType( _
    ByRef translation As C2fbTranslationContext, ByVal sourceType As String _
) As Long
    Dim typeName As String = Trim(sourceType)
    If Left(typeName, 6) = "Const " Then typeName = Mid(typeName, 7)
    If InStr(typeName, " Ptr") <> 0 Then Return 0
    Dim storageType As String = GenericHeaderTypeAliasStorageTypeInHeader( _
        translation.genericC.header, typeName, 0)
    If storageType <> "" Then typeName = storageType
    Select Case LCase(typeName)
    Case "byte", "ubyte", "short", "ushort", "long", "ulong", _
         "clong", "culong", "longint", "ulongint", "integer", "uinteger", _
         "c2fb_c_int", "c2fb_c_uint", "c2fb_c_long", "c2fb_c_ulong", _
         "c2fb_int64", "c2fb_uint64", "c2fb_size_t"
        Return -1
    End Select
    Return 0
End Function

Private Function IsGenericInlineFloatingType( _
    ByRef translation As C2fbTranslationContext, ByVal sourceType As String _
) As Long
    Dim typeName As String = Trim(sourceType)
    If Left(typeName, 6) = "Const " Then typeName = Mid(typeName, 7)
    If InStr(typeName, " Ptr") <> 0 Then Return 0
    Dim storageType As String = GenericHeaderTypeAliasStorageTypeInHeader( _
        translation.genericC.header, typeName, 0)
    If storageType <> "" Then typeName = storageType
    Select Case LCase(typeName)
    Case "single", "double": Return -1
    End Select
    Return 0
End Function

Private Function IsGenericInlinePointerType( _
    ByVal sourceType As String _
) As Long
    Dim typeName As String = Trim(sourceType)
    If Left(typeName, 6) = "Const " Then typeName = Trim(Mid(typeName, 7))
    Dim pointerDepth As Long = 0
    While Right(typeName, 4) = " Ptr"
        typeName = Trim(Left(typeName, Len(typeName) - 4))
        pointerDepth += 1
    Wend
    If pointerDepth = 0 OrElse _
       pointerDepth > MAX_FREEBASIC_POINTER_LEVELS OrElse _
       Left(LCase(typeName), 9) = "function " OrElse _
       Left(LCase(typeName), 4) = "sub " Then Return 0
    Return -1
End Function

Declare Function GenericInlineExpressionHasDivisionOperator( _
    ByVal expression As String _
) As Long
Declare Function GenericInlineNumericTokenIsFloating( _
    ByVal tokenText As String _
) As Long
Declare Function IsGenericInlineCallbackType( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceType As String _
) As Long
Declare Function GenericInlineFloatingExpressionHasFloatingOperand( _
    ByRef translation As C2fbTranslationContext, ByVal expression As String, _
    parameterNames() As String, parameterTypes() As String, _
    ByVal parameterCount As Long _
) As Long
Declare Function WrapGenericInlineParameterReferences( _
    ByRef translation As C2fbTranslationContext, ByVal expression As String, _
    freeParameterNames() As String, parameterTypes() As String, _
    ByVal parameterCount As Long, ByRef typedExpression As String _
) As Long

Private Function TranslateGenericInlinePointerDereference( _
    ByRef translation As C2fbTranslationContext, _
    ByVal returnType As String, ByVal expression As String, _
    parameterNames() As String, freeParameterNames() As String, _
    parameterTypes() As String, ByVal parameterCount As Long, _
    ByRef freeBasicExpression As String _
) As Long
    expression = Trim(expression)
    Dim dereferenceCount As Long = 0
    While expression <> ""
        Dim strippedExpression As String = _
            GenericMacroStripOuterParentheses(expression)
        If strippedExpression <> expression Then
            expression = strippedExpression
            Continue While
        End If
        If Left(expression, 1) <> "*" Then Exit While
        dereferenceCount += 1
        expression = Trim(Mid(expression, 2))
    Wend
    If dereferenceCount = 0 Then Return 0
    Dim pointerName As String = _
        GenericMacroStripOuterParentheses(expression)
    If IsIdentifierToken(pointerName) = 0 Then Return 0

    Dim parameterIndex As Long = -1
    For candidateIndex As Long = 0 To parameterCount - 1
        If parameterNames(candidateIndex) = pointerName Then
            parameterIndex = candidateIndex
            Exit For
        End If
    Next
    If parameterIndex < 0 OrElse _
       IsGenericInlinePointerType(parameterTypes(parameterIndex)) = 0 Then Return 0

    Dim pointerElementType As String = Trim(parameterTypes(parameterIndex))
    If Left(pointerElementType, 6) = "Const " Then _
        pointerElementType = Trim(Mid(pointerElementType, 7))
    Dim parameterPointerDepth As Long = 0
    While Right(pointerElementType, 4) = " Ptr"
        pointerElementType = Trim(Left( _
            pointerElementType, Len(pointerElementType) - 4))
        parameterPointerDepth += 1
    Wend
    If parameterPointerDepth = 0 OrElse _
       parameterPointerDepth > MAX_FREEBASIC_POINTER_LEVELS OrElse _
       IsGenericInlineCallbackType(translation, pointerElementType) <> 0 Then Return 0

    Dim returnBaseType As String = Trim(returnType)
    If Left(returnBaseType, 6) = "Const " Then _
        returnBaseType = Trim(Mid(returnBaseType, 7))
    Dim returnPointerDepth As Long = 0
    While Right(returnBaseType, 4) = " Ptr"
        returnBaseType = Trim(Left( _
            returnBaseType, Len(returnBaseType) - 4))
        returnPointerDepth += 1
    Wend

    If returnPointerDepth = 0 Then
        If IsGenericInlineIntegerType(translation, returnType) = 0 OrElse _
           IsGenericInlineIntegerType(translation, pointerElementType) = 0 OrElse _
           parameterPointerDepth <> dereferenceCount Then Return 0
    Else
        If IsGenericInlinePointerType(returnType) = 0 OrElse _
           parameterPointerDepth <> dereferenceCount + returnPointerDepth OrElse _
           IsGenericInlineCallbackType(translation, returnBaseType) <> 0 Then Return 0
        Dim parameterBaseStorage As String = _
            GenericHeaderTypeAliasStorageTypeInHeader( _
                translation.genericC.header, pointerElementType, 0)
        Dim returnBaseStorage As String = _
            GenericHeaderTypeAliasStorageTypeInHeader( _
                translation.genericC.header, returnBaseType, 0)
        If parameterBaseStorage = "" Then parameterBaseStorage = pointerElementType
        If returnBaseStorage = "" Then returnBaseStorage = returnBaseType
        If LCase(parameterBaseStorage) <> "any" AndAlso _
           LCase(returnBaseStorage) <> "any" AndAlso _
           LCase(parameterBaseStorage) <> LCase(returnBaseStorage) Then Return 0
    End If

    freeBasicExpression = "(" & freeParameterNames(parameterIndex) & ")"
    For dereferenceIndex As Long = 1 To dereferenceCount
        freeBasicExpression = "*(" & freeBasicExpression & ")"
    Next
    Return -1
End Function

Private Function TranslateGenericInlineIntegerPointerArithmetic( _
    ByRef translation As C2fbTranslationContext, _
    ByVal returnType As String, ByVal expression As String, _
    parameterNames() As String, freeParameterNames() As String, _
    parameterTypes() As String, ByVal parameterCount As Long, _
    ByRef freeBasicExpression As String _
) As Long
    If IsGenericInlineIntegerType(translation, returnType) = 0 OrElse _
       GenericInlineExpressionHasDivisionOperator(expression) <> 0 Then Return 0

    Dim tokens() As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        expression, tokens(), tokenCount) = 0 OrElse _
       GenericMacroExpressionTokenSequenceSupported( _
           translation, expression, parameterNames(), freeParameterNames(), _
           parameterCount, 0) = 0 Then Return 0

    Dim hasIntegerPointerDereference As Long = 0
    For tokenIndex As Long = 0 To tokenCount - 1
        If IsIdentifierToken(tokens(tokenIndex)) = 0 Then
            Dim firstByte As Long = Asc(tokens(tokenIndex), 1)
            If ((firstByte >= Asc("0") AndAlso firstByte <= Asc("9")) OrElse _
                (firstByte = Asc(".") AndAlso Len(tokens(tokenIndex)) > 1 AndAlso _
                 Asc(tokens(tokenIndex), 2) >= Asc("0") AndAlso _
                 Asc(tokens(tokenIndex), 2) <= Asc("9"))) AndAlso _
               GenericInlineNumericTokenIsFloating(tokens(tokenIndex)) <> 0 Then _
                Return 0
            Continue For
        End If
        Dim parameterIndex As Long = -1
        For candidateIndex As Long = 0 To parameterCount - 1
            If parameterNames(candidateIndex) = tokens(tokenIndex) Then
                parameterIndex = candidateIndex
                Exit For
            End If
        Next
        If parameterIndex < 0 Then
            If GenericEnumMemberIndexInContext( _
                translation, tokens(tokenIndex)) >= 0 Then Continue For
            Dim symbolIndex As Long = _
                GenericHeaderSymbolIndexInContext(translation, tokens(tokenIndex))
            If symbolIndex < 0 OrElse _
               translation.symbolTable.symbols(symbolIndex).kind <> _
                   GENERIC_SYMBOL_OBJECT OrElse _
               IsGenericInlineIntegerType(translation, _
                   translation.symbolTable.symbols(symbolIndex).genericHeader.freeBasicType) = 0 Then _
                Return 0
            Continue For
        End If

        If IsGenericInlinePointerType(parameterTypes(parameterIndex)) <> 0 Then
            Dim pointerElementType As String = Trim(parameterTypes(parameterIndex))
            If Left(pointerElementType, 6) = "Const " Then _
                pointerElementType = Trim(Mid(pointerElementType, 7))
            If Right(pointerElementType, 4) <> " Ptr" Then Return 0
            pointerElementType = Trim(Left( _
                pointerElementType, Len(pointerElementType) - 4))
            If InStr(pointerElementType, " Ptr") <> 0 OrElse _
               IsGenericInlineIntegerType(translation, pointerElementType) = 0 Then _
                Return 0

            Dim isDirectDereference As Long = 0
            If tokenIndex > 0 AndAlso tokens(tokenIndex - 1) = "*" Then
                isDirectDereference = -1
            ElseIf tokenIndex >= 2 AndAlso tokenIndex < tokenCount - 1 AndAlso _
                   tokens(tokenIndex - 2) = "*" AndAlso _
                   tokens(tokenIndex - 1) = "(" AndAlso _
                   tokens(tokenIndex + 1) = ")" Then
                isDirectDereference = -1
            End If
            If isDirectDereference = 0 Then Return 0
            hasIntegerPointerDereference = -1
        ElseIf IsGenericInlineIntegerType( _
            translation, parameterTypes(parameterIndex)) = 0 Then
            Return 0
        End If
    Next

    If hasIntegerPointerDereference = 0 Then Return 0
    Return TranslateGenericMacroTokenSequence( _
        translation, expression, parameterNames(), freeParameterNames(), _
        parameterCount, 0, freeBasicExpression)
End Function

Private Function TranslateGenericInlineIntegerPointerIndex( _
    ByRef translation As C2fbTranslationContext, _
    ByVal expression As String, parameterNames() As String, _
    freeParameterNames() As String, parameterTypes() As String, _
    ByVal parameterCount As Long, ByRef freeBasicExpression As String _
) As Long
    expression = Trim(expression)
    If Left(expression, 1) = "*" Then
        Dim pointerExpressionStart As Long = 2
        While pointerExpressionStart <= Len(expression) AndAlso _
              IsSpaceByte(Asc(expression, pointerExpressionStart)) <> 0
            pointerExpressionStart += 1
        Wend
        If pointerExpressionStart <= Len(expression) AndAlso _
           Asc(expression, pointerExpressionStart) = Asc("(") Then
            Dim pointerExpressionEnd As Long = pointerExpressionStart
            If ScanSimpleExpressionGroup( _
                expression, pointerExpressionEnd, Asc("("), Asc(")")) <> 0 AndAlso _
               Trim(Mid(expression, pointerExpressionEnd)) = "" Then
                Dim pointerOffsetExpression As String = GenericMacroStripOuterParentheses( _
                    Trim(Mid(expression, pointerExpressionStart + 1, _
                             pointerExpressionEnd - pointerExpressionStart - 2)))
                For candidateIndex As Long = 0 To parameterCount - 1
                    If IsGenericInlinePointerType( _
                        parameterTypes(candidateIndex)) = 0 Then Continue For
                    Dim pointerName As String = parameterNames(candidateIndex)
                    If Len(pointerOffsetExpression) <= Len(pointerName) OrElse _
                       Left(pointerOffsetExpression, Len(pointerName)) <> pointerName OrElse _
                       IsIdentifierPart(Asc( _
                           pointerOffsetExpression, Len(pointerName) + 1)) <> 0 Then Continue For
                    Dim pointerOffsetTail As String = Trim(Mid( _
                        pointerOffsetExpression, Len(pointerName) + 1))
                    If Len(pointerOffsetTail) < 2 OrElse _
                       (Left(pointerOffsetTail, 1) <> "+" AndAlso _
                        Left(pointerOffsetTail, 1) <> "-") Then Continue For
                    Dim indexText As String = Trim(Mid(pointerOffsetTail, 2))
                    If Left(pointerOffsetTail, 1) = "-" Then _
                        indexText = "- (" & indexText & ")"
                    If indexText <> "" Then _
                        expression = pointerName & "[" & indexText & "]"
                    Exit For
                Next
            End If
        End If
    End If

    Dim tokens() As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        expression, tokens(), tokenCount) = 0 OrElse tokenCount < 4 OrElse _
       IsIdentifierToken(tokens(0)) = 0 OrElse tokens(1) <> "[" OrElse _
       tokens(tokenCount - 1) <> "]" Then Return 0

    Dim pointerParameterIndex As Long = -1
    For parameterIndex As Long = 0 To parameterCount - 1
        If parameterNames(parameterIndex) = tokens(0) Then
            pointerParameterIndex = parameterIndex
            Exit For
        End If
    Next
    If pointerParameterIndex < 0 OrElse _
       IsGenericInlinePointerType(parameterTypes(pointerParameterIndex)) = 0 Then Return 0

    Dim pointerElementType As String = Trim(parameterTypes(pointerParameterIndex))
    If Left(pointerElementType, 6) = "Const " Then _
        pointerElementType = Trim(Mid(pointerElementType, 7))
    If Right(pointerElementType, 4) <> " Ptr" Then Return 0
    pointerElementType = Trim(Left( _
        pointerElementType, Len(pointerElementType) - 4))
    If InStr(pointerElementType, " Ptr") <> 0 OrElse _
       IsGenericInlineIntegerType(translation, pointerElementType) = 0 Then Return 0

    Dim groupOpen As Long = 1
    While groupOpen <= Len(expression) AndAlso _
          IsSpaceByte(Asc(expression, groupOpen)) <> 0
        groupOpen += 1
    Wend
    While groupOpen <= Len(expression) AndAlso _
          IsIdentifierPart(Asc(expression, groupOpen)) <> 0
        groupOpen += 1
    Wend
    While groupOpen <= Len(expression) AndAlso _
          IsSpaceByte(Asc(expression, groupOpen)) <> 0
        groupOpen += 1
    Wend
    If groupOpen > Len(expression) OrElse _
       Asc(expression, groupOpen) <> Asc("[") Then Return 0
    Dim groupEnd As Long = groupOpen
    If ScanSimpleExpressionGroup( _
        expression, groupEnd, Asc("["), Asc("]")) = 0 OrElse _
       Trim(Mid(expression, groupEnd)) <> "" Then Return 0

    Dim indexExpression As String = Trim(Mid( _
        expression, groupOpen + 1, groupEnd - groupOpen - 2))
    If indexExpression = "" OrElse _
       GenericInlineExpressionHasDivisionOperator(indexExpression) <> 0 OrElse _
       GenericMacroExpressionTokenSequenceSupported( _
           translation, indexExpression, parameterNames(), freeParameterNames(), _
           parameterCount, 0) = 0 Then Return 0

    Dim indexTokens() As String
    Dim indexTokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        indexExpression, indexTokens(), indexTokenCount) = 0 Then Return 0
    For tokenIndex As Long = 0 To indexTokenCount - 1
        Dim tokenText As String = indexTokens(tokenIndex)
        If IsIdentifierToken(tokenText) <> 0 Then
            Dim parameterIndex As Long = -1
            For candidateIndex As Long = 0 To parameterCount - 1
                If parameterNames(candidateIndex) = tokenText Then
                    parameterIndex = candidateIndex
                    Exit For
                End If
            Next
            If parameterIndex >= 0 Then
                If IsGenericInlineIntegerType( _
                    translation, parameterTypes(parameterIndex)) = 0 Then Return 0
            ElseIf GenericEnumMemberIndexInContext(translation, tokenText) < 0 Then
                Dim symbolIndex As Long = _
                    GenericHeaderSymbolIndexInContext(translation, tokenText)
                If symbolIndex < 0 OrElse _
                   translation.symbolTable.symbols(symbolIndex).kind <> _
                       GENERIC_SYMBOL_OBJECT OrElse _
                   IsGenericInlineIntegerType(translation, _
                       translation.symbolTable.symbols(symbolIndex).genericHeader.freeBasicType) = 0 Then _
                    Return 0
            End If
        Else
            Dim firstByte As Long = Asc(tokenText, 1)
            If ((firstByte >= Asc("0") AndAlso firstByte <= Asc("9")) OrElse _
                (firstByte = Asc(".") AndAlso Len(tokenText) > 1 AndAlso _
                 Asc(tokenText, 2) >= Asc("0") AndAlso _
                 Asc(tokenText, 2) <= Asc("9"))) AndAlso _
               GenericInlineNumericTokenIsFloating(tokenText) <> 0 Then Return 0
        End If
    Next

    Dim freeBasicIndex As String
    If TranslateGenericMacroTokenSequence( _
        translation, indexExpression, parameterNames(), freeParameterNames(), _
        parameterCount, 0, freeBasicIndex) = 0 Then Return 0
    freeBasicExpression = "*(" & freeParameterNames(pointerParameterIndex) & _
        " + (" & freeBasicIndex & "))"
    Return -1
End Function

Private Function IsGenericInlineCallbackType( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceType As String _
) As Long
    Dim typeName As String = Trim(sourceType)
    If Left(typeName, 6) = "Const " Then typeName = Trim(Mid(typeName, 7))
    If Left(LCase(typeName), 9) = "function " OrElse _
       Left(LCase(typeName), 4) = "sub " Then Return -1
    For aliasIndex As Long = 0 To _
        translation.genericC.header.headerTypeAliasCount - 1
        With translation.genericC.header.headerTypeAliases(aliasIndex)
            If .isTag = 0 AndAlso .isFunction <> 0 AndAlso _
               (.sourceName = typeName OrElse _
                LCase(.freeBasicName) = LCase(typeName)) Then Return -1
        End With
    Next
    Return 0
End Function

Private Function IsGenericHeaderFunctionDefinition( _
    ByRef declaration As C2fbDeclarationModel _
) As Long
    If declaration.isFunctionDefinition = 0 OrElse _
       declaration.isConditional <> 0 Then Return 0
    Dim declaratorStart As Long = _
        declaration.functionDeclaration.declaratorStartToken
    With declaration.functionDeclaration.declarator
        If declaratorStart <= 0 OrElse .operatorCount <= 0 OrElse _
           .operatorKind(0) <> C2FB_DECLARATOR_FUNCTION Then Return 0
        For operatorIndex As Long = 1 To .operatorCount - 1
            If .operatorKind(operatorIndex) <> C2FB_DECLARATOR_POINTER Then _
                Return 0
        Next
    End With

    Return -1
End Function

Private Function HasGenericStaticStorage( _
    ByRef declaration As C2fbDeclarationModel _
) As Long
    Dim declaratorStart As Long = _
        declaration.functionDeclaration.declaratorStartToken
    For tokenIndex As Long = 0 To declaratorStart - 1
        If declaration.tokens(tokenIndex) = "static" Then Return -1
    Next
    Return 0
End Function

Private Function ResolveGenericInlineReturnType( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef declaration As C2fbDeclarationModel, _
    ByRef returnType As String _
) As Long
    returnType = ""
    Dim functionDeclaration As C2fbFunctionDeclarationModel = _
        declaration.functionDeclaration
    Dim declaratorStart As Long = functionDeclaration.declaratorStartToken
    If declaratorStart <= 0 OrElse declaratorStart > MAX_TYPE_WORDS Then Return 0

    Dim returnTypeTokens() As String
    ReDim returnTypeTokens(0 To MAX_TYPE_WORDS - 1)
    Dim returnTypeTokenCount As Long = 0
    For tokenIndex As Long = 0 To declaratorStart - 1
        Select Case declaration.tokens(tokenIndex)
        Case "static", "inline", "__inline", "__inline__", _
             "extern", "register", "__extension__"
            Continue For
        End Select
        If returnTypeTokenCount >= MAX_TYPE_WORDS Then Return 0
        AddToken(returnTypeTokens(), returnTypeTokenCount, _
                 declaration.tokens(tokenIndex))
    Next
    Dim returnPointerCount As Long = _
        functionDeclaration.declarator.operatorCount - 1
    If returnPointerCount < 0 OrElse _
       returnTypeTokenCount + returnPointerCount > _
           UBound(returnTypeTokens) + 1 Then _
        Return 0
    For pointerIndex As Long = 1 To returnPointerCount
        AddToken(returnTypeTokens(), returnTypeTokenCount, "*")
    Next
    If returnTypeTokenCount = 0 Then Return 0

    Dim resolvedType As C2fbResolvedTypeModel
    ResolveC2fbTypeModel( _
        translation, catalog, returnTypeTokens(), 0, returnTypeTokenCount - 1, _
        resolvedType, C2FB_POINTER_MAPPING_PRESERVE, _
        C2FB_TYPE_MAPPING_GENERIC_HEADER)
    If resolvedType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Return 0
    returnType = resolvedType.freeBasicType
    If resolvedType.pointerCount > 0 AndAlso _
       IsGenericInlinePointerType(resolvedType.freeBasicType) <> 0 Then
        Return -1
    End If
    If resolvedType.pointerCount <> 0 Then Return 0
    If IsGenericInlineCallbackType( _
        translation, resolvedType.freeBasicType) <> 0 Then
        Return -1
    End If
    If IsGenericInlineIntegerType( _
        translation, resolvedType.freeBasicType) = 0 AndAlso _
       IsGenericInlineFloatingType( _
        translation, resolvedType.freeBasicType) = 0 Then Return 0

    If Left(returnType, 6) = "Const " Then returnType = Mid(returnType, 7)
    Return -1
End Function

Private Function TranslateGenericInlineFloatingExpression( _
    ByRef translation As C2fbTranslationContext, _
    ByVal expression As String, parameterNames() As String, _
    freeParameterNames() As String, ByVal parameterCount As Long, _
    ByRef freeBasicExpression As String _
) As Long
    Dim normalizedExpression As String
    If RewriteGenericMacroCharacterConstants( _
        expression, normalizedExpression) = 0 Then Return 0

    Dim tokens() As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        normalizedExpression, tokens(), tokenCount) = 0 OrElse _
       tokenCount = 0 Then Return 0

    Dim expectsOperand As Long = -1
    Dim parenthesisDepth As Long = 0
    freeBasicExpression = ""
    For tokenIndex As Long = 0 To tokenCount - 1
        Dim tokenText As String = tokens(tokenIndex)
        If expectsOperand <> 0 Then
            Select Case tokenText
            Case "+", "-"
                freeBasicExpression &= " " & tokenText
                Continue For
            Case "("
                parenthesisDepth += 1
                freeBasicExpression &= " ("
                Continue For
            End Select

            Dim translatedToken As String
            If GenericMacroTokenNumber( _
                translation, tokenText, translatedToken) <> 0 Then
                freeBasicExpression &= " " & translatedToken
                expectsOperand = 0
                Continue For
            End If

            If IsIdentifierToken(tokenText) <> 0 Then
                Dim parameterIndex As Long = -1
                For candidateIndex As Long = 0 To parameterCount - 1
                    If parameterNames(candidateIndex) = tokenText Then
                        parameterIndex = candidateIndex
                        Exit For
                    End If
                Next
                If parameterIndex < 0 Then Return 0
                freeBasicExpression &= " (" & _
                    freeParameterNames(parameterIndex) & ")"
                expectsOperand = 0
                Continue For
            End If
            Return 0
        End If

        Select Case tokenText
        Case ")"
            If parenthesisDepth <= 0 Then Return 0
            parenthesisDepth -= 1
            freeBasicExpression &= " )"
        Case "+", "-", "*", "/"
            freeBasicExpression &= " " & tokenText
            expectsOperand = -1
        Case Else
            Return 0
        End Select
    Next

    If expectsOperand <> 0 OrElse parenthesisDepth <> 0 Then Return 0
    freeBasicExpression = Trim(freeBasicExpression)
    Return IIf(freeBasicExpression <> "", -1, 0)
End Function

Private Function TranslateGenericInlineIntegerCastFromFloatingExpression( _
    ByRef translation As C2fbTranslationContext, _
    ByVal expression As String, parameterNames() As String, _
    freeParameterNames() As String, parameterTypes() As String, _
    ByVal parameterCount As Long, ByRef freeBasicExpression As String _
) As Long
    expression = Trim(expression)
    If Left(expression, 1) <> "(" Then Return 0
    Dim typeEnd As Long = 1
    If ScanSimpleExpressionGroup( _
        expression, typeEnd, Asc("("), Asc(")")) = 0 Then Return 0
    Dim sourceType As String = Trim(Mid(expression, 2, typeEnd - 3))
    Dim sourceOperand As String = Trim(Mid(expression, typeEnd))
    If sourceOperand = "" Then Return 0

    Dim freeBasicType As String
    Dim isPointerCast As Long
    If GenericHeaderMacroCastType( _
        translation, sourceType, freeBasicType, isPointerCast) = 0 OrElse _
       isPointerCast <> 0 OrElse _
       IsGenericInlineIntegerType(translation, freeBasicType) = 0 OrElse _
       GenericInlineFloatingExpressionHasFloatingOperand( _
           translation, sourceOperand, parameterNames(), parameterTypes(), _
           parameterCount) = 0 Then Return 0

    Dim floatingExpression As String
    If TranslateGenericInlineFloatingExpression( _
        translation, sourceOperand, parameterNames(), freeParameterNames(), _
        parameterCount, floatingExpression) = 0 Then Return 0
    Dim typedExpression As String
    If WrapGenericInlineParameterReferences( _
        translation, floatingExpression, freeParameterNames(), parameterTypes(), _
        parameterCount, typedExpression) = 0 Then Return 0

    freeBasicExpression = "Cast(" & freeBasicType & ", Fix(" & _
        typedExpression & "))"
    Return -1
End Function

Private Function TranslateGenericInlinePointerExpression( _
    ByRef translation As C2fbTranslationContext, _
    ByVal expression As String, parameterNames() As String, _
    freeParameterNames() As String, parameterTypes() As String, _
    ByVal parameterCount As Long, _
    ByRef freeBasicExpression As String _
) As Long
    expression = GenericMacroStripOuterParentheses(Trim(expression))
    If IsIdentifierToken(expression) <> 0 Then
        For parameterIndex As Long = 0 To parameterCount - 1
            If parameterNames(parameterIndex) = expression Then
                freeBasicExpression = "(" & _
                    freeParameterNames(parameterIndex) & ")"
                Return -1
            End If
        Next
        Return 0
    End If

    If GenericNullPointerConstantText(expression) <> 0 OrElse _
       GenericNullPointerConstantInContext(translation, expression) <> 0 Then
        freeBasicExpression = "0"
        Return -1
    End If
    If TryTranslateGenericHeaderStringPointerCast( _
        translation, expression, freeBasicExpression) <> 0 Then Return -1
    If TranslateGenericHeaderStringMacro( _
        expression, freeBasicExpression) <> 0 Then Return -1
    If Left(expression, 1) = "(" AndAlso _
       TranslateGenericHeaderMacroExpressionWithParameters( _
           translation, expression, freeBasicExpression, parameterNames(), _
           freeParameterNames(), parameterCount) <> 0 Then Return -1

    Dim expressionTokens() As String
    Dim expressionTokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        expression, expressionTokens(), expressionTokenCount) = 0 OrElse _
       expressionTokenCount <> 3 Then Return 0
    Dim operatorText As String = expressionTokens(1)
    If operatorText <> "+" AndAlso operatorText <> "-" Then Return 0

    Dim pointerParameterIndex As Long = -1
    Dim offsetParameterIndex As Long = -1
    Dim pointerIsOnRight As Long = 0
    For parameterIndex As Long = 0 To parameterCount - 1
        If expressionTokens(0) = parameterNames(parameterIndex) AndAlso _
           IsGenericInlinePointerType(parameterTypes(parameterIndex)) <> 0 Then
            pointerParameterIndex = parameterIndex
        ElseIf expressionTokens(2) = parameterNames(parameterIndex) AndAlso _
               IsGenericInlinePointerType(parameterTypes(parameterIndex)) <> 0 Then
            pointerParameterIndex = parameterIndex
            pointerIsOnRight = -1
        End If
        If expressionTokens(0) = parameterNames(parameterIndex) OrElse _
           expressionTokens(2) = parameterNames(parameterIndex) Then
            If IsGenericInlineIntegerType( _
                translation, parameterTypes(parameterIndex)) <> 0 Then _
                offsetParameterIndex = parameterIndex
        End If
    Next
    If pointerParameterIndex >= 0 AndAlso offsetParameterIndex >= 0 Then
        If pointerIsOnRight <> 0 AndAlso operatorText <> "+" Then Return 0
        Dim pointerType As String = parameterTypes(pointerParameterIndex)
        Dim pointerBaseType As String = Trim(pointerType)
        If Left(pointerBaseType, 6) = "Const " Then _
            pointerBaseType = Trim(Mid(pointerBaseType, 7))
        Dim pointerDepth As Long = 0
        While Right(pointerBaseType, 4) = " Ptr"
            pointerBaseType = Trim(Left( _
                pointerBaseType, Len(pointerBaseType) - 4))
            pointerDepth += 1
        Wend
        If pointerDepth = 1 AndAlso LCase(pointerBaseType) = "any" Then _
            pointerType = "UByte Ptr"
        Dim pointerExpression As String = "Cast(" & pointerType & ", (" & _
            freeParameterNames(pointerParameterIndex) & "))"
        Dim offsetExpression As String = "Cast(" & _
            parameterTypes(offsetParameterIndex) & ", (" & _
            freeParameterNames(offsetParameterIndex) & "))"
        Dim translatedOperator As String = operatorText
        If pointerIsOnRight <> 0 Then translatedOperator = "+"
        freeBasicExpression = pointerExpression & " " & translatedOperator & _
            " " & offsetExpression
        Return -1
    End If

    If pointerIsOnRight = 0 AndAlso pointerParameterIndex >= 0 AndAlso _
       offsetParameterIndex < 0 AndAlso operatorText <> "+" AndAlso _
       operatorText <> "-" Then Return 0
    If pointerIsOnRight = 0 AndAlso pointerParameterIndex >= 0 AndAlso _
       offsetParameterIndex < 0 Then
        Dim pointerType As String = parameterTypes(pointerParameterIndex)
        Dim pointerBaseType As String = Trim(pointerType)
        If Left(pointerBaseType, 6) = "Const " Then _
            pointerBaseType = Trim(Mid(pointerBaseType, 7))
        Dim pointerDepth As Long = 0
        While Right(pointerBaseType, 4) = " Ptr"
            pointerBaseType = Trim(Left( _
                pointerBaseType, Len(pointerBaseType) - 4))
            pointerDepth += 1
        Wend
        If pointerDepth = 1 AndAlso LCase(pointerBaseType) = "any" Then _
            pointerType = "UByte Ptr"
        Dim offsetValue As Long
        If EvaluateSimpleArrayBound( _
            expressionTokens(2), offsetValue, MAX_GENERIC_ARRAY_COUNT, -1) = 0 Then _
            Return 0
        Dim translatedOffset As String
        If GenericMacroTokenNumber( _
            translation, expressionTokens(2), translatedOffset) = 0 Then Return 0
        Dim pointerExpression As String = "Cast(" & pointerType & ", (" & _
            freeParameterNames(pointerParameterIndex) & "))"
        freeBasicExpression = pointerExpression & " " & operatorText & _
            " Cast(Long, " & translatedOffset & ")"
        Return -1
    End If
    Return 0
End Function

Private Function TranslateGenericInlineCallbackExpression( _
    ByRef translation As C2fbTranslationContext, _
    ByVal expression As String, parameterNames() As String, _
    freeParameterNames() As String, parameterTypes() As String, _
    ByVal parameterCount As Long, _
    ByRef freeBasicExpression As String _
) As Long
    expression = GenericMacroStripOuterParentheses(Trim(expression))
    If IsIdentifierToken(expression) <> 0 Then
        For parameterIndex As Long = 0 To parameterCount - 1
            If parameterNames(parameterIndex) = expression AndAlso _
               IsGenericInlineCallbackType( _
                    translation, parameterTypes(parameterIndex)) <> 0 Then
                freeBasicExpression = freeParameterNames(parameterIndex)
                Return -1
            End If
        Next

        If GenericNullPointerConstantText(expression) <> 0 OrElse _
           GenericNullPointerConstantInContext(translation, expression) <> 0 Then
            freeBasicExpression = "0"
            Return -1
        End If

        Dim symbolIndex As Long = _
            GenericHeaderSymbolIndexInContext(translation, expression)
        If symbolIndex >= 0 Then
            With translation.symbolTable.symbols(symbolIndex)
                If .kind = GENERIC_SYMBOL_FUNCTION OrElse _
                   .kind = GENERIC_SYMBOL_SUB Then
                    freeBasicExpression = "ProcPtr(" & .freeBasicName & ")"
                    Return -1
                ElseIf .kind = GENERIC_SYMBOL_OBJECT AndAlso _
                       IsGenericInlineCallbackType( _
                            translation, .genericHeader.freeBasicType) <> 0 Then
                    freeBasicExpression = .freeBasicName
                    Return -1
                End If
            End With
        End If
        Return 0
    End If

    If TranslateGenericHeaderMacroExpressionWithParameters( _
        translation, expression, freeBasicExpression, parameterNames(), _
        freeParameterNames(), parameterCount) <> 0 Then Return -1
    Return 0
End Function

Private Function ReadGenericInlineReturnExpression( _
    ByVal bodyText As String, ByRef returnExpression As String _
) As Long
    returnExpression = ""
    bodyText = Trim(bodyText)
    If Left(bodyText, 1) = "{" Then bodyText = Mid(bodyText, 2)
    If Right(bodyText, 1) = "}" Then bodyText = Left(bodyText, Len(bodyText) - 1)
    Dim position As Long = 1
    If ReadSimpleReturn(bodyText, position, returnExpression) = 0 Then Return 0
    SkipCSpaces(bodyText, position)
    If position <= Len(bodyText) OrElse Trim(returnExpression) = "" Then Return 0
    returnExpression = Trim(returnExpression)
    Return -1
End Function

Private Function BuildGenericInlineMacroParameters( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef declaration As C2fbDeclarationModel, _
    parameterNames() As String, freeParameterNames() As String, _
    parameterTypes() As String, _
    ByRef parameterCount As Long _
) As Long
    ReDim parameterNames(0 To MAX_TYPE_WORDS - 1)
    ReDim freeParameterNames(0 To MAX_TYPE_WORDS - 1)
    ReDim parameterTypes(0 To MAX_TYPE_WORDS - 1)
    parameterCount = 0

    Dim tokens() As String
    Dim tokenCount As Long = declaration.tokenCount
    If tokenCount = 0 OrElse tokenCount >= MAX_TYPE_WORDS Then Return 0
    ReDim tokens(0 To tokenCount - 1)
    For tokenIndex As Long = 0 To tokenCount - 1
        tokens(tokenIndex) = declaration.tokens(tokenIndex)
    Next
    Dim openToken As Long = _
        declaration.functionDeclaration.declarator.firstFunctionOpenToken
    Dim closePosition As Long = openToken
    If openToken < 0 OrElse SkipCDeclaratorGroup( _
        tokens(), closePosition, tokenCount - 1, "(", ")") = 0 Then Return 0
    Dim closeToken As Long = closePosition - 1
    If openToken + 1 > closeToken Then Return -1
    If openToken + 1 = closeToken AndAlso tokens(openToken + 1) = "void" Then _
        Return -1

    Dim parameterRanges() As C2fbTokenRangeModel
    Dim parameterRangeCount As Long
    If SplitC2fbTokenList( _
        tokens(), openToken + 1, closeToken - 1, _
        parameterRanges(), parameterRangeCount) = 0 OrElse _
       parameterRangeCount <= 0 Then Return 0
    If parameterRangeCount = 1 AndAlso _
       parameterRanges(0).firstToken = parameterRanges(0).lastToken AndAlso _
       tokens(parameterRanges(0).firstToken) = "void" Then Return -1

    For rangeIndex As Long = 0 To parameterRangeCount - 1
        Dim firstToken As Long = parameterRanges(rangeIndex).firstToken
        Dim lastToken As Long = parameterRanges(rangeIndex).lastToken
        Dim parameterResult As C2fbParameterConversionResultModel
        ConvertParameterInContext( _
            translation, catalog, tokens(), firstToken, lastToken, _
            parameterCount, parameterResult, C2FB_POINTER_MAPPING_PRESERVE, _
            C2FB_TYPE_MAPPING_GENERIC_HEADER, declaration.sourceName)
        If parameterResult.status <> C2FB_PARAMETER_CONVERSION_CONVERTED OrElse _
           IsIdentifierToken(parameterResult.sourceName) = 0 OrElse _
           (IsGenericInlineIntegerType( _
                translation, parameterResult.freeBasicType) = 0 AndAlso _
            IsGenericInlineFloatingType( _
                translation, parameterResult.freeBasicType) = 0 AndAlso _
            IsGenericInlinePointerType( _
                parameterResult.freeBasicType) = 0 AndAlso _
            IsGenericInlineCallbackType( _
                translation, parameterResult.freeBasicType) = 0) Then Return 0

        Dim hasDeclaredName As Long = 0
        For tokenIndex As Long = firstToken To lastToken
            If tokens(tokenIndex) = parameterResult.sourceName AndAlso _
               IsTypeOrQualifierTokenInContext( _
                   translation, tokens(tokenIndex)) = 0 Then
                hasDeclaredName = -1
                Exit For
            End If
        Next
        If hasDeclaredName = 0 Then Return 0
        For priorParameter As Long = 0 To parameterCount - 1
            If parameterNames(priorParameter) = parameterResult.sourceName Then Return 0
        Next

        parameterNames(parameterCount) = parameterResult.sourceName
        freeParameterNames(parameterCount) = _
            "c2fb_inline_arg_" & Trim(Str(parameterCount))
        parameterTypes(parameterCount) = parameterResult.freeBasicType
        parameterCount += 1
    Next
    Return -1
End Function

Private Function GenericInlineMacroParameterUsageAllowed( _
    ByVal expression As String, parameterNames() As String, _
    ByVal parameterCount As Long, ByVal forceConversion As Long _
) As Long
    ' FBFrog's force option permits unused and repeated macro parameters.
    ' Keep the default path exact so each C argument is evaluated once.
    If forceConversion <> 0 Then Return -1
    Dim tokens() As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        expression, tokens(), tokenCount) = 0 Then Return 0
    For parameterIndex As Long = 0 To parameterCount - 1
        Dim useCount As Long = 0
        For tokenIndex As Long = 0 To tokenCount - 1
            If tokenIndex > 0 AndAlso _
               (tokens(tokenIndex - 1) = "->" OrElse _
                tokens(tokenIndex - 1) = ".") Then Continue For
            If tokens(tokenIndex) = parameterNames(parameterIndex) Then _
                useCount += 1
        Next
        ' Macro substitution must not evaluate an argument more or less than
        ' the C inline call would evaluate its parameter expression.
        If useCount <> 1 Then Return 0
    Next
    Return -1
End Function

Private Function GenericInlineNumericTokenIsFloating( _
    ByVal tokenText As String _
) As Long
    Dim lowerToken As String = LCase(tokenText)
    If InStr(lowerToken, ".") <> 0 Then Return -1
    If Left(lowerToken, 2) = "0x" Then _
        Return CInt(InStr(lowerToken, "p") <> 0) * -1
    Return CInt(InStr(lowerToken, "e") <> 0 OrElse _
                InStr(lowerToken, "p") <> 0) * -1
End Function

Private Function GenericInlineIntegerDivisionOperandsSupported( _
    ByRef translation As C2fbTranslationContext, ByVal expression As String, _
    parameterNames() As String, parameterTypes() As String, _
    ByVal parameterCount As Long _
) As Long
    Dim normalizedExpression As String
    If RewriteGenericMacroCharacterConstants( _
        expression, normalizedExpression) = 0 Then Return 0

    Dim tokens() As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        normalizedExpression, tokens(), tokenCount) = 0 Then Return 0

    Dim hasIntegerDivision As Long = 0
    For tokenIndex As Long = 0 To tokenCount - 1
        Dim tokenText As String = tokens(tokenIndex)
        If tokenText = "/" OrElse tokenText = "%" Then
            hasIntegerDivision = -1
            Continue For
        End If

        If IsIdentifierToken(tokenText) <> 0 Then
            Dim parameterIndex As Long = -1
            For candidateIndex As Long = 0 To parameterCount - 1
                If parameterNames(candidateIndex) = tokenText Then
                    parameterIndex = candidateIndex
                    Exit For
                End If
            Next
            If parameterIndex >= 0 Then
                If IsGenericInlineIntegerType( _
                    translation, parameterTypes(parameterIndex)) = 0 Then Return 0
                Continue For
            End If

            If GenericEnumMemberIndexInContext(translation, tokenText) >= 0 Then _
                Continue For
            Dim symbolIndex As Long = _
                GenericHeaderSymbolIndexInContext(translation, tokenText)
            If symbolIndex < 0 OrElse _
               translation.symbolTable.symbols(symbolIndex).kind <> _
                   GENERIC_SYMBOL_OBJECT OrElse _
               IsGenericInlineIntegerType(translation, _
                   translation.symbolTable.symbols(symbolIndex).genericHeader.freeBasicType) = 0 Then _
                Return 0
            Continue For
        End If

        Dim firstByte As Long = Asc(tokenText, 1)
        If (firstByte >= Asc("0") AndAlso firstByte <= Asc("9")) OrElse _
           (firstByte = Asc(".") AndAlso Len(tokenText) > 1 AndAlso _
            Asc(tokenText, 2) >= Asc("0") AndAlso _
            Asc(tokenText, 2) <= Asc("9")) Then
            If GenericInlineNumericTokenIsFloating(tokenText) <> 0 Then Return 0
        End If
    Next
    Return CInt(hasIntegerDivision <> 0) * -1
End Function

Private Function GenericInlineFloatingExpressionHasFloatingOperand( _
    ByRef translation As C2fbTranslationContext, ByVal expression As String, _
    parameterNames() As String, parameterTypes() As String, _
    ByVal parameterCount As Long _
) As Long
    Dim normalizedExpression As String
    If RewriteGenericMacroCharacterConstants( _
        expression, normalizedExpression) = 0 Then Return 0

    Dim tokens() As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        normalizedExpression, tokens(), tokenCount) = 0 Then Return 0

    Dim hasFloatingOperand As Long = 0
    For tokenIndex As Long = 0 To tokenCount - 1
        Dim tokenText As String = tokens(tokenIndex)
        If IsIdentifierToken(tokenText) <> 0 Then
            Dim parameterIndex As Long = -1
            For candidateIndex As Long = 0 To parameterCount - 1
                If parameterNames(candidateIndex) = tokenText Then
                    parameterIndex = candidateIndex
                    Exit For
                End If
            Next
            If parameterIndex < 0 Then Return 0
            If IsGenericInlineFloatingType( _
                translation, parameterTypes(parameterIndex)) <> 0 Then
                hasFloatingOperand = -1
            ElseIf IsGenericInlineIntegerType( _
                translation, parameterTypes(parameterIndex)) = 0 Then
                Return 0
            End If
            Continue For
        End If

        Dim firstByte As Long = Asc(tokenText, 1)
        If (firstByte >= Asc("0") AndAlso firstByte <= Asc("9")) OrElse _
           (firstByte = Asc(".") AndAlso Len(tokenText) > 1 AndAlso _
            Asc(tokenText, 2) >= Asc("0") AndAlso _
            Asc(tokenText, 2) <= Asc("9")) Then
            If GenericInlineNumericTokenIsFloating(tokenText) <> 0 Then _
                hasFloatingOperand = -1
        End If
    Next
    Return CInt(hasFloatingOperand <> 0) * -1
End Function

Private Function GenericInlineExpressionUsesRecordAccess( _
    ByVal expression As String _
) As Long
    Dim tokens() As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        expression, tokens(), tokenCount) = 0 Then Return 0
    For tokenIndex As Long = 0 To tokenCount - 1
        Select Case tokens(tokenIndex)
        Case "->", ".", "[", "]": Return -1
        End Select
    Next
    Return 0
End Function

Private Function GenericInlineExpressionHasDivisionOperator( _
    ByVal expression As String _
) As Long
    Dim tokens() As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        expression, tokens(), tokenCount) = 0 Then Return -1
    For tokenIndex As Long = 0 To tokenCount - 1
        If tokens(tokenIndex) = "/" OrElse tokens(tokenIndex) = "%" Then _
            Return -1
    Next
    Return 0
End Function

Private Function TranslateGenericInlineRecordAccessExpression( _
    ByRef translation As C2fbTranslationContext, ByVal expression As String, _
    parameterNames() As String, freeParameterNames() As String, _
    ByVal parameterCount As Long, ByRef freeBasicExpression As String _
) As Long
    If GenericInlineExpressionUsesRecordAccess(expression) = 0 OrElse _
       GenericInlineExpressionHasDivisionOperator(expression) <> 0 OrElse _
       GenericMacroExpressionTokenSequenceSupported( _
           translation, expression, parameterNames(), freeParameterNames(), _
           parameterCount, 0) = 0 Then Return 0

    Dim translatedSource As String
    Dim position As Long = 1
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    While position <= Len(expression)
        Dim currentByte As Long = Asc(expression, position)
        If quoteByte <> 0 Then
            translatedSource &= Chr(currentByte)
            If escaped <> 0 Then
                escaped = 0
            ElseIf currentByte = Asc(Chr(92)) Then
                escaped = -1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
            position += 1
            Continue While
        ElseIf currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
            quoteByte = currentByte
            translatedSource &= Chr(currentByte)
            position += 1
            Continue While
        ElseIf IsIdentifierStart(currentByte) = 0 Then
            translatedSource &= Chr(currentByte)
            position += 1
            Continue While
        End If

        Dim tokenStart As Long = position
        position += 1
        While position <= Len(expression) AndAlso _
              IsIdentifierPart(Asc(expression, position)) <> 0
            position += 1
        Wend
        Dim tokenText As String = Mid(expression, tokenStart, position - tokenStart)
        Dim previousPosition As Long = tokenStart - 1
        While previousPosition > 0 AndAlso _
              IsSpaceByte(Asc(expression, previousPosition)) <> 0
            previousPosition -= 1
        Wend
        Dim isRecordField As Long = 0
        If previousPosition > 0 AndAlso _
           Asc(expression, previousPosition) = Asc(".") Then
            isRecordField = -1
        ElseIf previousPosition > 1 AndAlso _
               Asc(expression, previousPosition) = Asc(">") AndAlso _
               Asc(expression, previousPosition - 1) = Asc("-") Then
            isRecordField = -1
        End If

        Dim parameterIndex As Long = -1
        If isRecordField = 0 Then
            For candidateIndex As Long = 0 To parameterCount - 1
                If parameterNames(candidateIndex) = tokenText Then
                    parameterIndex = candidateIndex
                    Exit For
                End If
            Next
        End If
        If parameterIndex < 0 Then
            translatedSource &= tokenText
        Else
            translatedSource &= "(" & freeParameterNames(parameterIndex) & ")"
        End If
    Wend

    Dim emptyParameterNames(0 To 0) As String
    Dim emptyFreeParameterNames(0 To 0) As String
    Return TranslateGenericMacroTokenSequence( _
        translation, translatedSource, emptyParameterNames(), _
        emptyFreeParameterNames(), 0, 0, freeBasicExpression)
End Function

Private Function WrapGenericInlineParameterReferences( _
    ByRef translation As C2fbTranslationContext, _
    ByVal expression As String, freeParameterNames() As String, _
    parameterTypes() As String, ByVal parameterCount As Long, _
    ByRef typedExpression As String _
) As Long
    typedExpression = ""
    Dim position As Long = 1
    While position <= Len(expression)
        Dim currentByte As Long = Asc(expression, position)
        If IsIdentifierStart(currentByte) = 0 Then
            typedExpression &= Chr(currentByte)
            position += 1
            Continue While
        End If

        Dim tokenStart As Long = position
        position += 1
        While position <= Len(expression) AndAlso _
              IsIdentifierPart(Asc(expression, position)) <> 0
            position += 1
        Wend
        Dim tokenText As String = Mid(expression, tokenStart, position - tokenStart)
        Dim previousPosition As Long = tokenStart - 1
        While previousPosition > 0 AndAlso _
              IsSpaceByte(Asc(expression, previousPosition)) <> 0
            previousPosition -= 1
        Wend
        Dim isRecordField As Long = 0
        If previousPosition > 0 AndAlso _
           Asc(expression, previousPosition) = Asc(".") Then
            isRecordField = -1
        ElseIf previousPosition > 1 AndAlso _
               Asc(expression, previousPosition) = Asc(">") AndAlso _
               Asc(expression, previousPosition - 1) = Asc("-") Then
            isRecordField = -1
        End If
        Dim parameterIndex As Long = -1
        If isRecordField = 0 Then
            For candidateIndex As Long = 0 To parameterCount - 1
                If freeParameterNames(candidateIndex) = tokenText Then
                    parameterIndex = candidateIndex
                    Exit For
                End If
            Next
        End If
        If parameterIndex < 0 Then
            typedExpression &= tokenText
        Else
            Dim parameterType As String = Trim(parameterTypes(parameterIndex))
            If Left(parameterType, 6) = "Const " Then _
                parameterType = Trim(Mid(parameterType, 7))
            If IsGenericInlineIntegerType( _
                translation, parameterType) <> 0 Then
                ' Fix truncates floating arguments and preserves integer widths.
                typedExpression &= "Cast(" & parameterType & ", Fix((" & _
                    tokenText & ")))"
            ElseIf IsGenericInlineFloatingType( _
                translation, parameterType) <> 0 Then
                typedExpression &= "Cast(" & parameterType & ", (" & _
                    tokenText & "))"
            ElseIf IsGenericInlinePointerType(parameterType) <> 0 Then
                If Left(parameterType, 6) = "Const " Then _
                    parameterType = Trim(Mid(parameterType, 7))
                typedExpression &= "Cast(" & parameterType & ", (" & _
                    tokenText & "))"
            ElseIf IsGenericInlineCallbackType( _
                translation, parameterType) <> 0 Then
                typedExpression &= "(" & tokenText & ")"
            Else
                Return 0
            End If
        End If
    Wend
    Return -1
End Function

Private Function TranslateGenericInlineParameterIncrement( _
    ByRef translation As C2fbTranslationContext, _
    ByVal returnType As String, ByVal expression As String, _
    parameterNames() As String, freeParameterNames() As String, _
    parameterTypes() As String, ByVal parameterCount As Long, _
    ByRef freeBasicExpression As String _
) As Long
    Dim tokens() As String
    Dim tokenCount As Long
    expression = GenericMacroStripOuterParentheses(Trim(expression))
    If TokenizeCPreprocessorReplacement( _
        expression, tokens(), tokenCount) = 0 OrElse tokenCount <> 2 Then Return 0

    Dim isPrefix As Long = 0
    Dim operatorText As String
    Dim sourceParameterName As String
    If tokens(0) = "++" OrElse tokens(0) = "--" Then
        isPrefix = -1
        operatorText = tokens(0)
        sourceParameterName = tokens(1)
    ElseIf tokens(1) = "++" OrElse tokens(1) = "--" Then
        operatorText = tokens(1)
        sourceParameterName = tokens(0)
    Else
        Return 0
    End If
    If IsIdentifierToken(sourceParameterName) = 0 Then Return 0

    Dim parameterIndex As Long = -1
    For candidateIndex As Long = 0 To parameterCount - 1
        If parameterNames(candidateIndex) = sourceParameterName Then
            parameterIndex = candidateIndex
            Exit For
        End If
    Next
    If parameterIndex < 0 Then Return 0

    If IsGenericInlinePointerType(parameterTypes(parameterIndex)) <> 0 Then
        If IsGenericInlinePointerType(returnType) = 0 Then Return 0
        If isPrefix = 0 Then
            freeBasicExpression = freeParameterNames(parameterIndex)
            Return -1
        End If
        Dim pointerExpression As String = sourceParameterName & " + 1"
        If operatorText = "--" Then _
            pointerExpression = sourceParameterName & " - 1"
        Return TranslateGenericInlinePointerExpression( _
            translation, pointerExpression, parameterNames(), _
            freeParameterNames(), parameterTypes(), parameterCount, _
            freeBasicExpression)
    End If

    If IsGenericInlineIntegerType( _
        translation, parameterTypes(parameterIndex)) <> 0 Then
        freeBasicExpression = freeParameterNames(parameterIndex)
        If isPrefix <> 0 Then
            If operatorText = "++" Then
                freeBasicExpression &= " + 1"
            Else
                freeBasicExpression &= " - 1"
            End If
        End If
        Return -1
    End If

    If IsGenericInlineFloatingType( _
        translation, parameterTypes(parameterIndex)) <> 0 Then
        freeBasicExpression = freeParameterNames(parameterIndex)
        If isPrefix <> 0 Then
            If operatorText = "++" Then
                freeBasicExpression &= " + 1"
            Else
                freeBasicExpression &= " - 1"
            End If
        End If
        If IsGenericInlineIntegerType(translation, returnType) <> 0 Then _
            freeBasicExpression = "Fix(" & freeBasicExpression & ")"
        Return -1
    End If

    Return 0
End Function

Private Function GenericInlineExpressionHasLazyOperator( _
    ByVal expression As String _
) As Long
    Dim tokens() As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        expression, tokens(), tokenCount) = 0 Then Return -1
    For tokenIndex As Long = 0 To tokenCount - 1
        Select Case tokens(tokenIndex)
        Case "&&", "||", "?": Return -1
        End Select
    Next
    Return 0
End Function

Private Function ParenthesizeGenericInlineParameters( _
    ByVal expression As String, parameterNames() As String, _
    ByVal parameterCount As Long, ByRef result As String _
) As Long
    result = ""
    Dim position As Long = 1
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    While position <= Len(expression)
        Dim currentByte As Long = Asc(expression, position)
        If quoteByte <> 0 Then
            result &= Chr(currentByte)
            If escaped <> 0 Then
                escaped = 0
            ElseIf currentByte = Asc(Chr(92)) Then
                escaped = -1
            ElseIf currentByte = quoteByte Then
                quoteByte = 0
            End If
            position += 1
        ElseIf currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
            quoteByte = currentByte
            result &= Chr(currentByte)
            position += 1
        ElseIf IsIdentifierStart(currentByte) <> 0 Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(expression) AndAlso _
                  IsIdentifierPart(Asc(expression, position)) <> 0
                position += 1
            Wend
            Dim token As String = Mid(expression, tokenStart, position - tokenStart)
            Dim isParameter As Long = 0
            For parameterIndex As Long = 0 To parameterCount - 1
                If parameterNames(parameterIndex) = token Then
                    isParameter = -1
                    Exit For
                End If
            Next
            Dim previousPosition As Long = tokenStart - 1
            While previousPosition > 0 AndAlso _
                  IsSpaceByte(Asc(expression, previousPosition)) <> 0
                previousPosition -= 1
            Wend
            Dim isRecordField As Long = 0
            If previousPosition > 0 AndAlso _
               Asc(expression, previousPosition) = Asc(".") Then
                isRecordField = -1
            ElseIf previousPosition > 1 AndAlso _
                   Asc(expression, previousPosition) = Asc(">") AndAlso _
                   Asc(expression, previousPosition - 1) = Asc("-") Then
                isRecordField = -1
            End If
            If isParameter <> 0 AndAlso isRecordField = 0 Then
                result &= "(" & token & ")"
            Else
                result &= token
            End If
        Else
            result &= Chr(currentByte)
            position += 1
        End If
    Wend
    Return -1
End Function

Private Function GenericHeaderHasFunctionPrototype( _
    ByRef translation As C2fbTranslationContext, ByVal sourceName As String _
) As Long
    Return CInt(C2fbStringIndexMapLookup( _
        translation.genericC.header.functionPrototypeIndex, sourceName) >= 0) * -1
End Function

Private Sub AppendGenericHeaderInlineFunctionEvents( _
    ByRef translation As C2fbTranslationContext, _
    ByVal preprocessedPath As String, ByVal sourcePath As String, _
    events() As C2fbGenericHeaderOccurrenceEventModel, _
    ByRef eventCount As Long _
)
    Dim scanRequest As C2fbDeclarationScanRequestModel
    ConfigureC2fbFunctionBodyScanRequest( _
        scanRequest, preprocessedPath, sourcePath)
    scanRequest.options.sourceMapMode = C2FB_SOURCE_MAP_PREPROCESSOR_MARKERS
    scanRequest.options.sourceOriginPrecision = _
        C2FB_SOURCE_ORIGIN_LINES_AVAILABLE
    scanRequest.options.collectHeaderInlineBodies = -1

    Dim scanner As C2fbFunctionScanner
    If OpenC2fbFunctionScanner(scanner, scanRequest) = 0 Then _
        ReportError("cannot read inline functions while applying occurrence removals")
    Dim sourceItem As C2fbSourceItemModel
    While NextC2fbSourceItem(translation.sourceUnit, scanner, sourceItem) <> 0
        If sourceItem.declaration.entryKind <> C2FB_DECLARATION_FUNCTION OrElse _
           sourceItem.declaration.isFunctionDefinition = 0 OrElse _
           sourceItem.declaration.sourceName = "" OrElse _
           GenericSourceIncludedInPolicy( _
               translation.genericC.policy, _
               sourceItem.declaration.sourceSpan.startLocation.path) = 0 Then _
            Continue While
        Dim occurrence As C2fbGenericHeaderOccurrenceEventModel
        occurrence.sourceName = sourceItem.declaration.sourceName
        occurrence.inputOrder = sourceItem.declaration.inputOrder
        occurrence.declarationIndex = -1
        occurrence.macroOccurrenceIndex = -1
        occurrence.partIndex = -1
        occurrence.kind = C2FB_HEADER_OCCURRENCE_FUNCTION
        occurrence.isInlineFunctionBody = -1
        If AppendGenericHeaderOccurrenceEvent( _
            events(), eventCount, occurrence) = 0 Then _
            ReportError("generic-header symbol occurrences exceed the configured limit")
    Wend
    CloseC2fbFunctionScanner(scanner)
End Sub

Private Sub WriteGenericHeaderInlineFunctionMacros( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourcePath As String, ByVal preprocessedPath As String, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    names() As String, ByRef nameCount As Long, _
    outputNames() As String, ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    Dim scanRequest As C2fbDeclarationScanRequestModel
    ConfigureC2fbFunctionBodyScanRequest( _
        scanRequest, preprocessedPath, sourcePath)
    scanRequest.options.sourceMapMode = C2FB_SOURCE_MAP_PREPROCESSOR_MARKERS
    scanRequest.options.sourceOriginPrecision = _
        C2FB_SOURCE_ORIGIN_LINES_AVAILABLE
    scanRequest.options.collectHeaderInlineBodies = -1

    Dim scanner As C2fbFunctionScanner
    If OpenC2fbFunctionScanner(scanner, scanRequest) = 0 Then _
        ReportError("cannot read function bodies from the generic header")
    Dim sourceItem As C2fbSourceItemModel
    Dim convertedCount As Long = 0
    While NextC2fbSourceItem(translation.sourceUnit, scanner, sourceItem) <> 0
        If GenericSourceIncludedInPolicy( _
            translation.genericC.policy, _
            sourceItem.declaration.sourceSpan.startLocation.path) = 0 Then _
            Continue While
        Dim sourceName As String = sourceItem.declaration.sourceName
        If GenericProcedureExcludedInPolicy(translation.genericC.policy, sourceName) <> 0 Then _
            Continue While
        Dim forceRepeatedParameters As Long = _
            GenericInlineMacroForcedInPolicy( _
                translation.genericC.policy, sourceName)
        If IsGenericHeaderFunctionDefinition(sourceItem.declaration) = 0 AndAlso _
           forceRepeatedParameters = 0 Then Continue While
        If GenericHeaderFunctionOccurrenceRemoved( _
            translation, sourceName, sourceItem.declaration.inputOrder) <> 0 Then _
            Continue While

        Dim dropInlineBody As Long = GenericInlineBodyDroppedInPolicy( _
            translation.genericC.policy, sourceName)
        If translation.genericC.policy.suppressInlineFunctionBodies <> 0 OrElse _
           dropInlineBody <> 0 Then
            If HasGenericStaticStorage(sourceItem.declaration) = 0 AndAlso _
               GenericHeaderHasFunctionPrototype(translation, sourceName) = 0 Then
                EmitPrototypeModel( _
                    translation, catalog, sourceItem.declaration, outputFile, _
                    names(), nameCount, outputNames(), outputNameCount, _
                    conversionSummary, C2FB_TYPE_MAPPING_GENERIC_HEADER)
            End If
            Continue While
        End If

        Dim returnType As String
        Dim failureReason As String
        If HasGenericStaticStorage(sourceItem.declaration) = 0 AndAlso _
           GenericHeaderHasFunctionPrototype(translation, sourceName) <> 0 Then
            failureReason = "separate prototype conflicts with macro conversion"
        End If
        If failureReason = "" AndAlso ResolveGenericInlineReturnType( _
            translation, catalog, sourceItem.declaration, returnType) = 0 Then
            failureReason = "return type is outside the supported scalar, pointer, or callback macro subset: " & _
                returnType
        End If
        Dim returnExpression As String
        If failureReason = "" AndAlso ReadGenericInlineReturnExpression( _
            sourceItem.body, returnExpression) = 0 Then _
            failureReason = "body is not a single return expression"

        Dim parameterNames() As String
        Dim freeParameterNames() As String
        Dim parameterTypes() As String
        Dim parameterCount As Long = 0
        If failureReason = "" AndAlso BuildGenericInlineMacroParameters( _
            translation, catalog, sourceItem.declaration, parameterNames(), _
            freeParameterNames(), parameterTypes(), parameterCount) = 0 Then _
            failureReason = "parameter list is outside the integer macro subset"
        Dim hasFloatingReturnType As Long = CInt( _
            IsGenericInlineFloatingType(translation, returnType) <> 0) * -1
        Dim integerDivisionAssumed As Long = 0
        If failureReason = "" AndAlso _
           (IsGenericInlineIntegerType(translation, returnType) <> 0 OrElse _
            hasFloatingReturnType <> 0) AndAlso _
           GenericInlineIntegerDivisionOperandsSupported( _
               translation, returnExpression, parameterNames(), parameterTypes(), _
               parameterCount) <> 0 Then integerDivisionAssumed = -1
        Dim hasFloatingExpression As Long = 0
        If failureReason = "" AndAlso _
           IsGenericInlineIntegerType(translation, returnType) <> 0 Then _
            hasFloatingExpression = GenericInlineFloatingExpressionHasFloatingOperand( _
                translation, returnExpression, parameterNames(), parameterTypes(), _
                parameterCount)
        Dim hasPointerReturnType As Long = CInt( _
            IsGenericInlinePointerType(returnType) <> 0) * -1
        Dim hasCallbackReturnType As Long = CInt( _
            IsGenericInlineCallbackType(translation, returnType) <> 0) * -1
        If failureReason = "" AndAlso GenericInlineMacroParameterUsageAllowed( _
            returnExpression, parameterNames(), parameterCount, _
            forceRepeatedParameters) = 0 Then _
            failureReason = "macro substitution would repeat or omit a parameter"
        If failureReason = "" AndAlso forceRepeatedParameters = 0 AndAlso _
           parameterCount > 0 AndAlso _
           GenericInlineExpressionHasLazyOperator(returnExpression) <> 0 Then _
            failureReason = "parameterized lazy expression would change argument evaluation"

        Dim freeBasicExpression As String
        Dim isDirectCallMacro As Long = 0
        If failureReason = "" Then
            isDirectCallMacro = CInt(TranslateGenericFunctionCallMacro( _
                translation, returnExpression, parameterNames(), _
                freeParameterNames(), parameterCount, 0, _
                freeBasicExpression) <> 0) * -1
        End If
        If failureReason = "" AndAlso isDirectCallMacro = 0 Then
            If TranslateGenericInlineParameterIncrement( _
                translation, returnType, returnExpression, parameterNames(), _
                freeParameterNames(), parameterTypes(), parameterCount, _
                freeBasicExpression) <> 0 Then
                Dim typedExpression As String
                If WrapGenericInlineParameterReferences( _
                    translation, freeBasicExpression, freeParameterNames(), _
                    parameterTypes(), parameterCount, typedExpression) = 0 Then
                    failureReason = "increment parameter typing could not be preserved"
                Else
                    freeBasicExpression = typedExpression
                End If
            ElseIf IsGenericInlineIntegerType(translation, returnType) <> 0 AndAlso _
               TranslateGenericInlineIntegerCastFromFloatingExpression( _
                   translation, returnExpression, parameterNames(), _
                   freeParameterNames(), parameterTypes(), parameterCount, _
                   freeBasicExpression) <> 0 Then
                ' Fix preserves C's truncating conversion from floating to integer.
            ElseIf hasCallbackReturnType <> 0 Then
                If TranslateGenericInlineCallbackExpression( _
                    translation, returnExpression, parameterNames(), _
                    freeParameterNames(), parameterTypes(), parameterCount, _
                    freeBasicExpression) = 0 Then _
                    failureReason = "return expression is outside the callback macro subset"
            ElseIf (IsGenericInlineIntegerType(translation, returnType) <> 0 OrElse _
                    hasPointerReturnType <> 0) AndAlso _
                   TranslateGenericInlinePointerDereference( _
                       translation, returnType, returnExpression, _
                       parameterNames(), freeParameterNames(), parameterTypes(), _
                       parameterCount, freeBasicExpression) <> 0 Then
                Dim typedExpression As String
                If WrapGenericInlineParameterReferences( _
                    translation, freeBasicExpression, freeParameterNames(), _
                    parameterTypes(), parameterCount, typedExpression) = 0 Then
                    failureReason = "pointer dereference parameter typing could not be preserved"
                Else
                    freeBasicExpression = typedExpression
                End If
            ElseIf hasPointerReturnType <> 0 Then
                If TranslateGenericInlinePointerExpression( _
                    translation, returnExpression, parameterNames(), _
                    freeParameterNames(), parameterTypes(), parameterCount, _
                    freeBasicExpression) = 0 Then _
                    failureReason = "return expression is outside the pointer macro subset"
            ElseIf IsGenericInlineIntegerType(translation, returnType) <> 0 AndAlso _
                   TranslateGenericInlineIntegerPointerIndex( _
                       translation, returnExpression, parameterNames(), _
                       freeParameterNames(), parameterTypes(), parameterCount, _
                       freeBasicExpression) <> 0 Then
                Dim typedExpression As String
                If WrapGenericInlineParameterReferences( _
                    translation, freeBasicExpression, freeParameterNames(), _
                    parameterTypes(), parameterCount, typedExpression) = 0 Then
                    failureReason = "pointer index parameter typing could not be preserved"
                Else
                    freeBasicExpression = typedExpression
                End If
            ElseIf IsGenericInlineIntegerType(translation, returnType) <> 0 AndAlso _
                   TranslateGenericInlineIntegerPointerArithmetic( _
                       translation, returnType, returnExpression, parameterNames(), _
                       freeParameterNames(), parameterTypes(), parameterCount, _
                       freeBasicExpression) <> 0 Then
                Dim typedExpression As String
                If WrapGenericInlineParameterReferences( _
                    translation, freeBasicExpression, freeParameterNames(), _
                    parameterTypes(), parameterCount, typedExpression) = 0 Then
                    failureReason = "pointer expression parameter typing could not be preserved"
                Else
                    freeBasicExpression = typedExpression
                End If
            ElseIf hasFloatingReturnType <> 0 OrElse hasFloatingExpression <> 0 Then
                If integerDivisionAssumed <> 0 Then
                    Dim macroExpression As String
                    If ParenthesizeGenericInlineParameters( _
                        returnExpression, parameterNames(), parameterCount, _
                        macroExpression) = 0 OrElse _
                       GenericFunctionMacroBodySupported( _
                           returnExpression, 0, integerDivisionAssumed) = 0 OrElse _
                       TranslateGenericHeaderMacroExpressionWithParameters( _
                           translation, macroExpression, freeBasicExpression, _
                           parameterNames(), freeParameterNames(), parameterCount, _
                           integerDivisionAssumed) = 0 Then
                        failureReason = "return expression is outside the integer macro subset"
                    Else
                        Dim typedExpression As String
                        If WrapGenericInlineParameterReferences( _
                            translation, freeBasicExpression, freeParameterNames(), _
                            parameterTypes(), parameterCount, typedExpression) = 0 Then
                            failureReason = "integer division parameter typing could not be preserved"
                        Else
                            freeBasicExpression = typedExpression
                        End If
                    End If
                ElseIf TranslateGenericInlineFloatingExpression( _
                    translation, returnExpression, parameterNames(), _
                    freeParameterNames(), parameterCount, freeBasicExpression) = 0 Then
                    failureReason = "return expression is outside the floating macro subset"
                Else
                    Dim typedExpression As String
                    If WrapGenericInlineParameterReferences( _
                        translation, freeBasicExpression, freeParameterNames(), _
                        parameterTypes(), parameterCount, typedExpression) = 0 Then
                        failureReason = "floating parameter typing could not be preserved"
                    Else
                        freeBasicExpression = typedExpression
                        If hasFloatingReturnType = 0 Then _
                            freeBasicExpression = "Fix(" & freeBasicExpression & ")"
                    End If
                End If
            Else
                Dim macroExpression As String
                Dim integerExpressionTranslated As Long = 0
                If GenericInlineExpressionUsesRecordAccess(returnExpression) <> 0 Then
                    If integerDivisionAssumed = 0 Then _
                        integerExpressionTranslated = CInt( _
                            TranslateGenericInlineRecordAccessExpression( _
                                translation, returnExpression, parameterNames(), _
                                freeParameterNames(), parameterCount, _
                                freeBasicExpression) <> 0) * -1
                ElseIf ParenthesizeGenericInlineParameters( _
                    returnExpression, parameterNames(), parameterCount, _
                    macroExpression) <> 0 AndAlso _
                   GenericFunctionMacroBodySupported( _
                       returnExpression, 0, integerDivisionAssumed) <> 0 Then
                    integerExpressionTranslated = CInt( _
                        TranslateGenericHeaderMacroExpressionWithParameters( _
                            translation, macroExpression, freeBasicExpression, _
                            parameterNames(), freeParameterNames(), parameterCount, _
                            integerDivisionAssumed) <> 0) * -1
                End If
                If integerExpressionTranslated = 0 Then
                    failureReason = "return expression is outside the integer macro subset"
                Else
                    Dim typedExpression As String
                    If WrapGenericInlineParameterReferences( _
                        translation, freeBasicExpression, freeParameterNames(), _
                        parameterTypes(), parameterCount, typedExpression) = 0 Then
                        failureReason = "integer division parameter typing could not be preserved"
                    Else
                        freeBasicExpression = typedExpression
                    End If
                End If
            End If
        End If
        If failureReason = "" AndAlso isDirectCallMacro <> 0 Then
            Dim typedExpression As String
            If WrapGenericInlineParameterReferences( _
                translation, freeBasicExpression, freeParameterNames(), _
                parameterTypes(), parameterCount, typedExpression) = 0 Then
                failureReason = "direct-call parameter typing could not be preserved"
            Else
                freeBasicExpression = typedExpression
            End If
        End If

        If failureReason <> "" Then
            EmitC2fbSkippedAtLocation( _
                translation, outputFile, conversionSummary, _
                "unsupported header function body: " & failureReason, _
                sourceName, sourceItem.declaration.sourceSpan.startLocation)
            Continue While
        End If

        freeBasicExpression = "Cast(" & returnType & ", " & _
            freeBasicExpression & ")"
        Dim freeBasicName As String = GenericFreeBasicFunctionNameInContext( _
            translation, sourceName, outputNames(), outputNameCount, _
            C2FB_SYMBOL_RENAME_PROCEDURE)
        If forceRepeatedParameters <> 0 Then _
            forceRepeatedParameters = GenericInlineMacroForcedInPolicy( _
                translation.genericC.policy, sourceName, -1)
        If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES OrElse _
           conversionSummary.genericHeader.functionMacroCount >= MAX_FUNCTIONS Then _
            ReportError("generic header exceeds the inline function macro limit")
        If outputNameCount > UBound(outputNames) Then _
            ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
        outputNames(outputNameCount) = freeBasicName
        outputNameCount += 1

        Dim macroBinding As C2fbMacroBindingModel
        macroBinding.name = freeBasicName
        For parameterIndex As Long = 0 To parameterCount - 1
            If parameterIndex > 0 Then macroBinding.parameters &= ", "
            macroBinding.parameters &= freeParameterNames(parameterIndex)
        Next
        macroBinding.bodyText = freeBasicExpression
        macroBinding.isFunctionLike = -1
        WriteGenericMacroBindingWithGuardsInPolicy( _
            translation.genericC.policy, outputFile, sourceName, macroBinding)
        conversionSummary.genericHeader.functionMacroCount += 1
        convertedCount += 1
    Wend
    CloseC2fbFunctionScanner(scanner)
    If convertedCount > 0 Then WriteC2fbOutputLine(outputFile, "")
    If translation.genericC.policy.inlineMacroForceCount > 0 Then
        WriteC2fbOutputLine(outputFile, "' c2fb force-inline-macro mappings:")
        For forceIndex As Long = 0 To _
            translation.genericC.policy.inlineMacroForceCount - 1
            With translation.genericC.policy.inlineMacroForces(forceIndex)
                Dim stateText As String = "unused"
                If .matched <> 0 Then stateText = "matched"
                WriteC2fbOutputLine(outputFile, "' c2fb force-inline-macro " & _
                    stateText & ": " & .sourceName)
            End With
        Next
    End If
    If translation.genericC.policy.inlineBodyDropCount > 0 Then
        WriteC2fbOutputLine(outputFile, "' c2fb drop-inline-body mappings:")
        For dropIndex As Long = 0 To _
            translation.genericC.policy.inlineBodyDropCount - 1
            With translation.genericC.policy.inlineBodyDrops(dropIndex)
                Dim stateText As String = "unused"
                If .matched <> 0 Then stateText = "matched"
                WriteC2fbOutputLine(outputFile, "' c2fb drop-inline-body " & _
                    stateText & ": " & .sourceName)
            End With
        Next
    End If
End Sub

/' end of c2fb_generic_inline_functions.bi '/
