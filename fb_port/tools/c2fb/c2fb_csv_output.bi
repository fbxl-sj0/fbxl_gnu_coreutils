/'
    Project: C2FB report output

    File: c2fb_csv_output.bi

    Purpose:

        Parse and write bounded CSV reports for C2FB inventory tools.

    Responsibilities:

        - Parse quoted CSV input and reject malformed or oversized rows.
        - Quote output fields according to CSV delimiters and whitespace.
        - Use the shared file lifecycle to write function inventory records.

    This file intentionally does NOT contain:

        - Generated FreeBASIC file lifecycle or binding formatting.
        - C source collection, declaration scanning, or reconciliation policy.
'/

' Generated inventory rows have eight fields; this also bounds custom CSV rows.
Private Const MAX_C2FB_CSV_FIELDS As Long = 256

Private Type C2fbCsvFieldModel
    value As String
    quote As Long
End Type

Private Type C2fbCsvRowModel
    fields(Any) As C2fbCsvFieldModel
    fieldCount As Long
    fieldCapacity As Long
End Type

Private Type C2fbCsvFileOutputModel
    fileOutput As C2fbGeneratedFileOutputModel
End Type

Private Type C2fbFunctionIndexRecordModel
    upstreamSource As String
    functionName As String
    firstLine As Long
    lastLine As Long
    lineCount As Long
    sizeClass As String
    portStatus As String
    notes As String
End Type

Private Function C2fbCsvQuotedField(ByVal value As String) As String
    Dim result As String = Chr(34)
    For position As Long = 1 To Len(value)
        If Asc(value, position) = Asc(Chr(34)) Then result &= Chr(34)
        result &= Mid(value, position, 1)
    Next
    Return result & Chr(34)
End Function

Private Function C2fbCsvFieldRequiresQuotes(ByVal value As String) As Long
    If value = "" Then Return 0
    Dim firstByte As Long = Asc(value, 1)
    Dim lastByte As Long = Asc(value, Len(value))
    If firstByte = 9 OrElse firstByte = 32 OrElse _
       lastByte = 9 OrElse lastByte = 32 Then Return -1
    For position As Long = 1 To Len(value)
        Dim currentByte As Long = Asc(value, position)
        If currentByte = Asc(",") OrElse currentByte = Asc(Chr(34)) OrElse _
           currentByte = 10 OrElse currentByte = 13 Then Return -1
    Next
    Return 0
End Function

Private Function AppendC2fbCsvField( _
    ByRef row As C2fbCsvRowModel, ByVal value As String, _
    ByVal quote As Long _
) As Long
    If row.fieldCount >= MAX_C2FB_CSV_FIELDS Then Return 0
    For position As Long = 1 To Len(value)
        If Asc(value, position) = 10 OrElse Asc(value, position) = 13 Then Return 0
    Next
    If row.fieldCount >= row.fieldCapacity Then
        If row.fieldCapacity = 0 Then
            row.fieldCapacity = 8
            ReDim row.fields(0 To row.fieldCapacity - 1)
        Else
            If row.fieldCapacity >= MAX_C2FB_CSV_FIELDS Then Return 0
            Dim nextCapacity As Long = row.fieldCapacity * 2
            If nextCapacity > MAX_C2FB_CSV_FIELDS Then _
                nextCapacity = MAX_C2FB_CSV_FIELDS
            ReDim Preserve row.fields(0 To nextCapacity - 1)
            row.fieldCapacity = nextCapacity
        End If
    End If
    row.fields(row.fieldCount).value = value
    row.fields(row.fieldCount).quote = quote
    row.fieldCount += 1
    Return -1
End Function



Private Function ParseC2fbCsvRow( _
    ByVal lineText As String, ByRef row As C2fbCsvRowModel, _
    ByRef errorMessage As String _
) As Long
    Erase row.fields
    row.fieldCount = 0
    row.fieldCapacity = 0
    errorMessage = ""
    If lineText = "" Then Return -1

    Dim position As Long = 1
    While position <= Len(lineText)
        Dim fieldValue As String = ""
        If Asc(lineText, position) = Asc(Chr(34)) Then
            position += 1
            Dim foundClosingQuote As Long = 0
            While position <= Len(lineText)
                If Asc(lineText, position) = Asc(Chr(34)) Then
                    If position < Len(lineText) AndAlso _
                       Asc(lineText, position + 1) = Asc(Chr(34)) Then
                        fieldValue &= Chr(34)
                        position += 2
                    Else
                        position += 1
                        foundClosingQuote = -1
                        Exit While
                    End If
                Else
                    fieldValue &= Mid(lineText, position, 1)
                    position += 1
                End If
            Wend
            If foundClosingQuote = 0 Then
                errorMessage = "unterminated quoted field"
                Return 0
            End If
            If position <= Len(lineText) AndAlso _
               Asc(lineText, position) <> Asc(",") Then
                errorMessage = "characters follow a closing quote"
                Return 0
            End If
        Else
            While position <= Len(lineText) AndAlso _
                  Asc(lineText, position) <> Asc(",")
                If Asc(lineText, position) = Asc(Chr(34)) Then
                    errorMessage = "quote inside an unquoted field"
                    Return 0
                End If
                fieldValue &= Mid(lineText, position, 1)
                position += 1
            Wend
        End If

        If AppendC2fbCsvField(row, fieldValue, 0) = 0 Then
            errorMessage = "row exceeds the configured field or value limit"
            Return 0
        End If
        If position <= Len(lineText) AndAlso _
           Asc(lineText, position) = Asc(",") Then
            position += 1
            If position > Len(lineText) Then
                If AppendC2fbCsvField(row, "", 0) = 0 Then
                    errorMessage = "row exceeds the configured field limit"
                    Return 0
                End If
                Exit While
            End If
        End If
    Wend
    Return -1
End Function

Private Function OpenC2fbCsvFileOutput( _
    ByRef outputModel As C2fbCsvFileOutputModel, ByVal outputPath As String _
) As Long
    ' Preserve CSV path validation: only an empty path is rejected here.
    Return OpenC2fbGeneratedFileOutput( _
        outputModel.fileOutput, outputPath, -1)
End Function

Private Function CloseC2fbCsvFileOutput( _
    ByRef outputModel As C2fbCsvFileOutputModel _
) As Long
    CloseC2fbGeneratedFileOutput(outputModel.fileOutput)
    Return CInt(C2fbGeneratedFileOutputHasFailed(outputModel.fileOutput) = 0)
End Function

Private Function WriteC2fbCsvRow( _
    ByRef outputModel As C2fbCsvFileOutputModel, _
    ByRef row As C2fbCsvRowModel _
) As Long
    If outputModel.fileOutput.isOpen = 0 Then Return 0
    If row.fieldCount < 0 OrElse row.fieldCapacity < row.fieldCount Then Return 0
    If row.fieldCount = 0 Then
        WriteC2fbOutputLine(outputModel.fileOutput, "")
        Return -1
    End If

    For fieldIndex As Long = 0 To row.fieldCount - 1
        If fieldIndex > 0 Then WriteC2fbOutputText(outputModel.fileOutput, ",")
        If row.fields(fieldIndex).quote <> 0 OrElse _
           C2fbCsvFieldRequiresQuotes(row.fields(fieldIndex).value) <> 0 Then
            WriteC2fbOutputText( _
                outputModel.fileOutput, C2fbCsvQuotedField(row.fields(fieldIndex).value))
        Else
            WriteC2fbOutputText(outputModel.fileOutput, row.fields(fieldIndex).value)
        End If
    Next
    WriteC2fbOutputLine(outputModel.fileOutput, "")
    Return -1
End Function

Private Function WriteC2fbFunctionIndexHeader( _
    ByRef outputModel As C2fbCsvFileOutputModel _
) As Long
    Dim row As C2fbCsvRowModel
    If AppendC2fbCsvField(row, "Upstream source", 0) = 0 OrElse _
       AppendC2fbCsvField(row, "Function", 0) = 0 OrElse _
       AppendC2fbCsvField(row, "Start line", 0) = 0 OrElse _
       AppendC2fbCsvField(row, "End line", 0) = 0 OrElse _
       AppendC2fbCsvField(row, "Lines", 0) = 0 OrElse _
       AppendC2fbCsvField(row, "Size class", 0) = 0 OrElse _
       AppendC2fbCsvField(row, "Port status", 0) = 0 OrElse _
       AppendC2fbCsvField(row, "Notes", 0) = 0 Then Return 0
    Return WriteC2fbCsvRow(outputModel, row)
End Function

Private Function WriteC2fbFunctionIndexRecord( _
    ByRef outputModel As C2fbCsvFileOutputModel, _
    ByRef record As C2fbFunctionIndexRecordModel _
) As Long
    Dim row As C2fbCsvRowModel
    If AppendC2fbCsvField(row, record.upstreamSource, -1) = 0 OrElse _
       AppendC2fbCsvField(row, record.functionName, -1) = 0 OrElse _
       AppendC2fbCsvField(row, Trim(Str(record.firstLine)), 0) = 0 OrElse _
       AppendC2fbCsvField(row, Trim(Str(record.lastLine)), 0) = 0 OrElse _
       AppendC2fbCsvField(row, Trim(Str(record.lineCount)), 0) = 0 OrElse _
       AppendC2fbCsvField(row, record.sizeClass, 0) = 0 OrElse _
       AppendC2fbCsvField(row, record.portStatus, 0) = 0 OrElse _
       AppendC2fbCsvField(row, record.notes, 0) = 0 Then Return 0
    Return WriteC2fbCsvRow(outputModel, row)
End Function

/' end of c2fb_csv_output.bi '/
