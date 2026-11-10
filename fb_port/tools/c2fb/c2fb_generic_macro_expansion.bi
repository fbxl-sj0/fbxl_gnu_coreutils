/'
    Project: C2FB generic header converter

    File: c2fb_generic_macro_expansion.bi

    Purpose:

        Expand selected C macro replacement lists with the configured C
        preprocessor before generic-header lowering.

    Responsibilities:

        - Select active object-like and fixed-parameter function macros.
        - Ask the C compiler to expand their referenced macros.
        - Preserve formal parameters when rebuilding expanded definitions.
        - Apply override definitions without losing original source locations.
        - Report requests that were unused or could not be represented safely.

    This file intentionally does NOT contain:

        - C expression lowering or generated FreeBASIC macro formatting.
        - Macro token pasting or stringizing reimplementation.
        - Generic command-line parsing or compiler target selection.
'/

Private Type C2fbGenericMacroExpansionWorkModel
    sourceName As String
    functionLike As Long
    parameterNames(Any) As String
    placeholderNames(Any) As String
    parameterCount As Long
    isVariadic As Long
    beginMarker As String
    endMarker As String
    invocation As String
    expandedBody As String
    hasOutput As Long
    replacementDefinition As String
End Type

Private Type C2fbMacroInDefineExpansionWorkModel
    ownerName As String
    ownerHeader As String
    ownerBody As String
    targetName As String
    callPosition As Long
    callLength As Long
    beginMarker As String
    endMarker As String
    invocation As String
    expandedBody As String
    hasOutput As Long
End Type

Private Type C2fbMacroExpansionDefinitionIndexModel
    sourceName As String
    rawValue As String
    functionLike As Long
End Type

Private Function GenericMacroExpansionDefinitionIndex( _
    definitions() As C2fbMacroExpansionDefinitionIndexModel, _
    ByVal definitionCount As Long, ByVal sourceName As String _
) As Long
    For definitionIndex As Long = 0 To definitionCount - 1
        If definitions(definitionIndex).sourceName = sourceName Then _
            Return definitionIndex
    Next
    Return -1
End Function

Private Function GenericMacroExpansionBodyHasDynamicBuiltin( _
    ByVal sourceText As String, _
    definitions() As C2fbMacroExpansionDefinitionIndexModel, _
    ByVal definitionCount As Long, ByVal functionLike As Long, _
    ByVal checkVariadicHazards As Long, _
    stackNames() As String, _
    ByVal stackDepth As Long _
) As Long
    If stackDepth >= MAX_GENERIC_MACRO_EXPANSION_DEPTH Then Return -1
    If functionLike <> 0 Then
        Dim functionDefinition As C2fbMacroDefinitionModel
        functionDefinition.directive = "define"
        functionDefinition.functionLike = -1
        functionDefinition.rawValue = sourceText
        TokenizeCDeclaration( _
            functionDefinition.rawValue, functionDefinition.tokens(), _
            functionDefinition.tokenCount)
        Dim parameterNames() As String
        Dim freeParameterNames() As String
        Dim parameterCount As Long
        Dim isVariadic As Long
        If ParseGenericFunctionMacro( _
            functionDefinition, parameterNames(), freeParameterNames(), _
            parameterCount, isVariadic, sourceText) = 0 Then Return -1
    End If
    Dim position As Long = 1
    While position <= Len(sourceText)
        Dim currentByte As Long = Asc(sourceText, position)
        If currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
            Dim quoteByte As Long = currentByte
            position += 1
            Dim escaped As Long = 0
            Dim foundClosingQuote As Long = 0
            While position <= Len(sourceText)
                currentByte = Asc(sourceText, position)
                If escaped <> 0 Then
                    escaped = 0
                ElseIf currentByte = Asc(Chr(92)) Then
                    escaped = -1
                ElseIf currentByte = quoteByte Then
                    position += 1
                    foundClosingQuote = -1
                    Exit While
                End If
                position += 1
            Wend
            If foundClosingQuote = 0 Then Return -1
            Continue While
        End If
        If checkVariadicHazards <> 0 AndAlso _
           currentByte = Asc("#") Then Return -1
        If IsIdentifierStart(currentByte) = 0 Then
            position += 1
            Continue While
        End If
        Dim tokenStart As Long = position
        position += 1
        While position <= Len(sourceText) AndAlso _
              IsIdentifierPart(Asc(sourceText, position)) <> 0
            position += 1
        Wend
        Dim tokenText As String = Mid( _
            sourceText, tokenStart, position - tokenStart)
        Select Case tokenText
        Case "__BASE_FILE__", "__COUNTER__", "__DATE__", "__FILE__", _
             "__INCLUDE_LEVEL__", "__LINE__", "__TIMESTAMP__", "__TIME__", _
             "__VA_OPT__"
            Return -1
        End Select
        Dim referencedIndex As Long = GenericMacroExpansionDefinitionIndex( _
            definitions(), definitionCount, tokenText)
        If referencedIndex < 0 Then Continue While
        If definitions(referencedIndex).functionLike <> 0 Then
            Dim nextPosition As Long = position
            While nextPosition <= Len(sourceText) AndAlso _
                  IsSpaceByte(Asc(sourceText, nextPosition)) <> 0
                nextPosition += 1
            Wend
            If nextPosition > Len(sourceText) OrElse _
               Asc(sourceText, nextPosition) <> Asc("(") Then Continue While
        End If
        Dim isRecursive As Long = 0
        For stackIndex As Long = 0 To stackDepth - 1
            If stackNames(stackIndex) = tokenText Then
                isRecursive = -1
                Exit For
            End If
        Next
        If isRecursive <> 0 Then Continue While
        stackNames(stackDepth) = tokenText
        If GenericMacroExpansionBodyHasDynamicBuiltin( _
            definitions(referencedIndex).rawValue, definitions(), _
            definitionCount, definitions(referencedIndex).functionLike, _
            checkVariadicHazards, stackNames(), stackDepth + 1) <> 0 Then Return -1
    Wend
    Return 0
End Function

Private Function GenericMacroExpansionPlaceholderInToken( _
    ByVal tokenText As String, _
    ByRef work As C2fbGenericMacroExpansionWorkModel, _
    ByRef parameterIndex As Long _
) As Long
    parameterIndex = -1
    For candidateIndex As Long = 0 To work.parameterCount - 1
        If tokenText = work.placeholderNames(candidateIndex) Then
            parameterIndex = candidateIndex
            Return -1
        End If
        If InStr(tokenText, work.placeholderNames(candidateIndex)) > 0 Then _
            Return 0
    Next
    Return -1
End Function

Private Function RestoreGenericMacroExpansionParameters( _
    ByRef work As C2fbGenericMacroExpansionWorkModel, _
    ByVal expandedBody As String, ByRef restoredBody As String _
) As Long
    restoredBody = ""
    Dim position As Long = 1
    While position <= Len(expandedBody)
        Dim currentByte As Long = Asc(expandedBody, position)
        If currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
            Dim quoteByte As Long = currentByte
            Dim tokenStart As Long = position
            position += 1
            Dim escaped As Long = 0
            While position <= Len(expandedBody)
                currentByte = Asc(expandedBody, position)
                If escaped <> 0 Then
                    escaped = 0
                ElseIf currentByte = Asc(Chr(92)) Then
                    escaped = -1
                ElseIf currentByte = quoteByte Then
                    position += 1
                    Exit While
                End If
                position += 1
            Wend
            If position > Len(expandedBody) + 1 OrElse _
               Asc(expandedBody, position - 1) <> quoteByte Then Return 0
            Dim quotedToken As String = Mid( _
                expandedBody, tokenStart, position - tokenStart)
            For parameterIndex As Long = 0 To work.parameterCount - 1
                If InStr(quotedToken, work.placeholderNames(parameterIndex)) > 0 Then _
                    Return 0
            Next
            restoredBody &= quotedToken
        ElseIf IsIdentifierStart(currentByte) <> 0 Then
            Dim tokenStart As Long = position
            position += 1
            While position <= Len(expandedBody) AndAlso _
                  IsIdentifierPart(Asc(expandedBody, position)) <> 0
                position += 1
            Wend
            Dim tokenText As String = Mid( _
                expandedBody, tokenStart, position - tokenStart)
            Dim parameterIndex As Long
            If GenericMacroExpansionPlaceholderInToken( _
                tokenText, work, parameterIndex) = 0 Then Return 0
            If parameterIndex >= 0 Then
                restoredBody &= work.parameterNames(parameterIndex)
            Else
                restoredBody &= tokenText
            End If
        Else
            restoredBody &= Chr(currentByte)
            position += 1
        End If
    Wend
    Return -1
End Function

Private Function BuildGenericMacroExpansionWorkItems( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal macroTablePath As String, _
    workItems() As C2fbGenericMacroExpansionWorkModel, _
    ByRef workCount As Long _
) As Long
    Dim definitions() As C2fbMacroExpansionDefinitionIndexModel
    ReDim definitions(0 To 255)
    Dim definitionCount As Long = 0
    Dim reader As C2fbTextFileLineReaderModel
    If OpenC2fbTextFileLineReader(reader, macroTablePath) = 0 Then Return 0
    Dim lineText As String
    While ReadC2fbTextFileLine(reader, lineText) <> 0
        Dim definition As C2fbMacroDefinitionModel
        If ParseC2fbMacroDirective(Trim(lineText), definition) = 0 OrElse _
           definition.directive <> "define" Then Continue While
        If definitionCount >= MAX_GENERIC_HEADER_MACROS Then
            CloseC2fbTextFileLineReader(reader)
            Return 0
        End If
        If definitionCount > UBound(definitions) Then _
            ReDim Preserve definitions(0 To UBound(definitions) * 2 + 1)
        definitions(definitionCount).sourceName = definition.sourceName
        definitions(definitionCount).rawValue = definition.rawValue
        definitions(definitionCount).functionLike = definition.functionLike
        definitionCount += 1
    Wend
    CloseC2fbTextFileLineReader(reader)

    ReDim workItems(0 To 15)
    workCount = 0
    For definitionIndex As Long = 0 To definitionCount - 1
        Dim expansionRequested As Long = _
            GenericMacroExpansionRequestedInPolicy( _
                policy, definitions(definitionIndex).sourceName)
        Dim expansionExcluded As Long = GenericMacroNoExpansionInPolicy( _
            policy, definitions(definitionIndex).sourceName)
        If expansionExcluded <> 0 Then
            If expansionRequested <> 0 Then _
                MarkGenericMacroExpansionInPolicy( _
                    policy, definitions(definitionIndex).sourceName, -1)
            Continue For
        End If
        If expansionRequested = 0 Then Continue For
        Dim definition As C2fbMacroDefinitionModel
        definition.directive = "define"
        definition.sourceName = definitions(definitionIndex).sourceName
        definition.rawValue = definitions(definitionIndex).rawValue
        definition.functionLike = definitions(definitionIndex).functionLike
        If definition.functionLike <> 0 Then _
            TokenizeCDeclaration( _
                definition.rawValue, definition.tokens(), definition.tokenCount)

        Dim parameterNames() As String
        Dim freeParameterNames() As String
        Dim parameterCount As Long = 0
        Dim isVariadic As Long = 0
        Dim body As String = definition.rawValue
        If definition.functionLike <> 0 Then
            If ParseGenericFunctionMacro( _
                definition, parameterNames(), freeParameterNames(), _
                parameterCount, isVariadic, body) = 0 Then
                MarkGenericMacroExpansionInPolicy( _
                    policy, definition.sourceName, 0)
                Continue For
            End If
        End If

        Dim stackNames() As String
        ReDim stackNames(0 To MAX_GENERIC_MACRO_EXPANSION_DEPTH - 1)
        stackNames(0) = definition.sourceName
        If GenericMacroExpansionBodyHasDynamicBuiltin( _
            body, definitions(), definitionCount, 0, isVariadic, _
            stackNames(), 1) <> 0 Then
            MarkGenericMacroExpansionInPolicy( _
                policy, definition.sourceName, 0)
            Continue For
        End If

        If workCount >= MAX_FUNCTIONS Then
            MarkGenericMacroExpansionInPolicy( _
                policy, definition.sourceName, 0)
            Continue For
        End If
        If workCount > UBound(workItems) Then _
            ReDim Preserve workItems(0 To UBound(workItems) * 2 + 1)

        Dim work As C2fbGenericMacroExpansionWorkModel
        work.sourceName = definition.sourceName
        work.functionLike = definition.functionLike
        work.parameterCount = parameterCount
        work.isVariadic = isVariadic
        Dim markerSuffix As String
        For suffixAttempt As Long = 0 To 127
            Dim candidateSuffix As String = _
                Trim(Str(CULngInt(Timer * 1000))) & "_" & _
                Trim(Str(workCount)) & "_" & Trim(Str(suffixAttempt))
            Dim hasNameConflict As Long = CInt( _
                GenericMacroExpansionDefinitionIndex( _
                    definitions(), definitionCount, _
                    "C2FB_EXPANSION_BEGIN_" & candidateSuffix) >= 0 OrElse _
                GenericMacroExpansionDefinitionIndex( _
                    definitions(), definitionCount, _
                    "C2FB_EXPANSION_END_" & candidateSuffix) >= 0)
            For parameterIndex As Long = 0 To parameterCount - 1
                If GenericMacroExpansionDefinitionIndex( _
                    definitions(), definitionCount, _
                    "C2FB_EXPANSION_ARGUMENT_" & candidateSuffix & "_" & _
                    Trim(Str(parameterIndex))) >= 0 Then _
                    hasNameConflict = -1
            Next
            If hasNameConflict = 0 Then
                markerSuffix = candidateSuffix
                Exit For
            End If
        Next
        If markerSuffix = "" Then
            MarkGenericMacroExpansionInPolicy( _
                policy, definition.sourceName, 0)
            Continue For
        End If
        If parameterCount > 0 Then
            ReDim work.parameterNames(0 To parameterCount - 1)
            ReDim work.placeholderNames(0 To parameterCount - 1)
            For parameterIndex As Long = 0 To parameterCount - 1
                work.parameterNames(parameterIndex) = parameterNames(parameterIndex)
                work.placeholderNames(parameterIndex) = _
                    "C2FB_EXPANSION_ARGUMENT_" & markerSuffix & "_" & _
                    Trim(Str(parameterIndex))
            Next
        End If
        work.beginMarker = "C2FB_EXPANSION_BEGIN_" & markerSuffix
        work.endMarker = "C2FB_EXPANSION_END_" & markerSuffix
        work.invocation = definition.sourceName
        If definition.functionLike <> 0 Then
            work.invocation &= "("
            For parameterIndex As Long = 0 To parameterCount - 1
                If parameterIndex > 0 Then work.invocation &= ", "
                work.invocation &= work.placeholderNames(parameterIndex)
            Next
            work.invocation &= ")"
        End If
        workItems(workCount) = work
        workCount += 1
    Next
    Return -1
End Function

Private Function WriteGenericMacroExpansionProbe( _
    ByVal probePath As String, _
    workItems() As C2fbGenericMacroExpansionWorkModel, _
    ByVal workCount As Long _
) As Long
    If workCount <= 0 Then Return 0
    Dim fileNumber As Long = FreeFile
    If Open(probePath For Output As #fileNumber) <> 0 Then Return 0
    For workIndex As Long = 0 To workCount - 1
        Print #fileNumber, workItems(workIndex).beginMarker
        Print #fileNumber, workItems(workIndex).invocation
        Print #fileNumber, workItems(workIndex).endMarker
    Next
    Close #fileNumber
    If FileLengthIfPresent(probePath) < 0 Then Return 0
    Return -1
End Function

Private Function ReadGenericMacroExpansionProbeOutput( _
    ByVal outputPath As String, _
    workItems() As C2fbGenericMacroExpansionWorkModel, _
    ByVal workCount As Long _
) As Long
    Dim outputLength As LongInt = FileLengthIfPresent(outputPath)
    If outputLength < 0 OrElse _
       outputLength > MAX_GENERIC_MACRO_EXPANSION_OUTPUT_BYTES Then Return 0
    Dim reader As C2fbTextFileLineReaderModel
    If OpenC2fbTextFileLineReader(reader, outputPath) = 0 Then Return 0
    Dim activeWorkIndex As Long = -1
    Dim lineText As String
    While ReadC2fbTextFileLine(reader, lineText) <> 0
        Dim trimmedLine As String = Trim(lineText)
        Dim markerFound As Long = 0
        For workIndex As Long = 0 To workCount - 1
            If trimmedLine = workItems(workIndex).beginMarker Then
                If activeWorkIndex >= 0 Then
                    CloseC2fbTextFileLineReader(reader)
                    Return 0
                End If
                activeWorkIndex = workIndex
                workItems(workIndex).expandedBody = ""
                markerFound = -1
                Exit For
            ElseIf trimmedLine = workItems(workIndex).endMarker Then
                If activeWorkIndex <> workIndex Then
                    CloseC2fbTextFileLineReader(reader)
                    Return 0
                End If
                workItems(workIndex).hasOutput = -1
                activeWorkIndex = -1
                markerFound = -1
                Exit For
            End If
        Next
        If markerFound <> 0 OrElse activeWorkIndex < 0 OrElse trimmedLine = "" Then _
            Continue While
        If Len(workItems(activeWorkIndex).expandedBody) + Len(trimmedLine) + 1 > _
           MAX_GENERIC_MACRO_EXPANSION_BYTES Then
            CloseC2fbTextFileLineReader(reader)
            Return 0
        End If
        If workItems(activeWorkIndex).expandedBody <> "" Then _
            workItems(activeWorkIndex).expandedBody &= " "
        workItems(activeWorkIndex).expandedBody &= trimmedLine
    Wend
    CloseC2fbTextFileLineReader(reader)
    If activeWorkIndex >= 0 Then Return 0
    For workIndex As Long = 0 To workCount - 1
        If workItems(workIndex).hasOutput = 0 Then Return 0
    Next
    Return -1
End Function

Private Function WriteGenericMacroExpansionOverrides( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal outputPath As String, _
    workItems() As C2fbGenericMacroExpansionWorkModel, _
    ByVal workCount As Long _
) As Long
    Dim replacementCount As Long = 0
    For workIndex As Long = 0 To workCount - 1
        If workItems(workIndex).hasOutput = 0 Then
            MarkGenericMacroExpansionInPolicy( _
                policy, workItems(workIndex).sourceName, 0)
            Continue For
        End If
        Dim restoredBody As String
        If RestoreGenericMacroExpansionParameters( _
            workItems(workIndex), workItems(workIndex).expandedBody, _
            restoredBody) = 0 Then
            MarkGenericMacroExpansionInPolicy( _
                policy, workItems(workIndex).sourceName, 0)
            workItems(workIndex).hasOutput = 0
            Continue For
        End If
        Dim definitionText As String = _
            "#define " & workItems(workIndex).sourceName
        If workItems(workIndex).functionLike <> 0 Then
            definitionText &= "("
            For parameterIndex As Long = 0 To _
                workItems(workIndex).parameterCount - 1
                If parameterIndex > 0 Then definitionText &= ", "
                If workItems(workIndex).isVariadic <> 0 AndAlso _
                   parameterIndex = workItems(workIndex).parameterCount - 1 Then
                    definitionText &= "..."
                Else
                    definitionText &= workItems(workIndex).parameterNames(parameterIndex)
                End If
            Next
            definitionText &= ")"
        End If
        If restoredBody <> "" Then definitionText &= " " & restoredBody
        workItems(workIndex).replacementDefinition = definitionText
        replacementCount += 1
    Next
    If replacementCount = 0 Then Return -1

    Dim fileNumber As Long = FreeFile
    If Open(outputPath For Output As #fileNumber) <> 0 Then
        For workIndex As Long = 0 To workCount - 1
            If workItems(workIndex).replacementDefinition <> "" Then _
                MarkGenericMacroExpansionInPolicy( _
                    policy, workItems(workIndex).sourceName, 0)
        Next
        Return 0
    End If
    For workIndex As Long = 0 To workCount - 1
        If workItems(workIndex).replacementDefinition <> "" Then _
            Print #fileNumber, workItems(workIndex).replacementDefinition
    Next
    Close #fileNumber
    If Err <> 0 OrElse FileLengthIfPresent(outputPath) < 0 Then
        If FileLengthIfPresent(outputPath) >= 0 Then Kill outputPath
        For workIndex As Long = 0 To workCount - 1
            If workItems(workIndex).replacementDefinition <> "" Then _
                MarkGenericMacroExpansionInPolicy( _
                    policy, workItems(workIndex).sourceName, 0)
        Next
        Return 0
    End If
    For workIndex As Long = 0 To workCount - 1
        If workItems(workIndex).replacementDefinition <> "" Then _
            MarkGenericMacroExpansionInPolicy( _
                policy, workItems(workIndex).sourceName, 1)
    Next
    Return -1
End Function

Private Function ExpandGenericHeaderMacrosWithPreprocessor( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal compilerName As String, ByVal compilerOptions As String, _
    ByVal inputPath As String, ByVal macroTablePath As String, _
    ByVal probePath As String, ByVal expandedOutputPath As String, _
    ByVal overridePath As String _
) As Long
    If policy.macroExpansionPatternCount = 0 Then Return -1
    Dim workItems() As C2fbGenericMacroExpansionWorkModel
    Dim workCount As Long
    If BuildGenericMacroExpansionWorkItems( _
        policy, macroTablePath, workItems(), workCount) = 0 Then Return 0
    If workCount = 0 Then Return -1
    If WriteGenericMacroExpansionProbe( _
        probePath, workItems(), workCount) = 0 Then
        For workIndex As Long = 0 To workCount - 1
            MarkGenericMacroExpansionInPolicy( _
                policy, workItems(workIndex).sourceName, 0)
        Next
        Return -1
    End If

    Dim preprocessRequest As C2fbPreprocessorRequestModel
    preprocessRequest.compilerName = compilerName
    preprocessRequest.compilerOptions = _
        "-E -P -x c" & compilerOptions & _
        " -include " & ShellQuote(inputPath)
    preprocessRequest.inputPath = probePath
    preprocessRequest.outputPath = expandedOutputPath
    Dim preprocessResult As C2fbPreprocessorResultModel
    If RunC2fbPreprocessor(preprocessRequest, preprocessResult) = 0 OrElse _
       ReadGenericMacroExpansionProbeOutput( _
            expandedOutputPath, workItems(), workCount) = 0 Then
        For workIndex As Long = 0 To workCount - 1
            MarkGenericMacroExpansionInPolicy( _
                policy, workItems(workIndex).sourceName, 0)
        Next
        If FileLengthIfPresent(probePath) >= 0 Then Kill probePath
        If FileLengthIfPresent(expandedOutputPath) >= 0 Then _
            Kill expandedOutputPath
        Return -1
    End If
    If FileLengthIfPresent(probePath) >= 0 Then Kill probePath
    If FileLengthIfPresent(expandedOutputPath) >= 0 Then _
        Kill expandedOutputPath
    Return WriteGenericMacroExpansionOverrides( _
        policy, overridePath, workItems(), workCount)
End Function

Private Function FindGenericMacroCallClosingParenthesis( _
    ByVal sourceText As String, ByVal openPosition As Long, _
    ByRef closePosition As Long _
) As Long
    closePosition = 0
    Dim depth As Long = 0
    Dim position As Long = openPosition
    While position <= Len(sourceText)
        Dim currentByte As Long = Asc(sourceText, position)
        If currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
            Dim quoteByte As Long = currentByte
            position += 1
            Dim escaped As Long = 0
            Dim foundClosingQuote As Long = 0
            While position <= Len(sourceText)
                currentByte = Asc(sourceText, position)
                If escaped <> 0 Then
                    escaped = 0
                ElseIf currentByte = Asc(Chr(92)) Then
                    escaped = -1
                ElseIf currentByte = quoteByte Then
                    foundClosingQuote = -1
                    Exit While
                End If
                position += 1
            Wend
            If foundClosingQuote = 0 Then Return 0
        ElseIf currentByte = Asc("(") Then
            depth += 1
        ElseIf currentByte = Asc(")") Then
            depth -= 1
            If depth < 0 Then Return 0
            If depth = 0 Then
                closePosition = position
                Return -1
            End If
        End If
        position += 1
    Wend
    Return 0
End Function

Private Function GenericMacroCallUsesParentParameter( _
    ByVal sourceText As String, ByVal callPosition As Long, _
    ByVal callLength As Long, parameterNames() As String, _
    ByVal parameterCount As Long _
) As Long
    Dim endPosition As Long = callPosition + callLength
    Dim position As Long = callPosition
    While position < endPosition
        Dim currentByte As Long = Asc(sourceText, position)
        If currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
            Dim quoteByte As Long = currentByte
            position += 1
            Dim escaped As Long = 0
            While position < endPosition
                currentByte = Asc(sourceText, position)
                If escaped <> 0 Then
                    escaped = 0
                ElseIf currentByte = Asc(Chr(92)) Then
                    escaped = -1
                ElseIf currentByte = quoteByte Then
                    position += 1
                    Exit While
                End If
                position += 1
            Wend
            Continue While
        End If
        If IsIdentifierStart(currentByte) = 0 Then
            position += 1
            Continue While
        End If
        Dim tokenStart As Long = position
        position += 1
        While position < endPosition AndAlso _
              IsIdentifierPart(Asc(sourceText, position)) <> 0
            position += 1
        Wend
        Dim tokenText As String = Mid(sourceText, tokenStart, position - tokenStart)
        For parameterIndex As Long = 0 To parameterCount - 1
            If tokenText = parameterNames(parameterIndex) Then Return -1
        Next
    Wend
    Return 0
End Function

Private Function GenericMacroCallHasStringizeOrPasteContext( _
    ByVal sourceText As String, ByVal callPosition As Long, _
    ByVal callLength As Long _
) As Long
    Dim previousPosition As Long = callPosition - 1
    While previousPosition > 0 AndAlso _
          IsSpaceByte(Asc(sourceText, previousPosition)) <> 0
        previousPosition -= 1
    Wend
    If previousPosition > 0 AndAlso _
       Asc(sourceText, previousPosition) = Asc("#") Then Return -1

    Dim nextPosition As Long = callPosition + callLength
    While nextPosition <= Len(sourceText) AndAlso _
          IsSpaceByte(Asc(sourceText, nextPosition)) <> 0
        nextPosition += 1
    Wend
    If nextPosition + 1 <= Len(sourceText) AndAlso _
       Mid(sourceText, nextPosition, 2) = "##" Then Return -1
    Return 0
End Function

Private Function GenericObjectMacroExpandsToFunctionMacro( _
    definitions() As C2fbMacroExpansionDefinitionIndexModel, _
    ByVal definitionCount As Long, ByVal definitionIndex As Long, _
    ByVal depth As Long _
) As Long
    If depth >= MAX_GENERIC_MACRO_EXPANSION_DEPTH Then Return 0
    If definitions(definitionIndex).functionLike <> 0 Then Return -1
    Dim replacementName As String = Trim(definitions(definitionIndex).rawValue)
    If IsIdentifierToken(replacementName) = 0 Then Return 0
    Dim replacementIndex As Long = GenericMacroExpansionDefinitionIndex( _
        definitions(), definitionCount, replacementName)
    If replacementIndex < 0 Then Return 0
    Return GenericObjectMacroExpandsToFunctionMacro( _
        definitions(), definitionCount, replacementIndex, depth + 1)
End Function

Private Function ReadGenericMacroExpansionDefinitions( _
    ByVal macroTablePath As String, ByVal overridePath As String, _
    definitions() As C2fbMacroExpansionDefinitionIndexModel, _
    ByRef definitionCount As Long _
) As Long
    ReDim definitions(0 To 255)
    definitionCount = 0
    Dim reader As C2fbTextFileLineReaderModel
    If OpenC2fbTextFileLineReader(reader, macroTablePath) = 0 Then Return 0
    Dim lineText As String
    While ReadC2fbTextFileLine(reader, lineText) <> 0
        Dim definition As C2fbMacroDefinitionModel
        If ParseC2fbMacroDirective(Trim(lineText), definition) = 0 OrElse _
           definition.directive <> "define" Then Continue While
        If definitionCount >= MAX_FUNCTIONS Then
            CloseC2fbTextFileLineReader(reader)
            Return 0
        End If
        If definitionCount > UBound(definitions) Then _
            ReDim Preserve definitions(0 To UBound(definitions) * 2 + 1)
        definitions(definitionCount).sourceName = definition.sourceName
        definitions(definitionCount).rawValue = definition.rawValue
        definitions(definitionCount).functionLike = definition.functionLike
        definitionCount += 1
    Wend
    CloseC2fbTextFileLineReader(reader)

    If FileLengthIfPresent(overridePath) < 0 Then Return -1
    If OpenC2fbTextFileLineReader(reader, overridePath) = 0 Then Return 0
    While ReadC2fbTextFileLine(reader, lineText) <> 0
        Dim definition As C2fbMacroDefinitionModel
        If ParseC2fbMacroDirective(Trim(lineText), definition) = 0 OrElse _
           definition.directive <> "define" Then Continue While
        Dim definitionIndex As Long = GenericMacroExpansionDefinitionIndex( _
            definitions(), definitionCount, definition.sourceName)
        If definitionIndex < 0 Then
            If definitionCount >= MAX_FUNCTIONS Then
                CloseC2fbTextFileLineReader(reader)
                Return 0
            End If
            If definitionCount > UBound(definitions) Then _
                ReDim Preserve definitions(0 To UBound(definitions) * 2 + 1)
            definitionIndex = definitionCount
            definitionCount += 1
            definitions(definitionIndex).sourceName = definition.sourceName
        End If
        definitions(definitionIndex).rawValue = definition.rawValue
        definitions(definitionIndex).functionLike = definition.functionLike
    Wend
    CloseC2fbTextFileLineReader(reader)
    Return -1
End Function

Private Function BuildMacroInDefineExpansionWorkItems( _
    ByRef policy As C2fbGenericCPolicyModel, _
    definitions() As C2fbMacroExpansionDefinitionIndexModel, _
    ByVal definitionCount As Long, _
    workItems() As C2fbMacroInDefineExpansionWorkModel, _
    ByRef workCount As Long _
) As Long
    ReDim workItems(0 To 15)
    workCount = 0
    For ownerIndex As Long = 0 To definitionCount - 1
        Dim owner As C2fbMacroDefinitionModel
        owner.directive = "define"
        owner.sourceName = definitions(ownerIndex).sourceName
        owner.rawValue = definitions(ownerIndex).rawValue
        owner.functionLike = definitions(ownerIndex).functionLike
        Dim ownerBody As String = owner.rawValue
        Dim ownerHeader As String = "#define " & owner.sourceName
        Dim parameterNames() As String
        Dim freeParameterNames() As String
        Dim parameterCount As Long = 0
        Dim isVariadic As Long = 0
        If owner.functionLike <> 0 Then
            TokenizeCDeclaration(owner.rawValue, owner.tokens(), owner.tokenCount)
            If ParseGenericFunctionMacro( _
                owner, parameterNames(), freeParameterNames(), parameterCount, _
                isVariadic, ownerBody) = 0 Then Continue For
            Dim groupPosition As Long = 1
            If ScanSimpleExpressionGroup( _
                owner.rawValue, groupPosition, Asc("("), Asc(")")) = 0 Then _
                Continue For
            ownerHeader &= Left(owner.rawValue, groupPosition - 1)
        End If

        Dim position As Long = 1
        While position <= Len(ownerBody)
            Dim currentByte As Long = Asc(ownerBody, position)
            If currentByte = Asc(Chr(34)) OrElse currentByte = Asc("'") Then
                Dim quoteByte As Long = currentByte
                position += 1
                Dim escaped As Long = 0
                Dim foundClosingQuote As Long = 0
                While position <= Len(ownerBody)
                    currentByte = Asc(ownerBody, position)
                    If escaped <> 0 Then
                        escaped = 0
                    ElseIf currentByte = Asc(Chr(92)) Then
                        escaped = -1
                    ElseIf currentByte = quoteByte Then
                        foundClosingQuote = -1
                        Exit While
                    End If
                    position += 1
                Wend
                If foundClosingQuote = 0 Then Exit While
                position += 1
                Continue While
            End If
            If IsIdentifierStart(currentByte) = 0 Then
                position += 1
                Continue While
            End If
            Dim callStart As Long = position
            position += 1
            While position <= Len(ownerBody) AndAlso _
                  IsIdentifierPart(Asc(ownerBody, position)) <> 0
                position += 1
            Wend
            Dim calledMacroName As String = Mid( _
                ownerBody, callStart, position - callStart)
            Dim calledDefinitionIndex As Long = _
                GenericMacroExpansionDefinitionIndex( _
                    definitions(), definitionCount, calledMacroName)
            If calledDefinitionIndex < 0 OrElse _
               GenericMacroInDefineExpansionRequestedInPolicy( _
                    policy, calledMacroName) = 0 Then Continue While
            If GenericMacroNoExpansionInPolicy(policy, calledMacroName) <> 0 Then
                MarkGenericMacroInDefineExpansionInPolicy( _
                    policy, calledMacroName, -1)
                Continue While
            End If

            Dim callLength As Long = position - callStart
            If definitions(calledDefinitionIndex).functionLike <> 0 Then
                Dim openPosition As Long = position
                While openPosition <= Len(ownerBody) AndAlso _
                      IsSpaceByte(Asc(ownerBody, openPosition)) <> 0
                    openPosition += 1
                Wend
                If openPosition > Len(ownerBody) OrElse _
                   Asc(ownerBody, openPosition) <> Asc("(") Then Continue While
                Dim closePosition As Long
                If FindGenericMacroCallClosingParenthesis( _
                    ownerBody, openPosition, closePosition) = 0 Then
                    MarkGenericMacroInDefineExpansionInPolicy( _
                        policy, calledMacroName, 0)
                    Continue While
                End If
                callLength = closePosition - callStart + 1
            ElseIf GenericObjectMacroExpandsToFunctionMacro( _
                definitions(), definitionCount, calledDefinitionIndex, 0) <> 0 Then
                Dim openPosition As Long = position
                While openPosition <= Len(ownerBody) AndAlso _
                      IsSpaceByte(Asc(ownerBody, openPosition)) <> 0
                    openPosition += 1
                Wend
                If openPosition <= Len(ownerBody) AndAlso _
                   Asc(ownerBody, openPosition) = Asc("(") Then
                    Dim closePosition As Long
                    If FindGenericMacroCallClosingParenthesis( _
                        ownerBody, openPosition, closePosition) <> 0 Then
                        callLength = closePosition - callStart + 1
                    End If
                End If
            End If
            If GenericMacroCallHasStringizeOrPasteContext( _
                ownerBody, callStart, callLength) <> 0 Then
                MarkGenericMacroInDefineExpansionInPolicy( _
                    policy, calledMacroName, -1)
                position = callStart + callLength
                Continue While
            End If
            If GenericMacroCallUsesParentParameter( _
                ownerBody, callStart, callLength, parameterNames(), _
                parameterCount) <> 0 Then
                AddGenericMacroTokenConversionInPolicy(policy, owner.sourceName)
                MarkGenericMacroInDefineExpansionInPolicy( _
                    policy, calledMacroName, -1)
                position = callStart + callLength
                Continue While
            End If
            If workCount >= MAX_FUNCTIONS Then
                MarkGenericMacroInDefineExpansionInPolicy( _
                    policy, calledMacroName, 0)
                Continue While
            End If
            If workCount > UBound(workItems) Then _
                ReDim Preserve workItems(0 To UBound(workItems) * 2 + 1)

            Dim markerSuffix As String
            For suffixAttempt As Long = 0 To 127
                Dim candidateSuffix As String = _
                    Trim(Str(CULngInt(Timer * 1000))) & "_call_" & _
                    Trim(Str(workCount)) & "_" & Trim(Str(suffixAttempt))
                Dim hasNameConflict As Long = CInt( _
                    GenericMacroExpansionDefinitionIndex( _
                        definitions(), definitionCount, _
                        "C2FB_DEFINE_BEGIN_" & candidateSuffix) >= 0 OrElse _
                    GenericMacroExpansionDefinitionIndex( _
                        definitions(), definitionCount, _
                        "C2FB_DEFINE_END_" & candidateSuffix) >= 0)
                If hasNameConflict = 0 Then
                    markerSuffix = candidateSuffix
                    Exit For
                End If
            Next
            If markerSuffix = "" Then
                MarkGenericMacroInDefineExpansionInPolicy( _
                    policy, calledMacroName, 0)
                position = callStart + callLength
                Continue While
            End If
            If owner.functionLike <> 0 Then _
                AddGenericMacroTokenConversionInPolicy(policy, owner.sourceName)
            With workItems(workCount)
                .ownerName = owner.sourceName
                .ownerHeader = ownerHeader
                .ownerBody = ownerBody
                .targetName = calledMacroName
                .callPosition = callStart
                .callLength = callLength
                .beginMarker = "C2FB_DEFINE_BEGIN_" & markerSuffix
                .endMarker = "C2FB_DEFINE_END_" & markerSuffix
                .invocation = Mid(ownerBody, callStart, callLength)
            End With
            workCount += 1
            position = callStart + callLength
        Wend
    Next
    Return -1
End Function

Private Function WriteMacroInDefineExpansionProbe( _
    ByVal probePath As String, _
    workItems() As C2fbMacroInDefineExpansionWorkModel, _
    ByVal workCount As Long _
) As Long
    If workCount <= 0 Then Return 0
    Dim fileNumber As Long = FreeFile
    If Open(probePath For Output As #fileNumber) <> 0 Then Return 0
    For workIndex As Long = 0 To workCount - 1
        Print #fileNumber, workItems(workIndex).beginMarker
        Print #fileNumber, workItems(workIndex).invocation
        Print #fileNumber, workItems(workIndex).endMarker
    Next
    Close #fileNumber
    If Err <> 0 OrElse FileLengthIfPresent(probePath) < 0 Then Return 0
    Return -1
End Function

Private Function ReadMacroInDefineExpansionProbeOutput( _
    ByVal outputPath As String, _
    workItems() As C2fbMacroInDefineExpansionWorkModel, _
    ByVal workCount As Long _
) As Long
    Dim outputLength As LongInt = FileLengthIfPresent(outputPath)
    If outputLength < 0 OrElse _
       outputLength > MAX_GENERIC_MACRO_EXPANSION_OUTPUT_BYTES Then Return 0
    Dim reader As C2fbTextFileLineReaderModel
    If OpenC2fbTextFileLineReader(reader, outputPath) = 0 Then Return 0
    Dim activeWorkIndex As Long = -1
    Dim lineText As String
    While ReadC2fbTextFileLine(reader, lineText) <> 0
        Dim trimmedLine As String = Trim(lineText)
        Dim markerFound As Long = 0
        For workIndex As Long = 0 To workCount - 1
            If trimmedLine = workItems(workIndex).beginMarker Then
                If activeWorkIndex >= 0 Then
                    CloseC2fbTextFileLineReader(reader)
                    Return 0
                End If
                activeWorkIndex = workIndex
                workItems(workIndex).expandedBody = ""
                markerFound = -1
                Exit For
            ElseIf trimmedLine = workItems(workIndex).endMarker Then
                If activeWorkIndex <> workIndex Then
                    CloseC2fbTextFileLineReader(reader)
                    Return 0
                End If
                workItems(workIndex).hasOutput = -1
                activeWorkIndex = -1
                markerFound = -1
                Exit For
            End If
        Next
        If markerFound <> 0 OrElse activeWorkIndex < 0 OrElse _
           trimmedLine = "" Then Continue While
        If Len(workItems(activeWorkIndex).expandedBody) + Len(trimmedLine) + 1 > _
           MAX_GENERIC_MACRO_EXPANSION_BYTES Then
            CloseC2fbTextFileLineReader(reader)
            Return 0
        End If
        If workItems(activeWorkIndex).expandedBody <> "" Then _
            workItems(activeWorkIndex).expandedBody &= " "
        workItems(activeWorkIndex).expandedBody &= trimmedLine
    Wend
    CloseC2fbTextFileLineReader(reader)
    If activeWorkIndex >= 0 Then Return 0
    For workIndex As Long = 0 To workCount - 1
        If workItems(workIndex).hasOutput = 0 Then Return 0
    Next
    Return -1
End Function

Private Function AppendMacroInDefineExpansionOverrides( _
    ByRef policy As C2fbGenericCPolicyModel, ByVal overridePath As String, _
    workItems() As C2fbMacroInDefineExpansionWorkModel, _
    ByVal workCount As Long _
) As Long
    Dim fileNumber As Long = FreeFile
    If FileLengthIfPresent(overridePath) >= 0 Then
        If Open(overridePath For Append As #fileNumber) <> 0 Then Return 0
    Else
        If Open(overridePath For Output As #fileNumber) <> 0 Then Return 0
    End If
    Dim firstIndex As Long = 0
    While firstIndex < workCount
        Dim ownerName As String = workItems(firstIndex).ownerName
        Dim nextIndex As Long = firstIndex + 1
        While nextIndex < workCount AndAlso _
              workItems(nextIndex).ownerName = ownerName
            nextIndex += 1
        Wend
        Dim ownerBody As String = workItems(firstIndex).ownerBody
        Dim changed As Long = 0
        For workIndex As Long = nextIndex - 1 To firstIndex Step -1
            If workItems(workIndex).hasOutput = 0 Then
                MarkGenericMacroInDefineExpansionInPolicy( _
                    policy, workItems(workIndex).targetName, 0)
                Continue For
            End If
            ownerBody = Left(ownerBody, workItems(workIndex).callPosition - 1) & _
                workItems(workIndex).expandedBody & _
                Mid(ownerBody, workItems(workIndex).callPosition + _
                    workItems(workIndex).callLength)
            changed = -1
            MarkGenericMacroInDefineExpansionInPolicy( _
                policy, workItems(workIndex).targetName, 1)
        Next
        If changed <> 0 Then
            Dim replacementDefinition As String = workItems(firstIndex).ownerHeader
            If ownerBody <> "" Then _
                replacementDefinition &= " " & ownerBody
            Print #fileNumber, replacementDefinition
        End If
        firstIndex = nextIndex
    Wend
    Close #fileNumber
    If Err <> 0 OrElse FileLengthIfPresent(overridePath) < 0 Then Return 0
    Return -1
End Function

Private Function ExpandMacroCallsInGenericHeaderDefinitionsWithPreprocessor( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByVal compilerName As String, ByVal compilerOptions As String, _
    ByVal inputPath As String, ByVal macroTablePath As String, _
    ByVal probePath As String, ByVal expandedOutputPath As String, _
    ByVal overridePath As String _
) As Long
    If policy.macroInDefineExpansionPatternCount = 0 Then Return -1
    Dim definitions() As C2fbMacroExpansionDefinitionIndexModel
    Dim definitionCount As Long
    If ReadGenericMacroExpansionDefinitions( _
        macroTablePath, overridePath, definitions(), definitionCount) = 0 Then _
        Return 0
    Dim workItems() As C2fbMacroInDefineExpansionWorkModel
    Dim workCount As Long
    If BuildMacroInDefineExpansionWorkItems( _
        policy, definitions(), definitionCount, workItems(), workCount) = 0 Then _
        Return 0
    If workCount = 0 Then Return -1
    If WriteMacroInDefineExpansionProbe( _
        probePath, workItems(), workCount) = 0 Then
        For workIndex As Long = 0 To workCount - 1
            MarkGenericMacroInDefineExpansionInPolicy( _
                policy, workItems(workIndex).targetName, 0)
        Next
        Return -1
    End If

    Dim preprocessRequest As C2fbPreprocessorRequestModel
    preprocessRequest.compilerName = compilerName
    preprocessRequest.compilerOptions = _
        "-E -P -x c" & compilerOptions & _
        " -include " & ShellQuote(inputPath)
    preprocessRequest.inputPath = probePath
    preprocessRequest.outputPath = expandedOutputPath
    Dim preprocessResult As C2fbPreprocessorResultModel
    If RunC2fbPreprocessor(preprocessRequest, preprocessResult) = 0 OrElse _
       ReadMacroInDefineExpansionProbeOutput( _
            expandedOutputPath, workItems(), workCount) = 0 Then
        For workIndex As Long = 0 To workCount - 1
            MarkGenericMacroInDefineExpansionInPolicy( _
                policy, workItems(workIndex).targetName, 0)
        Next
        If FileLengthIfPresent(probePath) >= 0 Then Kill probePath
        If FileLengthIfPresent(expandedOutputPath) >= 0 Then _
            Kill expandedOutputPath
        Return -1
    End If
    If FileLengthIfPresent(probePath) >= 0 Then Kill probePath
    If FileLengthIfPresent(expandedOutputPath) >= 0 Then _
        Kill expandedOutputPath
    Return AppendMacroInDefineExpansionOverrides( _
        policy, overridePath, workItems(), workCount)
End Function

Private Function ApplyGenericMacroExpansionOverridesInContext( _
    ByRef translation As C2fbTranslationContext, ByVal overridePath As String _
) As Long
    If overridePath = "" OrElse FileLengthIfPresent(overridePath) < 0 Then Return -1
    Dim reader As C2fbTextFileLineReaderModel
    If OpenC2fbTextFileLineReader(reader, overridePath) = 0 Then Return 0
    Dim lineText As String
    While ReadC2fbTextFileLine(reader, lineText) <> 0
        Dim expandedDefinition As C2fbMacroDefinitionModel
        If ParseC2fbMacroDirective(lineText, expandedDefinition, -1) = 0 OrElse _
           expandedDefinition.directive <> "define" Then Continue While
        Dim macroIndex As Long = GenericHeaderMacroIndexInContext( _
            translation, expandedDefinition.sourceName)
        If macroIndex < 0 OrElse _
           translation.genericC.header.headerMacros(macroIndex).active = 0 Then _
            Continue While
        expandedDefinition.sourceLocation = _
            translation.genericC.header.headerMacros(macroIndex).definition.sourceLocation
        expandedDefinition.continued = _
            translation.genericC.header.headerMacros(macroIndex).definition.continued
        translation.genericC.header.headerMacros(macroIndex).definition = _
            expandedDefinition
    Wend
    CloseC2fbTextFileLineReader(reader)
    Return -1
End Function

Private Sub WriteGenericMacroExpansionReportInPolicy( _
    ByRef policy As C2fbGenericCPolicyModel, _
    ByRef outputFile As C2fbGeneratedFileOutputModel _
)
    If policy.macroExpansionPatternCount = 0 AndAlso _
       policy.macroInDefineExpansionPatternCount = 0 Then Exit Sub
    If policy.macroExpansionPatternCount > 0 Then
        WriteC2fbOutputLine(outputFile, "' c2fb selected macro expansion requests:")
        Dim automaticExpandedCount As Long = 0
        Dim automaticUnsupportedCount As Long = 0
        Dim automaticExcludedCount As Long = 0
        For patternIndex As Long = 0 To policy.macroExpansionPatternCount - 1
            If policy.macroExpansionPatterns(patternIndex).automatic <> 0 Then
                automaticExpandedCount += _
                    policy.macroExpansionPatterns(patternIndex).expandedCount
                automaticUnsupportedCount += _
                    policy.macroExpansionPatterns(patternIndex).unsupportedCount
                automaticExcludedCount += _
                    policy.macroExpansionPatterns(patternIndex).excludedCount
                Continue For
            End If
            Dim stateText As String
            If policy.macroExpansionPatterns(patternIndex).matched = 0 Then
                stateText = "unused"
            ElseIf policy.macroExpansionPatterns(patternIndex).expandedCount = 0 Then
                If policy.macroExpansionPatterns(patternIndex).unsupportedCount > 0 Then
                    stateText = "unsupported"
                Else
                    stateText = "excluded"
                End If
            ElseIf policy.macroExpansionPatterns(patternIndex).unsupportedCount > 0 OrElse _
                   policy.macroExpansionPatterns(patternIndex).excludedCount > 0 Then
                stateText = "partially expanded"
            Else
                stateText = "expanded"
            End If
            WriteC2fbOutputLine(outputFile, "' c2fb expand-macro " & stateText & ": " & _
                policy.macroExpansionPatterns(patternIndex).pattern & _
                " (expanded " & Trim(Str( _
                    policy.macroExpansionPatterns(patternIndex).expandedCount)) & _
                ", unsupported " & Trim(Str( _
                    policy.macroExpansionPatterns(patternIndex).unsupportedCount)) & _
                ", excluded " & Trim(Str( _
                    policy.macroExpansionPatterns(patternIndex).excludedCount)) & ")")
        Next
        If automaticExpandedCount + automaticUnsupportedCount + _
           automaticExcludedCount > 0 Then
            WriteC2fbOutputLine(outputFile, _
                "' c2fb automatic macro-state recovery: expanded " & _
                Trim(Str(automaticExpandedCount)) & ", unsupported " & _
                Trim(Str(automaticUnsupportedCount)) & ", excluded " & _
                Trim(Str(automaticExcludedCount)))
        End If
    End If
    If policy.macroNoExpansionPatternCount > 0 Then
        WriteC2fbOutputLine(outputFile, "' c2fb no-expand-macro patterns:")
        For patternIndex As Long = 0 To _
            policy.macroNoExpansionPatternCount - 1
            Dim stateText As String = "unused"
            If policy.macroNoExpansionPatterns(patternIndex).matched <> 0 Then _
                stateText = "matched"
            WriteC2fbOutputLine(outputFile, "' c2fb no-expand-macro " & _
                stateText & ": " & _
                policy.macroNoExpansionPatterns(patternIndex).pattern)
        Next
    End If
    If policy.macroInDefineExpansionPatternCount > 0 Then
        WriteC2fbOutputLine(outputFile, "' c2fb macro-call expansion in definitions:")
        For patternIndex As Long = 0 To _
            policy.macroInDefineExpansionPatternCount - 1
            Dim stateText As String
            If policy.macroInDefineExpansionPatterns(patternIndex).matched = 0 Then
                stateText = "unused"
            ElseIf policy.macroInDefineExpansionPatterns(patternIndex).expandedCount = 0 Then
                If policy.macroInDefineExpansionPatterns(patternIndex).unsupportedCount > 0 Then
                    stateText = "unsupported"
                Else
                    stateText = "excluded"
                End If
            ElseIf policy.macroInDefineExpansionPatterns(patternIndex).unsupportedCount > 0 OrElse _
                   policy.macroInDefineExpansionPatterns(patternIndex).excludedCount > 0 Then
                stateText = "partially expanded"
            Else
                stateText = "expanded"
            End If
            WriteC2fbOutputLine(outputFile, "' c2fb expand-in-define " & _
                stateText & ": " & _
                policy.macroInDefineExpansionPatterns(patternIndex).pattern & _
                " (expanded " & Trim(Str( _
                    policy.macroInDefineExpansionPatterns(patternIndex).expandedCount)) & _
                ", unsupported " & Trim(Str( _
                    policy.macroInDefineExpansionPatterns(patternIndex).unsupportedCount)) & _
                ", excluded " & Trim(Str( _
                    policy.macroInDefineExpansionPatterns(patternIndex).excludedCount)) & ")")
        Next
    End If
End Sub

/' end of c2fb_generic_macro_expansion.bi '/
