/'
    Project: C2FB physical source input
    -----------------------------------

    File: c2fb_source_lines.bi

    Purpose:

        Apply C source-line state over the shared text-file input backend.

    Responsibilities:

        - Provide raw physical lines to logical directive readers.
        - Track C source locations separately from underlying file positions.
        - Preserve multiline block-comment state for scanner-facing reads.
        - Strip comments once for each physical line returned to a scanner.

    This file intentionally does NOT contain:

        - Preprocessor continuation joining or conditional-branch policy.
        - Declaration parsing, function indexing, or translation policy.
'/

Private Type C2fbPhysicalSourceLineReaderModel
    textReader As C2fbTextFileLineReaderModel
    ' This may follow a preprocessor marker instead of physical file position.
    lineNumber As Long
    insideBlockComment As Long
End Type

Private Function OpenC2fbPhysicalSourceLineReader( _
    ByRef reader As C2fbPhysicalSourceLineReaderModel, _
    ByVal inputPath As String _
) As Long
    CloseC2fbTextFileLineReader(reader.textReader)
    reader.lineNumber = 0
    reader.insideBlockComment = 0
    If Trim(inputPath) = "" Then Return 0
    If OpenC2fbTextFileLineReader(reader.textReader, inputPath) = 0 Then Return 0
    Return -1
End Function

Private Function ReadC2fbRawPhysicalSourceLine( _
    ByRef reader As C2fbPhysicalSourceLineReaderModel, _
    ByRef lineText As String _
) As Long
    lineText = ""
    If ReadC2fbTextFileLine(reader.textReader, lineText) = 0 Then Return 0
    reader.lineNumber += 1
    Return -1
End Function

Private Function ReadC2fbPhysicalSourceLine( _
    ByRef reader As C2fbPhysicalSourceLineReaderModel, _
    ByRef lineText As String _
) As Long
    If ReadC2fbRawPhysicalSourceLine(reader, lineText) = 0 Then Return 0
    lineText = StripComments(lineText, reader.insideBlockComment)
    Return -1
End Function

Private Sub CloseC2fbPhysicalSourceLineReader( _
    ByRef reader As C2fbPhysicalSourceLineReaderModel _
)
    CloseC2fbTextFileLineReader(reader.textReader)
End Sub

/' end of c2fb_source_lines.bi '/
