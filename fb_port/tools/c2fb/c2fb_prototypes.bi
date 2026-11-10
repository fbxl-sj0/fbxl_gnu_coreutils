/'
    Project: C2FB prototype lowering
    --------------------------------

    File: c2fb_prototypes.bi

    Purpose:

        Lower collected C function declarations into shared FreeBASIC
        procedure bindings.

    Responsibilities:

        - Select eligible C functions and resolve their calling conventions.
        - Lower nested callback returns and function parameters through shared models.
        - Emit procedure bindings and register generic-header function symbols.

    This file intentionally does NOT contain:

        - C source scanning, declaration tokenization, or C type-shape parsing.
        - FreeBASIC output formatting or command-mode selection.
'/

Private Function IsFunctionName( _
    ByVal functionName As String, ByVal typeMappingKind As C2fbTypeMappingKind = C2FB_TYPE_MAPPING_BODY _
) As Long
    If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then Return CInt(IsIdentifierToken(functionName) <> 0)
    If Len(functionName) < 7 Then Return 0
    If Left(functionName, 7) = "sqlite3" Then Return -1
    Return 0
End Function

Private Function CDeclarationStdCallCount(ByVal declaration As String) As Long
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(declaration, tokens(), tokenCount)
    Dim result As Long = 0
    For i As Long = 0 To tokenCount - 1
        Select Case LCase(tokens(i))
        Case "stdcall", "__stdcall", "__stdcall__", "winapi", "apientry", "ntapi"
            result += 1
        End Select
    Next
    Return result
End Function

Private Function CDeclarationHasStdCall(ByVal declaration As String) As Long
    Return CInt(CDeclarationStdCallCount(declaration) > 0)
End Function

Private Function CFunctionCallingConvention( _
    ByVal declaration As String, ByVal functionName As String, _
    ByVal typeMappingKind As C2fbTypeMappingKind _
) As String
    If typeMappingKind = C2FB_TYPE_MAPPING_BODY Then Return "CDecl"
    Dim namePosition As Long = InStr(declaration, functionName)
    If namePosition = 0 Then Return "CDecl"
    Dim prefix As String = Left(declaration, namePosition - 1)
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(prefix, tokens(), tokenCount)
    For i As Long = 0 To tokenCount - 1
        Select Case LCase(tokens(i))
        Case "stdcall", "__stdcall", "__stdcall__", "winapi", "apientry", "ntapi"
            Return "StdCall"
        End Select
    Next

    Dim opening As Long = InStr(namePosition + Len(functionName), declaration, "(")
    If opening > 0 Then
        Dim closingPosition As Long = opening
        If ScanSimpleExpressionGroup( _
            declaration, closingPosition, Asc("("), Asc(")")) <> 0 Then
            Dim trailingText As String = Mid(declaration, closingPosition)
            If CDeclarationHasStdCall(trailingText) <> 0 Then Return "StdCall"
        End If
    End If
    Return "CDecl"
End Function

Private Function CFunctionHasStdCallOutsideParameters( _
    ByVal declaration As String, ByVal functionName As String _
) As Long
    Dim namePosition As Long = InStr(declaration, functionName)
    If namePosition = 0 Then Return 0
    Dim opening As Long = InStr(namePosition + Len(functionName), declaration, "(")
    If opening = 0 Then Return CDeclarationHasStdCall(Left(declaration, namePosition - 1))
    Dim closingPosition As Long = opening
    If ScanSimpleExpressionGroup( _
        declaration, closingPosition, Asc("("), Asc(")")) = 0 Then Return -1
    Dim outsideText As String = Left(declaration, opening - 1)
    outsideText &= " " & Mid(declaration, closingPosition)
    Return CDeclarationHasStdCall(outsideText)
End Function

Private Function CFunctionParametersHaveUnsupportedStdCall( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal declaration As String, ByVal functionName As String _
) As Long
    Dim normalized As String = StripCFunctionAttributes(declaration)
    If normalized = "" Then Return -1
    Dim namePosition As Long = InStr(normalized, functionName)
    If namePosition = 0 Then Return 0
    Dim opening As Long = InStr(namePosition + Len(functionName), normalized, "(")
    If opening = 0 Then Return 0
    Dim closingPosition As Long = opening
    If ScanSimpleExpressionGroup(normalized, closingPosition, Asc("("), Asc(")")) = 0 Then Return -1
    Dim parameterText As String = Mid( _
        normalized, opening + 1, closingPosition - opening - 2)
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(parameterText, tokens(), tokenCount)
    If tokenCount = 0 Then Return 0

    Dim parameterStart As Long = 0
    Dim nesting As Long = 0
    For tokenIndex As Long = 0 To tokenCount
        Dim atEnd As Long = CInt(tokenIndex = tokenCount)
        If atEnd = 0 Then
            If tokens(tokenIndex) = "(" OrElse tokens(tokenIndex) = "[" Then nesting += 1
            If tokens(tokenIndex) = ")" OrElse tokens(tokenIndex) = "]" Then nesting -= 1
        End If
        If atEnd = 0 AndAlso (tokens(tokenIndex) <> "," OrElse nesting <> 0) Then Continue For

        Dim parameterEnd As Long = tokenIndex - 1
        Dim expectedStdCallCount As Long = CBodyStdCallTokenCount( _
            tokens(), parameterStart, parameterEnd)
        If expectedStdCallCount > 0 Then
            Dim callbackResult As C2fbCallbackTypeResultModel
            ResolveCBodyCallbackTypeInContext( _
                translation, catalog, tokens(), _
                parameterStart, parameterEnd, callbackResult, 0, _
                C2FB_TYPE_MAPPING_GENERIC_HEADER)
            If callbackResult.status <> C2FB_CALLBACK_TYPE_CONVERTED Then Return -1
            Dim callbackDeclaration As String = _
                CBodyCallbackDeclarationInContext( _
                    translation, callbackResult.freeBasicType)
            If CDeclarationStdCallCount(callbackDeclaration) <> expectedStdCallCount Then Return -1
        End If
        parameterStart = tokenIndex + 1
    Next
    Return 0
End Function

Private Function GenericFreeBasicFunctionNameInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceName As String, outputNames() As String, ByVal outputNameCount As Long, _
    ByVal renameNamespace As C2fbSymbolRenameNamespace = _
        C2FB_SYMBOL_RENAME_GENERAL _
) As String
    Dim result As String
    Select Case renameNamespace
    Case C2FB_SYMBOL_RENAME_PROCEDURE
        result = GenericProcedureRenameInPolicy( _
            translation.genericC.policy, sourceName)
    Case C2FB_SYMBOL_RENAME_DEFINE
        result = GenericMacroRenameInPolicy( _
            translation.genericC.policy, sourceName)
    Case Else
        result = GenericSymbolRenameInPolicy( _
            translation.genericC.policy, sourceName)
    End Select
    If result = "" Then result = translation.genericC.policy.generatedNamePrefix & sourceName
    ' Keep explicit C renames usable as FreeBASIC identifiers.
    If C2fbFreeBasicIdentifierIsKeyword(result) <> 0 Then result &= "_"
    If translation.genericC.header.rootSourcePath <> "" AndAlso _
       outputNameCount >= 16 Then
        With translation.genericC.header
            If .outputNameIndex.capacity <= 0 OrElse _
               .outputNameIndexedCount > outputNameCount Then
                ResetC2fbStringIndexMap(.outputNameIndex)
                .outputNameIndexedCount = 0
            End If
            While .outputNameIndexedCount < outputNameCount
                Dim indexedName As String = LCase( _
                    outputNames(.outputNameIndexedCount))
                If indexedName <> "" AndAlso AddC2fbStringIndexMapEntry( _
                    .outputNameIndex, indexedName, .outputNameIndexedCount) = 0 Then _
                    ReportError("generic header output-name index exceeds its configured limit")
                .outputNameIndexedCount += 1
            Wend
            Do
                If C2fbStringIndexMapLookup( _
                    .outputNameIndex, LCase(result)) < 0 Then Exit Do
                result &= "_"
            Loop
            If AddC2fbStringIndexMapEntry( _
                .outputNameIndex, LCase(result), outputNameCount) = 0 Then _
                ReportError("generic header output-name index exceeds its configured limit")
            Return result
        End With
    End If
    Dim conflict As Long
    Do
        conflict = 0
        For i As Long = 0 To outputNameCount - 1
            If LCase(outputNames(i)) = LCase(result) Then
                result &= "_"
                conflict = -1
                Exit For
            End If
        Next
    Loop While conflict <> 0
    Return result
End Function

Private Sub ResetGenericHeaderSymbolsInContext( _
    ByRef translation As C2fbTranslationContext _
)
    ResetC2fbSymbolTableInContext(translation, 64)
End Sub

Private Function C2fbSymbolIndexInContext( _
    ByRef translation As C2fbTranslationContext, ByVal sourceName As String _
) As Long
    Return C2fbStringIndexMapLookup( _
        translation.symbolTable.nameIndex, sourceName)
End Function

Private Function GenericHeaderSymbolIndexInContext( _
    ByRef translation As C2fbTranslationContext, ByVal sourceName As String _
) As Long
    Dim symbolIndex As Long = C2fbSymbolIndexInContext(translation, sourceName)
    If symbolIndex < 0 OrElse _
       translation.symbolTable.symbols(symbolIndex).genericHeader.isRegistered = 0 OrElse _
       translation.symbolTable.symbols(symbolIndex).ambiguous <> 0 Then Return -1
    Return symbolIndex
End Function

Private Sub RecordGenericHeaderSymbolInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceName As String, ByVal freeBasicName As String, ByVal cName As String, _
    ByVal kind As C2fbSymbolKind, ByVal freeBasicType As String = "", _
    ByVal returnType As String = "", ByVal parameterList As String = "", _
    ByVal callingConvention As String = "CDecl", ByVal arrayCount As Long = 0, _
    ByVal unsizedArray As Long = 0 _
)
    Dim symbolIndex As Long = EnsureC2fbSymbolInContext( _
        translation, sourceName, cName, freeBasicName, kind)
    If symbolIndex < 0 Then _
        ReportError("generic header exceeds the configured symbol limit")
    With translation.symbolTable.symbols(symbolIndex)
        .genericHeader.freeBasicType = freeBasicType
        .genericHeader.returnType = returnType
        .genericHeader.parameterList = parameterList
        .genericHeader.callingConvention = callingConvention
        .genericHeader.arrayCount = arrayCount
        .genericHeader.unsizedArray = unsizedArray
        .genericHeader.isRegistered = -1
    End With
End Sub

Private Function FreeBasicProcedureHead( _
    ByRef procedureBinding As C2fbProcedureBindingModel, _
    ByVal isDeclaration As Long _
) As String
    Return C2fbProcedureHeadText(procedureBinding, isDeclaration)
End Function

Private Function FreeBasicProcedureDefinition( _
    ByRef procedureBinding As C2fbProcedureBindingModel, ByVal bodyText As String _
) As String
    Dim ending As String = "End Function"
    If procedureBinding.isSub <> 0 Then ending = "End Sub"
    Dim definitionBody As String = bodyText
    If procedureBinding.cName = "main" AndAlso _
       procedureBinding.returnType = "c2fb_c_int" AndAlso _
       procedureBinding.isSub = 0 Then
        Dim lastLineStart As Long = InStrRev(definitionBody, Chr(10)) + 1
        Dim finalLine As String = Trim(Mid(definitionBody, lastLineStart))
        Dim hasTrailingReturn As Long = CInt(Left(finalLine, 6) = "Return")
        If hasTrailingReturn <> 0 AndAlso Len(finalLine) > 6 AndAlso _
           Mid(finalLine, 7, 1) <> " " Then hasTrailingReturn = 0
        If hasTrailingReturn = 0 Then
            ' C main returns zero when it reaches its closing brace.
            If definitionBody <> "" Then definitionBody &= Chr(10)
            definitionBody &= "    Return 0"
        End If
    End If
    Return FreeBasicProcedureHead(procedureBinding, 0) & Chr(10) & _
        definitionBody & Chr(10) & ending
End Function

Private Sub EmitProcedureBinding( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByRef procedureBinding As C2fbProcedureBindingModel _
)
    WriteC2fbProcedureBinding(outputFile, procedureBinding)
End Sub

Private Sub RecordGenericHeaderProcedureInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceName As String, ByRef procedureBinding As C2fbProcedureBindingModel _
)
    Dim symbolKind As C2fbSymbolKind = GENERIC_SYMBOL_FUNCTION
    If procedureBinding.isSub <> 0 Then symbolKind = GENERIC_SYMBOL_SUB
    RecordGenericHeaderSymbolInContext(translation, _
        sourceName, procedureBinding.freeBasicName, procedureBinding.cName, _
        symbolKind, "", procedureBinding.returnType, procedureBinding.parameterList, _
        procedureBinding.callingConvention)
End Sub

Private Sub RecordGenericHeaderObjectInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceName As String, ByRef objectBinding As C2fbObjectBindingModel _
)
    RecordGenericHeaderSymbolInContext(translation, _
        sourceName, objectBinding.freeBasicName, objectBinding.cName, _
        GENERIC_SYMBOL_OBJECT, objectBinding.freeBasicType, "", "", "", _
        objectBinding.arrayCount, objectBinding.isUnsizedArray)
End Sub

Private Function IsAlreadyEmitted( _
    names() As String, _
    ByVal nameCount As Long, _
    ByVal functionName As String _
) As Long
    For i As Long = 0 To nameCount - 1
        If names(i) = functionName Then Return -1
    Next
    Return 0
End Function

Private Function GenericHeaderSourceNameWasEmitted( _
    ByRef translation As C2fbTranslationContext, names() As String, _
    ByVal nameCount As Long, ByVal sourceName As String _
) As Long
    If translation.genericC.header.rootSourcePath = "" OrElse _
       nameCount < 16 Then
        For nameIndex As Long = 0 To nameCount - 1
            If names(nameIndex) = sourceName Then Return -1
        Next
        Return 0
    End If

    With translation.genericC.header
        If .sourceNameIndex.capacity <= 0 OrElse _
           .sourceNameIndexedCount > nameCount Then
            ResetC2fbStringIndexMap(.sourceNameIndex)
            .sourceNameIndexedCount = 0
        End If
        While .sourceNameIndexedCount < nameCount
            Dim indexedName As String = names(.sourceNameIndexedCount)
            If indexedName <> "" AndAlso AddC2fbStringIndexMapEntry( _
                .sourceNameIndex, indexedName, .sourceNameIndexedCount) = 0 Then _
                ReportError("generic header source-name index exceeds its configured limit")
            .sourceNameIndexedCount += 1
        Wend
        Return CInt(C2fbStringIndexMapLookup( _
            .sourceNameIndex, sourceName) >= 0) * -1
    End With
End Function

Private Function CFunctionReturnOuterCallConv( _
    tokens() As String, ByVal declaratorStart As Long _
) As String
    Dim sawStdCall As Long = 0
    Dim sawCDecl As Long = 0
    For tokenIndex As Long = 0 To declaratorStart - 1
        Select Case LCase(tokens(tokenIndex))
        Case "stdcall", "__stdcall", "__stdcall__", "winapi", "apientry", "ntapi"
            sawStdCall = -1
        Case "cdecl", "__cdecl", "__cdecl__"
            sawCDecl = -1
        End Select
    Next
    If sawStdCall <> 0 AndAlso sawCDecl <> 0 Then Return "Invalid"
    If sawStdCall <> 0 Then Return "StdCall"
    Return "CDecl"
End Function

Private Function IsFunctionReturnCallbackDeclarator( _
    ByRef declarator As C2fbDeclaratorModel _
) As Long
    ' The declared function is the first F; each returned callback adds P-F.
    If declarator.operatorCount < 3 OrElse _
       declarator.operatorKind(0) <> C2FB_DECLARATOR_FUNCTION OrElse _
       (declarator.operatorCount - 1) Mod 2 <> 0 OrElse _
       Len(declarator.functionOpenPositions) <> _
           (declarator.operatorCount + 1) \ 2 Then Return 0

    For operatorIndex As Long = 1 To declarator.operatorCount - 1 Step 2
        If declarator.operatorKind(operatorIndex) <> C2FB_DECLARATOR_POINTER OrElse _
           operatorIndex + 1 >= declarator.operatorCount OrElse _
           declarator.operatorKind(operatorIndex + 1) <> _
               C2FB_DECLARATOR_FUNCTION Then Return 0
    Next
    Return -1
End Function

Private Function CFunctionReturnCallbackType( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    tokens() As String, ByVal tokenCount As Long, _
    ByVal declaratorStart As Long, _
    ByRef declarator As C2fbDeclaratorModel, _
    ByVal typeMappingKind As C2fbTypeMappingKind _
) As String
    Dim lastToken As Long = tokenCount - 1
    If tokens(lastToken) = ";" Then lastToken -= 1

    If IsFunctionReturnCallbackDeclarator(declarator) = 0 Then Return ""
    ' The first function operator belongs to the declared function. Remaining
    ' P-F pairs describe returned callback layers from outermost to innermost.
    Dim callbackFunctionPositions As String = _
        Mid(declarator.functionOpenPositions, 2)
    If callbackFunctionPositions = "" OrElse _
       Len(callbackFunctionPositions) > 8 Then Return ""

    Dim returnTypeTokens() As String
    ReDim returnTypeTokens(0 To 31)
    Dim returnTypeTokenCount As Long = 0
    For tokenIndex As Long = 0 To declaratorStart - 1
        Select Case LCase(tokens(tokenIndex))
        Case "extern", "static", "inline", "__inline", "__inline__", _
             "register", "__extension__", "__thread", _
             "cdecl", "__cdecl", "__cdecl__", "stdcall", "__stdcall", _
             "__stdcall__", "winapi", "apientry", "ntapi"
            Continue For
        End Select
        AddToken(returnTypeTokens(), returnTypeTokenCount, tokens(tokenIndex))
    Next
    If returnTypeTokenCount = 0 Then Return ""

    Dim returnTypeResult As C2fbResolvedTypeModel
    If typeMappingKind = C2FB_TYPE_MAPPING_BODY Then
        ResolveC2fbTypeModel( _
            translation, catalog, returnTypeTokens(), 0, returnTypeTokenCount - 1, _
            returnTypeResult, C2FB_POINTER_MAPPING_PRESERVE, typeMappingKind, _
            C2FB_TYPE_RECOGNITION_KNOWN_TYPES_ONLY)
    Else
        ResolveC2fbTypeModel( _
            translation, catalog, returnTypeTokens(), 0, returnTypeTokenCount - 1, _
            returnTypeResult, C2FB_POINTER_MAPPING_PRESERVE, typeMappingKind)
    End If
    If returnTypeResult.status <> C2FB_TYPE_RESOLUTION_RESOLVED OrElse _
       returnTypeResult.pointerCount <> 0 OrElse _
       returnTypeResult.freeBasicType = "" Then Return ""

    Dim outerCallbackType As String
    Dim fullDeclaration As String
    If BuildCBodyCallbackReturnChainInContext( _
        translation, catalog, tokens(), 0, lastToken, _
        callbackFunctionPositions, returnTypeResult.freeBasicType, _
        0, typeMappingKind, outerCallbackType, fullDeclaration) = 0 Then Return ""
    Return fullDeclaration
End Function

Private Function FindGenericCppDefaultArgumentSeparator( _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long, _
    ByRef separatorToken As Long _
) As Long
    separatorToken = -1
    Dim parenDepth As Long = 0
    Dim bracketDepth As Long = 0
    Dim braceDepth As Long = 0
    For tokenIndex As Long = firstToken To lastToken
        Select Case tokens(tokenIndex)
        Case "(": parenDepth += 1
        Case ")": If parenDepth > 0 Then parenDepth -= 1
        Case "[": bracketDepth += 1
        Case "]": If bracketDepth > 0 Then bracketDepth -= 1
        Case "{": braceDepth += 1
        Case "}": If braceDepth > 0 Then braceDepth -= 1
        Case "="
            If parenDepth = 0 AndAlso bracketDepth = 0 AndAlso _
               braceDepth = 0 Then
                separatorToken = tokenIndex
                Return -1
            End If
        End Select
    Next
    Return -1
End Function

Private Function GenericCppDefaultArgumentSourceText( _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long _
) As String
    Dim sourceText As String
    Dim tokenIndex As Long = firstToken
    Dim quoteByte As Long = 0
    Dim escaped As Long = 0
    While tokenIndex <= lastToken
        Dim tokenText As String = tokens(tokenIndex)
        If quoteByte <> 0 Then
            sourceText &= tokenText
            If escaped <> 0 Then
                escaped = 0
            ElseIf tokenText = Chr(92) Then
                escaped = -1
            ElseIf Len(tokenText) = 1 AndAlso _
                   Asc(tokenText, 1) = quoteByte Then
                quoteByte = 0
            End If
            tokenIndex += 1
            Continue While
        End If

        If (tokenText = "L" OrElse tokenText = "u" OrElse _
            tokenText = "U" OrElse tokenText = "u8") AndAlso _
           tokenIndex < lastToken AndAlso _
           (tokens(tokenIndex + 1) = Chr(34) OrElse _
            tokens(tokenIndex + 1) = "'") Then
            If sourceText <> "" Then sourceText &= " "
            sourceText &= tokenText & tokens(tokenIndex + 1)
            quoteByte = Asc(tokens(tokenIndex + 1), 1)
            tokenIndex += 2
            Continue While
        End If
        If tokenText = Chr(34) OrElse tokenText = "'" Then
            If sourceText <> "" Then sourceText &= " "
            sourceText &= tokenText
            quoteByte = Asc(tokenText, 1)
            tokenIndex += 1
            Continue While
        End If
        If sourceText <> "" Then sourceText &= " "
        sourceText &= tokenText
        tokenIndex += 1
    Wend
    Return sourceText
End Function

Private Function TranslateGenericCppDefaultArgument( _
    ByRef translation As C2fbTranslationContext, _
    ByRef parameterResult As C2fbParameterConversionResultModel, _
    tokens() As String, ByVal firstToken As Long, ByVal lastToken As Long, _
    ByVal functionName As String _
) As Long
    If firstToken > lastToken Then Return 0
    Dim sourceValue As String = GenericCppDefaultArgumentSourceText( _
        tokens(), firstToken, lastToken)
    If sourceValue = "" Then Return 0

    Dim freeBasicValue As String
    If TranslateGenericHeaderStringMacro(sourceValue, freeBasicValue) <> 0 Then
        Dim stringMode As Long = GenericStringOverrideModeForFieldInPolicy( _
            translation.genericC.policy, functionName, "", _
            parameterResult.sourceName)
        If stringMode >= 0 AndAlso Right( _
            parameterResult.freeBasicType, 4) = " Ptr" Then
            Dim elementType As String = Trim(Left( _
                parameterResult.freeBasicType, _
                Len(parameterResult.freeBasicType) - 4))
            Dim stringPointerType As String = GenericStringPointerTypeInHeader( _
                translation.genericC.header, elementType)
            If stringPointerType <> "" Then _
                parameterResult.freeBasicType = stringPointerType
        End If
        If Left(freeBasicValue, 5) = "WStr(" AndAlso _
           Right(parameterResult.freeBasicType, 4) = " Ptr" Then _
            freeBasicValue = "@" & freeBasicValue
    ElseIf InStr(LCase(parameterResult.freeBasicType), " ptr") > 0 AndAlso _
           (sourceValue = "nullptr" OrElse sourceValue = "__null" OrElse _
            sourceValue = "NULL") Then
        freeBasicValue = "0"
    ElseIf TranslateGenericHeaderMacroExpression( _
        translation, sourceValue, freeBasicValue, 0) = 0 Then
        Return 0
    End If

    If freeBasicValue = "" Then Return 0
    parameterResult.defaultValue = freeBasicValue
    parameterResult.freeBasicDeclaration = _
        parameterResult.argumentName & " As " & parameterResult.freeBasicType & _
        " = " & freeBasicValue
    Return -1
End Function

Private Sub EmitPrototypeModel( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef sourceDeclaration As C2fbDeclarationModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    names() As String, _
    ByRef nameCount As Long, _
    outputNames() As String, _
    ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel, _
    ByVal typeMappingKind As C2fbTypeMappingKind = C2FB_TYPE_MAPPING_BODY _
)
    Dim declaration As String = sourceDeclaration.text
    Dim analysisDeclaration As String = declaration
    If sourceDeclaration.linkName <> "" Then
        Dim loweredDeclaration As String
        Dim ignoredLinkName As String
        If ParseCAssemblyNameLabel( _
            declaration, loweredDeclaration, ignoredLinkName) <> 0 Then _
            analysisDeclaration = loweredDeclaration
    End If
    Dim tokens() As String
    Dim tokenCount As Long = sourceDeclaration.tokenCount
    If tokenCount < 3 OrElse tokenCount >= MAX_TYPE_WORDS Then Exit Sub
    ReDim tokens(0 To tokenCount - 1)
    For tokenIndex As Long = 0 To tokenCount - 1
        tokens(tokenIndex) = sourceDeclaration.tokens(tokenIndex)
    Next
    ' The parsed declaration is already a function. A leading struct, union,
    ' or enum can be a valid result type, especially for pointer returns.
    If tokens(0) = "typedef" Then Exit Sub

    Dim functionDeclaration As C2fbFunctionDeclarationModel = _
        sourceDeclaration.functionDeclaration
    Dim functionName As String = functionDeclaration.declarator.name
    Dim nameTokenIndex As Long = functionDeclaration.declarator.nameTokenIndex
    Dim openParen As Long = functionDeclaration.declarator.firstFunctionOpenToken
    Dim declaratorStart As Long = functionDeclaration.declaratorStartToken
    If IsFunctionName(functionName, typeMappingKind) = 0 Then Exit Sub
    If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER AndAlso _
       GenericProcedureExcludedInPolicy(translation.genericC.policy, functionName) <> 0 Then Exit Sub
    If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then
        If GenericHeaderSourceNameWasEmitted( _
            translation, names(), nameCount, functionName) <> 0 Then Exit Sub
    ElseIf IsAlreadyEmitted(names(), nameCount, functionName) Then
        Exit Sub
    End If
    If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then
        For tokenIndex As Long = 0 To declaratorStart - 1
            If tokens(tokenIndex) = "static" Then
                EmitC2fbSkipped(translation, _
                    outputFile, conversionSummary, "internal-linkage function declaration", declaration)
                Exit Sub
            End If
        Next
    End If

    Dim returnsCallback As Long = 0
    If IsFunctionReturnCallbackDeclarator( _
        functionDeclaration.declarator) <> 0 Then _
        returnsCallback = -1
    Dim callingConvention As String
    If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER AndAlso _
       returnsCallback <> 0 Then
        callingConvention = CFunctionReturnOuterCallConv(tokens(), declaratorStart)
    Else
        callingConvention = CFunctionCallingConvention( _
            analysisDeclaration, functionName, typeMappingKind)
    End If
    If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then
        If callingConvention = "Invalid" OrElse _
           CFunctionParametersHaveUnsupportedStdCall( _
               translation, catalog, analysisDeclaration, functionName) <> 0 OrElse _
           (returnsCallback = 0 AndAlso _
            CFunctionHasStdCallOutsideParameters(analysisDeclaration, functionName) <> 0 AndAlso _
            callingConvention <> "StdCall") Then
            EmitC2fbSkipped(translation, _
                outputFile, conversionSummary, "unsupported stdcall placement", declaration)
            Exit Sub
        End If
    End If

    Dim returnPointerCount As Long = 0
    Dim returnOperatorStart As Long = 1
    If returnsCallback = 0 Then
        For operatorIndex As Long = returnOperatorStart To _
            functionDeclaration.declarator.operatorCount - 1
            If functionDeclaration.declarator.operatorKind(operatorIndex) <> _
               C2FB_DECLARATOR_POINTER Then
                EmitC2fbSkipped(translation, _
                    outputFile, conversionSummary, "unsupported return declarator", declaration)
                Exit Sub
            End If
            returnPointerCount += 1
        Next
    End If

    Dim closePosition As Long = openParen
    If SkipCDeclaratorGroup(tokens(), closePosition, tokenCount - 1, "(", ")") = 0 Then
        EmitC2fbSkipped(translation, outputFile, conversionSummary, "malformed declaration", declaration)
        Exit Sub
    End If
    Dim closeParen As Long = closePosition - 1

    ' Rebuild the result type from the declaration specifiers and binding
    ' order. Parenthesized declarator syntax is not a C type specifier.
    Dim returnType As String
    If returnsCallback <> 0 Then
        returnType = CFunctionReturnCallbackType( _
            translation, catalog, tokens(), tokenCount, declaratorStart, _
            functionDeclaration.declarator, typeMappingKind)
        If returnType = "" Then
            EmitC2fbSkipped(translation, _
                outputFile, conversionSummary, "unsupported return callback", declaration)
            Exit Sub
        End If
    Else
        If declaratorStart + returnPointerCount > MAX_TYPE_WORDS Then
                EmitC2fbSkipped(translation, _
                outputFile, conversionSummary, "oversized return declarator", declaration)
            Exit Sub
        End If
        Dim returnTypeTokens() As String
        ReDim returnTypeTokens(0 To 31)
        Dim returnTokenCount As Long = 0
        For i As Long = 0 To declaratorStart - 1
            AddToken(returnTypeTokens(), returnTokenCount, tokens(i))
        Next
        For i As Long = 1 To returnPointerCount
            AddToken(returnTypeTokens(), returnTokenCount, "*")
        Next
        Dim resolvedReturnType As C2fbResolvedTypeModel
        ResolveC2fbTypeModel(translation, catalog, _
            returnTypeTokens(), 0, returnTokenCount - 1, resolvedReturnType, _
            C2FB_POINTER_MAPPING_OPAQUE, typeMappingKind)
        If resolvedReturnType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then
            EmitC2fbSkipped(translation, outputFile, conversionSummary, "unknown return type", _
                C2fbTypeResolutionFailureDescription(resolvedReturnType.status) & ": " & declaration)
            Exit Sub
        End If
        returnType = resolvedReturnType.freeBasicType
        If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER AndAlso _
           resolvedReturnType.pointerCount = 0 AndAlso _
           GenericHeaderTypeIsOpaqueEmptyRecordInHeader( _
            translation.genericC.header, returnType) <> 0 Then
            EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                "zero-size record return type has no FreeBASIC by-value ABI", declaration)
            Exit Sub
        End If
        If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then _
            returnType = ApplyGenericStringOverrideInGenericC( _
                translation.genericC, functionName, returnType)
        If returnType = "" OrElse returnType = "void" AndAlso _
           resolvedReturnType.pointerCount <> 0 Then
            EmitC2fbSkipped(translation, outputFile, conversionSummary, "unknown return type", declaration)
            Exit Sub
        End If
    End If

    Dim parameterList As String = ""
    Dim argCount As Long = 0
    Dim paramStart As Long = openParen + 1
    Dim parenDepth As Long = 0
    Dim hasVarargs As Long = 0
    Dim unsupported As Long = 0

    If paramStart < closeParen Then
        For i As Long = paramStart To closeParen
            Dim atEnd As Long = (i = closeParen)
            If Not atEnd Then
                If tokens(i) = "(" Then parenDepth += 1
                If tokens(i) = ")" Then parenDepth -= 1
            End If
            If atEnd OrElse (tokens(i) = "," AndAlso parenDepth = 0) Then
                Dim parameterLastToken As Long = i - 1
                Dim defaultValueStart As Long = -1
                If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER AndAlso _
                   translation.genericC.header.cppMode <> 0 Then
                    Dim defaultSeparator As Long
                    If FindGenericCppDefaultArgumentSeparator( _
                        tokens(), paramStart, parameterLastToken, _
                        defaultSeparator) = 0 Then
                        EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                            "malformed C++ default argument", declaration)
                        Exit Sub
                    End If
                    If defaultSeparator >= 0 Then
                        If defaultSeparator >= parameterLastToken Then
                            EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                                "empty C++ default argument", declaration)
                            Exit Sub
                        End If
                        defaultValueStart = defaultSeparator + 1
                        parameterLastToken = defaultSeparator - 1
                    End If
                End If
                Dim parameterResult As C2fbParameterConversionResultModel
                ConvertParameterInContext( _
                    translation, catalog, tokens(), _
                    paramStart, parameterLastToken, argCount, parameterResult, _
                    C2FB_POINTER_MAPPING_OPAQUE, typeMappingKind, functionName)
                If parameterResult.status = C2FB_PARAMETER_CONVERSION_VARIADIC Then
                    hasVarargs = -1
                    Exit For
                ElseIf parameterResult.status = C2FB_PARAMETER_CONVERSION_UNSUPPORTED OrElse _
                       parameterResult.status = C2FB_PARAMETER_CONVERSION_INVALID Then
                    EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                        "unsupported parameter declaration", declaration)
                    Exit Sub
                ElseIf parameterResult.status = C2FB_PARAMETER_CONVERSION_CONVERTED Then
                    If defaultValueStart >= 0 AndAlso _
                       TranslateGenericCppDefaultArgument( _
                        translation, parameterResult, tokens(), _
                        defaultValueStart, i - 1, functionName) = 0 Then
                        EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                            "unsupported C++ default argument", declaration)
                        Exit Sub
                    End If
                    If argCount > 0 Then parameterList &= ", "
                    If parameterResult.freeBasicType = "Cva_List" Then
                        parameterList &= "ByVal " & parameterResult.freeBasicDeclaration
                    ElseIf parameterResult.isByRef <> 0 Then
                        parameterList &= "ByRef " & parameterResult.freeBasicDeclaration
                    Else
                        parameterList &= "ByVal " & parameterResult.freeBasicDeclaration
                    End If
                    argCount += 1
                End If
                paramStart = i + 1
            End If
        Next
    End If

    If unsupported <> 0 Then
        EmitC2fbSkipped(translation, outputFile, conversionSummary, "unsupported declaration", declaration)
        Exit Sub
    End If

    If hasVarargs <> 0 Then
        If argCount > 0 Then parameterList &= ", "
        parameterList &= "..."
        ' C variadic calls use the CDecl ABI even when a compiler attribute
        ' requests a fixed-argument convention such as StdCall.
        callingConvention = "CDecl"
    End If

    Dim emittedName As String = functionName
    If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then _
        emittedName = GenericFreeBasicFunctionNameInContext( _
            translation, functionName, outputNames(), outputNameCount, _
            C2FB_SYMBOL_RENAME_PROCEDURE)
    Dim procedureBinding As C2fbProcedureBindingModel
    procedureBinding.freeBasicName = emittedName
    procedureBinding.cName = functionName
    procedureBinding.linkName = sourceDeclaration.linkName
    procedureBinding.returnType = returnType
    procedureBinding.parameterList = parameterList
    procedureBinding.callingConvention = callingConvention
    procedureBinding.isWindowsMS = CInt( _
        typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER AndAlso _
        translation.genericC.policy.windowsMsCallingConvention <> 0 AndAlso _
        callingConvention = "StdCall") * -1
    procedureBinding.isSub = CInt(returnType = "void") * -1
    If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then
        WriteGenericProcedureBindingWithGuardsInPolicy( _
            translation.genericC.policy, outputFile, functionName, procedureBinding)
    Else
        EmitProcedureBinding(outputFile, procedureBinding)
    End If

    If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then _
        RecordGenericHeaderProcedureInContext(translation, functionName, procedureBinding)

    If nameCount >= UBound(names) Then ReDim Preserve names(0 To UBound(names) * 2 + 1)
    names(nameCount) = functionName
    nameCount += 1
    If typeMappingKind = C2FB_TYPE_MAPPING_GENERIC_HEADER Then
        If outputNameCount > UBound(outputNames) Then _
            ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
        outputNames(outputNameCount) = emittedName
        outputNameCount += 1
    End If
    conversionSummary.convertedCount += 1
End Sub

Private Sub EmitPrototypeWithTokens( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal declaration As String, _
    tokens() As String, ByVal tokenCount As Long, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    names() As String, _
    ByRef nameCount As Long, _
    outputNames() As String, _
    ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel, _
    ByVal typeMappingKind As C2fbTypeMappingKind = C2FB_TYPE_MAPPING_BODY _
)
    Dim sourceDeclaration As C2fbDeclarationModel
    sourceDeclaration.text = declaration
    If tokenCount < 3 OrElse tokenCount >= MAX_TYPE_WORDS Then Exit Sub

    Dim loweredDeclaration As String
    Dim linkName As String
    Dim loweredTokens() As String
    Dim loweredTokenCount As Long = 0
    Dim assemblyNameStatus As Long = ParseCAssemblyNameLabel( _
        declaration, loweredDeclaration, linkName)
    If assemblyNameStatus > 0 Then
        EmitC2fbSkipped(translation, outputFile, conversionSummary, _
            "unsupported assembler symbol name", declaration)
        Exit Sub
    ElseIf assemblyNameStatus < 0 Then
        sourceDeclaration.text = loweredDeclaration
        TokenizeCDeclaration( _
            StripCFunctionAttributes(loweredDeclaration), _
            loweredTokens(), loweredTokenCount)
    Else
        ReDim loweredTokens(0 To tokenCount - 1)
        loweredTokenCount = tokenCount
        For tokenIndex As Long = 0 To tokenCount - 1
            loweredTokens(tokenIndex) = tokens(tokenIndex)
        Next
    End If
    If loweredTokenCount < 3 OrElse loweredTokenCount >= MAX_TYPE_WORDS Then Exit Sub
    sourceDeclaration.linkName = linkName
    sourceDeclaration.tokenCount = loweredTokenCount
    ReDim sourceDeclaration.tokens(0 To loweredTokenCount - 1)
    For tokenIndex As Long = 0 To loweredTokenCount - 1
        sourceDeclaration.tokens(tokenIndex) = loweredTokens(tokenIndex)
    Next
    Dim functionDeclaration As C2fbFunctionDeclarationModel
    If ParseCFunctionDeclarationModel( _
        sourceDeclaration.tokens(), loweredTokenCount, functionDeclaration) = 0 Then Exit Sub
    sourceDeclaration.functionDeclaration = functionDeclaration
    sourceDeclaration.entryKind = C2FB_DECLARATION_FUNCTION
    sourceDeclaration.sourceName = functionDeclaration.declarator.name
    EmitPrototypeModel( _
        translation, catalog, sourceDeclaration, outputFile, names(), nameCount, _
        outputNames(), outputNameCount, conversionSummary, typeMappingKind)
End Sub

Private Sub EmitPrototype( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal declaration As String, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    names() As String, _
    ByRef nameCount As Long, _
    outputNames() As String, _
    ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel, _
    ByVal typeMappingKind As C2fbTypeMappingKind = C2FB_TYPE_MAPPING_BODY _
)
    Dim normalizedDeclaration As String = StripCFunctionAttributes(declaration)
    Dim tokens() As String
    Dim tokenCount As Long = 0
    TokenizeCDeclaration(normalizedDeclaration, tokens(), tokenCount)
    EmitPrototypeWithTokens( _
        translation, catalog, declaration, tokens(), tokenCount, outputFile, _
        names(), nameCount, outputNames(), outputNameCount, conversionSummary, _
        typeMappingKind)
End Sub

/' end of c2fb_prototypes.bi '/
