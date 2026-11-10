/'
    Project: C2FB

    File: c2fb_function_index.bi

    Purpose:

        Index C function definitions and reconcile them with FreeBASIC procedures.

    Responsibilities:

        - Consume shared function declarations and source spans in inventory mode.
        - Apply per-file and cross-file duplicate rules.
        - Submit typed function-index records to the CSV output backend.
        - Select C source files and own the inventory CSV lifecycle and summary.
        - Index FreeBASIC declarations, procedures, and aliases for reconciliation.
        - Update reconciliation status through the shared CSV row model.

    This file intentionally does NOT contain:

        - Target type mapping or C function-body lowering.
        - Preprocessor evaluation or general translation-unit collection.
'/

Private Function FunctionSizeClass(ByVal lineCount As Long) As String
    If lineCount <= 20 Then Return "small"
    If lineCount <= 80 Then Return "medium"
    Return "large"
End Function

Private Sub WriteFunctionRow( _
    ByRef outputModel As C2fbCsvFileOutputModel, _
    ByVal upstreamSource As String, _
    ByRef declaration As C2fbDeclarationModel _
)
    Dim lineCount As Long = declaration.sourceSpan.endLocation.line - _
                            declaration.sourceSpan.startLocation.line + 1
    Dim record As C2fbFunctionIndexRecordModel
    record.upstreamSource = upstreamSource
    record.functionName = declaration.sourceName
    record.firstLine = declaration.sourceSpan.startLocation.line
    record.lastLine = declaration.sourceSpan.endLocation.line
    record.lineCount = lineCount
    record.sizeClass = FunctionSizeClass(lineCount)
    record.portStatus = "Needs mapping"
    If WriteC2fbFunctionIndexRecord(outputModel, record) = 0 Then _
        ReportError("cannot write an incomplete function index row")
End Sub

Private Sub IndexCFile( _
    ByVal inputPath As String, _
    ByVal sourceName As String, _
    ByRef outputModel As C2fbCsvFileOutputModel, _
    globalNames() As String, ByRef globalNameCount As Long, _
    ByVal skipGlobalDuplicates As Long = 0 _
)
    Dim sourceUnit As C2fbSourceUnitStateModel
    ResetC2fbSourceUnitState(sourceUnit)
    sourceUnit.diagnosticState.currentSourceLocation.path = inputPath
    Dim scanRequest As C2fbDeclarationScanRequestModel
    ConfigureC2fbFunctionInventoryScanRequest( _
        scanRequest, inputPath, inputPath)
    Dim scanner As C2fbFunctionScanner
    If OpenC2fbFunctionScanner(scanner, scanRequest) = 0 Then _
        ReportError("cannot read C function index input: " & inputPath)

    Dim indexedNames() As String
    ReDim indexedNames(0 To MAX_FUNCTIONS - 1)
    Dim indexedNameCount As Long = 0
    Dim sourceItem As C2fbSourceItemModel
    While NextC2fbSourceItem(sourceUnit, scanner, sourceItem) <> 0
        If sourceItem.declaration.isFunctionDefinition = 0 Then Continue While
        Dim functionName As String = sourceItem.declaration.sourceName
        If functionName = "" Then Continue While

        Dim isDuplicate As Long = 0
        For nameIndex As Long = 0 To indexedNameCount - 1
            If indexedNames(nameIndex) = functionName Then
                isDuplicate = -1
                Exit For
            End If
        Next
        If isDuplicate = 0 Then
            If indexedNameCount >= MAX_FUNCTIONS Then _
                ReportError("source file exceeds the function index limit")
            indexedNames(indexedNameCount) = functionName
            indexedNameCount += 1

            Dim globalDuplicate As Long = 0
            For globalIndex As Long = 0 To globalNameCount - 1
                If globalNames(globalIndex) = functionName Then
                    globalDuplicate = -1
                    Exit For
                End If
            Next
            If globalDuplicate = 0 Then
                If globalNameCount >= MAX_FUNCTIONS Then _
                    ReportError("function index exceeds the configured name limit")
                If globalNameCount > UBound(globalNames) Then _
                    ReDim Preserve globalNames(0 To UBound(globalNames) * 2 + 1)
                globalNames(globalNameCount) = functionName
                globalNameCount += 1
            End If
            If globalDuplicate = 0 OrElse skipGlobalDuplicates = 0 Then _
                WriteFunctionRow( _
                    outputModel, sourceName, sourceItem.declaration)
        End If
    Wend
    CloseC2fbFunctionScanner(scanner)
End Sub

Private Sub ConvertFunctionTree( _
    ByRef request As C2fbFunctionIndexRequestModel _
)
    Dim sourceDirectory As String = request.sourceDirectory
    Dim outputPath As String = request.outputPath
    Dim sourceScope As C2fbFunctionIndexSourceScope = request.sourceScope
    If sourceScope <> C2FB_FUNCTION_INDEX_SCOPE_C_ONLY AndAlso _
       sourceScope <> C2FB_FUNCTION_INDEX_SCOPE_C_AND_HEADERS Then _
        ReportError("invalid function-index source scope")
    Dim outputModel As C2fbCsvFileOutputModel
    If OpenC2fbCsvFileOutput(outputModel, outputPath) = 0 Then _
        ReportError("cannot write function index file: " & outputPath)
    If WriteC2fbFunctionIndexHeader(outputModel) = 0 Then _
        ReportError("cannot write function index header")

    Dim globalNames() As String
    ReDim globalNames(0 To 255)
    Dim globalNameCount As Long = 0
    Dim sourceFiles As C2fbSourceFileSetModel
    If AppendC2fbSourceDirectoryFiles( _
        sourceFiles, sourceDirectory, ".c", -1, -1) = 0 Then _
        ReportError("function index source tree exceeds the configured file limit")

    If sourceScope = C2FB_FUNCTION_INDEX_SCOPE_C_AND_HEADERS Then
        If AppendC2fbSourceDirectoryFiles( _
            sourceFiles, sourceDirectory, ".h", -1, 0) = 0 Then _
            ReportError("function index source tree exceeds the configured file limit")
    End If

    For fileIndex As Long = 0 To sourceFiles.itemCount - 1
        Dim fileName As String = sourceFiles.names(fileIndex)
        Dim sourceName As String = FileNameOnly(sourceDirectory) & "/" & fileName
        Dim inputPath As String = sourceDirectory & "/" & fileName
        If LCase(Right(fileName, 2)) = ".h" Then
            IndexCFile(inputPath, sourceName, outputModel, _
                       globalNames(), globalNameCount, -1)
        Else
            IndexCFile(inputPath, sourceName, outputModel, _
                       globalNames(), globalNameCount)
        End If
    Next

    If CloseC2fbCsvFileOutput(outputModel) = 0 Then _
        ReportError(C2fbGeneratedFileOutputFailureMessage( _
            outputModel.fileOutput, "cannot finish function index output: " & outputPath))
    Print "indexed " & IIf( _
        sourceScope = C2FB_FUNCTION_INDEX_SCOPE_C_AND_HEADERS, _
        "C and header", "C") & _
        " definitions from " & sourceDirectory & "; output " & outputPath
End Sub

Private Function FbDeclarationName(ByVal sourceLine As String) As String
    Dim lineText As String = LTrim(sourceLine)
    Dim position As Long = 1
    Dim word As String = ""
    While position <= Len(lineText) AndAlso IsIdentifierPart(Asc(lineText, position)) <> 0
        word &= Mid(lineText, position, 1)
        position += 1
    Wend
    If word <> "Declare" Then Return ""

    While position <= Len(lineText) AndAlso IsSpaceByte(Asc(lineText, position)) <> 0
        position += 1
    Wend
    word = ""
    While position <= Len(lineText) AndAlso IsIdentifierPart(Asc(lineText, position)) <> 0
        word &= Mid(lineText, position, 1)
        position += 1
    Wend
    If word <> "Function" AndAlso word <> "Sub" Then Return ""

    While position <= Len(lineText) AndAlso IsSpaceByte(Asc(lineText, position)) <> 0
        position += 1
    Wend
    Dim procedureName As String = ""
    If position > Len(lineText) OrElse IsIdentifierStart(Asc(lineText, position)) = 0 Then Return ""
    While position <= Len(lineText) AndAlso IsIdentifierPart(Asc(lineText, position)) <> 0
        procedureName &= Mid(lineText, position, 1)
        position += 1
    Wend
    Return procedureName
End Function

Private Function FbProcedureName(ByVal sourceLine As String) As String
    Dim lineText As String = LTrim(sourceLine)
    If Len(lineText) = 0 OrElse Left(lineText, 1) = "'" OrElse _
       Left(lineText, 2) = "/'" OrElse Left(lineText, 1) = "#" Then Return ""

    Dim position As Long = 1
    Dim firstWord As String = ""
    While position <= Len(lineText) AndAlso IsIdentifierPart(Asc(lineText, position)) <> 0
        firstWord &= Mid(lineText, position, 1)
        position += 1
    Wend
    If firstWord = "Private" OrElse firstWord = "Public" OrElse firstWord = "Static" Then
        While position <= Len(lineText) AndAlso IsSpaceByte(Asc(lineText, position)) <> 0
            position += 1
        Wend
        firstWord = ""
        While position <= Len(lineText) AndAlso IsIdentifierPart(Asc(lineText, position)) <> 0
            firstWord &= Mid(lineText, position, 1)
            position += 1
        Wend
    End If
    If firstWord <> "Function" AndAlso firstWord <> "Sub" Then Return ""

    While position <= Len(lineText) AndAlso IsSpaceByte(Asc(lineText, position)) <> 0
        position += 1
    Wend
    Dim procedureName As String = ""
    If position > Len(lineText) OrElse IsIdentifierStart(Asc(lineText, position)) = 0 Then Return ""
    While position <= Len(lineText) AndAlso IsIdentifierPart(Asc(lineText, position)) <> 0
        procedureName &= Mid(lineText, position, 1)
        position += 1
    Wend
    Return procedureName
End Function

Private Function FbProcedureAliasName(ByVal sourceLine As String) As String
    If Len(FbProcedureName(sourceLine)) = 0 Then Return ""
    Dim loweredLine As String = LCase(sourceLine)
    Dim aliasPosition As Long = InStr(loweredLine, " alias ")
    If aliasPosition = 0 Then Return ""
    Dim position As Long = aliasPosition + Len(" alias ")
    If position > Len(sourceLine) OrElse Asc(sourceLine, position) <> Asc("""") Then Return ""
    position += 1
    Dim aliasStart As Long = position
    While position <= Len(sourceLine) AndAlso Asc(sourceLine, position) <> Asc("""")
        position += 1
    Wend
    If position > Len(sourceLine) Then Return ""
    Dim procedureAlias As String = Mid(sourceLine, aliasStart, position - aliasStart)
    If IsIdentifierToken(procedureAlias) = 0 Then Return ""
    Return procedureAlias
End Function

Private Function FbDeclarationAliasName(ByVal sourceLine As String) As String
    If Len(FbDeclarationName(sourceLine)) = 0 Then Return ""
    Dim loweredLine As String = LCase(sourceLine)
    Dim aliasPosition As Long = InStr(loweredLine, " alias ")
    If aliasPosition = 0 Then Return ""
    Dim position As Long = aliasPosition + Len(" alias ")
    If position > Len(sourceLine) OrElse Asc(sourceLine, position) <> Asc(Chr(34)) Then Return ""
    position += 1
    Dim aliasStart As Long = position
    While position <= Len(sourceLine) AndAlso Asc(sourceLine, position) <> Asc(Chr(34))
        position += 1
    Wend
    If position > Len(sourceLine) Then Return ""
    Dim procedureAlias As String = Mid(sourceLine, aliasStart, position - aliasStart)
    If IsIdentifierToken(procedureAlias) = 0 Then Return ""
    Return procedureAlias
End Function

Private Function HasProcedureName( _
    names() As String, _
    ByVal nameCount As Long, _
    ByVal procedureName As String _
) As Long
    For i As Long = 0 To nameCount - 1
        If names(i) = procedureName Then Return -1
    Next
    Return 0
End Function

Private Sub IndexFbProcedures( _
    ByVal sourceDirectory As String, _
    names() As String, _
    ByRef nameCount As Long _
)
    ReDim names(0 To 255)
    nameCount = 0
    If sourceDirectory = "" Then Exit Sub
    Dim sourceFiles As C2fbSourceFileSetModel
    If AppendC2fbSourceDirectoryFiles( _
        sourceFiles, sourceDirectory, ".bas", 0, -1) = 0 Then _
        ReportError("FreeBASIC implementation tree exceeds the configured file limit")
    If AppendC2fbSourceDirectoryFiles( _
        sourceFiles, sourceDirectory, ".bi", 0, 0) = 0 Then _
        ReportError("FreeBASIC include tree exceeds the configured file limit")
    For fileIndex As Long = 0 To sourceFiles.itemCount - 1
        Dim fileName As String = sourceFiles.names(fileIndex)
        Dim lineReader As C2fbTextFileLineReaderModel
        If OpenC2fbTextFileLineReader( _
            lineReader, sourceDirectory & "/" & fileName) = 0 Then _
            ReportError("cannot read FreeBASIC implementation file: " & fileName)
        Dim sourceLine As String
        While ReadC2fbTextFileLine(lineReader, sourceLine) <> 0
            Dim procedureName As String = FbProcedureName(sourceLine)
            If Len(procedureName) <> 0 AndAlso _
               HasProcedureName(names(), nameCount, procedureName) = 0 Then
                If nameCount >= UBound(names) Then ReDim Preserve names(0 To UBound(names) * 2 + 1)
                names(nameCount) = procedureName
                nameCount += 1
            End If
            Dim procedureAlias As String = FbProcedureAliasName(sourceLine)
            If Len(procedureAlias) <> 0 AndAlso _
               HasProcedureName(names(), nameCount, procedureAlias) = 0 Then
                If nameCount >= UBound(names) Then ReDim Preserve names(0 To UBound(names) * 2 + 1)
                names(nameCount) = procedureAlias
                nameCount += 1
            End If
        Wend
        CloseC2fbTextFileLineReader(lineReader)
    Next
End Sub

Private Sub ReconcileFunctionTree( _
    ByRef request As C2fbFunctionReconcileRequestModel _
)
    Dim csvPath As String = request.csvPath
    Dim fbDirectory As String = request.fbDirectory
    Dim rows(0 To MAX_FUNCTIONS + 1) As String
    Dim rowCount As Long = 0
    Dim lineReader As C2fbTextFileLineReaderModel
    If OpenC2fbTextFileLineReader(lineReader, csvPath) = 0 Then _
        ReportError("cannot read function CSV: " & csvPath)
    Dim sourceLine As String
    While ReadC2fbTextFileLine(lineReader, sourceLine) <> 0
        If rowCount > UBound(rows) Then
            CloseC2fbTextFileLineReader(lineReader)
            ReportError("function CSV exceeds the configured row limit")
        End If
        rows(rowCount) = sourceLine
        rowCount += 1
    Wend
    CloseC2fbTextFileLineReader(lineReader)

    Dim procedureNames() As String
    Dim procedureCount As Long
    IndexFbProcedures(fbDirectory, procedureNames(), procedureCount)

    Dim outputModel As C2fbCsvFileOutputModel
    If OpenC2fbCsvFileOutput(outputModel, csvPath) = 0 Then _
        ReportError("cannot rewrite function CSV: " & csvPath)
    Dim reconciledFunctionCount As Long = 0
    For rowIndex As Long = 0 To rowCount - 1
        Dim outputRow As C2fbCsvRowModel
        Dim csvError As String
        If ParseC2fbCsvRow(rows(rowIndex), outputRow, csvError) = 0 Then _
            ReportError("invalid function CSV row " & Trim(Str(rowIndex + 1)) & _
                        ": " & csvError)
        If rowIndex > 0 AndAlso outputRow.fieldCount >= 7 AndAlso _
           HasProcedureName( _
                procedureNames(), procedureCount, outputRow.fields(1).value) <> 0 Then
            If outputRow.fields(6).value = "Needs mapping" OrElse _
               outputRow.fields(6).value = "FB body present" Then
                outputRow.fields(6).value = "FB body present"
                reconciledFunctionCount += 1
            End If
        End If
        For fieldIndex As Long = 0 To outputRow.fieldCount - 1
            outputRow.fields(fieldIndex).quote = -1
        Next
        If WriteC2fbCsvRow(outputModel, outputRow) = 0 Then _
            ReportError("cannot write a function CSV row")
    Next
    If CloseC2fbCsvFileOutput(outputModel) = 0 Then _
        ReportError(C2fbGeneratedFileOutputFailureMessage( _
            outputModel.fileOutput, "cannot finish reconciled function CSV: " & csvPath))

    Print "indexed " & Trim(Str(procedureCount)) & " FreeBASIC procedure names and aliases; marked " & _
        Trim(Str(reconciledFunctionCount)) & _
        " indexed functions with an FB body in " & csvPath
End Sub

/' end of c2fb_function_index.bi '/
