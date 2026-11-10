/'
    Project: C2FB body lowering
    ---------------------------

    File: c2fb_body_lowering.bi

    Purpose:

        Assemble conservative FreeBASIC procedure candidates from parsed
        signatures and lowered body statements.

    Responsibilities:

        - Convert collected function signatures and parameter bindings.
        - Apply exact user-supplied FreeBASIC replacements to complete functions.
        - Combine structured statement output into procedure definitions.
        - Route rejected procedure candidates through shared diagnostics.

    This file intentionally does NOT contain:

        - C statement or local declaration lowering.
        - C source collection, preprocessing, or command option handling.
        - Shared C text scanners, type resolution, or generated-file output.
'/

Private Function TranslateStructuredBody( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal functionName As String, _
    ByRef bodyText As String, _
    ByRef translatedBody As String, _
    ByVal returnType As String, _
    callableNames() As String, _
    ByVal callableCount As Long, _
    parameterNames() As String, _
    parameterAliases() As String, _
    parameterTypes() As String, _
    ByRef symbolCount As Long, _
    ByRef generatedBodyHelpers As String _
) As Long
    translatedBody = ""
    generatedBodyHelpers = ""
    Dim context As SimpleBodyContext
    context.functionName = functionName
    ResetSimpleBodyFailure(context)
    If SimpleBodyContainsBuiltinAlloca(bodyText) <> 0 Then
        If SimpleBodyContainsNonlocalExit(bodyText) <> 0 Then
            ReportC2fbRejected(translation, functionName, "alloca-nonlocal-exit", _
                               "alloca storage cannot be released across a longjmp")
            Return 0
        End If
        If EnsureSimpleAllocaTracking(context) = 0 Then
            ReportC2fbRejected(translation, functionName, "alloca-workspace-limit", _
                               "could not allocate procedure-local alloca tracking")
            Return 0
        End If
    End If
    Dim locals(0 To MAX_SIMPLE_VARIABLES - 1) As SimpleLocalVariable
    Dim localCount As Long = 0
    If PushSimpleBodyScope(context, symbolCount, localCount) = 0 Then Return 0
    context.scopeSymbols(0) = 0
    Dim position As Long = 1
    Dim statementCount As Long = 0
    Dim finalStatementTerminates As Long = 0
    While position <= Len(bodyText)
        SkipCSpaces(bodyText, position)
        If position > Len(bodyText) Then Exit While
        Dim statementText As String
        Dim statementStart As Long = position
        Dim statementTerminates As Long = 0
        If ParseSimpleCStatement(translation, catalog, bodyText, position, statementText, "    ", returnType, context, _
                                 callableNames(), callableCount, parameterNames(), _
                                 parameterAliases(), parameterTypes(), symbolCount, locals(), localCount, _
                                 statementTerminates) = 0 Then
            Dim failurePosition As Long = position
            If failurePosition < statementStart OrElse failurePosition > Len(bodyText) Then _
                failurePosition = statementStart
            If context.failureMessage <> "" Then
                ReportC2fbRejected( _
                    translation, functionName, context.failureCode, _
                    context.failureMessage)
            Else
                ReportC2fbRejected(translation,  _
                    functionName, "unsupported-body-statement", _
                    Left(Mid(bodyText, failurePosition), 300))
            End If
            Return 0
        End If
        translatedBody &= IIf(statementCount = 0, "", Chr(10)) & statementText
        statementCount += 1
        finalStatementTerminates = statementTerminates
    Wend
    For i As Long = 0 To context.labelCount - 1
        If context.labels(i).isUsed <> 0 AndAlso context.labels(i).isDefined = 0 Then
            ReportC2fbRejected(translation,  _
                functionName, "undefined-label", _
                "undefined label " & context.labels(i).sourceName)
            Return 0
        End If
    Next
    If statementCount = 0 Then translatedBody = "    ' empty C function body"
    If returnType <> "void" AndAlso finalStatementTerminates = 0 Then
        If functionName = "main" AndAlso returnType = "c2fb_c_int" Then
            ' C specifies an implicit return value of zero when main reaches
            ' the end of its body without an explicit return statement.
            If translatedBody <> "" Then translatedBody &= Chr(10)
            translatedBody &= "    Return 0"
        Else
            ReportC2fbRejected(translation, _
                functionName, "missing-return", _
                "final path is not known to return")
            Return 0
        End If
    End If
    If returnType = "void" AndAlso finalStatementTerminates = 0 AndAlso _
       context.allocaHeadName <> "" Then
        If translatedBody <> "" Then translatedBody &= Chr(10)
        translatedBody &= SimpleAllocaCleanupText(context, "    ")
    End If
    If context.declarations <> "" Then _
        translatedBody = context.declarations & Chr(10) & translatedBody
    generatedBodyHelpers = context.generatedBodyHelpers
    Return -1
End Function

Private Function ExtractGenericFreeBasicFunctionReplacement( _
    ByVal replacementText As String, _
    ByVal sourceName As String, ByVal freeBasicName As String, _
    ByVal expectedSub As Long, ByRef replacementBody As String _
) As Long
    replacementBody = ""
    Dim firstLineEnd As Long = InStr(replacementText, Chr(10))
    If firstLineEnd = 0 Then Return 0
    Dim headerLine As String = Trim(Left(replacementText, firstLineEnd - 1))
    If Right(headerLine, 1) = Chr(13) Then _
        headerLine = Left(headerLine, Len(headerLine) - 1)
    Dim headerTokens() As String
    Dim headerTokenCount As Long
    TokenizeCDeclaration(headerLine, headerTokens(), headerTokenCount)
    Dim tokenIndex As Long = 0
    If tokenIndex < headerTokenCount AndAlso _
       LCase(headerTokens(tokenIndex)) = "private" Then tokenIndex += 1
    If tokenIndex + 2 >= headerTokenCount Then Return 0
    Dim replacementIsSub As Long
    Select Case LCase(headerTokens(tokenIndex))
    Case "function"
        replacementIsSub = 0
    Case "sub"
        replacementIsSub = -1
    Case Else
        Return 0
    End Select
    If replacementIsSub <> expectedSub OrElse _
       headerTokens(tokenIndex + 2) <> "(" Then Return 0
    Dim replacementName As String = headerTokens(tokenIndex + 1)
    If LCase(replacementName) <> LCase(sourceName) AndAlso _
       LCase(replacementName) <> LCase(freeBasicName) Then Return 0

    Dim endLineStart As Long = 0
    Dim lastLine As String
    Dim lineStart As Long = firstLineEnd + 1
    While lineStart <= Len(replacementText)
        Dim lineEnd As Long = InStr(lineStart, replacementText, Chr(10))
        If lineEnd = 0 Then lineEnd = Len(replacementText) + 1
        Dim lineText As String = Mid(replacementText, lineStart, lineEnd - lineStart)
        If Right(lineText, 1) = Chr(13) Then _
            lineText = Left(lineText, Len(lineText) - 1)
        If Trim(lineText) <> "" Then
            lastLine = LCase(Trim(lineText))
            endLineStart = lineStart
        End If
        lineStart = lineEnd + 1
    Wend
    If endLineStart = 0 OrElse _
       lastLine <> IIf(expectedSub <> 0, "end sub", "end function") Then Return 0
    replacementBody = Mid( _
        replacementText, firstLineEnd + 1, endLineStart - firstLineEnd - 1)
    Return -1
End Function

Private Function BuildSimpleProcedure( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef sourceItem As C2fbSourceItemModel, _
    ByRef functionName As String, _
    callableNames() As String, _
    ByVal callableCount As Long, _
    ByRef procedureBinding As C2fbProcedureBindingModel _
) As String
    Dim procedureText As String = ""
    functionName = sourceItem.declaration.sourceName
    Dim tokenCount As Long = sourceItem.declaration.tokenCount
    Dim functionDeclaration As C2fbFunctionDeclarationModel = _
        sourceItem.declaration.functionDeclaration
    If C2fbCTextContainsIdentifier( _
        sourceItem.declaration.text, "volatile") <> 0 Then
        ReportC2fbRejected( _
            translation, functionName, "volatile-semantics-not-preserved", _
            "volatile-qualified function parameters are not supported")
        Return procedureText
    End If
    ' Keep body conversion conservative; every unrecognized statement rejects the candidate.
    If sourceItem.declaration.hasDirectives <> 0 Then
        ReportC2fbRejected(translation,  _
            functionName, "preprocessor-controlled-body", "preprocessor-controlled body")
        Return procedureText
    End If

    Dim bodyText As String = Trim(sourceItem.body)
    Dim freeBasicFunctionReplacement As String
    Dim hasFreeBasicFunctionReplacement As Long = 0
    If translation.target.profile <> C2FB_TARGET_SQLITE Then
        Dim replacementTarget As String
        Dim replacementIsFreeBasic As Long
        Dim sourceFunctionText As String = _
            sourceItem.declaration.text & "{" & sourceItem.body & "}"
        If C2fbReplacementRuleMatch( _
            translation.genericC.policy, sourceFunctionText, _
            replacementTarget, replacementIsFreeBasic) <> 0 AndAlso _
           replacementIsFreeBasic <> 0 Then
            freeBasicFunctionReplacement = replacementTarget
            hasFreeBasicFunctionReplacement = -1
        End If
    End If
    If functionDeclaration.declarator.operatorCount = 0 OrElse _
       functionDeclaration.declarator.operatorKind(0) <> C2FB_DECLARATOR_FUNCTION Then
        ReportC2fbRejected(translation, functionName, "unsupported-declaration", "unsupported declaration")
        Return procedureText
    End If

    Dim returnsCallback As Long = _
        IsFunctionReturnCallbackDeclarator(functionDeclaration.declarator)
    Dim returnPointerCount As Long = 0
    If returnsCallback = 0 Then
        For operatorIndex As Long = 1 To functionDeclaration.declarator.operatorCount - 1
            If functionDeclaration.declarator.operatorKind(operatorIndex) <> _
               C2FB_DECLARATOR_POINTER Then
                ReportC2fbRejected( _
                    translation, functionName, "unsupported-return-declarator", _
                    "unsupported return declarator")
                Return procedureText
            End If
            returnPointerCount += 1
        Next
    End If

    Dim openParen As Long = functionDeclaration.declarator.firstFunctionOpenToken
    Dim closePosition As Long = openParen
    If SkipCDeclaratorGroup( _
        sourceItem.declaration.tokens(), closePosition, tokenCount - 1, "(", ")") = 0 Then
        ReportC2fbRejected( _
            translation, functionName, "unsupported-declaration", "unsupported declaration")
        Return procedureText
    End If
    Dim closeParen As Long = closePosition - 1

    Dim returnType As String
    If returnsCallback <> 0 Then
        returnType = CFunctionReturnCallbackType( _
            translation, catalog, sourceItem.declaration.tokens(), tokenCount, _
            functionDeclaration.declaratorStartToken, _
            functionDeclaration.declarator, C2FB_TYPE_MAPPING_BODY)
        If returnType = "" Then
            ReportC2fbRejected( _
                translation, functionName, "unsupported-return-type", _
                "unsupported callback return type")
            Return procedureText
        End If
    Else
        Dim returnStart As Long = 0
        While returnStart < functionDeclaration.declaratorStartToken AndAlso _
              (sourceItem.declaration.tokens(returnStart) = "static" OrElse _
               sourceItem.declaration.tokens(returnStart) = "inline" OrElse _
               sourceItem.declaration.tokens(returnStart) = "__inline" OrElse _
               sourceItem.declaration.tokens(returnStart) = "__inline__" OrElse _
               sourceItem.declaration.tokens(returnStart) = "__extension__" OrElse _
               sourceItem.declaration.tokens(returnStart) = "extern" OrElse _
               sourceItem.declaration.tokens(returnStart) = "_Noreturn" OrElse _
               sourceItem.declaration.tokens(returnStart) = "__noreturn" OrElse _
               IsAttributeToken(sourceItem.declaration.tokens(returnStart)) <> 0)
            returnStart += 1
        Wend
        If functionDeclaration.declaratorStartToken + returnPointerCount > MAX_TYPE_WORDS Then
            ReportC2fbRejected( _
                translation, functionName, "return-type-limit-exceeded", "return type limit exceeded")
            Return procedureText
        End If
        Dim returnTypeTokens() As String
        ReDim returnTypeTokens(0 To MAX_TYPE_WORDS - 1)
        Dim returnTypeTokenCount As Long = 0
        For tokenIndex As Long = returnStart To functionDeclaration.declaratorStartToken - 1
            AddToken(returnTypeTokens(), returnTypeTokenCount, _
                     sourceItem.declaration.tokens(tokenIndex))
        Next
        For pointerIndex As Long = 1 To returnPointerCount
            AddToken(returnTypeTokens(), returnTypeTokenCount, "*")
        Next
        Dim resolvedReturnType As C2fbResolvedTypeModel
        ResolveC2fbTypeModel(translation, catalog, _
            returnTypeTokens(), 0, returnTypeTokenCount - 1, resolvedReturnType, _
            C2FB_POINTER_MAPPING_PRESERVE, C2FB_TYPE_MAPPING_BODY, _
            C2FB_TYPE_RECOGNITION_KNOWN_TYPES_ONLY)
        If resolvedReturnType.status <> C2FB_TYPE_RESOLUTION_RESOLVED Then
            Dim failureDetail As String = "return type resolution failed: " & _
                C2fbTypeResolutionFailureDescription(resolvedReturnType.status)
            ReportC2fbRejected(translation, functionName, "unsupported-return-type", failureDetail)
            Return procedureText
        End If
        returnType = resolvedReturnType.freeBasicType
        If returnType = "void" AndAlso resolvedReturnType.pointerCount <> 0 Then
            ReportC2fbRejected(translation, functionName, "unsupported-return-type", "unsupported return type")
            Return procedureText
        End If
    End If
    Dim parameterList As String = ""
    Dim argumentCount As Long = 0
    Dim sourceParameterNames(0 To MAX_SIMPLE_VARIABLES - 1) As String
    Dim sourceParameterAliases(0 To MAX_SIMPLE_VARIABLES - 1) As String
    Dim sourceParameterTypes(0 To MAX_SIMPLE_VARIABLES - 1) As String
    Dim parameterStart As Long = openParen + 1
    Dim parenDepth As Long = 0
    If parameterStart < closeParen Then
        For i As Long = parameterStart To closeParen
            Dim atEnd As Long = (i = closeParen)
            If Not atEnd Then
                If sourceItem.declaration.tokens(i) = "(" Then parenDepth += 1
                If sourceItem.declaration.tokens(i) = ")" Then parenDepth -= 1
            End If
            If atEnd OrElse (sourceItem.declaration.tokens(i) = "," AndAlso parenDepth = 0) Then
                If atEnd <> 0 AndAlso parameterStart = i - 1 AndAlso _
                   sourceItem.declaration.tokens(parameterStart) = "..." Then
                    If argumentCount = 0 Then
                        ReportC2fbRejected(translation,  _
                            functionName, "variadic-without-fixed-parameter", _
                            "variadic function has no fixed parameter")
                        Return ""
                    End If
                    If Len(parameterList) <> 0 Then parameterList &= ", "
                    parameterList &= "..."
                Else
                    Dim parameterResult As C2fbParameterConversionResultModel
                    ConvertParameterInContext( _
                        translation, catalog, sourceItem.declaration.tokens(), _
                        parameterStart, i - 1, argumentCount, parameterResult)
                    If parameterResult.status = C2FB_PARAMETER_CONVERSION_UNSUPPORTED OrElse _
                       parameterResult.status = C2FB_PARAMETER_CONVERSION_INVALID OrElse _
                       parameterResult.status = C2FB_PARAMETER_CONVERSION_VARIADIC Then
                        ReportC2fbRejected(translation, _
                            functionName, "unsupported-parameter-declaration", _
                            "unsupported parameter declaration")
                        Return ""
                    End If
                    If parameterResult.status = C2FB_PARAMETER_CONVERSION_CONVERTED Then
                        Dim parameterName As String = parameterResult.sourceName
                        If IsIdentifierToken(parameterName) = 0 Then
                            ReportC2fbRejected(translation, _
                                functionName, "unsupported-parameter-type", _
                                "unsupported parameter type")
                            Return ""
                        End If
                        Dim parameterTypeEnd As Long = i - 1
                        Dim parameterUsesPointer As Long = 0
                        ' A parameter name can repeat its enum or record tag.
                        ' Keep the final match, after the complete type span.
                        For typeIndex As Long = parameterStart To i - 1
                            If sourceItem.declaration.tokens(typeIndex) = "*" OrElse _
                               sourceItem.declaration.tokens(typeIndex) = "[" Then parameterUsesPointer = -1
                            If sourceItem.declaration.tokens(typeIndex) = parameterName AndAlso _
                               IsTypeOrQualifierTokenInContext(translation, sourceItem.declaration.tokens(typeIndex)) = 0 Then
                                parameterTypeEnd = typeIndex - 1
                            End If
                        Next
                        If parameterUsesPointer = 0 AndAlso _
                           InStr(parameterResult.freeBasicType, " Ptr") = 0 AndAlso _
                           IsCBodyCallbackTypeInContext( _
                               translation, parameterResult.freeBasicType) = 0 Then
                            Dim parameterTypeStatus As C2fbTypeResolutionStatus = _
                                C2fbTypeRecognitionStatusInContext( _
                                    translation, catalog, sourceItem.declaration.tokens(), _
                                    parameterStart, parameterTypeEnd)
                            If parameterTypeStatus <> C2FB_TYPE_RESOLUTION_RESOLVED Then
                                ReportC2fbRejected(translation, _
                                    functionName, "unsupported-parameter-type", _
                                    "unsupported parameter type: " & _
                                    C2fbTypeResolutionFailureDescription(parameterTypeStatus))
                                Return ""
                            End If
                        End If
                        If argumentCount >= MAX_TYPE_WORDS Then
                            ReportC2fbRejected(translation, _
                                functionName, "parameter-limit-exceeded", "parameter limit exceeded")
                            Return ""
                        End If
                        sourceParameterNames(argumentCount) = parameterName
                        sourceParameterTypes(argumentCount) = parameterResult.freeBasicType
                        sourceParameterAliases(argumentCount) = parameterResult.argumentName
                        If argumentCount > 0 Then parameterList &= ", "
                        ' C va_list parameters pass by value after C's
                        ' parameter adjustment, including array-backed ABIs.
                        parameterList &= "ByVal " & parameterResult.freeBasicDeclaration
                        argumentCount += 1
                    End If
                End If
                parameterStart = i + 1
            End If
        Next
    End If

    Dim structuredStatic As Long = 0
    For i As Long = 0 To tokenCount - 1
        If sourceItem.declaration.tokens(i) = "static" Then structuredStatic = -1
    Next
    procedureBinding.freeBasicName = CBodyFreeBasicProcedureNameInContext( _
        translation, catalog, functionName)
    procedureBinding.cName = functionName
    Dim bodySymbolIndex As Long = CBodyProcedureIndex(translation, functionName)
    If bodySymbolIndex >= 0 Then _
        procedureBinding.linkName = _
            translation.symbolTable.symbols(bodySymbolIndex).body.linkName
    If procedureBinding.linkName = "" Then _
        procedureBinding.linkName = sourceItem.declaration.linkName
    procedureBinding.returnType = returnType
    procedureBinding.parameterList = parameterList
    procedureBinding.callingConvention = CFunctionCallingConvention( _
        sourceItem.declaration.text, functionName, _
        C2FB_TYPE_MAPPING_GENERIC_HEADER)
    procedureBinding.isSub = CInt(returnType = "void") * -1
    procedureBinding.isPrivate = structuredStatic

    If hasFreeBasicFunctionReplacement <> 0 Then
        Dim replacementBody As String
        If ExtractGenericFreeBasicFunctionReplacement( _
            freeBasicFunctionReplacement, functionName, _
            procedureBinding.freeBasicName, procedureBinding.isSub, _
            replacementBody) = 0 Then
            ReportC2fbRejected( _
                translation, functionName, "invalid-function-replacement", _
                "FreeBASIC function replacement must match the C procedure name and kind")
            Return ""
        End If
        replacementBody = RewriteGenericBodyLocalNames( _
            replacementBody, sourceParameterNames(), _
            sourceParameterAliases(), argumentCount)
        Return FreeBasicProcedureDefinition(procedureBinding, replacementBody)
    End If

    Dim structuredBody As String
    Dim generatedBodyHelpers As String
    Dim totalSymbolCount As Long = argumentCount
    If TranslateStructuredBody(translation, catalog, functionName, bodyText, structuredBody, returnType, callableNames(), _
                               callableCount, sourceParameterNames(), _
                               sourceParameterAliases(), sourceParameterTypes(), totalSymbolCount, _
                               generatedBodyHelpers) = 0 Then Return procedureText

    procedureText = FreeBasicProcedureDefinition(procedureBinding, structuredBody)
    If generatedBodyHelpers <> "" Then _
        procedureText = generatedBodyHelpers & Chr(10) & procedureText
    Return procedureText
End Function
/' end of c2fb_body_lowering.bi '/
