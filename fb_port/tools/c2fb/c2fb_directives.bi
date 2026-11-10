/'
    Project: C2FB shared C input

    File: c2fb_directives.bi

    Purpose:

        Read logical C source lines with source line accounting.

    Responsibilities:

        - Own logical-reader state over the shared physical-file reader.
        - Detect backslash-newline continuations consistently.
        - Strip comments while preserving directive text.
        - Join backslash-newline continuations before removing comments.
        - Retain the first physical line and report incomplete final lines.

    This file intentionally does NOT contain:

        - Macro parsing, preprocessing policy, or C expression lowering.
        - Translation target mapping or output formatting.
'/

Private Function HasC2fbLineContinuation(ByVal lineText As String) As Long
    Dim position As Long = Len(lineText)
    While position > 0 AndAlso IsSpaceByte(Asc(lineText, position)) <> 0
        position -= 1
    Wend
    If position > 0 AndAlso Asc(lineText, position) = Asc("\") Then Return -1
    Return 0
End Function

Private Type C2fbLogicalSourceLineReaderModel
    physicalReader As C2fbPhysicalSourceLineReaderModel
    ' This follows #line markers and can differ from physical input position.
    sourceLineNumber As Long
    insideComment As Long
End Type

Private Function OpenC2fbLogicalSourceLineReader( _
    ByRef reader As C2fbLogicalSourceLineReaderModel, _
    ByVal inputPath As String _
) As Long
    reader.sourceLineNumber = 0
    reader.insideComment = 0
    If OpenC2fbPhysicalSourceLineReader( _
        reader.physicalReader, inputPath) = 0 Then Return 0
    Return -1
End Function

Private Function C2fbLogicalSourceLineNumber( _
    ByRef reader As C2fbLogicalSourceLineReaderModel _
) As Long
    Return reader.sourceLineNumber
End Function

Private Sub SetC2fbLogicalSourceLineNumber( _
    ByRef reader As C2fbLogicalSourceLineReaderModel, _
    ByVal sourceLineNumber As Long _
)
    If sourceLineNumber < 0 Then
        reader.sourceLineNumber = 0
    Else
        reader.sourceLineNumber = sourceLineNumber
    End If
End Sub

Private Sub CloseC2fbLogicalSourceLineReader( _
    ByRef reader As C2fbLogicalSourceLineReaderModel _
)
    CloseC2fbPhysicalSourceLineReader(reader.physicalReader)
    reader.sourceLineNumber = 0
    reader.insideComment = 0
End Sub

Private Function ReadC2fbLogicalLine( _
    ByRef reader As C2fbLogicalSourceLineReaderModel, _
    ByRef lineText As String, _
    ByRef firstLine As Long, ByRef wasContinued As Long, _
    ByRef isComplete As Long _
) As Long
    lineText = ""
    firstLine = 0
    wasContinued = 0
    isComplete = -1
    Dim physicalLine As String
    If ReadC2fbRawPhysicalSourceLine( _
        reader.physicalReader, physicalLine) = 0 Then Return 0

    reader.sourceLineNumber += 1
    firstLine = reader.sourceLineNumber
    Dim logicalLine As String = physicalLine
    While HasC2fbLineContinuation(logicalLine) <> 0
        Dim slashPosition As Long = Len(logicalLine)
        While slashPosition > 0 AndAlso _
              IsSpaceByte(Asc(logicalLine, slashPosition)) <> 0
            slashPosition -= 1
        Wend
        If slashPosition = 0 OrElse _
           Asc(logicalLine, slashPosition) <> Asc("\") Then Exit While
        logicalLine = Left(logicalLine, slashPosition - 1)
        wasContinued = -1
        Dim continuationText As String
        If ReadC2fbRawPhysicalSourceLine( _
            reader.physicalReader, continuationText) = 0 Then
            lineText = StripComments(logicalLine, reader.insideComment)
            isComplete = 0
            Return -1
        End If
        reader.sourceLineNumber += 1
        logicalLine &= continuationText
    Wend
    lineText = StripComments(logicalLine, reader.insideComment)
    Return -1
End Function

/' end of c2fb_directives.bi '/
