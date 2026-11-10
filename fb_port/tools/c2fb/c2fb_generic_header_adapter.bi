/'
    Project: C2FB generic header adapter

    File: c2fb_generic_header_adapter.bi

    Purpose:

        Normalize generic-header options and preprocess the requested C header.

    Responsibilities:

        - Apply generic header type, name, string, macro, source, and order policies.
        - Preserve explicitly mapped active C includes as FreeBASIC includes.
        - Forward compiler arguments and run declaration, macro-table, and
          selected-macro preprocessing.
        - Pass preprocessed inputs to the shared generic-header pipeline.
        - Remove temporary compiler outputs after conversion.

    This file intentionally does NOT contain:

        - Generic body options or statement translation.
        - C type syntax, macro lowering, or generated binding formatting.
'/

Private Function ReadC2fbGenericHeaderTitleFile( _
    ByVal inputPath As String, ByRef contents As String _
) As Long
    contents = ""
    Dim byteLength As LongInt = FileLengthIfPresent(inputPath)
    If byteLength < 0 OrElse byteLength > MAX_GENERIC_TITLE_FILE_BYTES Then Return 0
    Dim reader As C2fbTextFileLineReaderModel
    If OpenC2fbTextFileLineReader(reader, inputPath) = 0 Then Return 0
    Dim lineText As String
    Dim lineCount As Long = 0
    Dim contentLength As LongInt = 0
    While ReadC2fbTextFileLine(reader, lineText) <> 0
        contentLength += Len(lineText) + 1
        If contentLength > MAX_GENERIC_TITLE_FILE_BYTES OrElse _
           InStr(lineText, Chr(0)) > 0 Then
            CloseC2fbTextFileLineReader(reader)
            Return 0
        End If
        If lineCount > 0 Then contents &= Chr(10)
        contents &= lineText
        lineCount += 1
    Wend
    CloseC2fbTextFileLineReader(reader)
    Return -1
End Function

Private Sub TranslateGenericHeader( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef request As C2fbGenericHeaderInputModel _
)
    Dim inputPath As String = request.fileRequest.inputPath
    Dim outputPath As String = request.fileRequest.outputPath
    Dim titleLicensePath As String
    Dim titleTranslatorsPath As String
    Dim cppMode As Long = 0
    If ConfigureC2fbTranslationTarget( _
        translation, C2FB_TARGET_GENERIC, _
        C2FB_SOURCE_MAP_DISABLED) = 0 Then _
        ReportError("invalid generic header target context")
    ResetGenericTypeOverridesInPolicy(translation.genericC.policy)
    ResetGenericTypedefExpansionsInPolicy(translation.genericC.policy)
    ResetGenericSymbolRenamesInPolicy(translation.genericC.policy)
    translation.genericC.policy.procedureNamePrefix = ""
    translation.genericC.policy.procedureNamePrefixMatched = 0
    ResetGenericStringOverridesInPolicy(translation.genericC.policy)
    ResetGenericArraySizeOverridesInPolicy(translation.genericC.policy)
    ResetGenericFreeBasicIncludesInPolicy(translation.genericC.policy)
    ResetGenericFreeBasicLibrariesInPolicy(translation.genericC.policy)
    ResetGenericFreeBasicUndefinesInPolicy(translation.genericC.policy)
    ResetGenericPreservedIncludesInPolicy(translation.genericC.policy)
    ResetGenericIncludeRemovalsInPolicy(translation.genericC.policy)
    ResetGenericSymbolExcludesInPolicy(translation.genericC.policy)
    translation.genericC.policy.includeStaticObjects = 0
    translation.genericC.policy.privateStaticObjects = 0
    translation.genericC.policy.fixUnsizedArrays = 0
    translation.genericC.policy.fbfrogStringDefaults = 0
    translation.genericC.policy.fbfrogWStringSize = 0
    ResetGenericReservedMacroExportsInPolicy(translation.genericC.policy)
    ResetGenericOccurrenceRemovalPatternsInPolicy(translation.genericC.policy)
    ResetGenericTypeExcludesInPolicy(translation.genericC.policy)
    ResetGenericSourcePatternsInPolicy(translation.genericC.policy)
    ResetGenericMoveAboveInPolicy(translation.genericC.policy)
    ResetGenericDeclarationGuardsInPolicy(translation.genericC.policy)
    ResetGenericMacroTokenConversionsInPolicy(translation.genericC.policy)
    ResetGenericIntegerMacroAssumptionsInPolicy(translation.genericC.policy)
    ResetGenericDynamicMacroDivisionsInPolicy(translation.genericC.policy)
    ResetGenericMacroExpansionPatternsInPolicy(translation.genericC.policy)
    ResetGenericMacroInDefineExpansionPatternsInPolicy(translation.genericC.policy)
    ResetGenericMacroNoExpansionPatternsInPolicy(translation.genericC.policy)
    ResetGenericForwardDeclarationPatternsInPolicy(translation.genericC.policy)
    ResetGenericInlineMacroForcesInPolicy(translation.genericC.policy)
    ResetGenericInlineBodyDropsInPolicy(translation.genericC.policy)
    ResetC2fbReplacementRules(translation.genericC.policy)
    translation.genericC.policy.generatedNamePrefix = "c2fb_"
    translation.genericC.policy.removeEmptyReservedDefines = 0
    translation.genericC.policy.dropMacroBodyScopes = 0
    translation.genericC.policy.suppressInlineFunctionBodies = 0
    translation.genericC.policy.windowsMsCallingConvention = 0
    translation.genericC.policy.cLong32 = 0
    translation.genericC.header.title = ""
    translation.genericC.header.licenseText = ""
    translation.genericC.header.translatorsText = ""
    translation.genericC.header.verbosityLevel = 0
    translation.genericC.header.cppMode = 0
    translation.genericC.header.traditionalPreprocessorFallback = 0
    translation.genericC.header.traditionalPreprocessorFallbackEnabled = 0
    translation.genericC.header.preserveMissingIncludes = 0
    Dim forwardedArguments As C2fbArgumentListModel
    Dim argumentIndex As Long = 0
    While argumentIndex < request.argumentList.itemCount
        Dim argumentText As String = request.argumentList.values(argumentIndex)
        If argumentText = "--replacement-file" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--replacement-file requires a file path")
            LoadC2fbReplacementRuleFile( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, Len("--replacement-file=")) = _
               "--replacement-file=" Then
            LoadC2fbReplacementRuleFile( _
                translation.genericC.policy, Mid(argumentText, Len("--replacement-file=") + 1))
        ElseIf argumentText = "--c-include" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount OrElse _
               Trim(request.argumentList.values(argumentIndex)) = "" Then _
                ReportError("--c-include requires a C header path")
            If AppendC2fbArgumentValue( _
                forwardedArguments, "-include", MAX_GENERIC_COMPILER_ARGUMENTS) = 0 OrElse _
               AppendC2fbArgumentValue( _
                forwardedArguments, request.argumentList.values(argumentIndex), _
                MAX_GENERIC_COMPILER_ARGUMENTS) = 0 Then _
                ReportError("generic-header compiler arguments exceed the configured limit")
        ElseIf Left(argumentText, Len("--c-include=")) = "--c-include=" Then
            Dim includePath As String = Mid(argumentText, Len("--c-include=") + 1)
            If Trim(includePath) = "" Then ReportError("--c-include requires a C header path")
            If AppendC2fbArgumentValue( _
                forwardedArguments, "-include", MAX_GENERIC_COMPILER_ARGUMENTS) = 0 OrElse _
               AppendC2fbArgumentValue( _
                forwardedArguments, includePath, MAX_GENERIC_COMPILER_ARGUMENTS) = 0 Then _
                ReportError("generic-header compiler arguments exceed the configured limit")
        ElseIf argumentText = "--type-map" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--type-map requires CType=FreeBasicType")
            ParseGenericTypeMapArgumentInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, 11) = "--type-map=" Then
            ParseGenericTypeMapArgumentInPolicy(translation.genericC.policy, Mid(argumentText, 12))
        ElseIf argumentText = "--type-alignment" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--type-alignment requires CType=Bytes")
            ParseGenericTypeAlignmentArgumentInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, Len("--type-alignment=")) = "--type-alignment=" Then
            ParseGenericTypeAlignmentArgumentInPolicy( _
                translation.genericC.policy, Mid(argumentText, Len("--type-alignment=") + 1))
        ElseIf argumentText = "--typedef-hint" OrElse _
               argumentText = "-typedefhint" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError(argumentText & " requires a C typedef name")
            AddGenericTypedefHintInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, 15) = "--typedef-hint=" Then
            AddGenericTypedefHintInPolicy( _
                translation.genericC.policy, Mid(argumentText, 16))
        ElseIf argumentText = "--expand-type" OrElse argumentText = "-expand" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError(argumentText & " requires a C typedef name")
            AddGenericTypedefExpansionInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, 14) = "--expand-type=" Then
            AddGenericTypedefExpansionInPolicy( _
                translation.genericC.policy, Mid(argumentText, 15))
        ElseIf argumentText = "--rename-tag" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--rename-tag requires CName=FbName")
            ParseGenericSymbolRenameArgumentInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex), _
                C2FB_SYMBOL_RENAME_TAG)
        ElseIf Left(argumentText, Len("--rename-tag=")) = "--rename-tag=" Then
            ParseGenericSymbolRenameArgumentInPolicy( _
                translation.genericC.policy, _
                Mid(argumentText, Len("--rename-tag=") + 1), _
                C2FB_SYMBOL_RENAME_TAG)
        ElseIf argumentText = "--rename-typedef" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--rename-typedef requires CName=FbName")
            ParseGenericSymbolRenameArgumentInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex), _
                C2FB_SYMBOL_RENAME_TYPEDEF)
        ElseIf Left(argumentText, Len("--rename-typedef=")) = "--rename-typedef=" Then
            ParseGenericSymbolRenameArgumentInPolicy( _
                translation.genericC.policy, _
                Mid(argumentText, Len("--rename-typedef=") + 1), _
                C2FB_SYMBOL_RENAME_TYPEDEF)
        ElseIf argumentText = "--rename-proc-prefix" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--rename-proc-prefix requires a FreeBASIC identifier prefix")
            SetGenericProcedureNamePrefixInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, Len("--rename-proc-prefix=")) = _
               "--rename-proc-prefix=" Then
            SetGenericProcedureNamePrefixInPolicy( _
                translation.genericC.policy, _
                Mid(argumentText, Len("--rename-proc-prefix=") + 1))
        ElseIf argumentText = "--rename-proc" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--rename-proc requires CName=FbName")
            ParseGenericSymbolRenameArgumentInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex), _
                C2FB_SYMBOL_RENAME_PROCEDURE)
        ElseIf Left(argumentText, Len("--rename-proc=")) = "--rename-proc=" Then
            ParseGenericSymbolRenameArgumentInPolicy( _
                translation.genericC.policy, _
                Mid(argumentText, Len("--rename-proc=") + 1), _
                C2FB_SYMBOL_RENAME_PROCEDURE)
        ElseIf argumentText = "--rename-define" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--rename-define requires CName=FbName")
            ParseGenericSymbolRenameArgumentInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex), _
                C2FB_SYMBOL_RENAME_DEFINE)
        ElseIf Left(argumentText, Len("--rename-define=")) = "--rename-define=" Then
            ParseGenericSymbolRenameArgumentInPolicy( _
                translation.genericC.policy, _
                Mid(argumentText, Len("--rename-define=") + 1), _
                C2FB_SYMBOL_RENAME_DEFINE)
        ElseIf argumentText = "--rename-macro-param" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--rename-macro-param requires CName=FbName")
            ParseGenericSymbolRenameArgumentInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex), _
                C2FB_SYMBOL_RENAME_MACRO_PARAMETER)
        ElseIf Left(argumentText, Len("--rename-macro-param=")) = "--rename-macro-param=" Then
            ParseGenericSymbolRenameArgumentInPolicy( _
                translation.genericC.policy, _
                Mid(argumentText, Len("--rename-macro-param=") + 1), _
                C2FB_SYMBOL_RENAME_MACRO_PARAMETER)
        ElseIf argumentText = "--rename" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--rename requires CName=FbName")
            ParseGenericSymbolRenameArgumentInPolicy(translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf argumentText = "-rename_" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("-rename_ requires a C identifier")
            Dim sourceName As String = request.argumentList.values(argumentIndex)
            AddGenericSymbolRenameInPolicy( _
                translation.genericC.policy, sourceName, sourceName & "_")
        ElseIf Left(argumentText, 9) = "--rename=" Then
            ParseGenericSymbolRenameArgumentInPolicy(translation.genericC.policy, Mid(argumentText, 10))
        ElseIf argumentText = "--string" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--string requires a C declaration identifier")
            AddGenericStringOverrideInPolicy(translation.genericC.policy, request.argumentList.values(argumentIndex), 1)
        ElseIf Left(argumentText, 9) = "--string=" Then
            AddGenericStringOverrideInPolicy(translation.genericC.policy, Mid(argumentText, 10), 1)
        ElseIf argumentText = "--no-string" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--no-string requires a C declaration identifier")
            AddGenericStringOverrideInPolicy(translation.genericC.policy, request.argumentList.values(argumentIndex), -1)
        ElseIf Left(argumentText, 12) = "--no-string=" Then
            AddGenericStringOverrideInPolicy(translation.genericC.policy, Mid(argumentText, 13), -1)
        ElseIf argumentText = "--fbfrog-string-defaults" Then
            translation.genericC.policy.fbfrogStringDefaults = -1
        ElseIf Left(argumentText, Len("--fbfrog-wstring-size=")) = _
               "--fbfrog-wstring-size=" Then
            Dim widthText As String = _
                Mid(argumentText, Len("--fbfrog-wstring-size=") + 1)
            If widthText <> "1" AndAlso widthText <> "2" AndAlso _
               widthText <> "4" Then _
                ReportError("--fbfrog-wstring-size must be 1, 2, or 4")
            translation.genericC.policy.fbfrogWStringSize = Val(widthText)
        ElseIf argumentText = "--array-size" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--array-size requires CName=Count")
            ParseGenericArraySizeArgumentInPolicy(translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, 13) = "--array-size=" Then
            ParseGenericArraySizeArgumentInPolicy(translation.genericC.policy, Mid(argumentText, 14))
        ElseIf argumentText = "--fb-include" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--fb-include requires a FreeBASIC include path")
            AddGenericFreeBasicIncludeInPolicy(translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, 13) = "--fb-include=" Then
            AddGenericFreeBasicIncludeInPolicy(translation.genericC.policy, Mid(argumentText, 14))
        ElseIf argumentText = "--preserve-include" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--preserve-include requires CHeader=FreeBasicInclude")
            AddGenericPreservedIncludeMapInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, 19) = "--preserve-include=" Then
            AddGenericPreservedIncludeMapInPolicy( _
                translation.genericC.policy, Mid(argumentText, 20))
        ElseIf argumentText = "--preserve-missing-includes" Then
            translation.genericC.header.preserveMissingIncludes = -1
        ElseIf argumentText = "--traditional-cpp-fallback" Then
            translation.genericC.header.traditionalPreprocessorFallbackEnabled = -1
        ElseIf argumentText = "--remove-include" OrElse _
               argumentText = "-removeinclude" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError(argumentText & " requires a C header filename")
            AddGenericIncludeRemovalInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, Len("--remove-include=")) = "--remove-include=" Then
            AddGenericIncludeRemovalInPolicy( _
                translation.genericC.policy, Mid(argumentText, Len("--remove-include=") + 1))
        ElseIf argumentText = "--fb-library" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--fb-library requires a library name")
            AddGenericFreeBasicLibraryInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, 13) = "--fb-library=" Then
            AddGenericFreeBasicLibraryInPolicy( _
                translation.genericC.policy, Mid(argumentText, 14))
        ElseIf argumentText = "--undef" OrElse argumentText = "-undef" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError(argumentText & " requires a FreeBASIC macro identifier")
            AddGenericFreeBasicUndefineInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, 8) = "--undef=" Then
            AddGenericFreeBasicUndefineInPolicy( _
                translation.genericC.policy, Mid(argumentText, 9))
        ElseIf argumentText = "--remove-first" OrElse _
               argumentText = "-remove1st" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError(argumentText & " requires a C identifier pattern")
            AddGenericOccurrenceRemovalPatternInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex), -1)
        ElseIf Left(argumentText, Len("--remove-first=")) = "--remove-first=" Then
            AddGenericOccurrenceRemovalPatternInPolicy( _
                translation.genericC.policy, Mid(argumentText, Len("--remove-first=") + 1), -1)
        ElseIf argumentText = "--remove-repeated" OrElse _
               argumentText = "-remove2nd" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError(argumentText & " requires a C identifier pattern")
            AddGenericOccurrenceRemovalPatternInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex), 0)
        ElseIf Left(argumentText, Len("--remove-repeated=")) = "--remove-repeated=" Then
            AddGenericOccurrenceRemovalPatternInPolicy( _
                translation.genericC.policy, Mid(argumentText, Len("--remove-repeated=") + 1), 0)
        ElseIf argumentText = "--exclude-proc" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--exclude-proc requires a C function identifier or pattern")
            AddGenericSymbolExcludeInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex), _
                C2FB_GENERIC_SYMBOL_EXCLUDE_PROCEDURE)
        ElseIf Left(argumentText, 15) = "--exclude-proc=" Then
            AddGenericSymbolExcludeInPolicy( _
                translation.genericC.policy, Mid(argumentText, 16), _
                C2FB_GENERIC_SYMBOL_EXCLUDE_PROCEDURE)
        ElseIf argumentText = "--exclude-variable" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--exclude-variable requires a C object identifier or pattern")
            AddGenericSymbolExcludeInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex), _
                C2FB_GENERIC_SYMBOL_EXCLUDE_VARIABLE)
        ElseIf Left(argumentText, Len("--exclude-variable=")) = "--exclude-variable=" Then
            AddGenericSymbolExcludeInPolicy( _
                translation.genericC.policy, Mid(argumentText, Len("--exclude-variable=") + 1), _
                C2FB_GENERIC_SYMBOL_EXCLUDE_VARIABLE)
        ElseIf argumentText = "--exclude-define" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--exclude-define requires a C macro identifier or pattern")
            AddGenericSymbolExcludeInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex), _
                C2FB_GENERIC_SYMBOL_EXCLUDE_DEFINE)
        ElseIf Left(argumentText, Len("--exclude-define=")) = "--exclude-define=" Then
            AddGenericSymbolExcludeInPolicy( _
                translation.genericC.policy, Mid(argumentText, Len("--exclude-define=") + 1), _
                C2FB_GENERIC_SYMBOL_EXCLUDE_DEFINE)
        ElseIf argumentText = "--exclude" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--exclude requires a C identifier")
            AddGenericSymbolExcludeInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex), _
                C2FB_GENERIC_SYMBOL_EXCLUDE_ANY)
        ElseIf Left(argumentText, 10) = "--exclude=" Then
            AddGenericSymbolExcludeInPolicy( _
                translation.genericC.policy, Mid(argumentText, 11), _
                C2FB_GENERIC_SYMBOL_EXCLUDE_ANY)
        ElseIf argumentText = "--include-static-objects" Then
            translation.genericC.policy.includeStaticObjects = -1
        ElseIf argumentText = "--private-static-objects" Then
            translation.genericC.policy.privateStaticObjects = -1
        ElseIf argumentText = "--preserve-type-dependencies" Then
            translation.genericC.policy.preserveTypeDependencies = -1
        ElseIf argumentText = "--fix-unsized-arrays" Then
            translation.genericC.policy.fixUnsizedArrays = -1
        ElseIf argumentText = "--exclude-type" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--exclude-type requires a C type name")
            AddGenericTypeExcludeInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, 15) = "--exclude-type=" Then
            AddGenericTypeExcludeInPolicy( _
                translation.genericC.policy, Mid(argumentText, 16))
        ElseIf argumentText = "--emit-source" OrElse _
               argumentText = "--emit-declarations-from" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError(argumentText & " requires a source path pattern")
            AddGenericSourcePatternInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex), 0)
        ElseIf Left(argumentText, 14) = "--emit-source=" Then
            AddGenericSourcePatternInPolicy( _
                translation.genericC.policy, Mid(argumentText, 15), 0)
        ElseIf Left(argumentText, 25) = "--emit-declarations-from=" Then
            AddGenericSourcePatternInPolicy( _
                translation.genericC.policy, Mid(argumentText, 26), 0)
        ElseIf argumentText = "--exclude-source" OrElse _
               argumentText = "--exclude-declarations-from" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError(argumentText & " requires a source path pattern")
            AddGenericSourcePatternInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex), -1)
        ElseIf Left(argumentText, 17) = "--exclude-source=" Then
            AddGenericSourcePatternInPolicy( _
                translation.genericC.policy, Mid(argumentText, 18), -1)
        ElseIf Left(argumentText, 28) = "--exclude-declarations-from=" Then
            AddGenericSourcePatternInPolicy( _
                translation.genericC.policy, Mid(argumentText, 29), -1)
        ElseIf argumentText = "--source-route" Then
            If argumentIndex + 2 >= request.argumentList.itemCount Then _
                ReportError("--source-route requires a pattern and destination")
            AddGenericSourceRouteInPolicy( _
                translation.genericC.policy, _
                request.argumentList.values(argumentIndex + 1), _
                request.argumentList.values(argumentIndex + 2))
            argumentIndex += 2
        ElseIf argumentText = "--source-destination" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--source-destination requires a destination name")
            SetGenericSourceDestinationInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf argumentText = "--move-above" OrElse _
               argumentText = "-moveabove" Then
            If argumentIndex + 2 >= request.argumentList.itemCount Then _
                ReportError(argumentText & " requires Name ReferenceName")
            AddGenericMoveAboveInPolicy( _
                translation.genericC.policy, _
                request.argumentList.values(argumentIndex + 1), _
                request.argumentList.values(argumentIndex + 2))
            argumentIndex += 2
        ElseIf Left(argumentText, 13) = "--move-above=" Then
            ParseGenericMoveAboveArgumentInPolicy( _
                translation.genericC.policy, Mid(argumentText, 14))
        ElseIf argumentText = "--ifndef-decl" OrElse _
               argumentText = "-ifndefdecl" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError(argumentText & " requires a declaration name pattern")
            AddGenericDeclarationGuardPatternInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex), 0)
        ElseIf Left(argumentText, 14) = "--ifndef-decl=" Then
            AddGenericDeclarationGuardPatternInPolicy( _
                translation.genericC.policy, Mid(argumentText, 15), 0)
        ElseIf argumentText = "--undef-before-decl" OrElse _
               argumentText = "-undefbeforedecl" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError(argumentText & " requires a declaration name pattern")
            AddGenericDeclarationGuardPatternInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex), -1)
        ElseIf Left(argumentText, 20) = "--undef-before-decl=" Then
            AddGenericDeclarationGuardPatternInPolicy( _
                translation.genericC.policy, Mid(argumentText, 21), -1)
        ElseIf argumentText = "--convert-macro-tokens" OrElse _
               argumentText = "-convbodytokens" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError(argumentText & " requires a C macro name pattern")
            AddGenericMacroTokenConversionInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, 23) = "--convert-macro-tokens=" Then
            AddGenericMacroTokenConversionInPolicy( _
                translation.genericC.policy, Mid(argumentText, 24))
        ElseIf argumentText = "--assume-integer-macro" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--assume-integer-macro requires a C macro name pattern")
            AddGenericIntegerMacroAssumptionInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, 23) = "--assume-integer-macro=" Then
            AddGenericIntegerMacroAssumptionInPolicy( _
                translation.genericC.policy, Mid(argumentText, 24))
        ElseIf argumentText = "--dynamic-macro-division" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--dynamic-macro-division requires a C macro name pattern")
            AddGenericDynamicMacroDivisionInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, 25) = "--dynamic-macro-division=" Then
            AddGenericDynamicMacroDivisionInPolicy( _
                translation.genericC.policy, Mid(argumentText, 26))
        ElseIf argumentText = "--expand-macro" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError(argumentText & " requires a C macro name pattern")
            AddGenericMacroExpansionPatternInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, 15) = "--expand-macro=" Then
            AddGenericMacroExpansionPatternInPolicy( _
                translation.genericC.policy, Mid(argumentText, 16))
        ElseIf argumentText = "--expand-in-define" OrElse _
               argumentText = "-expandindefine" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError(argumentText & " requires a C macro name pattern")
            AddGenericMacroInDefineExpansionPatternInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, Len("--expand-in-define=")) = _
               "--expand-in-define=" Then
            AddGenericMacroInDefineExpansionPatternInPolicy( _
                translation.genericC.policy, _
                Mid(argumentText, Len("--expand-in-define=") + 1))
        ElseIf argumentText = "--no-expand-macro" OrElse _
               argumentText = "-noexpand" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError(argumentText & " requires a C macro name pattern")
            AddGenericMacroNoExpansionPatternInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, 18) = "--no-expand-macro=" Then
            AddGenericMacroNoExpansionPatternInPolicy( _
                translation.genericC.policy, Mid(argumentText, 19))
        ElseIf argumentText = "--forward-decl" OrElse _
               argumentText = "-addforwarddecl" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError(argumentText & " requires a C type name")
            AddGenericForwardDeclarationPatternInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, 15) = "--forward-decl=" Then
            AddGenericForwardDeclarationPatternInPolicy( _
                translation.genericC.policy, Mid(argumentText, 16))
        ElseIf argumentText = "--drop-inline-body" OrElse _
               argumentText = "-dropprocbody" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError(argumentText & " requires a C function name")
            AddGenericInlineBodyDropInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, 19) = "--drop-inline-body=" Then
            AddGenericInlineBodyDropInPolicy( _
                translation.genericC.policy, Mid(argumentText, 20))
        ElseIf argumentText = "--no-inline-bodies" OrElse _
               argumentText = "-nofunctionbodies" Then
            translation.genericC.policy.suppressInlineFunctionBodies = -1
        ElseIf argumentText = "--force-inline-macro" OrElse _
               argumentText = "-forcefunction2macro" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError(argumentText & " requires a C function name")
            AddGenericInlineMacroForceInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, 21) = "--force-inline-macro=" Then
            AddGenericInlineMacroForceInPolicy( _
                translation.genericC.policy, Mid(argumentText, 22))
        ElseIf Left(argumentText, 22) = "-forcefunction2macro=" Then
            AddGenericInlineMacroForceInPolicy( _
                translation.genericC.policy, Mid(argumentText, 23))
        ElseIf argumentText = "--remove-empty-reserved-defines" OrElse _
               argumentText = "-removeEmptyReservedDefines" Then
            translation.genericC.policy.removeEmptyReservedDefines = -1
        ElseIf argumentText = "--emit-reserved-defines" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--emit-reserved-defines requires a macro name or wildcard pattern")
            AddGenericReservedMacroExportInPolicy( _
                translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, Len("--emit-reserved-defines=")) = _
               "--emit-reserved-defines=" Then
            AddGenericReservedMacroExportInPolicy( _
                translation.genericC.policy, Mid(argumentText, Len("--emit-reserved-defines=") + 1))
        ElseIf argumentText = "--drop-macro-body-scopes" OrElse _
               argumentText = "-dropmacrobodyscopes" Then
            translation.genericC.policy.dropMacroBodyScopes = -1
        ElseIf argumentText = "--prefix" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--prefix requires a FreeBASIC identifier prefix")
            SetGenericNamePrefixInPolicy(translation.genericC.policy, request.argumentList.values(argumentIndex))
        ElseIf Left(argumentText, 9) = "--prefix=" Then
            SetGenericNamePrefixInPolicy(translation.genericC.policy, Mid(argumentText, 10))
        ElseIf argumentText = "--cxx" OrElse argumentText = "--language=c++" Then
            cppMode = -1
        ElseIf argumentText = "--windows-ms" OrElse argumentText = "-windowsms" Then
            translation.genericC.policy.windowsMsCallingConvention = -1
        ElseIf argumentText = "--clong32" OrElse argumentText = "-clong32" Then
            translation.genericC.policy.cLong32 = -1
        ElseIf argumentText = "-v" Then
            ' FBFrog only distinguishes normal and extra-debug verbosity.
            If translation.genericC.header.verbosityLevel < 2 Then _
                translation.genericC.header.verbosityLevel += 1
        ElseIf argumentText = "--title" OrElse argumentText = "-title" Then
            If translation.genericC.header.title <> "" Then _
                ReportError("generic-header title metadata was specified more than once")
            If argumentIndex + 3 >= request.argumentList.itemCount Then _
                ReportError(argumentText & " requires title, license file, and translators file")
            translation.genericC.header.title = Trim( _
                request.argumentList.values(argumentIndex + 1))
            titleLicensePath = request.argumentList.values(argumentIndex + 2)
            titleTranslatorsPath = request.argumentList.values(argumentIndex + 3)
            argumentIndex += 3
            ' Generic-header already has one positional output file. Consume
            ' fbfrog's optional destination when supplied; this invocation's
            ' output path is the destination.
            If argumentIndex + 1 < request.argumentList.itemCount AndAlso _
               LCase(Right(request.argumentList.values(argumentIndex + 1), 3)) = ".bi" Then _
                argumentIndex += 1
        ElseIf Left(argumentText, Len("--title=")) = "--title=" Then
            If translation.genericC.header.title <> "" Then _
                ReportError("generic-header title metadata was specified more than once")
            translation.genericC.header.title = Trim( _
                Mid(argumentText, Len("--title=") + 1))
        ElseIf argumentText = "--license-file" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--license-file requires a file path")
            If titleLicensePath <> "" Then _
                ReportError("--license-file was specified more than once")
            titleLicensePath = request.argumentList.values(argumentIndex)
        ElseIf Left(argumentText, Len("--license-file=")) = "--license-file=" Then
            If titleLicensePath <> "" Then _
                ReportError("--license-file was specified more than once")
            titleLicensePath = Mid(argumentText, Len("--license-file=") + 1)
        ElseIf argumentText = "--translators-file" Then
            argumentIndex += 1
            If argumentIndex >= request.argumentList.itemCount Then _
                ReportError("--translators-file requires a file path")
            If titleTranslatorsPath <> "" Then _
                ReportError("--translators-file was specified more than once")
            titleTranslatorsPath = request.argumentList.values(argumentIndex)
        ElseIf Left(argumentText, Len("--translators-file=")) = "--translators-file=" Then
            If titleTranslatorsPath <> "" Then _
                ReportError("--translators-file was specified more than once")
            titleTranslatorsPath = Mid(argumentText, Len("--translators-file=") + 1)
        Else
            If argumentText = "-x" AndAlso _
               argumentIndex + 1 < request.argumentList.itemCount AndAlso _
               LCase(request.argumentList.values(argumentIndex + 1)) = "c++" Then _
                cppMode = -1
            If Left(LCase(argumentText), Len("-std=c++")) = "-std=c++" OrElse _
               Left(LCase(argumentText), Len("-std=gnu++")) = "-std=gnu++" Then _
                cppMode = -1
            If AppendC2fbArgumentValue( _
                forwardedArguments, argumentText, _
                MAX_GENERIC_COMPILER_ARGUMENTS) = 0 Then _
                ReportError("generic-header compiler arguments exceed the configured limit")
        End If
        argumentIndex += 1
    Wend

    If translation.genericC.header.preserveMissingIncludes <> 0 AndAlso _
       translation.genericC.policy.preservedIncludeCount = 0 Then _
        ReportError("--preserve-missing-includes requires at least one --preserve-include mapping")
    If translation.genericC.policy.sourceRouteCount > 0 AndAlso _
       translation.genericC.policy.sourceDestination = "" Then _
        ReportError("--source-route requires --source-destination")
    If translation.genericC.policy.sourceRouteCount = 0 AndAlso _
       translation.genericC.policy.sourceDestination <> "" Then _
        ReportError("--source-destination requires at least one --source-route")

    Dim hasTitleMetadata As Long = CInt( _
        translation.genericC.header.title <> "" OrElse _
        titleLicensePath <> "" OrElse titleTranslatorsPath <> "")
    If hasTitleMetadata <> 0 Then
        If translation.genericC.header.title = "" OrElse _
           titleLicensePath = "" OrElse titleTranslatorsPath = "" Then _
            ReportError("title, license file, and translators file must be specified together")
        If InStr(translation.genericC.header.title, Chr(10)) > 0 OrElse _
           InStr(translation.genericC.header.title, Chr(13)) > 0 OrElse _
           InStr(translation.genericC.header.title, Chr(0)) > 0 Then _
            ReportError("generic-header title must be a single line of text")
        If ReadC2fbGenericHeaderTitleFile( _
            titleLicensePath, translation.genericC.header.licenseText) = 0 Then _
            ReportError("cannot read title license file within the configured size limit: " & titleLicensePath)
        If ReadC2fbGenericHeaderTitleFile( _
            titleTranslatorsPath, translation.genericC.header.translatorsText) = 0 Then _
            ReportError("cannot read title translators file within the configured size limit: " & titleTranslatorsPath)
    End If

    Dim compilerName As String
    Dim compilerOptions As String
    BuildC2fbCompilerOptions( _
        forwardedArguments, "cc", compilerName, compilerOptions)
    If Right(LCase(FileNameOnly(compilerName)), 2) = "++" Then cppMode = -1
    If cppMode <> 0 Then
        translation.genericC.header.cppMode = -1
        compilerOptions &= " " & ShellQuote("-x") & " " & ShellQuote("c++")
    End If

    WriteC2fbVerboseConsole( _
        translation.genericC.header.verbosityLevel, 1, _
        "generic-header input: " & inputPath)
    WriteC2fbVerboseConsole( _
        translation.genericC.header.verbosityLevel, 1, _
        "generic-header output: " & outputPath)
    WriteC2fbVerboseConsole( _
        translation.genericC.header.verbosityLevel, 1, _
        "preprocessor: " & compilerName)

    Dim temporaryPath As String
    Dim macroTablePath As String
    Dim macroExpansionProbePath As String
    Dim macroExpansionOutputPath As String
    Dim macroExpansionOverridesPath As String
    Dim missingIncludeStubDirectory As String
    Dim timePart As String = Trim(Str(CULngInt(Timer * 1000)))
    ' Reserve these paths even without a user expansion option. The two
    ' preprocessor dumps can disagree after a macro-state pragma, in which
    ' case the converter asks the compiler to re-expand that final macro.
    Dim hasMacroExpansion As Long = -1
    For attempt As Long = 0 To 127
        temporaryPath = outputPath & ".c2fb-preprocessed-" & timePart & "-" & _
                        Trim(Str(attempt)) & ".i"
        macroTablePath = outputPath & ".c2fb-macros-" & timePart & "-" & _
                         Trim(Str(attempt)) & ".i"
        If hasMacroExpansion <> 0 Then
            macroExpansionProbePath = outputPath & ".c2fb-expansion-probe-" & _
                timePart & "-" & Trim(Str(attempt)) & ".c"
            macroExpansionOutputPath = outputPath & ".c2fb-expansion-output-" & _
                timePart & "-" & Trim(Str(attempt)) & ".i"
            macroExpansionOverridesPath = outputPath & ".c2fb-expansion-overrides-" & _
                timePart & "-" & Trim(Str(attempt)) & ".i"
        End If
        If translation.genericC.header.preserveMissingIncludes <> 0 Then _
            missingIncludeStubDirectory = temporaryPath & ".include-stubs"
        If FileLengthIfPresent(temporaryPath) < 0 AndAlso _
           FileLengthIfPresent(macroTablePath) < 0 AndAlso _
           (translation.genericC.header.preserveMissingIncludes = 0 OrElse _
            (Dir(missingIncludeStubDirectory, C2FB_DIRECTORY_ATTRIBUTE) = "" AndAlso _
             Dir(missingIncludeStubDirectory) = "")) AndAlso _
           (hasMacroExpansion = 0 OrElse _
            (FileLengthIfPresent(macroExpansionProbePath) < 0 AndAlso _
             FileLengthIfPresent(macroExpansionOutputPath) < 0 AndAlso _
             FileLengthIfPresent(macroExpansionOverridesPath) < 0)) Then Exit For
        temporaryPath = ""
        macroTablePath = ""
        macroExpansionProbePath = ""
        macroExpansionOutputPath = ""
        macroExpansionOverridesPath = ""
        missingIncludeStubDirectory = ""
    Next
    If temporaryPath = "" OrElse macroTablePath = "" Then _
        ReportError("cannot reserve temporary paths for generic-header preprocessing")

    If translation.genericC.header.preserveMissingIncludes <> 0 Then
        Dim createdStubCount As Long
        Dim stubFailureReason As String
        If CreateGenericMissingIncludeStubs( _
            translation.genericC.policy, missingIncludeStubDirectory, _
            createdStubCount, stubFailureReason) = 0 Then _
            ReportError("cannot stage preserved missing C includes: " & stubFailureReason)
        compilerOptions &= " -idirafter " & ShellQuote(missingIncludeStubDirectory)
    End If

    WriteC2fbVerboseConsole( _
        translation.genericC.header.verbosityLevel, 2, _
        "preprocessor options: " & compilerOptions)

    Dim preprocessRequest As C2fbPreprocessorRequestModel
    preprocessRequest.compilerName = compilerName
    preprocessRequest.compilerOptions = "-E -dD -dI -x c" & compilerOptions
    preprocessRequest.inputPath = inputPath
    preprocessRequest.outputPath = temporaryPath
    Dim preprocessResult As C2fbPreprocessorResultModel
    If RunC2fbPreprocessor(preprocessRequest, preprocessResult) = 0 Then
        Dim traditionalFlagPresent As Long = CInt(InStr( _
            " " & LCase(compilerOptions) & " ", " -traditional-cpp ") > 0)
        If (translation.genericC.policy.macroTokenConversionCount > 0 OrElse _
            translation.genericC.header.traditionalPreprocessorFallbackEnabled <> 0) AndAlso _
           traditionalFlagPresent = 0 Then
            ' fbfrog token-conversion fixtures can contain non-standard # tokens
            ' in replacement lists. Other projects can opt into the retry when
            ' they require a preprocessor's traditional C/C++ expression rules.
            compilerOptions &= " -traditional-cpp"
            preprocessRequest.compilerOptions = "-E -dD -dI -x c" & compilerOptions
            If RunC2fbPreprocessor(preprocessRequest, preprocessResult) <> 0 Then _
                translation.genericC.header.traditionalPreprocessorFallback = -1
        End If
        If translation.genericC.header.traditionalPreprocessorFallback = 0 Then
            RemoveGenericMissingIncludeStubs( _
                translation.genericC.policy, missingIncludeStubDirectory)
            ReportC2fbPreprocessorFailure( _
                translation, preprocessResult, "C preprocessing failed")
            End 1
        End If
    End If

    WriteC2fbVerboseConsole( _
        translation.genericC.header.verbosityLevel, 1, _
        "C declaration preprocessing completed")

    preprocessRequest.compilerOptions = "-E -dM -x c" & compilerOptions
    preprocessRequest.outputPath = macroTablePath
    If RunC2fbPreprocessor(preprocessRequest, preprocessResult) = 0 Then
        If FileLengthIfPresent(temporaryPath) >= 0 Then Kill temporaryPath
        RemoveGenericMissingIncludeStubs( _
            translation.genericC.policy, missingIncludeStubDirectory)
        ReportC2fbPreprocessorFailure( _
            translation, preprocessResult, "C macro collection failed")
        End 1
    End If

    WriteC2fbVerboseConsole( _
        translation.genericC.header.verbosityLevel, 2, _
        "C macro preprocessing completed")

    Dim macroExpansionPreparationStatus As Long = _
        AddGenericMacroExpansionPatternsForRestoredMacros( _
            translation.genericC.policy, temporaryPath, macroTablePath)
    If macroExpansionPreparationStatus <> 0 Then
        If FileLengthIfPresent(temporaryPath) >= 0 Then Kill temporaryPath
        If FileLengthIfPresent(macroTablePath) >= 0 Then Kill macroTablePath
        RemoveGenericMissingIncludeStubs( _
            translation.genericC.policy, missingIncludeStubDirectory)
        Select Case macroExpansionPreparationStatus
        Case 1
            ReportError("cannot open preprocessed C input for macro restoration")
        Case 2
            ReportError("C macro directive states exceed the configured limit")
        Case 3
            ReportError("cannot index C macro directive state")
        Case 4
            ReportError("cannot open C macro table for restoration")
        Case Else
            ReportError("cannot reconcile preprocessor macro state")
        End Select
    End If

    If translation.genericC.policy.macroExpansionPatternCount > 0 Then
        If ExpandGenericHeaderMacrosWithPreprocessor( _
            translation.genericC.policy, compilerName, compilerOptions, _
            inputPath, macroTablePath, macroExpansionProbePath, _
            macroExpansionOutputPath, macroExpansionOverridesPath) = 0 Then
            If FileLengthIfPresent(temporaryPath) >= 0 Then Kill temporaryPath
            If FileLengthIfPresent(macroTablePath) >= 0 Then Kill macroTablePath
            If FileLengthIfPresent(macroExpansionProbePath) >= 0 Then _
                Kill macroExpansionProbePath
            If FileLengthIfPresent(macroExpansionOutputPath) >= 0 Then _
                Kill macroExpansionOutputPath
            If FileLengthIfPresent(macroExpansionOverridesPath) >= 0 Then _
                Kill macroExpansionOverridesPath
            RemoveGenericMissingIncludeStubs( _
                translation.genericC.policy, missingIncludeStubDirectory)
            ReportError("cannot expand selected C macro definitions")
        End If
    End If

    If translation.genericC.policy.macroInDefineExpansionPatternCount > 0 Then
        If ExpandMacroCallsInGenericHeaderDefinitionsWithPreprocessor( _
            translation.genericC.policy, compilerName, compilerOptions, _
            inputPath, macroTablePath, macroExpansionProbePath, _
            macroExpansionOutputPath, macroExpansionOverridesPath) = 0 Then
            If FileLengthIfPresent(temporaryPath) >= 0 Then Kill temporaryPath
            If FileLengthIfPresent(macroTablePath) >= 0 Then Kill macroTablePath
            If FileLengthIfPresent(macroExpansionProbePath) >= 0 Then _
                Kill macroExpansionProbePath
            If FileLengthIfPresent(macroExpansionOutputPath) >= 0 Then _
                Kill macroExpansionOutputPath
            If FileLengthIfPresent(macroExpansionOverridesPath) >= 0 Then _
                Kill macroExpansionOverridesPath
            RemoveGenericMissingIncludeStubs( _
                translation.genericC.policy, missingIncludeStubDirectory)
            ReportError("cannot prepare macro calls selected for in-definition expansion")
        End If
    End If

    ConvertGenericHeaderFile( _
        translation, catalog, inputPath, _
        temporaryPath, macroTablePath, macroExpansionOverridesPath, outputPath)
    If FileLengthIfPresent(temporaryPath) >= 0 Then Kill temporaryPath
    If FileLengthIfPresent(macroTablePath) >= 0 Then Kill macroTablePath
    If FileLengthIfPresent(macroExpansionProbePath) >= 0 Then _
        Kill macroExpansionProbePath
    If FileLengthIfPresent(macroExpansionOutputPath) >= 0 Then _
        Kill macroExpansionOutputPath
    If FileLengthIfPresent(macroExpansionOverridesPath) >= 0 Then _
        Kill macroExpansionOverridesPath
    RemoveGenericMissingIncludeStubs( _
        translation.genericC.policy, missingIncludeStubDirectory)
End Sub

/' end of c2fb_generic_header_adapter.bi '/
