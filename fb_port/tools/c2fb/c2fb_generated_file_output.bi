/'
    Project: C2FB output backend

    File: c2fb_generated_file_output.bi

    Purpose:

        Own generated FreeBASIC file lifecycle and ordered file preambles.

    Responsibilities:

        - Open, label, write, and close generated files through a bounded model.
        - Stage output beside its destination and preserve prior files on failure.
        - Retain write and close failures for adapter verification.
        - Remove partial outputs after failed writes or fatal conversion errors.
        - Store and emit file comments and ordered preamble entries.
        - Validate include guards and close paired guard lifecycles.
        - Provide shared text and line sinks for generated output backends.

    This file intentionally does NOT contain:

        - C parsing, translation policy, or binding-specific formatting.
        - CSV row parsing or report-specific field formatting.
'/

Private Type C2fbGeneratedFileCommentModel
    lines(Any) As String
    lineCount As Long
End Type

Private Type C2fbGeneratedFileOutputModel
    outputPath As String
    workingPath As String
    backupPath As String
    fileHandle As Long
    isOpen As Long
    writeFailed As Long
End Type

' Fatal errors abort the active output set before the command exits.
' One converter command keeps only a few generated destinations open at once.
Private Const MAX_ACTIVE_C2FB_GENERATED_FILES As Long = 32
Private Type C2fbActiveGeneratedFileModel
    outputPath As String
    workingPath As String
    backupPath As String
    fileHandle As Long
    isActive As Long
End Type
Private Dim Shared activeC2fbGeneratedFiles( _
    0 To MAX_ACTIVE_C2FB_GENERATED_FILES - 1) As C2fbActiveGeneratedFileModel
Private Dim Shared c2fbGeneratedOutputSequence As Long

Enum C2fbFilePreambleEntryKind
    C2FB_FILE_PREAMBLE_INVALID = 0
    C2FB_FILE_PREAMBLE_INCLUDE_ONCE = 1
    C2FB_FILE_PREAMBLE_LIBRARY = 2
    C2FB_FILE_PREAMBLE_UNDEFINE = 3
    C2FB_FILE_PREAMBLE_COMMENT = 4
    C2FB_FILE_PREAMBLE_BLANK = 5
End Enum
Private Const MAX_C2FB_FILE_PREAMBLE_ENTRIES As Long = 4096

Private Type C2fbGeneratedFilePreambleEntryModel
    kind As C2fbFilePreambleEntryKind
    value As String
End Type

Private Type C2fbGeneratedFilePreambleModel
    entries(Any) As C2fbGeneratedFilePreambleEntryModel
    entryCount As Long
    entryCapacity As Long
End Type

Private Type C2fbGeneratedFileGuardModel
    name As String
    outputPath As String
    fileHandle As Long
    isOpen As Long
End Type

' Keep generated file-comment blocks bounded even when they list user options.
Private Const MAX_C2FB_FILE_COMMENT_LINES As Long = 16384

Private Function C2fbOutputPathSeparatorIsDirectory(ByVal currentByte As Long) As Long
#if defined(__FB_WIN32__)
    Return CInt(currentByte = Asc("/") OrElse currentByte = Asc(Chr(92)))
#else
    Return CInt(currentByte = Asc("/"))
#endif
End Function

Private Function C2fbOutputFileNameOnly(ByVal path As String) As String
    For position As Long = Len(path) To 1 Step -1
        Dim currentByte As Long = Asc(path, position)
        If C2fbOutputPathSeparatorIsDirectory(currentByte) <> 0 Then _
            Return Mid(path, position + 1)
    Next
    Return path
End Function

Private Function C2fbOutputDirectoryPrefix(ByVal path As String) As String
    For position As Long = Len(path) To 1 Step -1
        Dim currentByte As Long = Asc(path, position)
        If C2fbOutputPathSeparatorIsDirectory(currentByte) <> 0 Then _
            Return Left(path, position)
    Next
    Return "./"
End Function

Private Function C2fbGeneratedOutputSidecarBase(ByVal outputPath As String) As String
    Dim firstHash As LongInt = 5381
    Dim secondHash As LongInt = 52711
    For position As Long = 1 To Len(outputPath)
        Dim currentByte As Long = Asc(outputPath, position)
        firstHash = (firstHash * 33 + currentByte) Mod 2147483647
        secondHash = (secondHash * 131 + currentByte) Mod 2147483629
    Next
    Return C2fbOutputDirectoryPrefix(outputPath) & ".c2fb-" & _
        Trim(Str(firstHash)) & "-" & Trim(Str(secondHash))
End Function

Private Function NewC2fbGeneratedWorkingPath( _
    ByVal outputPath As String _
) As String
    Dim sidecarBase As String = C2fbGeneratedOutputSidecarBase(outputPath)
    For attempt As Long = 0 To 63
        c2fbGeneratedOutputSequence += 1
        Dim timerToken As Long = CLng(Timer * 1000)
        Dim workingPath As String = sidecarBase & "-" & _
            Trim(Str(timerToken)) & "-" & _
            Trim(Str(c2fbGeneratedOutputSequence)) & ".tmp"
        If Dir(workingPath) = "" Then Return workingPath
    Next
    Return ""
End Function

Private Sub DeleteC2fbGeneratedFileIfPresent(ByVal outputPath As String)
    If outputPath = "" OrElse Dir(outputPath) = "" Then Exit Sub
    Kill outputPath
End Sub

Private Function RecoverC2fbGeneratedFileBackup( _
    ByVal outputPath As String, ByVal backupPath As String _
) As Long
    If Dir(backupPath) = "" Then Return -1
    If Dir(outputPath) = "" Then
        If Name(backupPath, outputPath) <> 0 Then Return 0
    Else
        DeleteC2fbGeneratedFileIfPresent(backupPath)
        If Dir(backupPath) <> "" Then Return 0
    End If
    Return -1
End Function

Private Function PublishC2fbGeneratedFileOutput( _
    ByRef outputModel As C2fbGeneratedFileOutputModel _
) As Long
    Dim movedOriginal As Long = 0
    If Dir(outputModel.outputPath) <> "" Then
        If Dir(outputModel.backupPath) <> "" Then Return 0
        If Name(outputModel.outputPath, outputModel.backupPath) <> 0 Then Return 0
        movedOriginal = -1
    End If

    If Name(outputModel.workingPath, outputModel.outputPath) <> 0 Then
        If movedOriginal <> 0 AndAlso Dir(outputModel.outputPath) = "" Then
            If Name(outputModel.backupPath, outputModel.outputPath) = 0 Then _
                outputModel.backupPath = ""
        End If
        Return 0
    End If
    outputModel.workingPath = ""
    If movedOriginal <> 0 Then _
        DeleteC2fbGeneratedFileIfPresent(outputModel.backupPath)
    Return -1
End Function

Private Function OpenC2fbGeneratedFileOutput( _
    ByRef outputModel As C2fbGeneratedFileOutputModel, _
    ByVal outputPath As String, _
    ByVal allowWhitespaceOnlyPath As Long = 0 _
) As Long
    outputModel.outputPath = outputPath
    outputModel.workingPath = ""
    outputModel.backupPath = ""
    outputModel.fileHandle = 0
    outputModel.isOpen = 0
    outputModel.writeFailed = 0
    If outputPath = "" OrElse _
       (allowWhitespaceOnlyPath = 0 AndAlso Trim(outputPath) = "") Then Return 0

    Dim registryIndex As Long = -1
    For index As Long = 0 To MAX_ACTIVE_C2FB_GENERATED_FILES - 1
        If activeC2fbGeneratedFiles(index).isActive <> 0 AndAlso _
           activeC2fbGeneratedFiles(index).outputPath = outputPath Then Return 0
        If activeC2fbGeneratedFiles(index).isActive = 0 AndAlso _
           registryIndex < 0 Then
            registryIndex = index
        End If
    Next
    If registryIndex < 0 Then Return 0

    outputModel.backupPath = _
        C2fbGeneratedOutputSidecarBase(outputPath) & ".bak"
    If RecoverC2fbGeneratedFileBackup( _
        outputPath, outputModel.backupPath) = 0 Then Return 0
    outputModel.workingPath = NewC2fbGeneratedWorkingPath(outputPath)
    If outputModel.workingPath = "" Then Return 0

    Dim outputFile As Long = FreeFile
    If Open(outputModel.workingPath For Output As #outputFile) <> 0 Then
        DeleteC2fbGeneratedFileIfPresent(outputModel.workingPath)
        Return 0
    End If
    activeC2fbGeneratedFiles(registryIndex).outputPath = outputPath
    activeC2fbGeneratedFiles(registryIndex).workingPath = outputModel.workingPath
    activeC2fbGeneratedFiles(registryIndex).backupPath = outputModel.backupPath
    activeC2fbGeneratedFiles(registryIndex).fileHandle = outputFile
    activeC2fbGeneratedFiles(registryIndex).isActive = -1
    outputModel.fileHandle = outputFile
    outputModel.isOpen = -1
    Return -1
End Function

Private Sub UnregisterC2fbGeneratedFileOutput(ByVal fileHandle As Long)
    For index As Long = 0 To MAX_ACTIVE_C2FB_GENERATED_FILES - 1
        If activeC2fbGeneratedFiles(index).isActive <> 0 AndAlso _
           activeC2fbGeneratedFiles(index).fileHandle = fileHandle Then
            activeC2fbGeneratedFiles(index).outputPath = ""
            activeC2fbGeneratedFiles(index).workingPath = ""
            activeC2fbGeneratedFiles(index).backupPath = ""
            activeC2fbGeneratedFiles(index).fileHandle = 0
            activeC2fbGeneratedFiles(index).isActive = 0
            Exit Sub
        End If
    Next
End Sub

Private Sub CloseC2fbGeneratedFileOutput( _
    ByRef outputModel As C2fbGeneratedFileOutputModel _
)
    If outputModel.isOpen = 0 Then Exit Sub
    Dim closedFileHandle As Long = outputModel.fileHandle
    Dim closeFailed As Long = 0
    Close #outputModel.fileHandle
    If Err <> 0 Then
        outputModel.writeFailed = -1
        closeFailed = -1
    End If
    outputModel.fileHandle = 0
    outputModel.isOpen = 0
    If closeFailed = 0 AndAlso outputModel.writeFailed = 0 Then
        If PublishC2fbGeneratedFileOutput(outputModel) = 0 Then _
            outputModel.writeFailed = -1
    End If
    If outputModel.writeFailed <> 0 Then
        DeleteC2fbGeneratedFileIfPresent(outputModel.workingPath)
        outputModel.workingPath = ""
        RecoverC2fbGeneratedFileBackup( _
            outputModel.outputPath, outputModel.backupPath)
    End If
    UnregisterC2fbGeneratedFileOutput(closedFileHandle)
End Sub

Private Sub AbortC2fbGeneratedFileOutput( _
    ByRef outputModel As C2fbGeneratedFileOutputModel _
)
    outputModel.writeFailed = -1
    Dim fileHandle As Long = outputModel.fileHandle
    If outputModel.isOpen <> 0 Then
        Close #outputModel.fileHandle
        outputModel.fileHandle = 0
        outputModel.isOpen = 0
    End If
    If fileHandle <> 0 Then UnregisterC2fbGeneratedFileOutput(fileHandle)
    DeleteC2fbGeneratedFileIfPresent(outputModel.workingPath)
    outputModel.workingPath = ""
    RecoverC2fbGeneratedFileBackup( _
        outputModel.outputPath, outputModel.backupPath)
End Sub

Private Sub AbortAllC2fbGeneratedFileOutputs()
    For index As Long = 0 To MAX_ACTIVE_C2FB_GENERATED_FILES - 1
        If activeC2fbGeneratedFiles(index).isActive <> 0 Then
            If activeC2fbGeneratedFiles(index).fileHandle <> 0 Then _
                Close #activeC2fbGeneratedFiles(index).fileHandle
            DeleteC2fbGeneratedFileIfPresent( _
                activeC2fbGeneratedFiles(index).workingPath)
            RecoverC2fbGeneratedFileBackup( _
                activeC2fbGeneratedFiles(index).outputPath, _
                activeC2fbGeneratedFiles(index).backupPath)
            activeC2fbGeneratedFiles(index).outputPath = ""
            activeC2fbGeneratedFiles(index).workingPath = ""
            activeC2fbGeneratedFiles(index).backupPath = ""
            activeC2fbGeneratedFiles(index).fileHandle = 0
            activeC2fbGeneratedFiles(index).isActive = 0
        End If
    Next
End Sub

Private Function C2fbGeneratedFileOutputHasFailed( _
    ByRef outputModel As C2fbGeneratedFileOutputModel _
) As Long
    If outputModel.writeFailed <> 0 Then _
        AbortAllC2fbGeneratedFileOutputs()
    Return outputModel.writeFailed
End Function

Private Function C2fbGeneratedFileOutputFailureMessage( _
    ByRef outputModel As C2fbGeneratedFileOutputModel, _
    ByVal message As String _
) As String
    If outputModel.backupPath <> "" AndAlso _
       Dir(outputModel.backupPath) <> "" AndAlso _
       Dir(outputModel.outputPath) = "" Then
        message &= "; previous output remains recoverable at " & _
                   outputModel.backupPath
    End If
    Return message
End Function

Private Sub WriteC2fbOutputLine( _
    ByRef outputModel As C2fbGeneratedFileOutputModel, ByVal lineText As String _
)
    If outputModel.isOpen = 0 Then
        outputModel.writeFailed = -1
        Exit Sub
    End If
    Print #outputModel.fileHandle, lineText
    If Err <> 0 Then outputModel.writeFailed = -1
End Sub

Private Sub WriteC2fbOutputText( _
    ByRef outputModel As C2fbGeneratedFileOutputModel, ByVal text As String _
)
    If outputModel.isOpen = 0 Then
        outputModel.writeFailed = -1
        Exit Sub
    End If
    Print #outputModel.fileHandle, text;
    If Err <> 0 Then outputModel.writeFailed = -1
End Sub

Private Sub WriteC2fbGeneratedFileLine( _
    ByRef outputModel As C2fbGeneratedFileOutputModel, _
    ByVal lineText As String _
)
    If outputModel.isOpen = 0 Then
        outputModel.writeFailed = -1
        Exit Sub
    End If
    WriteC2fbOutputLine(outputModel, lineText)
End Sub

Private Sub ResetC2fbGeneratedFileComment( _
    ByRef commentModel As C2fbGeneratedFileCommentModel _
)
    ReDim commentModel.lines(0 To 15)
    commentModel.lineCount = 0
End Sub

Private Function AddC2fbGeneratedFileCommentLine( _
    ByRef commentModel As C2fbGeneratedFileCommentModel, _
    ByVal lineText As String _
) As Long
    If commentModel.lineCount >= MAX_C2FB_FILE_COMMENT_LINES Then Return 0
    If commentModel.lineCount > UBound(commentModel.lines) Then _
        ReDim Preserve commentModel.lines( _
            0 To UBound(commentModel.lines) * 2 + 1)
    commentModel.lines(commentModel.lineCount) = lineText
    commentModel.lineCount += 1
    Return -1
End Function

Private Sub WriteC2fbGeneratedFileComment( _
    ByRef outputModel As C2fbGeneratedFileOutputModel, _
    ByRef commentModel As C2fbGeneratedFileCommentModel _
)
    If outputModel.isOpen = 0 Then
        outputModel.writeFailed = -1
        Exit Sub
    End If
    WriteC2fbGeneratedFileLine(outputModel, "/'")
    For lineIndex As Long = 0 To commentModel.lineCount - 1
        WriteC2fbGeneratedFileLine(outputModel, commentModel.lines(lineIndex))
    Next
    WriteC2fbGeneratedFileLine(outputModel, "'/")
End Sub

Private Function C2fbPreambleIdentifierIsValid( _
    ByVal value As String _
) As Long
    If value = "" Then Return 0
    If Asc(value, 1) >= Asc("0") AndAlso Asc(value, 1) <= Asc("9") Then
        For position As Long = 1 To Len(value)
            If Asc(value, position) < Asc("0") OrElse _
               Asc(value, position) > Asc("9") Then Return 0
        Next
        Return -1
    End If
    For position As Long = 1 To Len(value)
        Dim currentByte As Long = Asc(value, position)
        Dim isLetter As Long = CInt( _
            (currentByte >= Asc("A") AndAlso currentByte <= Asc("Z")) OrElse _
            (currentByte >= Asc("a") AndAlso currentByte <= Asc("z")))
        Dim isDigit As Long = CInt(currentByte >= Asc("0") AndAlso currentByte <= Asc("9"))
        If isLetter = 0 AndAlso currentByte <> Asc("_") AndAlso _
           (position = 1 OrElse isDigit = 0) Then Return 0
    Next
    Return -1
End Function

Private Function AppendC2fbGeneratedFilePreambleEntry( _
    ByRef preamble As C2fbGeneratedFilePreambleModel, _
    ByVal kind As C2fbFilePreambleEntryKind, ByVal value As String _
) As Long
    Select Case kind
        Case C2FB_FILE_PREAMBLE_INCLUDE_ONCE, C2FB_FILE_PREAMBLE_LIBRARY
            If value = "" Then Return 0
            For position As Long = 1 To Len(value)
                Dim currentByte As Long = Asc(value, position)
                If currentByte = Asc(Chr(10)) OrElse _
                   currentByte = Asc(Chr(13)) OrElse _
                   currentByte = Asc(Chr(34)) Then Return 0
            Next
        Case C2FB_FILE_PREAMBLE_UNDEFINE
            If C2fbPreambleIdentifierIsValid(value) = 0 Then Return 0
        Case C2FB_FILE_PREAMBLE_COMMENT
            For position As Long = 1 To Len(value)
                If Asc(value, position) = Asc(Chr(10)) OrElse _
                   Asc(value, position) = Asc(Chr(13)) Then Return 0
            Next
        Case C2FB_FILE_PREAMBLE_BLANK
            value = ""
        Case Else
            Return 0
    End Select

    If preamble.entryCount >= MAX_C2FB_FILE_PREAMBLE_ENTRIES Then Return 0
    If preamble.entryCount >= preamble.entryCapacity Then
        If preamble.entryCapacity = 0 Then
            preamble.entryCapacity = 16
            ReDim preamble.entries(0 To preamble.entryCapacity - 1)
        Else
            Dim nextCapacity As Long = preamble.entryCapacity * 2
            If nextCapacity > MAX_C2FB_FILE_PREAMBLE_ENTRIES Then _
                nextCapacity = MAX_C2FB_FILE_PREAMBLE_ENTRIES
            ReDim Preserve preamble.entries(0 To nextCapacity - 1)
            preamble.entryCapacity = nextCapacity
        End If
    End If
    preamble.entries(preamble.entryCount).kind = kind
    preamble.entries(preamble.entryCount).value = value
    preamble.entryCount += 1
    Return -1
End Function

Private Function AddC2fbGeneratedFileIncludeOnce( _
    ByRef preamble As C2fbGeneratedFilePreambleModel, _
    ByVal includePath As String _
) As Long
    Return AppendC2fbGeneratedFilePreambleEntry( _
        preamble, C2FB_FILE_PREAMBLE_INCLUDE_ONCE, includePath)
End Function

Private Function AddC2fbGeneratedFileLibrary( _
    ByRef preamble As C2fbGeneratedFilePreambleModel, _
    ByVal libraryName As String _
) As Long
    Return AppendC2fbGeneratedFilePreambleEntry( _
        preamble, C2FB_FILE_PREAMBLE_LIBRARY, libraryName)
End Function

Private Function AddC2fbGeneratedFileUndefine( _
    ByRef preamble As C2fbGeneratedFilePreambleModel, _
    ByVal macroName As String _
) As Long
    Return AppendC2fbGeneratedFilePreambleEntry( _
        preamble, C2FB_FILE_PREAMBLE_UNDEFINE, macroName)
End Function

Private Function AddC2fbGeneratedFilePreambleComment( _
    ByRef preamble As C2fbGeneratedFilePreambleModel, _
    ByVal commentText As String _
) As Long
    Return AppendC2fbGeneratedFilePreambleEntry( _
        preamble, C2FB_FILE_PREAMBLE_COMMENT, commentText)
End Function

Private Function AddC2fbGeneratedFilePreambleBlank( _
    ByRef preamble As C2fbGeneratedFilePreambleModel _
) As Long
    Return AppendC2fbGeneratedFilePreambleEntry( _
        preamble, C2FB_FILE_PREAMBLE_BLANK, "")
End Function

Private Sub WriteC2fbGeneratedFilePreamble( _
    ByRef outputModel As C2fbGeneratedFileOutputModel, _
    ByRef commentModel As C2fbGeneratedFileCommentModel, _
    ByRef preamble As C2fbGeneratedFilePreambleModel _
)
    If outputModel.isOpen = 0 Then
        outputModel.writeFailed = -1
        Exit Sub
    End If
    If commentModel.lineCount > 0 Then _
        WriteC2fbGeneratedFileComment(outputModel, commentModel)
    For entryIndex As Long = 0 To preamble.entryCount - 1
        Select Case preamble.entries(entryIndex).kind
            Case C2FB_FILE_PREAMBLE_INCLUDE_ONCE
                WriteC2fbGeneratedFileLine( _
                    outputModel, "#include once " & Chr(34) & _
                    preamble.entries(entryIndex).value & Chr(34))
            Case C2FB_FILE_PREAMBLE_LIBRARY
                WriteC2fbGeneratedFileLine( _
                    outputModel, "#inclib " & Chr(34) & _
                    preamble.entries(entryIndex).value & Chr(34))
            Case C2FB_FILE_PREAMBLE_UNDEFINE
                WriteC2fbGeneratedFileLine( _
                    outputModel, "#undef " & preamble.entries(entryIndex).value)
            Case C2FB_FILE_PREAMBLE_COMMENT
                WriteC2fbGeneratedFileLine( _
                    outputModel, "' " & preamble.entries(entryIndex).value)
            Case C2FB_FILE_PREAMBLE_BLANK
                WriteC2fbGeneratedFileLine(outputModel, "")
            Case Else
                Exit Sub
        End Select
    Next
End Sub

Private Function BeginC2fbGeneratedFileGuard( _
    ByRef outputModel As C2fbGeneratedFileOutputModel, _
    ByRef guardModel As C2fbGeneratedFileGuardModel, _
    ByVal guardName As String _
) As Long
    If guardModel.isOpen <> 0 Then Return 0
    guardModel.name = ""
    guardModel.outputPath = ""
    guardModel.fileHandle = 0
    If outputModel.isOpen = 0 OrElse _
       C2fbPreambleIdentifierIsValid(guardName) = 0 Then Return 0
    WriteC2fbGeneratedFileLine(outputModel, "#ifndef " & guardName)
    WriteC2fbGeneratedFileLine(outputModel, "#define " & guardName)
    WriteC2fbGeneratedFileLine(outputModel, "")
    guardModel.name = guardName
    guardModel.outputPath = outputModel.outputPath
    guardModel.fileHandle = outputModel.fileHandle
    guardModel.isOpen = -1
    Return -1
End Function

Private Function EndC2fbGeneratedFileGuard( _
    ByRef outputModel As C2fbGeneratedFileOutputModel, _
    ByRef guardModel As C2fbGeneratedFileGuardModel _
) As Long
    If outputModel.isOpen = 0 OrElse guardModel.isOpen = 0 OrElse _
       guardModel.name = "" OrElse _
       guardModel.outputPath <> outputModel.outputPath OrElse _
       guardModel.fileHandle <> outputModel.fileHandle Then Return 0
    WriteC2fbGeneratedFileLine(outputModel, "#endif")
    WriteC2fbGeneratedFileLine(outputModel, "")
    guardModel.name = ""
    guardModel.outputPath = ""
    guardModel.fileHandle = 0
    guardModel.isOpen = 0
    Return -1
End Function

Private Sub WriteC2fbGeneratedFileEndMarker( _
    ByRef outputModel As C2fbGeneratedFileOutputModel _
)
    If outputModel.isOpen = 0 Then
        outputModel.writeFailed = -1
        Exit Sub
    End If
    WriteC2fbGeneratedFileLine( _
        outputModel, "/' end of " & _
        C2fbOutputFileNameOnly(outputModel.outputPath) & " '/")
End Sub

/' end of c2fb_generated_file_output.bi '/
