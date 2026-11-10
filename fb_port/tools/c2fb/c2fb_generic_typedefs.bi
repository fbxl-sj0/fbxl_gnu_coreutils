/'
    Project: C2FB generic declaration adapters

    File: c2fb_generic_typedefs.bi

    Purpose:

        Lower generic C typedef declarations into FreeBASIC type bindings.

    Responsibilities:

        - Reuse declaration tokens and shared C declarator models.
        - Lower scalar, array, and function typedefs under the generic C profile.
        - Distinguish non-array typedefs from unsupported array forms.
        - Register aliases and emit typed output bindings or skip diagnostics.
        - Keep generic typedef policy together with its output pass.

    This file intentionally does NOT contain:

        - Translation-unit scanning, preprocessing, or generic macro lowering.
        - SQLite-specific type mappings or body statement translation.
'/

Declare Sub EmitGenericTypedefSingle( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal declaration As String, ByRef outputFile As C2fbGeneratedFileOutputModel, _
    typeNames() As String, ByRef typeNameCount As Long, _
    outputNames() As String, ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel, ByVal passKind As C2fbGenericHeaderDeclarationPassKind = C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS _
)

Private Sub ReportGenericTypedefSkipped( _
    ByRef translation As C2fbTranslationContext, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, ByVal declaration As String, _
    ByRef conversionSummary As C2fbConversionSummaryModel, ByVal passKind As C2fbGenericHeaderDeclarationPassKind _
)
    If passKind <> C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS AndAlso _
       passKind <> C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS_AFTER_RECORDS Then Exit Sub
    EmitC2fbSkipped(translation, outputFile, conversionSummary, "unsupported typedef", declaration)
End Sub

Private Sub ReportGenericTypedefExcluded( _
    ByRef translation As C2fbTranslationContext, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, ByVal sourceName As String, _
    ByRef conversionSummary As C2fbConversionSummaryModel, _
    ByVal passKind As C2fbGenericHeaderDeclarationPassKind _
)
    If passKind <> C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS AndAlso _
       passKind <> C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS_AFTER_RECORDS Then Exit Sub
    EmitC2fbSkipped(translation, outputFile, conversionSummary, _
        "excluded typedef", sourceName)
End Sub

Private Function GenericFunctionTypeFromTypedef( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    sourceTokens() As String, ByVal sourceTokenCount As Long, _
    ByRef aliasName As String _
) As String
    aliasName = ""
    Dim tokens() As String
    Dim tokenCount As Long = sourceTokenCount - 1
    If tokenCount <= 0 OrElse tokenCount >= MAX_TYPE_WORDS Then Return ""
    ReDim tokens(0 To tokenCount - 1)
    For tokenIndex As Long = 0 To tokenCount - 1
        tokens(tokenIndex) = sourceTokens(tokenIndex + 1)
    Next
    If tokenCount < 3 OrElse tokenCount >= MAX_TYPE_WORDS Then Return ""

    ' C permits redundant parentheses around a function typedef's name. Strip
    ' only a top-level (identifier) before its parameter list; (*identifier)
    ' is a function pointer declarator and must keep its binding order.
    Dim parserTokens() As String
    ReDim parserTokens(0 To tokenCount - 1)
    Dim parserTokenCount As Long = 0
    Dim sourceIndex As Long = 0
    While sourceIndex < tokenCount
        If sourceIndex > 0 AndAlso sourceIndex + 3 < tokenCount AndAlso _
           tokens(sourceIndex) = "(" AndAlso _
           IsIdentifierToken(tokens(sourceIndex + 1)) <> 0 AndAlso _
           tokens(sourceIndex + 2) = ")" AndAlso _
           tokens(sourceIndex + 3) = "(" AndAlso _
           IsCFunctionReturnTypePrefix(tokens(), 0, sourceIndex - 1) <> 0 Then
            parserTokens(parserTokenCount) = tokens(sourceIndex + 1)
            parserTokenCount += 1
            sourceIndex += 3
        Else
            parserTokens(parserTokenCount) = tokens(sourceIndex)
            parserTokenCount += 1
            sourceIndex += 1
        End If
    Wend

    Dim parsedDeclaration As C2fbFunctionDeclarationModel
    If ParseCFunctionDeclarationModel( _
        parserTokens(), parserTokenCount, parsedDeclaration) = 0 Then Return ""
    aliasName = parsedDeclaration.declarator.name
    If parsedDeclaration.declarator.operatorCount = 0 OrElse _
       parsedDeclaration.declarator.operatorKind(0) <> C2FB_DECLARATOR_FUNCTION Then Return ""

    Dim hasCallbackReturn As Long = CInt( _
        IsFunctionReturnCallbackDeclarator(parsedDeclaration.declarator) <> 0)
    Dim returnPointerCount As Long = 0
    If hasCallbackReturn = 0 Then
        For bindingIndex As Long = 1 To parsedDeclaration.declarator.operatorCount - 1
            If parsedDeclaration.declarator.operatorKind(bindingIndex) <> _
               C2FB_DECLARATOR_POINTER Then Return ""
            returnPointerCount += 1
        Next
    End If

    Dim parameterOpen As Long = parsedDeclaration.declarator.firstFunctionOpenToken
    Dim closePosition As Long = parameterOpen
    If SkipCDeclaratorGroup( _
        parserTokens(), closePosition, parserTokenCount - 1, "(", ")") = 0 Then Return ""
    Dim parameterClose As Long = closePosition - 1

    Dim returnType As String
    If hasCallbackReturn <> 0 Then
        returnType = CFunctionReturnCallbackType( _
            translation, catalog, parserTokens(), parserTokenCount, _
            parsedDeclaration.declaratorStartToken, _
            parsedDeclaration.declarator, C2FB_TYPE_MAPPING_GENERIC_HEADER)
        If returnType = "" Then Return ""
    Else
        Dim returnTypeTokens() As String
        ReDim returnTypeTokens(0 To 31)
        Dim returnTokenCount As Long = 0
        For tokenIndex As Long = 0 To parsedDeclaration.declaratorStartToken - 1
            AddToken(returnTypeTokens(), returnTokenCount, parserTokens(tokenIndex))
        Next
        For pointerIndex As Long = 1 To returnPointerCount
            AddToken(returnTypeTokens(), returnTokenCount, "*")
        Next
        Dim resolvedReturnType As C2fbResolvedTypeModel
        ResolveC2fbTypeModel(translation, catalog, _
            returnTypeTokens(), 0, returnTokenCount - 1, resolvedReturnType, _
            C2FB_POINTER_MAPPING_OPAQUE, C2FB_TYPE_MAPPING_GENERIC_HEADER)
        If resolvedReturnType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Return ""
        returnType = resolvedReturnType.freeBasicType
    End If

    Dim parameters As String
    Dim parameterCount As Long = 0
    Dim parameterStart As Long = parameterOpen + 1
    Dim nesting As Long = 0
    Dim hasVarArgs As Long = 0
    For position As Long = parameterStart To parameterClose
        Dim atEnd As Long = CInt(position = parameterClose)
        If position < parameterClose Then
            Select Case parserTokens(position)
            Case "(": nesting += 1
            Case ")": If nesting > 0 Then nesting -= 1
            End Select
            If parserTokens(position) = "," AndAlso nesting = 0 Then atEnd = -1
        End If
        If atEnd <> 0 Then
            Dim parameterResult As C2fbParameterConversionResultModel
            ConvertParameterInContext( _
                translation, catalog, parserTokens(), _
                parameterStart, position - 1, parameterCount, parameterResult, _
                C2FB_POINTER_MAPPING_OPAQUE, C2FB_TYPE_MAPPING_GENERIC_HEADER, aliasName)
            If parameterResult.status = C2FB_PARAMETER_CONVERSION_VARIADIC Then
                hasVarArgs = -1
                Exit For
            ElseIf parameterResult.status = C2FB_PARAMETER_CONVERSION_UNSUPPORTED OrElse _
                   parameterResult.status = C2FB_PARAMETER_CONVERSION_INVALID Then
                Return ""
            ElseIf parameterResult.status = C2FB_PARAMETER_CONVERSION_CONVERTED Then
                If parameterCount > 0 Then parameters &= ", "
                ' C va_list is a function parameter value. ByRef adds an
                ' extra pointer indirection on targets where va_list itself
                ' is already a pointer (for example MinGW x86/x64).
                parameters &= "ByVal " & parameterResult.freeBasicDeclaration
                parameterCount += 1
            End If
            parameterStart = position + 1
        End If
    Next
    If hasVarArgs <> 0 Then
        If parameterCount > 0 Then parameters &= ", "
        parameters &= "..."
    End If

    Dim callingConvention As String = CFunctionReturnOuterCallConv( _
        parserTokens(), parsedDeclaration.declaratorStartToken)
    If callingConvention = "Invalid" Then Return ""
    If hasVarArgs <> 0 Then callingConvention = "CDecl"
    If returnType = "void" Then
        Return "Sub " & callingConvention & "(" & parameters & ")"
    End If
    Return "Function " & callingConvention & "(" & parameters & ") As " & returnType
End Function

Private Sub ParseGenericArrayTypedef( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal normalized As String, tokens() As String, _
    ByVal tokenCount As Long, _
    ByRef result As C2fbGenericArrayTypedefResultModel _
)
    result.status = C2FB_GENERIC_ARRAY_TYPEDEF_NOT_APPLICABLE
    result.aliasName = ""
    result.sourceElementType = ""
    result.characterKind = C2FB_C_CHARACTER_NONE
    result.elementType = ""
    result.arrayCount = 0
    result.arrayBounds = ""

    If tokenCount < 3 OrElse tokens(0) <> "typedef" OrElse _
       tokenCount >= MAX_TYPE_WORDS Then Exit Sub
    Dim lastToken As Long = tokenCount - 1
    If tokens(lastToken) = ";" Then lastToken -= 1

    Dim sourceArrayAlias As Long = -1
    Dim hasUnsupportedSpecifier As Long = 0
    Dim hasConstQualifier As Long = 0
    For tokenIndex As Long = 1 To lastToken - 1
        If tokens(tokenIndex) = "const" Then
            hasConstQualifier = -1
        ElseIf tokens(tokenIndex) = "volatile" Then
            Continue For
        Else
            Dim sourceAliasIndex As Long = _
                GenericHeaderTypeAliasIndexInHeader( _
                    translation.genericC.header, tokens(tokenIndex), 0)
            If sourceAliasIndex >= 0 AndAlso _
               translation.genericC.header.headerTypeAliases(sourceAliasIndex).isArray <> 0 AndAlso _
               sourceArrayAlias < 0 Then
                sourceArrayAlias = sourceAliasIndex
            Else
                hasUnsupportedSpecifier = -1
            End If
        End If
    Next
    If sourceArrayAlias >= 0 AndAlso hasUnsupportedSpecifier = 0 AndAlso _
       IsIdentifierToken(tokens(lastToken)) <> 0 Then
        result.aliasName = tokens(lastToken)
        result.elementType = _
            translation.genericC.header.headerTypeAliases(sourceArrayAlias).arrayElementType
        result.characterKind = _
            translation.genericC.header.headerTypeAliases(sourceArrayAlias).characterKind
        result.sourceElementType = _
            translation.genericC.header.headerTypeAliases(sourceArrayAlias).sourceName
        result.arrayCount = _
            translation.genericC.header.headerTypeAliases(sourceArrayAlias).arrayCount
        result.arrayBounds = _
            translation.genericC.header.headerTypeAliases(sourceArrayAlias).arrayBounds
        If hasConstQualifier <> 0 AndAlso InStr(result.elementType, " Ptr") = 0 AndAlso _
           Left(result.elementType, 6) <> "Const " Then _
            result.elementType = "Const " & result.elementType
        result.status = C2FB_GENERIC_ARRAY_TYPEDEF_CONVERTED
        Exit Sub
    End If

    For declaratorStart As Long = 2 To lastToken
        If IsCFunctionReturnTypePrefix(tokens(), 1, declaratorStart - 1) = 0 Then Continue For
        Dim position As Long = declaratorStart
        Dim candidate As C2fbDeclaratorModel
        If ParseCDeclaratorModel( _
            tokens(), position, lastToken, candidate) = 0 Then Continue For
        If InStr(candidate.bindingOrder, "A") = 0 Then Continue For
        result.status = C2FB_GENERIC_ARRAY_TYPEDEF_UNSUPPORTED
        If position <> lastToken + 1 OrElse _
           Left(candidate.bindingOrder, 1) <> "A" Then Exit Sub

        Dim arrayDimensions As Long = 0
        Dim pointerDepth As Long = 0
        For bindingIndex As Long = 1 To Len(candidate.bindingOrder)
            Select Case Mid(candidate.bindingOrder, bindingIndex, 1)
            Case "A": arrayDimensions += 1
            Case "P": pointerDepth += 1
            Case "F": Exit Sub
            End Select
        Next
        If arrayDimensions <= 0 OrElse _
           arrayDimensions > MAX_GENERIC_ARRAY_RANK Then Exit Sub
        Dim identifierPosition As Long = _
            GenericLastIdentifierPosition(normalized, candidate.name)
        Dim firstArrayDimensionCount As Long
        Dim isUnsized As Long
        If identifierPosition = 0 OrElse _
           ParseGenericArrayBoundsInDeclaration( _
            translation, normalized, identifierPosition + Len(candidate.name), _
            arrayDimensions, result.arrayBounds, firstArrayDimensionCount, _
            result.arrayCount, isUnsized, -1, 0) = 0 Then Exit Sub

        Dim baseTokens() As String
        ReDim baseTokens(0 To MAX_TYPE_WORDS - 1)
        Dim baseTokenCount As Long = 0
        For tokenIndex As Long = 1 To declaratorStart - 1
            AddToken(baseTokens(), baseTokenCount, tokens(tokenIndex))
            If result.sourceElementType <> "" Then _
                result.sourceElementType &= " "
            result.sourceElementType &= tokens(tokenIndex)
        Next
        result.characterKind = GenericHeaderCCharacterKindInType( _
            translation, result.sourceElementType)
        If baseTokenCount + pointerDepth >= MAX_TYPE_WORDS Then Exit Sub
        For pointerIndex As Long = 1 To pointerDepth
            AddToken(baseTokens(), baseTokenCount, "*")
        Next
        Dim resolvedElementType As C2fbResolvedTypeModel
        ResolveC2fbTypeModel(translation, catalog, _
            baseTokens(), 0, baseTokenCount - 1, resolvedElementType, _
            C2FB_POINTER_MAPPING_OPAQUE, C2FB_TYPE_MAPPING_GENERIC_HEADER)
        If resolvedElementType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then Exit Sub
        result.elementType = resolvedElementType.freeBasicType
        If result.elementType = "" OrElse result.elementType = "void" Then Exit Sub
        If resolvedElementType.isConst <> 0 AndAlso resolvedElementType.pointerCount = 0 Then _
            result.elementType = "Const " & result.elementType
        result.aliasName = candidate.name
        result.status = C2FB_GENERIC_ARRAY_TYPEDEF_CONVERTED
        Exit Sub
    Next
End Sub

Private Function GenericTypedefCommonType( _
    tokens() As String, ByVal firstPartLastToken As Long, _
    ByRef commonType As String, ByRef commonTypeLastToken As Long _
) As Long
    commonType = ""
    commonTypeLastToken = -1
    If firstPartLastToken < 2 OrElse tokens(0) <> "typedef" OrElse _
       firstPartLastToken >= MAX_TYPE_WORDS Then Return 0

    For declaratorStart As Long = 2 To firstPartLastToken
        If IsCFunctionReturnTypePrefix(tokens(), 1, declaratorStart - 1) = 0 Then Continue For
        Dim position As Long = declaratorStart
        Dim declarator As C2fbDeclaratorModel
        If ParseCDeclaratorModel( _
            tokens(), position, firstPartLastToken, declarator, 0, 0) = 0 Then Continue For
        If position <> firstPartLastToken + 1 OrElse _
           IsIdentifierToken(declarator.name) = 0 Then Continue For
        For tokenIndex As Long = 1 To declaratorStart - 1
            If commonType <> "" Then commonType &= " "
            commonType &= tokens(tokenIndex)
        Next
        commonTypeLastToken = declaratorStart - 1
        Return CInt(commonType <> "")
    Next
    Return 0
End Function

Private Function GenericTypedefCommonTypeFromText( _
    ByVal declaration As String, ByRef commonType As String _
) As Long
    commonType = ""
    Dim normalized As String = StripCFunctionAttributes(declaration)
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(normalized, tokens(), tokenCount)
    If tokenCount < 3 OrElse tokens(0) <> "typedef" OrElse _
       tokenCount >= MAX_TYPE_WORDS Then Return 0
    Dim lastToken As Long = tokenCount - 1
    If tokens(lastToken) = ";" Then lastToken -= 1

    For declaratorStart As Long = 2 To lastToken
        If IsCFunctionReturnTypePrefix(tokens(), 1, declaratorStart - 1) = 0 Then Continue For
        Dim position As Long = declaratorStart
        Dim declarator As C2fbDeclaratorModel
        If ParseCDeclaratorModel( _
            tokens(), position, lastToken, declarator, 0, 0) = 0 Then Continue For
        If position <> lastToken + 1 OrElse _
           IsIdentifierToken(declarator.name) = 0 Then Continue For
        For tokenIndex As Long = 1 To declaratorStart - 1
            If commonType <> "" Then commonType &= " "
            commonType &= tokens(tokenIndex)
        Next
        Return CInt(commonType <> "")
    Next
    Return 0
End Function

Declare Sub EmitGenericTypedefSingleWithTokens( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal declaration As String, ByVal normalized As String, _
    tokens() As String, ByVal tokenCount As Long, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, typeNames() As String, _
    ByRef typeNameCount As Long, outputNames() As String, _
    ByRef outputNameCount As Long, ByRef conversionSummary As C2fbConversionSummaryModel, _
    ByVal passKind As C2fbGenericHeaderDeclarationPassKind _
)
Declare Sub EmitGenericTypedefFromText( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal declaration As String, ByRef outputFile As C2fbGeneratedFileOutputModel, _
    typeNames() As String, ByRef typeNameCount As Long, _
    outputNames() As String, ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel, ByVal passKind As C2fbGenericHeaderDeclarationPassKind _
)

Private Function GenericTypedefAlignmentValue( _
    ByRef translation As C2fbTranslationContext, _
    ByVal declaration As String, ByVal sourceType As String, _
    ByVal aliasName As String, _
    ByRef ignoredAlignment As Long _
) As Long
    ignoredAlignment = 0
    Dim requestedAlignment As Long
    If ParseC2fbAlignmentAttributes( _
        declaration, requestedAlignment) = 0 Then Return 0

    If requestedAlignment = 0 Then
        Dim sourceTypeTokens() As String
        Dim sourceTypeTokenCount As Long
        TokenizeCDeclaration(sourceType, sourceTypeTokens(), sourceTypeTokenCount)
        For tokenIndex As Long = 0 To sourceTypeTokenCount - 1
            Dim aliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
                translation.genericC.header, sourceTypeTokens(tokenIndex), 0)
            If aliasIndex >= 0 Then
                requestedAlignment = _
                    translation.genericC.header.headerTypeAliases(aliasIndex).alignmentValue
                If requestedAlignment > 0 Then Return requestedAlignment
            End If
        Next
    End If
    If requestedAlignment = 0 Then _
        requestedAlignment = GenericTypeOverrideAlignmentInPolicy( _
            translation.genericC.policy, aliasName)
    If requestedAlignment = 0 Then Return 0

    Dim naturalAlignment As Long = _
        GenericHeaderAlignmentOfTypeInBytes(translation, sourceType)
    If naturalAlignment > 0 AndAlso requestedAlignment < naturalAlignment Then
        ignoredAlignment = -1
        Return 0
    End If
    If naturalAlignment = requestedAlignment Then Return 0
    Return requestedAlignment
End Function

Private Function GenericTypedefUsesUnemittedAlias( _
    ByRef translation As C2fbTranslationContext, _
    sourceTokens() As String, ByVal sourceTokenCount As Long, _
    ByVal aliasName As String, ByVal functionType As String _
) As Long
    Dim functionTokens() As String
    Dim functionTokenCount As Long
    TokenizeCDeclaration(functionType, functionTokens(), functionTokenCount)
    If functionTokenCount = 0 Then Return 0

    For tokenIndex As Long = 0 To sourceTokenCount - 1
        If sourceTokens(tokenIndex) = aliasName Then Continue For
        Dim aliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
            translation.genericC.header, sourceTokens(tokenIndex), 0)
        If aliasIndex < 0 Then Continue For
        If translation.genericC.header.headerTypeAliases(aliasIndex).emitted <> 0 Then _
            Continue For
        Dim freeBasicName As String = _
            translation.genericC.header.headerTypeAliases(aliasIndex).freeBasicName
        If freeBasicName = "" Then Continue For
        For functionTokenIndex As Long = 0 To functionTokenCount - 1
            If functionTokens(functionTokenIndex) <> freeBasicName AndAlso _
               functionTokens(functionTokenIndex) <> sourceTokens(tokenIndex) Then _
                Continue For
            Return -1
        Next
    Next
    Return 0
End Function

Private Function GenericTypedefUsesRecordByValue( _
    ByRef translation As C2fbTranslationContext, _
    ByVal functionType As String _
) As Long
    Dim functionTokens() As String
    Dim functionTokenCount As Long
    TokenizeCDeclaration(functionType, functionTokens(), functionTokenCount)
    If functionTokenCount = 0 Then Return 0

    For aliasIndex As Long = 0 To _
        translation.genericC.header.headerTypeAliasCount - 1
        With translation.genericC.header.headerTypeAliases(aliasIndex)
            If .freeBasicName = "" OrElse _
               GenericHeaderTypeAliasStorageTypeInHeader( _
                    translation.genericC.header, .freeBasicName, 0) <> "Record" Then _
                Continue For
            For tokenIndex As Long = 0 To functionTokenCount - 1
                If functionTokens(tokenIndex) <> .freeBasicName Then Continue For
                If tokenIndex + 1 < functionTokenCount AndAlso _
                   functionTokens(tokenIndex + 1) = "Ptr" Then Continue For
                Return -1
            Next
        End With
    Next
    Return 0
End Function

Private Function GenericTypedefNeedsRecordDependentDeclaration( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, tokens() As String, _
    ByVal tokenCount As Long, _
    ByVal passKind As C2fbGenericHeaderDeclarationPassKind _
) As Long
    If tokenCount < 3 OrElse tokenCount >= MAX_TYPE_WORDS Then Return 0

    Dim hasFunctionDeclarator As Long = 0
    For tokenIndex As Long = 1 To tokenCount - 1
        If tokens(tokenIndex) = "(" Then
            hasFunctionDeclarator = -1
            Exit For
        End If
    Next
    Dim functionType As String
    Dim aliasName As String
    If hasFunctionDeclarator <> 0 Then
        Dim callbackResult As C2fbCallbackTypeResultModel
        ResolveCBodyCallbackTypeInContext( _
            translation, catalog, tokens(), 1, tokenCount - 1, _
            callbackResult, 0, C2FB_TYPE_MAPPING_GENERIC_HEADER)
        If callbackResult.status = C2FB_CALLBACK_TYPE_CONVERTED Then
            aliasName = callbackResult.callbackName
            functionType = CBodyCallbackDeclarationInContext( _
                translation, callbackResult.freeBasicType)
        ElseIf callbackResult.status = C2FB_CALLBACK_TYPE_NOT_CALLBACK Then
            functionType = GenericFunctionTypeFromTypedef( _
                translation, catalog, tokens(), tokenCount, aliasName)
        End If
    Else
        Dim lastToken As Long = tokenCount - 1
        If tokens(lastToken) = ";" Then lastToken -= 1
        For tokenIndex As Long = lastToken To 1 Step -1
            If IsIdentifierToken(tokens(tokenIndex)) <> 0 Then
                aliasName = tokens(tokenIndex)
                Exit For
            End If
        Next
    End If
    If aliasName = "" Then Return 0
    Dim aliasIndex As Long = GenericHeaderTypeAliasIndexInHeader( _
        translation.genericC.header, aliasName, 0)
    If aliasIndex < 0 Then Return 0
    If passKind = C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS_AFTER_RECORDS Then
        Return translation.genericC.header.headerTypeAliases( _
            aliasIndex).deferredAfterRecords
    End If

    Dim typeText As String = functionType
    If hasFunctionDeclarator = 0 Then _
        typeText = translation.genericC.header.headerTypeAliases( _
            aliasIndex).baseType
    Dim hasRecordByValueReturn As Long = 0
    If hasFunctionDeclarator <> 0 AndAlso functionType <> "" Then
        Dim returnTypeStart As Long = 0
        For position As Long = 1 To Len(functionType) - 3
            If Mid(functionType, position, 4) = " As " Then _
                returnTypeStart = position + 4
        Next
        If returnTypeStart > 0 Then
            Dim returnType As String = Trim(Mid(functionType, returnTypeStart))
            If Left(returnType, 6) = "Const " Then returnType = Mid(returnType, 7)
            hasRecordByValueReturn = CInt( _
                GenericHeaderTypeAliasStorageTypeInHeader( _
                    translation.genericC.header, returnType, 0) = "Record") * -1
        End If
    End If
    Dim needsRecordDependentDeclaration As Long = CInt( _
        hasRecordByValueReturn <> 0 OrElse _
        (hasFunctionDeclarator <> 0 AndAlso _
         GenericTypedefUsesRecordByValue(translation, functionType) <> 0) OrElse _
        GenericTypedefUsesUnemittedAlias( _
            translation, tokens(), tokenCount, aliasName, typeText) <> 0) * -1
    If needsRecordDependentDeclaration <> 0 Then _
        translation.genericC.header.headerTypeAliases( _
            aliasIndex).deferredAfterRecords = -1
    Return needsRecordDependentDeclaration
End Function

Private Sub EmitGenericTypedef( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef declarationModel As C2fbDeclarationModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    typeNames() As String, ByRef typeNameCount As Long, _
    outputNames() As String, ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel, ByVal passKind As C2fbGenericHeaderDeclarationPassKind = C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS _
)
    Dim declaration As String = declarationModel.text
    Dim sourceTokenCount As Long = declarationModel.tokenCount
    If sourceTokenCount <= 0 OrElse sourceTokenCount >= MAX_TYPE_WORDS Then
        EmitGenericTypedefFromText( _
            translation, catalog, declaration, outputFile, typeNames(), _
            typeNameCount, outputNames(), outputNameCount, conversionSummary, passKind)
        Exit Sub
    End If

    Dim tokens() As String
    ReDim tokens(0 To sourceTokenCount - 1)
    For tokenIndex As Long = 0 To sourceTokenCount - 1
        tokens(tokenIndex) = declarationModel.tokens(tokenIndex)
    Next

    Dim ranges() As C2fbTokenRangeModel
    Dim rangeCount As Long = 0
    If SplitC2fbTokenList( _
        tokens(), 0, sourceTokenCount - 1, ranges(), rangeCount) = 0 Then
        EmitGenericTypedefFromText( _
            translation, catalog, declaration, outputFile, typeNames(), _
            typeNameCount, outputNames(), outputNameCount, conversionSummary, passKind)
        Exit Sub
    End If

    Dim parts() As String
    Dim partCount As Long
    If rangeCount > 1 Then
        If SplitSimpleCList(declaration, parts(), partCount) = 0 OrElse _
           partCount <> rangeCount Then
            EmitGenericTypedefFromText( _
                translation, catalog, declaration, outputFile, typeNames(), _
                typeNameCount, outputNames(), outputNameCount, conversionSummary, passKind)
            Exit Sub
        End If
    End If

    If rangeCount = 1 Then
        Dim singleCommonType As String
        Dim singleSourceName As String
        Dim singleBindingOrder As String
        If ParseGenericHeaderDeclarator( _
            declaration, singleCommonType, singleSourceName, _
            singleBindingOrder) <> 0 AndAlso _
           GenericHeaderPlainDeclaratorRemoved( _
               declarationModel, singleSourceName) <> 0 Then Exit Sub
        EmitGenericTypedefSingleWithTokens( _
            translation, catalog, declaration, _
            StripCFunctionAttributes(declaration), tokens(), sourceTokenCount, _
            outputFile, typeNames(), typeNameCount, outputNames(), _
            outputNameCount, conversionSummary, passKind)
        Exit Sub
    End If

    Dim commonType As String
    Dim commonTypeLastToken As Long
    If GenericTypedefCommonType( _
        tokens(), ranges(0).lastToken, commonType, commonTypeLastToken) = 0 Then
        EmitGenericTypedefFromText( _
            translation, catalog, declaration, outputFile, typeNames(), _
            typeNameCount, outputNames(), outputNameCount, conversionSummary, passKind)
        Exit Sub
    End If

    Dim commonTypeTokenCount As Long = commonTypeLastToken + 1
    Dim partOrder() As Long
    If passKind = C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS Then
        ApplyGenericMoveAboveToDeclarationParts( _
            translation, parts(), partCount, commonType, partOrder())
    Else
        ReDim partOrder(0 To partCount - 1)
        For partIndex As Long = 0 To partCount - 1
            partOrder(partIndex) = partIndex
        Next
    End If
    For partPosition As Long = 0 To partCount - 1
        Dim partIndex As Long = partOrder(partPosition)
        Dim itemDeclaration As String = Trim(parts(partIndex))
        If partIndex > 0 Then itemDeclaration = "typedef " & commonType & " " & itemDeclaration
        Dim itemCommonType As String
        Dim itemSourceName As String
        Dim itemBindingOrder As String
        If ParseGenericHeaderDeclarator( _
            itemDeclaration, itemCommonType, itemSourceName, _
            itemBindingOrder) <> 0 AndAlso _
           GenericHeaderPlainDeclaratorRemoved( _
               declarationModel, itemSourceName) <> 0 Then Continue For

        Dim itemTokens() As String
        Dim itemTokenCount As Long = 0
        If BuildC2fbDeclaratorPartTokens( _
            tokens(), ranges(), rangeCount, partIndex, commonTypeTokenCount, _
            itemTokens(), itemTokenCount) = 0 Then
            ReportGenericTypedefSkipped( _
                translation, outputFile, itemDeclaration, conversionSummary, passKind)
            Continue For
        End If
        EmitGenericTypedefSingleWithTokens( _
            translation, catalog, itemDeclaration, _
            StripCFunctionAttributes(itemDeclaration), itemTokens(), _
            itemTokenCount, outputFile, typeNames(), typeNameCount, _
            outputNames(), outputNameCount, conversionSummary, passKind)
    Next
End Sub

Private Sub EmitGenericTypedefFromText( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal declaration As String, ByRef outputFile As C2fbGeneratedFileOutputModel, _
    typeNames() As String, ByRef typeNameCount As Long, _
    outputNames() As String, ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel, ByVal passKind As C2fbGenericHeaderDeclarationPassKind _
)
    Dim parts() As String
    Dim partCount As Long
    If SplitSimpleCList(declaration, parts(), partCount) = 0 OrElse partCount <= 1 Then
        EmitGenericTypedefSingle( _
            translation, catalog, declaration, outputFile, typeNames(), _
            typeNameCount, outputNames(), outputNameCount, conversionSummary, passKind)
        Exit Sub
    End If

    Dim commonType As String
    If GenericTypedefCommonTypeFromText(parts(0), commonType) = 0 Then
        ReportGenericTypedefSkipped(translation, outputFile, declaration, conversionSummary, passKind)
        Exit Sub
    End If
    Dim partOrder() As Long
    If passKind = C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS Then
        ApplyGenericMoveAboveToDeclarationParts( _
            translation, parts(), partCount, commonType, partOrder())
    Else
        ReDim partOrder(0 To partCount - 1)
        For partIndex As Long = 0 To partCount - 1
            partOrder(partIndex) = partIndex
        Next
    End If
    For partPosition As Long = 0 To partCount - 1
        Dim partIndex As Long = partOrder(partPosition)
        Dim itemDeclaration As String = Trim(parts(partIndex))
        If partIndex > 0 Then itemDeclaration = "typedef " & commonType & " " & itemDeclaration
        EmitGenericTypedefSingle( _
            translation, catalog, itemDeclaration, outputFile, typeNames(), _
            typeNameCount, outputNames(), outputNameCount, conversionSummary, passKind)
    Next
End Sub

Private Sub EmitGenericTypedefSingle( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal declaration As String, ByRef outputFile As C2fbGeneratedFileOutputModel, _
    typeNames() As String, ByRef typeNameCount As Long, _
    outputNames() As String, ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel, ByVal passKind As C2fbGenericHeaderDeclarationPassKind = C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS _
)
    Dim normalized As String = StripCFunctionAttributes(declaration)
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(normalized, tokens(), tokenCount)
    EmitGenericTypedefSingleWithTokens( _
        translation, catalog, declaration, normalized, tokens(), tokenCount, _
        outputFile, typeNames(), typeNameCount, outputNames(), _
        outputNameCount, conversionSummary, passKind)
End Sub

Private Function GenericTypedefSourceTypeText( _
    tokens() As String, ByVal tokenCount As Long, _
    ByVal aliasName As String _
) As String
    If tokenCount < 3 OrElse aliasName = "" Then Return ""
    Dim lastToken As Long = tokenCount - 1
    If tokens(lastToken) = ";" Then lastToken -= 1
    Dim aliasPosition As Long = -1
    For tokenIndex As Long = 1 To lastToken
        If tokens(tokenIndex) = aliasName Then aliasPosition = tokenIndex
    Next
    If aliasPosition <= 1 Then Return ""
    Dim result As String
    For tokenIndex As Long = 1 To aliasPosition - 1
        If result <> "" Then result &= " "
        result &= tokens(tokenIndex)
    Next
    Return result
End Function

Private Sub EmitGenericTypedefSingleWithTokens( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal declaration As String, ByVal normalized As String, _
    tokens() As String, ByVal tokenCount As Long, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, typeNames() As String, _
    ByRef typeNameCount As Long, outputNames() As String, _
    ByRef outputNameCount As Long, ByRef conversionSummary As C2fbConversionSummaryModel, _
    ByVal passKind As C2fbGenericHeaderDeclarationPassKind _
)
    If tokenCount = 0 OrElse tokens(0) <> "typedef" Then Exit Sub
    Dim needsDeferredDeclaration As Long = _
        GenericTypedefNeedsRecordDependentDeclaration( _
            translation, catalog, tokens(), tokenCount, passKind)
    If passKind = C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS AndAlso _
       needsDeferredDeclaration <> 0 Then Exit Sub
    If passKind = C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS_AFTER_RECORDS AndAlso _
       needsDeferredDeclaration = 0 Then Exit Sub
    If tokenCount < 3 OrElse tokenCount >= MAX_TYPE_WORDS Then
        ReportGenericTypedefSkipped(translation, outputFile, declaration, conversionSummary, passKind)
        Exit Sub
    End If
    Dim finalTypedefToken As Long = tokenCount - 1
    If tokens(finalTypedefToken) = ";" Then finalTypedefToken -= 1
    If finalTypedefToken > 1 AndAlso _
       IsIdentifierToken(tokens(finalTypedefToken)) <> 0 Then
        Dim existingAliasIndex As Long = _
            GenericHeaderTypeAliasIndexInHeader( _
                translation.genericC.header, tokens(finalTypedefToken), 0)
        If existingAliasIndex >= 0 Then
            With translation.genericC.header.headerTypeAliases(existingAliasIndex)
                If .baseType = "Record" OrElse .isForward <> 0 OrElse _
                   (.emitted <> 0 AndAlso .isArray = 0) Then Exit Sub
            End With
        End If
    End If
    Dim arrayTypedefResult As C2fbGenericArrayTypedefResultModel
    ParseGenericArrayTypedef( _
        translation, catalog, normalized, tokens(), tokenCount, arrayTypedefResult)
    If arrayTypedefResult.status = C2FB_GENERIC_ARRAY_TYPEDEF_INVALID OrElse _
       arrayTypedefResult.status = C2FB_GENERIC_ARRAY_TYPEDEF_UNSUPPORTED Then
        ReportGenericTypedefSkipped( _
            translation, outputFile, declaration, conversionSummary, passKind)
        Exit Sub
    End If
    If arrayTypedefResult.status = C2FB_GENERIC_ARRAY_TYPEDEF_CONVERTED Then
        Dim arrayAliasName As String = arrayTypedefResult.aliasName
        If GenericTypeExcludedInPolicy( _
            translation.genericC.policy, arrayAliasName) <> 0 Then
            ReportGenericTypedefExcluded(translation, outputFile, arrayAliasName, _
                conversionSummary, passKind)
            Exit Sub
        End If
        Dim arrayElementType As String = ApplyGenericStringOverrideInGenericC( _
            translation.genericC, arrayAliasName, arrayTypedefResult.elementType)
        Dim arrayElementCount As Long = arrayTypedefResult.arrayCount
        Dim arrayBounds As String = arrayTypedefResult.arrayBounds
        Dim arrayAliasIndex As Long = _
            GenericHeaderTypeAliasIndexInHeader(translation.genericC.header, arrayAliasName)
        If arrayAliasIndex >= 0 Then
            If translation.genericC.header.headerTypeAliases(arrayAliasIndex).isArray <> 0 Then
                MarkGenericTypedefExpansionMatchedInPolicy( _
                    translation.genericC.policy, arrayAliasName)
                If passKind = C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS Then _
                    WriteC2fbOutputLine( _
                        outputFile, "' c2fb expands array typedef at each use: " & _
                        arrayAliasName)
                Exit Sub
            End If
            ReportGenericTypedefSkipped( _
                translation, outputFile, declaration, conversionSummary, passKind)
            Exit Sub
        End If

        Dim arrayAliasFbName As String = GenericFreeBasicTypeNameInPolicy( _
            translation, arrayAliasName, typeNames(), typeNameCount, _
            outputNames(), outputNameCount)
        If typeNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES OrElse _
           outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
            ReportError("generic header exceeds the configured array typedef limit")
        If typeNameCount > UBound(typeNames) Then _
            ReDim Preserve typeNames(0 To UBound(typeNames) * 2 + 1)
        typeNames(typeNameCount) = arrayAliasFbName
        typeNameCount += 1
        If outputNameCount > UBound(outputNames) Then _
            ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
        outputNames(outputNameCount) = arrayAliasFbName
        outputNameCount += 1
        RecordGenericHeaderTypeAliasInHeader( _
            translation.genericC.header, arrayAliasName, arrayAliasFbName, "", -1, 0, -1, _
            arrayElementCount, arrayElementType, 0, 0, arrayBounds, _
            arrayTypedefResult.characterKind)
        MarkGenericTypedefExpansionMatchedInPolicy( _
            translation.genericC.policy, arrayAliasName)
        If passKind = C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS Then _
            WriteC2fbOutputLine( _
                outputFile, "' c2fb expands array typedef at each use: " & _
                arrayAliasName)
        Exit Sub
    End If

    Dim callbackResult As C2fbCallbackTypeResultModel
    Dim aliasName As String
    Dim isFunctionAlias As Long = 0
    Dim canExpandAlias As Long = 0
    ResolveCBodyCallbackTypeInContext( _
        translation, catalog, tokens(), 1, tokenCount - 1, _
        callbackResult, 0, C2FB_TYPE_MAPPING_GENERIC_HEADER)
    Dim freeBasicType As String
    If callbackResult.status = C2FB_CALLBACK_TYPE_UNSUPPORTED Then
        freeBasicType = GenericFunctionTypeFromTypedef( _
            translation, catalog, tokens(), tokenCount, aliasName)
        If freeBasicType = "" Then
            ReportGenericTypedefSkipped( _
                translation, outputFile, declaration, conversionSummary, passKind)
            Exit Sub
        End If
        isFunctionAlias = -1
    ElseIf callbackResult.status = C2FB_CALLBACK_TYPE_CONVERTED Then
        aliasName = callbackResult.callbackName
        isFunctionAlias = -1
        If GenericTypeExcludedInPolicy( _
            translation.genericC.policy, aliasName) <> 0 Then
            ReportGenericTypedefExcluded(translation, outputFile, aliasName, _
                conversionSummary, passKind)
            Exit Sub
        End If
        freeBasicType = CBodyCallbackDeclarationInContext( _
            translation, callbackResult.freeBasicType)
        If freeBasicType = "" Then
            ReportGenericTypedefSkipped( _
                translation, outputFile, declaration, conversionSummary, passKind)
            Exit Sub
        End If
    Else
        freeBasicType = GenericFunctionTypeFromTypedef( _
            translation, catalog, tokens(), tokenCount, aliasName)
        If freeBasicType <> "" Then isFunctionAlias = -1
        If freeBasicType = "" Then
            If CDeclarationHasStdCall(declaration) <> 0 Then
                If passKind = C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS Then
                    EmitC2fbSkipped(translation, _
                        outputFile, conversionSummary, "unsupported stdcall typedef", declaration)
                End If
                Exit Sub
            End If
            aliasName = tokens(tokenCount - 1)
            Dim hasArrayDeclarator As Long = 0
            Dim nesting As Long = 0
            For tokenIndex As Long = 1 To tokenCount - 2
                If tokens(tokenIndex) = "(" Then nesting += 1
                If tokens(tokenIndex) = ")" AndAlso nesting > 0 Then nesting -= 1
                If nesting = 0 AndAlso (tokens(tokenIndex) = "," OrElse tokens(tokenIndex) = "[") Then _
                    hasArrayDeclarator = -1
            Next
            If IsIdentifierToken(aliasName) = 0 OrElse hasArrayDeclarator <> 0 Then
                ReportGenericTypedefSkipped( _
                    translation, outputFile, declaration, conversionSummary, passKind)
                Exit Sub
            End If
            Dim resolvedAliasType As C2fbResolvedTypeModel
            ResolveC2fbTypeModel(translation, catalog, _
                tokens(), 1, tokenCount - 2, resolvedAliasType, _
                C2FB_POINTER_MAPPING_OPAQUE, C2FB_TYPE_MAPPING_GENERIC_HEADER)
            If resolvedAliasType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then
                Dim finalTypeToken As Long = tokenCount - 1
                If tokens(finalTypeToken) = ";" Then finalTypeToken -= 1
                Dim hasSimpleTagAlias As Long = CInt( _
                    finalTypeToken = 3 AndAlso _
                    (tokens(1) = "struct" OrElse tokens(1) = "union") AndAlso _
                    IsIdentifierToken(tokens(2)) <> 0 AndAlso _
                    IsIdentifierToken(tokens(3)) <> 0)
                Dim tagFreeBasicType As String
                If hasSimpleTagAlias <> 0 Then _
                    tagFreeBasicType = GenericHeaderTagAliasNameInHeader( _
                        translation.genericC.header, tokens(2))
                If tagFreeBasicType = "" Then
                    ReportGenericTypedefSkipped( _
                        translation, outputFile, declaration, _
                        conversionSummary, passKind)
                    Exit Sub
                End If

                ' A typedef can retain the C tag's type even when a filtered
                ' layout prevents the ordinary type resolver from flattening it.
                aliasName = tokens(finalTypeToken)
                resolvedAliasType.freeBasicType = tagFreeBasicType
                resolvedAliasType.pointerCount = 0
            End If
            freeBasicType = resolvedAliasType.freeBasicType
            If resolvedAliasType.isConst <> 0 AndAlso _
               Left(freeBasicType, 6) <> "Const " Then _
                freeBasicType = "Const " & freeBasicType
            If freeBasicType = "void" AndAlso _
               resolvedAliasType.pointerCount = 0 Then
                ' C APIs commonly typedef void as a byte-addressable opaque
                ' pointee (for example OpenGL's GLvoid). FreeBASIC's Any is
                ' the corresponding storage-free pointer base type.
                freeBasicType = "Any"
            End If
            If freeBasicType = "" OrElse freeBasicType = "void" Then
                ReportGenericTypedefSkipped( _
                    translation, outputFile, declaration, conversionSummary, passKind)
                Exit Sub
            End If
            Dim sourcePointerDepth As Long = 0
            Dim sourceItemAlias As Long = 0
            For tokenIndex As Long = 1 To tokenCount - 2
                If tokens(tokenIndex) = "*" Then sourcePointerDepth += 1
                Dim sourceAliasIndex As Long = _
                    GenericHeaderTypeAliasIndexInHeader( _
                        translation.genericC.header, tokens(tokenIndex), 0)
                If sourceAliasIndex >= 0 AndAlso _
                   translation.genericC.header.headerTypeAliases(sourceAliasIndex).isFunction <> 0 Then _
                    sourceItemAlias = -1
            Next
            If sourceItemAlias <> 0 AndAlso sourcePointerDepth = 0 Then _
                isFunctionAlias = -1
            If isFunctionAlias = 0 Then canExpandAlias = -1
            If resolvedAliasType.pointerCount = 0 AndAlso _
               (tokens(1) = "struct" OrElse tokens(1) = "union") AndAlso _
               LCase(freeBasicType) = LCase(aliasName) Then
                ' An opaque tag alias needs no declaration when all uses are pointers.
                Exit Sub
            End If
        End If
    End If

    If GenericTypeExcludedInPolicy(translation.genericC.policy, aliasName) <> 0 Then
        ReportGenericTypedefExcluded(translation, outputFile, aliasName, _
            conversionSummary, passKind)
        Exit Sub
    End If
    Dim typedefSourceType As String = GenericTypedefSourceTypeText( _
        tokens(), tokenCount, aliasName)
    Dim characterKind As Long = GenericHeaderCCharacterKindInType( _
        translation, typedefSourceType)
    Dim ignoredTypedefAlignment As Long
    Dim typedefAlignment As Long = GenericTypedefAlignmentValue( _
        translation, declaration, typedefSourceType, aliasName, _
        ignoredTypedefAlignment)
    Dim typedefStringMode As Long = GenericStringOverrideModeInPolicy( _
        translation.genericC.policy, aliasName)
    If typedefStringMode = 0 Then _
        typedefStringMode = GenericHeaderFbfrogStringDefaultMode( _
            translation, typedefSourceType, freeBasicType)
    If typedefStringMode > 0 AndAlso _
       characterKind <> C2FB_C_CHARACTER_NONE Then
        freeBasicType = GenericHeaderFbfrogStringTypedefTypeInHeader( _
            translation.genericC.header, freeBasicType)
    Else
        freeBasicType = ApplyGenericStringOverrideModeInHeader( _
            translation.genericC.header, typedefStringMode, freeBasicType)
    End If
    If freeBasicType = "" OrElse aliasName = "" OrElse IsIdentifierToken(aliasName) = 0 Then
        ReportGenericTypedefSkipped(translation, outputFile, declaration, conversionSummary, passKind)
        Exit Sub
    End If
    Dim functionPointerDepth As Long = 0
    If isFunctionAlias <> 0 Then functionPointerDepth = callbackResult.pointerDepth
    Dim aliasIndex As Long = GenericHeaderTypeAliasIndexInHeader(translation.genericC.header, aliasName)
    Dim freeBasicName As String
    If canExpandAlias <> 0 AndAlso isFunctionAlias = 0 AndAlso _
       typedefAlignment = 0 AndAlso _
       GenericTypedefExpansionRequestedInPolicy( _
           translation.genericC.policy, aliasName) <> 0 Then
        If aliasIndex >= 0 Then
            If translation.genericC.header.headerTypeAliases(aliasIndex).baseType = "Record" OrElse _
               translation.genericC.header.headerTypeAliases(aliasIndex).emitted <> 0 Then Exit Sub
            translation.genericC.header.headerTypeAliases(aliasIndex).freeBasicName = freeBasicType
            translation.genericC.header.headerTypeAliases(aliasIndex).baseType = ""
            translation.genericC.header.headerTypeAliases(aliasIndex).characterKind = characterKind
            translation.genericC.header.headerTypeAliases(aliasIndex).isFunction = 0
            translation.genericC.header.headerTypeAliases(aliasIndex).alignmentValue = 0
            translation.genericC.header.headerTypeAliases(aliasIndex).emitted = -1
            If translation.genericC.header.headerTypeAliases(aliasIndex).isForward <> 0 Then _
                translation.genericC.header.headerTypeAliases(aliasIndex).isForward = 0
        Else
            RecordGenericHeaderTypeAliasInHeader( _
                translation.genericC.header, aliasName, freeBasicType, "", -1, _
                0, 0, 0, "", 0, 0, "", characterKind)
        End If
        MarkGenericTypedefExpansionMatchedInPolicy( _
            translation.genericC.policy, aliasName)
        Exit Sub
    End If
    If aliasIndex >= 0 Then
        If translation.genericC.header.headerTypeAliases(aliasIndex).baseType = "Record" OrElse _
           translation.genericC.header.headerTypeAliases(aliasIndex).emitted <> 0 Then Exit Sub
        freeBasicName = translation.genericC.header.headerTypeAliases(aliasIndex).freeBasicName
        translation.genericC.header.headerTypeAliases(aliasIndex).baseType = freeBasicType
        translation.genericC.header.headerTypeAliases(aliasIndex).alignmentValue = _
            typedefAlignment
        If isFunctionAlias <> 0 Then
            translation.genericC.header.headerTypeAliases(aliasIndex).isFunction = -1
            translation.genericC.header.headerTypeAliases(aliasIndex).functionPointerDepth = _
                functionPointerDepth
        End If
        If characterKind <> C2FB_C_CHARACTER_NONE Then _
            translation.genericC.header.headerTypeAliases(aliasIndex).characterKind = characterKind
    Else
        freeBasicName = GenericFreeBasicTypeNameInPolicy( _
            translation, aliasName, typeNames(), typeNameCount, _
            outputNames(), outputNameCount)
        If typeNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
            ReportError("generic header exceeds the configured typedef limit")
        If typeNameCount > UBound(typeNames) Then _
            ReDim Preserve typeNames(0 To UBound(typeNames) * 2 + 1)
        typeNames(typeNameCount) = freeBasicName
        typeNameCount += 1
        If outputNameCount > UBound(outputNames) Then _
            ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
        outputNames(outputNameCount) = freeBasicName
        outputNameCount += 1
        RecordGenericHeaderTypeAliasInHeader( _
            translation.genericC.header, aliasName, freeBasicName, freeBasicType, 0, 0, 0, 0, "", _
            isFunctionAlias, 0, "", characterKind, functionPointerDepth, _
            typedefAlignment)
        aliasIndex = GenericHeaderTypeAliasIndexInHeader(translation.genericC.header, aliasName)
    End If
    If passKind = C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS OrElse _
       passKind = C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS_AFTER_RECORDS Then
        Dim typeAlias As C2fbTypeAliasBindingModel
        typeAlias.freeBasicName = freeBasicName
        typeAlias.targetType = freeBasicType
        typeAlias.alignmentValue = typedefAlignment
        WriteGenericTypeAliasWithGuardsInPolicy( _
            translation.genericC.policy, outputFile, aliasName, typeAlias)
        If ignoredTypedefAlignment <> 0 Then _
            WriteC2fbOutputLine( _
                outputFile, "' c2fb typedef-alignment-not-represented: " & _
                    aliasName)
        If aliasIndex >= 0 Then _
            MarkGenericHeaderTypeAliasEmittedInHeader(translation.genericC.header, aliasName, 0)
    End If
End Sub
/' end of c2fb_generic_typedefs.bi '/
