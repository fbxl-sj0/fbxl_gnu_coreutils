/'
    Project: C2FB

    File: c2fb_inputs.bi

    Purpose:

        Normalize command-line inputs into typed C2FB requests.

    Responsibilities:

        - Populate simple-body, generic-header/body, and preprocessed-tree
          request models.
        - Validate shared boolean option values.
        - Select any supported command mode and return its typed request model.

    This file intentionally does NOT contain:

        - C preprocessing, declaration scanning, or source parsing.
        - Mode-specific compiler option interpretation or translation policy.
'/

Private Function ParseC2fbBooleanValue( _
    ByVal valueText As String, ByVal defaultValue As Long, _
    ByRef parsedValue As Long _
) As Long
    If valueText = "" Then
        parsedValue = defaultValue
        Return -1
    End If
    If valueText <> "0" AndAlso valueText <> "1" Then Return 0
    parsedValue = Val(valueText)
    Return -1
End Function

Private Sub InitializeC2fbBodyTranslationOptions( _
    ByRef options As C2fbBodyTranslationOptions, _
    ByVal targetProfile As C2fbTargetProfile, _
    ByVal sourceMapMode As C2fbSourceMapMode _
)
    options.fbSourceDirectory = ""
    options.keepUnresolvedDependencies = 0
    options.includeExistingBodies = 0
    options.includeHeaderInlineBodies = 0
    options.includeHeaderBodyNames = ""
    options.includeIncludedCSourceBodies = 0
    options.assertionsStripped = 0
    options.assumeSingleThreadedAtomics = 0
    options.atomicMutexRuntime = 0
    options.assumeZeroStaticAggregates = 0
    options.targetProfile = targetProfile
    options.sourceLabel = ""
    options.sourceMapMode = sourceMapMode
    options.sourceOriginPrecision = C2FB_SOURCE_ORIGIN_LINES_AVAILABLE
End Sub

Private Function ReadC2fbSimpleBodyRequest( _
    ByVal modeName As String, ByRef request As C2fbBodyTranslationRequestModel, _
    ByRef errorMessage As String _
) As Long
    errorMessage = ""
    request.sourcePath = Command(2)
    request.outputPath = Command(3)
    InitializeC2fbBodyTranslationOptions( _
        request.translationOptions, C2FB_TARGET_SQLITE, _
        C2FB_SOURCE_MAP_DISABLED)
    request.translationOptions.fbSourceDirectory = Command(4)
    request.inputShape = C2FB_BODY_INPUT_FILE
    If modeName = "translate-simple-generic" OrElse _
       modeName = "translate-simple-generic-tree" Then _
        request.translationOptions.targetProfile = C2FB_TARGET_GENERIC
    If modeName = "translate-simple-tree" OrElse _
       modeName = "translate-simple-generic-tree" Then _
        request.inputShape = C2FB_BODY_INPUT_TREE

    If ParseC2fbBooleanValue( _
        Command(5), 0, request.translationOptions.keepUnresolvedDependencies) = 0 Then
        errorMessage = "keep-unresolved mode must be 0 or 1"
        Return 0
    End If
    If ParseC2fbBooleanValue( _
        Command(6), 0, request.translationOptions.includeExistingBodies) = 0 Then
        errorMessage = "include-existing mode must be 0 or 1"
        Return 0
    End If
    If request.sourcePath = "" OrElse request.outputPath = "" Then Return 0
    Return -1
End Function

Private Function ReadC2fbPreprocessedSourceFileList( _
    ByVal selectionText As String, _
    ByRef selectedFiles As C2fbSourceFileSetModel, _
    ByRef errorMessage As String _
) As Long
    errorMessage = ""
    Dim selectionPosition As Long = 1
    While selectionPosition <= Len(selectionText)
        Dim separatorPosition As Long = InStr(selectionPosition, selectionText, ",")
        Dim fileName As String
        If separatorPosition = 0 Then
            fileName = Trim(Mid(selectionText, selectionPosition))
            selectionPosition = Len(selectionText) + 1
        Else
            fileName = Trim(Mid(selectionText, selectionPosition, _
                                separatorPosition - selectionPosition))
            selectionPosition = separatorPosition + 1
        End If
        If fileName = "" Then
            errorMessage = "invalid engine C input in file selection: " & fileName
            Return 0
        End If
        If AppendC2fbSourceFileName(selectedFiles, fileName, -1) = 0 Then
            errorMessage = "selected source list exceeds the configured file limit"
            Return 0
        End If
    Wend
    If selectedFiles.itemCount = 0 Then Return 0
    Return -1
End Function

Private Function ReadC2fbPreprocessedBodyRequest( _
    ByVal modeName As String, ByVal argumentCount As Long, _
    ByRef request As C2fbPreprocessedBodyRequestModel, _
    ByRef errorMessage As String _
) As Long
    errorMessage = ""
    request.inputKind = C2FB_PREPROCESSED_INPUT_TREE
    If modeName = "translate-preprocessed-files" Then _
        request.inputKind = C2FB_PREPROCESSED_INPUT_FILE_LIST
    request.sourceDirectory = Command(2)
    request.generatedIncludeDirectory = Command(3)
    request.outputDirectory = Command(4)
    InitializeC2fbBodyTranslationOptions( _
        request.translationOptions, C2FB_TARGET_SQLITE, _
        C2FB_SOURCE_MAP_DISABLED)
    request.translationOptions.fbSourceDirectory = Command(5)
    request.compilerName = Command(6)
    request.threadSafe = 1
    request.featureDefines = Command(9)
    Dim sourceFileSelection As String = Command(11)
    Dim bodyOptionStart As Long = 11
    If request.inputKind = C2FB_PREPROCESSED_INPUT_FILE_LIST Then
        bodyOptionStart = 12
    ElseIf sourceFileSelection <> "" AndAlso _
           Left(sourceFileSelection, 1) <> "-" AndAlso _
           Left(sourceFileSelection, 1) <> "@" Then
        ' Keep the earlier tree form that accepts an explicit comma-separated
        ' file selection, while allowing body options directly after the
        ' fixed SQLite configuration arguments.
        request.inputKind = C2FB_PREPROCESSED_INPUT_FILE_LIST
        bodyOptionStart = 12
    End If

    If ParseC2fbBooleanValue( _
        Command(7), 1, request.threadSafe) = 0 Then
        errorMessage = "threadsafe mode must be 0 or 1"
        Return 0
    End If
    If ParseC2fbBooleanValue( _
        Command(8), 0, _
        request.translationOptions.keepUnresolvedDependencies) = 0 Then
        errorMessage = "keep-unresolved mode must be 0 or 1"
        Return 0
    End If
    If ParseC2fbBooleanValue( _
        Command(10), 0, request.translationOptions.includeExistingBodies) = 0 Then
        errorMessage = "include-existing mode must be 0 or 1"
        Return 0
    End If
    If request.sourceDirectory = "" OrElse _
       request.generatedIncludeDirectory = "" OrElse _
       request.outputDirectory = "" OrElse _
       request.translationOptions.fbSourceDirectory = "" Then Return 0
    If request.inputKind = C2FB_PREPROCESSED_INPUT_FILE_LIST AndAlso _
       sourceFileSelection = "" Then
        errorMessage = _
            "translate-preprocessed-files requires a comma-separated C input list"
        Return 0
    End If
    If request.inputKind = C2FB_PREPROCESSED_INPUT_FILE_LIST Then
        If ReadC2fbPreprocessedSourceFileList( _
            sourceFileSelection, request.selectedSourceFiles, errorMessage) = 0 Then _
            Return 0
    End If
    For optionIndex As Long = bodyOptionStart To argumentCount - 1
        If AppendC2fbArgumentValue( _
            request.bodyArguments, Command(optionIndex), MAX_FUNCTIONS) = 0 Then
            errorMessage = "preprocessed body options exceed the configured limit"
            Return 0
        End If
    Next
    Return -1
End Function

Private Function ReadC2fbGenericHeaderInputRequest( _
    ByVal argumentCount As Long, _
    ByRef request As C2fbGenericHeaderInputModel, _
    ByRef errorMessage As String _
) As Long
    errorMessage = ""
    request.fileRequest.inputPath = Command(2)
    request.fileRequest.outputPath = Command(3)
    If request.fileRequest.inputPath = "" OrElse _
       request.fileRequest.outputPath = "" Then Return 0

    Dim responseStack(0 To MAX_GENERIC_RESPONSE_DEPTH - 1) As String
    For sourceArgumentIndex As Long = 4 To argumentCount - 1
        If AppendC2fbResponseArgument( _
            Command(sourceArgumentIndex), request.argumentList, responseStack(), _
            0, "generic-header", errorMessage) = 0 Then Return 0
    Next
    Return -1
End Function

Private Function ReadC2fbGenericBodyInputRequest( _
    ByVal modeName As String, ByVal argumentCount As Long, _
    ByRef request As C2fbGenericBodyInputModel, _
    ByRef errorMessage As String _
) As Long
    errorMessage = ""
    request.bodyRequest.sourcePath = Command(2)
    request.bodyRequest.outputPath = Command(3)
    request.bodyRequest.inputShape = C2FB_BODY_INPUT_FILE
    If modeName = "translate-simple-generic-tree-c" Then _
        request.bodyRequest.inputShape = C2FB_BODY_INPUT_TREE
    InitializeC2fbBodyTranslationOptions( _
        request.bodyRequest.translationOptions, C2FB_TARGET_GENERIC, _
        C2FB_SOURCE_MAP_PREPROCESSOR_MARKERS)
    If request.bodyRequest.sourcePath = "" OrElse _
       request.bodyRequest.outputPath = "" Then Return 0

    For sourceArgumentIndex As Long = 4 To argumentCount - 1
        If AppendC2fbArgumentValue( _
            request.argumentList, Command(sourceArgumentIndex), MAX_FUNCTIONS) = 0 Then
            errorMessage = _
                "generic C input arguments exceed the configured limit"
            Return 0
        End If
    Next
    Return -1
End Function

Private Function ReadC2fbFileConversionRequest( _
    ByVal firstArgument As Long, _
    ByRef request As C2fbFileConversionRequestModel _
) As Long
    request.inputPath = Command(firstArgument)
    request.outputPath = Command(firstArgument + 1)
    If request.inputPath = "" OrElse request.outputPath = "" Then Return 0
    Return -1
End Function

Private Function ReadC2fbFunctionIndexRequest( _
    ByRef request As C2fbFunctionIndexRequestModel, _
    ByRef errorMessage As String _
) As Long
    errorMessage = ""
    request.sourceDirectory = Command(2)
    request.outputPath = Command(3)
    request.sourceScope = C2FB_FUNCTION_INDEX_SCOPE_C_ONLY
    Dim includeHeadersText As String = Command(4)
    If includeHeadersText <> "" Then
        If includeHeadersText <> "--include-headers" Then
            errorMessage = "functions accepts only the --include-headers option"
            Return 0
        End If
        request.sourceScope = C2FB_FUNCTION_INDEX_SCOPE_C_AND_HEADERS
    End If
    If request.sourceDirectory = "" OrElse request.outputPath = "" Then Return 0
    Return -1
End Function

Private Function ReadC2fbFunctionReconcileRequest( _
    ByRef request As C2fbFunctionReconcileRequestModel _
) As Long
    request.csvPath = Command(2)
    request.fbDirectory = Command(3)
    If request.csvPath = "" OrElse request.fbDirectory = "" Then Return 0
    Return -1
End Function

Private Function ReadC2fbApiRoutinesRequest( _
    ByRef request As C2fbApiRoutinesRequestModel _
) As Long
    request.preprocessedInputPath = Command(2)
    request.functionLedgerPath = Command(3)
    request.ownerModulePath = Command(4)
    request.outputPath = Command(5)
    If request.preprocessedInputPath = "" OrElse _
       request.functionLedgerPath = "" OrElse _
       request.ownerModulePath = "" OrElse request.outputPath = "" Then _
        Return 0
    Return -1
End Function

Private Function ReadC2fbCommandModel( _
    ByVal argumentCount As Long, ByRef request As C2fbCommandModel, _
    ByRef usageText As String, ByRef errorMessage As String _
) As Long
    Dim modeName As String = Command(1)
    usageText = ""
    errorMessage = ""

    Select Case modeName
    Case "defines"
        request.kind = C2FB_COMMAND_DEFINES
        usageText = "usage: c2fb defines input.h output.bi"
        Return ReadC2fbFileConversionRequest(2, request.fileRequest)
    Case "translate-simple", "translate-simple-generic", _
         "translate-simple-tree", "translate-simple-generic-tree"
        request.kind = C2FB_COMMAND_SIMPLE_BODY
        If ReadC2fbSimpleBodyRequest( _
            modeName, request.bodyRequest, errorMessage) = 0 Then
            If request.bodyRequest.inputShape = C2FB_BODY_INPUT_TREE Then
                usageText = "usage: c2fb translate-simple-tree|translate-simple-generic-tree source-directory output-directory [fb-source-directory] [keep-unresolved] [include-existing]"
            Else
                usageText = "usage: c2fb translate-simple[-generic] input.c output.bas [fb-source-directory] [keep-unresolved] [include-existing]"
            End If
            Return 0
        End If
        Return -1
    Case "translate-simple-generic-c", "translate-simple-generic-tree-c"
        request.kind = C2FB_COMMAND_GENERIC_BODY
        If ReadC2fbGenericBodyInputRequest( _
            modeName, argumentCount, request.genericBodyRequest, errorMessage) = 0 Then
            If request.genericBodyRequest.bodyRequest.inputShape = _
               C2FB_BODY_INPUT_TREE Then
                usageText = "usage: c2fb translate-simple-generic-tree-c source-directory output-directory [@options.txt ...] [compiler] [preprocessor-options...] [--fb-source-directory=Dir] [--type-map=CName=FbType] [--target-profile=generic|sqlite] [--typedef-hint=CName] [--rename-proc=CName=FbName] [--rename-proc-prefix=Prefix] [--exclude-proc=Pattern ...] [--replacement-file=Rules.rpl] [--keep-unresolved] [--include-existing] [--include-header-inline-bodies] [--include-header-inline-body=Name ...] [--include-header-body=Name ...] [--include-included-c-source-bodies] [--assume-zero-static-aggregates]"
            Else
                usageText = "usage: c2fb translate-simple-generic-c input.c output.bas [@options.txt ...] [compiler] [preprocessor-options...] [--fb-source-directory=Dir] [--type-map=CName=FbType] [--target-profile=generic|sqlite] [--typedef-hint=CName] [--rename-proc=CName=FbName] [--rename-proc-prefix=Prefix] [--exclude-proc=Pattern ...] [--replacement-file=Rules.rpl] [--keep-unresolved] [--include-existing] [--include-header-inline-bodies] [--include-header-inline-body=Name ...] [--include-header-body=Name ...] [--include-included-c-source-bodies] [--assume-single-threaded-atomics] [--assume-zero-static-aggregates]"
            End If
            Return 0
        End If
        Return -1
    Case "translate-preprocessed-tree", "translate-preprocessed-files"
        request.kind = C2FB_COMMAND_PREPROCESSED_BODY
        If ReadC2fbPreprocessedBodyRequest( _
            modeName, argumentCount, request.preprocessedBodyRequest, errorMessage) = 0 Then
            usageText = "usage: c2fb translate-preprocessed-tree|translate-preprocessed-files source-directory generated-include-directory output-directory fb-source-directory [compiler] [threadsafe] [keep-unresolved] [feature-defines] [include-existing] [source-files] [body-options ...]"
            Return 0
        End If
        Return -1
    Case "fp-tables"
        request.kind = C2FB_COMMAND_FP_TABLES
        usageText = "usage: c2fb fp-tables util.c output.bi"
        Return ReadC2fbFileConversionRequest(2, request.fileRequest)
    Case "functions"
        request.kind = C2FB_COMMAND_FUNCTION_INDEX
        usageText = "usage: c2fb functions source-directory output.csv [--include-headers]"
        If ReadC2fbFunctionIndexRequest( _
            request.functionIndexRequest, errorMessage) = 0 Then Return 0
        Return -1
    Case "reconcile-functions"
        request.kind = C2FB_COMMAND_FUNCTION_RECONCILE
        usageText = "usage: c2fb reconcile-functions functions.csv fb-source-directory"
        Return ReadC2fbFunctionReconcileRequest(request.functionReconcileRequest)
    Case "api-routines"
        request.kind = C2FB_COMMAND_API_ROUTINES
        usageText = "usage: c2fb api-routines loadext.i PORTING_FUNCTIONS.csv owner.bas output.bi"
        Return ReadC2fbApiRoutinesRequest(request.apiRoutinesRequest)
    Case "generic-header"
        request.kind = C2FB_COMMAND_GENERIC_HEADER
        usageText = "usage: c2fb generic-header input.h output.bi [@options.txt ...] [compiler] [preprocessor-options...] [-v [-v]] " & _
            "[--c-include=Header.h ...] [--prefix=FbPrefix] [--type-map=CName=FbType ...] [--type-alignment=CName=Bytes ...] [--typedef-hint=CName ...] " & _
            "[--expand-type=CName ...] [--expand-macro=Pattern ...] [--no-expand-macro=Pattern ...] [--forward-decl=Pattern ...] " & _
            "[--no-inline-bodies] [--drop-inline-body=Pattern ...] [--drop-macro-body-scopes] [--force-inline-macro=Pattern ...] " & _
            "[--assume-integer-macro=Pattern ...] [--dynamic-macro-division=Pattern ...] " & _
            "[--rename=CName=FbName ...] [--rename-tag=CName=FbName ...] " & _
            "[--rename-typedef=CName=FbName ...] [--rename-proc=CName=FbName ...] [--rename-proc-prefix=Prefix] [--rename-define=CName=FbName ...] " & _
            "[--rename-macro-param=CName=FbName ...] [--string=CName|--no-string=CName ...] [--array-size=CName=Count ...] " & _
            "[--fb-include=File.bi ...] [--fb-library=Name ...] [--undef=Macro ...] [--exclude=Pattern ...] " & _
            "[--exclude-proc=Pattern ...] [--exclude-variable=Pattern ...] [--exclude-define=Pattern ...] " & _
            "[--preserve-type-dependencies] " & _
            "[--remove-include=Header.h ...] [--emit-reserved-defines=Pattern ...] [--remove-empty-reserved-defines] " & _
            "[--clong32] [--replacement-file=Rules.rpl ...]"
        If ReadC2fbGenericHeaderInputRequest( _
            argumentCount, request.genericHeaderRequest, errorMessage) = 0 Then _
            Return 0
        Return -1
    Case Else
        request.kind = C2FB_COMMAND_HEADER
        usageText = "usage: c2fb input.h output.bi"
        Return ReadC2fbFileConversionRequest(1, request.fileRequest)
    End Select
End Function

/' end of c2fb_inputs.bi '/
