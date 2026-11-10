/'
    Project: C2FB generic header converter

    File: c2fb_generic_macro_collection.bi

    Purpose:

        Collect preprocessor macro definitions and their original source spans.

    Responsibilities:

        - Track active object-like and function-like macro definitions.
        - Retain preprocessed source order for caller-selected occurrence removal.
        - Preserve undefinition state for final header macro collection.
        - Detect restored macro states missing from the final macro table.
        - Match preprocessed definitions to source paths and line numbers.
        - Retain raw replacement text and tokenize only the final macro table.

    This file intentionally does NOT contain:

        - Macro expression lowering, replacement emission, or C preprocessing.
        - SQLite numeric-define policy or declaration layout conversion.
'/

Private Function GenericHeaderMacroIndexInContext( _
    ByRef translation As C2fbTranslationContext, ByVal sourceName As String _
) As Long
    Return C2fbStringIndexMapLookup( _
        translation.genericC.header.headerMacroIndex, sourceName)
End Function

Private Function GenericHeaderMacroOriginIndexInContext( _
    ByRef translation As C2fbTranslationContext, ByVal sourceName As String _
) As Long
    Return C2fbStringIndexMapLookup( _
        translation.genericC.header.macroOriginIndex, sourceName)
End Function

Private Function GenericHeaderMacroOriginIsCompilerOwned( _
    ByRef sourceLocation As C2fbSourceLocationModel _
) As Long
    If sourceLocation.path = "<built-in>" Then Return -1
    If sourceLocation.isSystemHeader = 0 Then Return 0

    ' GCC injects this standard-macro header before the requested source.
    ' Its definitions describe the selected C compiler, not the header API.
    Dim sourcePath As String = LCase(sourceLocation.path)
    For position As Long = 1 To Len(sourcePath)
        If Asc(sourcePath, position) = Asc(Chr(92)) Then _
            Mid(sourcePath, position, 1) = "/"
    Next
    Dim fileNameStart As Long = 1
    For position As Long = 1 To Len(sourcePath)
        If Mid(sourcePath, position, 1) = "/" Then _
            fileNameStart = position + 1
    Next
    Return CInt(Mid(sourcePath, fileNameStart) = "stdc-predef.h") * -1
End Function

Private Sub RecordGenericHeaderMacroOriginInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal sourceName As String, ByVal rawValue As String, _
    ByRef sourceLocation As C2fbSourceLocationModel _
)
    Dim sourceKey As String = C2fbReplacementTokenKey(sourceName & rawValue)
    If sourceKey = "" Then Exit Sub
    Dim originIndex As Long = GenericHeaderMacroOriginIndexInContext(translation, sourceName)
    If originIndex < 0 Then
        If translation.genericC.header.macroOriginCount >= MAX_GENERIC_HEADER_MACROS Then _
            ReportError("generic header exceeds the configured macro origin limit")
        If translation.genericC.header.macroOriginCount > _
           UBound(translation.genericC.header.macroOrigins) Then
            ReDim Preserve translation.genericC.header.macroOrigins( _
                0 To UBound(translation.genericC.header.macroOrigins) * 2 + 1)
        End If
        originIndex = translation.genericC.header.macroOriginCount
        If AddC2fbStringIndexMapEntry( _
            translation.genericC.header.macroOriginIndex, sourceName, _
            originIndex) <> -1 Then _
            ReportError("generic header exceeds the configured macro origin index limit")
        translation.genericC.header.macroOriginCount += 1
    End If
    With translation.genericC.header.macroOrigins(originIndex)
        .sourceName = sourceName
        .sourceKey = sourceKey
        .sourceLocation = sourceLocation
    End With
End Sub

Private Sub RecordGenericHeaderMacroOccurrenceInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef macroDefinition As C2fbMacroDefinitionModel _
)
    If translation.genericC.header.macroOccurrenceCount >= MAX_GENERIC_HEADER_MACROS Then _
        ReportError("generic header exceeds the configured macro occurrence limit")
    If translation.genericC.header.macroOccurrenceCount > _
       UBound(translation.genericC.header.macroOccurrences) Then _
        ReDim Preserve translation.genericC.header.macroOccurrences( _
            0 To UBound(translation.genericC.header.macroOccurrences) * 2 + 1)
    translation.genericC.header.macroOccurrences( _
        translation.genericC.header.macroOccurrenceCount) = macroDefinition
    translation.genericC.header.macroOccurrenceCount += 1
End Sub

Private Type C2fbGenericMacroDirectiveStateModel
    sourceName As String
    lastDirective As String
End Type

Private Function AddGenericMacroExpansionPatternsForRestoredMacros( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal preprocessedPath As String, ByVal macroTablePath As String _
) As Long
    Dim macroStates() As C2fbGenericMacroDirectiveStateModel
    ReDim macroStates(0 To 255)
    Dim macroStateCount As Long = 0
    Dim macroStateIndex As C2fbStringIndexMapModel
    ResetC2fbStringIndexMap(macroStateIndex)

    Dim lineReader As C2fbLogicalSourceLineReaderModel
    If OpenC2fbLogicalSourceLineReader(lineReader, preprocessedPath) = 0 Then
        Return 1
    End If
    Dim lineText As String
    Dim firstLine As Long
    Dim wasContinued As Long
    Dim isComplete As Long
    While ReadC2fbLogicalLine( _
        lineReader, lineText, firstLine, wasContinued, isComplete) <> 0
        If isComplete = 0 OrElse Left(LTrim(lineText), 1) <> "#" Then _
            Continue While
        Dim macro As C2fbMacroDefinitionModel
        If ParseC2fbMacroDirective(Trim(lineText), macro, 0) = 0 OrElse _
           (macro.directive <> "define" AndAlso _
            macro.directive <> "undef") Then Continue While
        Dim stateIndex As Long = C2fbStringIndexMapLookup( _
            macroStateIndex, macro.sourceName)
        If stateIndex < 0 Then
            If macroStateCount >= MAX_GENERIC_HEADER_MACROS Then
                CloseC2fbLogicalSourceLineReader(lineReader)
                Return 2
            End If
            If macroStateCount > UBound(macroStates) Then _
                ReDim Preserve macroStates( _
                    0 To UBound(macroStates) * 2 + 1)
            stateIndex = macroStateCount
            If AddC2fbStringIndexMapEntry( _
                macroStateIndex, macro.sourceName, stateIndex) <> -1 Then
                CloseC2fbLogicalSourceLineReader(lineReader)
                Return 3
            End If
            macroStates(stateIndex).sourceName = macro.sourceName
            macroStateCount += 1
        End If
        macroStates(stateIndex).lastDirective = macro.directive
    Wend
    CloseC2fbLogicalSourceLineReader(lineReader)

    Dim macroTableReader As C2fbTextFileLineReaderModel
    If OpenC2fbTextFileLineReader(macroTableReader, macroTablePath) = 0 Then
        Return 4
    End If
    While ReadC2fbTextFileLine(macroTableReader, lineText) <> 0
        If Left(LTrim(lineText), 1) <> "#" Then Continue While
        Dim macro As C2fbMacroDefinitionModel
        If ParseC2fbMacroDirective(Trim(lineText), macro, 0) = 0 OrElse _
           macro.directive <> "define" Then Continue While
        Dim stateIndex As Long = C2fbStringIndexMapLookup( _
            macroStateIndex, macro.sourceName)
        If stateIndex < 0 OrElse _
           macroStates(stateIndex).lastDirective <> "undef" Then Continue While

        ' Some preprocessors print a final #undef for a macro restored by
        ' _Pragma("pop_macro"), while their separate -dM table retains the
        ' temporary definition. Re-expand only those inconsistent names in
        ' source context so the generated binding follows the C compiler.
        AddGenericMacroExpansionPatternInPolicy( _
            policy, macro.sourceName, -1)
    Wend
    CloseC2fbTextFileLineReader(macroTableReader)
    Return 0
End Function

Private Sub SetGenericHeaderMacroInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByRef macroDefinition As C2fbMacroDefinitionModel _
)
    Dim macroIndex As Long = GenericHeaderMacroIndexInContext( _
        translation, macroDefinition.sourceName)
    If macroIndex < 0 Then
        If translation.genericC.header.headerMacroCount >= MAX_GENERIC_HEADER_MACROS Then _
            ReportError("generic header exceeds the configured macro limit")
        If translation.genericC.header.headerMacroCount > UBound(translation.genericC.header.headerMacros) Then _
            ReDim Preserve translation.genericC.header.headerMacros(0 To UBound(translation.genericC.header.headerMacros) * 2 + 1)
        macroIndex = translation.genericC.header.headerMacroCount
        If AddC2fbStringIndexMapEntry( _
            translation.genericC.header.headerMacroIndex, _
            macroDefinition.sourceName, macroIndex) <> -1 Then _
            ReportError("generic header exceeds the configured macro index limit")
        translation.genericC.header.headerMacroCount += 1
    End If
    translation.genericC.header.headerMacros(macroIndex).definition = macroDefinition
    With translation.genericC.header.headerMacros(macroIndex)
        .sourceRawValue = macroDefinition.rawValue
        .resolvedValue = ""
        .freeBasicName = ""
        .active = -1
        .privateName = 0
        ' Compiler predefined macros describe the C compilation target, not
        ' the header API. Keep them available for expression lowering, but
        ' require an explicit export request before emitting them.
        Dim macroOriginIndex As Long = _
            GenericHeaderMacroOriginIndexInContext( _
                translation, .definition.sourceName)
        Dim isCompilerBuiltin As Long = CInt(macroOriginIndex < 0) * -1
        If macroOriginIndex >= 0 Then
            isCompilerBuiltin = CInt(GenericHeaderMacroOriginIsCompilerOwned( _
                translation.genericC.header.macroOrigins( _
                    macroOriginIndex).sourceLocation) <> 0) * -1
        End If
        Dim reservedMacroExportRequested As Long = _
            GenericReservedMacroExportRequestedInPolicy( _
                translation.genericC.policy, .definition.sourceName)
        If isCompilerBuiltin <> 0 AndAlso _
           reservedMacroExportRequested = 0 Then .privateName = -1
        .emitted = 0
        .isString = 0
        .tokenConversionFailed = 0
    End With
End Sub

Private Sub CollectGenericHeaderMacroInContext( _
    ByRef translation As C2fbTranslationContext, _
    ByVal lineText As String, ByVal continued As Long, _
    ByRef sourceLocation As C2fbSourceLocationModel, _
    ByVal recordOrigin As Long = 0, ByVal inputOrder As LongInt = 0 _
)
    Dim macro As C2fbMacroDefinitionModel
    Dim tokenizeReplacement As Long = -1
    If recordOrigin <> 0 Then tokenizeReplacement = 0
    If ParseC2fbMacroDirective( _
        lineText, macro, tokenizeReplacement) = 0 Then Exit Sub
    If macro.directive = "undef" Then
        If recordOrigin <> 0 Then Exit Sub
        Dim macroIndex As Long = GenericHeaderMacroIndexInContext( _
            translation, macro.sourceName)
        If macroIndex >= 0 Then
            translation.genericC.header.headerMacros(macroIndex).active = 0
            translation.genericC.header.headerMacros(macroIndex).definition.rawValue = ""
            translation.genericC.header.headerMacros(macroIndex).sourceRawValue = ""
            Erase translation.genericC.header.headerMacros(macroIndex).definition.tokens
            translation.genericC.header.headerMacros(macroIndex).definition.tokenCount = 0
            translation.genericC.header.headerMacros(macroIndex).resolvedValue = ""
            translation.genericC.header.headerMacros(macroIndex).freeBasicName = ""
            translation.genericC.header.headerMacros(macroIndex).definition.functionLike = 0
            translation.genericC.header.headerMacros(macroIndex).definition.continued = 0
            translation.genericC.header.headerMacros(macroIndex).emitted = 0
            translation.genericC.header.headerMacros(macroIndex).isString = 0
            translation.genericC.header.headerMacros(macroIndex).tokenConversionFailed = 0
        End If
        Exit Sub
    End If
    macro.sourceLocation = sourceLocation
    macro.continued = continued
    macro.inputOrder = inputOrder
    If recordOrigin <> 0 Then
        RecordGenericHeaderMacroOccurrenceInContext(translation, macro)
        If continued = 0 Then
            RecordGenericHeaderMacroOriginInContext( _
                translation, macro.sourceName, macro.rawValue, macro.sourceLocation)
        End If
        Exit Sub
    End If
    SetGenericHeaderMacroInContext(translation, macro)
    Dim macroIndex As Long = GenericHeaderMacroIndexInContext( _
        translation, macro.sourceName)
    Dim sourceKey As String = C2fbReplacementTokenKey( _
        macro.sourceName & macro.rawValue)
    Dim originIndex As Long = GenericHeaderMacroOriginIndexInContext( _
        translation, macro.sourceName)
    If macroIndex >= 0 AndAlso originIndex >= 0 AndAlso _
       translation.genericC.header.macroOrigins(originIndex).sourceKey = sourceKey Then
        translation.genericC.header.headerMacros(macroIndex).definition.sourceLocation = _
            translation.genericC.header.macroOrigins(originIndex).sourceLocation
    End If
End Sub

Private Function CollectGenericHeaderMacroOriginsInContext( _
    ByRef translation As C2fbTranslationContext, ByVal inputPath As String _
) As Long
    ReDim translation.genericC.header.macroOrigins(0 To 255)
    translation.genericC.header.macroOriginCount = 0
    ResetC2fbStringIndexMap(translation.genericC.header.macroOriginIndex)
    ReDim translation.genericC.header.macroOccurrences(0 To 255)
    translation.genericC.header.macroOccurrenceCount = 0
    Dim lineReader As C2fbLogicalSourceLineReaderModel
    If OpenC2fbLogicalSourceLineReader(lineReader, inputPath) = 0 Then _
        ReportError("cannot read preprocessor macro origin input: " & inputPath)
    Dim lineText As String
    Dim firstLine As Long
    Dim wasContinued As Long
    Dim isComplete As Long
    While ReadC2fbLogicalLine( _
        lineReader, lineText, firstLine, wasContinued, isComplete) <> 0
        translation.sourceUnit.diagnosticState.currentSourceLocation.line = _
            C2fbLogicalSourceLineNumber(lineReader)
        If isComplete = 0 Then Continue While
        Dim trimmedLine As String = LTrim(lineText)
        If Left(trimmedLine, 1) <> "#" Then Continue While
        Dim directive As String = LTrim(Mid(trimmedLine, 2))
        Dim markerLocation As C2fbSourceLocationModel
        If CPreprocessorLineMarkerLocation( _
            directive, markerLocation) <> 0 Then
            SetC2fbLogicalSourceLineNumber( _
                lineReader, markerLocation.line - 1)
            markerLocation.line = C2fbLogicalSourceLineNumber(lineReader)
            translation.sourceUnit.diagnosticState.currentSourceLocation = markerLocation
        Else
            Dim sourceLocation As C2fbSourceLocationModel
            sourceLocation = translation.sourceUnit.diagnosticState.currentSourceLocation
            sourceLocation.line = firstLine
            Dim inputOrder As LongInt = _
                CLngInt(lineReader.physicalReader.textReader.physicalLineNumber) * _
                C2FB_SOURCE_ORDER_LINE_SCALE
            CollectGenericHeaderMacroInContext(translation, _
                trimmedLine, 0, sourceLocation, -1, inputOrder)
        End If
    Wend
    CloseC2fbLogicalSourceLineReader(lineReader)
    Return -1
End Function

Private Function CollectGenericHeaderMacrosInContext( _
    ByRef translation As C2fbTranslationContext, ByVal inputPath As String _
) As Long
    ReDim translation.genericC.header.headerMacros(0 To 255)
    translation.genericC.header.headerMacroCount = 0
    ResetC2fbStringIndexMap(translation.genericC.header.headerMacroIndex)
    ReDim translation.genericC.header.integerCastHelpers(0 To 7)
    translation.genericC.header.integerCastHelperCount = 0
    ReDim translation.genericC.header.operatorHelpers(0 To 1)
    translation.genericC.header.operatorHelperCount = 0
    Dim lineReader As C2fbLogicalSourceLineReaderModel
    If OpenC2fbLogicalSourceLineReader(lineReader, inputPath) = 0 Then _
        ReportError("cannot read preprocessor macro table: " & inputPath)
    Dim lineText As String
    Dim firstLine As Long
    Dim wasContinued As Long
    Dim isComplete As Long
    While ReadC2fbLogicalLine( _
        lineReader, lineText, firstLine, wasContinued, isComplete) <> 0
        If isComplete = 0 Then Continue While
        If Left(LTrim(lineText), 1) = "#" Then
            Dim sourceLocation As C2fbSourceLocationModel
            CollectGenericHeaderMacroInContext( _
                translation, Trim(lineText), wasContinued, sourceLocation)
        End If
    Wend
    CloseC2fbLogicalSourceLineReader(lineReader)
    Return -1
End Function

/' end of c2fb_generic_macro_collection.bi '/
