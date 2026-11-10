/'
    Project: SQLite C2FB support tools
    ----------------------------------

    File: api_routines.bas

    Purpose:

        Preserve the standalone command-line entry point for the SQLite
        extension API table adapter.

    Responsibilities:

        - Normalize the legacy four-path command line.
        - Call the shared C2FB API-table generator.
        - Preserve the standalone usage and error messages.

    This file intentionally does NOT contain:

        - API initializer parsing or output generation.
        - A parser for arbitrary C expressions or declarations.
'/

#lang "fb"

#include once "c2fb_model.bi"
#include once "c2fb_output.bi"
#include once "c2fb_csv_output.bi"
#include once "c2fb_file_input.bi"
#include once "c2fb_api_routines.bi"

Private Sub reportError(ByRef message As String)
    AbortAllC2fbGeneratedFileOutputs()
    Print "api-routines: " & message
    End 2
End Sub

Dim request As C2fbApiRoutinesRequestModel
request.preprocessedInputPath = Command(1)
request.functionLedgerPath = Command(2)
request.ownerModulePath = Command(3)
request.outputPath = Command(4)
If request.preprocessedInputPath = "" OrElse _
   request.functionLedgerPath = "" OrElse _
   request.ownerModulePath = "" OrElse request.outputPath = "" Then
    Print "usage: api_routines loadext.i PORTING_FUNCTIONS.csv owner.bas output.bi"
    End 2
End If

Dim result As C2fbApiRoutinesResultModel
Dim errorMessage As String
If ConvertC2fbApiRoutines(request, result, errorMessage) = 0 Then _
    reportError(errorMessage)

PrintC2fbApiRoutinesSummary(result, request.outputPath)

/' end of api_routines.bas '/
