/'
    Project: C2FB shared body translation pipeline

    File: c2fb_body_pipeline.bi

    Purpose:

        Lower one C input file into FreeBASIC body candidates for any target.

    Responsibilities:

        - Prepare declaration, symbol, and project indexes for the input.
        - Stream function definitions through the shared scanner and lowerer.
        - Filter duplicate, existing, and unresolved body candidates.
        - Select included-header bodies by dependency or inline-body policy.
        - Submit candidates to the shared body output backend.

    This file intentionally does NOT contain:

        - Command-line parsing or source-tree selection.
        - C preprocessing, expression lowering, or output formatting.
'/

Private Sub ReportGenericBodyStageTiming( _
    ByVal enabled As Long, ByVal stageName As String, _
    ByRef stageStartedAt As Double _
)
    If enabled = 0 Then Exit Sub
    Dim currentTime As Double = Timer
    Dim elapsedSeconds As Double = currentTime - stageStartedAt
    If elapsedSeconds < 0 Then elapsedSeconds += 86400
    Print "c2fb: generic-body stage timing: " & stageName & _
        " completed in " & Trim(Str(elapsedSeconds)) & " seconds"
    stageStartedAt = currentTime
End Sub

Private Sub FilterExistingBodyCandidates( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    candidates() As C2fbBodyCandidateModel, _
    ByVal candidateCount As Long, _
    existingNames() As String, _
    ByVal existingCount As Long _
)
    For i As Long = 0 To candidateCount - 1
        If candidates(i).source = "" OrElse candidates(i).duplicate <> 0 Then Continue For
        Dim procedureIndex As Long = _
            CBodyProcedureIndex(translation, candidates(i).name)
        If procedureIndex >= 0 AndAlso _
           translation.symbolTable.symbols(procedureIndex).body.needsDefinition <> 0 Then _
            Continue For
        Dim fbName As String = CBodyCallName(translation, catalog, candidates(i).name)
        If C2fbNameListContains(existingNames(), existingCount, candidates(i).name) <> 0 OrElse _
           C2fbNameListContains(existingNames(), existingCount, fbName) <> 0 Then
            candidates(i).source = ""
        End If
    Next
End Sub

Private Sub FilterCBodyPrivateDependencies( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    candidates() As C2fbBodyCandidateModel, ByVal candidateCount As Long _
)
    ' A private FreeBASIC implementation cannot be called from another
    ' candidate module. Keep the caller out of standalone batches unless its
    ' helper body is also present in this output file.
    For candidateIndex As Long = 0 To candidateCount - 1
        If candidates(candidateIndex).source = "" OrElse _
           candidates(candidateIndex).duplicate <> 0 Then Continue For
        For signatureIndex As Long = 0 To catalog.bodyCallSignatureCount - 1
            With catalog.bodyCallSignatures(signatureIndex)
                If Left(LCase(.name), Len("__c2fb_")) = "__c2fb_" OrElse _
                   Left(LCase(.fbName), Len("__c2fb_")) = "__c2fb_" Then _
                    Continue For
                If .isPrivate = 0 OrElse .fbName = "" Then Continue For
                Dim cCallName As String = _
                    CBodyCallName(translation, catalog, .name)
                If CBodyUsesProcedure(candidates(candidateIndex).source, .name) = 0 AndAlso _
                   CBodyUsesProcedure(candidates(candidateIndex).source, .fbName) = 0 AndAlso _
                   CBodyUsesProcedure(candidates(candidateIndex).source, cCallName) = 0 Then _
                    Continue For

                Dim helperIsInCandidate As Long = 0
                For helperIndex As Long = 0 To candidateCount - 1
                    If candidates(helperIndex).source = "" OrElse _
                       candidates(helperIndex).duplicate <> 0 Then Continue For
                    If candidates(helperIndex).name = .name OrElse _
                       candidates(helperIndex).name = .fbName OrElse _
                       candidates(helperIndex).procedureBinding.freeBasicName = .fbName Then
                        helperIsInCandidate = -1
                        Exit For
                    End If
                Next
                If helperIsInCandidate = 0 Then
                    candidates(candidateIndex).source = ""
                    candidates(candidateIndex).skipMessage = _
                        "requires private FreeBASIC helper " & .fbName & _
                        " from another module"
                    Exit For
                End If
            End With
        Next
        If candidates(candidateIndex).source = "" Then Continue For
        For privateIndex As Long = 0 To catalog.existingProcedureNameCount - 1
            Dim privateName As String = _
                catalog.existingProcedureNames(privateIndex)
            If Left(LCase(privateName), Len("__c2fb_")) = "__c2fb_" Then _
                Continue For
            If C2fbNameListContains( _
                catalog.callableNames(), catalog.callableNameCount, privateName) <> 0 Then _
                Continue For
            Dim cCallName As String = _
                CBodyCallName(translation, catalog, privateName)
            If cCallName = "" Then cCallName = privateName
            If CBodyUsesProcedure(candidates(candidateIndex).source, privateName) = 0 AndAlso _
               CBodyUsesProcedure(candidates(candidateIndex).source, cCallName) = 0 Then _
                Continue For

            Dim helperIsInCandidate As Long = 0
            For helperIndex As Long = 0 To candidateCount - 1
                If candidates(helperIndex).source = "" OrElse _
                   candidates(helperIndex).duplicate <> 0 Then Continue For
                If candidates(helperIndex).name = privateName OrElse _
                   candidates(helperIndex).name = cCallName OrElse _
                   candidates(helperIndex).procedureBinding.freeBasicName = privateName OrElse _
                   candidates(helperIndex).procedureBinding.freeBasicName = cCallName Then
                    helperIsInCandidate = -1
                    Exit For
                End If
            Next
            If helperIsInCandidate = 0 Then
                candidates(candidateIndex).source = ""
                candidates(candidateIndex).skipMessage = _
                    "requires private FreeBASIC helper " & privateName & _
                    " from another module"
                Exit For
            End If
        Next
    Next
End Sub

Private Sub FilterUnusedHeaderBodyCandidates( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    candidates() As C2fbBodyCandidateModel, ByVal candidateCount As Long, _
    ByVal includeHeaderInlineBodies As Long, _
    ByVal includeHeaderBodyNames As String _
)
    For i As Long = 0 To candidateCount - 1
        candidates(i).isHeaderRequired = 0
        If candidates(i).isHeaderBody <> 0 Then
            If (includeHeaderInlineBodies <> 0 AndAlso _
                candidates(i).isHeaderInlineBody <> 0) OrElse _
               C2fbDelimitedNameListContains( _
                   includeHeaderBodyNames, candidates(i).name) <> 0 Then
                candidates(i).isHeaderRequired = -1
            End If
        End If
    Next

    ' Static bodies from included headers are module-local candidates. Inline
    ' bodies explicitly selected by the caller start as roots; other helpers
    ' remain dependency-driven.
    For sourceIndex As Long = 0 To candidateCount - 1
        If candidates(sourceIndex).isHeaderBody <> 0 OrElse _
           candidates(sourceIndex).source = "" OrElse _
           candidates(sourceIndex).duplicate <> 0 Then Continue For
        For headerIndex As Long = 0 To candidateCount - 1
            If candidates(headerIndex).isHeaderBody = 0 OrElse _
               candidates(headerIndex).duplicate <> 0 Then Continue For
            Dim headerFbName As String = CBodyCallName( _
                translation, catalog, candidates(headerIndex).name)
            If CBodyUsesProcedure(candidates(sourceIndex).source, _
                                  candidates(headerIndex).name) <> 0 OrElse _
               CBodyUsesProcedure(candidates(sourceIndex).source, headerFbName) <> 0 Then _
                candidates(headerIndex).isHeaderRequired = -1
        Next
    Next

    Dim changed As Long
    Do
        changed = 0
        For sourceIndex As Long = 0 To candidateCount - 1
            If candidates(sourceIndex).isHeaderBody = 0 OrElse _
               candidates(sourceIndex).isHeaderRequired = 0 OrElse _
               candidates(sourceIndex).source = "" OrElse _
               candidates(sourceIndex).duplicate <> 0 Then Continue For
            For headerIndex As Long = 0 To candidateCount - 1
                If candidates(headerIndex).isHeaderBody = 0 OrElse _
                   candidates(headerIndex).isHeaderRequired <> 0 OrElse _
                   candidates(headerIndex).source = "" OrElse _
                   candidates(headerIndex).duplicate <> 0 Then Continue For
                Dim headerFbName As String = CBodyCallName( _
                    translation, catalog, candidates(headerIndex).name)
                If CBodyUsesProcedure(candidates(sourceIndex).source, _
                                      candidates(headerIndex).name) <> 0 OrElse _
                   CBodyUsesProcedure(candidates(sourceIndex).source, headerFbName) <> 0 Then
                    candidates(headerIndex).isHeaderRequired = -1
                    changed = -1
                End If
            Next
        Next
    Loop While changed <> 0

    For i As Long = 0 To candidateCount - 1
        If candidates(i).isHeaderBody <> 0 AndAlso _
           candidates(i).isHeaderRequired = 0 Then candidates(i).source = ""
    Next
End Sub

Private Function CBodyDeclarationHasInlineSpecifier( _
    ByRef declaration As C2fbDeclarationModel _
) As Long
    Dim declaratorStart As Long = _
        declaration.functionDeclaration.declaratorStartToken
    If declaratorStart <= 0 Then Return 0
    For tokenIndex As Long = 0 To declaratorStart - 1
        Select Case declaration.tokens(tokenIndex)
        Case "inline", "__inline", "__inline__": Return -1
        End Select
    Next
    Return 0
End Function

Private Sub TranslateCBodyFile( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef request As C2fbBodyFileTranslationRequestModel _
)
    Dim inputPath As String = request.inputPath
    Dim outputPath As String = request.outputPath
    Dim bodyOptions As C2fbBodyTranslationOptions = request.translationOptions
    Dim stageStartedAt As Double = Timer
    Dim fbSourceDirectory As String = bodyOptions.fbSourceDirectory
    Dim keepUnresolvedDependencies As Long = _
        bodyOptions.keepUnresolvedDependencies
    Dim includeExistingBodies As Long = bodyOptions.includeExistingBodies
    Dim assertionsStripped As Long = bodyOptions.assertionsStripped
    Dim targetProfile As C2fbTargetProfile = bodyOptions.targetProfile
    Dim sourceLabel As String = bodyOptions.sourceLabel
    Dim sourceMapMode As C2fbSourceMapMode = bodyOptions.sourceMapMode
    If Len(inputPath) = 0 OrElse Len(outputPath) = 0 Then _
        ReportError("body translation requires an input C file and an output FreeBASIC file")
    If ConfigureC2fbTranslationTarget( _
        translation, targetProfile, sourceMapMode) = 0 Then _
        ReportError("invalid body translation target context")
    translation.body.assumeSingleThreadedAtomics = _
        bodyOptions.assumeSingleThreadedAtomics
    translation.body.atomicMutexRuntime = _
        bodyOptions.atomicMutexRuntime
    translation.body.assumeZeroStaticAggregates = _
        bodyOptions.assumeZeroStaticAggregates
    translation.sourceUnit.diagnosticState.currentSourceLocation.path = inputPath
    translation.sourceUnit.diagnosticState.currentSourceLocation.line = 0
    If sourceLabel <> "" Then translation.sourceUnit.diagnosticState.currentSourceLocation.path = sourceLabel
    Dim lowerName As String = LCase(FileNameOnly(inputPath))
    If translation.target.profile = C2FB_TARGET_SQLITE AndAlso _
       (Left(lowerName, 4) = "test" OrElse lowerName = "tclsqlite.c") Then
        ReportError("test-support sources are outside the engine conversion scope")
    End If

    PrepareC2fbProjectCatalog( _
    catalog, fbSourceDirectory, bodyOptions.fbSourceRecursive)
    translation.body.recordBindingCount = 0
    ResetCBodyCallbackTypesInContext(translation)
    IndexCBodyCallbackTypesFromCatalog(translation, catalog)
    ReportGenericBodyStageTiming( _
        bodyOptions.profileTimings, "FreeBASIC project catalog", stageStartedAt)
    ResetC2fbSymbolTableInContext(translation, 256)
    Dim rootSourcePath As String = inputPath
    If sourceLabel <> "" Then rootSourcePath = sourceLabel
    translation.body.includeGlobalDefinitions = _
        bodyOptions.includeGlobalDefinitions
    Dim declarationScan As C2fbDeclarationScanRequestModel
    ConfigureC2fbBodyDeclarationScanRequest( _
        declarationScan, inputPath, rootSourcePath)
    declarationScan.options.sourceMapMode = translation.target.sourceMapMode
    declarationScan.options.sourceOriginPrecision = bodyOptions.sourceOriginPrecision
    declarationScan.options.collectHeaderInlineBodies = _
        bodyOptions.includeHeaderInlineBodies
    declarationScan.options.includeHeaderBodyNames = _
        bodyOptions.includeHeaderBodyNames
    declarationScan.options.collectIncludedCSourceBodies = _
        bodyOptions.includeIncludedCSourceBodies
    If CollectC2fbDeclarationsInSourceUnit( _
        translation.sourceUnit, declarationScan) = 0 Then _
        Return
    ReportGenericBodyStageTiming( _
        bodyOptions.profileTimings, "C declaration scan", stageStartedAt)
    If translation.target.profile = C2FB_TARGET_GENERIC Then _
        IndexGenericBodyEnumConstants( _
            translation, -1, 0, bodyOptions.profileTimings)
    ReportGenericBodyStageTiming( _
        bodyOptions.profileTimings, "initial enum indexing", stageStartedAt)
    IndexCBodyTypeAliasesFromDeclarations(translation, catalog)
    IndexCBodyRecordsFromDeclarations(translation, catalog)
    IndexCBodyGeneratedSourceRecords(translation, catalog)
    ' Re-index typedef aliases after port record bindings are available.
    IndexCBodyTypeAliasesFromDeclarations(translation, catalog)
    ReportGenericBodyStageTiming( _
        bodyOptions.profileTimings, "type alias and record indexing", stageStartedAt)
    ' Enum expressions can use typedef ranks once the body aliases are known.
    If translation.target.profile = C2FB_TARGET_GENERIC Then _
        IndexGenericBodyEnumConstants( _
            translation, 0, 0, bodyOptions.profileTimings, 1)
    ReportGenericBodyStageTiming( _
        bodyOptions.profileTimings, "enum resolution after aliases", stageStartedAt)
    IndexCBodyProceduresFromDeclarations(translation, catalog)
    AddCBodyCallableSymbols( _
        translation, catalog, _
        catalog.callableNames(), _
        catalog.callableNameCount)
    BuildCBodyRecordStaticInitializerBindings(translation, catalog)
    IndexCBodyExternalObjectsFromDeclarations(translation, catalog)
    ReportGenericBodyStageTiming( _
        bodyOptions.profileTimings, "procedure and object indexing", stageStartedAt)
    ' Array-valued file-scope objects can complete countof expressions used
    ' by earlier enum members, so retry unresolved values once storage extents
    ' are available.
    If translation.target.profile = C2FB_TARGET_GENERIC Then _
        IndexGenericBodyEnumConstants( _
            translation, 0, 0, bodyOptions.profileTimings, 2)
    ReportGenericBodyStageTiming( _
        bodyOptions.profileTimings, "enum resolution after object extents", stageStartedAt)
    Dim candidates() As C2fbBodyCandidateModel
    ReDim candidates(0 To INITIAL_BODY_CANDIDATE_CAPACITY - 1)
    Dim candidateCount As Long = 0
    Dim candidateNameIndex As C2fbStringIndexMapModel
    ResetC2fbStringIndexMap(candidateNameIndex)

    Dim bodyScan As C2fbDeclarationScanRequestModel
    ConfigureC2fbFunctionBodyScanRequest(bodyScan, inputPath, rootSourcePath)
    bodyScan.options.sourceMapMode = translation.target.sourceMapMode
    bodyScan.options.sourceOriginPrecision = bodyOptions.sourceOriginPrecision
    bodyScan.options.collectHeaderInlineBodies = _
        bodyOptions.includeHeaderInlineBodies
    bodyScan.options.includeHeaderBodyNames = _
        bodyOptions.includeHeaderBodyNames
    bodyScan.options.collectIncludedCSourceBodies = _
        bodyOptions.includeIncludedCSourceBodies
    Dim scanner As C2fbFunctionScanner
    If OpenC2fbFunctionScanner(scanner, bodyScan) = 0 Then _
        ReportError("cannot read C function source: " & inputPath)

    Dim sourceItem As C2fbSourceItemModel
    While NextC2fbSourceItem(translation.sourceUnit, scanner, sourceItem) <> 0
        If sourceItem.declaration.isFunctionDefinition = 0 Then Continue While
        Dim functionName As String = sourceItem.declaration.sourceName
        Dim procedureBinding As C2fbProcedureBindingModel
        translation.sourceUnit.diagnosticState.currentSourceLocation.path = sourceItem.declaration.sourceSpan.startLocation.path
        translation.sourceUnit.diagnosticState.currentSourceLocation.line = sourceItem.declaration.sourceSpan.startLocation.line
        translation.sourceUnit.diagnosticState.currentSourceLocation.column = sourceItem.declaration.sourceSpan.startLocation.column
        Dim diagnosticStart As Long = _
            translation.sourceUnit.diagnosticState.diagnosticCount
        translation.sourceUnit.diagnosticState.suppressWarningConsole = _
            sourceItem.declaration.isHeaderBody
        Dim functionStartedAt As Double = Timer
        Dim isExcluded As Long = GenericProcedureExcludedInPolicy( _
            translation.genericC.policy, functionName)
        Dim implementation As String
        If isExcluded <> 0 Then
            ReportGenericBodyStageTiming( _
                bodyOptions.profileTimings, _
                "excluded function " & functionName, functionStartedAt)
        Else
            implementation = BuildSimpleProcedure( _
                translation, catalog, sourceItem, functionName, _
                catalog.callableNames(), catalog.callableNameCount, _
                procedureBinding)
            ReportGenericBodyStageTiming( _
                bodyOptions.profileTimings, _
                "function " & functionName, functionStartedAt)
        End If
        translation.sourceUnit.diagnosticState.suppressWarningConsole = 0
        Dim functionDiagnosticCount As Long = _
            translation.sourceUnit.diagnosticState.diagnosticCount - diagnosticStart
        If Len(functionName) = 0 Then Continue While

        Dim existing As Long = C2fbStringIndexMapLookup( _
            candidateNameIndex, functionName)
        If existing >= 0 Then
            candidates(existing).duplicate = -1
            candidates(existing).source = ""
        ElseIf candidateCount < MAX_FUNCTIONS Then
            If candidateCount > UBound(candidates) Then
                Dim nextCandidateCapacity As Long = _
                    (UBound(candidates) + 1) * 2
                If nextCandidateCapacity > MAX_FUNCTIONS Then _
                    nextCandidateCapacity = MAX_FUNCTIONS
                ReDim Preserve candidates(0 To nextCandidateCapacity - 1)
            End If
            candidates(candidateCount).name = functionName
            candidates(candidateCount).source = implementation
            candidates(candidateCount).procedureBinding = procedureBinding
            candidates(candidateCount).sourceLocation.path = sourceItem.declaration.sourceSpan.startLocation.path
            candidates(candidateCount).sourceLocation.line = sourceItem.declaration.sourceSpan.startLocation.line
            candidates(candidateCount).sourceLocation.column = sourceItem.declaration.sourceSpan.startLocation.column
            candidates(candidateCount).diagnosticStart = diagnosticStart
            candidates(candidateCount).diagnosticCount = functionDiagnosticCount
            candidates(candidateCount).isHeaderBody = sourceItem.declaration.isHeaderBody
            candidates(candidateCount).isHeaderInlineBody = _
                CBodyDeclarationHasInlineSpecifier(sourceItem.declaration)
            If isExcluded <> 0 Then
                candidates(candidateCount).source = ""
                candidates(candidateCount).skipMessage = _
                    "excluded by --exclude-proc"
            End If
            If AddC2fbStringIndexMapEntry( _
                candidateNameIndex, functionName, candidateCount) <> -1 Then _
                ReportError("source file exceeds the configured function limit")
            candidateCount += 1
        Else
            CloseC2fbFunctionScanner(scanner)
            ReportError("source file exceeds the configured function limit")
        End If
    Wend
    CloseC2fbFunctionScanner(scanner)
    ReportGenericBodyStageTiming( _
        bodyOptions.profileTimings, "function scanning and lowering", stageStartedAt)

    For entryIndex As Long = 0 To candidateCount - 1
        Dim index As Long = _
            CBodyProcedureIndex(translation, candidates(entryIndex).name)
        If includeExistingBodies = 0 AndAlso _
           C2fbNameListContains(catalog.existingProcedureNames(), _
                       catalog.existingProcedureNameCount, _
                       candidates(entryIndex).name) <> 0 AndAlso _
           (index < 0 OrElse translation.symbolTable.symbols(index).body.needsDefinition = 0) Then candidates(entryIndex).source = ""
    Next
    If keepUnresolvedDependencies = 0 Then _
        FilterCBodyDependencies( _
            translation, catalog, candidates(), candidateCount)
    If Len(fbSourceDirectory) <> 0 AndAlso includeExistingBodies = 0 Then
        FilterExistingBodyCandidates( _
                                     translation, catalog, _
                                     candidates(), candidateCount, _
                                     catalog.existingProcedureNames(), _
                                     catalog.existingProcedureNameCount)
        FilterCBodyPrivateDependencies( _
            translation, catalog, candidates(), candidateCount)
    End If
    If translation.target.sourceMapMode <> C2FB_SOURCE_MAP_DISABLED Then _
        FilterUnusedHeaderBodyCandidates( _
            translation, catalog, candidates(), candidateCount, _
            bodyOptions.includeHeaderInlineBodies, _
            bodyOptions.includeHeaderBodyNames)
    If keepUnresolvedDependencies = 0 Then _
        FilterCBodyDependencies( _
            translation, catalog, candidates(), candidateCount)
    ReportGenericBodyStageTiming( _
        bodyOptions.profileTimings, "candidate dependency filtering", stageStartedAt)

    For candidateIndex As Long = 0 To candidateCount - 1
        Dim symbolIndex As Long = CBodyProcedureIndex( _
            translation, candidates(candidateIndex).name)
        If candidates(candidateIndex).isHeaderBody <> 0 AndAlso _
           candidates(candidateIndex).isHeaderRequired = 0 Then
            candidates(candidateIndex).skipMessage = ""
        ElseIf includeExistingBodies = 0 AndAlso _
               C2fbNameListContains( _
            catalog.existingProcedureNames(), catalog.existingProcedureNameCount, _
           candidates(candidateIndex).name) <> 0 AndAlso _
           (symbolIndex < 0 OrElse _
            translation.symbolTable.symbols(symbolIndex).body.needsDefinition = 0) Then
            candidates(candidateIndex).skipMessage = _
                "FreeBASIC body already exists"
        ElseIf candidates(candidateIndex).duplicate <> 0 Then
            candidates(candidateIndex).skipMessage = _
                "multiple source definitions"
        ElseIf candidates(candidateIndex).source = "" AndAlso _
               candidates(candidateIndex).skipMessage = "" Then
            candidates(candidateIndex).skipMessage = _
                "outside the supported subset"
        End If
    Next

    For candidateIndex As Long = 0 To candidateCount - 1
        If candidates(candidateIndex).isHeaderBody = 0 OrElse _
           candidates(candidateIndex).isHeaderRequired = 0 OrElse _
           candidates(candidateIndex).source <> "" Then Continue For
        For diagnosticIndex As Long = candidates(candidateIndex).diagnosticStart To _
            candidates(candidateIndex).diagnosticStart + _
            candidates(candidateIndex).diagnosticCount - 1
            If diagnosticIndex < 0 OrElse _
               diagnosticIndex >= translation.sourceUnit.diagnosticState.diagnosticCount Then _
                Continue For
            WriteC2fbDiagnosticConsole( _
                translation.sourceUnit.diagnosticState.diagnostics(diagnosticIndex))
        Next
    Next

    Dim candidateFile As C2fbBodyCandidateFileModel
    candidateFile.outputPath = outputPath
    candidateFile.sourceLabel = sourceLabel
    If candidateFile.sourceLabel = "" Then _
        candidateFile.sourceLabel = inputPath
    candidateFile.fbSourceDirectory = fbSourceDirectory
    candidateFile.keepUnresolvedDependencies = keepUnresolvedDependencies
    candidateFile.assertionsStripped = assertionsStripped
    WriteC2fbBodyCandidateFile( _
        translation, catalog, candidateFile, candidates(), candidateCount)
    ReportGenericBodyStageTiming( _
        bodyOptions.profileTimings, "candidate output", stageStartedAt)
End Sub

/' end of c2fb_body_pipeline.bi '/
