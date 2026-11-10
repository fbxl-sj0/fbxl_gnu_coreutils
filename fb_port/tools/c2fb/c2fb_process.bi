/'
    Project: C2FB process execution
    ------------------------------

    File: c2fb_process.bi

    Purpose:

        Execute the compiler and system commands requested by C2FB adapters.

    Responsibilities:

        - Run shell commands through one quoting and status path.
        - Execute typed C preprocessor requests and validate their output files.
        - Remove partial preprocessor output after a failed command.
        - Create directory trees for batch adapters.
        - Check file existence and length without changing directory iteration.

    This file intentionally does NOT contain:

        - Compiler switch selection or source-file selection policy.
        - C parsing, translation, or generated-file output.
'/

Private Function RunShellCommand( _
    ByVal commandName As String, _
    ByVal commandArguments As String _
) As Long
    Dim commandText As String = ShellQuote(commandName) & " " & commandArguments
    Return c2fbSystem(StrPtr(commandText))
End Function

Private Function RunC2fbPreprocessor( _
    ByRef request As C2fbPreprocessorRequestModel, _
    ByRef result As C2fbPreprocessorResultModel _
) As Long
    result.inputPath = request.inputPath
    result.outputPath = request.outputPath
    result.compilerStatus = 0
    result.failureReason = ""
    If Trim(request.compilerName) = "" OrElse _
       request.inputPath = "" OrElse request.outputPath = "" Then
        result.failureReason = "incomplete compiler request"
        Return 0
    End If

    Dim compilerArguments As String = Trim(request.compilerOptions)
    If compilerArguments <> "" Then compilerArguments &= " "
    compilerArguments &= ShellQuote(request.inputPath) & _
        " -o " & ShellQuote(request.outputPath)
    result.compilerStatus = RunShellCommand( _
        request.compilerName, compilerArguments)
    If result.compilerStatus <> 0 Then
        result.failureReason = "compiler exited with status " & _
            Trim(Str(result.compilerStatus))
    ElseIf FileLengthIfPresent(request.outputPath) < 0 Then
        result.failureReason = "compiler produced no output file"
    End If
    If result.failureReason <> "" Then
        ' Failed preprocessing must not leave a partial file that a later
        ' conversion could mistake for current input.
        If FileLengthIfPresent(request.outputPath) >= 0 Then _
            Kill request.outputPath
        Return 0
    End If
    Return -1
End Function

Private Function MakeDirectoryTree(ByVal directoryPath As String) As Long
    Return CInt(RunShellCommand("mkdir", "-p " & ShellQuote(directoryPath)) = 0)
End Function
/' end of c2fb_process.bi '/
