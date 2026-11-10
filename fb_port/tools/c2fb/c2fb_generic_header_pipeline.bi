/'
    Project: C2FB generic header converter

    File: c2fb_generic_header_pipeline.bi

    Purpose:

        Assemble the generic-header translation passes and generated output.

    Responsibilities:

        - Emit collected typedefs, declarations, enums, records, and macros in ABI order.
        - Apply source-path filters while retaining imported types and macro dependencies for resolution.
        - Apply occurrence removals before declaration and macro lowering.
        - Apply compatible source declaration moves, including safe scalar and forward-tag hoists.
        - Open and close the generated header with its comments and preamble.
        - Report macro expansion, renames, and unused array-size hints.
        - Emit inline-function bodies as macros or public declarations per policy.
        - Emit private helpers requested while lowering function-like macros.
        - Emit private operator overloads after their generated macro definitions.
        - Pass one translation context and project catalog through all passes.

    This file intentionally does NOT contain:

        - C declaration parsing, record-layout validation, or macro lowering.
        - Generic command-line parsing or compiler process execution.
'/

Declare Sub WriteGenericHeaderInlineFunctionMacros( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourcePath As String, ByVal preprocessedPath As String, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    names() As String, ByRef nameCount As Long, _
    outputNames() As String, ByRef outputNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)

Private Function GenericHeaderSafeCommentLine(ByVal inputText As String) As String
    Dim safeText As String
    Dim position As Long = 1
    While position <= Len(inputText)
        If Mid(inputText, position, 2) = "'/" Then
            ' The generated block comment uses '/ as its closing delimiter.
            safeText &= "' /"
            position += 2
        Else
            safeText &= Mid(inputText, position, 1)
            position += 1
        End If
    Wend
    Return safeText
End Function

Private Function C2fbTextUsesLongDoubleType( _
    ByVal sourceText As String _
) As Long
    If InStr(LCase(sourceText), "long") = 0 Then Return 0
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(sourceText, tokens(), tokenCount)
    If tokenCount < 2 Then Return 0
    For tokenIndex As Long = 0 To tokenCount - 2
        If LCase(tokens(tokenIndex)) = "long" AndAlso _
           LCase(tokens(tokenIndex + 1)) = "double" Then Return -1
    Next
    Return 0
End Function

Private Function C2fbTextUsesHexFloatingLiteral( _
    ByVal sourceText As String _
) As Long
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(sourceText, tokens(), tokenCount)
    If tokenCount = 0 Then Return 0
    For tokenIndex As Long = 0 To tokenCount - 1
        Dim tokenText As String = LCase(tokens(tokenIndex))
        If Left(tokenText, 2) = "0x" AndAlso InStr(tokenText, "p") <> 0 Then _
            Return -1
    Next
    Return 0
End Function

Private Function GenericHeaderUsesCLongDouble( _
    ByRef translation As C2fbTranslationContext _
) As Long
    For overrideIndex As Long = 0 To _
        translation.genericC.policy.typeOverrideCount - 1
        If InStr(LCase(translation.genericC.policy.typeOverrides( _
                          overrideIndex).freeBasicType), "clongdouble") <> 0 Then _
            Return -1
    Next

    For declarationIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .removeFromGenericHeader = 0 AndAlso _
               GenericSourceIncludedInPolicy( _
                   translation.genericC.policy, _
                   .sourceSpan.startLocation.path) <> 0 Then
                If C2fbTextUsesLongDoubleType(.text) <> 0 Then Return -1
                If C2fbTextUsesHexFloatingLiteral(.text) <> 0 Then Return -1
                If .entryKind = C2FB_DECLARATION_RECORD Then
                    For fieldIndex As Long = 0 To .recordFieldCount - 1
                        If C2fbTextUsesLongDoubleType( _
                               .recordFields(fieldIndex).text) <> 0 Then Return -1
                    Next
                End If
            End If
        End With
    Next

    For macroIndex As Long = 0 To _
        translation.genericC.header.headerMacroCount - 1
        With translation.genericC.header.headerMacros(macroIndex)
            If .active = 0 OrElse .privateName <> 0 OrElse _
               GenericDefineExcludedInPolicy( _
                   translation.genericC.policy, .definition.sourceName) <> 0 OrElse _
               GenericSourceIncludedInPolicy( _
                   translation.genericC.policy, _
                   .definition.sourceLocation.path) = 0 Then Continue For
            If C2fbTextUsesLongDoubleType(.definition.rawValue) <> 0 OrElse _
               C2fbTextUsesLongDoubleType(.sourceRawValue) <> 0 OrElse _
               C2fbTextUsesLongDoubleType(.resolvedValue) <> 0 Then Return -1
        End With
    Next
    Return 0
End Function

Private Function AddGenericHeaderTitleTextLines( _
    ByRef fileComment As C2fbGeneratedFileCommentModel, _
    ByVal inputText As String, ByVal linePrefix As String _
) As Long
    Dim lineStart As Long = 1
    While lineStart <= Len(inputText)
        Dim lineEnd As Long = InStr(lineStart, inputText, Chr(10))
        If lineEnd = 0 Then lineEnd = Len(inputText) + 1
        Dim lineText As String = Mid(inputText, lineStart, lineEnd - lineStart)
        If Right(lineText, 1) = Chr(13) Then _
            lineText = Left(lineText, Len(lineText) - 1)
        If AddC2fbGeneratedFileCommentLine( _
            fileComment, linePrefix & GenericHeaderSafeCommentLine(lineText)) = 0 Then _
            Return 0
        lineStart = lineEnd + 1
    Wend
    Return -1
End Function

Declare Function GenericHeaderDeclarationDefinesRequiredTypeDependency( _
    ByRef translation As C2fbTranslationContext, _
    ByRef declaration As C2fbDeclarationModel _
) As Long

Private Sub EmitCollectedGenericHeaderDeclarations( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByVal passKind As C2fbGenericHeaderDeclarationPassKind, _
    names() As String, ByRef nameCount As Long, _
    outputNames() As String, ByRef outputNameCount As Long, _
    typeNames() As String, ByRef typeNameCount As Long, _
    ByRef conversionSummary As C2fbConversionSummaryModel _
)
    Select Case passKind
    Case C2FB_GENERIC_HEADER_PASS_INDEX_TYPEDEFS
    Case C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS
    Case C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS_AFTER_RECORDS
    Case C2FB_GENERIC_HEADER_PASS_EMIT_DECLARATIONS
    Case Else
        ReportError("invalid generic-header declaration pass")
    End Select

    For declarationIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .removeFromGenericHeader <> 0 Then Continue For
            Dim isPlainDeclaration As Long = CInt( _
                .entryKind = C2FB_DECLARATION_PLAIN)
            Dim isFunctionDeclaration As Long = CInt( _
                .entryKind = C2FB_DECLARATION_FUNCTION)
            If isPlainDeclaration = 0 AndAlso isFunctionDeclaration = 0 Then _
                Continue For
            If passKind <> C2FB_GENERIC_HEADER_PASS_INDEX_TYPEDEFS AndAlso _
               GenericSourceIncludedInPolicy( _
                translation.genericC.policy, .sourceSpan.startLocation.path) = 0 Then
                If passKind <> C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS OrElse _
                   translation.genericC.policy.preserveTypeDependencies = 0 OrElse _
                   GenericHeaderDeclarationDefinesRequiredTypeDependency( _
                       translation, translation.sourceUnit.declarations(declarationIndex)) = 0 Then _
                    Continue For
                End If
            If passKind = C2FB_GENERIC_HEADER_PASS_EMIT_DECLARATIONS AndAlso _
               GenericMoveAboveDeclarationWasHoisted( _
                translation, translation.sourceUnit.declarations(declarationIndex)) <> 0 Then _
                Continue For
            translation.sourceUnit.diagnosticState.currentSourceLocation.path = .sourceSpan.startLocation.path
            translation.sourceUnit.diagnosticState.currentSourceLocation.line = .sourceSpan.startLocation.line
            If passKind <> C2FB_GENERIC_HEADER_PASS_EMIT_DECLARATIONS AndAlso _
               isPlainDeclaration <> 0 Then
                If passKind = C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS AndAlso _
                   .tokenCount > 0 AndAlso .tokens(0) = "typedef" Then
                    EmitGenericHeaderHoistedExternalDeclarations( _
                        translation, catalog, _
                        translation.sourceUnit.declarations(declarationIndex), _
                        outputFile, names(), nameCount, outputNames(), _
                        outputNameCount, conversionSummary)
                End If
                EmitGenericTypedef(translation, catalog, _
                                   translation.sourceUnit.declarations(declarationIndex), _
                                   outputFile, typeNames(), typeNameCount, _
                                   outputNames(), outputNameCount, conversionSummary, passKind)
            End If
            If passKind = C2FB_GENERIC_HEADER_PASS_EMIT_DECLARATIONS Then
                If .unsupportedAssemblyName <> 0 Then
                    EmitC2fbSkipped(translation, outputFile, conversionSummary, _
                        "unsupported assembler symbol name", .text)
                    Continue For
                End If
                If isFunctionDeclaration <> 0 Then
                    EmitPrototypeModel( _
                        translation, catalog, _
                        translation.sourceUnit.declarations(declarationIndex), _
                        outputFile, names(), nameCount, outputNames(), _
                        outputNameCount, conversionSummary, _
                        C2FB_TYPE_MAPPING_GENERIC_HEADER)
                Else
                    EmitGenericHeaderDeclaration( _
                        translation, catalog, _
                        translation.sourceUnit.declarations(declarationIndex), _
                        outputFile, names(), nameCount, _
                        outputNames(), outputNameCount, conversionSummary)
                End If
            End If
        End With
    Next
End Sub

Private Function GenericHeaderTypeDependencyIndex( _
    ByRef translation As C2fbTranslationContext, ByVal sourceName As String _
) As Long
    For dependencyIndex As Long = 0 To _
        translation.genericC.header.requiredTypeDependencyCount - 1
        If translation.genericC.header.requiredTypeDependencies(dependencyIndex) = _
           sourceName Then Return dependencyIndex
    Next
    Return -1
End Function

Private Sub AddGenericHeaderTypeDependency( _
    ByRef translation As C2fbTranslationContext, ByVal sourceName As String, _
    ByRef changed As Long _
)
    If sourceName = "" OrElse _
       GenericHeaderTypeDependencyIndex(translation, sourceName) >= 0 Then Exit Sub
    If translation.genericC.header.requiredTypeDependencyCount >= _
       MAX_GENERIC_HEADER_OUTPUT_NAMES Then _
        ReportError("generic header type dependency count exceeds the configured limit")
    If translation.genericC.header.requiredTypeDependencyCount = 0 Then
        ReDim translation.genericC.header.requiredTypeDependencies(0 To 31)
    ElseIf translation.genericC.header.requiredTypeDependencyCount > _
           UBound(translation.genericC.header.requiredTypeDependencies) Then
        ReDim Preserve translation.genericC.header.requiredTypeDependencies( _
            0 To UBound(translation.genericC.header.requiredTypeDependencies) * 2 + 1)
    End If
    translation.genericC.header.requiredTypeDependencies( _
        translation.genericC.header.requiredTypeDependencyCount) = sourceName
    translation.genericC.header.requiredTypeDependencyCount += 1
    changed = -1
End Sub

Private Sub AddGenericHeaderTypeDependenciesFromTypeText( _
    ByRef translation As C2fbTranslationContext, ByVal typeText As String, _
    ByVal currentSourceName As String, ByRef changed As Long _
)
    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(typeText, tokens(), tokenCount)
    For tokenIndex As Long = 0 To tokenCount - 1
        For aliasIndex As Long = 0 To _
            translation.genericC.header.headerTypeAliasCount - 1
            With translation.genericC.header.headerTypeAliases(aliasIndex)
                If .isTag <> 0 OrElse .sourceName = currentSourceName OrElse _
                   .freeBasicName <> tokens(tokenIndex) Then Continue For
                AddGenericHeaderTypeDependency( _
                    translation, .sourceName, changed)
            End With
        Next
    Next
End Sub

Private Sub PrepareGenericHeaderTypeDependencies( _
    ByRef translation As C2fbTranslationContext _
)
    If translation.genericC.policy.preserveTypeDependencies = 0 Then Exit Sub
    translation.genericC.header.requiredTypeDependencyCount = 0
    ReDim translation.genericC.header.requiredTypeDependencies(0 To 31)

    For declarationIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind <> C2FB_DECLARATION_RECORD OrElse _
               .recordKind = C2FB_RECORD_ENUM OrElse _
               .removeFromGenericHeader <> 0 OrElse _
               GenericSourceIncludedInPolicy( _
                   translation.genericC.policy, _
                   .sourceSpan.startLocation.path) = 0 Then Continue For
            If declarationIndex <= UBound(translation.genericC.header.recordPlans) AndAlso _
               translation.genericC.header.recordPlans(declarationIndex).isExcluded <> 0 Then _
                Continue For
            For fieldIndex As Long = 0 To .recordFieldCount - 1
                With .recordFields(fieldIndex)
                    For tokenIndex As Long = 0 To .tokenCount - 1
                        For aliasIndex As Long = 0 To _
                            translation.genericC.header.headerTypeAliasCount - 1
                            With translation.genericC.header.headerTypeAliases(aliasIndex)
                                If .isTag = 0 AndAlso .sourceName = _
                                   translation.sourceUnit.declarations( _
                                       declarationIndex).recordFields(fieldIndex).tokens(tokenIndex) Then
                                    Dim changed As Long
                                    AddGenericHeaderTypeDependency( _
                                        translation, .sourceName, changed)
                                End If
                            End With
                        Next
                    Next
                End With
            Next
        End With
    Next

    For declarationIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If .entryKind <> C2FB_DECLARATION_PLAIN OrElse _
               .removeFromGenericHeader <> 0 OrElse _
               GenericSourceIncludedInPolicy( _
                   translation.genericC.policy, _
                   .sourceSpan.startLocation.path) = 0 Then Continue For
            Dim hasStaticStorage As Long = 0
            Dim isTypedef As Long = 0
            For tokenIndex As Long = 0 To .tokenCount - 1
                If .tokens(tokenIndex) = "static" Then hasStaticStorage = -1
                If .tokens(tokenIndex) = "typedef" Then isTypedef = -1
            Next
            If hasStaticStorage = 0 OrElse isTypedef <> 0 Then Continue For
            For tokenIndex As Long = 0 To .tokenCount - 1
                For aliasIndex As Long = 0 To _
                    translation.genericC.header.headerTypeAliasCount - 1
                    With translation.genericC.header.headerTypeAliases(aliasIndex)
                        If .isTag = 0 AndAlso .sourceName = _
                           translation.sourceUnit.declarations( _
                               declarationIndex).tokens(tokenIndex) Then
                            Dim changed As Long
                            AddGenericHeaderTypeDependency( _
                                translation, .sourceName, changed)
                        End If
                    End With
                Next
            Next
        End With
    Next

    Dim dependencyIndex As Long = 0
    While dependencyIndex < _
          translation.genericC.header.requiredTypeDependencyCount
        Dim sourceName As String = _
            translation.genericC.header.requiredTypeDependencies(dependencyIndex)
        For aliasIndex As Long = 0 To _
            translation.genericC.header.headerTypeAliasCount - 1
            With translation.genericC.header.headerTypeAliases(aliasIndex)
                If .isTag = 0 AndAlso .sourceName = sourceName Then
                    Dim changed As Long
                    AddGenericHeaderTypeDependenciesFromTypeText( _
                        translation, .baseType, sourceName, changed)
                    Exit For
                End If
            End With
        Next
        dependencyIndex += 1
    Wend
End Sub

Private Function GenericHeaderDeclarationDefinesRequiredTypeDependency( _
    ByRef translation As C2fbTranslationContext, _
    ByRef declaration As C2fbDeclarationModel _
) As Long
    If declaration.entryKind <> C2FB_DECLARATION_PLAIN OrElse _
       declaration.tokenCount < 3 OrElse declaration.tokens(0) <> "typedef" Then _
        Return 0
    Dim ranges() As C2fbTokenRangeModel
    Dim rangeCount As Long
    If SplitC2fbTokenList( _
        declaration.tokens(), 0, declaration.tokenCount - 1, _
        ranges(), rangeCount) = 0 OrElse rangeCount = 0 Then Return 0
    Dim commonType As String
    Dim commonTypeLastToken As Long
    If GenericTypedefCommonType( _
        declaration.tokens(), ranges(0).lastToken, _
        commonType, commonTypeLastToken) = 0 Then Return 0
    Dim commonTypeTokenCount As Long = commonTypeLastToken + 1
    For partIndex As Long = 0 To rangeCount - 1
        Dim itemTokens() As String
        Dim itemTokenCount As Long
        If BuildC2fbDeclaratorPartTokens( _
            declaration.tokens(), ranges(), rangeCount, partIndex, _
            commonTypeTokenCount, itemTokens(), itemTokenCount) = 0 Then Continue For
        Dim itemCommonType As String
        Dim sourceName As String
        Dim bindingOrder As String
        Dim itemCommonTypeTokenCount As Long
        If ParseGenericHeaderDeclaratorTokens( _
            itemTokens(), 0, itemTokenCount - 1, itemCommonType, _
            sourceName, bindingOrder, itemCommonTypeTokenCount) <> 0 AndAlso _
           GenericHeaderTypeDependencyIndex(translation, sourceName) >= 0 Then _
            Return -1
    Next
    Return 0
End Function

Private Sub WriteGenericSymbolRenameReportInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    If policy.symbolRenameCount = 0 AndAlso _
       policy.procedureNamePrefix = "" Then Exit Sub
    If policy.symbolRenameCount > 0 Then _
        WriteC2fbOutputLine(outputFile, "' c2fb rename mappings matched during name resolution:")
    If policy.procedureNamePrefix <> "" Then
        Dim prefixState As String = "unused"
        If policy.procedureNamePrefixMatched <> 0 Then prefixState = "matched"
        WriteC2fbOutputLine(outputFile, "' c2fb procedure rename prefix " & _
            prefixState & ": " & policy.procedureNamePrefix)
    End If
    For renameIndex As Long = 0 To policy.symbolRenameCount - 1
        Dim namespaceText As String
        Select Case policy.symbolRenames(renameIndex).renameNamespace
        Case C2FB_SYMBOL_RENAME_TAG: namespaceText = "tag "
        Case C2FB_SYMBOL_RENAME_TYPEDEF: namespaceText = "typedef "
        Case C2FB_SYMBOL_RENAME_PROCEDURE: namespaceText = "procedure "
        Case C2FB_SYMBOL_RENAME_DEFINE: namespaceText = "macro "
        Case C2FB_SYMBOL_RENAME_MACRO_PARAMETER: namespaceText = "macro parameter "
        End Select
        Dim stateText As String = "unused"
        If policy.symbolRenames(renameIndex).matched <> 0 Then stateText = "matched"
        If policy.symbolRenames(renameIndex).renameNamespace = _
           C2FB_SYMBOL_RENAME_GENERAL Then
            WriteC2fbOutputLine(outputFile, "' c2fb rename " & stateText & ": " & _
                policy.symbolRenames(renameIndex).sourceName & " -> " & _
                policy.symbolRenames(renameIndex).freeBasicName)
        Else
            WriteC2fbOutputLine(outputFile, "' c2fb " & namespaceText & _
                "rename " & stateText & ": " & _
                policy.symbolRenames(renameIndex).sourceName & " -> " & _
                policy.symbolRenames(renameIndex).freeBasicName)
        End If
    Next
End Sub

Private Sub WriteGenericTypedefExpansionReportInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    If policy.typedefExpansionCount = 0 Then Exit Sub
    WriteC2fbOutputLine(outputFile, "' c2fb typedef expansion requests:")
    For expansionIndex As Long = 0 To policy.typedefExpansionCount - 1
        Dim stateText As String = "unused"
        If policy.typedefExpansions(expansionIndex).matched <> 0 Then _
            stateText = "matched"
        WriteC2fbOutputLine(outputFile, "' c2fb expand-type " & stateText & ": " & _
            policy.typedefExpansions(expansionIndex).sourceName)
    Next
End Sub

Private Sub ReportUnusedGenericArraySizeOverridesInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    For overrideIndex As Long = 0 To policy.arraySizeOverrideCount - 1
        If policy.arraySizeOverrides(overrideIndex).applied = 0 Then
            WriteC2fbOutputLine( _
                outputFile, "' c2fb ignored --array-size hint for non-unsized external array: " & _
                policy.arraySizeOverrides(overrideIndex).sourceName)
        End If
    Next
End Sub

Private Function GenericHeaderDeclaresJmpBufType( _
    ByRef declaration As C2fbDeclarationModel _
) As Long
    If declaration.isTypedef <> 0 AndAlso _
       declaration.recordAlias = "jmp_buf" Then Return -1
    If declaration.entryKind <> C2FB_DECLARATION_PLAIN Then Return 0

    Dim tokens() As String
    Dim tokenCount As Long
    TokenizeCDeclaration(declaration.text, tokens(), tokenCount)
    If tokenCount < 2 OrElse tokens(0) <> "typedef" Then Return 0
    Dim typedefBody As String = Trim(Mid( _
        declaration.text, Len("typedef") + 1))
    If Right(typedefBody, 1) = ";" Then _
        typedefBody = RTrim(Left(typedefBody, Len(typedefBody) - 1))
    Dim parts() As String
    Dim partCount As Long
    If SplitSimpleCList(typedefBody, parts(), partCount) = 0 Then Return 0
    For partIndex As Long = 0 To partCount - 1
        Dim commonType As String
        Dim aliasName As String
        Dim bindingOrder As String
        If ParseGenericHeaderDeclarator( _
            "typedef " & parts(partIndex) & ";", commonType, _
            aliasName, bindingOrder) <> 0 AndAlso aliasName = "jmp_buf" Then _
            Return -1
    Next
    Return 0
End Function

Private Function GenericHeaderNeedsBuiltinJmpBufInclude( _
    ByRef translation As C2fbTranslationContext _
) As Long
    Dim mappedType As String = GenericTypeOverrideInPolicy( _
        translation.genericC.policy, "jmp_buf")
    If mappedType <> "" AndAlso mappedType <> "jmp_buf" Then Return 0

    Dim mentionsJmpBuf As Long = 0
    Dim declaresJmpBuf As Long = 0
    For declarationIndex As Long = 0 To _
        translation.sourceUnit.declarationCount - 1
        With translation.sourceUnit.declarations(declarationIndex)
            If GenericHeaderDeclaresJmpBufType( _
                translation.sourceUnit.declarations(declarationIndex)) <> 0 Then _
                declaresJmpBuf = -1
            Dim declarationTokens() As String
            Dim declarationTokenCount As Long
            Dim scanText As String = .text & " " & .recordTail
            TokenizeCDeclaration( _
                scanText, declarationTokens(), declarationTokenCount)
            For tokenIndex As Long = 0 To declarationTokenCount - 1
                If declarationTokens(tokenIndex) = "jmp_buf" Then _
                    mentionsJmpBuf = -1
            Next
        End With
    Next
    Return CInt(mentionsJmpBuf <> 0 AndAlso declaresJmpBuf = 0) * -1
End Function

Private Sub ReportGenericHeaderStageTiming( _
    ByVal verbosityLevel As Long, ByVal stageName As String, _
    ByRef stageStartedAt As Double _
)
    Dim currentTime As Double = Timer
    Dim elapsedSeconds As Double = currentTime - stageStartedAt
    If elapsedSeconds < 0 Then elapsedSeconds += 86400
    WriteC2fbVerboseConsole( _
        verbosityLevel, 2, _
        "generic-header stage timing: " & stageName & " completed in " & _
        Trim(Str(elapsedSeconds)) & " seconds")
    stageStartedAt = currentTime
End Sub

Private Sub ConvertGenericHeaderFile( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourcePath As String, ByVal inputPath As String, _
    ByVal macroInputPath As String, ByVal macroExpansionPath As String, _
    ByVal outputPath As String _
)
    Dim stageStartedAt As Double = Timer
    translation.genericC.header.rootSourcePath = sourcePath
    translation.genericC.header.usesCLongDouble = 0
    translation.sourceUnit.diagnosticState.currentSourceLocation.path = sourcePath
    translation.sourceUnit.diagnosticState.currentSourceLocation.line = 0
    If CollectGenericHeaderMacroOriginsInContext( _
        translation, inputPath) = 0 Then Return
    ReportGenericHeaderStageTiming( _
        translation.genericC.header.verbosityLevel, _
        "macro-origin collection", stageStartedAt)
    If CollectGenericHeaderPreservedIncludes( _
        translation, inputPath, sourcePath) = 0 Then Return
    ReportGenericHeaderStageTiming( _
        translation.genericC.header.verbosityLevel, _
        "include collection", stageStartedAt)
    Dim declarationScan As C2fbDeclarationScanRequestModel
    ConfigureC2fbTranslationUnitScanRequest( _
        declarationScan, inputPath, sourcePath)
    declarationScan.cppMode = translation.genericC.header.cppMode
    declarationScan.options.sourceMapMode = _
        C2FB_SOURCE_MAP_PREPROCESSOR_MARKERS
    declarationScan.options.collectLibraryPragmas = _
        C2FB_LIBRARY_PRAGMAS_COLLECT
    If CollectC2fbDeclarationsInSourceUnit( _
        translation.sourceUnit, declarationScan) = 0 Then Return
    ReportGenericHeaderStageTiming( _
        translation.genericC.header.verbosityLevel, _
        "declaration scan", stageStartedAt)
    For pragmaIndex As Long = 0 To _
        translation.sourceUnit.libraryPragmaCount - 1
        With translation.sourceUnit.libraryPragmas(pragmaIndex)
            If GenericSourceIncludedInPolicy( _
                translation.genericC.policy, .sourceLocation.path) <> 0 Then _
                AddGenericFreeBasicLibraryInPolicy( _
                    translation.genericC.policy, .libraryName)
        End With
    Next
    If CollectGenericHeaderMacrosInContext( _
        translation, macroInputPath) = 0 Then Return
    ReportGenericHeaderStageTiming( _
        translation.genericC.header.verbosityLevel, _
        "macro collection", stageStartedAt)
    WriteC2fbVerboseConsole( _
        translation.genericC.header.verbosityLevel, 2, _
        "collected " & Trim(Str(translation.sourceUnit.declarationCount)) & _
        " declaration slots and " & _
        Trim(Str(translation.genericC.header.headerMacroCount)) & _
        " macro definitions")
    ApplyGenericHeaderOccurrenceRemovals( _
        translation, inputPath, sourcePath)
    PrepareGenericHeaderFunctionPrototypeIndex(translation)
    If ExpandGenericHeaderRecordTypedefAliases(translation) = 0 Then Return
    ApplyGenericMoveAboveToSourceUnit(translation)
    If ApplyGenericMacroExpansionOverridesInContext( _
        translation, macroExpansionPath) = 0 Then _
        ReportError("cannot apply selected C macro expansion results")
    ReportGenericHeaderStageTiming( _
        translation.genericC.header.verbosityLevel, _
        "occurrence and alias preparation", stageStartedAt)
    For macroIndex As Long = 0 To _
        translation.genericC.header.headerMacroCount - 1
        With translation.genericC.header.headerMacros(macroIndex)
            If .active <> 0 AndAlso GenericSourceIncludedInPolicy( _
                translation.genericC.policy, .definition.sourceLocation.path) = 0 Then _
                ' Keep excluded object-like macros available to dependency
                ' lowering, but prevent them from becoming exported bindings.
                .privateName = -1
            End If
        End With
    Next
    translation.genericC.header.usesCLongDouble = _
        GenericHeaderUsesCLongDouble(translation)
    Dim longDoublePreambleEmitted As Long = _
        translation.genericC.header.usesCLongDouble
    ReportGenericHeaderStageTiming( _
        translation.genericC.header.verbosityLevel, _
        "macro visibility filtering", stageStartedAt)
    ReDim translation.genericC.header.headerTypeAliases(0 To 63)
    translation.genericC.header.headerTypeAliasCount = 0
    ResetC2fbStringIndexMap(translation.genericC.header.typeAliasIndex)
    ResetC2fbStringIndexMap(translation.genericC.header.freeBasicTypeAliasIndex)
    ReDim translation.genericC.header.enumMembers(0 To 255)
    translation.genericC.header.enumMemberCount = 0
    ResetC2fbStringIndexMap(translation.genericC.header.enumMemberIndex)
    ResetGenericHeaderSymbolsInContext(translation)
    ResetCBodyCallbackTypesInContext(translation)

    Dim fileOutput As C2fbGeneratedFileOutputModel
    If OpenC2fbGeneratedFileOutput(fileOutput, outputPath) = 0 Then _
        ReportError("cannot write FreeBASIC header: " & outputPath)
    Dim fileComment As C2fbGeneratedFileCommentModel
    ResetC2fbGeneratedFileComment(fileComment)
    If translation.genericC.header.title <> "" Then
        If AddC2fbGeneratedFileCommentLine( _
            fileComment, "    FreeBASIC binding for " & _
                GenericHeaderSafeCommentLine(translation.genericC.header.title)) = 0 OrElse _
           AddC2fbGeneratedFileCommentLine(fileComment, "") = 0 OrElse _
           AddC2fbGeneratedFileCommentLine( _
            fileComment, "    based on the C header files:") = 0 OrElse _
           AddGenericHeaderTitleTextLines( _
            fileComment, translation.genericC.header.licenseText, "      ") = 0 OrElse _
           AddC2fbGeneratedFileCommentLine(fileComment, "") = 0 OrElse _
           AddC2fbGeneratedFileCommentLine( _
            fileComment, "    translated to FreeBASIC by:") = 0 OrElse _
           AddGenericHeaderTitleTextLines( _
            fileComment, translation.genericC.header.translatorsText, "      ") = 0 OrElse _
           AddC2fbGeneratedFileCommentLine(fileComment, "") = 0 Then _
            ReportError("generic header title metadata exceeds the comment limit")
    End If
    If AddC2fbGeneratedFileCommentLine( _
        fileComment, "    Generated generic C ABI declarations") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
        fileComment, "    Source: " & sourcePath) = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
        fileComment, "    Generated by fb_tools/c2fb/c2fb.bas. Review before relying on a declaration.") = 0 Then _
        ReportError("generic header file comment exceeds its limit")
    Dim filePreamble As C2fbGeneratedFilePreambleModel
    If AddC2fbGeneratedFileIncludeOnce( _
        filePreamble, "crt/stddef.bi") = 0 OrElse _
       AddC2fbGeneratedFileIncludeOnce( _
        filePreamble, "crt/long.bi") = 0 Then _
        ReportError("generic header preamble exceeds its configured limit")
    If translation.genericC.header.usesCLongDouble <> 0 Then
        If AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "crt/longdouble.bi") = 0 Then _
            ReportError("generic header preamble exceeds its configured limit")
    End If
    If GenericHeaderNeedsBuiltinJmpBufInclude(translation) <> 0 Then
        If AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, "crt/setjmp.bi") = 0 Then _
            ReportError("generic header preamble exceeds its configured limit")
    End If
    For includeIndex As Long = 0 To translation.genericC.policy.freeBasicIncludeCount - 1
        If AddC2fbGeneratedFileIncludeOnce( _
            filePreamble, translation.genericC.policy.freeBasicIncludes(includeIndex)) = 0 Then _
            ReportError("invalid or excessive FreeBASIC include in generic header options")
    Next
    For libraryIndex As Long = 0 To translation.genericC.policy.freeBasicLibraryCount - 1
        If AddC2fbGeneratedFileLibrary( _
            filePreamble, translation.genericC.policy.freeBasicLibraries(libraryIndex)) = 0 Then _
            ReportError("invalid or excessive FreeBASIC library in generic header options")
    Next
    If translation.genericC.header.preserveMissingIncludes <> 0 Then
        If AddC2fbGeneratedFilePreambleComment( _
            filePreamble, "Exact mapped C includes may use empty preprocessing stubs; the mapped FreeBASIC includes must provide their declarations.") = 0 Then _
            ReportError("generic header preamble exceeds its configured limit")
    End If
    For undefIndex As Long = 0 To translation.genericC.policy.freeBasicUndefineCount - 1
        If AddC2fbGeneratedFileUndefine( _
            filePreamble, translation.genericC.policy.freeBasicUndefines(undefIndex)) = 0 Then _
            ReportError("invalid or excessive FreeBASIC macro undefine in generic header options")
    Next
    If translation.genericC.policy.generatedNamePrefix <> "c2fb_" Then
        If AddC2fbGeneratedFilePreambleComment( _
            filePreamble, "Generated identifiers use the supplied --prefix: " & _
            translation.genericC.policy.generatedNamePrefix) = 0 Then _
            ReportError("generic header preamble exceeds its configured limit")
    End If
    If AddC2fbGeneratedFilePreambleComment( _
        filePreamble, "User-defined scalar types and by-value records must be declared before generated declarations.") = 0 Then _
        ReportError("generic header preamble exceeds its configured limit")
    If translation.genericC.policy.typeOverrideCount > 0 Then
        If AddC2fbGeneratedFilePreambleComment( _
            filePreamble, "Types supplied through --type-map or --typedef-hint must be defined by an earlier include or declaration.") = 0 Then _
            ReportError("generic header preamble exceeds its configured limit")
    End If
    If translation.genericC.policy.symbolRenameCount > 0 Then
        If AddC2fbGeneratedFilePreambleComment( _
            filePreamble, "Rename mapping matches are listed after the generated declarations.") = 0 Then _
            ReportError("generic header preamble exceeds its configured limit")
    End If
    If translation.genericC.policy.moveAboveCount > 0 Then
        If AddC2fbGeneratedFilePreambleComment( _
            filePreamble, "Requested declaration moves stay within compatible phases, with safe scalar and forward-tag pointer hoists before simple typedefs.") = 0 Then _
            ReportError("generic header preamble exceeds its configured limit")
    End If
    If translation.genericC.policy.ifndefDeclarationPatternCount > 0 OrElse _
       translation.genericC.policy.undefBeforeDeclarationPatternCount > 0 Then
        If AddC2fbGeneratedFilePreambleComment( _
            filePreamble, "Matching generated bindings receive the requested #undef and #ifndef declaration guards.") = 0 Then _
            ReportError("generic header preamble exceeds its configured limit")
    End If
    If translation.genericC.policy.macroTokenConversionCount > 0 Then
        If AddC2fbGeneratedFilePreambleComment( _
            filePreamble, "Selected macros use token-by-token C-to-FreeBASIC conversion without expression validation.") = 0 Then _
            ReportError("generic header preamble exceeds its configured limit")
    End If
    If translation.genericC.header.traditionalPreprocessorFallback <> 0 Then
        If AddC2fbGeneratedFilePreambleComment( _
            filePreamble, "Traditional compiler preprocessing was used after standard preprocessing failed.") = 0 Then _
            ReportError("generic header preamble exceeds its configured limit")
    End If
    If translation.genericC.policy.sourceIncludeCount > 0 OrElse _
       translation.genericC.policy.sourceExcludeCount > 0 OrElse _
       translation.genericC.policy.sourceRouteCount > 0 Then
        If AddC2fbGeneratedFilePreambleComment( _
            filePreamble, "Source filters and ordered routes apply to declarations, record layouts, macros, inline functions, and library pragmas.") = 0 Then _
            ReportError("generic header preamble exceeds its configured limit")
        If AddC2fbGeneratedFilePreambleComment( _
            filePreamble, "Types omitted by source filters must be supplied by an earlier declaration, --fb-include, or a preserved C include mapping.") = 0 Then _
            ReportError("generic header preamble exceeds its configured limit")
    End If
    If translation.genericC.policy.inlineMacroForceCount > 0 Then
        If AddC2fbGeneratedFilePreambleComment( _
            filePreamble, "Forced inline macro matches are listed after the generated declarations.") = 0 Then _
            ReportError("generic header preamble exceeds its configured limit")
    End If
    If translation.genericC.policy.stringOverrideCount > 0 Then
        If AddC2fbGeneratedFilePreambleComment( _
            filePreamble, "Narrow and wide string conversion follows the supplied --string and --no-string names.") = 0 Then _
            ReportError("generic header preamble exceeds its configured limit")
    End If
    If translation.genericC.policy.fbfrogStringDefaults <> 0 Then
        If AddC2fbGeneratedFilePreambleComment( _
            filePreamble, "FBFrog-compatible string defaults are enabled for character typedefs and arrays.") = 0 Then _
            ReportError("generic header preamble exceeds its configured limit")
    End If
    If translation.genericC.policy.removeEmptyReservedDefines <> 0 Then
        If AddC2fbGeneratedFilePreambleComment( _
            filePreamble, "Empty reserved C defines (__* and _[A-Z]*) are omitted.") = 0 Then _
            ReportError("generic header preamble exceeds its configured limit")
    End If
    If translation.genericC.policy.replacementRuleCount > 0 Then
        If AddC2fbGeneratedFilePreambleComment( _
            filePreamble, "Explicit generic-header macro replacement rules were loaded.") = 0 Then _
            ReportError("generic header preamble exceeds its configured limit")
    End If
    For excludeIndex As Long = 0 To translation.genericC.policy.symbolExcludeCount - 1
        Dim exclusionText As String
        Select Case translation.genericC.policy.symbolExcludes(excludeIndex).excludeKind
        Case C2FB_GENERIC_SYMBOL_EXCLUDE_PROCEDURE
            exclusionText = "c2fb excludes requested procedure: "
        Case C2FB_GENERIC_SYMBOL_EXCLUDE_VARIABLE
            exclusionText = "c2fb excludes requested object: "
        Case C2FB_GENERIC_SYMBOL_EXCLUDE_DEFINE
            exclusionText = "c2fb excludes requested macro: "
        Case Else
            exclusionText = "c2fb excludes requested function, object, or macro: "
        End Select
        If AddC2fbGeneratedFilePreambleComment( _
            filePreamble, exclusionText & _
            translation.genericC.policy.symbolExcludes(excludeIndex).sourceName) = 0 Then _
            ReportError("generic header preamble exceeds its configured limit")
    Next
    If AddC2fbGeneratedFilePreambleBlank(filePreamble) = 0 Then _
        ReportError("generic header preamble exceeds its configured limit")
    WriteC2fbGeneratedFilePreamble(fileOutput, fileComment, filePreamble)
    WriteC2fbAbiTypeAliases(translation, fileOutput)

    Dim names() As String
    ReDim names(0 To 63)
    Dim nameCount As Long = 0
    Dim outputNames() As String
    ReDim outputNames(0 To 63)
    Dim outputNameCount As Long = 0
    ResetC2fbStringIndexMap(translation.genericC.header.outputNameIndex)
    translation.genericC.header.outputNameIndexedCount = 0
    ResetC2fbStringIndexMap(translation.genericC.header.sourceNameIndex)
    translation.genericC.header.sourceNameIndexedCount = 0
    Dim typeNames() As String
    ReDim typeNames(0 To 63)
    Dim typeNameCount As Long = 0
    ResetC2fbStringIndexMap(translation.genericC.header.typeNameIndex)
    translation.genericC.header.typeNameIndexedCount = 0
    Dim conversionSummary As C2fbConversionSummaryModel

    ' Record and typedef arrays may use supported enum values as bounds. Index
    ' those values before the layout passes evaluate the array extents.
    IndexGenericBodyEnumConstants(translation)

    PrepareGenericHeaderRecords( _
        translation, _
        typeNames(), typeNameCount, outputNames(), outputNameCount)
    PrepareGenericHeaderForwardDeclarations( _
        translation, typeNames(), typeNameCount, _
        outputNames(), outputNameCount)
    EmitCollectedGenericHeaderDeclarations( _
        translation, catalog, fileOutput, _
        C2FB_GENERIC_HEADER_PASS_INDEX_TYPEDEFS, _
        names(), nameCount, outputNames(), outputNameCount, _
        typeNames(), typeNameCount, conversionSummary)
    ReportGenericHeaderStageTiming( _
        translation.genericC.header.verbosityLevel, _
        "record and typedef preparation", stageStartedAt)
    PrepareGenericHeaderTypeDependencies(translation)
    ValidateGenericHeaderRecordLayouts( _
        translation, catalog, outputNames(), outputNameCount)
    ReportGenericHeaderStageTiming( _
        translation.genericC.header.verbosityLevel, _
        "record dependency and layout analysis", stageStartedAt)
    If ExpandGenericHeaderRecordTrailingDeclarators(translation) = 0 Then Return
    PrepareGenericHeaderForwardDeclarations( _
        translation, typeNames(), typeNameCount, _
        outputNames(), outputNameCount, -1)
    ReportGenericHeaderStageTiming( _
        translation.genericC.header.verbosityLevel, _
        "trailing declarator and forward preparation", stageStartedAt)
    WriteGenericHeaderRecordAliases(translation, fileOutput)
    WriteGenericHeaderForwardDeclarations(translation, fileOutput)
    ReportGenericHeaderStageTiming( _
        translation.genericC.header.verbosityLevel, _
        "record alias and forward emission", stageStartedAt)
    EmitCollectedGenericHeaderDeclarations( _
        translation, catalog, fileOutput, _
        C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS, _
        names(), nameCount, outputNames(), outputNameCount, _
        typeNames(), typeNameCount, conversionSummary)
    ReportGenericHeaderStageTiming( _
        translation.genericC.header.verbosityLevel, _
        "typedef emission before records", stageStartedAt)
    ' The enum writer builds emitted names in declaration order; clear the
    ' temporary all-source index, then restore filtered enum values afterward.
    ReDim translation.genericC.header.enumMembers(0 To 255)
    translation.genericC.header.enumMemberCount = 0
    ResetC2fbStringIndexMap(translation.genericC.header.enumMemberIndex)
    WriteGenericHeaderEnumConstants( _
        translation, catalog, fileOutput, outputNames(), outputNameCount, _
        conversionSummary)
    ' Enum values from filtered headers still size and initialize selected C objects.
    ' Rebuild the index because the header writer replaced it with emitted names.
    IndexGenericBodyEnumConstants(translation, 0, -1, 0, 2)
    ReportGenericHeaderStageTiming( _
        translation.genericC.header.verbosityLevel, _
        "enum constant emission", stageStartedAt)
    WriteGenericHeaderRecords(translation, fileOutput, conversionSummary)
    ReportGenericHeaderStageTiming( _
        translation.genericC.header.verbosityLevel, _
        "record emission", stageStartedAt)
    EmitCollectedGenericHeaderDeclarations( _
        translation, catalog, fileOutput, _
        C2FB_GENERIC_HEADER_PASS_EMIT_TYPEDEFS_AFTER_RECORDS, _
        names(), nameCount, outputNames(), outputNameCount, _
        typeNames(), typeNameCount, conversionSummary)
    ReportGenericHeaderStageTiming( _
        translation.genericC.header.verbosityLevel, _
        "typedef emission after records", stageStartedAt)
    EmitCollectedGenericHeaderDeclarations( _
        translation, catalog, fileOutput, _
        C2FB_GENERIC_HEADER_PASS_EMIT_DECLARATIONS, _
        names(), nameCount, outputNames(), outputNameCount, _
        typeNames(), typeNameCount, conversionSummary)
    ReportGenericHeaderStageTiming( _
        translation.genericC.header.verbosityLevel, _
        "declaration emission", stageStartedAt)
    WriteGenericHeaderTransientMacros( _
        translation, fileOutput, outputNames(), outputNameCount, conversionSummary)
    ReportGenericHeaderStageTiming( _
        translation.genericC.header.verbosityLevel, _
        "transient macro emission", stageStartedAt)
    ' -dM does not retain the defining file or line for each active macro.
    translation.sourceUnit.diagnosticState.currentSourceLocation.path = sourcePath
    translation.sourceUnit.diagnosticState.currentSourceLocation.line = 0
    WriteGenericHeaderMacros( _
        translation, catalog, fileOutput, _
        outputNames(), outputNameCount, conversionSummary)
    ReportGenericHeaderStageTiming( _
        translation.genericC.header.verbosityLevel, _
        "macro emission", stageStartedAt)
    WriteGenericHeaderInlineFunctionMacros( _
        translation, catalog, sourcePath, inputPath, fileOutput, _
        names(), nameCount, outputNames(), outputNameCount, conversionSummary)
    ReportGenericHeaderStageTiming( _
        translation.genericC.header.verbosityLevel, _
        "inline function macro emission", stageStartedAt)
    ' A hex-float macro can discover this helper after the preamble was written.
    ' The generated macro is expanded only after this included header finishes.
    If longDoublePreambleEmitted = 0 AndAlso _
       translation.genericC.header.usesCLongDouble <> 0 Then
        WriteC2fbGeneratedFileLine( _
            fileOutput, "#include once " & Chr(34) & "crt/longdouble.bi" & Chr(34))
        WriteC2fbGeneratedFileLine(fileOutput, "")
    End If
    WriteGenericHeaderIntegerCastHelpers(translation, fileOutput)
    WriteGenericHeaderOperatorHelpers(translation, fileOutput)
    ReportUnusedGenericArraySizeOverridesInPolicy( _
        translation.genericC.policy, fileOutput)
    WriteGenericSourcePatternReportInPolicy( _
        translation.genericC.policy, fileOutput)
    WriteGenericPreservedIncludeReportInPolicy( _
        translation.genericC.policy, fileOutput)
    WriteGenericIncludeRemovalReportInPolicy( _
        translation.genericC.policy, fileOutput)
    WriteGenericReservedMacroExportReportInPolicy( _
        translation.genericC.policy, fileOutput)
    WriteGenericMoveAboveReportInPolicy( _
        translation.genericC.policy, fileOutput)
    WriteGenericDeclarationGuardReportInPolicy( _
        translation.genericC.policy, fileOutput)
    WriteGenericMacroTokenConversionReportInPolicy( _
        translation.genericC.policy, fileOutput)
    WriteGenericIntegerMacroAssumptionReportInPolicy( _
        translation.genericC.policy, fileOutput)
    WriteGenericDynamicMacroDivisionReportInPolicy( _
        translation.genericC.policy, fileOutput)
    WriteGenericMacroExpansionReportInPolicy( _
        translation.genericC.policy, fileOutput)
    WriteGenericForwardDeclarationReportInPolicy( _
        translation.genericC.policy, fileOutput)
    WriteGenericSymbolRenameReportInPolicy(translation.genericC.policy, fileOutput)
    WriteGenericTypedefExpansionReportInPolicy(translation.genericC.policy, fileOutput)
    ReportGenericHeaderStageTiming( _
        translation.genericC.header.verbosityLevel, _
        "helper and report emission", stageStartedAt)
    If translation.body.generatedStaticDeclarations <> "" Then
        ' File-scope compound literals keep private static byte storage for
        ' module-static pointer initializers emitted earlier in this include.
        WriteC2fbOutputText( _
            fileOutput, translation.body.generatedStaticDeclarations)
    End If
    WriteC2fbGeneratedFileEndMarker(fileOutput)
    CloseC2fbGeneratedFileOutput(fileOutput)
    If C2fbGeneratedFileOutputHasFailed(fileOutput) <> 0 Then _
        ReportError(C2fbGeneratedFileOutputFailureMessage( _
            fileOutput, "cannot finish FreeBASIC header: " & outputPath))
    Dim moduleStaticSummary As String
    If conversionSummary.genericHeader.moduleStaticObjectCount > 0 Then _
        moduleStaticSummary = " and " & _
            Trim(Str(conversionSummary.genericHeader.moduleStaticObjectCount)) & _
            " module-static objects"
    Print "converted " & Trim(Str(conversionSummary.convertedCount)) & _
        " function declarations and " & _
        Trim(Str(conversionSummary.genericHeader.externalObjectCount)) & _
        " external objects" & moduleStaticSummary & "; emitted " & _
        Trim(Str(conversionSummary.genericHeader.recordLayoutCount)) & " record layouts, " & _
        Trim(Str(conversionSummary.genericHeader.integerMacroCount)) & " integer, " & _
        Trim(Str(conversionSummary.genericHeader.floatingMacroCount)) & " floating, " & _
        Trim(Str(conversionSummary.genericHeader.pointerCastMacroCount)) & " pointer-cast, " & _
        Trim(Str(conversionSummary.genericHeader.typeMacroCount)) & " type, " & _
        Trim(Str(conversionSummary.genericHeader.stringMacroCount)) & " string, " & _
        Trim(Str(conversionSummary.genericHeader.aliasMacroCount)) & " alias, and " & _
        Trim(Str(conversionSummary.genericHeader.functionMacroCount)) & " function-like, " & _
        Trim(Str(conversionSummary.genericHeader.callMacroCount)) & " direct-call, " & _
        Trim(Str(conversionSummary.genericHeader.tokenSequenceMacroCount)) & " token-sequence, " & _
        Trim(Str(conversionSummary.genericHeader.initializerMacroCount)) & " initializer, and " & _
        Trim(Str(conversionSummary.genericHeader.statementMacroCount)) & " statement, and " & _
        Trim(Str(conversionSummary.genericHeader.emptyMacroCount)) & " empty macros; token-converted " & _
        Trim(Str(conversionSummary.genericHeader.tokenMacroConversionCount)) & " selected macros; applied " & _
        Trim(Str(conversionSummary.genericHeader.customMacroReplacementCount)) & " custom macro replacement rules; skipped " & _
        Trim(Str(conversionSummary.skippedCount)) & " unsupported declarations or macro expressions; output " & outputPath
End Sub

/' end of c2fb_generic_header_pipeline.bi '/
