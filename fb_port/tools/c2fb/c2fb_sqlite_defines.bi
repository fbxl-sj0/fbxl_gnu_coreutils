/'
    Project: C2FB SQLite adapters

    File: c2fb_sqlite_defines.bi

    Purpose:

        Convert simple SQLite integer defines into FreeBASIC constants.

    Responsibilities:

        - Select SQLite-specific macro names and omit build configuration inputs.
        - Track conflicting definitions across conditional branches.
        - Resolve references among supported numeric constants.
        - Emit constants and source-located skip diagnostics through shared output.

    This file intentionally does NOT contain:

        - C macro directive parsing or integer-expression normalization.
        - Generic-header macro lowering or complete preprocessor evaluation.
'/

' The initial table leaves room for the common public-header define set and
' grows only when a larger source file requires it.
Private Const INITIAL_SQLITE_DEFINE_CAPACITY As Long = 64

Private Function IsKnownConstantReference( _
    ByVal expression As String, _
    definitions() As C2fbSqliteDefineModel, _
    ByVal definitionCount As Long _
) As Long
    Dim i As Long = 1
    While i <= Len(expression)
        If Asc(expression, i) = Asc("&") AndAlso i < Len(expression) AndAlso _
           (Asc(expression, i + 1) = Asc("H") OrElse Asc(expression, i + 1) = Asc("h")) Then
            i += 2
            While i <= Len(expression) AndAlso IsHexDigit(Asc(expression, i))
                i += 1
            Wend
        ElseIf IsIdentifierStart(Asc(expression, i)) Then
            Dim start As Long = i
            i += 1
            While i <= Len(expression) AndAlso IsIdentifierPart(Asc(expression, i))
                i += 1
            Wend
            Dim identifier As String = Mid(expression, start, i - start)
            Select Case identifier
            Case "And", "Or", "Xor", "Not", "Shl", "Shr"
                Continue While
            End Select
            Dim found As Long = 0
            For j As Long = 0 To definitionCount - 1
                If definitions(j).definition.sourceName = identifier AndAlso _
                   definitions(j).ambiguous = 0 Then
                    found = -1
                    Exit For
                End If
            Next
            If found = 0 Then Return 0
        Else
            i += 1
        End If
    Wend
    Return -1
End Function

Private Function ParseDefineLine( _
    ByVal lineText As String, _
    ByRef macro As C2fbMacroDefinitionModel _
) As Long
    If ParseC2fbMacroDirective(lineText, macro) = 0 OrElse _
       macro.directive <> "define" OrElse macro.functionLike <> 0 OrElse _
       macro.rawValue = "" Then Return 0
    If Left(macro.sourceName, Len("SQLITE_")) <> "SQLITE_" Then Return 0
    Return -1
End Function

Private Function IsBuildConfigurationMacro(ByVal macroName As String) As Long
    Select Case macroName
    Case "SQLITE_STDCALL", "SQLITE_THREADSAFE", "SQLITE_WASI"
        ' These select compiler or platform behavior and must remain build inputs.
        Return -1
    End Select
    Return 0
End Function

Private Sub ConvertDefines( _
    ByRef translation As C2fbTranslationContext, _
    ByRef request As C2fbFileConversionRequestModel _
)
    Dim inputPath As String = request.inputPath
    Dim outputPath As String = request.outputPath
    If ConfigureC2fbTranslationTarget( _
        translation, C2FB_TARGET_SQLITE, _
        C2FB_SOURCE_MAP_DISABLED) = 0 Then _
        ReportError("invalid SQLite define target context")
    translation.sourceUnit.diagnosticState.currentSourceLocation.path = inputPath
    translation.sourceUnit.diagnosticState.currentSourceLocation.line = 0
    Dim lineReader As C2fbLogicalSourceLineReaderModel
    If OpenC2fbLogicalSourceLineReader(lineReader, inputPath) = 0 Then _
        ReportError("cannot read SQLite definitions file: " & inputPath)
    Dim definitions() As C2fbSqliteDefineModel
    ReDim definitions(0 To INITIAL_SQLITE_DEFINE_CAPACITY - 1)
    Dim definitionCount As Long = 0
    Dim conversionSummary As C2fbConversionSummaryModel
    Dim firstLine As Long
    Dim wasContinued As Long
    Dim isComplete As Long
    Dim lineText As String

    While ReadC2fbLogicalLine( _
        lineReader, lineText, firstLine, wasContinued, isComplete) <> 0
        translation.sourceUnit.diagnosticState.currentSourceLocation.line = _
            C2fbLogicalSourceLineNumber(lineReader)
        Dim macro As C2fbMacroDefinitionModel
        If ParseDefineLine(lineText, macro) = 0 Then Continue While
        If isComplete = 0 Then
            conversionSummary.skippedCount += 1
            Continue While
        End If
        macro.sourceLocation.path = inputPath
        macro.sourceLocation.line = firstLine
        macro.continued = wasContinued
        If IsBuildConfigurationMacro(macro.sourceName) <> 0 Then
            conversionSummary.skippedCount += 1
            Continue While
        End If

        Dim convertedValue As String
        If ConvertIntegerExpression( _
            macro.rawValue, convertedValue, C2FB_INTEGER_IDENTIFIERS_SQLITE) = 0 Then
            conversionSummary.skippedCount += 1
            Continue While
        End If

        Dim found As Long = 0
        For i As Long = 0 To definitionCount - 1
            If definitions(i).definition.sourceName = macro.sourceName Then
                found = -1
                If definitions(i).integerExpression <> convertedValue Then _
                    definitions(i).ambiguous = -1
                Exit For
            End If
        Next
        If found = 0 Then
            If definitionCount >= MAX_FUNCTIONS Then _
                ReportError("SQLite numeric define count exceeds the configured limit")
            If definitionCount > UBound(definitions) Then
                ReDim Preserve definitions(0 To UBound(definitions) * 2 + 1)
            End If
            definitions(definitionCount).definition = macro
            definitions(definitionCount).integerExpression = convertedValue
            definitionCount += 1
        End If
    Wend
    CloseC2fbLogicalSourceLineReader(lineReader)

    Dim fileOutput As C2fbGeneratedFileOutputModel
    If OpenC2fbGeneratedFileOutput(fileOutput, outputPath) = 0 Then _
        ReportError("cannot write FreeBASIC constants file: " & outputPath)
    Dim fileComment As C2fbGeneratedFileCommentModel
    ResetC2fbGeneratedFileComment(fileComment)
    If AddC2fbGeneratedFileCommentLine( _
        fileComment, "    Generated simple SQLITE_* constants") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
        fileComment, "    Source: " & inputPath) = 0 OrElse _
        AddC2fbGeneratedFileCommentLine( _
        fileComment, "    Generated by fb_tools/c2fb/c2fb.bas. Build configuration macros are omitted.") = 0 Then _
        ReportError("constants file comment exceeds its limit")
    Dim filePreamble As C2fbGeneratedFilePreambleModel
    WriteC2fbGeneratedFilePreamble(fileOutput, fileComment, filePreamble)
    Dim fileGuard As C2fbGeneratedFileGuardModel
    If BeginC2fbGeneratedFileGuard( _
        fileOutput, fileGuard, "SQLITE3_FB_API_CONSTANTS_BI") = 0 Then _
        ReportError("cannot open the SQLite constants include guard")

    For i As Long = 0 To definitionCount - 1
        If definitions(i).ambiguous <> 0 Then
            EmitC2fbSkippedAtLocation(translation,  _
                fileOutput, conversionSummary, "conflicting conditional definition", _
                definitions(i).definition.sourceName, _
                definitions(i).definition.sourceLocation, 0)
            conversionSummary.sqliteDefines.ambiguousCount += 1
        ElseIf IsKnownConstantReference( _
            definitions(i).integerExpression, definitions(), definitionCount) = 0 Then
            EmitC2fbSkippedAtLocation(translation,  _
                fileOutput, conversionSummary, "unresolved constant expression", _
                definitions(i).definition.sourceName, _
                definitions(i).definition.sourceLocation)
        Else
            Dim macroBinding As C2fbMacroBindingModel
            macroBinding.name = definitions(i).definition.sourceName
            macroBinding.bodyText = definitions(i).integerExpression
            WriteC2fbMacroBinding(fileOutput, macroBinding)
            conversionSummary.convertedCount += 1
        End If
    Next
    WriteC2fbGeneratedFileLine(fileOutput, "")
    If EndC2fbGeneratedFileGuard(fileOutput, fileGuard) = 0 Then _
        ReportError("cannot close the SQLite constants include guard")
    WriteC2fbGeneratedFileEndMarker(fileOutput)
    CloseC2fbGeneratedFileOutput(fileOutput)
    If C2fbGeneratedFileOutputHasFailed(fileOutput) <> 0 Then _
        ReportError(C2fbGeneratedFileOutputFailureMessage( _
            fileOutput, "cannot finish FreeBASIC constants file: " & outputPath))
    Print "converted " & Trim(Str(conversionSummary.convertedCount)) & _
        " numeric constants; skipped " & Trim(Str(conversionSummary.skippedCount)) & _
        " expressions and " & Trim(Str(conversionSummary.sqliteDefines.ambiguousCount)) & _
        " conflicting conditional definitions; output " & outputPath
End Sub
/' end of c2fb_sqlite_defines.bi '/
