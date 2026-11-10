/'
    Project: C2FB file input backend
    --------------------------------

    File: c2fb_file_input.bi

    Purpose:

        Own shared text and binary file input for C2FB adapters.

    Responsibilities:

        - Validate and open text or binary input paths.
        - Read physical text lines and track the underlying file position.
        - Read complete binary files through the same lifecycle model.
        - Close an open reader through one lifecycle operation.

    This file intentionally does NOT contain:

        - Comment stripping, directive continuation, or language parsing.
        - Translation policy or generated-file output.
'/

Private Type C2fbTextFileLineReaderModel
    fileNumber As Long
    physicalLineNumber As Long
    isOpen As Long
End Type

Private Function OpenC2fbTextFileLineReader( _
    ByRef reader As C2fbTextFileLineReaderModel, _
    ByVal inputPath As String _
) As Long
    If reader.isOpen <> 0 Then Close #reader.fileNumber
    reader.fileNumber = 0
    reader.physicalLineNumber = 0
    reader.isOpen = 0
    If Len(inputPath) = 0 Then Return 0

    Dim fileNumber As Long = FreeFile
    If Open(inputPath For Input As #fileNumber) <> 0 Then Return 0
    reader.fileNumber = fileNumber
    reader.isOpen = -1
    Return -1
End Function

Private Function ReadC2fbTextFileLine( _
    ByRef reader As C2fbTextFileLineReaderModel, _
    ByRef lineText As String _
) As Long
    lineText = ""
    If reader.isOpen = 0 OrElse EOF(reader.fileNumber) Then Return 0
    Line Input #reader.fileNumber, lineText
    reader.physicalLineNumber += 1
    Return -1
End Function

Private Sub CloseC2fbTextFileLineReader( _
    ByRef reader As C2fbTextFileLineReaderModel _
)
    If reader.isOpen <> 0 Then Close #reader.fileNumber
    reader.fileNumber = 0
    reader.isOpen = 0
End Sub

Private Type C2fbBinaryFileReaderModel
    fileNumber As Long
    byteLength As LongInt
    isOpen As Long
End Type

Private Function OpenC2fbBinaryFileReader( _
    ByRef reader As C2fbBinaryFileReaderModel, _
    ByVal inputPath As String _
) As Long
    If reader.isOpen <> 0 Then Close #reader.fileNumber
    reader.fileNumber = 0
    reader.byteLength = 0
    reader.isOpen = 0
    If Len(inputPath) = 0 Then Return 0

    Dim fileNumber As Long = FreeFile
    If Open(inputPath For Binary Access Read As #fileNumber) <> 0 Then Return 0
    reader.fileNumber = fileNumber
    reader.byteLength = LOF(fileNumber)
    reader.isOpen = -1
    Return -1
End Function

Private Sub CloseC2fbBinaryFileReader( _
    ByRef reader As C2fbBinaryFileReaderModel _
)
    If reader.isOpen <> 0 Then Close #reader.fileNumber
    reader.fileNumber = 0
    reader.isOpen = 0
End Sub

Private Function ReadC2fbWholeBinaryFile( _
    ByVal inputPath As String, ByRef contents As String _
) As Long
    contents = ""
    Dim reader As C2fbBinaryFileReaderModel
    If OpenC2fbBinaryFileReader(reader, inputPath) = 0 Then Return 0
    If reader.byteLength > 0 Then
        Dim byteCount As Long = reader.byteLength
        contents = Space(byteCount)
        Get #reader.fileNumber, 1, contents
    End If
    CloseC2fbBinaryFileReader(reader)
    Return -1
End Function

Private Function FileLengthIfPresent(ByVal path As String) As LongInt
    Dim reader As C2fbBinaryFileReaderModel
    If OpenC2fbBinaryFileReader(reader, path) = 0 Then Return -1
    Dim byteLength As LongInt = reader.byteLength
    CloseC2fbBinaryFileReader(reader)
    Return byteLength
End Function

/' end of c2fb_file_input.bi '/
