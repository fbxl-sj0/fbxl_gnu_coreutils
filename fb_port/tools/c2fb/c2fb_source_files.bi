/'
    Project: C2FB input adapters

    File: c2fb_source_files.bi

    Purpose:

        Collect bounded, deterministically ordered source-file sets for C2FB passes.

    Responsibilities:

        - Append file names with optional duplicate suppression.
        - Enumerate supported C and FreeBASIC source extensions.
        - Sort each enumerated file group by its relative path.
        - Optionally index nested FreeBASIC interfaces by their relative paths.
        - Apply engine-source exclusions selected by the calling adapter.

    This file intentionally does NOT contain:

        - Command-line interpretation or compiler argument parsing.
        - C preprocessing, source parsing, or output formatting.
'/

Private Const MAX_C2FB_SOURCE_DIRECTORY_DEPTH As Long = 32
' FreeBASIC's Dir() attribute flag for directories, also named fbDirectory.
Private Const C2FB_DIRECTORY_ATTRIBUTE As Long = &H10

Private Function AppendC2fbSourceFileName( _
    ByRef sourceFiles As C2fbSourceFileSetModel, _
    ByVal fileName As String, ByVal suppressDuplicates As Long = 0 _
) As Long
    If fileName = "" Then Return 0
    If suppressDuplicates <> 0 Then
        For fileIndex As Long = 0 To sourceFiles.itemCount - 1
            If sourceFiles.names(fileIndex) = fileName Then Return 1
        Next
    End If
    If sourceFiles.itemCount >= MAX_FUNCTIONS Then Return 0
    If sourceFiles.itemCount >= sourceFiles.capacity Then
        If sourceFiles.capacity = 0 Then
            sourceFiles.capacity = 32
            ReDim sourceFiles.names(0 To sourceFiles.capacity - 1)
        Else
            Dim nextCapacity As Long = sourceFiles.capacity * 2
            If nextCapacity > MAX_FUNCTIONS Then nextCapacity = MAX_FUNCTIONS
            ReDim Preserve sourceFiles.names(0 To nextCapacity - 1)
            sourceFiles.capacity = nextCapacity
        End If
    End If
    sourceFiles.names(sourceFiles.itemCount) = fileName
    sourceFiles.itemCount += 1
    Return -1
End Function

Private Sub SortC2fbSourceFileRange( _
    ByRef sourceFiles As C2fbSourceFileSetModel, _
    ByVal firstIndex As Long _
)
    If firstIndex < 0 OrElse sourceFiles.itemCount - firstIndex < 2 Then Exit Sub

    Dim gap As Long = (sourceFiles.itemCount - firstIndex) \ 2
    While gap > 0
        For sourceIndex As Long = firstIndex + gap To sourceFiles.itemCount - 1
            Dim sourceName As String = sourceFiles.names(sourceIndex)
            Dim insertIndex As Long = sourceIndex
            While insertIndex >= firstIndex + gap AndAlso _
                  sourceFiles.names(insertIndex - gap) > sourceName
                sourceFiles.names(insertIndex) = _
                    sourceFiles.names(insertIndex - gap)
                insertIndex -= gap
            Wend
            sourceFiles.names(insertIndex) = sourceName
        Next
        gap \= 2
    Wend
End Sub

Private Function IsC2fbGeneratedSourceDirectory( _
    ByVal directoryName As String _
) As Long
    Select Case LCase(directoryName)
    Case ".git", ".hg", ".svn", "build", "builds", "out", "obj", _
         "node_modules", "__pycache__"
        Return -1
    End Select
    If Left(directoryName, 1) = "." Then Return -1
    Return 0
End Function

Private Function AppendC2fbRecursiveSourceFiles( _
    ByRef sourceFiles As C2fbSourceFileSetModel, _
    ByVal sourceDirectory As String, ByVal relativeDirectory As String, _
    ByVal extension As String, ByVal excludeEngineSupport As Long, _
    ByVal depth As Long _
) As Long
    If depth > MAX_C2FB_SOURCE_DIRECTORY_DEPTH Then Return 0

    Dim currentDirectory As String = sourceDirectory
    If relativeDirectory <> "" Then _
        currentDirectory &= "/" & relativeDirectory

    Dim firstFileIndex As Long = sourceFiles.itemCount
    Dim fileName As String = Dir(currentDirectory & "/*" & extension)
    While fileName <> ""
        Dim lowerName As String = LCase(fileName)
        If excludeEngineSupport = 0 OrElse _
           (Left(lowerName, 4) <> "test" AndAlso _
            lowerName <> "tclsqlite" & extension) Then
            Dim relativeFileName As String = fileName
            If relativeDirectory <> "" Then _
                relativeFileName = relativeDirectory & "/" & fileName
            If AppendC2fbSourceFileName( _
                sourceFiles, relativeFileName, -1) = 0 Then Return 0
        End If
        fileName = Dir()
    Wend
    SortC2fbSourceFileRange(sourceFiles, firstFileIndex)

    Dim childDirectories As C2fbSourceFileSetModel
    Dim directoryName As String = Dir( _
        currentDirectory & "/*", C2FB_DIRECTORY_ATTRIBUTE)
    While directoryName <> ""
        If directoryName <> "." AndAlso directoryName <> ".." AndAlso _
           IsC2fbGeneratedSourceDirectory(directoryName) = 0 Then
            Dim childPath As String = directoryName
            If relativeDirectory <> "" Then _
                childPath = relativeDirectory & "/" & directoryName
            If AppendC2fbSourceFileName( _
                childDirectories, childPath, -1) = 0 Then Return 0
        End If
        directoryName = Dir()
    Wend

    SortC2fbSourceFileRange(childDirectories, 0)
    For childIndex As Long = 0 To childDirectories.itemCount - 1
        If AppendC2fbRecursiveSourceFiles( _
            sourceFiles, sourceDirectory, childDirectories.names(childIndex), _
            extension, excludeEngineSupport, depth + 1) = 0 Then Return 0
    Next
    Return -1
End Function

Private Function AppendC2fbSourceDirectoryFiles( _
    ByRef sourceFiles As C2fbSourceFileSetModel, _
    ByVal sourceDirectory As String, ByVal extension As String, _
    ByVal excludeEngineSupport As Long, ByVal resetList As Long, _
    ByVal includeSubdirectories As Long = 0 _
) As Long
    extension = LCase(extension)
    Select Case LCase(extension)
    Case ".c", ".h", ".bi", ".bas"
    Case Else
        Return 0
    End Select
    If sourceDirectory = "" Then Return 0
    If excludeEngineSupport <> 0 AndAlso _
       extension <> ".c" AndAlso extension <> ".h" Then Return 0
    If resetList <> 0 Then
        sourceFiles.itemCount = 0
        sourceFiles.capacity = 0
    End If

    If includeSubdirectories <> 0 Then _
        Return AppendC2fbRecursiveSourceFiles( _
            sourceFiles, sourceDirectory, "", extension, _
            excludeEngineSupport, 0)

    Dim firstFileIndex As Long = sourceFiles.itemCount
    Dim fileName As String = Dir(sourceDirectory & "/*" & extension)
    While fileName <> ""
        Dim lowerName As String = LCase(fileName)
        If excludeEngineSupport <> 0 AndAlso _
           (Left(lowerName, 4) = "test" OrElse _
            lowerName = "tclsqlite" & extension) Then
            fileName = Dir()
            Continue While
        End If
        If AppendC2fbSourceFileName(sourceFiles, fileName) = 0 Then Return 0
        fileName = Dir()
    Wend
    SortC2fbSourceFileRange(sourceFiles, firstFileIndex)
    Return -1
End Function

/' end of c2fb_source_files.bi '/
