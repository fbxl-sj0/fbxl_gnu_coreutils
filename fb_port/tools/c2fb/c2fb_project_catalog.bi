/'
    Project: C2FB FreeBASIC project index

    File: c2fb_project_catalog.bi

    Purpose:

        Build reusable FreeBASIC source indexes for body translation.

    Responsibilities:

        - Collect callable, local declaration, existing procedure, and call-signature indexes.
        - Share each .bi and .bas traversal across the indexes it feeds.
        - Preserve ordered names while using bounded indexes for duplicate checks.
        - Index implementation-local record layouts without exporting their private procedures.
        - Delegate nested type-layout parsing to the shared layout indexer.
        - Cache the result in C2fbProjectCatalog for a source path and scan policy.

    This file intentionally does NOT contain:

        - C source scanning, C type mapping, or function-body lowering.
        - FreeBASIC output formatting or command-line option parsing.
'/

Private Sub AppendUniqueFreeBasicProjectName( _
    names() As String, ByRef nameCount As Long, _
    ByRef nameSet As C2fbNameSetModel, ByVal sourceName As String, _
    ByVal limitMessage As String _
)
    If sourceName = "" OrElse C2fbNameSetContains(nameSet, sourceName) <> 0 Then Exit Sub
    If nameCount >= MAX_FUNCTIONS Then ReportError(limitMessage)
    If AddC2fbNameSet(nameSet, sourceName) = 0 Then _
        ReportError("FreeBASIC project name index exceeds the configured limit")
    If nameCount >= UBound(names) Then _
        ReDim Preserve names(0 To UBound(names) * 2 + 1)
    names(nameCount) = sourceName
    nameCount += 1
End Sub

Private Sub AppendUniqueExistingFreeBasicProcedure( _
    ByRef catalog As C2fbProjectCatalog, ByVal procedureName As String _
)
    If procedureName = "" OrElse _
       C2fbNameSetContains( _
            catalog.existingProcedureNameSet, procedureName) <> 0 Then Exit Sub
    If catalog.existingProcedureNameCount >= MAX_FUNCTIONS Then _
        ReportError("FreeBASIC procedure index exceeds the configured limit")
    If AddC2fbNameSet( _
        catalog.existingProcedureNameSet, procedureName) = 0 Then _
        ReportError("FreeBASIC procedure name index exceeds the configured limit")
    If catalog.existingProcedureNameCount >= _
       UBound(catalog.existingProcedureNames) Then _
        ReDim Preserve catalog.existingProcedureNames( _
            0 To UBound(catalog.existingProcedureNames) * 2 + 1)
    catalog.existingProcedureNames( _
        catalog.existingProcedureNameCount) = procedureName
    catalog.existingProcedureNameCount += 1
End Sub

Private Sub IndexFreeBasicCatalogFile( _
    ByRef catalog As C2fbProjectCatalog, ByVal sourceDirectory As String, _
    ByVal fileName As String, ByVal isInterfaceFile As Long, _
    ByVal isLocalDeclarationFile As Long, _
    ByRef layoutState As C2fbFbLayoutScanStateModel, _
    ByVal indexImplementationLayouts As Long = 0, _
    ByVal signatureFallback As Long = 0 _
)
    Dim lineReader As C2fbTextFileLineReaderModel
    If OpenC2fbTextFileLineReader( _
        lineReader, sourceDirectory & "/" & fileName) = 0 Then _
        ReportError("cannot read FreeBASIC project source: " & fileName)
    Dim pendingDeclaration As String
    Dim sourceLine As String

    While ReadC2fbTextFileLine(lineReader, sourceLine) <> 0
        If isInterfaceFile <> 0 OrElse indexImplementationLayouts <> 0 Then _
            IndexC2fbFbLayoutLine(catalog, layoutState, fileName, sourceLine)
        Dim declarationName As String = FbDeclarationName(sourceLine)
        Dim procedureDefinitionName As String = ""
        If isInterfaceFile = 0 Then _
            procedureDefinitionName = FbProcedureName(sourceLine)
        Dim signatureName As String = declarationName
        If signatureName = "" Then signatureName = procedureDefinitionName

        If pendingDeclaration = "" Then
            If signatureName <> "" Then pendingDeclaration = Trim(sourceLine)
        Else
            pendingDeclaration &= " " & Trim(sourceLine)
        End If
        If pendingDeclaration <> "" Then
            Dim trimmedDeclaration As String = RTrim(pendingDeclaration)
            If Right(trimmedDeclaration, 1) = "_" Then
                pendingDeclaration = RTrim(Left( _
                    trimmedDeclaration, Len(trimmedDeclaration) - 1))
            Else
                RecordFbBodyCallSignature( _
                    catalog, pendingDeclaration, signatureFallback)
                pendingDeclaration = ""
            End If
        End If

        If isInterfaceFile <> 0 Then
            AppendUniqueFreeBasicProjectName( _
                catalog.callableNames(), catalog.callableNameCount, _
                catalog.callableNameSet, _
                declarationName, _
                "FreeBASIC callable index exceeds the configured limit")
            Dim declarationAlias As String = FbDeclarationAliasName(sourceLine)
            AppendUniqueFreeBasicProjectName( _
                catalog.callableNames(), catalog.callableNameCount, _
                catalog.callableNameSet, _
                declarationAlias, _
                "FreeBASIC callable index exceeds the configured limit")
            If isLocalDeclarationFile <> 0 Then
                AppendUniqueFreeBasicProjectName( _
                    catalog.localDeclarationNames(), _
                    catalog.localDeclarationNameCount, _
                    catalog.localDeclarationNameSet, declarationName, _
                    "FreeBASIC local declaration index exceeds the configured limit")
                AppendUniqueFreeBasicProjectName( _
                    catalog.localDeclarationNames(), _
                    catalog.localDeclarationNameCount, _
                    catalog.localDeclarationNameSet, declarationAlias, _
                    "FreeBASIC local declaration index exceeds the configured limit")
            End If
        Else
            Dim loweredLine As String = LCase(LTrim(sourceLine))
            Dim declarationAlias As String = FbDeclarationAliasName(sourceLine)
            AppendUniqueFreeBasicProjectName( _
                catalog.callableNames(), catalog.callableNameCount, _
                catalog.callableNameSet, _
                declarationName, _
                "FreeBASIC callable index exceeds the configured limit")
            AppendUniqueFreeBasicProjectName( _
                catalog.callableNames(), catalog.callableNameCount, _
                catalog.callableNameSet, _
                declarationAlias, _
                "FreeBASIC callable index exceeds the configured limit")

            Dim procedureAlias As String = FbProcedureAliasName(sourceLine)
            AppendUniqueExistingFreeBasicProcedure( _
                catalog, procedureDefinitionName)
            AppendUniqueExistingFreeBasicProcedure(catalog, procedureAlias)
            If Left(loweredLine, 8) <> "private " AndAlso _
               Left(loweredLine, 7) <> "static " Then
                AppendUniqueFreeBasicProjectName( _
                    catalog.callableNames(), catalog.callableNameCount, _
                    catalog.callableNameSet, _
                    procedureDefinitionName, _
                    "FreeBASIC callable index exceeds the configured limit")
                AppendUniqueFreeBasicProjectName( _
                    catalog.callableNames(), catalog.callableNameCount, _
                    catalog.callableNameSet, _
                    procedureAlias, _
                    "FreeBASIC callable index exceeds the configured limit")
            End If
        End If
    Wend
    CloseC2fbTextFileLineReader(lineReader)
End Sub

Private Sub PrepareC2fbProjectCatalog( _
    ByRef catalog As C2fbProjectCatalog, ByVal sourceDirectory As String, _
    ByVal sourceRecursive As Long = 0 _
)
    If catalog.ready <> 0 AndAlso _
       catalog.sourceDirectory = sourceDirectory AndAlso _
       catalog.sourceRecursive = sourceRecursive Then Exit Sub

    ReDim catalog.callableNames(0 To 255)
    catalog.callableNameCount = 0
    ReDim catalog.localDeclarationNames(0 To 255)
    catalog.localDeclarationNameCount = 0
    ReDim catalog.existingProcedureNames(0 To 255)
    catalog.existingProcedureNameCount = 0
    ResetC2fbNameSet(catalog.callableNameSet)
    ResetC2fbNameSet(catalog.localDeclarationNameSet)
    ResetC2fbNameSet(catalog.existingProcedureNameSet)
    ReDim catalog.bodyCallSignatures(0 To 255)
    catalog.bodyCallSignatureCount = 0
    ResetC2fbStringIndexMap(catalog.bodyCallSignatureMap)
    ResetC2fbFbLayoutCatalog(catalog)

    If sourceDirectory <> "" Then
        Dim interfaceFiles As C2fbSourceFileSetModel
        If AppendC2fbSourceDirectoryFiles( _
            interfaceFiles, sourceDirectory, ".bi", 0, -1, _
            sourceRecursive) = 0 Then _
            ReportError("FreeBASIC interface tree exceeds the configured file limit")
        For fileIndex As Long = 0 To interfaceFiles.itemCount - 1
            Dim fileName As String = interfaceFiles.names(fileIndex)
            Dim isLocalDeclarationFile As Long = -1
            If fileName = "sqlite3_api_declarations.bi" OrElse _
               fileName = "sqlite3_internal_api_declarations.bi" Then _
                isLocalDeclarationFile = 0
            Dim layoutState As C2fbFbLayoutScanStateModel
            Dim isFallbackSignatureFile As Long = CInt( _
                fileName = "sqlite3_api_declarations.bi" OrElse _
                fileName = "sqlite3_internal_api_declarations.bi") * -1
            ResetC2fbFbLayoutFile(layoutState)
            IndexFreeBasicCatalogFile( _
                catalog, sourceDirectory, fileName, -1, _
                isLocalDeclarationFile, layoutState, 0, isFallbackSignatureFile)
        Next

        Dim implementationFiles As C2fbSourceFileSetModel
        If AppendC2fbSourceDirectoryFiles( _
            implementationFiles, sourceDirectory, ".bas", 0, -1, _
            sourceRecursive) = 0 Then _
            ReportError("FreeBASIC implementation tree exceeds the configured file limit")
        For fileIndex As Long = 0 To implementationFiles.itemCount - 1
            Dim layoutState As C2fbFbLayoutScanStateModel
            IndexFreeBasicCatalogFile( _
                catalog, sourceDirectory, implementationFiles.names(fileIndex), _
                0, 0, layoutState, -1)
        Next
    End If

    catalog.sourceDirectory = sourceDirectory
    catalog.sourceRecursive = sourceRecursive
    catalog.ready = -1
End Sub

/' end of c2fb_project_catalog.bi '/
