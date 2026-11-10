/'
    Project: C2FB generic header converter

    File: c2fb_generic_macro_output.bi

    Purpose:

        Emit generic-header macro bindings and unsupported-macro notes.

    Responsibilities:

        - Emit supported integer, floating-literal, type, alias, function, and string macros.
        - Emit guarded private overload helpers for call-site integer casts.
        - Emit private overload sets for call-site-dependent arithmetic macros.
        - Preserve unsupported preprocessor definitions for manual review.
        - Bound macro excerpts written into generated comments.
        - Use the shared macro lowerer and output sink for generated bindings.

    This file intentionally does NOT contain:

        - Macro source collection or expression parsing.
        - C record layout or external object declaration lowering.
'/

Private Function GenericFreeBasicMacroNameInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceName As String, outputNames() As String, _
    ByVal outputNameCount As Long _
) As String
    Return GenericFreeBasicFunctionNameInContext( _
        translation, sourceName, outputNames(), outputNameCount, _
        C2FB_SYMBOL_RENAME_DEFINE)
End Function

Private Function GenericHeaderTransientMacroSourceIncluded( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourcePath As String _
) As Long
    If GenericSourceIncludedInPolicy( _
        translation.genericC.policy, sourcePath) = 0 Then Return 0
    If translation.genericC.header.rootSourcePath <> "" AndAlso _
       GenericSourcePathMatchesPatternInPolicy( _
        sourcePath, translation.genericC.header.rootSourcePath) <> 0 Then Return -1
    If translation.genericC.policy.sourceIncludeCount > 0 Then Return -1
    Return 0
End Function

Private Sub WriteGenericHeaderTransientMacros( _
    ByRef translation As C2fbTranslationContext, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    outputNames() As String, ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    Dim emptyParameterNames(0 To 0) As String
    For occurrenceIndex As Long = 0 To _
        translation.genericC.header.macroOccurrenceCount - 1
        Dim occurrence As C2fbMacroDefinitionModel = _
            translation.genericC.header.macroOccurrences(occurrenceIndex)
        If occurrence.directive <> "define" OrElse occurrence.sourceName = "" OrElse _
           GenericHeaderTransientMacroSourceIncluded( _
            translation, occurrence.sourceLocation.path) = 0 OrElse _
           GenericDefineExcludedInPolicy( _
            translation.genericC.policy, occurrence.sourceName) <> 0 Then Continue For

        Dim activeIndex As Long = GenericHeaderMacroIndexInContext( _
            translation, occurrence.sourceName)
        If activeIndex >= 0 AndAlso _
           translation.genericC.header.headerMacros(activeIndex).active <> 0 Then _
            Continue For

        Dim freeBasicName As String = GenericFreeBasicMacroNameInContext( _
            translation, occurrence.sourceName, outputNames(), outputNameCount)
        If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
            ReportError("generic header exceeds the configured transient macro limit")
        If outputNameCount > UBound(outputNames) Then _
            ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
        outputNames(outputNameCount) = freeBasicName
        outputNameCount += 1

        Dim macroBinding As C2fbMacroBindingModel
        macroBinding.name = freeBasicName
        If occurrence.functionLike <> 0 Then
            TokenizeCDeclaration(occurrence.rawValue, occurrence.tokens(), occurrence.tokenCount)
            Dim parameterNames() As String
            Dim freeParameterNames() As String
            Dim parameterCount As Long
            Dim isVariadic As Long
            Dim body As String
            If ParseGenericFunctionMacro( _
                occurrence, parameterNames(), freeParameterNames(), _
                parameterCount, isVariadic, body) = 0 Then Continue For
            ApplyGenericMacroParameterRenamesInPolicy( _
                translation.genericC.policy, parameterNames(), _
                freeParameterNames(), parameterCount, body)

            Dim translatedFunctionBody As String
            If TranslateGenericMacroTokenSequence( _
                translation, body, parameterNames(), freeParameterNames(), _
                parameterCount, isVariadic, translatedFunctionBody) = 0 Then
                translatedFunctionBody = body
                For parameterIndex As Long = 0 To parameterCount - 1
                    freeParameterNames(parameterIndex) = parameterNames(parameterIndex)
                Next
            End If
            For parameterIndex As Long = 0 To parameterCount - 1
                If parameterIndex > 0 Then macroBinding.parameters &= ", "
                macroBinding.parameters &= freeParameterNames(parameterIndex)
                If isVariadic <> 0 AndAlso parameterIndex = parameterCount - 1 Then _
                    macroBinding.parameters &= "..."
            Next
            macroBinding.bodyText = translatedFunctionBody
            macroBinding.isFunctionLike = -1
            conversionSummary.genericHeader.functionMacroCount += 1
        Else
            Dim translatedObjectBody As String
            If TranslateGenericMacroTokenSequence( _
                translation, occurrence.rawValue, emptyParameterNames(), _
                emptyParameterNames(), 0, 0, translatedObjectBody) = 0 Then _
                translatedObjectBody = occurrence.rawValue
            macroBinding.bodyText = translatedObjectBody
            conversionSummary.genericHeader.tokenSequenceMacroCount += 1
        End If

        WriteGenericMacroBindingWithGuardsInPolicy( _
            translation.genericC.policy, outputFile, _
            occurrence.sourceName, macroBinding)
        WriteC2fbOutputLine(outputFile, "#undef " & freeBasicName)
    Next
End Sub

' Bound skipped-macro excerpts so one opaque system macro cannot bloat output.
Private Const MAX_GENERIC_MACRO_SUMMARY As Long = 240

Private Sub PreallocateGenericHeaderTokenMacroNames( _
    ByRef translation As C2fbTranslationContext, _
    outputNames() As String, ByRef outputNameCount As Long _
)
    For macroIndex As Long = 0 To _
        translation.genericC.header.headerMacroCount - 1
        With translation.genericC.header.headerMacros(macroIndex)
            If .active = 0 OrElse .privateName <> 0 OrElse _
               .emitted <> 0 OrElse _
               GenericDefineExcludedInPolicy( _
                translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
               GenericMacroTokenConversionForcedInPolicy( _
                translation.genericC.policy, .definition.sourceName, 0) = 0 OrElse _
               .freeBasicName <> "" Then Continue For
            If .definition.functionLike <> 0 Then
                Dim parameterNames() As String
                Dim freeParameterNames() As String
                Dim parameterCount As Long
                Dim isVariadic As Long
                Dim body As String
                If ParseGenericFunctionMacro( _
                    .definition, parameterNames(), freeParameterNames(), _
                    parameterCount, isVariadic, body) = 0 Then Continue For
            End If
            .freeBasicName = GenericFreeBasicMacroNameInContext( _
                translation, .definition.sourceName, outputNames(), outputNameCount)
            If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                ReportError("generic header exceeds the configured token macro limit")
            If outputNameCount > UBound(outputNames) Then _
                ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
            outputNames(outputNameCount) = .freeBasicName
            outputNameCount += 1
        End With
    Next

    ' A token-converted wrapper can call a helper macro whose name must be
    ' reserved before normal macro emission assigns names in output order.
    For ownerIndex As Long = 0 To _
        translation.genericC.header.headerMacroCount - 1
        With translation.genericC.header.headerMacros(ownerIndex)
            If .active = 0 OrElse .privateName <> 0 OrElse _
               .emitted <> 0 OrElse GenericDefineExcludedInPolicy( _
                translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
               GenericMacroTokenConversionForcedInPolicy( _
                translation.genericC.policy, .definition.sourceName, 0) = 0 Then _
                Continue For

            Dim macroBody As String = .definition.rawValue
            Dim parameterNames() As String
            Dim freeParameterNames() As String
            Dim parameterCount As Long = 0
            Dim isVariadic As Long = 0
            If .definition.functionLike <> 0 Then
                If ParseGenericFunctionMacro( _
                    .definition, parameterNames(), freeParameterNames(), _
                    parameterCount, isVariadic, macroBody) = 0 Then Continue For
            End If

            Dim bodyTokens() As String
            Dim bodyTokenCount As Long
            If TokenizeCPreprocessorReplacement( _
                macroBody, bodyTokens(), bodyTokenCount) = 0 Then Continue For
            For tokenIndex As Long = 0 To bodyTokenCount - 1
                Dim sourceToken As String = bodyTokens(tokenIndex)
                If IsIdentifierToken(sourceToken) = 0 Then Continue For
                Dim isParameter As Long = 0
                For parameterIndex As Long = 0 To parameterCount - 1
                    If sourceToken = parameterNames(parameterIndex) Then
                        isParameter = -1
                        Exit For
                    End If
                Next
                If isParameter <> 0 Then Continue For

                Dim helperIndex As Long = GenericHeaderMacroIndexInContext( _
                    translation, sourceToken)
                If helperIndex < 0 Then Continue For
                With translation.genericC.header.headerMacros(helperIndex)
                    If .active = 0 OrElse .privateName <> 0 OrElse _
                       GenericDefineExcludedInPolicy( _
                        translation.genericC.policy, sourceToken) <> 0 Then _
                        Continue For
                    If .freeBasicName <> "" Then Continue For
                    .freeBasicName = GenericFreeBasicMacroNameInContext( _
                        translation, sourceToken, outputNames(), outputNameCount)
                    If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                        ReportError("generic header exceeds the configured token macro limit")
                    If outputNameCount > UBound(outputNames) Then _
                        ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
                    outputNames(outputNameCount) = .freeBasicName
                    outputNameCount += 1
                End With
            Next
        End With
    Next
End Sub

Private Sub ValidateGenericHeaderTokenFunctionMacros( _
    ByRef translation As C2fbTranslationContext _
)
    For macroIndex As Long = 0 To _
        translation.genericC.header.headerMacroCount - 1
        With translation.genericC.header.headerMacros(macroIndex)
            If .active = 0 OrElse .privateName <> 0 OrElse _
               .definition.functionLike = 0 OrElse .emitted <> 0 OrElse _
               GenericDefineExcludedInPolicy( _
                translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
               GenericMacroTokenConversionForcedInPolicy( _
                translation.genericC.policy, .definition.sourceName, 0) = 0 Then _
                Continue For

            Dim parameterNames() As String
            Dim freeParameterNames() As String
            Dim parameterCount As Long
            Dim isVariadic As Long
            Dim body As String
            If ParseGenericFunctionMacro( _
                .definition, parameterNames(), freeParameterNames(), _
                parameterCount, isVariadic, body) = 0 Then
                .tokenConversionFailed = -1
                Continue For
            End If

            Dim macroDefinition As String = .definition.sourceName & .sourceRawValue
            Dim replacementText As String
            Dim replacementToFreeBasic As Long
            Dim hasReplacement As Long = C2fbReplacementRuleMatch( _
                translation.genericC.policy, macroDefinition, replacementText, _
                replacementToFreeBasic)
            If hasReplacement <> 0 AndAlso replacementToFreeBasic <> 0 Then _
                Continue For
            If hasReplacement <> 0 Then body = Trim(replacementText)
            Dim freeBasicBody As String
            If TranslateGenericMacroTokenSequence( _
                translation, body, parameterNames(), freeParameterNames(), _
                parameterCount, isVariadic, freeBasicBody) = 0 Then _
                .tokenConversionFailed = -1
        End With
    Next
End Sub

Private Sub WriteGenericHeaderTokenConvertedObjectMacros( _
    ByRef translation As C2fbTranslationContext, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    Dim noParameterNames(0 To 0) As String
    For macroIndex As Long = 0 To _
        translation.genericC.header.headerMacroCount - 1
        With translation.genericC.header.headerMacros(macroIndex)
            If .active = 0 OrElse .privateName <> 0 OrElse _
               GenericDefineExcludedInPolicy( _
                translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
               .definition.functionLike <> 0 OrElse .emitted <> 0 OrElse _
               .tokenConversionFailed <> 0 Then Continue For
            If GenericMacroTokenConversionForcedInPolicy( _
                translation.genericC.policy, .definition.sourceName) = 0 Then _
                Continue For

            Dim freeBasicBody As String
            If TranslateGenericMacroTokenSequence( _
                translation, .definition.rawValue, noParameterNames(), _
                noParameterNames(), 0, 0, freeBasicBody) = 0 Then
                .tokenConversionFailed = -1
                Continue For
            End If

            Dim macroBinding As C2fbMacroBindingModel
            macroBinding.name = .freeBasicName
            macroBinding.bodyText = freeBasicBody
            WriteGenericMacroBindingWithGuardsInPolicy( _
                translation.genericC.policy, outputFile, _
                .definition.sourceName, macroBinding)
            .emitted = -1
            conversionSummary.genericHeader.tokenMacroConversionCount += 1
        End With
    Next
End Sub

Private Sub WriteGenericHeaderTypeMacros( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, outputNames() As String, _
    ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    For passIndex As Long = 0 To translation.genericC.header.headerMacroCount - 1
        Dim madeProgress As Long = 0
        For macroIndex As Long = 0 To translation.genericC.header.headerMacroCount - 1
            With translation.genericC.header.headerMacros(macroIndex)
                If .active = 0 OrElse GenericDefineExcludedInPolicy(translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
                   .definition.functionLike <> 0 OrElse .definition.continued <> 0 OrElse _
                   .emitted <> 0 Then Continue For
                Dim freeBasicType As String = GenericTypeOverrideInPolicy(translation.genericC.policy, .definition.sourceName)
                If freeBasicType = "" Then
                    If GenericTypeMacroValue( _
                        translation, catalog, _
                        translation.genericC.header.headerMacros(macroIndex).definition, _
                        freeBasicType) = 0 Then Continue For
                End If
                freeBasicType = ApplyGenericStringOverrideInGenericC(translation.genericC, .definition.sourceName, freeBasicType)
                If .privateName <> 0 Then
                If GenericTypeOverrideInPolicy(translation.genericC.policy, .definition.sourceName) = "" Then _
                    AddGenericTypeOverrideInPolicy( _
                        translation.genericC.policy, .definition.sourceName, freeBasicType)
                    .emitted = -1
                    madeProgress = -1
                    Continue For
                End If
                If GenericMacroTokenConversionForcedInPolicy( _
                    translation.genericC.policy, .definition.sourceName, 0) <> 0 Then _
                    Continue For
                If GenericHeaderSymbolIndexInContext(translation, .definition.sourceName) >= 0 OrElse _
                   GenericHeaderTypeAliasIndexInHeader(translation.genericC.header, .definition.sourceName, 0) >= 0 Then
                    EmitC2fbSkippedAtLocation( _
                        translation, outputFile, conversionSummary, _
                        "ambiguous type macro", .definition.sourceName, _
                        .definition.sourceLocation)
                    .emitted = -1
                    madeProgress = -1
                    Continue For
                End If
                If .freeBasicName = "" Then
                    .freeBasicName = GenericFreeBasicMacroNameInContext(translation,  _
                        .definition.sourceName, outputNames(), outputNameCount)
                    If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                        ReportError("generic header exceeds the configured type macro limit")
                    If outputNameCount > UBound(outputNames) Then _
                        ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
                    outputNames(outputNameCount) = .freeBasicName
                    outputNameCount += 1
                End If
                Dim functionAlias As Long = 0
                For tokenIndex As Long = 0 To .definition.tokenCount - 1
                    Dim targetAliasIndex As Long = _
                        GenericHeaderTypeAliasIndexInHeader( _
                            translation.genericC.header, .definition.tokens(tokenIndex), 0)
                    If targetAliasIndex >= 0 AndAlso _
                       translation.genericC.header.headerTypeAliases(targetAliasIndex).isFunction <> 0 Then _
                        functionAlias = -1
                Next
                WriteGenericTypeAliasByNameWithGuardsInPolicy( _
                    translation.genericC.policy, outputFile, .definition.sourceName, _
                    .freeBasicName, freeBasicType)
                RecordGenericHeaderTypeAliasInHeader(translation.genericC.header,  _
                    .definition.sourceName, .freeBasicName, freeBasicType, -1, 0, 0, 0, "", functionAlias)
                .emitted = -1
                    conversionSummary.genericHeader.typeMacroCount += 1
                madeProgress = -1
            End With
        Next
        If madeProgress = 0 Then Exit For
    Next
    If conversionSummary.genericHeader.typeMacroCount > 0 Then _
        WriteC2fbOutputLine(outputFile, "")
End Sub

Private Sub WriteGenericHeaderAliasMacros( _
    ByRef translation As C2fbTranslationContext, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, outputNames() As String, _
    ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    For passIndex As Long = 0 To translation.genericC.header.headerMacroCount - 1
        Dim madeProgress As Long = 0
        For macroIndex As Long = 0 To translation.genericC.header.headerMacroCount - 1
            With translation.genericC.header.headerMacros(macroIndex)
                If .active = 0 OrElse GenericDefineExcludedInPolicy(translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
                   .definition.functionLike <> 0 OrElse .definition.continued <> 0 OrElse _
                   .privateName <> 0 OrElse .emitted <> 0 OrElse _
                   .freeBasicName = "" OrElse _
                   GenericMacroTokenConversionForcedInPolicy( _
                    translation.genericC.policy, .definition.sourceName, 0) <> 0 Then Continue For
                Dim targetName As String = GenericHeaderAliasMacroName( _
                    translation.genericC.header.headerMacros(macroIndex).definition)
                If targetName = "" Then Continue For
                If targetName = .definition.sourceName Then
                    ' Exact self-aliases have no binding effect in FreeBASIC.
                    .emitted = -1
                    madeProgress = -1
                    Continue For
                End If
                Dim targetMacroIndex As Long = GenericHeaderMacroIndexInContext( _
                    translation, targetName)
                If targetMacroIndex >= 0 AndAlso _
                   translation.genericC.header.headerMacros(targetMacroIndex).active <> 0 AndAlso _
                   translation.genericC.header.headerMacros(targetMacroIndex).privateName = 0 AndAlso _
                   translation.genericC.header.headerMacros(targetMacroIndex).definition.functionLike <> 0 AndAlso _
                   GenericDefineExcludedInPolicy( _
                    translation.genericC.policy, targetName) = 0 Then
                    With translation.genericC.header.headerMacros(targetMacroIndex)
                        If .freeBasicName = "" Then
                            .freeBasicName = GenericFreeBasicMacroNameInContext( _
                                translation, targetName, outputNames(), outputNameCount)
                            If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                                ReportError("generic header exceeds the configured alias macro limit")
                            If outputNameCount > UBound(outputNames) Then _
                                ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
                            outputNames(outputNameCount) = .freeBasicName
                            outputNameCount += 1
                        End If
                    End With
                    If .freeBasicName = "" Then
                        .freeBasicName = GenericFreeBasicMacroNameInContext( _
                            translation, .definition.sourceName, _
                            outputNames(), outputNameCount)
                        If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                            ReportError("generic header exceeds the configured alias macro limit")
                        If outputNameCount > UBound(outputNames) Then _
                            ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
                        outputNames(outputNameCount) = .freeBasicName
                        outputNameCount += 1
                    End If
                    Dim functionMacroAlias As C2fbMacroBindingModel
                    functionMacroAlias.name = .freeBasicName
                    functionMacroAlias.bodyText = _
                        translation.genericC.header.headerMacros( _
                            targetMacroIndex).freeBasicName
                    WriteGenericMacroBindingWithGuardsInPolicy( _
                        translation.genericC.policy, outputFile, _
                        .definition.sourceName, functionMacroAlias)
                    .emitted = -1
                    conversionSummary.genericHeader.aliasMacroCount += 1
                    madeProgress = -1
                    Continue For
                End If
                If GenericHeaderSymbolIndexInContext(translation, .definition.sourceName) >= 0 OrElse _
                   GenericHeaderTypeAliasIndexInHeader(translation.genericC.header, .definition.sourceName, 0) >= 0 Then
                    EmitC2fbSkippedAtLocation( _
                        translation, outputFile, conversionSummary, _
                        "ambiguous alias macro", .definition.sourceName, _
                        .definition.sourceLocation)
                    .emitted = -1
                    madeProgress = -1
                    Continue For
                End If

                Dim targetSymbolIndex As Long = GenericHeaderSymbolIndexInContext(translation, targetName)
                Dim targetTypeIndex As Long = GenericHeaderTypeAliasIndexInHeader(translation.genericC.header, targetName, 0)
                If targetTypeIndex < 0 Then
                    targetTypeIndex = GenericHeaderTypeAliasIndexInHeader(translation.genericC.header, targetName, -1)
                End If
                Dim mappedType As String
                If targetSymbolIndex < 0 AndAlso targetTypeIndex < 0 Then _
                    mappedType = GenericTypeOverrideInPolicy(translation.genericC.policy, targetName)

                If targetSymbolIndex < 0 AndAlso targetTypeIndex < 0 AndAlso mappedType = "" Then
                    If targetMacroIndex >= 0 AndAlso _
                       translation.genericC.header.headerMacros(targetMacroIndex).active <> 0 AndAlso _
                       translation.genericC.header.headerMacros(targetMacroIndex).emitted = 0 Then Continue For
                    Continue For
                End If

                If targetMacroIndex >= 0 AndAlso targetSymbolIndex < 0 AndAlso _
                   targetTypeIndex < 0 AndAlso translation.genericC.header.headerMacros(targetMacroIndex).isString = 0 Then
                    ' Integer macro aliases were already emitted as Const values.
                    Continue For
                End If

                If targetSymbolIndex >= 0 Then
                    With translation.symbolTable.symbols(targetSymbolIndex)
                        Dim aliasName As String = translation.genericC.header.headerMacros(macroIndex).definition.sourceName
                        Dim aliasReturnType As String = _
                            ApplyGenericStringOverrideInGenericC( _
                                translation.genericC, aliasName, .genericHeader.returnType)
                        Dim aliasParameters As String = _
                            ApplyGenericStringOverrideInGenericC( _
                                translation.genericC, aliasName, .genericHeader.parameterList)
                        Dim aliasObjectType As String = _
                            ApplyGenericStringOverrideInGenericC( _
                                translation.genericC, aliasName, .genericHeader.freeBasicType)
                        Dim procedureBinding As C2fbProcedureBindingModel
                        Dim objectBinding As C2fbObjectBindingModel
                        Select Case .kind
                        Case GENERIC_SYMBOL_FUNCTION, GENERIC_SYMBOL_SUB
                            procedureBinding.freeBasicName = _
                                translation.genericC.header.headerMacros(macroIndex).freeBasicName
                            procedureBinding.cName = .cName
                            procedureBinding.returnType = aliasReturnType
                            procedureBinding.parameterList = aliasParameters
                            procedureBinding.callingConvention = .genericHeader.callingConvention
                            procedureBinding.isSub = CInt(.kind = GENERIC_SYMBOL_SUB) * -1
                            WriteGenericProcedureBindingWithGuardsInPolicy( _
                                translation.genericC.policy, outputFile, aliasName, _
                                procedureBinding)
                        Case GENERIC_SYMBOL_OBJECT
                            objectBinding.freeBasicName = _
                                translation.genericC.header.headerMacros(macroIndex).freeBasicName
                            objectBinding.cName = .cName
                            objectBinding.freeBasicType = aliasObjectType
                            objectBinding.arrayCount = .genericHeader.arrayCount
                            objectBinding.isUnsizedArray = .genericHeader.unsizedArray
                            If .genericHeader.unsizedArray <> 0 Then _
                                objectBinding.aliasAccessorTarget = .freeBasicName
                            WriteGenericObjectBindingWithGuardsInPolicy( _
                                translation.genericC.policy, outputFile, aliasName, objectBinding)
                        Case Else
                            Continue For
                        End Select
                        If .kind = GENERIC_SYMBOL_FUNCTION OrElse .kind = GENERIC_SYMBOL_SUB Then
                            RecordGenericHeaderProcedureInContext(translation,  _
                                translation.genericC.header.headerMacros(macroIndex).definition.sourceName, _
                                procedureBinding)
                        ElseIf .kind = GENERIC_SYMBOL_OBJECT Then
                            RecordGenericHeaderObjectInContext(translation,  _
                                translation.genericC.header.headerMacros(macroIndex).definition.sourceName, _
                                objectBinding)
                        Else
                            RecordGenericHeaderSymbolInContext(translation,  _
                                translation.genericC.header.headerMacros(macroIndex).definition.sourceName, _
                                translation.genericC.header.headerMacros(macroIndex).freeBasicName, .cName, .kind, _
                                aliasObjectType, aliasReturnType, aliasParameters, _
                                .genericHeader.callingConvention, _
                                .genericHeader.arrayCount, .genericHeader.unsizedArray)
                        End If
                    End With
                ElseIf targetTypeIndex >= 0 Then
                    If translation.genericC.header.headerTypeAliases(targetTypeIndex).isArray <> 0 Then
                        RecordGenericHeaderTypeAliasInHeader(translation.genericC.header,  _
                            translation.genericC.header.headerMacros(macroIndex).definition.sourceName, _
                            translation.genericC.header.headerMacros(macroIndex).freeBasicName, "", -1, 0, -1, _
                            translation.genericC.header.headerTypeAliases(targetTypeIndex).arrayCount, _
                            translation.genericC.header.headerTypeAliases(targetTypeIndex).arrayElementType)
                        WriteC2fbOutputLine( _
                            outputFile, "' c2fb expands array typedef alias macro at each use: " & _
                            translation.genericC.header.headerMacros(macroIndex).definition.sourceName)
                    Else
                        Dim aliasType As String = ApplyGenericStringOverrideInGenericC(translation.genericC,  _
                            translation.genericC.header.headerMacros(macroIndex).definition.sourceName, _
                            translation.genericC.header.headerTypeAliases(targetTypeIndex).freeBasicName)
                        WriteGenericTypeAliasByNameWithGuardsInPolicy( _
                            translation.genericC.policy, outputFile, _
                            translation.genericC.header.headerMacros(macroIndex).definition.sourceName, _
                            translation.genericC.header.headerMacros(macroIndex).freeBasicName, _
                            aliasType)
                        RecordGenericHeaderTypeAliasInHeader(translation.genericC.header,  _
                            translation.genericC.header.headerMacros(macroIndex).definition.sourceName, _
                            translation.genericC.header.headerMacros(macroIndex).freeBasicName, _
                            aliasType, -1, 0, 0, 0, "", _
                            translation.genericC.header.headerTypeAliases(targetTypeIndex).isFunction)
                    End If
                Else
                    mappedType = ApplyGenericStringOverrideInGenericC(translation.genericC,  _
                        translation.genericC.header.headerMacros(macroIndex).definition.sourceName, mappedType)
                    WriteGenericTypeAliasByNameWithGuardsInPolicy( _
                        translation.genericC.policy, outputFile, _
                        translation.genericC.header.headerMacros(macroIndex).definition.sourceName, _
                        translation.genericC.header.headerMacros(macroIndex).freeBasicName, _
                        mappedType)
                    RecordGenericHeaderTypeAliasInHeader(translation.genericC.header,  _
                        translation.genericC.header.headerMacros(macroIndex).definition.sourceName, _
                        translation.genericC.header.headerMacros(macroIndex).freeBasicName, mappedType, -1)
                End If

                translation.genericC.header.headerMacros(macroIndex).emitted = -1
                conversionSummary.genericHeader.aliasMacroCount += 1
                madeProgress = -1
            End With
        Next
        If madeProgress = 0 Then Exit For
    Next
    If conversionSummary.genericHeader.aliasMacroCount > 0 Then _
        WriteC2fbOutputLine(outputFile, "")
End Sub

Private Function GenericFunctionMacroUsesParameter( _
    ByVal sourceBody As String, parameterNames() As String, _
    ByVal parameterCount As Long, ByVal isVariadic As Long _
) As Long
    Dim tokens() As String
    Dim tokenCount As Long = 0
    If TokenizeCPreprocessorReplacement( _
        sourceBody, tokens(), tokenCount) = 0 Then Return -1
    For tokenIndex As Long = 0 To tokenCount - 1
        If IsIdentifierToken(tokens(tokenIndex)) = 0 Then Continue For
        If isVariadic <> 0 AndAlso tokens(tokenIndex) = "__VA_ARGS__" Then _
            Return -1
        For parameterIndex As Long = 0 To parameterCount - 1
            If tokens(tokenIndex) = parameterNames(parameterIndex) Then Return -1
        Next
    Next
    Return 0
End Function

Private Function GenericFunctionMacroStringizingConcatCandidate( _
    ByVal sourceBody As String, parameterNames() As String, _
    ByVal parameterCount As Long, ByVal isVariadic As Long _
) As Long
    Dim tokens() As String
    Dim tokenCount As Long = 0
    If TokenizeCPreprocessorReplacement( _
        sourceBody, tokens(), tokenCount) = 0 OrElse tokenCount < 3 Then Return 0
    Dim hasLiteral As Long = 0
    Dim hasStringizedParameter As Long = 0
    Dim tokenIndex As Long = 0
    While tokenIndex < tokenCount
        Dim sourceToken As String = tokens(tokenIndex)
        Dim isStringLiteral As Long = 0
        If Left(sourceToken, 1) = Chr(34) Then
            isStringLiteral = -1
        ElseIf Len(sourceToken) > 1 AndAlso _
               (Left(sourceToken, 1) = "L" OrElse Left(sourceToken, 1) = "u" OrElse _
                Left(sourceToken, 1) = "U") AndAlso _
               Mid(sourceToken, 2, 1) = Chr(34) Then
            isStringLiteral = -1
        ElseIf Len(sourceToken) > 2 AndAlso Left(sourceToken, 2) = "u8" AndAlso _
               Mid(sourceToken, 3, 1) = Chr(34) Then
            isStringLiteral = -1
        End If
        If isStringLiteral <> 0 Then
            hasLiteral = -1
            tokenIndex += 1
        ElseIf sourceToken = "#" AndAlso tokenIndex + 1 < tokenCount Then
            Dim parameterName As String = tokens(tokenIndex + 1)
            If IsIdentifierToken(parameterName) = 0 Then Return 0
            Dim parameterMatched As Long = 0
            If isVariadic <> 0 AndAlso parameterName = "__VA_ARGS__" Then _
                parameterMatched = -1
            For parameterIndex As Long = 0 To parameterCount - 1
                If parameterNames(parameterIndex) = parameterName Then _
                    parameterMatched = -1
            Next
            If parameterMatched = 0 Then Return 0
            hasStringizedParameter = -1
            tokenIndex += 2
        Else
            Return 0
        End If
    Wend
    Return CInt(hasLiteral <> 0 AndAlso hasStringizedParameter <> 0)
End Function

Private Sub WriteGenericHeaderFunctionMacros( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, outputNames() As String, _
    ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    For macroIndex As Long = 0 To translation.genericC.header.headerMacroCount - 1
        With translation.genericC.header.headerMacros(macroIndex)
            If .active = 0 OrElse GenericDefineExcludedInPolicy(translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
               .definition.functionLike = 0 OrElse _
               .privateName <> 0 OrElse .emitted <> 0 Then Continue For
            Dim tokenConversionRequested As Long = _
                GenericMacroTokenConversionForcedInPolicy( _
                    translation.genericC.policy, .definition.sourceName)
            If tokenConversionRequested <> 0 AndAlso _
               .tokenConversionFailed <> 0 Then Continue For
            If .definition.continued <> 0 AndAlso tokenConversionRequested = 0 Then _
                Continue For

            Dim parameterNames() As String
            Dim freeParameterNames() As String
            Dim parameterCount As Long
            Dim isVariadic As Long
            Dim body As String
            If ParseGenericFunctionMacro( _
                .definition, _
                parameterNames(), freeParameterNames(), _
                parameterCount, isVariadic, body) = 0 Then
                If tokenConversionRequested <> 0 Then .tokenConversionFailed = -1
                Continue For
            End If
            ApplyGenericMacroParameterRenamesInPolicy( _
                translation.genericC.policy, parameterNames(), _
                freeParameterNames(), parameterCount, body)
            Dim sourceBodyHasOuterParentheses As Long = CInt( _
                GenericMacroStripOuterParentheses(body) <> Trim(body))

            Dim macroDefinition As String = .definition.sourceName & .sourceRawValue
            Dim replacementText As String
            Dim replacementToFreeBasic As Long
            Dim hasReplacement As Long = C2fbReplacementRuleMatch( _
                translation.genericC.policy, macroDefinition, replacementText, _
                replacementToFreeBasic)
            Dim hasFreeBasicReplacement As Long = 0
            Dim isMultiLineFreeBasicReplacement As Long = 0
            Dim freeBasicExpression As String
            Dim integerDivisionAssumed As Long = 0
            Dim usedIntegerDivisionAssumption As Long = 0
            Dim nullaryStringMacro As Long = 0
            Dim stringizingConcatMacro As Long = 0
            Dim directIdentifierMacro As Long = 0
            Dim isStatementBlockMacro As Long = 0
            If tokenConversionRequested = 0 AndAlso isVariadic = 0 AndAlso _
               (hasReplacement = 0 OrElse replacementToFreeBasic = 0) Then
                Dim stringMacroBody As String = body
                If hasReplacement <> 0 Then stringMacroBody = Trim(replacementText)
                If GenericFunctionMacroUsesParameter( _
                    stringMacroBody, parameterNames(), parameterCount, isVariadic) = 0 AndAlso _
                   TranslateGenericHeaderStringMacro( _
                    stringMacroBody, freeBasicExpression) <> 0 Then
                    body = stringMacroBody
                    nullaryStringMacro = -1
                End If
            End If
            If nullaryStringMacro = 0 AndAlso tokenConversionRequested = 0 AndAlso _
               (hasReplacement = 0 OrElse replacementToFreeBasic = 0) Then
                Dim stringizingBody As String = body
                If hasReplacement <> 0 Then stringizingBody = Trim(replacementText)
                If GenericFunctionMacroStringizingConcatCandidate( _
                    stringizingBody, parameterNames(), parameterCount, _
                    isVariadic) <> 0 AndAlso _
                   TranslateGenericMacroTokenSequence( _
                    translation, stringizingBody, parameterNames(), _
                    freeParameterNames(), parameterCount, isVariadic, _
                    freeBasicExpression) <> 0 Then
                    body = stringizingBody
                    stringizingConcatMacro = -1
                End If
            End If
            If nullaryStringMacro = 0 AndAlso stringizingConcatMacro = 0 AndAlso _
               tokenConversionRequested = 0 AndAlso isVariadic = 0 AndAlso _
               (hasReplacement = 0 OrElse replacementToFreeBasic = 0) AndAlso _
               IsIdentifierToken(body) <> 0 AndAlso _
               GenericFunctionMacroUsesParameter( _
                   body, parameterNames(), parameterCount, isVariadic) = 0 Then
                ' Keep caller-owned identifier tokens available to a later binding.
                freeBasicExpression = body
                directIdentifierMacro = -1
            End If
            If nullaryStringMacro = 0 AndAlso stringizingConcatMacro = 0 AndAlso _
               directIdentifierMacro = 0 Then
                If tokenConversionRequested <> 0 AndAlso _
                   (hasReplacement = 0 OrElse replacementToFreeBasic = 0) Then
                    If hasReplacement <> 0 Then body = Trim(replacementText)
                    If TranslateGenericMacroTokenSequence( _
                        translation, body, parameterNames(), freeParameterNames(), _
                        parameterCount, isVariadic, freeBasicExpression) = 0 Then
                        .tokenConversionFailed = -1
                        Continue For
                    End If
                ElseIf tokenConversionRequested <> 0 Then
                    freeBasicExpression = RewriteGenericBodyLocalNames( _
                        replacementText, parameterNames(), freeParameterNames(), parameterCount)
                    hasFreeBasicReplacement = -1
                    isMultiLineFreeBasicReplacement = CInt( _
                        InStr(replacementText, Chr(10)) <> 0 OrElse _
                        InStr(replacementText, Chr(13)) <> 0)
                ElseIf hasReplacement <> 0 AndAlso replacementToFreeBasic <> 0 Then
                    freeBasicExpression = RewriteGenericBodyLocalNames( _
                        replacementText, parameterNames(), freeParameterNames(), parameterCount)
                    hasFreeBasicReplacement = -1
                    isMultiLineFreeBasicReplacement = CInt( _
                        InStr(replacementText, Chr(10)) <> 0 OrElse _
                        InStr(replacementText, Chr(13)) <> 0)
            Else
                If hasReplacement <> 0 Then body = Trim(replacementText)
                Dim conditionalCallBody As String
                Dim conditionalCallStatus As Long = _
                    TranslateGenericConditionalCallMacro( _
                        translation, body, parameterNames(), freeParameterNames(), _
                        parameterCount, isVariadic, conditionalCallBody)
                If conditionalCallStatus > 0 Then
                    freeBasicExpression = conditionalCallBody
                    isStatementBlockMacro = -1
                ElseIf conditionalCallStatus < 0 Then
                    Continue For
                Else
                    Dim initializerBody As String
                    Dim initializerStatus As Long = _
                        TranslateGenericBraceInitializerMacro( _
                            translation, body, parameterNames(), freeParameterNames(), _
                            parameterCount, isVariadic, initializerBody)
                    If initializerStatus > 0 Then
                        freeBasicExpression = initializerBody
                    ElseIf initializerStatus < 0 Then
                        Continue For
                    Else
                        Dim statementIntegerDivisionAssumed As Long = 0
                        If InStr(body, "/=") <> 0 Then _
                            statementIntegerDivisionAssumed = _
                                GenericIntegerMacroAssumedInPolicy( _
                                    translation.genericC.policy, .definition.sourceName)
                        Dim statementBlockBody As String
                        Dim statementBlockStatus As Long = _
                            TranslateGenericStatementMacroBlock( _
                                translation, catalog, body, parameterNames(), freeParameterNames(), _
                                parameterCount, isVariadic, statementBlockBody, _
                                translation.genericC.policy.dropMacroBodyScopes, _
                                statementIntegerDivisionAssumed, .definition.sourceName, _
                                CInt(.definition.functionLike <> 0) * -1)
                        If statementBlockStatus > 0 Then
                            freeBasicExpression = statementBlockBody
                            isStatementBlockMacro = -1
                            If statementIntegerDivisionAssumed <> 0 AndAlso _
                               InStr(statementBlockBody, "\=") <> 0 Then _
                                GenericIntegerMacroAssumedInPolicy( _
                                    translation.genericC.policy, .definition.sourceName, -1)
                        ElseIf statementBlockStatus < 0 Then
                            Continue For
                        Else
                            Dim unwrappedCallBody As String
                            If StripGenericSingleCallMacroWrapper( _
                                body, unwrappedCallBody) <> 0 Then _
                                body = unwrappedCallBody
                            If GenericMacroExpressionContainsDivision(body) <> 0 Then _
                                integerDivisionAssumed = _
                                    GenericIntegerMacroAssumedInPolicy( _
                                        translation.genericC.policy, .definition.sourceName)
                            Dim dynamicIntegerDivision As Long = 0
                            If integerDivisionAssumed = 0 AndAlso _
                               GenericMacroExpressionContainsDivision(body) <> 0 Then _
                                dynamicIntegerDivision = _
                                    GenericMacroDivisionDynamicInPolicy( _
                                        translation.genericC.policy, _
                                        .definition.sourceName)
                            If integerDivisionAssumed <> 0 Then
                                If GenericFunctionMacroBodySupported( _
                                    body, isVariadic, -1) = 0 Then Continue For
                                If TranslateGenericHeaderMacroExpressionWithParameters( _
                                    translation, body, freeBasicExpression, parameterNames(), _
                                    freeParameterNames(), parameterCount, _
                                    integerDivisionAssumed) = 0 Then Continue For
                                usedIntegerDivisionAssumption = -1
                            ElseIf TranslateGenericFunctionCallMacro( _
                                translation, body, parameterNames(), freeParameterNames(), parameterCount, _
                                isVariadic, freeBasicExpression) = 0 AndAlso _
                               TranslateGenericDirectCallMacroTokens( _
                                translation, body, parameterNames(), freeParameterNames(), _
                                parameterCount, isVariadic, freeBasicExpression) = 0 AndAlso _
                               TranslateGenericStringizingMacro( _
                                body, parameterNames(), freeParameterNames(), parameterCount, _
                                isVariadic, freeBasicExpression) = 0 AndAlso _
                               TranslateGenericTokenPasteMacro( _
                                    translation, body, parameterNames(), _
                                    freeParameterNames(), parameterCount, _
                                    freeBasicExpression) = 0 Then
                                If TranslateGenericHeaderMacroExpressionWithParameters( _
                                    translation, body, freeBasicExpression, parameterNames(), _
                                    freeParameterNames(), parameterCount, _
                                    integerDivisionAssumed, 0, _
                                    dynamicIntegerDivision) = 0 Then
                                    If dynamicIntegerDivision <> 0 Then Continue For
                                    If GenericMacroExpressionTokenSequenceSupported( _
                                        translation, body, parameterNames(), _
                                        freeParameterNames(), parameterCount, _
                                        isVariadic) = 0 OrElse _
                                       TranslateGenericMacroTokenSequence( _
                                        translation, body, parameterNames(), _
                                        freeParameterNames(), parameterCount, _
                                        isVariadic, freeBasicExpression) = 0 Then _
                                        Continue For
                                End If
                            End If
                            If dynamicIntegerDivision <> 0 Then _
                                GenericMacroDivisionDynamicInPolicy( _
                                    translation.genericC.policy, _
                                    .definition.sourceName, -1)
                        End If
                    End If
                End If
            End If
            End If

            If isStatementBlockMacro = 0 AndAlso _
               hasFreeBasicReplacement = 0 AndAlso _
               sourceBodyHasOuterParentheses <> 0 Then _
                freeBasicExpression = "(" & freeBasicExpression & ")"

            Dim freeBasicName As String = .freeBasicName
            If freeBasicName = "" Then
                freeBasicName = GenericFreeBasicMacroNameInContext(translation,  _
                    .definition.sourceName, outputNames(), outputNameCount)
                If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                    ReportError("generic header exceeds the configured function macro limit")
                If outputNameCount > UBound(outputNames) Then _
                    ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
                outputNames(outputNameCount) = freeBasicName
                outputNameCount += 1
            End If

            Dim freeBasicParameters As String
            For parameterIndex As Long = 0 To parameterCount - 1
                If parameterIndex > 0 Then freeBasicParameters &= ", "
                freeBasicParameters &= freeParameterNames(parameterIndex)
                If isVariadic <> 0 AndAlso parameterIndex = parameterCount - 1 Then _
                    freeBasicParameters &= "..."
            Next
            Dim macroBinding As C2fbMacroBindingModel
            macroBinding.name = freeBasicName
            macroBinding.parameters = freeBasicParameters
            macroBinding.bodyText = freeBasicExpression
            macroBinding.isFunctionLike = -1
            macroBinding.isBlock = isStatementBlockMacro
            If isStatementBlockMacro <> 0 Then
                macroBinding.bodyText = IndentC2fbReplacement( _
                    freeBasicExpression, "    ")
            End If
            If hasFreeBasicReplacement <> 0 AndAlso _
               isMultiLineFreeBasicReplacement <> 0 Then
                macroBinding.bodyText = IndentC2fbReplacement( _
                    freeBasicExpression, "    ")
                macroBinding.isBlock = -1
            End If
            WriteGenericMacroBindingWithGuardsInPolicy( _
                translation.genericC.policy, outputFile, .definition.sourceName, _
                macroBinding)
            If usedIntegerDivisionAssumption <> 0 Then _
                GenericIntegerMacroAssumedInPolicy( _
                    translation.genericC.policy, .definition.sourceName, -1)
            .freeBasicName = freeBasicName
            .emitted = -1
            conversionSummary.genericHeader.functionMacroCount += 1
            If tokenConversionRequested <> 0 AndAlso _
               (hasReplacement = 0 OrElse replacementToFreeBasic = 0) Then _
                conversionSummary.genericHeader.tokenMacroConversionCount += 1
            If hasReplacement <> 0 Then _
                conversionSummary.genericHeader.customMacroReplacementCount += 1
        End With
    Next
    If conversionSummary.genericHeader.functionMacroCount > 0 Then _
        WriteC2fbOutputLine(outputFile, "")
End Sub

Private Sub WriteGenericHeaderObjectCallMacros( _
    ByRef translation As C2fbTranslationContext, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, outputNames() As String, _
    ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    Dim noParameterNames(0 To 0) As String
    For macroIndex As Long = 0 To _
        translation.genericC.header.headerMacroCount - 1
        With translation.genericC.header.headerMacros(macroIndex)
            If .active = 0 OrElse .privateName <> 0 OrElse .emitted <> 0 OrElse _
               .definition.functionLike <> 0 OrElse .definition.continued <> 0 OrElse _
               GenericDefineExcludedInPolicy( _
                translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
               GenericMacroTokenConversionForcedInPolicy( _
                translation.genericC.policy, .definition.sourceName, 0) <> 0 Then _
                Continue For

            Dim freeBasicBody As String
            If TranslateGenericDirectCallMacroTokens( _
                translation, .definition.rawValue, noParameterNames(), _
                noParameterNames(), 0, 0, freeBasicBody) = 0 Then Continue For

            Dim freeBasicName As String = .freeBasicName
            If freeBasicName = "" Then _
                freeBasicName = GenericFreeBasicMacroNameInContext( _
                    translation, .definition.sourceName, outputNames(), outputNameCount)
            If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                ReportError("generic header exceeds the configured object-call macro limit")
            If outputNameCount > UBound(outputNames) Then _
                ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
            outputNames(outputNameCount) = freeBasicName
            outputNameCount += 1

            Dim macroBinding As C2fbMacroBindingModel
            macroBinding.name = freeBasicName
            macroBinding.bodyText = freeBasicBody
            WriteGenericMacroBindingWithGuardsInPolicy( _
                translation.genericC.policy, outputFile, _
                .definition.sourceName, macroBinding)
            .freeBasicName = freeBasicName
            .emitted = -1
            conversionSummary.genericHeader.callMacroCount += 1
        End With
    Next
    If conversionSummary.genericHeader.callMacroCount > 0 Then _
        WriteC2fbOutputLine(outputFile, "")
End Sub

Private Function GenericObjectMacroTokenSequenceBody( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceBody As String, ByRef normalizedBody As String _
) As Long
    normalizedBody = sourceBody
    Dim tokens() As String
    Dim tokenCount As Long = 0
    If TokenizeCPreprocessorReplacement( _
        sourceBody, tokens(), tokenCount) = 0 OrElse tokenCount < 2 Then Return 0
    Dim hasIdentifier As Long = 0
    Dim pasteIndex As Long = -1
    For tokenIndex As Long = 0 To tokenCount - 1
        Dim sourceToken As String = tokens(tokenIndex)
        If IsIdentifierToken(sourceToken) <> 0 Then
            hasIdentifier = -1
        ElseIf sourceToken = "##" Then
            If pasteIndex >= 0 OrElse tokenIndex = 0 OrElse _
               tokenIndex >= tokenCount - 1 Then Return 0
            Dim leftToken As String = tokens(tokenIndex - 1)
            Dim rightToken As String = tokens(tokenIndex + 1)
            If IsIdentifierToken(leftToken) = 0 OrElse _
               IsIdentifierToken(rightToken) = 0 Then Return 0
            pasteIndex = tokenIndex
            If GenericHeaderSymbolIndexInContext(translation, leftToken) >= 0 OrElse _
               GenericHeaderSymbolIndexInContext(translation, rightToken) >= 0 OrElse _
               GenericHeaderMacroIndexInContext(translation, leftToken) >= 0 OrElse _
               GenericHeaderMacroIndexInContext(translation, rightToken) >= 0 OrElse _
               GenericEnumMemberIndexInContext(translation, leftToken) >= 0 OrElse _
               GenericEnumMemberIndexInContext(translation, rightToken) >= 0 OrElse _
               GenericSymbolRenameInPolicy( _
                   translation.genericC.policy, leftToken) <> "" OrElse _
               GenericSymbolRenameInPolicy( _
                   translation.genericC.policy, rightToken) <> "" Then Return 0
        ElseIf Left(sourceToken, 1) = Chr(34) OrElse _
               (Len(sourceToken) > 1 AndAlso _
                (Left(sourceToken, 1) = "L" OrElse Left(sourceToken, 1) = "u" OrElse _
                 Left(sourceToken, 1) = "U") AndAlso _
                Mid(sourceToken, 2, 1) = Chr(34)) OrElse _
               (Len(sourceToken) > 2 AndAlso Left(sourceToken, 2) = "u8" AndAlso _
                Mid(sourceToken, 3, 1) = Chr(34)) Then
            Continue For
        Else
            Return 0
        End If
    Next
    If hasIdentifier = 0 Then Return 0
    If pasteIndex >= 0 Then
        Dim pastedName As String = tokens(pasteIndex - 1) & tokens(pasteIndex + 1)
        If IsIdentifierToken(pastedName) = 0 OrElse _
           GenericHeaderSymbolIndexInContext(translation, pastedName) >= 0 OrElse _
           GenericHeaderMacroIndexInContext(translation, pastedName) >= 0 OrElse _
           GenericEnumMemberIndexInContext(translation, pastedName) >= 0 OrElse _
           GenericSymbolRenameInPolicy( _
               translation.genericC.policy, pastedName) <> "" Then Return 0
        normalizedBody = ""
        For tokenIndex As Long = 0 To tokenCount - 1
            If tokenIndex = pasteIndex Then Continue For
            If tokenIndex = pasteIndex + 1 Then Continue For
            If normalizedBody <> "" Then normalizedBody &= " "
            If tokenIndex = pasteIndex - 1 Then
                normalizedBody &= pastedName
            Else
                normalizedBody &= tokens(tokenIndex)
            End If
        Next
    End If
    Return -1
End Function

Private Sub WriteGenericHeaderObjectTokenSequenceMacros( _
    ByRef translation As C2fbTranslationContext, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, outputNames() As String, _
    ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    Dim noParameterNames(0 To 0) As String
    For macroIndex As Long = 0 To translation.genericC.header.headerMacroCount - 1
        With translation.genericC.header.headerMacros(macroIndex)
            If .active = 0 OrElse .privateName <> 0 OrElse .emitted <> 0 OrElse _
               .definition.functionLike <> 0 OrElse .definition.continued <> 0 OrElse _
               GenericDefineExcludedInPolicy( _
                translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
               GenericMacroTokenConversionForcedInPolicy( _
                translation.genericC.policy, .definition.sourceName, 0) <> 0 Then _
                Continue For

            Dim tokenSequenceBody As String
            If GenericObjectMacroTokenSequenceBody( _
                translation, .definition.rawValue, tokenSequenceBody) = 0 Then _
                Continue For
            Dim freeBasicBody As String
            If TranslateGenericMacroTokenSequence( _
                translation, tokenSequenceBody, noParameterNames(), _
                noParameterNames(), 0, 0, freeBasicBody) = 0 Then Continue For
            Dim freeBasicName As String = .freeBasicName
            If freeBasicName = "" Then _
                freeBasicName = GenericFreeBasicMacroNameInContext( _
                    translation, .definition.sourceName, outputNames(), outputNameCount)
            If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                ReportError("generic header exceeds the configured token-sequence macro limit")
            If outputNameCount > UBound(outputNames) Then _
                ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
            outputNames(outputNameCount) = freeBasicName
            outputNameCount += 1
            Dim macroBinding As C2fbMacroBindingModel
            macroBinding.name = freeBasicName
            macroBinding.bodyText = freeBasicBody
            WriteGenericMacroBindingWithGuardsInPolicy( _
                translation.genericC.policy, outputFile, _
                .definition.sourceName, macroBinding)
            .freeBasicName = freeBasicName
            .emitted = -1
            conversionSummary.genericHeader.tokenSequenceMacroCount += 1
        End With
    Next
    If conversionSummary.genericHeader.tokenSequenceMacroCount > 0 Then _
        WriteC2fbOutputLine(outputFile, "")
End Sub

Private Function GenericHeaderMacroSummary(ByVal rawValue As String) As String
    Dim summary As String
    For position As Long = 1 To Len(rawValue)
        If Len(summary) >= MAX_GENERIC_MACRO_SUMMARY Then Exit For
        Dim currentByte As Long = Asc(rawValue, position)
        If currentByte = 10 OrElse currentByte = 13 Then
            summary &= " "
        Else
            summary &= Chr(currentByte)
        End If
    Next
    If Len(rawValue) > Len(summary) Then summary &= "..."
    Return Trim(summary)
End Function

Private Function IsGenericEmptyReservedMacro( _
    ByRef macro As C2fbGenericHeaderMacroModel _
) As Long
    If macro.active = 0 OrElse macro.definition.functionLike <> 0 OrElse _
       macro.definition.continued <> 0 OrElse _
       Trim(macro.definition.rawValue) <> "" OrElse _
       Len(macro.definition.sourceName) < 2 OrElse _
       Left(macro.definition.sourceName, 1) <> "_" Then Return 0
    Dim secondByte As Long = Asc(macro.definition.sourceName, 2)
    Return CInt(secondByte = Asc("_") OrElse _
                (secondByte >= Asc("A") AndAlso secondByte <= Asc("Z")))
End Function

Private Sub WriteGenericHeaderEmptyMacros( _
    ByRef translation As C2fbTranslationContext, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, outputNames() As String, _
    ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    For macroIndex As Long = 0 To translation.genericC.header.headerMacroCount - 1
        With translation.genericC.header.headerMacros(macroIndex)
            If .active = 0 OrElse .emitted <> 0 OrElse _
               .definition.continued <> 0 OrElse _
               GenericDefineExcludedInPolicy( _
                translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
               GenericMacroTokenConversionForcedInPolicy( _
                translation.genericC.policy, .definition.sourceName, 0) <> 0 Then _
                Continue For
            Dim freeParameterNames() As String
            Dim parameterNames() As String
            Dim parameterCount As Long = 0
            Dim isVariadic As Long = 0
            Dim emptyBody As String
            If .definition.functionLike <> 0 Then
                If ParseGenericFunctionMacro( _
                    .definition, parameterNames(), freeParameterNames(), _
                    parameterCount, isVariadic, emptyBody) = 0 OrElse _
                   Trim(emptyBody) <> "" Then Continue For
                ApplyGenericMacroParameterRenamesInPolicy( _
                    translation.genericC.policy, parameterNames(), _
                    freeParameterNames(), parameterCount, emptyBody)
            ElseIf Trim(.definition.rawValue) <> "" Then
                Continue For
            End If
            If translation.genericC.policy.removeEmptyReservedDefines <> 0 AndAlso _
               IsGenericEmptyReservedMacro( _
                translation.genericC.header.headerMacros(macroIndex)) <> 0 Then
                .emitted = -1
                Continue For
            End If
            If .privateName <> 0 Then
                .resolvedValue = ""
                .emitted = -1
                Continue For
            End If

            Dim freeBasicName As String = GenericFreeBasicMacroNameInContext( _
                translation, .definition.sourceName, outputNames(), outputNameCount)
            If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                ReportError("generic header exceeds the configured empty macro limit")
            If outputNameCount > UBound(outputNames) Then _
                ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
            outputNames(outputNameCount) = freeBasicName
            outputNameCount += 1

            Dim macroBinding As C2fbMacroBindingModel
            macroBinding.name = freeBasicName
            If .definition.functionLike <> 0 Then
                macroBinding.isFunctionLike = -1
                For parameterIndex As Long = 0 To parameterCount - 1
                    If parameterIndex > 0 Then macroBinding.parameters &= ", "
                    macroBinding.parameters &= freeParameterNames(parameterIndex)
                    If isVariadic <> 0 AndAlso parameterIndex = parameterCount - 1 Then _
                        macroBinding.parameters &= "..."
                Next
            End If
            WriteGenericMacroBindingWithGuardsInPolicy( _
                translation.genericC.policy, outputFile, _
                .definition.sourceName, macroBinding)
            .freeBasicName = freeBasicName
            .emitted = -1
            conversionSummary.genericHeader.emptyMacroCount += 1
        End With
    Next
    If conversionSummary.genericHeader.emptyMacroCount > 0 Then _
        WriteC2fbOutputLine(outputFile, "")
End Sub

Private Sub WriteGenericHeaderObjectMacroReplacements( _
    ByRef translation As C2fbTranslationContext, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, outputNames() As String, _
    ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    For macroIndex As Long = 0 To translation.genericC.header.headerMacroCount - 1
        With translation.genericC.header.headerMacros(macroIndex)
            If .active = 0 OrElse GenericDefineExcludedInPolicy(translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
               .definition.functionLike <> 0 OrElse .definition.continued <> 0 OrElse _
               .privateName <> 0 OrElse .emitted <> 0 Then Continue For

            Dim macroDefinition As String = .definition.sourceName
            If .sourceRawValue <> "" Then macroDefinition &= " " & .sourceRawValue
            Dim replacementText As String
            Dim replacementToFreeBasic As Long
            If C2fbReplacementRuleMatch( _
                translation.genericC.policy, macroDefinition, replacementText, _
                replacementToFreeBasic) = 0 Then Continue For
            If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                ReportError("generic header exceeds the configured macro replacement limit")
            If outputNameCount > UBound(outputNames) Then _
                ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
            .freeBasicName = GenericFreeBasicMacroNameInContext(translation,  _
                .definition.sourceName, outputNames(), outputNameCount)
            outputNames(outputNameCount) = .freeBasicName
            outputNameCount += 1

            Dim macroBinding As C2fbMacroBindingModel
            macroBinding.name = .freeBasicName
            macroBinding.isFunctionLike = 0
            macroBinding.isBlock = 0
            If replacementToFreeBasic <> 0 Then
                If InStr(replacementText, Chr(10)) <> 0 OrElse _
                   InStr(replacementText, Chr(13)) <> 0 Then
                    macroBinding.bodyText = IndentC2fbReplacement( _
                        replacementText, "    ")
                    macroBinding.isBlock = -1
                Else
                    macroBinding.bodyText = replacementText
                End If
                WriteGenericMacroBindingWithGuardsInPolicy( _
                    translation.genericC.policy, outputFile, .definition.sourceName, _
                    macroBinding)
                .emitted = -1
            Else
                .definition.rawValue = Trim(replacementText)
                TokenizeCDeclaration( _
                    .definition.rawValue, .definition.tokens(), .definition.tokenCount)
            End If
            conversionSummary.genericHeader.customMacroReplacementCount += 1
        End With
    Next
End Sub

Private Function GenericHexFloatDigitValue(ByVal character As Long) As Long
    If character >= Asc("0") AndAlso character <= Asc("9") Then _
        Return character - Asc("0")
    If character >= Asc("A") AndAlso character <= Asc("F") Then _
        Return character - Asc("A") + 10
    If character >= Asc("a") AndAlso character <= Asc("f") Then _
        Return character - Asc("a") + 10
    Return -1
End Function

Private Function MultiplyGenericHexFloatDecimalDigits( _
    digits() As UByte, ByRef digitCount As Long, ByVal factor As Long _
) As Long
    Dim carry As Long = 0
    For digitIndex As Long = 0 To digitCount - 1
        Dim product As Long = CLng(digits(digitIndex)) * factor + carry
        digits(digitIndex) = CByte(product Mod 10)
        carry = product \ 10
    Next
    While carry > 0
        If digitCount > UBound(digits) Then Return 0
        digits(digitCount) = CByte(carry Mod 10)
        digitCount += 1
        carry \= 10
    Wend
    Return -1
End Function

Private Function AddGenericHexFloatDecimalDigits( _
    digits() As UByte, ByRef digitCount As Long, ByVal addend As Long _
) As Long
    Dim carry As Long = addend
    For digitIndex As Long = 0 To digitCount - 1
        Dim sum As Long = CLng(digits(digitIndex)) + carry
        digits(digitIndex) = CByte(sum Mod 10)
        carry = sum \ 10
        If carry = 0 Then Return -1
    Next
    While carry > 0
        If digitCount > UBound(digits) Then Return 0
        digits(digitCount) = CByte(carry Mod 10)
        digitCount += 1
        carry \= 10
    Wend
    Return -1
End Function

Private Function GenericHexFloatDecimalDigitsToString( _
    digits() As UByte, ByVal digitCount As Long _
) As String
    Dim result As String = ""
    For digitIndex As Long = digitCount - 1 To 0 Step -1
        result &= Chr(Asc("0") + digits(digitIndex))
    Next
    Return result
End Function

Private Function GenericHexFloatScientificText( _
    ByVal decimalDigits As String, ByVal decimalPoint As Long, _
    ByVal precision As Long _
) As String
    Dim firstNonzero As Long = 1
    While firstNonzero <= Len(decimalDigits) AndAlso _
          Mid(decimalDigits, firstNonzero, 1) = "0"
        firstNonzero += 1
    Wend
    If firstNonzero > Len(decimalDigits) Then Return "0.0e0"

    Dim decimalExponent As Long = decimalPoint - firstNonzero
    Dim significantDigits As String = Mid(decimalDigits, firstNonzero)
    If Len(significantDigits) > precision Then
        Dim roundedDigits As String = Left(significantDigits, precision)
        Dim nextDigit As Long = Asc(significantDigits, precision + 1) - Asc("0")
        Dim hasRemainingNonzero As Long = 0
        For index As Long = precision + 2 To Len(significantDigits)
            If Asc(significantDigits, index) <> Asc("0") Then
                hasRemainingNonzero = -1
                Exit For
            End If
        Next
        Dim lastDigit As Long = Asc(roundedDigits, precision) - Asc("0")
        Dim roundUp As Long = CInt( _
            nextDigit > 5 OrElse _
            (nextDigit = 5 AndAlso _
             (hasRemainingNonzero <> 0 OrElse (lastDigit Mod 2) <> 0)))
        If roundUp <> 0 Then
            Dim position As Long = precision
            While position > 0
                Dim currentDigit As Long = Asc(roundedDigits, position)
                If currentDigit = Asc("9") Then
                    roundedDigits = Left(roundedDigits, position - 1) & "0" & _
                        Mid(roundedDigits, position + 1)
                    position -= 1
                Else
                    roundedDigits = Left(roundedDigits, position - 1) & _
                        Chr(currentDigit + 1) & Mid(roundedDigits, position + 1)
                    Exit While
                End If
            Wend
            If position = 0 Then
                roundedDigits = "1" & String(precision - 1, "0")
                decimalExponent += 1
            End If
        End If
        significantDigits = roundedDigits
    End If

    Dim exponentText As String = Trim(Str(decimalExponent))
    If Len(significantDigits) = 1 Then _
        Return significantDigits & "e" & exponentText
    Return Left(significantDigits, 1) & "." & _
        Mid(significantDigits, 2) & "e" & exponentText
End Function

Private Function TranslateGenericHexFloatingMacroLiteral( _
    ByVal sourceToken As String, ByRef freeBasicValue As String, _
    ByRef freeBasicType As String _
) As Long
    Dim lowerToken As String = LCase(sourceToken)
    If Left(lowerToken, 2) <> "0x" Then Return 0

    Dim position As Long = 3
    Dim significand As String = ""
    Dim significandDigitCount As Long = 0
    Dim fractionDigitCount As Long = 0
    While position <= Len(sourceToken) AndAlso _
          IsHexDigit(Asc(sourceToken, position)) <> 0
        significand &= Mid(sourceToken, position, 1)
        position += 1
        significandDigitCount += 1
    Wend
    If Mid(sourceToken, position, 1) = "." Then
        position += 1
        While position <= Len(sourceToken) AndAlso _
              IsHexDigit(Asc(sourceToken, position)) <> 0
            significand &= Mid(sourceToken, position, 1)
            position += 1
            significandDigitCount += 1
            fractionDigitCount += 1
        Wend
    End If
    If significandDigitCount = 0 OrElse _
       significandDigitCount > MAX_GENERIC_HEX_FLOAT_SIGNIFICAND_DIGITS OrElse _
       LCase(Mid(sourceToken, position, 1)) <> "p" Then Return 0

    position += 1
    Dim exponentSign As Long = 1
    If Mid(sourceToken, position, 1) = "+" Then
        position += 1
    ElseIf Mid(sourceToken, position, 1) = "-" Then
        exponentSign = -1
        position += 1
    End If
    Dim exponentStart As Long = position
    Dim exponentMagnitude As Long = 0
    While position <= Len(sourceToken) AndAlso _
          Asc(sourceToken, position) >= Asc("0") AndAlso _
          Asc(sourceToken, position) <= Asc("9")
        Dim exponentDigit As Long = Asc(sourceToken, position) - Asc("0")
        If exponentMagnitude > _
           (MAX_GENERIC_HEX_FLOAT_EXPONENT - exponentDigit) \ 10 Then Return 0
        exponentMagnitude = exponentMagnitude * 10 + exponentDigit
        position += 1
    Wend
    If position = exponentStart Then Return 0

    Dim suffix As String = LCase(Mid(sourceToken, position, 1))
    If suffix = "f" Then
        freeBasicType = "Single"
        position += 1
    ElseIf suffix = "l" Then
        Return 0
    Else
        freeBasicType = "Double"
    End If
    If position <= Len(sourceToken) AndAlso _
       IsIdentifierPart(Asc(sourceToken, position)) <> 0 Then Return 0

    Dim binaryExponent As Long = _
        exponentSign * exponentMagnitude - 4 * fractionDigitCount
    While Len(significand) > 1 AndAlso Right(significand, 1) = "0"
        significand = Left(significand, Len(significand) - 1)
        binaryExponent += 4
    Wend
    While Len(significand) > 1 AndAlso Left(significand, 1) = "0"
        significand = Mid(significand, 2)
    Wend
    If significand = "0" Then
        freeBasicValue = "0.0"
    Else
        Dim leadingHexDigit As Long = _
            GenericHexFloatDigitValue(Asc(significand, 1))
        Dim leadingBitCount As Long = 1
        While leadingHexDigit >= 2
            leadingHexDigit \= 2
            leadingBitCount += 1
        Wend
        Dim highestBinaryExponent As Long = _
            4 * (Len(significand) - 1) + leadingBitCount - 1 + binaryExponent
        Dim maximumBinaryExponent As Long
        Dim minimumSubnormalExponent As Long
        If freeBasicType = "Single" Then
            maximumBinaryExponent = 127
            minimumSubnormalExponent = -149
        Else
            maximumBinaryExponent = 1023
            minimumSubnormalExponent = -1074
        End If
        If highestBinaryExponent > maximumBinaryExponent Then Return 0
        If highestBinaryExponent < minimumSubnormalExponent - 1 Then
            freeBasicValue = "0.0"
        Else
            If binaryExponent < -MAX_GENERIC_HEX_FLOAT_DECIMAL_DIGITS OrElse _
               binaryExponent > MAX_GENERIC_HEX_FLOAT_EXPONENT Then Return 0

            Dim decimalDigits(0 To MAX_GENERIC_HEX_FLOAT_DECIMAL_DIGITS - 1) As UByte
            Dim decimalDigitCount As Long = 1
            decimalDigits(0) = 0
            For sourceIndex As Long = 1 To Len(significand)
                If MultiplyGenericHexFloatDecimalDigits( _
                    decimalDigits(), decimalDigitCount, 16) = 0 OrElse _
                   AddGenericHexFloatDecimalDigits( _
                    decimalDigits(), decimalDigitCount, _
                    GenericHexFloatDigitValue(Asc(significand, sourceIndex))) = 0 Then _
                    Return 0
            Next

            Dim decimalPrecision As Long = _
                IIf(freeBasicType = "Single", 9, 17)
            If binaryExponent >= 0 Then
                For exponentIndex As Long = 1 To binaryExponent
                    If MultiplyGenericHexFloatDecimalDigits( _
                        decimalDigits(), decimalDigitCount, 2) = 0 Then Return 0
                Next
                Dim integerDigits As String = _
                    GenericHexFloatDecimalDigitsToString( _
                        decimalDigits(), decimalDigitCount)
                freeBasicValue = GenericHexFloatScientificText( _
                    integerDigits, Len(integerDigits), decimalPrecision)
            Else
                Dim decimalPlaces As Long = -binaryExponent
                If decimalPlaces > MAX_GENERIC_HEX_FLOAT_DECIMAL_DIGITS Then Return 0
                For exponentIndex As Long = 1 To decimalPlaces
                    If MultiplyGenericHexFloatDecimalDigits( _
                        decimalDigits(), decimalDigitCount, 5) = 0 Then Return 0
                Next
                Dim integerDigits As String = _
                    GenericHexFloatDecimalDigitsToString( _
                        decimalDigits(), decimalDigitCount)
                Dim decimalPoint As Long = Len(integerDigits) - decimalPlaces
                freeBasicValue = GenericHexFloatScientificText( _
                    integerDigits, decimalPoint, decimalPrecision)
            End If
        End If
    End If

    If freeBasicType = "Single" Then
        freeBasicValue &= "!"
    Else
        freeBasicValue &= "#"
    End If
    Return -1
End Function

Private Function TranslateGenericFloatingMacroLiteral( _
    ByRef translation As C2fbTranslationContext, _
    ByVal rawValue As String, ByRef freeBasicValue As String, _
    ByRef freeBasicType As String _
) As Long
    rawValue = GenericMacroStripOuterParentheses(Trim(rawValue))
    Dim signText As String
    If Left(rawValue, 1) = "-" OrElse Left(rawValue, 1) = "+" Then
        signText = Left(rawValue, 1)
        rawValue = LTrim(Mid(rawValue, 2))
    End If
    If rawValue = "" Then Return 0

    Dim tokens() As String
    Dim tokenCount As Long
    If TokenizeCPreprocessorReplacement( _
        rawValue, tokens(), tokenCount) = 0 OrElse tokenCount <> 1 Then Return 0
    Dim sourceToken As String = tokens(0)
    Dim lowerSourceToken As String = LCase(sourceToken)
    If Left(lowerSourceToken, 2) = "0x" Then
        If TranslateGenericHexFloatingMacroLiteral( _
            sourceToken, freeBasicValue, freeBasicType) = 0 Then Return 0
        If signText = "-" Then freeBasicValue = "-" & freeBasicValue
        Return -1
    End If
    Dim lastByte As Long = Asc(sourceToken, Len(sourceToken))
    If InStr(sourceToken, ".") = 0 AndAlso _
       InStr(lowerSourceToken, "e") = 0 AndAlso _
       lastByte <> Asc("f") AndAlso lastByte <> Asc("F") AndAlso _
       lastByte <> Asc("d") AndAlso lastByte <> Asc("D") Then Return 0
    If lastByte = Asc("f") OrElse lastByte = Asc("F") Then
        freeBasicType = "Single"
    ElseIf lastByte = Asc("l") OrElse lastByte = Asc("L") Then
        Return 0
    Else
        freeBasicType = "Double"
    End If
    If GenericMacroTokenNumber( _
        translation, sourceToken, freeBasicValue) = 0 Then Return 0
    If freeBasicType = "Double" AndAlso Right(freeBasicValue, 1) <> "#" Then _
        freeBasicValue &= "#"
    If signText = "-" Then freeBasicValue = "-" & freeBasicValue
    Return -1
End Function

Private Sub WriteGenericHeaderFloatingMacros( _
    ByRef translation As C2fbTranslationContext, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, outputNames() As String, _
    ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    For macroIndex As Long = 0 To translation.genericC.header.headerMacroCount - 1
        With translation.genericC.header.headerMacros(macroIndex)
            If .active = 0 OrElse _
               GenericDefineExcludedInPolicy( _
                   translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
               .definition.functionLike <> 0 OrElse .definition.continued <> 0 OrElse _
               .emitted <> 0 OrElse _
               (.privateName = 0 AndAlso GenericMacroTokenConversionForcedInPolicy( _
                    translation.genericC.policy, .definition.sourceName, 0) <> 0) Then _
                Continue For

            Dim freeBasicValue As String
            Dim freeBasicType As String
            If TranslateGenericFloatingMacroLiteral( _
                translation, .definition.rawValue, freeBasicValue, freeBasicType) = 0 Then _
                Continue For
            If .privateName <> 0 Then
                .resolvedValue = freeBasicValue
                .emitted = -1
                Continue For
            End If

            .freeBasicName = GenericFreeBasicMacroNameInContext(translation, _
                .definition.sourceName, outputNames(), outputNameCount)
            If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                ReportError("generic header exceeds the configured floating macro limit")
            If outputNameCount > UBound(outputNames) Then _
                ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
            outputNames(outputNameCount) = .freeBasicName
            outputNameCount += 1

            Dim constantBinding As C2fbConstantBindingModel
            constantBinding.freeBasicName = .freeBasicName
            constantBinding.targetType = freeBasicType
            constantBinding.valueExpression = freeBasicValue
            WriteGenericConstantBindingWithGuardsInPolicy( _
                translation.genericC.policy, outputFile, .definition.sourceName, _
                constantBinding)
            .emitted = -1
            conversionSummary.genericHeader.floatingMacroCount += 1
        End With
    Next
    If conversionSummary.genericHeader.floatingMacroCount > 0 Then _
        WriteC2fbOutputLine(outputFile, "")
End Sub

Private Sub WriteGenericHeaderPointerCastMacros( _
    ByRef translation As C2fbTranslationContext, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    outputNames() As String, ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    For passIndex As Long = 0 To translation.genericC.header.headerMacroCount - 1
        Dim madeProgress As Long = 0
        For macroIndex As Long = 0 To translation.genericC.header.headerMacroCount - 1
            With translation.genericC.header.headerMacros(macroIndex)
                If .active = 0 OrElse .definition.functionLike <> 0 OrElse _
                   .definition.continued <> 0 OrElse .emitted <> 0 OrElse _
                   GenericDefineExcludedInPolicy( _
                    translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
                   (.privateName = 0 AndAlso GenericMacroTokenConversionForcedInPolicy( _
                    translation.genericC.policy, .definition.sourceName, 0) <> 0) OrElse _
                   GenericHeaderMacroPointerCastCandidate( _
                    translation, .definition.rawValue) = 0 Then Continue For

                Dim freeBasicExpression As String
                If TranslateGenericHeaderMacroExpression( _
                    translation, .definition.rawValue, freeBasicExpression) = 0 OrElse _
                   Left(freeBasicExpression, 5) <> "CPtr(" Then Continue For
                If .privateName <> 0 Then
                    .resolvedValue = freeBasicExpression
                    .isString = CInt(InStr(freeBasicExpression, "StrPtr(") <> 0) * -1
                    .emitted = -1
                    madeProgress = -1
                    Continue For
                End If

                If .freeBasicName = "" Then
                    .freeBasicName = GenericFreeBasicMacroNameInContext( _
                        translation, .definition.sourceName, _
                        outputNames(), outputNameCount)
                    If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                        ReportError("generic header exceeds the configured pointer macro limit")
                    If outputNameCount > UBound(outputNames) Then _
                        ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
                    outputNames(outputNameCount) = .freeBasicName
                    outputNameCount += 1
                End If

                Dim pointerMacroBinding As C2fbMacroBindingModel
                pointerMacroBinding.name = .freeBasicName
                pointerMacroBinding.bodyText = freeBasicExpression
                WriteGenericMacroBindingWithGuardsInPolicy( _
                    translation.genericC.policy, outputFile, _
                    .definition.sourceName, pointerMacroBinding)
                .isString = CInt(InStr(freeBasicExpression, "StrPtr(") <> 0) * -1
                .emitted = -1
                conversionSummary.genericHeader.pointerCastMacroCount += 1
                madeProgress = -1
            End With
        Next
        If madeProgress = 0 Then Exit For
    Next
    If conversionSummary.genericHeader.pointerCastMacroCount > 0 Then _
        WriteC2fbOutputLine(outputFile, "")
End Sub

Private Sub WriteGenericHeaderStatementObjectMacros( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, outputNames() As String, _
    ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    Dim noParameterNames(0 To 0) As String
    For macroIndex As Long = 0 To _
        translation.genericC.header.headerMacroCount - 1
        With translation.genericC.header.headerMacros(macroIndex)
            If .active = 0 OrElse .privateName <> 0 OrElse .emitted <> 0 OrElse _
               .definition.functionLike <> 0 OrElse .definition.continued <> 0 OrElse _
               GenericDefineExcludedInPolicy( _
                translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
               GenericMacroTokenConversionForcedInPolicy( _
                translation.genericC.policy, .definition.sourceName, 0) <> 0 Then _
                Continue For

            Dim sourceBody As String = Trim(.definition.rawValue)

            Dim initializerBody As String
            Dim initializerStatus As Long = TranslateGenericBraceInitializerMacro( _
                translation, sourceBody, noParameterNames(), noParameterNames(), _
                0, 0, initializerBody)
            If initializerStatus < 0 Then Continue For
            If initializerStatus > 0 Then
                Dim initializerName As String = GenericFreeBasicMacroNameInContext( _
                    translation, .definition.sourceName, outputNames(), outputNameCount)
                If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                    ReportError("generic header exceeds the configured initializer macro limit")
                If outputNameCount > UBound(outputNames) Then _
                    ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
                outputNames(outputNameCount) = initializerName
                outputNameCount += 1
                Dim initializerBinding As C2fbMacroBindingModel
                initializerBinding.name = initializerName
                initializerBinding.bodyText = initializerBody
                WriteGenericMacroBindingWithGuardsInPolicy( _
                    translation.genericC.policy, outputFile, _
                    .definition.sourceName, initializerBinding)
                .freeBasicName = initializerName
                .emitted = -1
                conversionSummary.genericHeader.initializerMacroCount += 1
                Continue For
            End If

            Dim emptyBlockKind As Long = 0
            If Left(sourceBody, 1) = "{" Then
                Dim blockEnd As Long = 1
                If ScanSimpleExpressionGroup( _
                    sourceBody, blockEnd, Asc("{"), Asc("}")) = 0 Then Continue For
                Dim blockTail As String = Trim(Mid(sourceBody, blockEnd))
                If blockTail <> "" AndAlso blockTail <> ";" Then Continue For
                Dim blockContents As String = Trim(Mid( _
                    sourceBody, 2, blockEnd - 3))
                If blockContents = "" Then
                    emptyBlockKind = 1
                ElseIf blockContents = ";" Then
                    emptyBlockKind = 2
                End If
            End If

            Dim freeBasicBody As String
            If emptyBlockKind = 0 Then
                Dim statementIntegerDivisionAssumed As Long = 0
                If InStr(sourceBody, "/=") <> 0 Then _
                    statementIntegerDivisionAssumed = _
                        GenericIntegerMacroAssumedInPolicy( _
                            translation.genericC.policy, .definition.sourceName)
                Dim blockStatus As Long = TranslateGenericStatementMacroBlock( _
                    translation, catalog, sourceBody, noParameterNames(), noParameterNames(), _
                    0, 0, freeBasicBody, _
                    translation.genericC.policy.dropMacroBodyScopes, _
                    statementIntegerDivisionAssumed, .definition.sourceName)
                If blockStatus <= 0 Then Continue For
                If statementIntegerDivisionAssumed <> 0 AndAlso _
                   InStr(freeBasicBody, "\=") <> 0 Then _
                    GenericIntegerMacroAssumedInPolicy( _
                        translation.genericC.policy, .definition.sourceName, -1)
            End If

            Dim freeBasicName As String = GenericFreeBasicMacroNameInContext( _
                translation, .definition.sourceName, outputNames(), outputNameCount)
            If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                ReportError("generic header exceeds the configured statement macro limit")
            If outputNameCount > UBound(outputNames) Then _
                ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
            outputNames(outputNameCount) = freeBasicName
            outputNameCount += 1

            Dim macroBinding As C2fbMacroBindingModel
            macroBinding.name = freeBasicName
            If emptyBlockKind = 1 Then
                ' C's empty initializer maps to FreeBASIC's empty parentheses.
                macroBinding.bodyText = "()"
            ElseIf emptyBlockKind = 2 Then
                macroBinding.bodyText = ""
            ElseIf Left(Trim(freeBasicBody), 5) = "Scope" OrElse _
                   InStr(freeBasicBody, Chr(10)) <> 0 Then
                macroBinding.isBlock = -1
                macroBinding.bodyText = IndentC2fbReplacement( _
                    freeBasicBody, "    ")
            Else
                macroBinding.bodyText = Trim(freeBasicBody)
            End If
            WriteGenericMacroBindingWithGuardsInPolicy( _
                translation.genericC.policy, outputFile, _
                .definition.sourceName, macroBinding)
            .freeBasicName = freeBasicName
            .emitted = -1
            conversionSummary.genericHeader.statementMacroCount += 1
        End With
    Next
    If conversionSummary.genericHeader.statementMacroCount > 0 Then _
        WriteC2fbOutputLine(outputFile, "")
End Sub

Private Sub WriteGenericHeaderMacros( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, outputNames() As String, _
    ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    Dim noParameterNames(0 To 0) As String
    WriteGenericHeaderObjectMacroReplacements( _
        translation, outputFile, outputNames(), outputNameCount, conversionSummary)
    WriteGenericHeaderEmptyMacros( _
        translation, outputFile, outputNames(), outputNameCount, conversionSummary)
    WriteGenericHeaderStatementObjectMacros( _
        translation, catalog, outputFile, outputNames(), outputNameCount, conversionSummary)
    WriteGenericHeaderFloatingMacros( _
        translation, outputFile, outputNames(), outputNameCount, conversionSummary)
    For macroIndex As Long = 0 To translation.genericC.header.headerMacroCount - 1
        With translation.genericC.header.headerMacros(macroIndex)
            If .active = 0 OrElse GenericDefineExcludedInPolicy(translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
               .definition.functionLike <> 0 OrElse .definition.continued <> 0 OrElse _
               .privateName <> 0 OrElse _
               GenericMacroTokenConversionForcedInPolicy( _
                translation.genericC.policy, .definition.sourceName, 0) <> 0 OrElse _
               GenericIntegerMacroCandidate(.definition.rawValue) = 0 OrElse _
               GenericHeaderMacroPointerCastCandidate( _
                translation, .definition.rawValue) <> 0 Then Continue For
            .freeBasicName = GenericFreeBasicMacroNameInContext(translation,  _
                .definition.sourceName, outputNames(), outputNameCount)
            If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                ReportError("generic header exceeds the configured macro output limit")
            If outputNameCount > UBound(outputNames) Then _
                ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
            outputNames(outputNameCount) = .freeBasicName
            outputNameCount += 1
        End With
    Next

    For passIndex As Long = 0 To translation.genericC.header.headerMacroCount - 1
        Dim madeProgress As Long = 0
        For macroIndex As Long = 0 To translation.genericC.header.headerMacroCount - 1
            With translation.genericC.header.headerMacros(macroIndex)
                If .active = 0 OrElse GenericDefineExcludedInPolicy(translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
                   .definition.functionLike <> 0 OrElse .definition.continued <> 0 OrElse _
                   (.privateName = 0 AndAlso GenericMacroTokenConversionForcedInPolicy( _
                    translation.genericC.policy, .definition.sourceName, 0) <> 0) OrElse _
                   .emitted <> 0 OrElse _
                   GenericIntegerMacroCandidate(.definition.rawValue) = 0 OrElse _
                   GenericHeaderMacroPointerCastCandidate( _
                    translation, .definition.rawValue) <> 0 Then Continue For
                Dim hasIntegerDivision As Long = CInt( _
                    InStr(.definition.rawValue, "/") <> 0 OrElse _
                    InStr(.definition.rawValue, "%") <> 0)
                Dim integerDivisionAssumed As Long = 0
                If hasIntegerDivision <> 0 Then _
                    integerDivisionAssumed = GenericIntegerMacroAssumedInPolicy( _
                        translation.genericC.policy, .definition.sourceName)
                Dim possibleTypeMacro As String
                If GenericTypeMacroValue( _
                    translation, catalog, .definition, possibleTypeMacro) <> 0 Then _
                    Continue For
                Dim freeBasicExpression As String
                Dim requiresMacro As Long = _
                    GenericIntegerMacroExpressionRequiresMacro( _
                        translation, .definition.rawValue)
                Dim translationSucceeded As Long = 0
                If GenericNullPointerConstantText(.definition.rawValue) <> 0 Then
                    freeBasicExpression = "0"
                    translationSucceeded = -1
                ElseIf TranslateGenericHeaderMacroExpression( _
                    translation, .definition.rawValue, freeBasicExpression, _
                    integerDivisionAssumed) <> 0 Then
                    translationSucceeded = -1
                End If
                If requiresMacro <> 0 OrElse translationSucceeded = 0 Then
                    If translationSucceeded = 0 Then
                        If GenericIntegerMacroTokenSequenceSupported( _
                            translation, .definition.rawValue) = 0 OrElse _
                           TranslateGenericMacroTokenSequence( _
                            translation, .definition.rawValue, noParameterNames(), _
                            noParameterNames(), 0, 0, freeBasicExpression) = 0 Then _
                            Continue For
                    End If
                    If .privateName <> 0 Then
                        .resolvedValue = freeBasicExpression
                    Else
                        Dim expressionMacroBinding As C2fbMacroBindingModel
                        expressionMacroBinding.name = .freeBasicName
                        expressionMacroBinding.bodyText = freeBasicExpression
                        WriteGenericMacroBindingWithGuardsInPolicy( _
                            translation.genericC.policy, outputFile, _
                            .definition.sourceName, expressionMacroBinding)
                        conversionSummary.genericHeader.integerMacroCount += 1
                    End If
                    .emitted = -1
                    madeProgress = -1
                    Continue For
                End If
                If .privateName <> 0 Then
                    .resolvedValue = freeBasicExpression
                Else
                    Dim constantBinding As C2fbConstantBindingModel
                    constantBinding.freeBasicName = .freeBasicName
                    constantBinding.valueExpression = freeBasicExpression
                    WriteGenericConstantBindingWithGuardsInPolicy( _
                        translation.genericC.policy, outputFile, .definition.sourceName, _
                        constantBinding)
                    conversionSummary.genericHeader.integerMacroCount += 1
                End If
                .emitted = -1
                If integerDivisionAssumed <> 0 Then _
                    GenericIntegerMacroAssumedInPolicy( _
                        translation.genericC.policy, .definition.sourceName, -1)
                madeProgress = -1
            End With
        Next
        If madeProgress = 0 Then Exit For
    Next

    WriteGenericHeaderTypeMacros( _
        translation, catalog, outputFile, outputNames(), outputNameCount, conversionSummary)
    WriteGenericHeaderPointerCastMacros( _
        translation, outputFile, outputNames(), outputNameCount, conversionSummary)

    For macroIndex As Long = 0 To translation.genericC.header.headerMacroCount - 1
        With translation.genericC.header.headerMacros(macroIndex)
            If .active = 0 OrElse GenericDefineExcludedInPolicy(translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
               .definition.functionLike <> 0 OrElse .definition.continued <> 0 OrElse _
               .emitted <> 0 OrElse (.privateName = 0 AndAlso _
               GenericMacroTokenConversionForcedInPolicy( _
                    translation.genericC.policy, .definition.sourceName, 0) <> 0) Then Continue For
            Dim freeBasicValue As String
            If TranslateGenericHeaderStringMacro( _
                .definition.rawValue, freeBasicValue) = 0 AndAlso _
               TryTranslateGenericHeaderStringPointerCast( _
                translation, .definition.rawValue, freeBasicValue) = 0 Then Continue For
            If .privateName <> 0 Then
                .resolvedValue = freeBasicValue
                .emitted = -1
                .isString = -1
                Continue For
            End If
            .freeBasicName = GenericFreeBasicMacroNameInContext(translation,  _
                .definition.sourceName, outputNames(), outputNameCount)
            If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                ReportError("generic header exceeds the configured string macro output limit")
            If outputNameCount > UBound(outputNames) Then _
                ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
            outputNames(outputNameCount) = .freeBasicName
            outputNameCount += 1
            Dim stringMacroBinding As C2fbMacroBindingModel
            stringMacroBinding.name = .freeBasicName
            stringMacroBinding.bodyText = freeBasicValue
            WriteGenericMacroBindingWithGuardsInPolicy( _
                translation.genericC.policy, outputFile, .definition.sourceName, _
                stringMacroBinding)
            .emitted = -1
            .isString = -1
            conversionSummary.genericHeader.stringMacroCount += 1
        End With
    Next

    For passIndex As Long = 0 To translation.genericC.header.headerMacroCount - 1
        Dim madeStringAliasProgress As Long = 0
        For macroIndex As Long = 0 To translation.genericC.header.headerMacroCount - 1
            With translation.genericC.header.headerMacros(macroIndex)
                If .active = 0 OrElse GenericDefineExcludedInPolicy(translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
                   .definition.functionLike <> 0 OrElse .definition.continued <> 0 OrElse _
                   .emitted <> 0 OrElse (.privateName = 0 AndAlso _
                   GenericMacroTokenConversionForcedInPolicy( _
                    translation.genericC.policy, .definition.sourceName, 0) <> 0) Then Continue For
                Dim targetName As String = GenericHeaderAliasMacroName( _
                    translation.genericC.header.headerMacros(macroIndex).definition)
                Dim targetIndex As Long = GenericHeaderMacroIndexInContext(translation, targetName)
                If targetIndex < 0 OrElse translation.genericC.header.headerMacros(targetIndex).active = 0 OrElse _
                   translation.genericC.header.headerMacros(targetIndex).isString = 0 Then Continue For
                Dim stringAliasValue As String
                If translation.genericC.header.headerMacros(targetIndex).privateName <> 0 Then
                    stringAliasValue = _
                        translation.genericC.header.headerMacros(targetIndex).resolvedValue
                Else
                    stringAliasValue = _
                        translation.genericC.header.headerMacros(targetIndex).freeBasicName
                End If
                If stringAliasValue = "" Then Continue For
                If .privateName <> 0 Then
                    .resolvedValue = stringAliasValue
                    .emitted = -1
                    .isString = -1
                    madeStringAliasProgress = -1
                    Continue For
                End If
                If .freeBasicName = "" Then
                    .freeBasicName = GenericFreeBasicMacroNameInContext(translation,  _
                        .definition.sourceName, outputNames(), outputNameCount)
                    If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                        ReportError("generic header exceeds the configured string macro output limit")
                    If outputNameCount > UBound(outputNames) Then _
                        ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
                    outputNames(outputNameCount) = .freeBasicName
                    outputNameCount += 1
                End If
                Dim stringAliasBinding As C2fbMacroBindingModel
                stringAliasBinding.name = .freeBasicName
                stringAliasBinding.bodyText = stringAliasValue
                WriteGenericMacroBindingWithGuardsInPolicy( _
                    translation.genericC.policy, outputFile, .definition.sourceName, _
                    stringAliasBinding)
                .emitted = -1
                .isString = -1
                conversionSummary.genericHeader.stringMacroCount += 1
                madeStringAliasProgress = -1
            End With
        Next
        If madeStringAliasProgress = 0 Then Exit For
    Next

    WriteGenericHeaderAliasMacros( _
        translation, outputFile, outputNames(), outputNameCount, conversionSummary)
    PreallocateGenericHeaderTokenMacroNames( _
        translation, outputNames(), outputNameCount)
    ValidateGenericHeaderTokenFunctionMacros(translation)
    WriteGenericHeaderTokenConvertedObjectMacros( _
        translation, outputFile, conversionSummary)
    WriteGenericHeaderFunctionMacros( _
        translation, catalog, outputFile, outputNames(), outputNameCount, conversionSummary)
    WriteGenericHeaderObjectCallMacros( _
        translation, outputFile, outputNames(), outputNameCount, conversionSummary)
    WriteGenericHeaderObjectTokenSequenceMacros( _
        translation, outputFile, outputNames(), outputNameCount, conversionSummary)

    For macroIndex As Long = 0 To translation.genericC.header.headerMacroCount - 1
        With translation.genericC.header.headerMacros(macroIndex)
            If .active = 0 OrElse GenericDefineExcludedInPolicy(translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
               .privateName <> 0 OrElse .emitted <> 0 Then Continue For
            If .tokenConversionFailed <> 0 Then _
                GenericMacroTokenConversionForcedInPolicy( _
                    translation.genericC.policy, .definition.sourceName)
            If translation.genericC.policy.removeEmptyReservedDefines <> 0 AndAlso _
               IsGenericEmptyReservedMacro(translation.genericC.header.headerMacros(macroIndex)) <> 0 Then
                .emitted = -1
                Continue For
            End If
            If .definition.functionLike <> 0 Then
                Dim rawFunctionBody As String = Trim(Mid( _
                    .definition.rawValue, InStr(.definition.rawValue, ")") + 1))
                If Left(rawFunctionBody, 1) = "{" AndAlso _
                   Right(rawFunctionBody, 1) = "}" Then
                    Dim parameterNames() As String
                    Dim freeParameterNames() As String
                    Dim parameterCount As Long
                    Dim isVariadic As Long
                    Dim parsedBody As String
                    If ParseGenericFunctionMacro( _
                        .definition, parameterNames(), freeParameterNames(), _
                        parameterCount, isVariadic, parsedBody) <> 0 Then
                        ApplyGenericMacroParameterRenamesInPolicy( _
                            translation.genericC.policy, parameterNames(), _
                            freeParameterNames(), parameterCount, parsedBody)
                        .freeBasicName = GenericFreeBasicMacroNameInContext( _
                            translation, .definition.sourceName, _
                            outputNames(), outputNameCount)
                        If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                            ReportError("generic header exceeds the configured statement macro limit")
                        If outputNameCount > UBound(outputNames) Then _
                            ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
                        outputNames(outputNameCount) = .freeBasicName
                        outputNameCount += 1
                        Dim todoMacro As C2fbMacroBindingModel
                        todoMacro.name = .freeBasicName
                        For parameterIndex As Long = 0 To parameterCount - 1
                            If parameterIndex > 0 Then todoMacro.parameters &= ", "
                            todoMacro.parameters &= freeParameterNames(parameterIndex)
                            If isVariadic <> 0 AndAlso parameterIndex = parameterCount - 1 Then _
                                todoMacro.parameters &= "..."
                        Next
                        todoMacro.bodyText = _
                            "Scope : /' TODO: unsupported C statement macro '/ : End Scope"
                        todoMacro.isFunctionLike = -1
                        WriteGenericMacroBindingWithGuardsInPolicy( _
                            translation.genericC.policy, outputFile, _
                            .definition.sourceName, todoMacro)
                        .emitted = -1
                        conversionSummary.genericHeader.statementMacroCount += 1
                        Continue For
                    End If
                End If
                If .tokenConversionFailed <> 0 Then
                    EmitC2fbSkippedAtLocation(translation, _
                        outputFile, conversionSummary, _
                        "requested macro token conversion unsupported", _
                        "#define " & .definition.sourceName & _
                        GenericHeaderMacroSummary(.sourceRawValue), _
                        .definition.sourceLocation)
                    .emitted = -1
                    Continue For
                End If
                EmitC2fbSkippedAtLocation(translation,  _
                    outputFile, conversionSummary, "unsupported function-like macro", _
                    "#define " & .definition.sourceName & GenericHeaderMacroSummary(.sourceRawValue), _
                    .definition.sourceLocation)
                Continue For
            End If
            Dim rawObjectBody As String = Trim(.definition.rawValue)
            If Left(rawObjectBody, 1) = "{" AndAlso Right(rawObjectBody, 1) = "}" Then
                ' Preserve the macro name and leave a compile-safe reminder for
                ' brace-wrapped C statements that cannot be translated yet.
                If .freeBasicName = "" Then
                    .freeBasicName = GenericFreeBasicMacroNameInContext( _
                        translation, .definition.sourceName, _
                        outputNames(), outputNameCount)
                    If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                        ReportError("generic header exceeds the configured statement macro limit")
                    If outputNameCount > UBound(outputNames) Then _
                        ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
                    outputNames(outputNameCount) = .freeBasicName
                    outputNameCount += 1
                End If
                Dim placeholderMacro As C2fbMacroBindingModel
                placeholderMacro.name = .freeBasicName
                placeholderMacro.bodyText = _
                    "Scope : /' TODO: unsupported C statement macro '/ : End Scope"
                WriteGenericMacroBindingWithGuardsInPolicy( _
                    translation.genericC.policy, outputFile, _
                    .definition.sourceName, placeholderMacro)
                .emitted = -1
                conversionSummary.genericHeader.statementMacroCount += 1
                Continue For
            End If
            Dim nestedDirectiveBody As String = Trim(.definition.rawValue)
            If Left(nestedDirectiveBody, Len("#define ")) = "#define " Then
                .freeBasicName = GenericFreeBasicMacroNameInContext( _
                    translation, .definition.sourceName, _
                    outputNames(), outputNameCount)
                If outputNameCount >= MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
                    ReportError("generic header exceeds the configured token macro limit")
                If outputNameCount > UBound(outputNames) Then _
                    ReDim Preserve outputNames(0 To UBound(outputNames) * 2 + 1)
                outputNames(outputNameCount) = .freeBasicName
                outputNameCount += 1
                Dim nestedDirectiveMacro As C2fbMacroBindingModel
                nestedDirectiveMacro.name = .freeBasicName
                nestedDirectiveMacro.bodyText = nestedDirectiveBody
                WriteGenericMacroBindingWithGuardsInPolicy( _
                    translation.genericC.policy, outputFile, _
                    .definition.sourceName, nestedDirectiveMacro)
                .emitted = -1
                conversionSummary.genericHeader.tokenSequenceMacroCount += 1
                Continue For
            End If
            Dim skippedMacroKind As String = "unsupported macro expression"
            If .tokenConversionFailed <> 0 Then
                skippedMacroKind = "requested macro token conversion unsupported"
            ElseIf .definition.continued <> 0 Then
                skippedMacroKind = "continued macro definition"
            End If
            EmitC2fbSkippedAtLocation(translation,  _
                outputFile, conversionSummary, skippedMacroKind, _
                "#define " & .definition.sourceName & " " & GenericHeaderMacroSummary(.sourceRawValue), _
                .definition.sourceLocation)
        End With
    Next
    If conversionSummary.genericHeader.integerMacroCount > 0 OrElse _
       conversionSummary.genericHeader.floatingMacroCount > 0 OrElse _
       conversionSummary.genericHeader.stringMacroCount > 0 Then _
        WriteC2fbOutputLine(outputFile, "")
End Sub

Private Sub WriteGenericHeaderIntegerCastHelpers( _
    ByRef translation As C2fbTranslationContext, _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    If translation.genericC.header.integerCastHelperCount = 0 Then Exit Sub
    Dim parameterTypes(0 To 10) As String
    parameterTypes(0) = "Byte"
    parameterTypes(1) = "UByte"
    parameterTypes(2) = "Short"
    parameterTypes(3) = "UShort"
    parameterTypes(4) = "Long"
    parameterTypes(5) = "ULong"
    parameterTypes(6) = "LongInt"
    parameterTypes(7) = "ULongInt"
    parameterTypes(8) = "Single"
    parameterTypes(9) = "Double"
    parameterTypes(10) = "Const Any Ptr"

    WriteC2fbOutputLine(outputFile, "")
    For helperIndex As Long = 0 To _
        translation.genericC.header.integerCastHelperCount - 1
        With translation.genericC.header.integerCastHelpers(helperIndex)
            WriteC2fbOutputLine(outputFile, "#ifndef " & .guardName)
            WriteC2fbOutputLine(outputFile, "#define " & .guardName)
            WriteC2fbOutputLine(outputFile, _
                "/' C floating-to-integer casts truncate toward zero. '/")
            For parameterIndex As Long = 0 To UBound(parameterTypes)
                Dim convertedValue As String = "value"
                If parameterIndex = 8 OrElse parameterIndex = 9 Then
                    convertedValue = "Fix(value)"
                ElseIf parameterIndex = 10 Then
                    convertedValue = "CULngInt(value)"
                End If
                WriteC2fbOutputLine(outputFile, _
                    "Private Function " & .functionName & " Overload(" & _
                    "ByVal value As " & parameterTypes(parameterIndex) & ") As " & _
                    .targetType)
                WriteC2fbOutputLine(outputFile, _
                    "    Return Cast(" & .targetType & ", " & convertedValue & ")")
                WriteC2fbOutputLine(outputFile, "End Function")
            Next
            WriteC2fbOutputLine(outputFile, "#endif")
            WriteC2fbOutputLine(outputFile, "")
        End With
    Next
End Sub

Private Sub WriteGenericHeaderOperatorHelpers( _
    ByRef translation As C2fbTranslationContext, _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    If translation.genericC.header.operatorHelperCount = 0 Then Exit Sub
    Dim typeNames(0 To 9) As String
    Dim typeWidths(0 To 9) As Long
    Dim typeSigned(0 To 9) As Long
    Dim typeRanks(0 To 9) As Long
    typeNames(0) = "Byte": typeWidths(0) = 8: typeSigned(0) = -1: typeRanks(0) = 1
    typeNames(1) = "UByte": typeWidths(1) = 8: typeSigned(1) = 0: typeRanks(1) = 1
    typeNames(2) = "Short": typeWidths(2) = 16: typeSigned(2) = -1: typeRanks(2) = 2
    typeNames(3) = "UShort": typeWidths(3) = 16: typeSigned(3) = 0: typeRanks(3) = 2
    typeNames(4) = "Long": typeWidths(4) = 32: typeSigned(4) = -1: typeRanks(4) = 3
    typeNames(5) = "ULong": typeWidths(5) = 32: typeSigned(5) = 0: typeRanks(5) = 3
    typeNames(6) = "LongInt": typeWidths(6) = 64: typeSigned(6) = -1: typeRanks(6) = 4
    typeNames(7) = "ULongInt": typeWidths(7) = 64: typeSigned(7) = 0: typeRanks(7) = 4
    typeNames(8) = "Single": typeWidths(8) = 32: typeSigned(8) = -1: typeRanks(8) = 5
    typeNames(9) = "Double": typeWidths(9) = 64: typeSigned(9) = -1: typeRanks(9) = 6

    WriteC2fbOutputLine(outputFile, "")
    For helperIndex As Long = 0 To _
        translation.genericC.header.operatorHelperCount - 1
        With translation.genericC.header.operatorHelpers(helperIndex)
            Dim typeLimit As Long = UBound(typeNames)
            If .operatorText = "%" Then typeLimit = 7
            If .operatorText <> "/" AndAlso .operatorText <> "%" Then _
                ReportError("invalid generic C arithmetic helper operator")
            WriteC2fbOutputLine(outputFile, "#ifndef " & .guardName)
            WriteC2fbOutputLine(outputFile, "#define " & .guardName)
            WriteC2fbOutputLine(outputFile, _
                "/' C promotions and usual arithmetic conversions are selected from the argument types. '/")
            WriteC2fbOutputLine(outputFile, _
                "' This procedure helper cannot be used in a FreeBASIC constant expression.")
            For leftIndex As Long = 0 To typeLimit
                For rightIndex As Long = 0 To typeLimit
                    Dim resultIndex As Long
                    If leftIndex >= 8 OrElse rightIndex >= 8 Then
                        If leftIndex = 9 OrElse rightIndex = 9 Then
                            resultIndex = 9
                        Else
                            resultIndex = 8
                        End If
                    Else
                        Dim promotedLeft As Long = leftIndex
                        Dim promotedRight As Long = rightIndex
                        ' The C int type represented by FreeBASIC Long can hold
                        ' every signed or unsigned char and short value.
                        If promotedLeft < 4 Then promotedLeft = 4
                        If promotedRight < 4 Then promotedRight = 4
                        If typeSigned(promotedLeft) = typeSigned(promotedRight) Then
                            If typeRanks(promotedLeft) >= typeRanks(promotedRight) Then
                                resultIndex = promotedLeft
                            Else
                                resultIndex = promotedRight
                            End If
                        Else
                            Dim signedIndex As Long = promotedLeft
                            Dim unsignedIndex As Long = promotedRight
                            If typeSigned(promotedLeft) = 0 Then
                                signedIndex = promotedRight
                                unsignedIndex = promotedLeft
                            End If
                            If typeRanks(unsignedIndex) >= typeRanks(signedIndex) Then
                                resultIndex = unsignedIndex
                            ElseIf typeWidths(signedIndex) > typeWidths(unsignedIndex) Then
                                resultIndex = signedIndex
                            ElseIf signedIndex = 4 Then
                                resultIndex = 5
                            Else
                                resultIndex = 7
                            End If
                        End If
                    End If

                    Dim resultType As String = typeNames(resultIndex)
                    Dim freeBasicOperator As String = Chr(92)
                    If .operatorText = "%" Then
                        freeBasicOperator = "Mod"
                    ElseIf resultIndex >= 8 Then
                        freeBasicOperator = "/"
                    End If
                    WriteC2fbOutputLine(outputFile, _
                        "Private Function " & .functionName & " Overload(" & _
                        "ByVal leftValue As " & typeNames(leftIndex) & ", " & _
                        "ByVal rightValue As " & typeNames(rightIndex) & ") As " & _
                        resultType)
                    WriteC2fbOutputLine(outputFile, _
                        "    Return Cast(" & resultType & ", Cast(" & resultType & _
                        ", leftValue) " & freeBasicOperator & " Cast(" & _
                        resultType & ", rightValue))")
                    WriteC2fbOutputLine(outputFile, "End Function")
                Next
            Next
            WriteC2fbOutputLine(outputFile, "#endif")
            WriteC2fbOutputLine(outputFile, "")
        End With
    Next
End Sub

/' end of c2fb_generic_macro_output.bi '/
