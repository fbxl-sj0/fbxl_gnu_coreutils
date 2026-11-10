/'
    Project: C2FB body source adapter

    File: c2fb_simple_body_adapter.bi

    Purpose:

        Adapt simple C tree requests to the shared body translation pipeline.

    Responsibilities:

        - Select C source files with the bounded source-file model.
        - Derive output names and invoke the shared per-file translator.

    This file intentionally does NOT contain:

        - Per-file declaration indexing, body lowering, or candidate filtering.
        - Generic C preprocessing or SQLite preprocessed-tree configuration.
'/

Private Sub TranslateCBodyTree( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByVal sourceDirectory As String, _
    ByVal outputDirectory As String, _
    ByRef bodyOptions As C2fbBodyTranslationOptions _
)
    If Len(sourceDirectory) = 0 OrElse Len(outputDirectory) = 0 Then
        ReportError("translate-simple-tree requires source and output directories")
    End If

    Dim sourceFiles As C2fbSourceFileSetModel
    If AppendC2fbSourceDirectoryFiles( _
        sourceFiles, sourceDirectory, ".c", _
        CInt(bodyOptions.targetProfile = C2FB_TARGET_SQLITE), -1) = 0 Then _
        ReportError("source tree exceeds the configured file limit")

    For fileIndex As Long = 0 To sourceFiles.itemCount - 1
        Dim fileName As String = sourceFiles.names(fileIndex)
        Dim outputName As String = Left(fileName, Len(fileName) - 2) & "_candidates.bas"
        Dim fileOptions As C2fbBodyTranslationOptions = bodyOptions
        Dim fileRequest As C2fbBodyFileTranslationRequestModel
        fileRequest.inputPath = sourceDirectory & "/" & fileName
        fileRequest.outputPath = outputDirectory & "/" & outputName
        fileRequest.translationOptions = fileOptions
        TranslateCBodyFile( _
            translation, catalog, fileRequest)
    Next
    Print "processed " & Trim(Str(sourceFiles.itemCount)) & _
          " C source files into " & outputDirectory
End Sub

Private Sub TranslateCBodyRequest( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef request As C2fbBodyTranslationRequestModel _
)
    If request.inputShape = C2FB_BODY_INPUT_TREE Then
        TranslateCBodyTree( _
            translation, catalog, request.sourcePath, request.outputPath, _
            request.translationOptions)
    Else
        Dim fileRequest As C2fbBodyFileTranslationRequestModel
        fileRequest.inputPath = request.sourcePath
        fileRequest.outputPath = request.outputPath
        fileRequest.translationOptions = request.translationOptions
        TranslateCBodyFile(translation, catalog, fileRequest)
    End If
End Sub
/' end of c2fb_simple_body_adapter.bi '/
