/'
    Project: C2FB command adapters
    ------------------------------

    File: c2fb_api_routines_adapter.bi

    Purpose:

        Adapt the typed API-table request to the shared generator core.

    Responsibilities:

        - Report generation failures through the C2FB diagnostic path.
        - Format the adapter's successful result summary.

    This file intentionally does NOT contain:

        - API struct or initializer parsing.
        - Generated table layout or file output.
'/

Private Sub ConvertC2fbApiRoutinesRequest( _
    ByRef request As C2fbApiRoutinesRequestModel _
)
    Dim result As C2fbApiRoutinesResultModel
    Dim errorMessage As String
    If ConvertC2fbApiRoutines(request, result, errorMessage) = 0 Then _
        ReportError(errorMessage)
    PrintC2fbApiRoutinesSummary(result, request.outputPath)
End Sub

/' end of c2fb_api_routines_adapter.bi '/
