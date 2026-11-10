/'
    Project: C2FB SQLite adapters

    File: c2fb_sqlite_preprocessed_adapter.bi

    Purpose:

        Prepare SQLite C inputs and lower them through the shared body pipeline.

    Responsibilities:

        - Generate the SQLite support headers required by C preprocessing.
        - Select engine source files and validate/encode SQLite feature defines.
        - Preserve or suppress assertions according to the selected conversion policy.
        - Preprocess each input and route it through shared body conversion.
        - Record preprocessing failures and preserve per-file output policy.

    This file intentionally does NOT contain:

        - C declaration or function-body lowering.
        - Generic C option handling or body candidate formatting.
'/

Private Function FeatureDefineArguments(ByVal definitions As String) As String
    Dim arguments As String = ""
    Dim startPosition As Long = 1
    While startPosition <= Len(definitions)
        Dim separatorPosition As Long = InStr(startPosition, definitions, ",")
        If separatorPosition = 0 Then separatorPosition = Len(definitions) + 1
        If separatorPosition = Len(definitions) Then _
            ReportError("feature define list must not end with a comma")
        Dim definition As String = Trim(Mid(definitions, startPosition, _
                                             separatorPosition - startPosition))
        If definition = "" Then ReportError("feature defines must be comma-separated names or NAME=VALUE pairs")

        Dim equalsPosition As Long = InStr(definition, "=")
        Dim macroName As String = definition
        Dim value As String = ""
        If equalsPosition <> 0 Then
            macroName = Left(definition, equalsPosition - 1)
            value = Mid(definition, equalsPosition + 1)
            If value = "" Then ReportError("feature define has an empty value: " & definition)
        End If
        If macroName = "" OrElse IsIdentifierStart(Asc(macroName, 1)) = 0 Then _
            ReportError("invalid feature define name: " & definition)
        For i As Long = 2 To Len(macroName)
            If IsIdentifierPart(Asc(macroName, i)) = 0 Then _
                ReportError("invalid feature define name: " & definition)
        Next
        For i As Long = 1 To Len(value)
            Dim c As Long = Asc(value, i)
            If (c < Asc("0") OrElse c > Asc("9")) AndAlso _
               (c < Asc("A") OrElse c > Asc("Z")) AndAlso _
               (c < Asc("a") OrElse c > Asc("z")) AndAlso c <> Asc("_") Then _
                ReportError("feature define values may contain only letters, digits, and underscores: " & definition)
        Next

        arguments &= " -D" & ShellQuote(definition)
        startPosition = separatorPosition + 1
    Wend
    Return arguments
End Function

Private Function FeatureDefineEnabled( _
    ByVal definitions As String, _
    ByVal requestedName As String _
) As Long
    Dim startPosition As Long = 1
    While startPosition <= Len(definitions)
        Dim separatorPosition As Long = InStr(startPosition, definitions, ",")
        If separatorPosition = 0 Then separatorPosition = Len(definitions) + 1
        Dim definition As String = Trim(Mid(definitions, startPosition, _
                                             separatorPosition - startPosition))
        Dim equalsPosition As Long = InStr(definition, "=")
        Dim macroName As String = definition
        Dim value As String = ""
        If equalsPosition <> 0 Then
            macroName = Left(definition, equalsPosition - 1)
            value = Mid(definition, equalsPosition + 1)
        End If
        If macroName = requestedName Then
            If value = "0" Then Return 0
            Return -1
        End If
        startPosition = separatorPosition + 1
    Wend
    Return 0
End Function

Private Function WriteC2fbPreprocessorHeaders( _
    ByRef environment As C2fbPreprocessorEnvironmentModel, _
    ByRef errorMessage As String _
) As Long
    errorMessage = ""
    Dim headerTemplatePath As String = _
        environment.sourceDirectory & "/sqlite.h.in"
    If FileLengthIfPresent(headerTemplatePath) <= 0 Then
        errorMessage = _
            "cannot read SQLite public header template: " & headerTemplatePath
        Return 0
    End If

    Dim lineReader As C2fbTextFileLineReaderModel
    If OpenC2fbTextFileLineReader(lineReader, headerTemplatePath) = 0 Then
        errorMessage = "cannot read SQLite public header template: " & _
                       headerTemplatePath
        Return 0
    End If
    Dim generatedOutput As C2fbGeneratedFileOutputModel
    If OpenC2fbGeneratedFileOutput( _
        generatedOutput, environment.includeDirectory & "/sqlite3.h") = 0 Then
        CloseC2fbTextFileLineReader(lineReader)
        errorMessage = "cannot write SQLite preprocessing header: sqlite3.h"
        Return 0
    End If
    Dim lineText As String
    While ReadC2fbTextFileLine(lineReader, lineText) <> 0
        WriteC2fbGeneratedFileLine(generatedOutput, lineText)
    Wend
    ' The public header template deliberately leaves this guard to its generator.
    WriteC2fbGeneratedFileLine(generatedOutput, "#endif /* SQLITE3_H */")
    CloseC2fbTextFileLineReader(lineReader)
    CloseC2fbGeneratedFileOutput(generatedOutput)
    If C2fbGeneratedFileOutputHasFailed(generatedOutput) <> 0 Then
        errorMessage = C2fbGeneratedFileOutputFailureMessage( _
            generatedOutput, "cannot finish SQLite preprocessing header: sqlite3.h")
        Return 0
    End If

    If OpenC2fbGeneratedFileOutput( _
        generatedOutput, environment.includeDirectory & "/sqlite_cfg.h") = 0 Then
        errorMessage = "cannot write SQLite preprocessing header: sqlite_cfg.h"
        Return 0
    End If
    WriteC2fbGeneratedFileLine(generatedOutput, _
        "/* c2fb uses SQLite's default source feature configuration. */")
    CloseC2fbGeneratedFileOutput(generatedOutput)
    If C2fbGeneratedFileOutputHasFailed(generatedOutput) <> 0 Then
        errorMessage = C2fbGeneratedFileOutputFailureMessage( _
            generatedOutput, "cannot finish SQLite preprocessing header: sqlite_cfg.h")
        Return 0
    End If

    Dim assertHeaderPath As String = _
        environment.includeDirectory & "/assert.h"
    If environment.assertionsRestored <> 0 Then
        If OpenC2fbGeneratedFileOutput(generatedOutput, assertHeaderPath) = 0 Then
            errorMessage = "cannot write SQLite preprocessing header: assert.h"
            Return 0
        End If
        WriteC2fbGeneratedFileLine(generatedOutput, _
            "/* C2FB candidate mode: preserve assertion conditions for FreeBASIC. */")
        WriteC2fbGeneratedFileLine(generatedOutput, "#ifndef SQLITE_C2FB_ASSERT_H")
        WriteC2fbGeneratedFileLine(generatedOutput, "#define SQLITE_C2FB_ASSERT_H")
        WriteC2fbGeneratedFileLine(generatedOutput, _
            "void sqlite3DebugAssertCheck(int condition, const char *expression);")
        Dim assertionMacro As C2fbMacroBindingModel
        assertionMacro.name = "assert"
        assertionMacro.parameters = "expression"
        assertionMacro.bodyText = _
            "sqlite3DebugAssertCheck(!!(expression), #expression)"
        assertionMacro.isFunctionLike = -1
        WriteC2fbMacroBinding(generatedOutput, assertionMacro)
        WriteC2fbGeneratedFileLine(generatedOutput, "#endif")
        CloseC2fbGeneratedFileOutput(generatedOutput)
        If C2fbGeneratedFileOutputHasFailed(generatedOutput) <> 0 Then
            errorMessage = C2fbGeneratedFileOutputFailureMessage( _
                generatedOutput, "cannot finish SQLite preprocessing header: assert.h")
            Return 0
        End If
    ElseIf environment.assertionsStripped <> 0 Then
        If OpenC2fbGeneratedFileOutput(generatedOutput, assertHeaderPath) = 0 Then
            errorMessage = "cannot write SQLite preprocessing header: assert.h"
            Return 0
        End If
        WriteC2fbGeneratedFileLine(generatedOutput, _
            "/* C2FB candidate mode: assertions are restored during integration. */")
        WriteC2fbGeneratedFileLine(generatedOutput, "#ifndef SQLITE_C2FB_ASSERT_H")
        WriteC2fbGeneratedFileLine(generatedOutput, "#define SQLITE_C2FB_ASSERT_H")
        Dim assertionMacro As C2fbMacroBindingModel
        assertionMacro.name = "assert"
        assertionMacro.parameters = "expression"
        assertionMacro.bodyText = "((void)0)"
        assertionMacro.isFunctionLike = -1
        WriteC2fbMacroBinding(generatedOutput, assertionMacro)
        WriteC2fbGeneratedFileLine(generatedOutput, "#endif")
        CloseC2fbGeneratedFileOutput(generatedOutput)
        If C2fbGeneratedFileOutputHasFailed(generatedOutput) <> 0 Then
            errorMessage = C2fbGeneratedFileOutputFailureMessage( _
                generatedOutput, "cannot finish SQLite preprocessing header: assert.h")
            Return 0
        End If
    ElseIf FileLengthIfPresent(assertHeaderPath) >= 0 Then
        Kill assertHeaderPath
    End If
    Return -1
End Function

Private Sub WriteDefaultPreprocessorHeaders( _
    ByVal sourceDirectory As String, _
    ByVal repositoryRoot As String, _
    ByVal includeDirectory As String, _
    ByVal assertionsStripped As Long, _
    ByVal assertionsRestored As Long _
)
    Dim environment As C2fbPreprocessorEnvironmentModel
    environment.sourceDirectory = sourceDirectory
    environment.includeDirectory = includeDirectory
    environment.assertionsStripped = assertionsStripped
    environment.assertionsRestored = assertionsRestored
    Dim errorMessage As String
    If WriteC2fbPreprocessorHeaders(environment, errorMessage) = 0 Then _
        ReportError(errorMessage)

    Dim pragmaPath As String = includeDirectory & "/pragma.h"
    Dim pragmaScript As String = repositoryRoot & "/tool/mkpragmatab.tcl"
    Dim pragmaExitCode As Long = RunShellCommand( _
        "tclsh", ShellQuote(pragmaScript) & " " & ShellQuote(pragmaPath))
    If pragmaExitCode <> 0 OrElse FileLengthIfPresent(pragmaPath) <= 0 Then _
        ReportError("failed to generate pragma.h for C preprocessing")
End Sub

Private Sub ConvertPreprocessedBodyRequest( _
    ByRef translation As C2fbTranslationContext, _
    ByRef catalog As C2fbProjectCatalog, _
    ByRef request As C2fbPreprocessedBodyRequestModel _
)
    Dim sourceDirectory As String = request.sourceDirectory
    Dim generatedIncludeDirectory As String = _
        request.generatedIncludeDirectory
    Dim outputDirectory As String = request.outputDirectory
    Dim compilerName As String = request.compilerName
    Dim threadSafe As Long = request.threadSafe
    Dim featureDefines As String = request.featureDefines
    If Len(sourceDirectory) = 0 OrElse Len(generatedIncludeDirectory) = 0 OrElse _
       Len(outputDirectory) = 0 OrElse threadSafe < 0 OrElse threadSafe > 1 Then
        ReportError("translate-preprocessed-tree requires source, generated-header, output, and FreeBASIC directories")
    End If
    If Len(compilerName) = 0 Then compilerName = "gcc"

    Dim genericBodyRequest As C2fbGenericBodyInputModel
    If request.inputKind = C2FB_PREPROCESSED_INPUT_TREE Then
        genericBodyRequest.bodyRequest.inputShape = C2FB_BODY_INPUT_TREE
    Else
        genericBodyRequest.bodyRequest.inputShape = C2FB_BODY_INPUT_FILE
    End If
    genericBodyRequest.bodyRequest.translationOptions = request.translationOptions
    If AppendC2fbArgumentValue( _
        genericBodyRequest.argumentList, _
        "--fb-source-directory=" & request.translationOptions.fbSourceDirectory, _
        MAX_FUNCTIONS) = 0 OrElse _
       AppendC2fbArgumentValue( _
        genericBodyRequest.argumentList, _
        "--keep-unresolved=" & Trim(Str( _
            request.translationOptions.keepUnresolvedDependencies)), _
        MAX_FUNCTIONS) = 0 OrElse _
       AppendC2fbArgumentValue( _
        genericBodyRequest.argumentList, _
        "--include-existing=" & Trim(Str( _
            request.translationOptions.includeExistingBodies)), _
        MAX_FUNCTIONS) = 0 Then _
        ReportError("SQLite body defaults exceed the configured option limit")
    For optionIndex As Long = 0 To request.bodyArguments.itemCount - 1
        If AppendC2fbArgumentValue( _
            genericBodyRequest.argumentList, _
            request.bodyArguments.values(optionIndex), MAX_FUNCTIONS) = 0 Then _
            ReportError("SQLite body options exceed the configured limit")
    Next
    ParseC2fbGenericBodyOptions(translation, genericBodyRequest)
    Dim bodyOptions As C2fbBodyTranslationOptions = _
        genericBodyRequest.bodyRequest.translationOptions
    If threadSafe <> 0 AndAlso _
       bodyOptions.assumeSingleThreadedAtomics <> 0 Then _
        ReportError( _
            "--assume-single-threaded-atomics is only supported with THREADSAFE=0")
    bodyOptions.assumeSingleThreadedAtomics = CInt(threadSafe = 0)
    Dim fbSourceDirectory As String = bodyOptions.fbSourceDirectory
    Dim keepUnresolvedDependencies As Long = _
        bodyOptions.keepUnresolvedDependencies
    Dim includeExistingBodies As Long = bodyOptions.includeExistingBodies

    Dim repositoryRoot As String = "."
    Dim sourcePath As String = sourceDirectory
    While Len(sourcePath) > 1 AndAlso _
          (Right(sourcePath, 1) = "/" OrElse Right(sourcePath, 1) = "\")
        sourcePath = Left(sourcePath, Len(sourcePath) - 1)
    Wend
    Dim separator As Long = 0
    For i As Long = Len(sourcePath) To 1 Step -1
        If Asc(sourcePath, i) = Asc("/") OrElse Asc(sourcePath, i) = Asc("\") Then
            separator = i
            Exit For
        End If
    Next
    If separator > 0 Then
        repositoryRoot = Left(sourcePath, separator - 1)
        If Len(repositoryRoot) = 0 Then repositoryRoot = "/"
    End If

    Dim includeDirectory As String = outputDirectory & "/.c2fb_includes"
    Dim preprocessedDirectory As String = outputDirectory & "/.c2fb_preprocessed"
    If MakeDirectoryTree(outputDirectory) = 0 OrElse _
       MakeDirectoryTree(includeDirectory) = 0 OrElse _
       MakeDirectoryTree(preprocessedDirectory) = 0 Then
        ReportError("cannot create preprocessing output directories")
    End If
    Dim featureArguments As String = FeatureDefineArguments(featureDefines)
    Dim assertionsStripped As Long = _
        FeatureDefineEnabled(featureDefines, "C2FB_DISABLE_ASSERTS")
    Dim assertionsRestored As Long = _
        FeatureDefineEnabled(featureDefines, "C2FB_RESTORE_ASSERTS")
    If assertionsStripped <> 0 AndAlso assertionsRestored <> 0 Then _
        ReportError("C2FB_DISABLE_ASSERTS and C2FB_RESTORE_ASSERTS cannot both be enabled")
    WriteDefaultPreprocessorHeaders(sourceDirectory, repositoryRoot, includeDirectory, _
                                    assertionsStripped, assertionsRestored)

    Dim sourceFiles As C2fbSourceFileSetModel
    Dim fileName As String
    Select Case request.inputKind
    Case C2FB_PREPROCESSED_INPUT_TREE
        If AppendC2fbSourceDirectoryFiles( _
            sourceFiles, sourceDirectory, ".c", -1, -1) = 0 Then _
            ReportError("source tree exceeds the configured file limit")
    Case C2FB_PREPROCESSED_INPUT_FILE_LIST
        If request.selectedSourceFiles.itemCount = 0 Then _
            ReportError("file-list input mode requires a source selection")
        For selectionIndex As Long = 0 To request.selectedSourceFiles.itemCount - 1
            fileName = request.selectedSourceFiles.names(selectionIndex)
            Dim lowerName As String = LCase(fileName)
            Dim fileExtension As String = Right(lowerName, 2)
            If Len(fileName) <= 2 OrElse _
               (fileExtension <> ".c" AndAlso fileExtension <> ".h") OrElse _
               InStr(fileName, "/") <> 0 OrElse InStr(fileName, Chr(92)) <> 0 OrElse _
               Left(lowerName, 4) = "test" OrElse lowerName = "tclsqlite.c" OrElse _
               lowerName = "tclsqlite.h" Then
                ReportError("invalid engine C input in file selection: " & fileName)
            End If
            If FileLengthIfPresent(sourceDirectory & "/" & fileName) < 0 Then _
                ReportError("selected C input does not exist: " & fileName)
            If AppendC2fbSourceFileName( _
                sourceFiles, fileName, -1) = 0 Then _
                ReportError("selected source list exceeds the configured file limit")
        Next
    Case Else
        ReportError("invalid preprocessed body input selection kind")
    End Select

    If sourceFiles.itemCount = 0 Then _
        ReportError("source selection contains no engine C inputs: " & sourceDirectory)

    ' A .h and .c pair with the same stem need distinct candidate paths.
    For fileIndex As Long = 0 To sourceFiles.itemCount - 1
        Dim currentBase As String = Left( _
            sourceFiles.names(fileIndex), Len(sourceFiles.names(fileIndex)) - 2)
        If LCase(Right(sourceFiles.names(fileIndex), 2)) = ".h" Then currentBase &= "_header"
        For priorIndex As Long = 0 To fileIndex - 1
            Dim priorBase As String = Left( _
                sourceFiles.names(priorIndex), Len(sourceFiles.names(priorIndex)) - 2)
            If LCase(Right(sourceFiles.names(priorIndex), 2)) = ".h" Then priorBase &= "_header"
            If LCase(priorBase) = LCase(currentBase) Then _
                ReportError("selected C inputs would share a candidate output name: " & currentBase)
        Next
    Next

    Dim preprocessedCount As Long = 0
    Dim preprocessingFailureCount As Long = 0
    For fileIndex As Long = 0 To sourceFiles.itemCount - 1
        fileName = sourceFiles.names(fileIndex)
        Dim inputPath As String = sourceDirectory & "/" & fileName
        Dim outputBaseName As String = Left(fileName, Len(fileName) - 2)
        If LCase(Right(fileName, 2)) = ".h" Then outputBaseName &= "_header"
        Dim preprocessedPath As String = preprocessedDirectory & "/" & _
            outputBaseName & ".i"
        Dim outputPath As String = outputDirectory & "/" & _
            outputBaseName & "_preprocessed_candidates.bas"
        If FileLengthIfPresent(preprocessedPath) >= 0 Then Kill preprocessedPath
        Dim preprocessRequest As C2fbPreprocessorRequestModel
        preprocessRequest.compilerName = compilerName
        preprocessRequest.compilerOptions = _
            "-E -P -x c -DSQLITE_THREADSAFE=" & Trim(Str(threadSafe)) & _
            featureArguments & _
            " -I" & ShellQuote(includeDirectory) & _
            " -I" & ShellQuote(generatedIncludeDirectory) & _
            " -I" & ShellQuote(sourceDirectory) & _
            genericBodyRequest.compilerOptions
        preprocessRequest.inputPath = inputPath
        preprocessRequest.outputPath = preprocessedPath
        Dim preprocessResult As C2fbPreprocessorResultModel
        If RunC2fbPreprocessor(preprocessRequest, preprocessResult) = 0 Then
            ReportC2fbPreprocessorFailure( _
                translation, preprocessResult, "C preprocessing failed")
            ' An older candidate belongs to a different preprocessing run and
            ' must not be reported as a valid result after this failure.
            If FileLengthIfPresent(outputPath) >= 0 Then Kill outputPath
            preprocessingFailureCount += 1
            Continue For
        End If

        Dim fileOptions As C2fbBodyTranslationOptions = bodyOptions
        fileOptions.assertionsStripped = assertionsStripped
        ' A THREADSAFE=0 SQLite build has no supported concurrent connection
        ' access, so relaxed atomic loads can use ordinary scalar reads.
        fileOptions.assumeSingleThreadedAtomics = CInt(threadSafe = 0)
        ' -P removes markers, so preserve the path but suppress flattened-file coordinates.
        fileOptions.sourceLabel = inputPath
        fileOptions.sourceOriginPrecision = C2FB_SOURCE_ORIGIN_PATH_ONLY
        Dim fileRequest As C2fbBodyFileTranslationRequestModel
        fileRequest.inputPath = preprocessedPath
        fileRequest.outputPath = outputPath
        fileRequest.translationOptions = fileOptions
        TranslateCBodyFile(translation, catalog, fileRequest)
        preprocessedCount += 1
    Next
    Print "preprocessed " & Trim(Str(preprocessedCount)) & _
          " engine C inputs; skipped " & _
          Trim(Str(preprocessingFailureCount)) & _
          " preprocessing failures; candidates in " & outputDirectory
    If preprocessingFailureCount <> 0 Then End 1
End Sub
/' end of c2fb_sqlite_preprocessed_adapter.bi '/
