/'
    Project: C2FB diagnostics
    ------------------------

    File: c2fb_diagnostics.bi

    Purpose:

        Collect source-located diagnostics and send conversion rejections
        through the shared diagnostic output model.

    Responsibilities:

        - Format fatal command failures as diagnostic records and exit with status 1.
        - Bound and reset diagnostics for one translation invocation.
        - Create stable diagnostic codes from pass-owned reasons.
        - Record skipped declarations, body rejections, and preprocessing failures.
        - Route diagnostics to generated output or the shared console formatter.
        - Abort active generated files before a fatal command exit.

    This file intentionally does NOT contain:

        - C syntax classification or target-specific rejection policy.
        - FreeBASIC diagnostic formatting, option parsing, or command dispatch.
'/

' Bound stored diagnostics for one translation invocation.
Private Const MAX_C2FB_DIAGNOSTICS As Long = 65536
' Start small because most command invocations report only a few diagnostics.
Private Const INITIAL_C2FB_DIAGNOSTIC_CAPACITY As Long = 64

Private Sub ReportError(ByVal message As String)
    AbortAllC2fbGeneratedFileOutputs()
    Dim diagnostic As C2fbDiagnosticModel
    diagnostic.severity = C2FB_DIAGNOSTIC_SEVERITY_ERROR
    diagnostic.code = "fatal-error"
    diagnostic.message = message
    WriteC2fbDiagnosticConsole(diagnostic)
    End 1
End Sub

Private Sub ResetC2fbDiagnostics( _
    ByRef diagnosticState As C2fbDiagnosticStateModel _
)
    ReDim diagnosticState.diagnostics(0 To INITIAL_C2FB_DIAGNOSTIC_CAPACITY - 1)
    diagnosticState.diagnosticCount = 0
    diagnosticState.suppressWarningConsole = 0
    diagnosticState.currentSourceLocation.path = ""
    diagnosticState.currentSourceLocation.line = 0
    diagnosticState.currentSourceLocation.column = 0
End Sub

Private Sub ResetC2fbSourceUnitState( _
    ByRef sourceUnit As C2fbSourceUnitStateModel _
)
    sourceUnit.declarationCount = 0
    sourceUnit.libraryPragmaCount = 0
    ResetC2fbDiagnostics(sourceUnit.diagnosticState)
End Sub

Private Sub InitializeC2fbTranslationSession( _
    ByRef translation As C2fbTranslationContext _
)
    ResetC2fbTranslationTarget(translation)
    ResetC2fbSourceUnitState(translation.sourceUnit)
    translation.genericC.header.recordPlanCount = 0
End Sub

Private Sub AddC2fbDiagnostic( _
    ByRef translation As C2fbTranslationContext, _
    ByRef diagnostic As C2fbDiagnosticModel _
)
    If translation.sourceUnit.diagnosticState.diagnosticCount >= MAX_C2FB_DIAGNOSTICS Then _
        ReportError("translation exceeds the configured diagnostic limit")
    If translation.sourceUnit.diagnosticState.diagnosticCount > UBound(translation.sourceUnit.diagnosticState.diagnostics) Then
        ReDim Preserve translation.sourceUnit.diagnosticState.diagnostics( _
            0 To UBound(translation.sourceUnit.diagnosticState.diagnostics) * 2 + 1)
    End If
    translation.sourceUnit.diagnosticState.diagnostics(translation.sourceUnit.diagnosticState.diagnosticCount) = diagnostic
    translation.sourceUnit.diagnosticState.diagnosticCount += 1
End Sub

Private Function C2fbDiagnosticCode(ByVal reason As String) As String
    Dim result As String
    For position As Long = 1 To Len(reason)
        Dim currentByte As Long = Asc(reason, position)
        If currentByte = Asc(" ") Then
            result &= "-"
        ElseIf (currentByte >= Asc("a") AndAlso currentByte <= Asc("z")) OrElse _
               (currentByte >= Asc("0") AndAlso currentByte <= Asc("9")) OrElse _
               currentByte = Asc("-") Then
            result &= Chr(currentByte)
        End If
    Next
    Return result
End Function

Private Sub EmitC2fbSkippedAtLocation( _
    ByRef translation As C2fbTranslationContext, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, ByRef conversionSummary As C2fbConversionSummaryModel, _
    ByVal reason As String, ByVal sourceText As String, _
    ByRef sourceLocation As C2fbSourceLocationModel, _
    ByVal countAsSkipped As Long = -1 _
)
    Dim diagnostic As C2fbDiagnosticModel
    diagnostic.severity = C2FB_DIAGNOSTIC_SEVERITY_WARNING
    diagnostic.code = C2fbDiagnosticCode(reason)
    diagnostic.location = sourceLocation
    diagnostic.message = reason
    If Trim(sourceText) <> "" Then diagnostic.message &= ": " & Trim(sourceText)
    AddC2fbDiagnostic(translation, diagnostic)
    WriteC2fbSkippedDiagnostic(outputFile, diagnostic)
    If countAsSkipped <> 0 Then conversionSummary.skippedCount += 1
End Sub

Private Sub EmitC2fbSkipped( _
    ByRef translation As C2fbTranslationContext, _
    ByRef outputFile As C2fbGeneratedFileOutputModel, ByRef conversionSummary As C2fbConversionSummaryModel, _
    ByVal reason As String, ByVal sourceText As String, _
    ByVal countAsSkipped As Long = -1 _
)
    EmitC2fbSkippedAtLocation( _
        translation, outputFile, conversionSummary, reason, sourceText, _
        translation.sourceUnit.diagnosticState.currentSourceLocation, countAsSkipped)
End Sub

Private Sub ReportC2fbRejected( _
    ByRef translation As C2fbTranslationContext, _
    ByVal subject As String, ByVal reason As String, ByVal detail As String _
)
    Dim diagnostic As C2fbDiagnosticModel
    diagnostic.severity = C2FB_DIAGNOSTIC_SEVERITY_WARNING
    diagnostic.code = C2fbDiagnosticCode(reason)
    diagnostic.location = translation.sourceUnit.diagnosticState.currentSourceLocation
    diagnostic.message = subject & ": " & detail
    AddC2fbDiagnostic(translation, diagnostic)
    If translation.sourceUnit.diagnosticState.suppressWarningConsole = 0 Then _
        WriteC2fbDiagnosticConsole(diagnostic)
End Sub

Private Sub ReportC2fbPreprocessorFailure( _
    ByRef translation As C2fbTranslationContext, _
    ByRef result As C2fbPreprocessorResultModel, _
    ByVal operation As String _
)
    Dim diagnostic As C2fbDiagnosticModel
    diagnostic.severity = C2FB_DIAGNOSTIC_SEVERITY_ERROR
    diagnostic.code = "preprocessing-failed"
    diagnostic.location.path = result.inputPath
    diagnostic.location.line = 0
    diagnostic.message = operation
    If result.inputPath <> "" Then _
        diagnostic.message &= " for " & result.inputPath
    If result.failureReason <> "" Then _
        diagnostic.message &= ": " & result.failureReason
    AddC2fbDiagnostic(translation, diagnostic)
    WriteC2fbDiagnosticConsole(diagnostic)
End Sub

/' end of c2fb_diagnostics.bi '/
