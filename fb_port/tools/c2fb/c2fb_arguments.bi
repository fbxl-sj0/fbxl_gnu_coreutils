/'
    Project: C2FB input adapters

    File: c2fb_arguments.bi

    Purpose:

        Expand bounded compiler argument lists and prepare shell-safe values.

    Responsibilities:

        - Grow shared argument lists within caller-selected bounds.
        - Expand response files while rejecting cycles and excessive nesting.
        - Quote shell arguments consistently for compiler and system calls.
        - Separate a compiler name from its forwarded options.

    This file intentionally does NOT contain:

        - Mode-specific option policy or command dispatch.
        - Compiler execution, source selection, or C parsing.
'/

Private Function AppendC2fbArgumentValue( _
    ByRef arguments As C2fbArgumentListModel, ByVal argumentText As String, _
    ByVal maximumCount As Long _
) As Long
    If maximumCount <= 0 OrElse arguments.itemCount >= maximumCount Then Return 0
    If arguments.itemCount >= arguments.capacity Then
        If arguments.capacity = 0 Then
            arguments.capacity = 32
            If arguments.capacity > maximumCount Then _
                arguments.capacity = maximumCount
            ReDim arguments.values(0 To arguments.capacity - 1)
        Else
            Dim nextCapacity As Long = arguments.capacity * 2
            If nextCapacity > maximumCount Then nextCapacity = maximumCount
            ReDim Preserve arguments.values(0 To nextCapacity - 1)
            arguments.capacity = nextCapacity
        End If
    End If
    arguments.values(arguments.itemCount) = argumentText
    arguments.itemCount += 1
    Return -1
End Function

Private Function AppendC2fbResponseArgument( _
    ByVal argumentText As String, ByRef arguments As C2fbArgumentListModel, _
    responseStack() As String, ByVal responseDepth As Long, _
    ByVal argumentContext As String, ByRef errorMessage As String _
) As Long
    errorMessage = ""
    If Left(argumentText, 1) <> "@" Then
        If AppendC2fbArgumentValue( _
            arguments, argumentText, MAX_FUNCTIONS) = 0 Then
            errorMessage = argumentContext & _
                " argument list exceeds its configured limit"
            Return 0
        End If
        Return -1
    End If

    Dim responsePath As String = Trim(Mid(argumentText, 2))
    If responsePath = "" Then
        errorMessage = "@ response file path must not be empty"
        Return 0
    End If
    If responseDepth >= MAX_GENERIC_RESPONSE_DEPTH Then
        errorMessage = argumentContext & _
            " response-file nesting exceeds its configured limit"
        Return 0
    End If
    For parentDepth As Long = 0 To responseDepth - 1
        If responseStack(parentDepth) = responsePath Then
            errorMessage = "cycle in " & argumentContext & _
                " response files: " & responsePath
            Return 0
        End If
    Next

    Dim responseReader As C2fbTextFileLineReaderModel
    If OpenC2fbTextFileLineReader(responseReader, responsePath) = 0 Then
        errorMessage = "cannot read " & argumentContext & _
            " response file: " & responsePath
        Return 0
    End If
    responseStack(responseDepth) = responsePath
    Dim lineText As String
    While ReadC2fbTextFileLine(responseReader, lineText) <> 0
        lineText = Trim(lineText)
        If lineText = "" OrElse Left(lineText, 1) = "#" Then Continue While
        If AppendC2fbResponseArgument( _
            lineText, arguments, responseStack(), responseDepth + 1, _
            argumentContext, errorMessage) = 0 Then
            CloseC2fbTextFileLineReader(responseReader)
            Return 0
        End If
    Wend
    CloseC2fbTextFileLineReader(responseReader)
    Return -1
End Function

Private Function ShellQuote(ByVal value As String) As String
    Dim quoted As String = Chr(39)
    For i As Long = 1 To Len(value)
        If Asc(value, i) = Asc(Chr(39)) Then
            quoted &= Chr(39) & Chr(92) & Chr(39) & Chr(39)
        Else
            quoted &= Mid(value, i, 1)
        End If
    Next
    Return quoted & Chr(39)
End Function

Private Sub BuildC2fbCompilerOptions( _
    ByRef arguments As C2fbArgumentListModel, _
    ByVal defaultCompiler As String, _
    ByRef compilerName As String, ByRef compilerOptions As String _
)
    compilerName = defaultCompiler
    Dim firstOption As Long = 0
    If arguments.itemCount > 0 AndAlso _
       Left(arguments.values(0), 1) <> "-" Then
        compilerName = arguments.values(0)
        firstOption = 1
    End If

    compilerOptions = ""
    For optionIndex As Long = firstOption To arguments.itemCount - 1
        compilerOptions &= " " & ShellQuote(arguments.values(optionIndex))
    Next
End Sub

/' end of c2fb_arguments.bi '/
