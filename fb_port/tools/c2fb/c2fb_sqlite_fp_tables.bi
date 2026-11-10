/'
    Project: C2FB SQLite adapters

    File: c2fb_sqlite_fp_tables.bi

    Purpose:

        Extract and emit SQLite's generated base-10 conversion tables.

    Responsibilities:

        - Read the bounded hexadecimal tables from SQLite source.
        - Validate table dimensions and split 64-bit values into words.
        - Submit initialized array bindings to the shared output dispatcher.

    This file intentionally does NOT contain:

        - General C array parsing or arbitrary constant evaluation.
        - Generic header conversion or body translation.
'/

Private Type CUInt64Table
    cName As String
    highName As String
    lowName As String
    itemCount As Long
    highWord(0 To 31) As ULongInt
    lowWord(0 To 31) As ULongInt
End Type

Private Function ParseHexWord32(ByVal digits As String) As ULongInt
    If Len(digits) > 8 Then ReportError("floating-point table word exceeds 32 bits")
    Dim value As ULongInt = 0
    For i As Long = 1 To Len(digits)
        Dim c As Long = Asc(digits, i)
        Dim digit As Long
        If c >= Asc("0") AndAlso c <= Asc("9") Then
            digit = c - Asc("0")
        ElseIf c >= Asc("A") AndAlso c <= Asc("F") Then
            digit = c - Asc("A") + 10
        ElseIf c >= Asc("a") AndAlso c <= Asc("f") Then
            digit = c - Asc("a") + 10
        Else
            ReportError("invalid digit in floating-point table")
        End If
        value = value * 16 + CULngInt(digit)
    Next
    Return value
End Function

Private Sub EmitFpWordArray( _
    ByRef outputFile As C2fbGeneratedFileOutputModel, _
    ByVal arrayName As String, _
    table As CUInt64Table, _
    ByVal highWord As Long _
)
    Dim arrayBinding As C2fbIntegerConstantArrayBindingModel
    arrayBinding.name = arrayName
    arrayBinding.elementType = "ULong"
    arrayBinding.lowerBound = 0
    For valueIndex As Long = 0 To table.itemCount - 1
        Dim value As ULongInt
        If highWord <> 0 Then
            value = table.highWord(valueIndex)
        Else
            value = table.lowWord(valueIndex)
        End If
        If AppendC2fbIntegerConstantArrayValue(arrayBinding, value) = 0 Then _
            ReportError("floating-point table array exceeds the configured output limit")
    Next
    If WriteC2fbIntegerConstantArrayBinding(outputFile, arrayBinding) = 0 Then _
        ReportError("invalid floating-point table array output model")
End Sub

Private Sub ConvertFpTables(ByRef request As C2fbFileConversionRequestModel)
    Dim inputPath As String = request.inputPath
    Dim outputPath As String = request.outputPath
    Dim tables(0 To 2) As CUInt64Table
    tables(0).cName = "aBase"
    tables(0).highName = "sqlite3Fp10BaseHigh"
    tables(0).lowName = "sqlite3Fp10BaseLow"
    tables(1).cName = "aScale"
    tables(1).highName = "sqlite3Fp10ScaleHigh"
    tables(1).lowName = "sqlite3Fp10ScaleLow"
    tables(2).cName = "aScaleLo"
    tables(2).lowName = "sqlite3Fp10ScaleTail"

    Dim sourceReader As C2fbPhysicalSourceLineReaderModel
    If OpenC2fbPhysicalSourceLineReader(sourceReader, inputPath) = 0 Then _
        ReportError("cannot read floating-point table source: " & inputPath)
    Dim activeTable As Long = -1
    Dim lineText As String
    While ReadC2fbPhysicalSourceLine(sourceReader, lineText) <> 0
        Dim scanStart As Long = 1
        If activeTable < 0 Then
            For i As Long = 0 To 2
                If InStr(lineText, tables(i).cName & "[]") <> 0 Then
                    activeTable = i
                    Exit For
                End If
            Next
            If activeTable < 0 Then Continue While
            scanStart = InStr(lineText, "{") + 1
            If scanStart <= 1 Then ReportError("missing array initializer for " & tables(activeTable).cName)
        End If

        Dim i As Long = scanStart
        While i <= Len(lineText)
            If Asc(lineText, i) = Asc("0") AndAlso i < Len(lineText) AndAlso _
               (Asc(lineText, i + 1) = Asc("x") OrElse Asc(lineText, i + 1) = Asc("X")) Then
                Dim digitStart As Long = i + 2
                Dim digitEnd As Long = digitStart
                While digitEnd <= Len(lineText) AndAlso IsHexDigit(Asc(lineText, digitEnd)) <> 0
                    digitEnd += 1
                Wend
                If digitEnd = digitStart Then ReportError("empty hexadecimal table value")
                Dim digits As String = Mid(lineText, digitStart, digitEnd - digitStart)
                Dim table As CUInt64Table Ptr = @tables(activeTable)
                If table->itemCount >= 32 Then ReportError("too many values in " & table->cName)
                If activeTable = 2 Then
                    table->highWord(table->itemCount) = 0
                    table->lowWord(table->itemCount) = ParseHexWord32(digits)
                Else
                    If Len(digits) > 16 Then ReportError("64-bit table value exceeds 64 bits")
                    Dim highDigits As Long = Len(digits) - 8
                    If highDigits > 0 Then
                        table->highWord(table->itemCount) = ParseHexWord32(Left(digits, highDigits))
                    Else
                        table->highWord(table->itemCount) = 0
                    End If
                    Dim lowStart As Long = 1
                    If highDigits > 0 Then lowStart = highDigits + 1
                    table->lowWord(table->itemCount) = ParseHexWord32(Mid(digits, lowStart))
                End If
                table->itemCount += 1
                i = digitEnd
            Else
                i += 1
            End If
        Wend
        If InStr(lineText, "};") <> 0 Then activeTable = -1
    Wend
    CloseC2fbPhysicalSourceLineReader(sourceReader)

    If activeTable >= 0 Then ReportError("unterminated floating-point table " & tables(activeTable).cName)
    If tables(0).itemCount <> 27 OrElse tables(1).itemCount <> 26 OrElse _
       tables(2).itemCount <> 26 Then
        ReportError("unexpected power-of-ten table sizes")
    End If

    Dim fileOutput As C2fbGeneratedFileOutputModel
    If OpenC2fbGeneratedFileOutput(fileOutput, outputPath) = 0 Then _
        ReportError("cannot write floating-point table file: " & outputPath)
    Dim fileComment As C2fbGeneratedFileCommentModel
    ResetC2fbGeneratedFileComment(fileComment)
    If AddC2fbGeneratedFileCommentLine( _
        fileComment, "    Project: SQLite FreeBASIC port") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine(fileComment, "") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
        fileComment, "    File: " & FileNameOnly(outputPath)) = 0 OrElse _
       AddC2fbGeneratedFileCommentLine(fileComment, "") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
        fileComment, "    Purpose: Hold SQLite's generated base-10 conversion tables.") = 0 OrElse _
       AddC2fbGeneratedFileCommentLine( _
        fileComment, "    Source: " & inputPath) = 0 OrElse _
        AddC2fbGeneratedFileCommentLine( _
        fileComment, "    Generated by fb_tools/c2fb/c2fb.bas. Do not edit by hand.") = 0 Then _
        ReportError("floating-point table file comment exceeds its limit")
    Dim filePreamble As C2fbGeneratedFilePreambleModel
    If AddC2fbGeneratedFilePreambleBlank(filePreamble) = 0 Then _
        ReportError("floating-point table preamble exceeds its configured limit")
    WriteC2fbGeneratedFilePreamble(fileOutput, fileComment, filePreamble)
    EmitFpWordArray(fileOutput, tables(0).highName, tables(0), -1)
    WriteC2fbGeneratedFileLine(fileOutput, "")
    EmitFpWordArray(fileOutput, tables(0).lowName, tables(0), 0)
    WriteC2fbGeneratedFileLine(fileOutput, "")
    EmitFpWordArray(fileOutput, tables(1).highName, tables(1), -1)
    WriteC2fbGeneratedFileLine(fileOutput, "")
    EmitFpWordArray(fileOutput, tables(1).lowName, tables(1), 0)
    WriteC2fbGeneratedFileLine(fileOutput, "")
    EmitFpWordArray(fileOutput, tables(2).lowName, tables(2), 0)
    WriteC2fbGeneratedFileLine(fileOutput, "")
    WriteC2fbGeneratedFileEndMarker(fileOutput)
    CloseC2fbGeneratedFileOutput(fileOutput)
    If C2fbGeneratedFileOutputHasFailed(fileOutput) <> 0 Then _
        ReportError(C2fbGeneratedFileOutputFailureMessage( _
            fileOutput, "cannot finish floating-point table file: " & outputPath))
    Print "converted SQLite power-of-ten tables; output " & outputPath
End Sub
/' end of c2fb_sqlite_fp_tables.bi '/
