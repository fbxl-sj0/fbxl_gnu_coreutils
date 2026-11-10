/'
    Project: C2FB generic body adapter

    File: c2fb_generic_body_adapter.bi

    Purpose:

        Normalize generic-body options and preprocess source files for shared lowering.

    Responsibilities:

        - Parse generic body type and replacement options.
        - Select included-header inline definitions when requested.
        - Build compiler requests for file and tree body conversion.
        - Preserve marker-aware source locations in body request options.
        - Route preprocessed bodies through the common body file converter.

    This file intentionally does NOT contain:

        - Generic header option parsing or declaration emission.
        - C statement lowering, type mapping, or candidate-file output.
'/

Private Sub ParseC2fbGenericBodyOptions( _
    ByRef translation As C2fbTranslationContext, _
    ByRef request As C2fbGenericBodyInputModel _
)
    ResetGenericTypeOverridesInPolicy(translation.genericC.policy)
    ResetGenericArraySizeOverridesInPolicy(translation.genericC.policy)
    ResetGenericSymbolRenamesInPolicy(translation.genericC.policy)
    ResetGenericSymbolExcludesInPolicy(translation.genericC.policy)
    translation.genericC.policy.generatedNamePrefix = "c2fb_"
    translation.genericC.policy.procedureNamePrefix = ""
    translation.genericC.policy.procedureNamePrefixMatched = 0
    ResetC2fbReplacementRules(translation.genericC.policy)
    request.compilerName = ""
    request.compilerOptions = ""
    request.bodyRequest.translationOptions.fbSourceDirectory = ""
    request.bodyRequest.translationOptions.fbSourceRecursive = 0
    request.bodyRequest.translationOptions.keepUnresolvedDependencies = 0
    request.bodyRequest.translationOptions.includeExistingBodies = 0
    request.bodyRequest.translationOptions.includeHeaderInlineBodies = 0
    request.bodyRequest.translationOptions.includeHeaderBodyNames = ""
    request.bodyRequest.translationOptions.includeIncludedCSourceBodies = 0
    request.bodyRequest.translationOptions.includeGlobalDefinitions = 0
    request.bodyRequest.translationOptions.profileTimings = 0
    request.bodyRequest.translationOptions.assumeSingleThreadedAtomics = 0
    request.bodyRequest.translationOptions.atomicMutexRuntime = 0
    request.bodyRequest.translationOptions.assumeZeroStaticAggregates = 0
    Dim expandedArguments As C2fbArgumentListModel
    Dim responseStack(0 To MAX_GENERIC_RESPONSE_DEPTH - 1) As String
    For sourceArgumentIndex As Long = 0 To request.argumentList.itemCount - 1
        Dim argumentError As String
        If AppendC2fbResponseArgument( _
            request.argumentList.values(sourceArgumentIndex), expandedArguments, _
            responseStack(), 0, "generic-header", argumentError) = 0 Then _
            ReportError(argumentError)
    Next

    Dim forwardedArguments As C2fbArgumentListModel
    Dim argumentIndex As Long = 0
    While argumentIndex < expandedArguments.itemCount
        Dim argumentText As String = expandedArguments.values(argumentIndex)
        If argumentText = "--replacement-file" Then
            argumentIndex += 1
            If argumentIndex >= expandedArguments.itemCount Then _
                ReportError("--replacement-file requires a file path")
            LoadC2fbReplacementRuleFile( _
                translation.genericC.policy, expandedArguments.values(argumentIndex))
        ElseIf Left(argumentText, Len("--replacement-file=")) = _
               "--replacement-file=" Then
            LoadC2fbReplacementRuleFile( _
                translation.genericC.policy, Mid(argumentText, Len("--replacement-file=") + 1))
        ElseIf argumentText = "--exclude-proc" Then
            argumentIndex += 1
            If argumentIndex >= expandedArguments.itemCount Then _
                ReportError("--exclude-proc requires a C function identifier or pattern")
            AddGenericSymbolExcludeInPolicy( _
                translation.genericC.policy, expandedArguments.values(argumentIndex), _
                C2FB_GENERIC_SYMBOL_EXCLUDE_PROCEDURE)
        ElseIf Left(argumentText, Len("--exclude-proc=")) = "--exclude-proc=" Then
            AddGenericSymbolExcludeInPolicy( _
                translation.genericC.policy, _
                Mid(argumentText, Len("--exclude-proc=") + 1), _
                C2FB_GENERIC_SYMBOL_EXCLUDE_PROCEDURE)
        ElseIf argumentText = "--rename-proc-prefix" Then
            argumentIndex += 1
            If argumentIndex >= expandedArguments.itemCount Then _
                ReportError("--rename-proc-prefix requires a FreeBASIC identifier prefix")
            SetGenericProcedureNamePrefixInPolicy( _
                translation.genericC.policy, expandedArguments.values(argumentIndex))
        ElseIf Left(argumentText, Len("--rename-proc-prefix=")) = _
               "--rename-proc-prefix=" Then
            SetGenericProcedureNamePrefixInPolicy( _
                translation.genericC.policy, _
                Mid(argumentText, Len("--rename-proc-prefix=") + 1))
        ElseIf argumentText = "--rename-proc" Then
            argumentIndex += 1
            If argumentIndex >= expandedArguments.itemCount Then _
                ReportError("--rename-proc requires CName=FbName")
            ParseGenericSymbolRenameArgumentInPolicy( _
                translation.genericC.policy, expandedArguments.values(argumentIndex), _
                C2FB_SYMBOL_RENAME_PROCEDURE)
        ElseIf Left(argumentText, Len("--rename-proc=")) = "--rename-proc=" Then
            ParseGenericSymbolRenameArgumentInPolicy( _
                translation.genericC.policy, _
                Mid(argumentText, Len("--rename-proc=") + 1), _
                C2FB_SYMBOL_RENAME_PROCEDURE)
        ElseIf argumentText = "--rename" Then
            argumentIndex += 1
            If argumentIndex >= expandedArguments.itemCount Then _
                ReportError("--rename requires CName=FbName")
            ParseGenericSymbolRenameArgumentInPolicy( _
                translation.genericC.policy, expandedArguments.values(argumentIndex))
        ElseIf Left(argumentText, 9) = "--rename=" Then
            ParseGenericSymbolRenameArgumentInPolicy( _
                translation.genericC.policy, Mid(argumentText, 10))
        ElseIf argumentText = "--reuse-static-object" Then
            argumentIndex += 1
            If argumentIndex >= expandedArguments.itemCount Then _
                ReportError("--reuse-static-object requires CName=FbName")
            ParseGenericSymbolRenameArgumentInPolicy( _
                translation.genericC.policy, _
                expandedArguments.values(argumentIndex), _
                C2FB_SYMBOL_RENAME_STATIC_OBJECT_REUSE)
        ElseIf Left(argumentText, Len("--reuse-static-object=")) = _
               "--reuse-static-object=" Then
            ParseGenericSymbolRenameArgumentInPolicy( _
                translation.genericC.policy, _
                Mid(argumentText, Len("--reuse-static-object=") + 1), _
                C2FB_SYMBOL_RENAME_STATIC_OBJECT_REUSE)
        ElseIf Left(argumentText, Len("--reuse-static-object-layout=")) = _
               "--reuse-static-object-layout=" Then
            ParseGenericStaticObjectLayoutArgumentInPolicy( _
                translation.genericC.policy, _
                Mid(argumentText, Len("--reuse-static-object-layout=") + 1))
        ElseIf argumentText = "--type-map" Then
            argumentIndex += 1
            If argumentIndex >= expandedArguments.itemCount Then _
                ReportError("--type-map requires CType=FreeBasicType")
            ParseGenericTypeMapArgumentInPolicy(translation.genericC.policy, expandedArguments.values(argumentIndex))
        ElseIf Left(argumentText, 11) = "--type-map=" Then
            ParseGenericTypeMapArgumentInPolicy(translation.genericC.policy, Mid(argumentText, 12))
        ElseIf argumentText = "--array-size" Then
            argumentIndex += 1
            If argumentIndex >= expandedArguments.itemCount Then _
                ReportError("--array-size requires CName=Count")
            ParseGenericArraySizeArgumentInPolicy( _
                translation.genericC.policy, expandedArguments.values(argumentIndex))
        ElseIf Left(argumentText, 13) = "--array-size=" Then
            ParseGenericArraySizeArgumentInPolicy( _
                translation.genericC.policy, Mid(argumentText, 14))
        ElseIf argumentText = "--target-profile" Then
            argumentIndex += 1
            If argumentIndex >= expandedArguments.itemCount Then _
                ReportError("--target-profile requires generic or sqlite")
            Select Case LCase(expandedArguments.values(argumentIndex))
            Case "generic"
                request.bodyRequest.translationOptions.targetProfile = _
                    C2FB_TARGET_GENERIC
            Case "sqlite"
                request.bodyRequest.translationOptions.targetProfile = _
                    C2FB_TARGET_SQLITE
            Case Else
                ReportError("--target-profile requires generic or sqlite")
            End Select
        ElseIf Left(argumentText, Len("--target-profile=")) = _
               "--target-profile=" Then
            Select Case LCase(Mid(argumentText, Len("--target-profile=") + 1))
            Case "generic"
                request.bodyRequest.translationOptions.targetProfile = _
                    C2FB_TARGET_GENERIC
            Case "sqlite"
                request.bodyRequest.translationOptions.targetProfile = _
                    C2FB_TARGET_SQLITE
            Case Else
                ReportError("--target-profile requires generic or sqlite")
            End Select
        ElseIf argumentText = "--typedef-hint" OrElse _
               argumentText = "-typedefhint" Then
            argumentIndex += 1
            If argumentIndex >= expandedArguments.itemCount Then _
                ReportError(argumentText & " requires a C typedef name")
            AddGenericTypedefHintInPolicy( _
                translation.genericC.policy, expandedArguments.values(argumentIndex))
        ElseIf Left(argumentText, 15) = "--typedef-hint=" Then
            AddGenericTypedefHintInPolicy( _
                translation.genericC.policy, Mid(argumentText, 16))
        ElseIf argumentText = "--fb-source-directory" OrElse _
           argumentText = "--fb-source-dir" Then
            argumentIndex += 1
            If argumentIndex >= expandedArguments.itemCount Then _
                ReportError(argumentText & " requires a directory")
            request.bodyRequest.translationOptions.fbSourceDirectory = expandedArguments.values(argumentIndex)
        ElseIf Left(argumentText, 22) = "--fb-source-directory=" Then
            request.bodyRequest.translationOptions.fbSourceDirectory = Mid(argumentText, 23)
        ElseIf Left(argumentText, 16) = "--fb-source-dir=" Then
            request.bodyRequest.translationOptions.fbSourceDirectory = Mid(argumentText, 17)
        ElseIf argumentText = "--fb-source-recursive" Then
            request.bodyRequest.translationOptions.fbSourceRecursive = -1
        ElseIf Left(argumentText, Len("--fb-source-recursive=")) = _
               "--fb-source-recursive=" Then
            Dim recursiveText As String = Mid( _
                argumentText, Len("--fb-source-recursive=") + 1)
            Dim recursiveValue As Long
            If recursiveText = "" OrElse _
               ParseC2fbBooleanValue(recursiveText, 0, recursiveValue) = 0 Then _
                ReportError("--fb-source-recursive must be 0 or 1")
            request.bodyRequest.translationOptions.fbSourceRecursive = _
                recursiveValue
        ElseIf argumentText = "--keep-unresolved" Then
            request.bodyRequest.translationOptions.keepUnresolvedDependencies = -1
        ElseIf Left(argumentText, 18) = "--keep-unresolved=" Then
            Dim keepText As String = Mid(argumentText, 19)
            Dim keepValue As Long
            If keepText = "" OrElse _
               ParseC2fbBooleanValue(keepText, 0, keepValue) = 0 Then _
                ReportError("--keep-unresolved must be 0 or 1")
            request.bodyRequest.translationOptions.keepUnresolvedDependencies = keepValue
        ElseIf argumentText = "--include-existing" Then
            request.bodyRequest.translationOptions.includeExistingBodies = -1
        ElseIf Left(argumentText, 19) = "--include-existing=" Then
            Dim includeText As String = Mid(argumentText, 20)
            Dim includeValue As Long
            If includeText = "" OrElse _
               ParseC2fbBooleanValue(includeText, 0, includeValue) = 0 Then _
                ReportError("--include-existing must be 0 or 1")
            request.bodyRequest.translationOptions.includeExistingBodies = includeValue
        ElseIf argumentText = "--include-header-inline-bodies" Then
            request.bodyRequest.translationOptions.includeHeaderInlineBodies = -1
        ElseIf Left(argumentText, Len("--include-header-inline-body=")) = _
               "--include-header-inline-body=" OrElse _
               Left(argumentText, Len("--include-header-body=")) = _
               "--include-header-body=" Then
            Dim optionPrefix As String = "--include-header-body="
            If Left(argumentText, Len("--include-header-inline-body=")) = _
               "--include-header-inline-body=" Then _
                optionPrefix = "--include-header-inline-body="
            Dim headerBodyName As String = Trim(Mid( _
                argumentText, Len(optionPrefix) + 1))
            If IsIdentifierToken(headerBodyName) = 0 Then _
                ReportError(optionPrefix & " requires a C function name")
            Dim headerBodyNameKey As String = _
                "|" & LCase(headerBodyName) & "|"
            If InStr( _
                request.bodyRequest.translationOptions.includeHeaderBodyNames, _
                headerBodyNameKey) = 0 Then _
                request.bodyRequest.translationOptions.includeHeaderBodyNames &= _
                    headerBodyNameKey
            request.bodyRequest.translationOptions.sourceMapMode = _
                C2FB_SOURCE_MAP_PREPROCESSOR_MARKERS
        ElseIf argumentText = "--include-global-definitions" Then
            request.bodyRequest.translationOptions.includeGlobalDefinitions = -1
            request.bodyRequest.translationOptions.sourceMapMode = _
                C2FB_SOURCE_MAP_PREPROCESSOR_MARKERS
        ElseIf Left(argumentText, Len("--include-global-definitions=")) = _
               "--include-global-definitions=" Then
            Dim globalDefinitionsText As String = Mid( _
                argumentText, Len("--include-global-definitions=") + 1)
            Dim includeGlobalDefinitionsValue As Long
            If globalDefinitionsText = "" OrElse _
               ParseC2fbBooleanValue( _
                   globalDefinitionsText, 0, includeGlobalDefinitionsValue) = 0 Then _
                ReportError("--include-global-definitions must be 0 or 1")
            request.bodyRequest.translationOptions.includeGlobalDefinitions = _
                includeGlobalDefinitionsValue
            If includeGlobalDefinitionsValue <> 0 Then _
                request.bodyRequest.translationOptions.sourceMapMode = _
                    C2FB_SOURCE_MAP_PREPROCESSOR_MARKERS
        ElseIf Left(argumentText, Len("--include-header-inline-bodies=")) = _
               "--include-header-inline-bodies=" Then
            Dim inlineText As String = Mid( _
                argumentText, Len("--include-header-inline-bodies=") + 1)
            Dim inlineValue As Long
            If inlineText = "" OrElse _
               ParseC2fbBooleanValue(inlineText, 0, inlineValue) = 0 Then _
                ReportError("--include-header-inline-bodies must be 0 or 1")
            request.bodyRequest.translationOptions.includeHeaderInlineBodies = _
                inlineValue
        ElseIf argumentText = "--include-included-c-source-bodies" Then
            request.bodyRequest.translationOptions.includeIncludedCSourceBodies = -1
            request.bodyRequest.translationOptions.sourceMapMode = _
                C2FB_SOURCE_MAP_PREPROCESSOR_MARKERS
        ElseIf Left(argumentText, Len("--include-included-c-source-bodies=")) = _
               "--include-included-c-source-bodies=" Then
            Dim includedCText As String = Mid( _
                argumentText, Len("--include-included-c-source-bodies=") + 1)
            Dim includeCValue As Long
            If includedCText = "" OrElse _
               ParseC2fbBooleanValue(includedCText, 0, includeCValue) = 0 Then _
                ReportError("--include-included-c-source-bodies must be 0 or 1")
            request.bodyRequest.translationOptions.includeIncludedCSourceBodies = _
                includeCValue
            If includeCValue <> 0 Then _
                request.bodyRequest.translationOptions.sourceMapMode = _
                    C2FB_SOURCE_MAP_PREPROCESSOR_MARKERS
        ElseIf argumentText = "--profile-timings" Then
            request.bodyRequest.translationOptions.profileTimings = -1
        ElseIf argumentText = "--assume-single-threaded-atomics" Then
            request.bodyRequest.translationOptions.assumeSingleThreadedAtomics = -1
        ElseIf Left(argumentText, Len("--assume-single-threaded-atomics=")) = _
               "--assume-single-threaded-atomics=" Then
            Dim atomicText As String = Mid( _
                argumentText, Len("--assume-single-threaded-atomics=") + 1)
            Dim atomicValue As Long
            If atomicText = "" OrElse _
               ParseC2fbBooleanValue(atomicText, 0, atomicValue) = 0 Then _
                ReportError("--assume-single-threaded-atomics must be 0 or 1")
            request.bodyRequest.translationOptions.assumeSingleThreadedAtomics = _
                atomicValue
        ElseIf argumentText = "--atomic-mutex" Then
            request.bodyRequest.translationOptions.atomicMutexRuntime = -1
        ElseIf Left(argumentText, Len("--atomic-mutex=")) = _
               "--atomic-mutex=" Then
            Dim atomicMutexText As String = Mid( _
                argumentText, Len("--atomic-mutex=") + 1)
            Dim atomicMutexValue As Long
            If atomicMutexText = "" OrElse _
               ParseC2fbBooleanValue(atomicMutexText, 0, atomicMutexValue) = 0 Then _
                ReportError("--atomic-mutex must be 0 or 1")
            request.bodyRequest.translationOptions.atomicMutexRuntime = _
                atomicMutexValue
        ElseIf argumentText = "--assume-zero-static-aggregates" Then
            request.bodyRequest.translationOptions.assumeZeroStaticAggregates = -1
        ElseIf Left(argumentText, Len("--assume-zero-static-aggregates=")) = _
               "--assume-zero-static-aggregates=" Then
            Dim zeroAggregateText As String = Mid( _
                argumentText, Len("--assume-zero-static-aggregates=") + 1)
            Dim zeroAggregateValue As Long
            If zeroAggregateText = "" OrElse _
               ParseC2fbBooleanValue( _
                   zeroAggregateText, 0, zeroAggregateValue) = 0 Then _
                ReportError("--assume-zero-static-aggregates must be 0 or 1")
            request.bodyRequest.translationOptions.assumeZeroStaticAggregates = _
                zeroAggregateValue
        Else
            If argumentText = "-o" Then _
                ReportError("the C preprocessor output path is managed by C2FB")
            If AppendC2fbArgumentValue( _
                forwardedArguments, argumentText, MAX_FUNCTIONS) = 0 Then _
                ReportError("generic C compiler arguments exceed the configured limit")
        End If
        argumentIndex += 1
    Wend

    If request.bodyRequest.translationOptions.assumeSingleThreadedAtomics <> 0 AndAlso _
       request.bodyRequest.translationOptions.atomicMutexRuntime <> 0 Then _
        ReportError("--atomic-mutex and --assume-single-threaded-atomics are mutually exclusive")

    BuildC2fbCompilerOptions( _
        forwardedArguments, "cc", request.compilerName, request.compilerOptions)
End Sub

Private Function WriteGenericAtomicMutexShim(ByVal shimPath As String) As Long
    Dim fileNumber As Long = FreeFile
    If Open(shimPath For Output As #fileNumber) <> 0 Then Return 0
    Print #fileNumber, "#include <stdatomic.h>"
    Print #fileNumber, "#define memory_order_relaxed 0"
    Print #fileNumber, "#define memory_order_consume 1"
    Print #fileNumber, "#define memory_order_acquire 2"
    Print #fileNumber, "#define memory_order_release 3"
    Print #fileNumber, "#define memory_order_acq_rel 4"
    Print #fileNumber, "#define memory_order_seq_cst 5"
    Print #fileNumber, "#undef atomic_load"
    Print #fileNumber, "#define atomic_load(object) __atomic_load_n((object), 5)"
    Print #fileNumber, "#undef atomic_load_explicit"
    Print #fileNumber, "#define atomic_load_explicit(object, order) __atomic_load_n((object), (order))"
    Print #fileNumber, "#undef atomic_store"
    Print #fileNumber, "#define atomic_store(object, value) __atomic_store_n((object), (value), 5)"
    Print #fileNumber, "#undef atomic_store_explicit"
    Print #fileNumber, "#define atomic_store_explicit(object, value, order) __atomic_store_n((object), (value), (order))"
    Print #fileNumber, "#undef atomic_exchange"
    Print #fileNumber, "#define atomic_exchange(object, value) __atomic_exchange_n((object), (value), 5)"
    Print #fileNumber, "#undef atomic_exchange_explicit"
    Print #fileNumber, "#define atomic_exchange_explicit(object, value, order) __atomic_exchange_n((object), (value), (order))"
    Print #fileNumber, "#undef atomic_fetch_add"
    Print #fileNumber, "#define atomic_fetch_add(object, value) __atomic_fetch_add((object), (value), 5)"
    Print #fileNumber, "#undef atomic_fetch_add_explicit"
    Print #fileNumber, "#define atomic_fetch_add_explicit(object, value, order) __atomic_fetch_add((object), (value), (order))"
    Print #fileNumber, "#undef atomic_fetch_sub"
    Print #fileNumber, "#define atomic_fetch_sub(object, value) __atomic_fetch_sub((object), (value), 5)"
    Print #fileNumber, "#undef atomic_fetch_sub_explicit"
    Print #fileNumber, "#define atomic_fetch_sub_explicit(object, value, order) __atomic_fetch_sub((object), (value), (order))"
    Print #fileNumber, "#undef atomic_fetch_or"
    Print #fileNumber, "#define atomic_fetch_or(object, value) __atomic_fetch_or((object), (value), 5)"
    Print #fileNumber, "#undef atomic_fetch_or_explicit"
    Print #fileNumber, "#define atomic_fetch_or_explicit(object, value, order) __atomic_fetch_or((object), (value), (order))"
    Print #fileNumber, "#undef atomic_fetch_and"
    Print #fileNumber, "#define atomic_fetch_and(object, value) __atomic_fetch_and((object), (value), 5)"
    Print #fileNumber, "#undef atomic_fetch_and_explicit"
    Print #fileNumber, "#define atomic_fetch_and_explicit(object, value, order) __atomic_fetch_and((object), (value), (order))"
    Print #fileNumber, "#undef atomic_fetch_xor"
    Print #fileNumber, "#define atomic_fetch_xor(object, value) __atomic_fetch_xor((object), (value), 5)"
    Print #fileNumber, "#undef atomic_fetch_xor_explicit"
    Print #fileNumber, "#define atomic_fetch_xor_explicit(object, value, order) __atomic_fetch_xor((object), (value), (order))"
    Print #fileNumber, "#undef atomic_compare_exchange_strong"
    Print #fileNumber, "#define atomic_compare_exchange_strong(object, expected, desired) __atomic_compare_exchange_n((object), (expected), (desired), 0, 5, 5)"
    Print #fileNumber, "#undef atomic_compare_exchange_weak"
    Print #fileNumber, "#define atomic_compare_exchange_weak(object, expected, desired) __atomic_compare_exchange_n((object), (expected), (desired), 1, 5, 5)"
    Print #fileNumber, "#undef atomic_compare_exchange_strong_explicit"
    Print #fileNumber, "#define atomic_compare_exchange_strong_explicit(object, expected, desired, success, failure) __atomic_compare_exchange_n((object), (expected), (desired), 0, (success), (failure))"
    Print #fileNumber, "#undef atomic_compare_exchange_weak_explicit"
    Print #fileNumber, "#define atomic_compare_exchange_weak_explicit(object, expected, desired, success, failure) __atomic_compare_exchange_n((object), (expected), (desired), 1, (success), (failure))"
    Print #fileNumber, "#undef atomic_thread_fence"
    Print #fileNumber, "#define atomic_thread_fence(order) __atomic_thread_fence((order))"
    Print #fileNumber, "#undef atomic_is_lock_free"
    Print #fileNumber, "#define atomic_is_lock_free(object) __atomic_is_lock_free(sizeof(*(object)), (object))"
    Print #fileNumber, "#undef atomic_flag_test_and_set"
    Print #fileNumber, "#define atomic_flag_test_and_set(object) __atomic_test_and_set((object), 5)"
    Print #fileNumber, "#undef atomic_flag_test_and_set_explicit"
    Print #fileNumber, "#define atomic_flag_test_and_set_explicit(object, order) __atomic_test_and_set((object), (order))"
    Print #fileNumber, "#undef atomic_flag_clear"
    Print #fileNumber, "#define atomic_flag_clear(object) __atomic_clear((object), 5)"
    Print #fileNumber, "#undef atomic_flag_clear_explicit"
    Print #fileNumber, "#define atomic_flag_clear_explicit(object, order) __atomic_clear((object), (order))"
    Close #fileNumber
    Return CInt(FileLengthIfPresent(shimPath) >= 0) * -1
End Function

Private Function CollectGenericBodyTargetMacros( _
    ByRef translation As C2fbTranslationContext, _
    ByRef request As C2fbGenericBodyInputModel, _
    ByVal temporaryPrefix As String, ByVal timePart As String, _
    ByVal atomicShimPath As String _
) As Long
    Dim probePath As String
    Dim macroTablePath As String
    For attempt As Long = 0 To 127
        probePath = temporaryPrefix & ".c2fb-body-abi-probe-" & _
                    timePart & "-" & Trim(Str(attempt)) & ".c"
        macroTablePath = temporaryPrefix & ".c2fb-body-abi-macros-" & _
                         timePart & "-" & Trim(Str(attempt)) & ".txt"
        If FileLengthIfPresent(probePath) < 0 AndAlso _
           FileLengthIfPresent(macroTablePath) < 0 Then Exit For
        probePath = ""
        macroTablePath = ""
    Next
    If probePath = "" OrElse macroTablePath = "" Then Return 0

    Dim probeFileNumber As Long = FreeFile
    If Open(probePath For Output As #probeFileNumber) <> 0 Then Return 0
    Close #probeFileNumber

    Dim preprocessRequest As C2fbPreprocessorRequestModel
    preprocessRequest.compilerName = request.compilerName
    preprocessRequest.compilerOptions = _
        "-E -dM -x c" & request.compilerOptions
    If atomicShimPath <> "" Then _
        preprocessRequest.compilerOptions &= _
            " -include " & ShellQuote(atomicShimPath)
    preprocessRequest.inputPath = probePath
    preprocessRequest.outputPath = macroTablePath
    Dim preprocessResult As C2fbPreprocessorResultModel
    If RunC2fbPreprocessor(preprocessRequest, preprocessResult) = 0 Then
        If FileLengthIfPresent(probePath) >= 0 Then Kill probePath
        If FileLengthIfPresent(macroTablePath) >= 0 Then Kill macroTablePath
        Return 0
    End If

    Dim collectionResult As Long = CollectGenericHeaderMacrosInContext( _
        translation, macroTablePath)
    If FileLengthIfPresent(probePath) >= 0 Then Kill probePath
    If FileLengthIfPresent(macroTablePath) >= 0 Then Kill macroTablePath
    Return collectionResult
End Function

Private Function PreprocessGenericBodyFile( _
    ByRef translation As C2fbTranslationContext, _
    ByVal inputPath As String, ByVal temporaryPrefix As String, _
    ByRef request As C2fbGenericBodyInputModel, _
    ByRef temporaryPath As String, _
    ByRef result As C2fbPreprocessorResultModel _
) As Long
    Dim timePart As String = Trim(Str(CULngInt(Timer * 1000)))
    temporaryPath = ""
    result.inputPath = inputPath
    result.outputPath = ""
    result.compilerStatus = 0
    result.failureReason = ""
    For attempt As Long = 0 To 127
        temporaryPath = temporaryPrefix & ".c2fb-body-preprocessed-" & timePart & "-" & _
                        Trim(Str(attempt)) & ".i"
        If FileLengthIfPresent(temporaryPath) < 0 Then Exit For
        temporaryPath = ""
    Next
    If temporaryPath = "" Then
        result.inputPath = inputPath
        result.failureReason = "cannot reserve a temporary preprocessed path"
        Return 0
    End If
    Dim atomicShimPath As String
    If request.bodyRequest.translationOptions.atomicMutexRuntime <> 0 Then
        For attempt As Long = 0 To 127
            atomicShimPath = temporaryPrefix & ".c2fb-atomic-mutex-" & _
                             timePart & "-" & Trim(Str(attempt)) & ".h"
            If FileLengthIfPresent(atomicShimPath) < 0 Then Exit For
            atomicShimPath = ""
        Next
        If atomicShimPath = "" OrElse _
           WriteGenericAtomicMutexShim(atomicShimPath) = 0 Then
            result.inputPath = inputPath
            result.failureReason = "cannot create the temporary atomic macro shim"
            temporaryPath = ""
            Return 0
        End If
    End If
    ' Keep compiler line markers so body conversion can distinguish source
    ' definitions from inline bodies pulled in from headers.
    Dim preprocessRequest As C2fbPreprocessorRequestModel
    preprocessRequest.compilerName = request.compilerName
    preprocessRequest.compilerOptions = "-E -x c" & request.compilerOptions
    If atomicShimPath <> "" Then _
        preprocessRequest.compilerOptions &= " -include " & ShellQuote(atomicShimPath)
    preprocessRequest.inputPath = inputPath
    preprocessRequest.outputPath = temporaryPath
    If RunC2fbPreprocessor(preprocessRequest, result) = 0 Then
        If atomicShimPath <> "" AndAlso FileLengthIfPresent(atomicShimPath) >= 0 Then _
            Kill atomicShimPath
        temporaryPath = ""
        Return 0
    End If
    ' The body lowering stage needs the C compiler's target widths to compute
    ' sizeof for mapped records. A body translation does not run generic-header
    ' preprocessing, so collect the compiler's predefined macro table here.
    ' Some preprocessors do not implement -dM; in that case ordinary bodies
    ' still translate and expressions requiring an unknown ABI size are skipped.
    CollectGenericBodyTargetMacros( _
        translation, request, temporaryPrefix, timePart, atomicShimPath)
    If atomicShimPath <> "" AndAlso FileLengthIfPresent(atomicShimPath) >= 0 Then _
        Kill atomicShimPath
    Return -1
End Function

Private Sub TranslateGenericBodyFile( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef request As C2fbGenericBodyInputModel _
)
    ParseC2fbGenericBodyOptions(translation, request)
    Dim temporaryPath As String
    Dim preprocessResult As C2fbPreprocessorResultModel
    If PreprocessGenericBodyFile( _
        translation, request.bodyRequest.sourcePath, request.bodyRequest.outputPath, _
        request, temporaryPath, _
        preprocessResult) = 0 Then
        ReportC2fbPreprocessorFailure( _
            translation, preprocessResult, "C preprocessing failed")
        End 1
    End If

    Dim bodyOptions As C2fbBodyTranslationOptions = _
        request.bodyRequest.translationOptions
    bodyOptions.sourceLabel = request.bodyRequest.sourcePath
    Dim fileRequest As C2fbBodyFileTranslationRequestModel
    fileRequest.inputPath = temporaryPath
    fileRequest.outputPath = request.bodyRequest.outputPath
    fileRequest.translationOptions = bodyOptions
    TranslateCBodyFile(translation, catalog, fileRequest)
    If FileLengthIfPresent(temporaryPath) >= 0 Then Kill temporaryPath
End Sub

Private Sub TranslateGenericBodyTree( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef request As C2fbGenericBodyInputModel _
)
    Dim sourceDirectory As String = request.bodyRequest.sourcePath
    Dim outputDirectory As String = request.bodyRequest.outputPath
    If sourceDirectory = "" OrElse outputDirectory = "" Then _
        ReportError("translate-simple-generic-tree-c requires source and output directories")
    If MakeDirectoryTree(outputDirectory) = 0 Then _
        ReportError("cannot create generic C body output directory: " & outputDirectory)

    ParseC2fbGenericBodyOptions(translation, request)
    Dim sourceFiles As C2fbSourceFileSetModel
    If AppendC2fbSourceDirectoryFiles( _
        sourceFiles, sourceDirectory, ".c", 0, -1) = 0 Then _
        ReportError("generic C source tree exceeds the configured file limit")
    If sourceFiles.itemCount = 0 Then _
        ReportError("generic C source directory contains no .c files: " & sourceDirectory)

    For fileIndex As Long = 0 To sourceFiles.itemCount - 1
        Dim fileName As String = sourceFiles.names(fileIndex)
        Dim inputPath As String = sourceDirectory & "/" & fileName
        Dim outputName As String = Left(fileName, Len(fileName) - 2) & _
                                   "_candidates.bas"
        Dim outputPath As String = outputDirectory & "/" & outputName
        Dim temporaryPath As String
        Dim preprocessResult As C2fbPreprocessorResultModel
        If PreprocessGenericBodyFile( _
            translation, inputPath, outputPath, request, temporaryPath, _
            preprocessResult) = 0 Then
            ReportC2fbPreprocessorFailure( _
                translation, preprocessResult, "C preprocessing failed")
            End 1
        End If
        Dim bodyOptions As C2fbBodyTranslationOptions = _
            request.bodyRequest.translationOptions
        bodyOptions.sourceLabel = inputPath
        Dim fileRequest As C2fbBodyFileTranslationRequestModel
        fileRequest.inputPath = temporaryPath
        fileRequest.outputPath = outputPath
        fileRequest.translationOptions = bodyOptions
        TranslateCBodyFile(translation, catalog, fileRequest)
        If FileLengthIfPresent(temporaryPath) >= 0 Then Kill temporaryPath
    Next
    Print "processed " & Trim(Str(sourceFiles.itemCount)) & _
          " preprocessed C source files into " & outputDirectory
End Sub

Private Sub TranslateGenericBodyRequest( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef request As C2fbGenericBodyInputModel _
)
    If request.bodyRequest.inputShape = C2FB_BODY_INPUT_TREE Then
        TranslateGenericBodyTree(translation, catalog, request)
    Else
        TranslateGenericBodyFile(translation, catalog, request)
    End If
End Sub

/' end of c2fb_generic_body_adapter.bi '/
